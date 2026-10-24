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
import prepare_runtime as prepare


class PrepareRuntimeTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='napi-runtime-prepare-')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def test_rejects_cipd_checksum_before_installing_client(self):
        with patch.object(prepare.urllib.request, 'urlopen', return_value=io.BytesIO(b'wrong')):
            with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
                prepare.cipd_client(self.root, 'mac-amd64')
        self.assertFalse((self.root/'cipd').exists())
        payload = b'verified executable'
        with patch.dict(prepare.CIPD_SHA256, {'mac-amd64': hashlib.sha256(payload).hexdigest()}), \
                patch.object(prepare.urllib.request, 'urlopen', return_value=io.BytesIO(payload)):
            client = prepare.cipd_client(self.root, 'mac-amd64')
            self.assertEqual(client.read_bytes(), payload)
            self.assertEqual(client.stat().st_mode & 0o777, 0o755)
        with self.assertRaisesRegex(ValueError, 'checksum mismatch'):
            prepare.cipd_client(self.root, 'mac-arm64')

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
            prepare.checkout(target, str(source), revision, ['/kept/'])
            self.assertEqual((target/'kept/runtime.cc').read_text(), 'runtime')
            self.assertFalse((target/'unneeded').exists())
            # A completed cache is reusable without contacting the remote.
            prepare.checkout(target, 'https://invalid.example/no-network', revision)
            (target/'kept/runtime.cc').write_text('local change')
            with self.assertRaises(subprocess.CalledProcessError):
                prepare.checkout(target, str(source), revision)

    def test_existing_sdk_customization_is_preserved(self):
        runtime = self.root/'runtime/napi'
        runtime.mkdir(parents=True)
        custom = runtime/'runtime.cc'
        custom.write_text('local customization')
        with self.assertRaisesRegex(ValueError, 'existing SDK customization'):
            prepare.copy_runtime(self.root)
        self.assertEqual(custom.read_text(), 'local customization')

    def test_existing_linux_cache_can_be_reused(self):
        runtime = self.root/'runtime/napi'
        runtime.mkdir(parents=True)
        (runtime/'.napi-linux-cache').write_text('napi-linux-cache\n')
        prepare.copy_runtime(self.root)
        self.assertEqual((runtime/'runtime.cc').read_bytes(),
                         (prepare.ROOT/'native/runtime/runtime.cc').read_bytes())

    def test_prepares_matching_tools_and_vm_for_each_host(self):
        config = self.root/'sdk/build/config/gclient_args.gni'
        config.parent.mkdir(parents=True)
        for profile, cpu, target, cipd, cache in [
            ('linux-x64', 'x64', 'linux', 'linux-amd64', 'out/ProductX64'),
            ('macos-x64', 'x64', 'mac', 'mac-amd64', 'xcodebuild/ProductX64'),
            ('macos-arm64', 'arm64', 'mac', 'mac-arm64', 'xcodebuild/ProductARM64'),
        ]:
            with self.subTest(profile=profile):
                commands = []
                def run(command, **kwargs):
                    commands.append(command)
                    if str(command[0]).endswith('/buildtools/gn'):
                        self.assertEqual(config.read_text(), 'build_devtools_from_sources = false\n')
                with patch.object(prepare, 'host_profile', return_value=profile), \
                        patch.object(prepare, 'checkout'), \
                        patch.object(prepare, 'cipd_client', return_value=self.root/'cipd') as client, \
                        patch.object(prepare, 'copy_runtime'), \
                        patch.object(prepare, 'run', side_effect=run), \
                        contextlib.redirect_stdout(io.StringIO()):
                    prepare.prepare(self.root, 2)
                client.assert_called_once_with(self.root, cipd)
                ensure = (self.root/'tools.ensure').read_text()
                self.assertIn(f'fuchsia/third_party/clang/{cipd}', ensure)
                self.assertIn(f'@Subdir buildtools/{target}-{cpu}/clang', ensure)
                self.assertEqual('sysroot' in ensure, target == 'linux')
                gn = next(command for command in commands if command[1] == 'gen')
                self.assertEqual(gn[2], self.root/'sdk'/cache)
                for key in ['host_cpu', 'target_cpu', 'dart_target_arch']:
                    self.assertIn(f'{key}="{cpu}"', gn[-1])
                self.assertIn(f'target_os="{target}"', gn[-1])
                self.assertIn('dart_sysroot="debian"' if target == 'linux' else 'mac_sdk_min="14.0"', gn[-1])
                self.assertEqual(commands[-1][-1], f'clang_{cpu}_shared/phony/runtime/napi/napi_runtime_set')

    def test_cache_key_separates_architecture_and_xcode_sdk(self):
        keys = set()
        for profile, sdk in [('linux-x64', 'linux'), ('macos-arm64', '26A'),
                             ('macos-x64', '26A'), ('macos-x64', '26B')]:
            with patch.object(prepare, 'host_profile', return_value=profile), \
                    patch.object(prepare.subprocess, 'check_output', return_value=sdk.encode()):
                keys.add(prepare.cache_key())
        self.assertEqual(len(keys), 4)
