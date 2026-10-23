import contextlib
import hashlib
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]/'tool/native'))
import prepare_linux


class PrepareLinuxTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='napi-linux-prepare-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_rejects_cipd_checksum_before_installing_client(self):
        with patch.object(prepare_linux.urllib.request, 'urlopen', return_value=io.BytesIO(b'wrong')):
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                prepare_linux.cipd_client(self.root)
        self.assertFalse((self.root/'cipd').exists())
        payload = b'verified executable'
        with patch.object(prepare_linux, 'CIPD_SHA256', hashlib.sha256(payload).hexdigest()), \
                patch.object(prepare_linux.urllib.request, 'urlopen', return_value=io.BytesIO(payload)):
            client = prepare_linux.cipd_client(self.root)
            self.assertEqual(client.read_bytes(), payload)
            self.assertEqual(client.stat().st_mode & 0o777, 0o755)

    def test_sparse_checkout_reuses_pinned_sources_and_rejects_modifications(self):
        source = self.root/'origin'
        source.mkdir()
        (source/'kept').mkdir()
        (source/'kept/runtime.cc').write_text('runtime')
        (source/'unneeded').mkdir()
        (source/'unneeded/test.cc').write_text('test')
        def git(*args):
            return subprocess.run(['git', '-C', str(source), *args], check=True,
                                  text=True, capture_output=True).stdout.strip()
        git('init')
        git('add', '.')
        git('-c', 'user.name=Test', '-c', 'user.email=test@example.com', 'commit', '-m', 'source')
        revision = git('rev-parse', 'HEAD')
        target = self.root/'checkout'
        with contextlib.redirect_stdout(io.StringIO()):
            prepare_linux.checkout(target, str(source), revision, ['/kept/'])
            self.assertEqual((target/'kept/runtime.cc').read_text(), 'runtime')
            self.assertFalse((target/'unneeded').exists())
            # A completed cache is reusable without contacting the remote.
            prepare_linux.checkout(target, 'https://invalid.example/no-network', revision)
            (target/'kept/runtime.cc').write_text('local change')
            with self.assertRaises(subprocess.CalledProcessError):
                prepare_linux.checkout(target, str(source), revision)

    def test_existing_sdk_customization_is_preserved(self):
        runtime = self.root/'runtime/napi'
        runtime.mkdir(parents=True)
        custom = runtime/'runtime.cc'
        custom.write_text('local customization')
        with self.assertRaisesRegex(ValueError, 'existing SDK customization'):
            prepare_linux.copy_runtime(self.root)
        self.assertEqual(custom.read_text(), 'local customization')

    def test_prepares_gclient_configuration_before_gn(self):
        config = self.root/'sdk/build/config/gclient_args.gni'
        config.parent.mkdir(parents=True)
        generated = False

        def run(command, **kwargs):
            nonlocal generated
            if str(command[0]).endswith('/buildtools/gn'):
                self.assertEqual(config.read_text(), 'build_devtools_from_sources = false\n')
                generated = True

        with patch.object(prepare_linux.platform, 'system', return_value='Linux'), \
                patch.object(prepare_linux.platform, 'machine', return_value='x86_64'), \
                patch.object(prepare_linux, 'checkout'), \
                patch.object(prepare_linux, 'cipd_client', return_value=self.root/'cipd'), \
                patch.object(prepare_linux, 'copy_runtime'), \
                patch.object(prepare_linux, 'run', side_effect=run), \
                contextlib.redirect_stdout(io.StringIO()):
            prepare_linux.prepare(self.root, 2)
        self.assertTrue(generated)
