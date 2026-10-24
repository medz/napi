#!/usr/bin/env python3
"""Maintainer-only native bundle build from a configured Product VM cache.

Uses existing pinned SDK objects; never downloads or compiles business C/C++.
See native/README.md for the cache preparation prerequisite.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import subprocess
import tempfile

SDK_VERSION = '3.13.5'
SDK_REVISION = '04bcd1036cdc799ac6564988f159ee454d42c822'
ABI = 15
MINIMUM_OS = '14.0'
MINIMUM_LIBC = '2.28'
WINDOWS_SDK_VERSION = '10.0.26100.0'
LINUX_TARGETS = {'x64': 'x86_64-linux-gnu', 'arm64': 'aarch64-linux-gnu'}
ROOT = Path(__file__).resolve().parents[2]
SOURCE_FILES = [
    'tool/native/build.py', 'native/bridge/bridge.cc', 'native/bridge/abi.h',
    'native/runtime/runtime.cc', 'native/runtime/runtime.h',
    'native/runtime/identity.cc', 'native/runtime/BUILD.gn',
    'native/runtime/DART_LICENSE', 'native/runtime/DART_AUTHORS', 'LICENSE',
]


def run(command, cwd=None, env=None):
    result = subprocess.run(command, cwd=cwd, env=env, text=True, capture_output=True)
    if result.returncode:
        raise RuntimeError(f'{shlex.join(map(str, command))}\n{result.stdout}{result.stderr}')
    return result.stdout.strip()


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(block)
    return result.hexdigest()


def variables(path):
    return dict(line.strip().split(' = ', 1) for line in path.read_text().splitlines()
                if ' = ' in line)


def host_profile():
    host = platform.system(), platform.machine()
    if host == ('Darwin', 'arm64'):
        return 'macos-arm64'
    if host == ('Darwin', 'x86_64'):
        return 'macos-x64'
    if host == ('Linux', 'x86_64'):
        return 'linux-x64'
    if host == ('Linux', 'aarch64'):
        return 'linux-arm64'
    if host == ('Windows', 'AMD64'):
        return 'windows-x64'
    raise ValueError('Native maintainer builds require macOS/Linux arm64 or x64, or Windows x64')


def source_inputs():
    return {name: digest(ROOT/name) for name in SOURCE_FILES}


def vm_inputs(cache, objects):
    result = hashlib.sha256()
    for relative in objects:
        result.update(relative.encode() + b'\0' +
                      digest((cache/relative).resolve(strict=True)).encode() + b'\0')
    return result.hexdigest()


def dependency_inputs(depfiles, roots, include_system=False):
    """Record headers from compiler depfiles, including extensionless C++ headers."""
    result = {}
    sources = {(ROOT/name).resolve() for name in SOURCE_FILES if name.endswith('.cc')}
    locations = sorted(roots.items(), key=lambda item: len(item[1].parts), reverse=True) if include_system else roots.items()
    for depfile in depfiles:
        dependencies = shlex.split(depfile.read_text().replace('\\\n', ' ').split(':', 1)[1])
        for name in dependencies:
            path = Path(name)
            if not path.is_absolute():
                path = roots['cache']/path
            path = path.resolve(strict=True)
            if path in sources or (not include_system and path.suffix not in ['.h', '.hpp', '.inc']):
                continue
            for label, root in locations:
                if path.is_relative_to(root):
                    result[label+'/'+path.relative_to(root).as_posix()] = digest(path)
                    break
            else:
                raise ValueError(f'Unrecorded native header root: {path}')
    return dict(sorted(result.items()))


def linux_toolchain_inputs(depfile, sdk, cache, clang, linker, ignored=()):
    # lld records every opened input, including linker scripts and their
    # transitive libraries. Only the first rule contains dependencies; the
    # remaining rules are phony targets for make.
    rule = depfile.read_text().replace('\\\n', ' ').splitlines()[0]
    paths = [Path(clang), Path(linker),
             *(cache/name.replace('$$', '$') for name in shlex.split(rule.split(':', 1)[1]))]
    ignored = {Path(path).resolve() for path in ignored}
    sdk = sdk.resolve()
    result = {}
    for path in paths:
        path = path.resolve(strict=True)
        if path in ignored:
            continue
        if not path.is_relative_to(sdk):
            raise ValueError(f'Linux link input is outside the pinned SDK: {path}')
        result[path.relative_to(sdk).as_posix()] = digest(path)
    return dict(sorted(result.items()))


def validate_cache(sdk, cache):
    profile = host_profile()
    linux = profile.startswith('linux-')
    windows = profile == 'windows-x64'
    architecture = profile.rsplit('-', 1)[1]
    if run(['git', '-C', str(sdk), 'rev-parse', 'HEAD']) != SDK_REVISION:
        raise ValueError(f'Expected Dart SDK revision {SDK_REVISION}')
    version = dict(line.split(None, 1) for line in (sdk/'tools/VERSION').read_text().splitlines()
                   if line.strip() and not line.startswith('#') and len(line.split(None, 1)) == 2)
    if '.'.join(version.get(key, '') for key in ['MAJOR', 'MINOR', 'PATCH']) != SDK_VERSION:
        raise ValueError(f'Expected Dart SDK {SDK_VERSION}')
    args = {}
    for line in (cache/'args.gn').read_text().splitlines():
        line = line.split('#', 1)[0].strip()
        if ' = ' in line:
            key, value = line.split(' = ', 1)
            args[key] = value
    expected = {
        'target_os': '"linux"' if linux else '"win"' if windows else '"mac"',
        **{key: '"'+architecture+'"'
           for key in ['host_cpu', 'target_cpu', 'dart_target_arch']},
        'is_product': 'true', 'is_release': 'false',
        'is_debug': 'false', 'dart_debug': 'false', 'dart_use_compressed_pointers': 'false',
        'dart_dynamic_modules': 'false',
        **{key: 'false' for key in ['is_asan', 'is_lsan', 'is_msan', 'is_tsan',
                                    'is_ubsan', 'is_hwasan']},
    }
    if linux:
        expected['dart_sysroot'] = '"debian"'
        if args.get('use_custom_libcxx', 'false') != 'false':
            raise ValueError('Linux VM cache must use the default C++ standard library')
    for key, value in expected.items():
        if args.get(key) != value:
            raise ValueError(f'Unsupported VM cache: args.gn must set {key} = {value}')
    toolchain_name = f'clang_{architecture}_shared'
    toolchain = (cache/toolchain_name/'toolchain.ninja').read_text()
    if not linux and not windows and f'-mmacosx-version-min={MINIMUM_OS}' not in toolchain:
        raise ValueError(f'VM cache must target macOS {MINIMUM_OS}')
    if not linux and not windows and f'buildtools/mac-{architecture}/clang/bin/clang++' not in toolchain:
        raise ValueError(f'VM cache must use the pinned SDK macOS {architecture} clang')
    target = cache/toolchain_name/'obj/runtime/napi/napi_runtime.ninja'
    compile_target = cache/toolchain_name/'obj/runtime/napi/napi_runtime_set.ninja'
    if not target.is_file() or not compile_target.is_file():
        raise ValueError('Missing prepared runtime/napi Product cache; see native/README.md')
    if linux:
        if f'buildtools/linux-{architecture}/clang/bin/clang++' not in toolchain:
            raise ValueError(f'VM cache must use the pinned SDK Linux {architecture} clang')
        sysroot = (sdk/'buildtools/sysroot/linux').resolve(strict=True)
        for path, key in [(compile_target, 'cflags'), (target, 'ldflags')]:
            flags = shlex.split(variables(path).get(key, ''))
            roots = [flag.removeprefix('--sysroot=') for flag in flags
                     if flag.startswith('--sysroot=')]
            if (len(roots) != 1 or (cache/roots[0]).resolve() != sysroot or
                    '--target='+LINUX_TARGETS[architecture] not in flags or '-fPIC' not in flags):
                raise ValueError(f'VM cache must target Linux {architecture} with the pinned Debian sysroot')
    if windows:
        if ('buildtools/win-x64/clang/bin/clang-cl.exe' not in toolchain or
                '--target=x86_64-pc-windows-msvc' not in toolchain or
                'buildtools/win-x64/clang/bin/lld-link.exe' not in toolchain):
            raise ValueError('VM cache must use the pinned SDK Windows x64 clang-cl and lld-link')
        flags = windows_arguments(variables(compile_target).get('cflags', ''))
        if '/MT' not in flags or any(flag in flags for flag in ['/MD', '/MDd', '/MTd']):
            raise ValueError('Windows VM cache must use the release static CRT (/MT)')
        if not (cache/'environment.x64').is_file():
            raise ValueError('Windows VM cache has no x64 toolchain environment')
    return target, compile_target


def publish(source, target):
    # Atomic directory publication without replacing a racing output/symlink.
    profile = host_profile()
    if profile == 'windows-x64':
        # Windows rename fails if the destination exists; never use replace.
        os.rename(source, target)
        return
    libc = ctypes.CDLL(None, use_errno=True)
    if profile.startswith('linux-'):
        # Linux renameat2(AT_FDCWD, ..., RENAME_NOREPLACE). Use the syscall
        # directly so publication does not require glibc's newer wrapper.
        rename = libc.syscall
        rename.restype = ctypes.c_long
        number = 276 if profile == 'linux-arm64' else 316
        result = rename(ctypes.c_long(number), ctypes.c_int(-100),
                        ctypes.c_char_p(os.fsencode(source)), ctypes.c_int(-100),
                        ctypes.c_char_p(os.fsencode(target)), ctypes.c_uint(1))
    else:
        rename = libc.renamex_np
        rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
        rename.restype = ctypes.c_int
        result = rename(os.fsencode(source), os.fsencode(target), 4)  # RENAME_EXCL
    if result != 0:
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(target))


def validate_elf(readelf, binary, runtime, architecture):
    header = run([readelf, '--file-header', str(binary)])
    machine = 'AArch64' if architecture == 'arm64' else '(Advanced Micro Devices X86-64|AMD x86-64)'
    if not re.search(r'Class:\s+ELF64', header) or not re.search(r'Machine:\s+' + machine, header):
        raise ValueError(f'Expected Linux {architecture} ELF: {binary.name}')
    dynamic = run([readelf, '--dynamic', str(binary)])
    def entries(tag):
        return re.findall(r'\(' + tag + r'\).*?\[([^\]]+)\]', dynamic)

    if entries('SONAME') != [binary.name] or entries('RUNPATH') != ['$ORIGIN'] or entries('RPATH'):
        raise ValueError(f'Invalid ELF SONAME or RUNPATH: {binary.name}')
    loader = 'ld-linux-aarch64.so.1' if architecture == 'arm64' else 'ld-linux-x86-64.so.2'
    allowed = {'libc.so.6', 'libdl.so.2', 'libpthread.so.0', 'libm.so.6', 'librt.so.1', loader}
    if binary.name != runtime:
        allowed.add(runtime)
        if runtime not in entries('NEEDED'):
            raise ValueError('Native bridge must depend on its named runtime')
    unexpected = set(entries('NEEDED')) - allowed
    if unexpected:
        raise ValueError(f'Unexpected ELF dependencies: {sorted(unexpected)}')
    versions = run([readelf, '--version-info', str(binary)])
    required = re.findall(r'\bGLIBC_([A-Za-z0-9_.]+)\b', versions)
    maximum = tuple(map(int, MINIMUM_LIBC.split('.')))
    newer = {value for value in required if not re.fullmatch(r'[0-9]+(?:\.[0-9]+)+', value) or
             tuple(map(int, value.split('.'))) > maximum}
    if not required or newer:
        symbols = run([readelf, '--dyn-syms', '--wide', str(binary)])
        incompatible = [line.strip() for line in symbols.splitlines() if re.search(r'\bUND\b', line)
                        and any('@GLIBC_'+version in line for version in newer)]
        raise ValueError(f'{binary.name} requires newer than glibc {MINIMUM_LIBC}: '
                         f'{", ".join(sorted(set(required)))}\n' + '\n'.join(incompatible))


def windows_arguments(value):
    """Parse Ninja's Windows response arguments without treating '\\' as a shell escape."""
    value = re.sub(r'\$([ $:])', r'\1', value)
    result, argument, quoted, started = [], [], False, False
    index = 0
    while index < len(value):
        char = value[index]
        if char.isspace() and not quoted:
            if started:
                result.append(''.join(argument))
                argument, started = [], False
        elif char == '\\':
            end = index
            while end < len(value) and value[end] == '\\':
                end += 1
            count = end - index
            if end < len(value) and value[end] == '"':
                argument.extend('\\' * (count // 2))
                if count % 2:
                    argument.append('"')
                else:
                    quoted = not quoted
                index = end
            else:
                argument.extend('\\' * count)
                index = end - 1
            started = True
        elif char == '"':
            quoted, started = not quoted, True
        else:
            argument.append(char)
            started = True
        index += 1
    if quoted:
        raise ValueError('Unterminated Windows compiler argument')
    if started:
        result.append(''.join(argument))
    return result


def windows_inputs(paths, roots, ignored=()):
    ignored = {path.resolve() for path in ignored}
    result = {}
    for path in paths:
        path = path.resolve(strict=True)
        if path in ignored or path.is_relative_to(roots['generated']):
            continue
        for label, root in sorted(roots.items(), key=lambda item: len(item[1].parts), reverse=True):
            if path.is_relative_to(root):
                result[label+'/'+path.relative_to(root).as_posix()] = digest(path)
                break
        else:
            raise ValueError(f'Unrecorded Windows toolchain input: {path}')
    return dict(sorted(result.items()))


def validate_pe(readobj, binary, runtime):
    image = run([readobj, '--file-headers', '--coff-imports', str(binary)])
    if ('Machine: IMAGE_FILE_MACHINE_AMD64' not in image or
            not re.search(r'Magic:\s+0x20B\b', image) or 'IMAGE_FILE_DLL' not in image):
        raise ValueError(f'Expected Windows x64 DLL: {binary.name}')
    dependencies = {name.lower() for name in re.findall(r'\b(?:Delay)?Import\s*\{\s*Name:\s*(\S+)', image)}
    allowed = {'kernel32.dll', 'ntdll.dll', 'advapi32.dll', 'bcrypt.dll', 'crypt32.dll',
               'iphlpapi.dll', 'ole32.dll', 'pathcch.dll', 'psapi.dll', 'rpcrt4.dll',
               'shell32.dll', 'shlwapi.dll', 'user32.dll', 'userenv.dll', 'ws2_32.dll', 'winmm.dll'}
    if binary.name != runtime:
        allowed.update({runtime.lower(), 'node.exe'})
        if not {runtime.lower(), 'node.exe'} <= dependencies:
            raise ValueError('Native bridge must import Node and its named runtime')
    unexpected = dependencies - allowed
    if unexpected:
        raise ValueError(f'Unexpected Windows dependencies: {sorted(unexpected)}')
    if not dependencies:
        raise ValueError(f'Windows image has no import dependencies: {binary.name}')


def build_windows(sdk, headers, output, cache, node_library):
    if os.path.lexists(output):
        raise FileExistsError(f'Output already exists: {output}')
    if node_library is None or not node_library.is_file():
        raise ValueError('Windows builds require --node-library pointing to the Node x64 node.lib')
    if not (headers/'node_api.h').is_file():
        raise ValueError('Node headers must contain node_api.h')
    uv_headers = next((root for root in [headers, headers.parent] if (root/'uv.h').is_file()), None)
    if uv_headers is None:
        raise ValueError('Node headers or their parent must contain libuv uv.h')
    target, compile_target = validate_cache(sdk, cache)
    recipes = {'args.gn': cache/'args.gn', 'toolchain.ninja': cache/'clang_x64_shared/toolchain.ninja',
               'compile.ninja': compile_target, 'link.ninja': target,
               'environment.x64': cache/'environment.x64'}
    recipe_hashes = {name: digest(path) for name, path in recipes.items()}
    environment = dict(item.split('=', 1) for item in (cache/'environment.x64').read_text().split('\0') if item)
    environment['VSLANG'] = '1033'
    # Clang's include tracing is English; inherited SDK environment controls LIB/INCLUDE.
    edge_type = ': clang_x64_shared_solink '
    edge = next(line for line in target.read_text().splitlines() if edge_type in line)
    objects = [name for name in windows_arguments(edge.split(edge_type, 1)[1].split(' |', 1)[0])
               if not name.endswith('/napi_runtime_set.runtime.obj')]
    vm_hash = vm_inputs(cache, objects)
    object_paths = [(cache/name).resolve() for name in objects]
    compile_vars, link_vars = variables(compile_target), variables(target)
    flags = [flag for key in ['defines', 'include_dirs', 'cflags', 'cflags_cc']
             for flag in windows_arguments(compile_vars.get(key, ''))]
    if not all(any(flag in flags for flag in ['-D'+name, '/D'+name])
               for name in ['PRODUCT', 'DART_PRECOMPILED_RUNTIME', 'NAPI_DART_RUNTIME_BUILD']):
        raise ValueError('Unsupported Windows VM cache compiler configuration')
    link_flags = [flag for flag in windows_arguments(link_vars.get('ldflags', ''))
                  if not flag.lower().startswith(('/pdb:', '/debug', '/implib:', '/out:'))]
    libraries = windows_arguments(link_vars.get('libs', ''))
    clang_root = sdk/'buildtools/win-x64/clang'
    clang, linker = [clang_root/'bin'/name for name in ['clang-cl.exe', 'lld-link.exe']]
    includes = environment.get('INCLUDE', '').replace('\\', '/')
    msvc_versions = set(re.findall(r'/VC/Tools/MSVC/([^/;]+)/include(?:;|$)', includes, re.I))
    sdk_versions = set(re.findall(r'/Windows Kits/10/Include/([^/;]+)/', includes, re.I))
    if len(msvc_versions) != 1 or sdk_versions != {WINDOWS_SDK_VERSION}:
        raise ValueError('Windows VM cache must use one MSVC toolset and Windows SDK '+WINDOWS_SDK_VERSION)
    compiler = {'version': run([str(clang), '--version']), 'sha256': digest(clang),
                'clangPackageSha256': digest(clang_root/'.versions/clang.cipd_version'),
                'windowsSdkVersion': WINDOWS_SDK_VERSION, 'msvcVersion': next(iter(msvc_versions)),
                'nodeLibrarySha256': digest(node_library)}
    sources = source_inputs()
    source_hash = hashlib.sha256(json.dumps(sources, sort_keys=True).encode()).hexdigest()
    producer = {'commit': run(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']),
                'dirty': bool(run(['git', '-C', str(ROOT), 'status', '--porcelain', '--', *SOURCE_FILES])),
                'files': sources}
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.napi-native-', dir=output.parent) as temporary:
        stage = Path(temporary)
        artifact = stage/'bundle'
        artifact.mkdir()
        roots = {'repository': ROOT.resolve(), 'sdk': sdk.resolve(), 'node': headers.resolve(),
                 'nodeLibrary': node_library.parent.resolve(), 'libuv': uv_headers.resolve(),
                 'cache': cache.resolve(), 'generated': stage.resolve()}
        for variable in ['INCLUDE', 'LIB']:
            for index, name in enumerate(environment.get(variable, '').split(';')):
                if name:
                    roots[f'{variable.lower()}/{index}'] = (cache/name).resolve(strict=True)
        bridge_flags = ['/nologo', '--target=x86_64-pc-windows-msvc', '/std:c++17', '/O2', '/MT', '/EHsc',
                        '/DWIN32_LEAN_AND_MEAN', '/DNOMINMAX', '/D_WIN32_WINNT=0x0A00',
                        '/DUSING_UV_SHARED=1', '/DBUILDING_NODE_EXTENSION',
                        *['/I'+str(path) for path in [headers, uv_headers, sdk/'runtime',
                           sdk/'runtime/include', ROOT/'native/runtime', stage]]]
        headers_seen = {}
        link_inputs_seen = {}
        expected_header = stage/'expected_runtime.h'
        expected_header.write_text('constexpr const char* kExpectedRuntimeId = "";\n')

        def compile_source(name, identity):
            source = ROOT/('native/bridge/bridge.cc' if name == 'bridge' else f'native/runtime/{name}.cc')
            options = bridge_flags if name == 'bridge' else [*flags, f'/DNAPI_DART_RUNTIME_ID="{identity}"']
            command = [str(clang), *options, str(source)]
            includes = run([*command, '/Zs', '/showIncludes'], cwd=cache, env=environment)
            paths = [(cache/path.strip()).resolve() for path in
                     re.findall(r'^Note: including file:\s*(.+)$', includes, re.M)]
            if not paths:
                raise ValueError(f'Clang did not report header dependencies for {source.name}')
            inputs = windows_inputs(paths, roots)
            if name in headers_seen and inputs != headers_seen[name]:
                raise ValueError('Native headers changed during the build')
            headers_seen[name] = inputs
            obj = stage/(name+'.obj')
            run([*command, '/c', '/Fo'+str(obj)], cwd=cache, env=environment)
            return obj

        def link_image(name, paths, binary, implib):
            response = stage/(name+'-objects.rsp')
            response.write_text('\n'.join(subprocess.list2cmdline([str(path)]) for path in paths)+'\n')
            dependencies = stage/(name+'-inputs.rsp')
            run([str(linker), '/nologo', '/DLL', *link_flags, '@'+str(response), *libraries,
                 '/OUT:'+str(binary), '/IMPLIB:'+str(implib),
                 '/linkreprofullpathrsp:'+str(dependencies)], cwd=cache, env=environment)
            files = [Path(re.sub(r'^/(?:defaultlib|wholearchive):', '', value, flags=re.I))
                     for value in windows_arguments(dependencies.read_text())]
            inputs = windows_inputs([clang, linker, *files], roots, object_paths)
            if name in link_inputs_seen and inputs != link_inputs_seen[name]:
                raise ValueError('Native toolchain inputs changed during the build')
            link_inputs_seen[name] = inputs

        # Resolve implicit MSVC/UCRT libraries before choosing a runtime identity.
        runtime_objects = [compile_source(name, '') for name in ['runtime', 'identity']]
        probe = stage/'probe.dll'
        probe_lib = stage/'probe.lib'
        link_image('runtime', [*object_paths, *runtime_objects], probe, probe_lib)
        bridge_object = compile_source('bridge', '')
        link_image('bridge', [bridge_object, probe_lib, node_library], stage/'probe.node', stage/'bridge.lib')
        toolchain_inputs = {name: value for inputs in link_inputs_seen.values() for name, value in inputs.items()}
        header_inputs = {name: value for inputs in headers_seen.values() for name, value in inputs.items()}
        toolchain_hash = hashlib.sha256(json.dumps(toolchain_inputs, sort_keys=True).encode()).hexdigest()
        header_hash = hashlib.sha256(json.dumps(header_inputs, sort_keys=True).encode()).hexdigest()
        arguments = {'runtimeCompile': flags.copy(), 'bridgeCompile': bridge_flags.copy(),
                     'link': link_flags.copy(), 'libraries': libraries.copy()}
        for values in arguments.values():
            for index, value in enumerate(values):
                for label, root in sorted(roots.items(), key=lambda item: len(str(item[1])), reverse=True):
                    value = value.replace(str(root), '<'+label+'>')
                values[index] = value
        arguments_hash = hashlib.sha256(json.dumps(arguments, sort_keys=True).encode()).hexdigest()
        identity_hash = hashlib.sha256('\0'.join([
            source_hash, vm_hash, toolchain_hash, header_hash, arguments_hash,
            json.dumps(compiler, sort_keys=True), json.dumps(recipe_hashes, sort_keys=True)]).encode()).hexdigest()
        identity = f'dart-{SDK_REVISION}-product-windows-x64-abi{ABI}-id{identity_hash}'
        filename = f'libnapi_runtime_{identity}.dll'
        runtime = artifact/filename
        implib = stage/(filename+'.lib')
        runtime_objects = [compile_source(name, identity) for name in ['runtime', 'identity']]
        link_image('runtime', [*object_paths, *runtime_objects], runtime, implib)
        expected_header.write_text('constexpr const char* kExpectedRuntimeId = '+json.dumps(identity)+';\n')
        bridge_object = compile_source('bridge', identity)
        link_image('bridge', [bridge_object, implib, node_library], artifact/'bridge.node', stage/'bridge.lib')
        for binary in [runtime, artifact/'bridge.node']:
            validate_pe(str(clang_root/'bin/llvm-readobj.exe'), binary, filename)
        for name, value in {**header_inputs, **toolchain_inputs}.items():
            label = next(label for label in sorted(roots, key=len, reverse=True) if name.startswith(label+'/'))
            if digest(roots[label]/name[len(label)+1:]) != value:
                raise ValueError('Native toolchain inputs or headers changed during the build')
        for source, destination in [('native/runtime/DART_LICENSE', 'DART_LICENSE'),
                                    ('native/runtime/DART_AUTHORS', 'DART_AUTHORS'), ('LICENSE', 'NAPI_LICENSE')]:
            shutil.copy2(ROOT/source, artifact/destination)
        manifest = {
            'format': 1, 'sdkVersion': SDK_VERSION, 'sdkRevision': SDK_REVISION,
            'platform': 'windows', 'architecture': 'x64', 'minimumOsVersion': '10.0',
            'abi': ABI, 'identity': identity, 'bridge': 'bridge.node', 'runtime': filename,
            'files': {file.name: digest(file) for file in sorted(artifact.iterdir())},
            'build': {'cacheArgumentsSha256': recipe_hashes['args.gn'], 'vmInputsSha256': vm_hash,
                      'vmInputCount': len(objects), 'sourceSha256': source_hash,
                      'toolchainInputsSha256': toolchain_hash, 'argumentsSha256': arguments_hash,
                      'runtimeHeadersSha256': header_hash,
                      'provenance': {'format': 1, 'producer': producer, 'compiler': compiler,
                                     'cacheRecipe': recipe_hashes, 'headers': header_inputs,
                                     'toolchainInputs': toolchain_inputs, 'arguments': arguments}}}
        (artifact/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
        if source_inputs() != sources or vm_inputs(cache, objects) != vm_hash:
            raise ValueError('Native source or VM inputs changed during the build')
        if {name: digest(path) for name, path in recipes.items()} != recipe_hashes:
            raise ValueError('Native cache recipes changed during the build')
        if digest(clang) != compiler['sha256'] or digest(node_library) != compiler['nodeLibrarySha256']:
            raise ValueError('Native compiler or Node library changed during the build')
        if digest(clang_root/'.versions/clang.cipd_version') != compiler['clangPackageSha256']:
            raise ValueError('Native compiler package changed during the build')
        publish(artifact, output)
    return manifest


def build(sdk, headers, output, cache, node_library=None):
    profile = host_profile()
    if profile == 'windows-x64':
        return build_windows(sdk, headers, output, cache, node_library)
    linux = profile.startswith('linux-')
    architecture = profile.rsplit('-', 1)[1]
    toolchain_name = f'clang_{architecture}_shared'
    if os.path.lexists(output):
        raise FileExistsError(f'Output already exists: {output}')
    if not (headers/'node_api.h').is_file():
        raise ValueError('Node headers must contain node_api.h')
    uv_headers = next((root for root in [headers, headers.parent]
                       if (root/'uv.h').is_file()), None)
    if uv_headers is None:
        raise ValueError('Node headers or their parent must contain libuv uv.h')
    target, compile_target = validate_cache(sdk, cache)
    recipes = {'args.gn': cache/'args.gn',
               'toolchain.ninja': cache/toolchain_name/'toolchain.ninja',
               'compile.ninja': compile_target, 'link.ninja': target}
    recipe_hashes = {name: digest(path) for name, path in recipes.items()}
    sources = source_inputs()
    producer = {
        'commit': run(['git', '-C', str(ROOT), 'rev-parse', 'HEAD']),
        # A dirty producer is an explicit source snapshot, not a claim that the
        # commit alone reproduces these bytes. Consumers verify every input.
        'dirty': bool(run(['git', '-C', str(ROOT), 'status', '--porcelain', '--', *SOURCE_FILES])),
        'files': sources,
    }
    baseline = f'glibc={MINIMUM_LIBC}' if linux else 'minos=14.0'
    source_hash = hashlib.sha256(f'napi-abi={ABI};{profile};product;{baseline}\0'.encode())
    for source in [ROOT/'native/runtime/runtime.cc', ROOT/'native/runtime/runtime.h',
                   ROOT/'native/runtime/identity.cc', ROOT/'native/bridge/abi.h']:
        source_hash.update(source.name.encode() + b'\0' + source.read_bytes() + b'\0')
    source_hash = source_hash.hexdigest()
    ninja = target.read_text()
    edge_type = f': {toolchain_name}_solink '
    edge = next(line for line in ninja.splitlines() if edge_type in line)
    objects = shlex.split(edge.split(edge_type, 1)[1].split(' |', 1)[0])
    # Always compile the repository runtime. A cached candidate runtime.o is
    # never trusted as an implementation of this source/identity.
    objects = [path for path in objects if not path.endswith('/napi_runtime_set.runtime.o')]
    vm_inputs_hash = vm_inputs(cache, objects)
    compile_vars = variables(compile_target)
    flags = [flag for key in ['defines', 'include_dirs', 'cflags', 'cflags_cc']
             for flag in shlex.split(compile_vars.get(key, ''))]
    if '-DPRODUCT' not in flags or '-DDART_PRECOMPILED_RUNTIME' not in flags:
        raise ValueError('Unsupported VM cache compiler configuration')
    compiler_packages = {}
    if linux:
        clang_root = sdk/f'buildtools/linux-{architecture}/clang'
        clang = str(clang_root/'bin/clang++')
        linker = str(clang_root/'bin/ld.lld')
        sysroot = str(sdk/'buildtools/sysroot/linux')
        compiler_packages = {
            'clangPackageSha256': clang_root/'.versions/clang.cipd_version',
            'sysrootSha256': Path(sysroot)/'.versions/sysroot.cipd_version',
        }
        compiler_profile = {name: digest(path) for name, path in compiler_packages.items()}
        compile_prefix = []  # The prepared compiler flags already include the sysroot.
        link_vars = variables(target)
        link_flags = [flag for flag in shlex.split(link_vars.get('ldflags', ''))
                      if not flag.startswith(('-Wl,-rpath=', '-Wl,-rpath,', '-Wl,-soname='))]
        link_flags += ['--ld-path='+linker, '-Wl,--strip-debug',
                       '-Wl,--enable-new-dtags', '-Wl,-rpath,$ORIGIN']
        libraries = shlex.split(link_vars.get('libs', ''))
    else:
        clang_root = sdk/f'buildtools/mac-{architecture}/clang'
        clang = str(clang_root/'bin/clang++')
        sysroot = run(['xcrun', '--show-sdk-path'])
        compiler_packages = {
            'clangPackageSha256': clang_root/'.versions/clang.cipd_version',
            'libcxxSha256': clang_root/'lib/libc++.a',
        }
        compiler_profile = {
            'macosSdkVersion': run(['xcrun', '--show-sdk-version']),
            **{name: digest(path) for name, path in compiler_packages.items()},
        }
        mac_target = 'x86_64' if architecture == 'x64' else architecture
        compile_prefix = ['-isysroot', sysroot, f'-mmacosx-version-min={MINIMUM_OS}',
                          f'--target={mac_target}-apple-macos']
        link_vars = variables(target)
        # Keep the SDK's compiler/libc++ pairing. Omit the optional lld ICF
        # flag so this link recipe also accepts Xcode's linker.
        link_flags = [flag for flag in shlex.split(link_vars.get('ldflags', ''))
                      if not flag.startswith(('-Wl,-install_name,', '-Wl,-rpath,'))
                      and flag != '-Wl,--icf=all']
        libraries = [flag for key in ['libs', 'frameworks']
                     for flag in shlex.split(link_vars.get(key, ''))]
    compiler_version = run([clang, '--version'])
    if linux:
        compiler_version = '\n'.join(line for line in compiler_version.splitlines()
                                     if not line.startswith('InstalledDir:'))
    provenance = {
        'format': 1,
        'producer': producer,
        'compiler': {'version': compiler_version, 'sha256': digest(Path(clang)),
                     **compiler_profile},
        'cacheRecipe': recipe_hashes,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.napi-native-', dir=output.parent) as temp:
        stage = Path(temp)
        artifact = stage/'bundle'
        artifact.mkdir()
        bridge_flags = (['-fPIC', '--sysroot='+sysroot, '--target='+LINUX_TARGETS[architecture]] if linux else
                        ['-dynamiclib', '-undefined', 'dynamic_lookup'])
        bridge_options = ['-std=c++17', '-O2', *bridge_flags,
                          '-MD' if linux else '-MMD', '-MF', str(stage/'bridge.d'), *compile_prefix,
                          '-I'+str(headers), '-I'+str(uv_headers),
                          '-I'+str(sdk/'runtime'), '-I'+str(sdk/'runtime/include'),
                          '-I'+str(ROOT/'native/runtime'), '-I'+str(stage)]
        header_roots = {
            'generated': stage.resolve(), 'repository': ROOT.resolve(),
            'sdk': sdk.resolve(), 'node': headers.resolve(),
            'libuv': (uv_headers/'uv.h').resolve().parent, 'cache': cache.resolve(),
        }

        def source_dependencies(command, depfile):
            run([*command, '-M' if linux else '-MM', '-Wno-unused-command-line-argument'], cwd=cache)
            return dependency_inputs([depfile], header_roots, include_system=linux)

        identity_inputs = source_hash + '\0' + vm_inputs_hash
        if not linux:
            identity_inputs += '\0' + provenance['compiler']['sha256']
            identity_inputs += '\0' + json.dumps(compiler_profile, sort_keys=True)
        if linux:
            runtime_header_inputs = {}
            for name in ['runtime', 'identity']:
                depfile = stage/f'{name}.d'
                runtime_header_inputs[name] = source_dependencies(
                    [clang, *compile_prefix, *flags, '-DNAPI_DART_RUNTIME_ID=""',
                     '-MD', '-MF', str(depfile),
                     '-c', str(ROOT/f'native/runtime/{name}.cc'), '-o', str(stage/f'{name}.o')],
                    depfile)
            runtime_headers = {path: value for inputs in runtime_header_inputs.values()
                               for path, value in inputs.items()}
            runtime_headers_hash = hashlib.sha256(
                json.dumps(runtime_headers, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            link_probe = stage/'link-probe.d'
            probe_objects = [str((cache/path).resolve()) for path in objects]
            probe_filelist = stage/'probe-objects.rsp'
            probe_filelist.write_text('\n'.join(map(shlex.quote, probe_objects))+'\n')
            # VM objects can load additional archive members and dependent
            # libraries. Discover those inputs without compiling a new source.
            run([clang, '-shared', *link_flags, '-Wl,--whole-archive', '@'+str(probe_filelist),
                 '-Wl,--no-whole-archive', *libraries,
                 '-Wl,--dependency-file='+str(link_probe), '-o', str(stage/'link-probe.so')], cwd=cache)
            toolchain_inputs = linux_toolchain_inputs(link_probe, sdk, cache, clang, linker, probe_objects)
            toolchain_hash = hashlib.sha256(
                json.dumps(toolchain_inputs, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            arguments = {'runtimeCompile': flags, 'bridgeCompile': bridge_options,
                         'link': link_flags, 'libraries': libraries}
            roots = sorted([(str(prefix), label) for path, label in
                            [(sdk, '<sdk>'), (cache, '<cache>'), (ROOT, '<repository>'),
                             (headers, '<node>'), (uv_headers, '<libuv>'), (stage, '<generated>')]
                            for prefix in [path.absolute(), path.resolve()]],
                           key=lambda item: len(item[0]), reverse=True)
            for name, values in arguments.items():
                normalized = []
                for value in values:
                    for path, label in roots:
                        value = value.replace(path, label)
                    normalized.append(value)
                arguments[name] = normalized
            arguments_hash = hashlib.sha256(
                json.dumps(arguments, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
            identity_inputs += '\0' + toolchain_hash + '\0' + arguments_hash + '\0' + runtime_headers_hash
            provenance['toolchainInputs'] = toolchain_inputs
            provenance['arguments'] = arguments
            provenance['runtimeHeaders'] = runtime_headers
        identity_hash = hashlib.sha256(identity_inputs.encode()).hexdigest()
        identity = f'dart-{SDK_REVISION}-product-{profile}-abi{ABI}-id{identity_hash}'
        filename = f'libnapi_runtime_{identity}' + ('.so' if linux else '.dylib')
        runtime_objects = []
        depfiles = []
        header_hashes = {}

        def compile_source(command, depfile, expected_headers=None):
            # Discover the actual dependencies before compilation;
            # post-build hashes alone cannot describe the bytes the compiler used.
            before = source_dependencies(command, depfile)
            if expected_headers is not None and before != expected_headers:
                raise ValueError('Native headers changed during the build')
            for name, value in before.items():
                if name in header_hashes and header_hashes[name] != value:
                    raise ValueError('Native headers changed during the build')
            header_hashes.update(before)
            run(command, cwd=cache)

        for name in ['runtime', 'identity']:
            obj = stage/f'{name}.o'
            depfile = stage/f'{name}.d'
            depfiles.append(depfile)
            command = [clang, *compile_prefix,
                       *flags, f'-DNAPI_DART_RUNTIME_ID="{identity}"',
                       '-MD' if linux else '-MMD', '-MF', str(depfile),
                       '-c', str(ROOT/f'native/runtime/{name}.cc'), '-o', str(obj)]
            compile_source(command, depfile, runtime_header_inputs[name] if linux else None)
            runtime_objects.append(str(obj))
        filelist = stage/'objects.rsp'
        object_paths = [str((cache/path).resolve()) for path in objects] + runtime_objects
        filelist.write_text('\n'.join(map(shlex.quote, object_paths) if linux else object_paths)+'\n')
        runtime = artifact/filename
        link_dependencies = []

        def check_link_inputs(depfile, ignored, allow_subset=False):
            actual = linux_toolchain_inputs(depfile, sdk, cache, clang, linker, ignored)
            added = sorted(actual.keys() - toolchain_inputs.keys())
            removed = sorted(toolchain_inputs.keys() - actual.keys())
            changed = sorted(name for name in actual.keys() & toolchain_inputs.keys()
                             if actual[name] != toolchain_inputs[name])
            if added or changed or (removed and not allow_subset):
                raise ValueError(f'Native toolchain inputs changed during the build: '
                                 f'added={added}, removed={removed}, changed={changed}')

        if linux:
            runtime_link = stage/'runtime-link.d'
            link_dependencies.append((runtime_link, object_paths, False))
            run([clang, '-shared', *link_flags, '-Wl,-soname,'+filename,
                 '-Wl,--dependency-file='+str(runtime_link),
                 '-Wl,--whole-archive', '@'+str(filelist), '-Wl,--no-whole-archive',
                 *libraries, '-o', str(runtime)], cwd=cache)
            validate_elf(str(Path(clang).with_name('llvm-readelf')), runtime, filename, architecture)
            check_link_inputs(runtime_link, object_paths)
        else:
            run([clang, '-shared', *compile_prefix, *link_flags,
                 '-Wl,-install_name,@rpath/'+filename, '-Wl,-filelist,'+str(filelist),
                 *libraries, '-o', str(runtime)], cwd=cache)
        (stage/'expected_runtime.h').write_text('constexpr const char* kExpectedRuntimeId = '+json.dumps(identity)+';\n')
        bridge = artifact/'bridge.node'
        bridge_dependencies = stage/'bridge.d'
        depfiles.append(bridge_dependencies)
        bridge_object = stage/'bridge.o'
        bridge_link = (['-c', '-o', str(bridge_object)] if linux else
                       [str(runtime), *link_flags, *libraries, '-Wl,-install_name,@rpath/bridge.node',
                        '-Wl,-rpath,@loader_path', '-o', str(bridge)])
        compile_source([clang, *bridge_options,
             str(ROOT/'native/bridge/bridge.cc'), *bridge_link],
            bridge_dependencies)
        if linux:
            bridge_link = stage/'bridge-link.d'
            link_dependencies.append((bridge_link, [bridge_object, runtime], True))
            run([clang, '-shared', *link_flags, str(bridge_object), str(runtime),
                 '-Wl,-soname,bridge.node', '-Wl,--dependency-file='+str(bridge_link),
                 *libraries, '-o', str(bridge)], cwd=cache)
            check_link_inputs(bridge_link, [bridge_object, runtime], allow_subset=True)
        provenance['headers'] = header_hashes
        for binary in [runtime, bridge]:
            if linux:
                if binary == bridge:
                    validate_elf(str(Path(clang).with_name('llvm-readelf')), binary, filename, architecture)
            else:
                run(['codesign', '--force', '--sign', '-', str(binary)])
        shutil.copy2(ROOT/'native/runtime/DART_LICENSE', artifact/'DART_LICENSE')
        shutil.copy2(ROOT/'native/runtime/DART_AUTHORS', artifact/'DART_AUTHORS')
        shutil.copy2(ROOT/'LICENSE', artifact/'NAPI_LICENSE')
        manifest = {
            'format': 1, 'sdkVersion': SDK_VERSION, 'sdkRevision': SDK_REVISION,
            'platform': 'linux' if linux else 'macos', 'architecture': architecture,
            **({'libc': 'glibc', 'minimumLibcVersion': MINIMUM_LIBC} if linux else
               {'minimumOsVersion': MINIMUM_OS}),
            'abi': ABI, 'identity': identity, 'bridge': 'bridge.node', 'runtime': filename,
            'files': {file.name: digest(file) for file in sorted(artifact.iterdir())},
            'build': {'cacheArgumentsSha256': digest(cache/'args.gn'),
                      'vmInputsSha256': vm_inputs_hash, 'vmInputCount': len(objects),
                      **({'toolchainInputsSha256': toolchain_hash,
                          'argumentsSha256': arguments_hash,
                          'runtimeHeadersSha256': runtime_headers_hash} if linux else {}),
                      'sourceSha256': source_hash, 'provenance': provenance},
        }
        (artifact/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
        if source_inputs() != sources:
            raise ValueError('Native source inputs changed during the build')
        if vm_inputs(cache, objects) != vm_inputs_hash:
            raise ValueError('Native VM inputs changed during the build')
        if {name: digest(path) for name, path in recipes.items()} != recipe_hashes:
            raise ValueError('Native cache recipes changed during the build')
        if dependency_inputs(depfiles, header_roots, include_system=linux) != header_hashes:
            raise ValueError('Native headers changed during the build')
        if digest(Path(clang)) != provenance['compiler']['sha256']:
            raise ValueError('Native compiler changed during the build')
        if any(digest(path) != compiler_profile[name] for name, path in compiler_packages.items()):
            raise ValueError('Native compiler packages changed during the build')
        for depfile, ignored, allow_subset in link_dependencies:
            check_link_inputs(depfile, ignored, allow_subset)
        publish(artifact, output)
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', type=Path, required=True)
    parser.add_argument('--node-headers', type=Path, required=True)
    parser.add_argument('--node-library', type=Path, help='Node x64 node.lib (required on Windows)')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runtime-build', type=Path)
    args = parser.parse_args()
    sdk = args.sdk.resolve(strict=True)
    profile = host_profile()
    default_cache = ('xcodebuild' if profile.startswith('macos-') else 'out')
    default_cache += '/Product' + profile.rsplit('-', 1)[1].upper()
    cache = (args.runtime_build or sdk/default_cache).resolve(strict=True)
    # Preserve the caller's include-root layout when node/ is a package-manager
    # symlink and libuv is installed beside it rather than in the same package.
    manifest = build(sdk, args.node_headers.absolute(), args.output.absolute(), cache,
                     args.node_library.resolve(strict=True) if args.node_library else None)
    print(json.dumps({'output': str(args.output.absolute()), 'identity': manifest['identity'],
                      'files': manifest['files'], 'build': manifest['build']}, indent=2))


if __name__ == '__main__':
    main()
