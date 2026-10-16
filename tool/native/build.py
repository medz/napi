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
ABI = 1
MINIMUM_OS = '14.0'
ROOT = Path(__file__).resolve().parents[2]


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
    target, compile_target = validate_cache(sdk, cache)
    source_hash = hashlib.sha256(b'napi-abi=1;macos-arm64;product;minos=14.0\0')
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
    inputs = hashlib.sha256()
    for relative in objects:
        path = (cache/relative).resolve(strict=True)
        inputs.update(relative.encode() + b'\0' + digest(path).encode() + b'\0')
    vm_inputs_hash = inputs.hexdigest()
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
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.napi-native-', dir=output.parent) as temp:
        stage = Path(temp)
        artifact = stage/'bundle'
        artifact.mkdir()
        runtime_objects = []
        for name in ['runtime', 'identity']:
            obj = stage/f'{name}.o'
            command = [clang, '-isysroot', sysroot, f'-mmacosx-version-min={MINIMUM_OS}',
                       *flags, f'-DNAPI_DART_RUNTIME_ID="{identity}"',
                       '-c', str(ROOT/f'native/runtime/{name}.cc'), '-o', str(obj)]
            run(command, cwd=cache)
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
        run([clang, '-std=c++17', '-O2', '-dynamiclib', '-undefined', 'dynamic_lookup',
             '-isysroot', sysroot, f'-mmacosx-version-min={MINIMUM_OS}',
             '-I'+str(headers), '-I'+str(sdk/'runtime'), '-I'+str(sdk/'runtime/include'),
             '-I'+str(ROOT/'native/runtime'), '-I'+str(stage),
             str(ROOT/'native/bridge/bridge.cc'), str(runtime),
             '-Wl,-install_name,@rpath/bridge.node', '-Wl,-rpath,@loader_path', '-o', str(bridge)])
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
                      'sourceSha256': source_hash},
        }
        (artifact/'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n')
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
    manifest = build(sdk, args.node_headers.resolve(strict=True), args.output.absolute(), cache)
    print(json.dumps({'output': str(args.output.absolute()), 'identity': manifest['identity'],
                      'files': manifest['files'], 'build': manifest['build']}, indent=2))


if __name__ == '__main__':
    main()
