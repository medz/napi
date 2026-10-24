import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2]/'tool/native'))
import build


class WindowsBuildTest(unittest.TestCase):
    def test_ninja_arguments_preserve_windows_paths_and_defines(self):
        arguments = [r'/IC:\SDK\include', r'/IC:\Program Files\Windows Kits\include',
                     '/DVALUE="quoted text"', r'/LIBPATH:D:\libs', '', 'trailing\\']
        self.assertEqual(build.windows_arguments(subprocess.list2cmdline(arguments)), arguments)
        self.assertEqual(build.windows_arguments('C$:/SDK/include $$literal'), ['C:/SDK/include', '$literal'])
        with self.assertRaisesRegex(ValueError, 'Unterminated'):
            build.windows_arguments('/I"missing quote')

    def test_cache_requires_x64_clang_and_static_crt(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sdk, cache = root/'sdk', root/'cache'
            (sdk/'tools').mkdir(parents=True)
            (sdk/'tools/VERSION').write_text('MAJOR 3\nMINOR 13\nPATCH 5\n')
            target = cache/'clang_x64_shared/obj/runtime/napi/napi_runtime.ninja'
            compile_target = target.with_name('napi_runtime_set.ninja')
            target.parent.mkdir(parents=True)
            target.touch()
            (cache/'environment.x64').write_text('LIB=libs\0\0')
            toolchain = cache/'clang_x64_shared/toolchain.ninja'
            recipe = ('../../buildtools/win-x64/clang/bin/clang-cl.exe '
                      '--target=x86_64-pc-windows-msvc\n'
                      '../../buildtools/win-x64/clang/bin/lld-link.exe')
            args = {'target_os': '"win"', 'host_cpu': '"x64"', 'target_cpu': '"x64"',
                    'dart_target_arch': '"x64"', 'is_product': 'true',
                    **{key: 'false' for key in ['is_release', 'is_debug', 'dart_debug',
                        'dart_use_compressed_pointers', 'dart_dynamic_modules', 'is_asan',
                        'is_lsan', 'is_msan', 'is_tsan', 'is_ubsan', 'is_hwasan']}}
            (cache/'args.gn').write_text('\n'.join(f'{key} = {value}' for key, value in args.items()))
            for changed in [None, 'target', 'compiler', 'linker', 'CRT']:
                with self.subTest(changed=changed):
                    current = recipe
                    if changed == 'target':
                        current = current.replace('x86_64-pc', 'aarch64-pc')
                    elif changed in ['compiler', 'linker']:
                        current = current.replace('clang-cl.exe' if changed == 'compiler' else 'lld-link.exe', 'cl.exe')
                    toolchain.write_text(current)
                    compile_target.write_text('cflags = '+('/MD' if changed == 'CRT' else '/MT')+'\n')
                    with patch.object(build, 'host_profile', return_value='windows-x64'), \
                            patch.object(build, 'run', return_value=build.SDK_REVISION):
                        if changed:
                            with self.assertRaises(ValueError):
                                build.validate_cache(sdk, cache)
                        else:
                            self.assertEqual(build.validate_cache(sdk, cache), (target, compile_target))

    def test_pe_rejects_wrong_machine_unbundled_crt_and_wrong_runtime(self):
        header = 'Machine: IMAGE_FILE_MACHINE_AMD64\nMagic: 0x20B\nIMAGE_FILE_DLL\n'
        dependencies = ['KERNEL32.dll', 'node.exe', 'runtime.dll', 'DBGHELP.dll',
                        'OLEAUT32.dll', 'api-ms-win-core-path-l1-1-0.dll']
        for changed in [None, 'machine', 'crt', 'runtime']:
            with self.subTest(changed=changed):
                image = header.replace('AMD64', 'ARM64') if changed == 'machine' else header
                imports = dependencies + ['VCRUNTIME140.dll'] if changed == 'crt' else dependencies
                if changed == 'runtime':
                    imports = ['KERNEL32.dll', 'node.exe', 'other.dll']
                image += ''.join('Import {\n  Name: '+name+'\n}\n' for name in imports)
                with patch.object(build, 'run', return_value=image):
                    if changed:
                        with self.assertRaises(ValueError):
                            build.validate_pe('readobj', Path('bridge.node'), 'runtime.dll')
                    else:
                        build.validate_pe('readobj', Path('bridge.node'), 'runtime.dll')

    def test_build_tracks_headers_libraries_and_cache_before_publication(self):
        for changed in [None, 'header', 'library', 'node', 'vm', 'source', 'recipe', 'compiler', 'package']:
            with self.subTest(changed=changed), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp).resolve()
                repo, sdk, cache, node = [root/name for name in ['repo', 'sdk', 'cache', 'node']]
                includes = [root/'VS/VC/Tools/MSVC/14.44/include',
                            root/'Windows Kits/10/Include/10.0.26100.0/ucrt']
                libdir = root/'VS/VC/Tools/MSVC/14.44/lib/x64'
                for directory in [repo, sdk, cache, node, libdir, *includes]:
                    directory.mkdir(parents=True)
                for name in build.SOURCE_FILES:
                    source = repo/name
                    source.parent.mkdir(parents=True, exist_ok=True)
                    source.write_text(name)
                for name in ['node_api.h', 'uv.h', 'node.lib']:
                    (node/name).write_text(name)
                header = includes[0]/'string'
                header.write_text('MSVC header')
                library = libdir/'libcmt.lib'
                library.write_text('static CRT')
                clang_root = sdk/'buildtools/win-x64/clang'
                (clang_root/'bin').mkdir(parents=True)
                (clang_root/'.versions').mkdir()
                package = clang_root/'.versions/clang.cipd_version'
                package.write_text('pinned clang')
                clang, linker = [clang_root/'bin'/name for name in ['clang-cl.exe', 'lld-link.exe']]
                clang.write_text('compiler')
                linker.write_text('linker')
                (cache/'clang_x64_shared').mkdir()
                (cache/'clang_x64_shared/toolchain.ninja').write_text('toolchain')
                (cache/'args.gn').write_text('arguments')
                (cache/'environment.x64').write_text('INCLUDE='+ ';'.join(map(str, includes))+'\0LIB='+str(libdir)+'\0\0')
                vm = cache/'vm.obj'
                vm.write_text('VM')
                target, compile_target = cache/'link.ninja', cache/'compile.ninja'
                target.write_text('build runtime: clang_x64_shared_solink vm.obj\n'
                                  'ldflags = /MACHINE:X64\nlibs = kernel32.lib\n')
                compile_target.write_text('defines = /DPRODUCT /DDART_PRECOMPILED_RUNTIME /DNAPI_DART_RUNTIME_BUILD\n'
                                          'cflags = /MT\n')
                commands = []
                def run(command, cwd=None, env=None):
                    commands.append(command)
                    if command[0] == 'git':
                        return 'a'*40 if 'rev-parse' in command else ''
                    if '--version' in command:
                        return 'pinned clang-cl 23\nInstalledDir: '+str(clang.parent)
                    if '/Zs' in command:
                        return 'Note: including file: '+str(header)
                    if '/c' in command:
                        obj = Path(next(arg[3:] for arg in command if arg.startswith('/Fo')))
                        obj.write_text('object')
                        return ''
                    if '/DLL' in command:
                        binary = Path(next(arg[5:] for arg in command if arg.startswith('/OUT:')))
                        implib = Path(next(arg[8:] for arg in command if arg.startswith('/IMPLIB:')))
                        binary.write_text('image')
                        implib.write_text('import library')
                        response = Path(next(arg[1:] for arg in command if arg.startswith('@')))
                        paths = build.windows_arguments(response.read_text()) + [str(library)]
                        dependencies = Path(next(arg.split(':', 1)[1] for arg in command
                                                 if arg.startswith('/linkreprofullpathrsp:')))
                        dependencies.write_text('\n'.join('"'+path+'"' for path in paths))
                        if binary.parent.name == 'bundle' and changed:
                            {'header': header, 'library': library, 'node': node/'node.lib',
                             'vm': vm, 'source': repo/'native/runtime/runtime.cc',
                             'recipe': target, 'compiler': clang, 'package': package}[changed].write_text('changed')
                        return ''
                    raise AssertionError(command)
                output = root/'bundle'
                with patch.object(build, 'ROOT', repo), patch.object(build, 'run', side_effect=run), \
                        patch.object(build, 'host_profile', return_value='windows-x64'), \
                        patch.object(build, 'validate_cache', return_value=(target, compile_target)), \
                        patch.object(build, 'validate_pe'), \
                        patch.object(build, 'publish', side_effect=lambda a, b: a.rename(b)):
                    if changed:
                        with self.assertRaisesRegex(ValueError, 'changed during the build'):
                            build.build(sdk, node, output, cache, node/'node.lib')
                        self.assertFalse(output.exists())
                    else:
                        manifest = build.build(sdk, node, output, cache, node/'node.lib')
                        self.assertEqual(manifest['platform'], 'windows')
                        self.assertEqual(manifest['minimumOsVersion'], '10.0')
                        self.assertTrue(manifest['runtime'].endswith('.dll'))
                        self.assertEqual(set(manifest['files']), {manifest['runtime'], 'bridge.node',
                                                               'NAPI_LICENSE', 'DART_LICENSE', 'DART_AUTHORS'})
                        compiler = manifest['build']['provenance']['compiler']
                        self.assertEqual(compiler['version'], 'pinned clang-cl 23')
                        self.assertEqual(compiler['windowsSdkVersion'], '10.0.26100.0')
                        self.assertEqual(compiler['msvcVersion'], '14.44')
                        self.assertEqual(compiler['nodeLibrarySha256'], build.digest(node/'node.lib'))
                        bridge_commands = [command for command in commands if '/DBUILDING_NODE_EXTENSION' in command]
                        self.assertTrue(bridge_commands)
                        for command in bridge_commands:
                            self.assertIn('/DUSING_UV_SHARED=1', command)
                            self.assertIn('/MT', command)
                            self.assertNotIn('/DNAPI_DART_RUNTIME_BUILD', command)
                        self.assertEqual(json.loads((output/'manifest.json').read_text()), manifest)
