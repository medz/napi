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

    def test_linux_archive_retains_libc_profile_and_so_payload(self):
        old_runtime = self.manifest['runtime']
        identity = self.manifest['identity'].replace('macos-arm64', 'linux-x64')
        runtime = 'libnapi_runtime_'+identity+'.so'
        (self.directory/old_runtime).rename(self.directory/runtime)
        self.manifest['files'][runtime] = self.manifest['files'].pop(old_runtime)
        self.manifest.update(platform='linux', architecture='x64', libc='glibc',
                             minimumLibcVersion='2.17', identity=identity, runtime=runtime)
        del self.manifest['minimumOsVersion']
        compiler = self.manifest['build']['provenance']['compiler']
        del compiler['macosSdkVersion']
        compiler.update(sysrootSha256='5'*64, clangPackageSha256='6'*64)
        self.manifest['build']['toolchainInputsSha256'] = '7'*64
        self.manifest['build']['provenance']['toolchainInputs'] = {
            'buildtools/linux-x64/clang/bin/ld.lld': '8'*64,
        }
        self.save()
        lock = bundle.pack(self.directory, self.archive, self.lock, self.dart,
                           repository=self.repository)
        self.assertEqual(lock['profile']['libc'], 'glibc')
        self.assertEqual(lock['profile']['minimumLibcVersion'], '2.17')
        self.assertNotIn('minimumOsVersion', lock['profile'])
        fetched = bundle.fetch(self.lock, self.cache, self.dart, self.archive, self.repository)
        self.assertTrue((fetched/runtime).is_file())
        self.assertFalse((fetched/old_runtime).exists())
        compiler.pop('sysrootSha256')
        with self.assertRaisesRegex(ValueError, 'toolchain provenance'):
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
        cases = [(profile, changed) for profile in ['macos-arm64', 'linux-x64']
                 for changed in [None, 'vm', 'recipe', 'header', 'source', 'compiler']]
        cases += [('linux-x64', 'sysroot'), ('linux-x64', 'clang-package')]
        cases += [('linux-x64', 'bridge-extra')]
        link_changes = ['linker', 'crt', 'static-library', 'linker-script', 'indirect-library']
        cases += [('linux-x64', name) for name in link_changes]
        cases += [('linux-x64', 'initial-'+name) for name in link_changes]
        cases += [('linux-x64', 'initial-'+name) for name in
                  ['link-flags', 'compile-flags', 'library-order']]
        cases += [('linux-x64', None)]  # The same inputs in another SDK directory.
        original_identity = None
        for profile, changed in cases:
            with self.subTest(profile=profile, changed=changed), tempfile.TemporaryDirectory() as tmp:
                linux = profile == 'linux-x64'
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
                clang = sdk/'buildtools/linux-x64/clang/bin/clang++' if linux else root/'clang'
                clang.parent.mkdir(parents=True, exist_ok=True)
                clang.write_text('compiler')
                packages = {
                    'sysroot': sdk/'buildtools/sysroot/linux/.versions/sysroot.cipd_version',
                    'clang-package': sdk/'buildtools/linux-x64/clang/.versions/clang.cipd_version',
                }
                for path in packages.values():
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('pinned package')
                link_inputs = {
                    'linker': sdk/'buildtools/linux-x64/clang/bin/ld.lld',
                    'crt': sdk/'buildtools/sysroot/linux/usr/lib/crti.o',
                    'static-library': sdk/'buildtools/linux-x64/clang/lib/libc++.a',
                    'linker-script': sdk/'buildtools/sysroot/linux/usr/lib/libc.so',
                    'indirect-library': sdk/'buildtools/sysroot/linux/lib/libc.so.6',
                }
                for path in link_inputs.values():
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('GROUP ( /lib/libc.so.6 )' if path.name == 'libc.so' else 'original link input')
                initial_change = changed is not None and changed.startswith('initial-')
                if initial_change and changed.removeprefix('initial-') in link_inputs:
                    link_inputs[changed.removeprefix('initial-')].write_text('updated before build')
                (cache/'args.gn').write_text('arguments')
                toolchain_name = 'clang_x64_shared' if linux else 'clang_arm64_shared'
                toolchain = cache/toolchain_name/'toolchain.ninja'
                toolchain.parent.mkdir()
                toolchain.write_text('toolchain')
                target, compile_target = cache/'link.ninja', cache/'compile.ninja'
                target.write_text(f'build runtime: {toolchain_name}_solink vm.o\n' + (
                    f'  ldflags = --sysroot={sdk}/buildtools/sysroot/linux -fPIC '
                    '--target=x86_64-linux-gnu -static-libgcc -static-libstdc++ '
                    '-Wl,-rpath=\\$$ORIGIN/ -Wl,--disable-new-dtags\n  libs = -ldl -lpthread\n'
                    if linux else ''))
                compile_target.write_text('defines = -DPRODUCT -DDART_PRECOMPILED_RUNTIME\n')
                if changed == 'initial-link-flags':
                    target.write_text(target.read_text().replace('-fPIC', '-fPIC -Wl,-Bsymbolic'))
                if changed == 'initial-compile-flags':
                    compile_target.write_text(compile_target.read_text()+'cflags = -fno-inline\n')
                if changed == 'initial-library-order':
                    target.write_text(target.read_text().replace('-ldl -lpthread', '-lpthread -ldl'))
                vm = cache/'vm.o'
                vm.write_text('original VM input')
                original_vm = build.vm_inputs(cache, ['vm.o'])
                commands = []

                def fake_run(command, cwd=None):
                    commands.append(command)
                    if command[0] == 'git':
                        return '1'*40 if 'rev-parse' in command else ''
                    if command[:2] == ['xcrun', '--find']:
                        return str(clang)
                    if command[:2] == ['xcrun', '--show-sdk-path']:
                        return str(root/'macos-sdk')
                    if command[:2] == ['xcrun', '--show-sdk-version']:
                        return '27.0'
                    if '--version' in command:
                        return 'test compiler\nInstalledDir: '+str(clang.parent)
                    if command[0] == 'codesign':
                        return ''
                    if '--file-header' in command:
                        return 'Class: ELF64\nMachine: Advanced Micro Devices X86-64'
                    if '--dynamic' in command:
                        binary = Path(command[-1])
                        runtime = next(binary.parent.glob('*.so')).name
                        return (f'(SONAME) Library soname: [{binary.name}]\n'
                                '(RUNPATH) Library runpath: [$ORIGIN]\n'
                                '(NEEDED) Shared library: [libc.so.6]\n' +
                                (f'(NEEDED) Shared library: [{runtime}]' if binary.suffix == '.node' else ''))
                    if '--version-info' in command:
                        return 'Name: GLIBC_2.2.5\nName: GLIBC_2.17'
                    output = Path(command[command.index('-o')+1])
                    if ('-shared' in command and output.name != 'link-probe.so' and changed and
                            not initial_change and changed != 'bridge-extra'):
                        {'vm': vm, 'recipe': target, 'header': header,
                         'source': repo/'native/runtime/runtime.cc',
                         'compiler': clang, **packages, **link_inputs}[changed].write_text('changed during build')
                    if '-MM' not in command:
                        output.write_bytes(b'test artifact')
                    if '-MF' in command:
                        Path(command[command.index('-MF')+1]).write_text(
                            f'{output}: {shlex.quote(str(header))}\n')
                    link_dep = next((arg.removeprefix('-Wl,--dependency-file=') for arg in command
                                     if arg.startswith('-Wl,--dependency-file=')), None)
                    if link_dep:
                        # A library loaded from an archive member is only read
                        # once the VM or bridge supplies the referring object.
                        inputs = [path for name, path in link_inputs.items() if name != 'indirect-library']
                        has_objects = False
                        for arg in command:
                            if arg.startswith('@'):
                                inputs += [Path(name) for name in shlex.split(Path(arg[1:]).read_text())]
                                has_objects = True
                        if has_objects:
                            inputs.append(link_inputs['indirect-library'])
                        if output.suffix == '.node':
                            inputs += [output.parent.parent/'bridge.o', next(output.parent.glob('*.so'))]
                            if changed == 'bridge-extra':
                                extra = sdk/'unrecorded-library.a'
                                extra.write_text('not present in runtime probe')
                                inputs.append(extra)
                        Path(link_dep).write_text(
                            str(output)+': '+ ' '.join(map(str, inputs))+'\n\n'+
                            '\n'.join(str(path)+':' for path in inputs)+'\n')
                    return ''

                output = root/'bundle'
                with patch.object(build, 'ROOT', repo), patch.object(build, 'run', fake_run), \
                     patch.object(build.platform, 'system', return_value='Linux' if linux else 'Darwin'), \
                     patch.object(build.platform, 'machine', return_value='x86_64' if linux else 'arm64'), \
                     patch.object(build, 'validate_cache', return_value=(target, compile_target)), \
                     patch.object(build, 'publish', side_effect=lambda a, b: a.rename(b)):
                    if changed and not initial_change:
                        with self.assertRaisesRegex(ValueError, 'changed during the build'):
                            build.build(sdk, node, output, cache)
                        self.assertFalse(output.exists())
                    else:
                        manifest = build.build(sdk, node, output, cache)
                        self.assertEqual(manifest['build']['vmInputsSha256'], original_vm)
                        self.assertEqual(manifest['build']['provenance']['headers'],
                                         {'sdk/actual.h': build.digest(header)})
                        self.assertIn(f'-product-{profile}-abi15-id', manifest['identity'])
                        if linux:
                            if initial_change:
                                self.assertNotEqual(manifest['identity'], original_identity)
                            elif original_identity is not None:
                                self.assertEqual(manifest['identity'], original_identity)
                            else:
                                original_identity = manifest['identity']
                            self.assertEqual(manifest['minimumLibcVersion'], '2.17')
                            self.assertEqual(manifest['libc'], 'glibc')
                            self.assertNotIn('minimumOsVersion', manifest)
                            self.assertEqual(manifest['build']['provenance']['compiler']['sysrootSha256'],
                                             build.digest(packages['sysroot']))
                            self.assertEqual(manifest['build']['provenance']['compiler']['version'], 'test compiler')
                            self.assertEqual(manifest['build']['provenance']['toolchainInputs'],
                                             {path.relative_to(sdk).as_posix(): build.digest(path)
                                              for path in [clang, *link_inputs.values()]})
                            links = [command for command in commands if '-shared' in command and '-MM' not in command]
                            self.assertEqual(len(links), 3)
                            for command in links:
                                self.assertIn('-static-libstdc++', command)
                                self.assertIn(f'--sysroot={sdk}/buildtools/sysroot/linux', command)
                                self.assertIn('-Wl,-rpath,$ORIGIN', command)
                                self.assertNotIn('-Wl,-rpath=$$ORIGIN/', command)
                                self.assertIn('--ld-path='+str(link_inputs['linker']), command)
                            self.assertIn('-Wl,-soname,'+manifest['runtime'], links[1])
                            self.assertIn('-Wl,-soname,bridge.node', links[2])
                            self.assertFalse(any(command[0] in ['xcrun', 'codesign'] for command in commands))

    def test_linux_cache_requires_pinned_target_and_sysroot(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sdk, cache = root/'sdk', root/'cache'
            (sdk/'tools').mkdir(parents=True)
            (sdk/'tools/VERSION').write_text('MAJOR 3\nMINOR 13\nPATCH 5\n')
            sysroot = sdk/'buildtools/sysroot/linux'
            sysroot.mkdir(parents=True)
            target = cache/'clang_x64_shared/obj/runtime/napi/napi_runtime.ninja'
            compile_target = target.with_name('napi_runtime_set.ninja')
            target.parent.mkdir(parents=True)
            toolchain = cache/'clang_x64_shared/toolchain.ninja'
            toolchain.write_text('command = ../../buildtools/linux-x64/clang/bin/clang++')
            args = {'target_os': '"linux"', 'host_cpu': '"x64"', 'target_cpu': '"x64"',
                    'dart_target_arch': '"x64"', 'dart_sysroot': '"debian"', 'is_product': 'true',
                    **{key: 'false' for key in ['is_release', 'is_debug', 'dart_debug',
                        'dart_use_compressed_pointers', 'dart_dynamic_modules', 'is_asan',
                        'is_lsan', 'is_msan', 'is_tsan', 'is_ubsan', 'is_hwasan']}}
            flags = f'--sysroot={sysroot} --target=x86_64-linux-gnu -fPIC'
            for changed in [None, 'host', 'args-sysroot', 'compile-sysroot', 'link-sysroot', 'pic', 'compiler', 'libcxx']:
                with self.subTest(changed=changed):
                    current = dict(args)
                    if changed == 'host':
                        current['host_cpu'] = '"arm64"'
                    if changed == 'args-sysroot':
                        current['dart_sysroot'] = '"alpine"'
                    if changed == 'libcxx':
                        current['use_custom_libcxx'] = 'true'
                    (cache/'args.gn').write_text('\n'.join(f'{key} = {value}' for key, value in current.items()))
                    compile_target.write_text('cflags = ' + (flags.replace(str(sysroot), '/host')
                                              if changed == 'compile-sysroot' else flags))
                    target.write_text('  ldflags = ' + (flags.replace(str(sysroot), '/host')
                                      if changed == 'link-sysroot' else flags.replace('-fPIC', '')
                                      if changed == 'pic' else flags))
                    toolchain.write_text('command = ' + ('/usr/bin/clang++' if changed == 'compiler' else
                                         '../../buildtools/linux-x64/clang/bin/clang++'))
                    with patch.object(build.platform, 'system', return_value='Linux'), \
                         patch.object(build.platform, 'machine', return_value='x86_64'), \
                         patch.object(build, 'run', return_value=build.SDK_REVISION):
                        if changed:
                            with self.assertRaises(ValueError):
                                build.validate_cache(sdk, cache)
                        else:
                            self.assertEqual(build.validate_cache(sdk, cache), (target, compile_target))

    def test_elf_rejects_newer_libc_and_nonportable_dependencies(self):
        dynamic = ('(SONAME) Library soname: [bridge.node]\n'
                   '(RUNPATH) Library runpath: [$ORIGIN]\n'
                   '(NEEDED) Shared library: [runtime.so]\n'
                   '(NEEDED) Shared library: [libc.so.6]\n')
        for changed in [None, 'glibc', 'private-glibc', 'absolute-path', 'libstdc++', 'runpath', 'machine']:
            with self.subTest(changed=changed):
                def readelf(command, cwd=None):
                    if '--file-header' in command:
                        return 'Class: ELF64\nMachine: ' + ('AArch64' if changed == 'machine' else 'AMD x86-64')
                    if '--version-info' in command:
                        return 'Name: GLIBC_' + ('2.28' if changed == 'glibc' else
                                                'PRIVATE' if changed == 'private-glibc' else '2.17')
                    if '--dyn-syms' in command:
                        return '1: 0 0 FUNC GLOBAL DEFAULT UND getrandom@GLIBC_2.28 (2)'
                    value = dynamic
                    if changed == 'absolute-path':
                        value += '(NEEDED) Shared library: [/build/libhelper.so]'
                    if changed == 'libstdc++':
                        value += '(NEEDED) Shared library: [libstdc++.so.6]'
                    if changed == 'runpath':
                        value = value.replace('$ORIGIN', '/build')
                    return value

                with patch.object(build, 'run', readelf):
                    if changed:
                        with self.assertRaisesRegex(ValueError, 'getrandom@GLIBC_2.28' if changed == 'glibc' else '.'):
                            build.validate_elf('readelf', Path('bridge.node'), 'runtime.so')
                    else:
                        build.validate_elf('readelf', Path('bridge.node'), 'runtime.so')

    def test_atomic_publish_preserves_existing_destination(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, target = root/'source', root/'target'
            source.mkdir()
            (source/'payload').write_text('new bundle')
            for symlink in [False, True]:
                with self.subTest(symlink=symlink):
                    if symlink:
                        target.symlink_to(root/'missing')
                    else:
                        target.mkdir()
                    with self.assertRaises(FileExistsError):
                        build.publish(source, target)
                    self.assertEqual((source/'payload').read_text(), 'new bundle')
                    if symlink:
                        self.assertEqual(target.readlink(), root/'missing')
                        target.unlink()
                    else:
                        self.assertEqual(list(target.iterdir()), [])
                        target.rmdir()
            build.publish(source, target)
            self.assertFalse(source.exists())
            self.assertEqual((target/'payload').read_text(), 'new bundle')


if __name__ == '__main__':
    unittest.main()
