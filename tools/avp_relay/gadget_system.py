# SPDX-License-Identifier: GPL-3.0-or-later
"""Linux operations for the dedicated USB Ethernet appliance.

No shell commands, Wi-Fi uplink selection, Internet probes or tablet state.
Only this separately privileged service writes configfs/network configuration.
"""
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import time

from .gadget_config import STATE, atomic_json

BRIDGE = 'plankbr0'
GADGET = Path('/sys/kernel/config/usb_gadget/plank_network')
NETDIR = Path('/etc/systemd/network')
FILES = ('04-plank-usb.netdev', '04-plank-usb-bridge.network',
         '04-plank-usb-wired.network', '04-plank-usb-device.network')
MARKER = '# Managed by plank-avp-relay-usb\n'


def run(*args, check=True, input=None):
    try:
        result = subprocess.run(args, input=input, capture_output=True, text=True, timeout=8,
                                env={**os.environ, 'LC_ALL': 'C'})
    except FileNotFoundError:
        if not check:
            return ''
        raise RuntimeError(f'Required command {args[0]} is unavailable.') from None
    except subprocess.TimeoutExpired:
        raise RuntimeError(f'{args[0]} did not complete in time.') from None
    if check and result.returncode:
        raise RuntimeError(f'{args[0]} failed: {result.stderr.strip()[:240]}')
    return result.stdout.strip() if result.returncode == 0 else ''


def read(path, default=''):
    try:
        return Path(path).read_text().replace('\x00', '').strip()
    except OSError:
        return default


def write(path, value):
    Path(path).write_text(str(value) + '\n')


def network_files(mode, wired, mac, device_mac, address, baseline):
    """Pure rendering: each interface is managed by exactly one owned file."""
    common = '\n[Link]\nRequiredForOnline=no\n\n[Network]\n'
    if mode == 'router':
        return {FILES[3]: MARKER + '[Match]\nMACAddress=' + device_mac + common +
                f'Address={address}\nDHCPServer=yes\nConfigureWithoutCarrier=yes\n'
                'IPv6AcceptRA=no\n\n[DHCPServer]\n'
                f'UplinkInterface={wired}\nEmitDNS=yes\nPoolOffset=0\nPoolSize=0\n'}
    bridge = MARKER + f'[Match]\nName={BRIDGE}\n\n[Network]\n'
    if baseline['dhcp']:
        bridge += 'DHCP=yes\n'
    for item in baseline['addresses']:
        bridge += f'Address={item}\n'
    for server in baseline['dns']:
        bridge += f'DNS={server}\n'
    for route in baseline['routes']:
        bridge += '\n[Route]\n'
        if route['destination'] != 'default':
            bridge += f"Destination={route['destination']}\n"
        bridge += f"Gateway={route['gateway']}\n"
        if route.get('metric') is not None:
            bridge += f"Metric={route['metric']}\n"
    # Keep the existing DHCP identifier policy; a matching MAC alone cannot
    # guarantee that the DHCP server will issue the previous address.
    return {
        FILES[0]: MARKER + f'[NetDev]\nName={BRIDGE}\nKind=bridge\nMACAddress={mac}\n\n[Bridge]\nSTP=no\n',
        FILES[1]: bridge,
        FILES[2]: MARKER + f'[Match]\nName={wired}' + common +
                  f'Bridge={BRIDGE}\nLinkLocalAddressing=no\nIPv6AcceptRA=no\n',
        FILES[3]: MARKER + f'[Match]\nMACAddress={device_mac}' + common +
                  f'Bridge={BRIDGE}\nLinkLocalAddressing=no\nIPv6AcceptRA=no\n',
    }


def firewall(mode, wired, usb, subnet):
    # The inet guard covers both IP families. In router mode, forwarded IPv6
    # is intentionally unavailable until there is an explicit IPv6 design.
    guard = (f'iifname "{usb}" meta nfproto ipv6 drop\n'
             f'iifname "{usb}" oifname != "{wired}" drop\n'
             f'oifname "{usb}" ct state established,related accept\n'
             f'oifname "{usb}" drop\n') if mode == 'router' else (
             f'iifname "{BRIDGE}" oifname != "{BRIDGE}" drop\n')
    nat = f'ip saddr {subnet} oifname "{wired}" masquerade\n' if mode == 'router' else ''
    return ('add table inet plank_usb\ndelete table inet plank_usb\n'
            'add table ip plank_usb\ndelete table ip plank_usb\n'
            'table inet plank_usb { chain forward { type filter hook forward priority -10; policy accept;\n' +
            guard + '}\n}\ntable ip plank_usb { chain postrouting { type nat hook postrouting priority srcnat; policy accept;\n' +
            nat + '}\n}\n')


class LinuxGadget:
    def __init__(self, settings):
        self.settings = settings
        self.wired = ''
        self.controller = ''
        self.function = settings.function
        self.gateway = None
        self.current = None
        self.baseline = None
        self.guard_ready = False
        self.restart_required = False
        self.unsupported = ''
        self.fault = ''
        self.inherited_mode = None
        self.digest = hashlib.sha256((read('/etc/machine-id') + ':plank-usb-network').encode()).hexdigest()
        self.device_mac = '02:' + ':'.join(self.digest[n:n+2] for n in range(0, 10, 2))
        self.host_mac = '06:' + self.device_mac[3:]

    def prepare(self):
        self.select_wired(required=False)
        model = read('/sys/firmware/devicetree/base/model').lower().replace(' ', '').replace('-', '')
        if self.settings.enabled == 'false' or (self.settings.enabled == 'auto' and
                (not Path('/etc/armbian-release').exists() or 'nanopizero2' not in model)):
            self.unsupported = 'USB networking is not enabled for this hardware.'
            return False
        if not run('systemctl', 'is-active', 'systemd-networkd.service', check=False) == 'active':
            raise RuntimeError('USB networking requires systemd-networkd.')
        self.select_wired(required=True)
        run('modprobe', 'libcomposite')
        try:
            run('modprobe', 'usb_f_' + self.function)
        except RuntimeError:
            if self.function != 'ncm':
                raise
            run('modprobe', 'usb_f_ecm')
            self.function = 'ecm'
        run('modprobe', 'bridge')
        if not any(line.split()[1:3] == ['/sys/kernel/config', 'configfs']
                   for line in read('/proc/mounts').splitlines()):
            run('mount', '-t', 'configfs', 'none', '/sys/kernel/config')
        roles = list(Path('/sys/class/usb_role').glob('*/role'))
        if len(roles) == 1 and read(roles[0]) != 'device':
            write(roles[0], 'device')
        controllers = sorted(Path('/sys/class/udc').glob('*'))
        if not controllers:
            self.install_overlay()
            self.restart_required = True
            return True
        if self.settings.controller:
            controllers = [item for item in controllers if item.name == self.settings.controller]
        if len(controllers) != 1:
            raise RuntimeError('Set controller in usb-network.conf; USB controller selection is ambiguous.')
        self.controller = controllers[0].name
        self.adopt_standalone()
        self.capture_baseline()
        # Do not silently take control from another gadget application.
        for gadget in GADGET.parent.iterdir():
            if gadget != GADGET:
                raise RuntimeError('Another USB gadget is configured. Remove its installer before enabling PLANK USB networking.')
        if run('systemctl', 'is-active', 'usb-gadget.service', check=False) == 'active':
            raise RuntimeError('The standalone usb-gadget service must be removed before PLANK takes ownership.')
        self.teardown()
        self.setup()
        run('udevadm', 'settle', '--timeout=5')
        return True

    def select_wired(self, required=False):
        candidates = []
        for port in sorted(Path('/sys/class/net').iterdir()):
            if (port / 'device').exists() and not (port / 'wireless').exists() and not (port / 'phy80211').exists():
                if (port / 'device/subsystem').resolve().name != 'usb':
                    candidates.append(port.name)
        if self.settings.wired_interface:
            self.wired = self.settings.wired_interface
            port = Path('/sys/class/net') / self.wired
            if not port.exists() or (port / 'wireless').exists() or (port / 'phy80211').exists():
                self.wired = ''
                if required:
                    raise RuntimeError('The selected wired interface is unavailable or wireless.')
        elif len(candidates) == 1:
            self.wired = candidates[0]
        elif required:
            raise RuntimeError('Set wired_interface in usb-network.conf; Ethernet selection is ambiguous.')

    def install_overlay(self):
        if not Path('/etc/armbian-release').exists():
            raise RuntimeError('Enable USB peripheral mode in this board’s firmware configuration.')
        tree = Path('/sys/firmware/devicetree/base')
        node = self.settings.otg_node
        if not node:
            nodes = [item.parent for item in tree.rglob('dr_mode') if read(item) == 'host' and
                     read(item.parent / 'status', 'okay') in ('ok', 'okay')]
            if len(nodes) != 1:
                raise RuntimeError('Set otg_node in usb-network.conf; USB peripheral-mode selection is ambiguous.')
            node = '/' + str(nodes[0].relative_to(tree))
        if not (tree / node.lstrip('/') / 'dr_mode').exists():
            raise RuntimeError('The configured OTG node does not exist.')
        directory = Path('/boot/overlay-user')
        directory.mkdir(exist_ok=True)
        source = STATE / 'plank-usb-peripheral.dts'
        write(source, '/dts-v1/;\n/plugin/;\n/ { fragment@0 { target-path = "' + node +
              '"; __overlay__ { dr_mode = "peripheral"; }; }; };')
        overlay = directory / 'plank-usb-peripheral.dtbo'
        run('dtc', '-@', '-I', 'dts', '-O', 'dtb', '-o', str(overlay), str(source))
        env = Path('/boot/armbianEnv.txt')
        original = env.read_text()
        backup = STATE / 'armbianEnv.before'
        if not backup.exists():
            backup.write_text(original)
        lines = original.splitlines()
        found = False
        for index, line in enumerate(lines):
            if line.startswith('user_overlays='):
                values = line.split('=', 1)[1].split()
                if 'plank-usb-peripheral' not in values:
                    values.append('plank-usb-peripheral')
                lines[index] = 'user_overlays=' + ' '.join(values)
                found = True
        if not found:
            lines.append('user_overlays=plank-usb-peripheral')
        env.write_text('\n'.join(lines) + '\n')

    def adopt_standalone(self):
        """One-time migration of the exact supplied installer, never a backend.

        Unknown gadget services remain untouched. Keep an owned private backup
        before retiring the standalone service and its networkd fragments.
        """
        tool = Path('/usr/local/sbin/usb-gadget')
        unit = Path('/etc/systemd/system/usb-gadget.service')
        config = Path('/etc/default/usb-gadget')
        if not (tool.exists() and unit.exists() and config.exists()):
            return
        if ('installed by install-usb-gadget.sh' not in tool.read_text() or
                'ExecStart=/usr/local/sbin/usb-gadget monitor' not in unit.read_text()):
            raise RuntimeError('An unrecognized USB gadget service already owns this device.')
        values = dict(line.split('=', 1) for line in config.read_text().splitlines()
                      if '=' in line and not line.startswith('#'))
        if values.get('MODE') not in ('bridge', 'router') or values.get('WAN_IF') != self.wired or values.get('GADGET') != 'usbeth':
            raise RuntimeError('The standalone gadget settings cannot be migrated automatically.')
        old_bridge = values.get('BRIDGE', 'br0')
        if not re.fullmatch(r'[a-zA-Z0-9_-]{1,15}', old_bridge):
            raise RuntimeError('Invalid previous bridge name.')
        table = int(values.get('RT_TABLE', '155'))
        if not 1 <= table < 2**31 or table in (253, 254, 255):
            raise RuntimeError('Invalid previous routing table.')
        names = ['05-usb-gadget.network', '04-usbbr.netdev', '04-usbbr-bridge.network',
                 '04-usbbr-uplink.network', '04-usbbr-gadget.network']
        paths = [tool, unit, config] + [NETDIR/name for name in names if (NETDIR/name).exists()]
        for path in paths[3:]:
            if 'written by install-usb-gadget.sh' not in path.read_text():
                raise RuntimeError('A previous USB network file has an unknown owner.')
        backup = STATE / 'standalone-before.json'
        if not backup.exists():
            atomic_json(backup, {str(path): path.read_text() for path in paths})
        self.capture_baseline(allowed_bridge=old_bridge)
        self.inherited_mode = values['MODE']
        if not (STATE / 'mode.json').exists():
            atomic_json(STATE / 'mode.json', dict(mode=self.inherited_mode, targetMode=self.inherited_mode,
                                                phase='idle', requestID=None))
        run('systemctl', 'disable', '--now', 'usb-gadget.service')
        self.teardown_path(GADGET.parent / 'usbeth')
        self.clear_routes()
        run('ip', '-4', 'route', 'flush', 'table', str(table), check=False)
        run('nft', 'delete', 'table', 'ip', 'usb_gadget', check=False)
        for path in paths:
            path.unlink()
        run('systemctl', 'daemon-reload')
        run('networkctl', 'reload')
        if (Path('/sys/class/net') / old_bridge / 'bridge').exists():
            run('ip', 'link', 'delete', old_bridge)
        run('networkctl', 'reconfigure', self.wired)

    def capture_baseline(self, allowed_bridge=None):
        path = STATE / 'wired-before.json'
        if path.exists():
            self.baseline = json.loads(path.read_text())
            if self.baseline['wired'] != self.wired:
                raise RuntimeError('Wired interface changed; restore the previous USB network configuration first.')
            return
        master = Path('/sys/class/net') / self.wired / 'master'
        source = self.wired
        if master.exists() and master.resolve().name != allowed_bridge:
            raise RuntimeError('The Ethernet port is already bridged. Remove its previous bridge configuration first.')
        if master.exists():
            source = allowed_bridge
        addresses = json.loads(run('ip', '-j', 'address', 'show', 'dev', source))[0]['addr_info']
        global4 = [a for a in addresses if a['family'] == 'inet' and a['scope'] == 'global']
        dhcp = not global4 or any(a.get('dynamic') for a in global4)
        static = [str(ipaddress.ip_interface(f"{a['local']}/{a['prefixlen']}")) for a in addresses
                  if a['scope'] == 'global' and not a.get('dynamic') and
                  (a['family'] != 'inet' or not dhcp)]
        routes = []
        for family in ('-4', '-6'):
            for route in json.loads(run('ip', family, '-j', 'route', 'show', 'dev', source)):
                if route.get('gateway') and route.get('protocol') not in ('dhcp', 'ra'):
                    destination = route.get('dst', 'default')
                    if destination != 'default':
                        destination = str(ipaddress.ip_network(destination))
                    routes.append(dict(destination=destination, gateway=str(ipaddress.ip_address(route['gateway'])),
                                       metric=route.get('metric')))
        dns = run('resolvectl', 'dns', source, check=False).partition(':')[2].split()
        servers = []
        for value in dns:
            try:
                servers.append(str(ipaddress.ip_address(value)))
            except ValueError:
                pass
        self.baseline = dict(wired=self.wired, dhcp=dhcp, addresses=static, dns=servers, routes=routes,
                             forwarding=read('/proc/sys/net/ipv4/ip_forward', '0'),
                             mac=read(Path('/sys/class/net') / self.wired / 'address'))
        atomic_json(path, self.baseline)

    def setup(self):
        GADGET.mkdir()
        try:
            for name, value in {'idVendor': '0x1d6b', 'idProduct': '0x0104',
                                'bcdDevice': '0x0100', 'bcdUSB': '0x0200'}.items():
                write(GADGET / name, value)
            strings = GADGET / 'strings/0x409'
            strings.mkdir()
            for name, value in {'serialnumber': self.digest[10:26], 'manufacturer': 'PLANK',
                                'product': 'PLANK AVP Relay Ethernet'}.items():
                write(strings / name, value)
            config = GADGET / 'configs/c.1'
            (config / 'strings/0x409').mkdir(parents=True)
            write(config / 'strings/0x409/configuration', 'PLANK USB Ethernet')
            write(config / 'MaxPower', 250)
            self.function_path.mkdir()
            write(self.function_path / 'dev_addr', self.device_mac)
            write(self.function_path / 'host_addr', self.host_mac)
            # Reserve the name before binding: newer kernels register the
            # network device only when UDC is bound. Configuration and the
            # wired-only firewall must be ready before that attachment.
            write(self.function_path / 'ifname', 'plankusb0')
            (config / 'network').symlink_to(self.function_path)
        except Exception:
            self.teardown()
            raise

    @property
    def function_path(self):
        return GADGET / ('functions/' + self.function + '.usb0')

    def usb_interface(self):
        for path in Path('/sys/class/net').iterdir():
            if read(path / 'address') == self.device_mac:
                return path.name
        name = read(self.function_path / 'ifname')
        if name == 'plankusb0':
            if (Path('/sys/class/net') / name).exists():
                raise RuntimeError('The reserved USB network interface name is already in use.')
            return name
        raise RuntimeError('USB network interface has not appeared.')

    def unbind(self):
        if read(GADGET / 'UDC'):
            write(GADGET / 'UDC', '')

    def teardown(self):
        self.teardown_path(GADGET)

    def teardown_path(self, gadget):
        if not gadget.exists():
            return
        if read(gadget / 'UDC'):
            write(gadget / 'UDC', '')
        for link in gadget.glob('configs/*/*'):
            if link.is_symlink():
                link.unlink()
        for pattern in ('configs/*/strings/*', 'configs/*', 'functions/*', 'strings/*'):
            for directory in gadget.glob(pattern):
                directory.rmdir()
        gadget.rmdir()

    def clear_routes(self):
        for priority in (31000, 31001, 31002):
            # These resources are reserved by the dedicated appliance image.
            run('ip', '-4', 'rule', 'del', 'pref', str(priority), check=False)
        run('ip', '-4', 'route', 'flush', 'table', '155', check=False)
        self.gateway = None

    def check_subnet(self):
        target = ipaddress.IPv4Interface(self.settings.router_address).network
        for interface in json.loads(run('ip', '-j', 'address', 'show')):
            if interface['ifname'] == self.usb_interface():
                continue
            for address in interface.get('addr_info', []):
                if address['family'] == 'inet' and address['scope'] == 'global':
                    other = ipaddress.IPv4Interface(f"{address['local']}/{address['prefixlen']}").network
                    if target.overlaps(other):
                        raise RuntimeError('The Router subnet overlaps another network. Change router_address in usb-network.conf.')

    def apply(self, mode):
        if self.restart_required:
            return
        if mode == 'router':
            self.check_subnet()
        self.unbind()
        self.guard_ready = False
        usb = self.usb_interface()
        # Apply the wired-only guard before enabling forwarding or exposing USB.
        run('nft', '-f', '-', input=firewall(mode, self.wired, usb,
                                           ipaddress.IPv4Interface(self.settings.router_address).network))
        self.clear_routes()
        files = network_files(mode, self.wired, self.baseline['mac'], self.device_mac,
                              self.settings.router_address, self.baseline)
        NETDIR.mkdir(parents=True, exist_ok=True)
        for name in FILES:
            path = NETDIR / name
            if path.exists() and not path.read_text().startswith(MARKER):
                raise RuntimeError('A USB network configuration filename is already in use.')
            if name in files:
                temporary = path.with_suffix(path.suffix + '.tmp')
                temporary.write_text(files[name])
                temporary.replace(path)
            elif path.exists():
                path.unlink()
        run('networkctl', 'reload')
        if mode == 'bridge':
            for attempt in range(15):
                if (Path('/sys/class/net') / BRIDGE).exists():
                    break
                time.sleep(0.2)
            else:
                raise RuntimeError('The USB bridge did not appear after network configuration.')
        if mode == 'router' and (Path('/sys/class/net') / BRIDGE).exists():
            run('ip', 'link', 'delete', BRIDGE)
        # networkd may retain the old link's addresses after moving it to a
        # bridge. Flush those addresses explicitly; configuration is on br0.
        if mode == 'bridge':
            run('ip', 'address', 'flush', 'dev', self.wired, 'scope', 'global')
        run('networkctl', 'reconfigure', self.wired)
        if (Path('/sys/class/net') / usb).exists():
            run('networkctl', 'reconfigure', usb)
        if mode == 'bridge':
            run('networkctl', 'reconfigure', BRIDGE)
        matches = {usb: FILES[3]} if (Path('/sys/class/net') / usb).exists() else {}
        if mode == 'bridge':
            matches.update({self.wired: FILES[2], BRIDGE: FILES[1]})
        self.verify_network_files(matches)
        if mode == 'router':
            run('ip', '-4', 'rule', 'add', 'pref', '31000', 'iif', usb, 'lookup', 'main', 'suppress_prefixlength', '0')
            run('ip', '-4', 'rule', 'add', 'pref', '31001', 'iif', usb, 'lookup', '155')
            run('ip', '-4', 'rule', 'add', 'pref', '31002', 'iif', usb, 'unreachable')
        write('/proc/sys/net/ipv4/ip_forward', '1' if mode == 'router' else self.baseline['forwarding'])
        self.current = mode
        self.guard_ready = True
        self.sync()

    def verify_network_files(self, matches):
        for interface, name in matches.items():
            for attempt in range(5):
                status = run('networkctl', 'status', interface, '--no-pager')
                if str(NETDIR / name) in status:
                    break
                if attempt == 4:
                    raise RuntimeError('An earlier network configuration overrides the USB appliance settings.')
                time.sleep(0.2)

    def sync(self):
        if self.restart_required or not self.current:
            return
        connected = read(Path('/sys/class/net') / self.wired / 'carrier') == '1'
        if not connected:
            self.unbind()
            return
        # Recover after a firewall reload, keeping USB detached until protected.
        if not run('nft', 'list', 'table', 'inet', 'plank_usb', check=False) or not run(
                'nft', 'list', 'table', 'ip', 'plank_usb', check=False):
            self.unbind()
            self.guard_ready = False
            run('nft', '-f', '-', input=firewall(self.current, self.wired, self.usb_interface(),
                                               ipaddress.IPv4Interface(self.settings.router_address).network))
            self.guard_ready = True
        if self.current == 'router':
            routes = json.loads(run('ip', '-4', '-j', 'route', 'show', 'default', 'dev', self.wired))
            gateway = next((item['gateway'] for item in routes if item.get('gateway')), '')
            if gateway != self.gateway:
                if gateway:
                    run('ip', '-4', 'route', 'replace', 'default', 'via', gateway, 'dev', self.wired, 'table', '155')
                else:
                    run('ip', '-4', 'route', 'flush', 'table', '155')
                self.gateway = gateway
        if self.guard_ready and not read(GADGET / 'UDC'):
            write(GADGET / 'UDC', self.controller)
            # Binding creates the netdev on kernels with deferred registration.
            # Its networkd file and forwarding guard already exist.
            usb = self.usb_interface()
            run('udevadm', 'settle', '--timeout=5')
            run('networkctl', 'reconfigure', usb)
            self.verify_network_files({usb: FILES[3]})
        self.fault = ''

    def status(self):
        if not self.wired:
            self.select_wired(required=False)
        carrier = read(Path('/sys/class/net') / self.wired / 'carrier') if self.wired else ''
        connected = (carrier == '1') if carrier in ('0', '1') else None
        ethernet = 'unknown' if connected is None else ('connected' if connected else 'disconnected')
        if self.restart_required:
            usb = 'reboot'
        elif self.fault:
            usb = 'error'
        elif not self.current:
            usb = 'unavailable'
        elif connected is False:
            usb = 'waiting'
        elif connected is None:
            usb = 'unavailable'
        elif read(GADGET / 'UDC'):
            state = read(Path('/sys/class/udc') / self.controller / 'state')
            usb = 'connected' if state == 'configured' else ('suspended' if state == 'suspended' else 'disconnected')
        else:
            usb = 'preparing'
        addresses = []
        interfaces = [BRIDGE] if self.current == 'bridge' else [self.wired]
        if self.current == 'router':
            interfaces.append(self.usb_interface())
        for interface in interfaces:
            if interface and (Path('/sys/class/net') / interface).exists():
                info = json.loads(run('ip', '-j', 'address', 'show', 'dev', interface))
                addresses += [a['local'] for item in info for a in item.get('addr_info', []) if a['scope'] == 'global']
        return dict(ethernet=ethernet, usb=usb, addresses=list(dict.fromkeys(addresses))[:8])

    def remove(self):
        self.teardown()
        self.clear_routes()
        for family in ('inet', 'ip'):
            run('nft', 'delete', 'table', family, 'plank_usb', check=False)
        for name in FILES:
            path = NETDIR / name
            if path.exists() and path.read_text().startswith(MARKER):
                path.unlink()
        if (STATE / 'wired-before.json').exists():
            before = json.loads((STATE / 'wired-before.json').read_text())
            run('networkctl', 'reload', check=False)
            run('ip', 'link', 'delete', BRIDGE, check=False)
            run('networkctl', 'reconfigure', before['wired'], check=False)
            write('/proc/sys/net/ipv4/ip_forward', before['forwarding'])
        env = Path('/boot/armbianEnv.txt')
        if (STATE / 'armbianEnv.before').exists() and env.exists():
            lines = env.read_text().splitlines()
            for index, line in enumerate(lines):
                if line.startswith('user_overlays='):
                    lines[index] = 'user_overlays=' + ' '.join(value for value in line.split('=', 1)[1].split()
                                                               if value != 'plank-usb-peripheral')
            env.write_text('\n'.join(lines) + '\n')
            (Path('/boot/overlay-user') / 'plank-usb-peripheral.dtbo').unlink(missing_ok=True)
