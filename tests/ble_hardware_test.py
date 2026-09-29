# SPDX-License-Identifier: GPL-3.0-or-later
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from ble_lab.hardware import prepare_firmware, switch_disks, recover_radios, initialized
from ble_lab.host_setup import configure_armbian


class ArmbianInstallationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / 'etc/default/cpufrequtils'
        self.config.parent.mkdir(parents=True)

    def test_non_armbian_configuration_is_untouched(self):
        self.assertFalse(configure_armbian(self.root))
        self.assertFalse(self.config.exists())
        self.config.write_text('GOVERNOR="performance"\nENABLED="false"\n')
        original = self.config.read_bytes()
        self.assertFalse(configure_armbian(self.root))
        self.assertEqual(self.config.read_bytes(), original)
        self.assertFalse((self.root / 'var').exists())

    def test_armbian_preserves_other_settings_and_original_across_upgrades(self):
        (self.root / 'etc/armbian-release').write_text('VENDOR="Armbian"\n')
        original = ('# Board frequency limits\nMIN_SPEED=408000\nMAX_SPEED=2016000\n'
                    'BOOST=false\nENABLE=true\nGOVERNOR=ondemand\n'
                    'export GOVERNOR="performance"\nENABLED=false\n')
        self.config.write_text(original)
        self.config.chmod(0o640)
        self.assertTrue(configure_armbian(self.root))
        changed = self.config.read_bytes()
        self.assertIn(b'MIN_SPEED=408000\nMAX_SPEED=2016000\nBOOST=false\nENABLE=true\n', changed)
        self.assertIn(b'GOVERNOR="powersave"\nexport GOVERNOR="powersave"\nENABLED="true"\n', changed)
        self.assertTrue(changed.startswith(b'# Board frequency limits\n'))
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o640)
        backup = self.root / 'var/backups/plank-tablet-relay/cpufrequtils.before-powersave'
        self.assertEqual(backup.read_text(), original)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        self.assertFalse(configure_armbian(self.root))
        self.assertEqual(self.config.read_bytes(), changed)
        self.config.write_text('GOVERNOR=performance\n')
        self.assertTrue(configure_armbian(self.root))
        self.assertEqual(backup.read_text(), original)

    def test_armbian_creates_missing_settings(self):
        (self.root / 'etc/armbian-release').touch()
        self.assertTrue(configure_armbian(self.root))
        self.assertEqual(self.config.read_text(), 'GOVERNOR="powersave"\nENABLED="true"\n')
        self.config.write_text('MAX_SPEED=2016000')  # No trailing newline.
        self.assertTrue(configure_armbian(self.root))
        self.assertEqual(self.config.read_text(), 'MAX_SPEED=2016000\nGOVERNOR="powersave"\nENABLED="true"\n')


class HardwareTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.firmware = self.root / 'firmware'
        self.bundle = self.root / 'bundle'
        self.bundle.mkdir()
        self.name = 'rtl8851bu_fw.bin'
        (self.bundle / self.name).write_bytes(b'test firmware')
        (self.bundle / 'manifest.json').write_text(json.dumps({'files': {
            self.name: hashlib.sha256(b'test firmware').hexdigest()}}))
        self.fallback = self.firmware / 'updates/rtl_bt' / self.name

    def prepare(self, **kwargs):
        prepare_firmware(self.firmware, self.bundle, release='test-kernel', **kwargs)

    def test_install_without_dongle_supplies_firmware_for_later_hotplug(self):
        self.prepare()
        self.assertTrue(self.fallback.is_symlink())
        self.assertEqual(self.fallback.read_bytes(), b'test firmware')
        self.prepare()
        self.assertEqual(self.fallback.read_bytes(), b'test firmware')
        self.prepare(remove=True)
        self.assertFalse(self.fallback.is_symlink())
        self.prepare(remove=True)
        self.prepare()  # Reinstall, no adapter required.
        self.assertEqual(self.fallback.read_bytes(), b'test firmware')

    def test_preserves_distribution_and_admin_firmware_including_compression(self):
        for relative in ('rtl_bt/', 'updates/rtl_bt/', 'test-kernel/rtl_bt/',
                         'updates/test-kernel/rtl_bt/'):
            for suffix in ('', '.xz', '.zst'):
                with self.subTest(relative=relative, suffix=suffix):
                    existing = self.firmware / relative / (self.name + suffix)
                    existing.parent.mkdir(parents=True, exist_ok=True)
                    existing.write_bytes(b'OS supplied')
                    self.prepare()
                    self.assertFalse(self.fallback.is_symlink())
                    self.assertEqual(existing.read_bytes(), b'OS supplied')
                    self.prepare(remove=True)
                    self.assertEqual(existing.read_bytes(), b'OS supplied')
                    existing.unlink()

    def test_os_update_supersedes_only_owned_fallback(self):
        self.prepare()
        supplied = self.firmware / 'rtl_bt' / self.name
        supplied.parent.mkdir(parents=True)
        supplied.write_bytes(b'new OS firmware')
        self.prepare()
        self.assertFalse(self.fallback.exists())
        self.assertEqual(supplied.read_bytes(), b'new OS firmware')

    def test_respects_custom_firmware_search_path(self):
        extra = self.root / 'admin/rtl_bt'
        extra.mkdir(parents=True)
        (extra / self.name).write_bytes(b'admin firmware')
        self.prepare(extra=extra.parent)
        self.assertFalse(self.fallback.exists())

    def test_remove_does_not_delete_an_admin_replacement(self):
        self.prepare()
        self.fallback.unlink()
        self.fallback.write_bytes(b'replacement')
        self.prepare(remove=True)
        self.assertEqual(self.fallback.read_bytes(), b'replacement')

    def test_never_replaces_unowned_broken_symlink(self):
        self.fallback.parent.mkdir(parents=True)
        self.fallback.symlink_to('/nonexistent/admin-firmware')
        with self.assertRaisesRegex(RuntimeError, 'Refusing to replace'):
            self.prepare()
        self.prepare(remove=True)
        self.assertEqual(os.readlink(self.fallback), '/nonexistent/admin-firmware')

    def test_bad_bundle_cannot_install_firmware(self):
        (self.bundle / self.name).write_bytes(b'corrupted')
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            self.prepare()
        self.assertFalse(self.fallback.exists())

    def test_actual_bundled_firmware_matches_pinned_manifest(self):
        bundle = Path(__file__).resolve().parents[1] / 'packaging/ble/firmware'
        prepare_firmware(self.firmware, bundle)
        self.assertEqual((self.firmware / 'updates/rtl_bt/rtl8851bu_fw.bin').stat().st_size, 49760)
        self.assertEqual((self.firmware / 'updates/rtl_bt/rtl8851bu_config.bin').stat().st_size, 6)

    def usb_device(self, name='1-1', vendor='0bda', product='1a2b', kind='08'):
        usb = self.root / 'usb'
        device = usb / name
        interface = usb / (name + ':1.0')
        device.mkdir(parents=True)
        interface.mkdir()
        for key, value in {'idVendor': vendor, 'idProduct': product, 'busnum': '1', 'devnum': '2'}.items():
            (device / key).write_text(value)
        for key, value in {'bInterfaceClass': kind, 'bInterfaceSubClass': '01', 'bInterfaceProtocol': '01'}.items():
            (interface / key).write_text(value)
        return usb, interface

    def test_mode_switch_is_scoped_to_realtek_driver_disk_and_usb_address(self):
        usb, _ = self.usb_device()
        self.usb_device('1-2', vendor='abcd')
        self.usb_device('1-3', kind='e0')
        with patch('ble_lab.hardware.run') as run:
            switch_disks(usb)
        run.assert_called_once_with(['usb_modeswitch', '-K', '-v', '0bda', '-p', '1a2b', '-b', '1', '-g', '2'])

    def radio(self):
        usb, interface = self.usb_device(vendor='3625', product='010b', kind='e0')
        drivers = self.root / 'drivers'
        driver = drivers / 'btusb'
        driver.mkdir(parents=True)
        (driver / 'unbind').write_text('untouched')
        (driver / 'bind').write_text('untouched')
        (interface / 'driver').symlink_to(driver)
        return usb, interface, drivers

    def test_initialized_controller_is_never_reset(self):
        usb, _, drivers = self.radio()
        with patch('ble_lab.hardware.wait_initialized', return_value=True):
            recover_radios(usb, drivers)
        self.assertEqual((drivers / 'btusb/unbind').read_text(), 'untouched')
        self.assertEqual((drivers / 'btusb/bind').read_text(), 'untouched')

    def test_failed_firmware_probe_retries_only_bluetooth_interface(self):
        usb, interface, drivers = self.radio()
        wifi = usb / '1-1:1.2'
        wifi.mkdir()
        with patch('ble_lab.hardware.wait_initialized', side_effect=[False, True]):
            recover_radios(usb, drivers)
        self.assertEqual((drivers / 'btusb/unbind').read_text(), interface.name)
        self.assertEqual((drivers / 'btusb/bind').read_text(), interface.name)
        self.assertEqual(list(wifi.iterdir()), [])

    def test_management_failure_does_not_reset_an_unknown_controller(self):
        usb, _, drivers = self.radio()
        with patch('ble_lab.hardware.wait_initialized', side_effect=OSError('permission denied')):
            with self.assertRaises(OSError):
                recover_radios(usb, drivers)
        self.assertEqual((drivers / 'btusb/unbind').read_text(), 'untouched')

    def test_hci_sysfs_presence_alone_does_not_prove_firmware_initialized(self):
        _, interface, _ = self.radio()
        hci = self.root / 'bluetooth/hci2'
        hci.mkdir(parents=True)
        (hci / 'device').symlink_to(interface)
        with patch('ble_lab.hardware.controller_indexes', return_value={0}):
            self.assertFalse(initialized(interface, hci.parent))
        with patch('ble_lab.hardware.controller_indexes', return_value={2}):
            self.assertTrue(initialized(interface, hci.parent))


if __name__ == '__main__':
    unittest.main()
