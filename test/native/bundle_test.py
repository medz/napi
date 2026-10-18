import copy
import io
import json
import os
from pathlib import Path
import shlex
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import urllib.request
import warnings
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parents[2]/'tool/native'))
import bundle
import build


class BundleTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='napi distribution 雪 ')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repository = self.root/'repository'
        for name in bundle.SOURCE_FILES:
            file = self.repository/name
            file.parent.mkdir(parents=True, exist_ok=True)
            file.write_text('source '+name)
        self.directory = self.root/'bundle'
        self.directory.mkdir()
        identity = 'dart-3.13.5-product-macos-arm64-abi15-test'
        runtime = 'libnapi_runtime_'+identity+'.dylib'
        files = {}
        for name in ['bridge.node', runtime, 'DART_LICENSE', 'DART_AUTHORS', 'NAPI_LICENSE']:
            file = self.directory/name
            file.write_text('test '+name)
            files[name] = bundle.digest(file)
        self.manifest = {
            'format': 1, 'sdkVersion': '3.13.5',
            'sdkRevision': '04bcd1036cdc799ac6564988f159ee454d42c822',
            'platform': 'macos', 'architecture': 'arm64', 'minimumOsVersion': '14.0',
            'abi': 15, 'identity': identity, 'bridge': 'bridge.node', 'runtime': runtime,
            'files': files, 'build': {'provenance': {
                'format': 1, 'producer': {'commit': '1'*40, 'dirty': True,
                    'files': {name: bundle.digest(self.repository/name) for name in bundle.SOURCE_FILES}},
                'compiler': {'version': 'test compiler', 'sha256': '2'*64, 'macosSdkVersion': '27.0'},
                'headers': {'node/node_api.h': '3'*64}, 'cacheRecipe': {'args.gn': '4'*64},
            }},
        }
        self.save()
        self.archive = self.root/'bundle.zip'
        self.lock = self.root/'bundle.lock.json'
        self.cache = self.root/'cache'
        self.dart = os.environ.get('NAPI_DART', 'dart')

    def save(self):
        (self.directory/'manifest.json').write_text(json.dumps(self.manifest)+'\n')

    def fake_verify(self, directory, repository, dart):
        manifest = bundle.json_file(directory/'manifest.json')
        bundle.provenance(manifest, repository)
        for name, expected in manifest['files'].items():
            if bundle.digest(bundle.regular(directory/name)) != expected:
                raise ValueError('Payload integrity mismatch')
        return manifest

    def prepare(self):
        with patch.object(bundle, 'verify', side_effect=self.fake_verify):
            return bundle.pack(self.directory, self.archive, self.lock,
                               self.dart, repository=self.repository)

    def fetch(self):
        with patch.object(bundle, 'verify', side_effect=self.fake_verify):
            return bundle.fetch(self.lock, self.cache, self.dart, self.archive, self.repository)

    def test_real_validator_pack_cold_and_warm_cache(self):
        # This is the real Dart bundle verifier; fixture payloads are hashed,
        # never dlopened. Neither SDK sources nor C compilation are needed.
        bundle.pack(self.directory, self.archive, self.lock, self.dart, repository=self.repository)
        first = bundle.fetch(self.lock, self.cache, self.dart, self.archive, self.repository)
        self.archive.unlink()
        second = bundle.fetch(self.lock, self.cache, self.dart, repository=self.repository)
        self.assertEqual(first, second)
        self.assertEqual(set(p.name for p in first.iterdir()), {'manifest.json', *self.manifest['files']})
        self.manifest['abi'] = 14
        self.save()
        with self.assertRaisesRegex(ValueError, 'validation failed'):
            bundle.verify(self.directory, self.repository, self.dart)

    def test_old_and_modified_source_provenance_rejected(self):
        old = copy.deepcopy(self.manifest)
        old['build'].pop('provenance')
        with self.assertRaisesRegex(ValueError, 'provenance'):
            bundle.provenance(old, self.repository)
        (self.repository/'native/bridge/bridge.cc').write_text('changed bridge, same ABI')
        with self.assertRaisesRegex(ValueError, 'bridge.cc'):
            bundle.provenance(self.manifest, self.repository)

    def test_local_reads_are_bounded_before_allocating_payloads(self):
        source = io.BytesIO(b'x'*100)
        with patch.object(Path, 'open', return_value=source), patch.object(source, 'read', wraps=source.read) as read:
            with self.assertRaisesRegex(ValueError, 'too large'):
                bundle.bounded_bytes(self.directory/'bridge.node', 8, 'too large')
            # A bounded reader consumes at most the limit plus one byte.
            read.assert_called_once_with(9)

    def test_cached_payload_and_source_rechecked(self):
        self.prepare()
        output = self.fetch()
        (output/'bridge.node').write_text('corrupt cache')
        with self.assertRaisesRegex(ValueError, 'integrity'):
            self.fetch()
        self.assertEqual((output/'bridge.node').read_text(), 'corrupt cache')

    def test_cache_hit_rejects_changed_builder_source(self):
        self.prepare()
        output = self.fetch()
        (self.repository/'tool/native/build.py').write_text('different build inputs')
        with self.assertRaisesRegex(ValueError, 'build.py'):
            self.fetch()
        self.assertTrue((output/'manifest.json').is_file())

    def test_manifest_replacement_during_verification_is_rejected(self):
        def race(*args, **kwargs):
            self.manifest['build']['provenance']['compiler']['version'] = 'changed'
            self.save()
            return bundle.subprocess.CompletedProcess(args, 0, '', '')

        with patch.object(bundle.subprocess, 'run', side_effect=race):
            with self.assertRaisesRegex(ValueError, 'changed during validation'):
                bundle.verify(self.directory, self.repository, self.dart)

    def test_locked_manifest_is_checked_after_verification(self):
        lock = self.prepare()

        def race(directory, repository, dart):
            (directory/'bridge.node').write_text('different valid payload')
            self.manifest['files']['bridge.node'] = bundle.digest(directory/'bridge.node')
            self.save()
            return self.fake_verify(directory, repository, dart)

        with patch.object(bundle, 'verify', side_effect=race):
            with self.assertRaisesRegex(ValueError, 'reviewed lock'):
                bundle.check_locked(self.directory, lock, self.repository, self.dart)

    def test_pack_binds_the_verified_manifest_snapshot(self):
        def race(directory, repository, dart):
            verified = self.fake_verify(directory, repository, dart)
            self.manifest['build']['provenance']['compiler']['version'] = 'changed'
            self.save()
            return verified

        with patch.object(bundle, 'verify', side_effect=race):
            with self.assertRaisesRegex(ValueError, 'changed while preparing'):
                bundle.pack(self.directory, self.archive, self.lock,
                            self.dart, repository=self.repository)
        self.assertFalse(self.archive.exists())
        self.assertFalse(self.lock.exists())

    def test_missing_remote_is_not_a_skip_or_build(self):
        self.prepare()
        with self.assertRaisesRegex(ValueError, 'no published source'):
            bundle.fetch(self.lock, self.cache, self.dart, repository=self.repository)
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_remote_bytes_are_verified_before_unpacking(self):
        lock = self.prepare()
        lock['archive']['url'] = 'https://github.com/medz/napi/releases/download/v1/runtime.zip'
        data = self.archive.read_bytes()
        with patch.object(bundle.urllib.request, 'build_opener') as create:
            create.return_value.open.return_value = io.BytesIO(data)
            bundle.acquire(lock, self.root/'download.zip')
            create.return_value.open.assert_called_once_with(lock['archive']['url'], timeout=30)
        self.assertEqual((self.root/'download.zip').read_bytes(), data)
        request = urllib.request.Request(lock['archive']['url'])
        for url in ['http://release-assets.githubusercontent.com/file',
                    'https://example.com/file', 'https://user:password@github.com/file']:
            with self.assertRaisesRegex(ValueError, 'redirect'):
                bundle.Redirects().redirect_request(request, None, 302, '', {}, url)

    def test_download_is_size_and_digest_bounded(self):
        lock = self.prepare()
        self.archive.write_bytes(self.archive.read_bytes()+b'extra')
        with self.assertRaisesRegex(ValueError, 'locked size'):
            self.fetch()
        self.assertEqual(list(self.cache.iterdir()), [])
        self.archive.write_bytes(b'x'*lock['archive']['bytes'])
        with self.assertRaisesRegex(ValueError, 'integrity mismatch'):
            self.fetch()

    def test_pack_size_limits_fail_before_publication(self):
        with patch.object(bundle, 'MAX_BYTES', 1):
            with self.assertRaisesRegex(ValueError, 'Expanded native archive'):
                self.prepare()
        self.assertFalse(self.archive.exists())
        self.assertFalse(self.lock.exists())
        # Force only the archive-size branch without allocating a huge payload.
        original = zipfile.ZipFile.close

        def inflate(zipped):
            filename = zipped.filename
            writable = zipped.mode == 'x' and zipped.fp is not None
            original(zipped)
            if writable:
                with Path(filename).open('ab') as output:
                    output.write(b'x'*10_000)

        with patch.object(bundle, 'MAX_BYTES', 10_000), patch.object(zipfile.ZipFile, 'close', inflate):
            with self.assertRaisesRegex(ValueError, '^Native archive'):
                self.prepare()
        self.assertFalse(self.archive.exists())
        self.assertFalse(self.lock.exists())

    def test_zip_entries_are_flat_unique_regular_and_bounded(self):
        lock = self.prepare()
        original = {name: (self.directory/name).read_bytes() for name in ['manifest.json', *self.manifest['files']]}
        attacks = ['../escape', '/absolute', 'extra', 'duplicate', 'symlink', 'oversize']
        for attack in attacks:
            archive = self.root/(attack.replace('/', '_')+'.zip')
            with zipfile.ZipFile(archive, 'w') as zipped:
                for name, data in original.items():
                    entry = zipfile.ZipInfo(name)
                    entry.external_attr = (stat.S_IFREG | 0o644) << 16
                    if name == 'bridge.node' and attack == 'symlink':
                        entry.external_attr = (stat.S_IFLNK | 0o777) << 16
                    zipped.writestr(entry, data)
                if attack in ['../escape', '/absolute', 'extra']:
                    zipped.writestr(attack, b'bad')
                elif attack == 'duplicate':
                    with warnings.catch_warnings():
                        warnings.simplefilter('ignore', UserWarning)
                        zipped.writestr('bridge.node', b'duplicate')
            destination = self.root/('expanded-'+attack.replace('/', '_'))
            maximum = 1 if attack == 'oversize' else bundle.MAX_BYTES
            with patch.object(bundle, 'MAX_BYTES', maximum), self.assertRaises(ValueError):
                bundle.unpack(archive, destination, lock)
            self.assertFalse(destination.exists())

    def test_lock_profile_path_and_manifest_mismatch(self):
        lock = self.prepare()
        lock['profile']['identity'] = '../../escape'
        self.lock.write_text(json.dumps(lock))
        with self.assertRaisesRegex(ValueError, 'Invalid native bundle lock'):
            self.fetch()
        lock['profile']['identity'] = self.manifest['identity']
        lock['profile']['abi'] = 14
        self.lock.write_text(json.dumps(lock))
        with self.assertRaisesRegex(ValueError, 'profile differs'):
            self.fetch()
        lock['profile']['abi'] = 15
        lock['manifestSha256'] = '0'*64
        self.lock.write_text(json.dumps(lock))
        with self.assertRaisesRegex(ValueError, 'reviewed lock'):
            self.fetch()
        self.assertEqual(list(self.cache.iterdir()), [])

    def test_existing_archive_lock_and_symlink_cache_are_preserved(self):
        self.prepare()
        before = self.archive.read_bytes()
        with self.assertRaises(FileExistsError):
            bundle.pack(self.directory, self.archive, self.lock, self.dart, repository=self.repository)
        self.assertEqual(self.archive.read_bytes(), before)
        target = self.root/'untouched'
        target.mkdir()
        self.cache.symlink_to(target, target_is_directory=True)
        with self.assertRaisesRegex(ValueError, 'Symlinks'):
            self.fetch()
        self.assertEqual(list(target.iterdir()), [])
        with self.assertRaisesRegex(ValueError, 'Symlinks'):
            bundle.pack(self.directory, self.cache/'new.zip', self.root/'new.lock',
                        self.dart, repository=self.repository)
        self.assertEqual(list(target.iterdir()), [])

    def test_racing_empty_cache_directory_is_not_replaced(self):
        lock = self.prepare()
        destination = self.cache/lock['archive']['sha256']
        original = bundle.publish

        def race(source, target, dart):
            target.mkdir()
            original(source, target, dart)

        with patch.object(bundle, 'publish', side_effect=race), self.assertRaises(ValueError):
            self.fetch()
        self.assertTrue(destination.is_dir())
        self.assertEqual(list(destination.iterdir()), [])

    def test_failed_lock_publication_preserves_replaced_archive(self):
        original = Path.open

        def race(path, mode='r', *args, **kwargs):
            if path == self.lock and mode == 'x':
                replacement = self.root/'other.zip'
                replacement.write_text('other writer archive')
                replacement.replace(self.archive)
                self.lock.write_text('other writer lock')
                raise FileExistsError(self.lock)
            return original(path, mode, *args, **kwargs)

        with patch.object(Path, 'open', race), self.assertRaisesRegex(ValueError, 'preserved'):
            self.prepare()
        self.assertEqual(self.archive.read_text(), 'other writer archive')
        self.assertEqual(self.lock.read_text(), 'other writer lock')

    def test_source_urls_are_exact_release_assets(self):
        bundle.check_url('https://github.com/medz/napi/releases/download/v1.0.0/runtime.zip')
        for url in ['http://github.com/medz/napi/releases/download/v1/runtime.zip',
                    'https://example.com/runtime.zip',
                    'https://github.com/medz/napi/releases/latest/download/runtime.zip',
                    'https://github.com/medz/napi/releases/download/latest/runtime.zip',
                    'https://github.com/medz/napi/releases/download/v1/runtime.zip?token=x',
                    'file:///tmp/runtime.zip']:
            with self.assertRaises(ValueError, msg=url):
                bundle.check_url(url)


class BuildInputsTest(unittest.TestCase):
    def test_prepared_inputs_cannot_change_during_build(self):
        # Commands are intercepted: this exercises publication decisions without
        # compiling C/C++, downloading an SDK or loading any fixture payload.
        for changed in [None, 'vm', 'recipe', 'header', 'source', 'compiler']:
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                repo, cache, sdk, node = [root/name for name in ['repo', 'cache', 'sdk', 'node']]
                for path in [repo, cache, sdk, node]:
                    path.mkdir()
                for name in build.SOURCE_FILES:
                    file = repo/name
                    file.parent.mkdir(parents=True, exist_ok=True)
                    file.write_text('source '+name)
                for name in ['node_api.h', 'uv.h']:
                    (node/name).write_text('header')
                header = sdk/'actual.h'
                header.write_text('header')
                clang = root/'clang'
                clang.write_text('compiler')
                (cache/'args.gn').write_text('arguments')
                toolchain = cache/'clang_arm64_shared/toolchain.ninja'
                toolchain.parent.mkdir()
                toolchain.write_text('toolchain')
                target, compile_target = cache/'link.ninja', cache/'compile.ninja'
                target.write_text('build runtime.dylib: clang_arm64_shared_solink vm.o\n')
                compile_target.write_text('defines = -DPRODUCT -DDART_PRECOMPILED_RUNTIME\n')
                vm = cache/'vm.o'
                vm.write_text('original VM input')
                original_vm = build.vm_inputs(cache, ['vm.o'])

                def fake_run(command, cwd=None):
                    if command[0] == 'git':
                        return '1'*40 if 'rev-parse' in command else ''
                    if command[:2] == ['xcrun', '--find']:
                        return str(clang)
                    if command[:2] == ['xcrun', '--show-sdk-path']:
                        return str(root/'macos-sdk')
                    if command[:2] == ['xcrun', '--show-sdk-version']:
                        return '27.0'
                    if '--version' in command:
                        return 'test compiler'
                    if command[0] == 'codesign':
                        return ''
                    output = Path(command[command.index('-o')+1])
                    if '-shared' in command and changed:
                        {'vm': vm, 'recipe': target, 'header': header,
                         'source': repo/'native/runtime/runtime.cc',
                         'compiler': clang}[changed].write_text('changed during build')
                    if '-MM' not in command:
                        output.write_bytes(b'test artifact')
                    if '-MF' in command:
                        Path(command[command.index('-MF')+1]).write_text(
                            f'{output}: {shlex.quote(str(header))}\n')
                    return ''

                output = root/'bundle'
                with patch.object(build, 'ROOT', repo), patch.object(build, 'run', fake_run), \
                     patch.object(build.platform, 'system', return_value='Darwin'), \
                     patch.object(build.platform, 'machine', return_value='arm64'), \
                     patch.object(build, 'validate_cache', return_value=(target, compile_target)), \
                     patch.object(build, 'publish', side_effect=lambda a, b: a.rename(b)):
                    if changed:
                        with self.assertRaisesRegex(ValueError, 'changed during the build'):
                            build.build(sdk, node, output, cache)
                        self.assertFalse(output.exists())
                    else:
                        manifest = build.build(sdk, node, output, cache)
                        self.assertEqual(manifest['build']['vmInputsSha256'], original_vm)
                        self.assertEqual(manifest['build']['provenance']['headers'],
                                         {'sdk/actual.h': build.digest(header)})


if __name__ == '__main__':
    unittest.main()
