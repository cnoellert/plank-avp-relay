# SPDX-License-Identifier: GPL-3.0-or-later
"""Focused source preparation and package boundary checks; no root or services."""
import hashlib
import importlib.util
import json
from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('drawing_source', ROOT / 'scripts/prepare-drawing-source.py')
source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source)
wacom = runpy.run_path(str(ROOT / 'packaging/drawing/plank-drawing-permissions'))['wacom']


def git(repository, *args):
    return subprocess.check_output(['git', '-C', str(repository), *args], text=True).strip()


class DrawingPackageTests(unittest.TestCase):
    def test_exact_commit_ignores_working_files_and_refuses_bad_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            repository = scratch / 'repo'
            repository.mkdir()
            git(repository, 'init', '-q')
            (repository / 'source.c').write_text('committed\n')
            git(repository, 'add', 'source.c')
            git(repository, '-c', 'user.name=Package Test', '-c', 'user.email=test@example.invalid',
                'commit', '-qm', 'Source fixture')
            commit = git(repository, 'rev-parse', 'HEAD')
            archive = scratch / 'source.tar'
            git(repository, 'archive', commit, '-o', str(archive))
            pin = {'repository': str(repository), 'commit': commit,
                   'archive_sha256': hashlib.sha256(archive.read_bytes()).hexdigest()}
            manifest = scratch / 'pin.json'
            manifest.write_text(json.dumps(pin))
            (repository / 'source.c').write_text('dirty working file\n')
            (repository / 'private-untracked').write_text('untracked fixture\n')
            destination = scratch / 'prepared'
            source.prepare(manifest, destination, repository)
            self.assertEqual((destination / 'source.c').read_text(), 'committed\n')
            self.assertFalse((destination / 'private-untracked').exists())
            with self.assertRaisesRegex(ValueError, 'must not exist'):
                source.prepare(manifest, destination, repository)
            pin['archive_sha256'] = '0' * 64
            manifest.write_text(json.dumps(pin))
            with self.assertRaisesRegex(ValueError, 'hash mismatch'):
                source.prepare(manifest, scratch / 'invalid', repository)
            self.assertFalse((scratch / 'invalid').exists())

    def test_wacom_only_permissions(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            for vendor, expected in [('056a', True), ('1234', False)]:
                parent = scratch / vendor
                (parent / 'child').mkdir(parents=True)
                (parent / 'idVendor').write_text(vendor + '\n')
                self.assertEqual(wacom(parent / 'child'), expected)
            self.assertTrue(wacom(scratch / '0005:056A:0360.0001' / 'input'))
            self.assertFalse(wacom(scratch / '0005:1234:0360.0001' / 'input'))
            self.assertFalse(wacom(scratch / 'plain' / 'input'))

    def test_unmanaged_unit_binary_and_dangling_link_refused_before_unpack(self):
        with tempfile.TemporaryDirectory() as directory:
            scratch = Path(directory)
            script = (ROOT / 'debian/plank-avp-relay.preinst').read_text()
            paths = ['/etc/systemd/system/plank-tablet-relay.service',
                     '/run/systemd/system/plank-tablet-relay.service',
                     '/usr/local/libexec/plank-tablet-relay']
            for index, path in enumerate(paths):
                script = script.replace(path, str(scratch / f'owned-by-operator-{index}'))
            check = scratch / 'preinst'
            check.write_text(script)
            self.assertEqual(subprocess.run(['sh', str(check), 'install'], capture_output=True).returncode, 0)
            for index in range(len(paths)):
                existing = scratch / f'owned-by-operator-{index}'
                existing.write_text('operator fixture\n')
                result = subprocess.run(['sh', str(check), 'upgrade'], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('before changing files', result.stderr)
                self.assertEqual(existing.read_text(), 'operator fixture\n')
                existing.unlink()
            dangling = scratch / 'owned-by-operator-0'
            dangling.symlink_to(scratch / 'absent')
            self.assertNotEqual(subprocess.run(['sh', str(check), 'install'], capture_output=True).returncode, 0)
            self.assertTrue(dangling.is_symlink())


if __name__ == '__main__':
    unittest.main()
