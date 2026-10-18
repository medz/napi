#!/usr/bin/env python3
"""Maintainer-only macOS arm64 bundle build from a configured Product VM cache.

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
import shlex
import shutil
import subprocess
import tempfile

SDK_VERSION = '3.13.5'
SDK_REVISION = '04bcd1036cdc799ac6564988f159ee454d42c822'
ABI = 15
MINIMUM_OS = '14.0'
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
    return dict(line.split(' = ', 1) for line in path.read_text().splitlines()
                if ' = ' in line and not line.startswith(' '))


def source_inputs():
    return {name: digest(ROOT/name) for name in SOURCE_FILES}


def vm_inputs(cache, objects):
    result = hashlib.sha256()
    for relative in objects:
        result.update(relative.encode() + b'\0' +
                      digest((cache/relative).resolve(strict=True)).encode() + b'\0')
    return result.hexdigest()


def dependency_inputs(depfiles, roots):
    """Record actual non-system headers read by these compilations, not a guess."""
    result = {}
    for depfile in depfiles:
        dependencies = shlex.split(depfile.read_text().replace('\\\n', ' ').split(':', 1)[1])
        for name in dependencies:
            path = Path(name)
            if not path.is_absolute():
                path = roots['cache']/path
            path = path.resolve(strict=True)
            if path.suffix not in ['.h', '.hpp', '.inc']:
                continue
            for label, root in roots.items():
                if path.is_relative_to(root):
                    result[label+'/'+path.relative_to(root).as_posix()] = digest(path)
                    break
            else:
                raise ValueError(f'Unrecorded native header root: {path}')
    return dict(sorted(result.items()))


def validate_cache(sdk, cache):
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
        'target_os': '"mac"', 'host_cpu': '"arm64"', 'target_cpu': '"arm64"',
        'dart_target_arch': '"arm64"', 'is_product': 'true', 'is_release': 'false',
        'is_debug': 'false', 'dart_debug': 'false', 'dart_use_compressed_pointers': 'false',
        'dart_dynamic_modules': 'false',
        **{key: 'false' for key in ['is_asan', 'is_lsan', 'is_msan', 'is_tsan',
                                    'is_ubsan', 'is_hwasan']},
    }
    for key, value in expected.items():
        if args.get(key) != value:
            raise ValueError(f'Unsupported VM cache: args.gn must set {key} = {value}')
    toolchain = (cache/'clang_arm64_shared/toolchain.ninja').read_text()
    if f'-mmacosx-version-min={MINIMUM_OS}' not in toolchain:
        raise ValueError(f'VM cache must target macOS {MINIMUM_OS}')
    target = cache/'clang_arm64_shared/obj/runtime/napi/napi_runtime.ninja'
    compile_target = cache/'clang_arm64_shared/obj/runtime/napi/napi_runtime_set.ninja'
    if not target.is_file() or not compile_target.is_file():
        raise ValueError('Missing prepared runtime/napi Product cache; see native/README.md')
    return target, compile_target


def publish(source, target):
    # Atomic directory publication without replacing a racing output/symlink.
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renamex_np
    rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    if rename(os.fsencode(source), os.fsencode(target), 4) != 0:  # RENAME_EXCL
        code = ctypes.get_errno()
        raise OSError(code, os.strerror(code), str(target))


def build(sdk, headers, output, cache):
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise ValueError('Only native macOS arm64 maintainer builds are supported')
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
               'toolchain.ninja': cache/'clang_arm64_shared/toolchain.ninja',
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
    source_hash = hashlib.sha256(f'napi-abi={ABI};macos-arm64;product;minos=14.0\0'.encode())
    for source in [ROOT/'native/runtime/runtime.cc', ROOT/'native/runtime/runtime.h',
                   ROOT/'native/runtime/identity.cc', ROOT/'native/bridge/abi.h']:
        source_hash.update(source.name.encode() + b'\0' + source.read_bytes() + b'\0')
    source_hash = source_hash.hexdigest()
    ninja = target.read_text()
    edge = next(line for line in ninja.splitlines() if ': clang_arm64_shared_solink ' in line)
    objects = shlex.split(edge.split(': clang_arm64_shared_solink ', 1)[1].split(' |', 1)[0])
    # Always compile the repository runtime. A cached candidate runtime.o is
    # never trusted as an implementation of this source/identity.
    objects = [path for path in objects if not path.endswith('/napi_runtime_set.runtime.o')]
    vm_inputs_hash = vm_inputs(cache, objects)
    identity_hash = hashlib.sha256(
        (source_hash + '\0' + vm_inputs_hash).encode()).hexdigest()
    identity = f'dart-{SDK_REVISION}-product-macos-arm64-abi{ABI}-id{identity_hash}'
    filename = f'libnapi_runtime_{identity}.dylib'
    compile_vars = variables(compile_target)
    flags = [flag for key in ['defines', 'include_dirs', 'cflags', 'cflags_cc']
             for flag in shlex.split(compile_vars.get(key, ''))]
    if '-DPRODUCT' not in flags or '-DDART_PRECOMPILED_RUNTIME' not in flags:
        raise ValueError('Unsupported VM cache compiler configuration')
    clang = run(['xcrun', '--find', 'clang++'])
    sysroot = run(['xcrun', '--show-sdk-path'])
    provenance = {
        'format': 1,
        'producer': producer,
        'compiler': {'version': run([clang, '--version']), 'sha256': digest(Path(clang)),
                     'macosSdkVersion': run(['xcrun', '--show-sdk-version'])},
        'cacheRecipe': recipe_hashes,
    }
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.napi-native-', dir=output.parent) as temp:
        stage = Path(temp)
        artifact = stage/'bundle'
        artifact.mkdir()
        runtime_objects = []
        depfiles = []
        header_roots = {
            'generated': stage.resolve(), 'repository': ROOT.resolve(),
            'sdk': sdk.resolve(), 'node': headers.resolve(),
            'libuv': (uv_headers/'uv.h').resolve().parent, 'cache': cache.resolve(),
        }
        header_hashes = {}

        def compile_source(command, depfile):
            # Discover the actual non-system dependencies before compilation;
            # post-build hashes alone cannot describe the bytes the compiler used.
            run([*command, '-MM', '-Wno-unused-command-line-argument'], cwd=cache)
            before = dependency_inputs([depfile], header_roots)
            for name, value in before.items():
                if name in header_hashes and header_hashes[name] != value:
                    raise ValueError('Native headers changed during the build')
            header_hashes.update(before)
            run(command, cwd=cache)

        for name in ['runtime', 'identity']:
            obj = stage/f'{name}.o'
            depfile = stage/f'{name}.d'
            depfiles.append(depfile)
            command = [clang, '-isysroot', sysroot, f'-mmacosx-version-min={MINIMUM_OS}',
                       *flags, f'-DNAPI_DART_RUNTIME_ID="{identity}"',
                       '-MMD', '-MF', str(depfile),
                       '-c', str(ROOT/f'native/runtime/{name}.cc'), '-o', str(obj)]
            compile_source(command, depfile)
            runtime_objects.append(str(obj))
        filelist = stage/'objects.rsp'
        filelist.write_text('\n'.join([str((cache/path).resolve()) for path in objects] + runtime_objects)+'\n')
        runtime = artifact/filename
        run([clang, '-shared', '-isysroot', sysroot, f'-mmacosx-version-min={MINIMUM_OS}',
             '--target=arm64-apple-macos', '-Wl,-dead_strip', '-undefined', 'dynamic_lookup',
             '-Wl,-install_name,@rpath/'+filename, '-Wl,-filelist,'+str(filelist),
             '-ldl', '-lpthread', '-framework', 'CoreFoundation', '-framework', 'Security',
             '-framework', 'Foundation', '-framework', 'CoreServices', '-o', str(runtime)], cwd=cache)
        (stage/'expected_runtime.h').write_text('constexpr const char* kExpectedRuntimeId = '+json.dumps(identity)+';\n')
        bridge = artifact/'bridge.node'
        bridge_dependencies = stage/'bridge.d'
        depfiles.append(bridge_dependencies)
        compile_source([clang, '-std=c++17', '-O2', '-dynamiclib', '-undefined', 'dynamic_lookup',
             '-MMD', '-MF', str(bridge_dependencies),
             '-isysroot', sysroot, f'-mmacosx-version-min={MINIMUM_OS}',
             '-I'+str(headers), '-I'+str(uv_headers),
             '-I'+str(sdk/'runtime'), '-I'+str(sdk/'runtime/include'),
             '-I'+str(ROOT/'native/runtime'), '-I'+str(stage),
             str(ROOT/'native/bridge/bridge.cc'), str(runtime),
             '-Wl,-install_name,@rpath/bridge.node', '-Wl,-rpath,@loader_path', '-o', str(bridge)],
            bridge_dependencies)
        provenance['headers'] = header_hashes
        for binary in [runtime, bridge]:
            run(['codesign', '--force', '--sign', '-', str(binary)])
        shutil.copy2(ROOT/'native/runtime/DART_LICENSE', artifact/'DART_LICENSE')
        shutil.copy2(ROOT/'native/runtime/DART_AUTHORS', artifact/'DART_AUTHORS')
        shutil.copy2(ROOT/'LICENSE', artifact/'NAPI_LICENSE')
        manifest = {
            'format': 1, 'sdkVersion': SDK_VERSION, 'sdkRevision': SDK_REVISION,
            'platform': 'macos', 'architecture': 'arm64', 'minimumOsVersion': MINIMUM_OS,
            'abi': ABI, 'identity': identity, 'bridge': 'bridge.node', 'runtime': filename,
            'files': {file.name: digest(file) for file in sorted(artifact.iterdir())},
            'build': {'cacheArgumentsSha256': digest(cache/'args.gn'),
                      'vmInputsSha256': vm_inputs_hash, 'vmInputCount': len(objects),
                      'sourceSha256': source_hash, 'provenance': provenance},
        }
        (artifact/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
        if source_inputs() != sources:
            raise ValueError('Native source inputs changed during the build')
        if vm_inputs(cache, objects) != vm_inputs_hash:
            raise ValueError('Native VM inputs changed during the build')
        if {name: digest(path) for name, path in recipes.items()} != recipe_hashes:
            raise ValueError('Native cache recipes changed during the build')
        if dependency_inputs(depfiles, header_roots) != header_hashes:
            raise ValueError('Native headers changed during the build')
        if digest(Path(clang)) != provenance['compiler']['sha256']:
            raise ValueError('Native compiler changed during the build')
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
    cache = (args.runtime_build or sdk/'xcodebuild/ProductARM64').resolve(strict=True)
    # Preserve the caller's include-root layout when node/ is a package-manager
    # symlink and libuv is installed beside it rather than in the same package.
    manifest = build(sdk, args.node_headers.absolute(), args.output.absolute(), cache)
    print(json.dumps({'output': str(args.output.absolute()), 'identity': manifest['identity'],
                      'files': manifest['files'], 'build': manifest['build']}, indent=2))


if __name__ == '__main__':
    main()
