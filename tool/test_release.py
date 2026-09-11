import hashlib
import io
import os
import pathlib
import shutil
import subprocess
import tarfile
import tempfile
import unittest

from release import app_version, linux_installer


class ReleaseTests(unittest.TestCase):
    def test_version_requires_build(self):
        self.assertEqual(app_version('name: sylphy\nversion: 1.10.0+12\n'), ('1.10.0', 12))
        for version in ['1.0', '1.0.0', '1.0.0+0', '1.0.0+2100000001']:
            with self.assertRaises(ValueError):
                app_version('version: ' + version)

    def test_payload_digest_and_executable_permissions(self):
        with tempfile.TemporaryDirectory() as folder:
            root = pathlib.Path(folder)
            bundle = root / 'bundle'
            (bundle / 'lib').mkdir(parents=True)
            (bundle / 'sylphy').write_bytes(b'fake binary')
            (bundle / 'lib/libsylphy_core.so').write_bytes(b'fake core')
            output = root / 'update.run'
            linux_installer(bundle, output, '1.2.0', 3)
            header, payload = output.read_bytes().split(b'\n__SYLPHY_PAYLOAD__\n', 1)
            self.assertIn(hashlib.sha256(payload).hexdigest().encode(), header)
            self.assertNotIn(b'@VERSION@', header)
            with tarfile.open(fileobj=io.BytesIO(payload), mode='r:gz') as archive:
                self.assertEqual(archive.getmember('sylphy').mode, 0o755)
                self.assertEqual(archive.extractfile('lib/libsylphy_core.so').read(), b'fake core')

    @unittest.skipUnless(os.name == 'posix' and pathlib.Path('/bin/true').is_file(), 'Linux installer integration')
    def test_linux_update_preserves_data_and_rejects_corruption(self):
        with tempfile.TemporaryDirectory(prefix='sylphy release ') as folder:
            root = pathlib.Path(folder)
            bundle = root / 'bundle'
            (bundle / 'lib').mkdir(parents=True)
            shutil.copyfile('/bin/true', bundle / 'sylphy')
            (bundle / 'lib/libsylphy_core.so').write_bytes(b'test')
            user_home = root / 'user home'
            user_home.mkdir()
            data = user_home / '.local/share/sylphy/account.vault'
            data.parent.mkdir(parents=True)
            data.write_bytes(b'keep private data')
            environment = dict(os.environ, HOME=str(user_home))
            first = root / 'first.run'
            linux_installer(bundle, first, '1.2.0', 3)
            subprocess.run(['/bin/sh', str(first), '--install-only'], env=environment, check=True)
            current = user_home / '.local/opt/sylphy/current'
            previous = current.resolve()
            second = root / 'second.run'
            linux_installer(bundle, second, '1.3.0', 4)
            valid = second.read_bytes()
            second.write_bytes(valid[:-1] + bytes([valid[-1] ^ 1]))
            failed = subprocess.run(['/bin/sh', str(second), '--install-only'], env=environment)
            self.assertNotEqual(failed.returncode, 0)
            self.assertEqual(current.resolve(), previous)
            second.write_bytes(valid)
            subprocess.run(['/bin/sh', str(second), '--install-only'], env=environment, check=True)
            self.assertNotEqual(current.resolve(), previous)
            self.assertTrue((previous / 'sylphy').is_file())
            self.assertEqual(data.read_bytes(), b'keep private data')
            self.assertTrue((user_home / '.local/bin/sylphy').resolve().is_file())


if __name__ == '__main__':
    unittest.main()
