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
ROOT = Path(__file__).resolve().parents[2]
SOURCE_FILES = [
    'tool/native/build.py', 'native/bridge/bridge.cc', 'native/bridge/abi.h',
    'native/runtime/runtime.cc', 'native/runtime/runtime.h',
    'native/runtime/identity.cc', 'native/runtime/BUILD.gn',
    'native/runtime/DART_LICENSE', 'native/runtime/DART_AUTHORS', 'LICENSE',
]


def run(command, cwd=None):
    result = subprocess.run(command, cwd=cwd, text=True, capture_output=True)
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
    raise ValueError('Only native macOS arm64/x64 and Linux x64 maintainer builds are supported')


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
    linux = profile == 'linux-x64'
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
        'target_os': '"linux"' if linux else '"mac"',
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
    if not linux and f'-mmacosx-version-min={MINIMUM_OS}' not in toolchain:
        raise ValueError(f'VM cache must target macOS {MINIMUM_OS}')
    if not linux and f'buildtools/mac-{architecture}/clang/bin/clang++' not in toolchain:
        raise ValueError(f'VM cache must use the pinned SDK macOS {architecture} clang')
    target = cache/toolchain_name/'obj/runtime/napi/napi_runtime.ninja'
    compile_target = cache/toolchain_name/'obj/runtime/napi/napi_runtime_set.ninja'
    if not target.is_file() or not compile_target.is_file():
        raise ValueError('Missing prepared runtime/napi Product cache; see native/README.md')
    if linux:
        if 'buildtools/linux-x64/clang/bin/clang++' not in toolchain:
            raise ValueError('VM cache must use the pinned SDK Linux x64 clang')
        sysroot = (sdk/'buildtools/sysroot/linux').resolve(strict=True)
        for path, key in [(compile_target, 'cflags'), (target, 'ldflags')]:
            flags = shlex.split(variables(path).get(key, ''))
            roots = [flag.removeprefix('--sysroot=') for flag in flags
                     if flag.startswith('--sysroot=')]
            if (len(roots) != 1 or (cache/roots[0]).resolve() != sysroot or
                    '--target=x86_64-linux-gnu' not in flags or '-fPIC' not in flags):
                raise ValueError('VM cache must target Linux x64 with the pinned Debian sysroot')
    return target, compile_target


def publish(source, target):
    # Atomic directory publication without replacing a racing output/symlink.
    libc = ctypes.CDLL(None, use_errno=True)
    if host_profile() == 'linux-x64':
        # Linux x64 renameat2(AT_FDCWD, ..., RENAME_NOREPLACE). Use the syscall
        # directly so publication does not require glibc's newer wrapper.
        rename = libc.syscall
        rename.restype = ctypes.c_long
        result = rename(ctypes.c_long(316), ctypes.c_int(-100),
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


def validate_elf(readelf, binary, runtime):
    header = run([readelf, '--file-header', str(binary)])
    if not re.search(r'Class:\s+ELF64', header) or not re.search(
            r'Machine:\s+(Advanced Micro Devices X86-64|AMD x86-64)', header):
        raise ValueError(f'Expected Linux x64 ELF: {binary.name}')
    dynamic = run([readelf, '--dynamic', str(binary)])
    def entries(tag):
        return re.findall(r'\(' + tag + r'\).*?\[([^\]]+)\]', dynamic)

    if entries('SONAME') != [binary.name] or entries('RUNPATH') != ['$ORIGIN'] or entries('RPATH'):
        raise ValueError(f'Invalid ELF SONAME or RUNPATH: {binary.name}')
    allowed = {'libc.so.6', 'libdl.so.2', 'libpthread.so.0', 'libm.so.6',
               'librt.so.1', 'ld-linux-x86-64.so.2'}
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


def build(sdk, headers, output, cache):
    profile = host_profile()
    linux = profile == 'linux-x64'
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
        clang = str(sdk/'buildtools/linux-x64/clang/bin/clang++')
        linker = str(sdk/'buildtools/linux-x64/clang/bin/ld.lld')
        sysroot = str(sdk/'buildtools/sysroot/linux')
        compiler_packages = {
            'clangPackageSha256': sdk/'buildtools/linux-x64/clang/.versions/clang.cipd_version',
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
        bridge_flags = (['-fPIC', '--sysroot='+sysroot, '--target=x86_64-linux-gnu'] if linux else
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
            validate_elf(str(Path(clang).with_name('llvm-readelf')), runtime, filename)
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
                    validate_elf(str(Path(clang).with_name('llvm-readelf')), binary, filename)
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
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--runtime-build', type=Path)
    args = parser.parse_args()
    sdk = args.sdk.resolve(strict=True)
    profile = host_profile()
    default_cache = ('out/ProductX64' if profile == 'linux-x64' else
                     'xcodebuild/Product' + profile.rsplit('-', 1)[1].upper())
    cache = (args.runtime_build or sdk/default_cache).resolve(strict=True)
    # Preserve the caller's include-root layout when node/ is a package-manager
    # symlink and libuv is installed beside it rather than in the same package.
    manifest = build(sdk, args.node_headers.absolute(), args.output.absolute(), cache)
    print(json.dumps({'output': str(args.output.absolute()), 'identity': manifest['identity'],
                      'files': manifest['files'], 'build': manifest['build']}, indent=2))


if __name__ == '__main__':
    main()
