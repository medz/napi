#!/usr/bin/env python3
"""Prepare the pinned Product VM objects for this supported native host."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import urllib.request

from build import host_profile, MINIMUM_OS

ROOT = Path(__file__).resolve().parents[2]
SDK_REVISION = '04bcd1036cdc799ac6564988f159ee454d42c822'
CLANG_REVISION = 'deb6854eec93529b2bd30178d400ad2ee7665cd4'
SYSROOT_REVISION = 'fa7a5a9710540f30ff98ae48b62f2cdf72ed2acd'
GN_REVISION = 'b8becbd4f7979f63ab3542524b2b4d8db2ce3b52'
NINJA_VERSION = 'version:3@1.13.2.chromium.4'
# Official depot_tools cipd_client_version and cipd_client_version.digests.
CIPD_REVISION = '7a04966073ee0fee4501e766b6200e98faae91b1'
CIPD_SHA256 = {
    'linux-amd64': '11a383b48744870d96365192b92992650b695eedf3a745615948b8d6561834ed',
    'mac-amd64': '3ce5c8167cd82fcd89cb7e8229f08673ea76f66f61e4dc205a808f781075794f',
    'mac-arm64': '4ac2fa37f23486d249a2d71ff5084b6207c00cfa55928dad577fe99f0376ab71',
}
GN_ARGS = '''is_debug=false is_release=false is_product=true dart_debug=false
dart_runtime_mode="release" dart_use_compressed_pointers=false
dart_use_crashpad=false dart_dynamic_modules=false
is_asan=false is_lsan=false is_msan=false is_tsan=false is_ubsan=false is_hwasan=false'''


def configuration():
    profile = host_profile()
    cpu = profile.rsplit('-', 1)[1]
    target = 'linux' if profile == 'linux-x64' else 'mac'
    args = (f'target_os="{target}" host_cpu="{cpu}" target_cpu="{cpu}" '
            f'dart_target_arch="{cpu}" is_clang=true\n' + GN_ARGS)
    args += '\ndart_sysroot="debian"' if target == 'linux' else f'\nmac_sdk_min="{MINIMUM_OS}"'
    return profile, cpu, target, args


def run(command, *, cwd=None, input=None, capture=False):
    print(shlex.join(map(str, command)), flush=True)
    result = subprocess.run(command, cwd=cwd, input=input, text=True,
                            stdout=subprocess.PIPE if capture else None, check=True)
    return result.stdout.strip() if capture else None


def cache_key():
    profile, _, target, args = configuration()
    digest = hashlib.sha256((SDK_REVISION + '\n' + args).encode())
    if target == 'mac':
        digest.update(subprocess.check_output(['xcrun', '--show-sdk-build-version']))
    for source in [Path(__file__), ROOT/'native/runtime/BUILD.gn']:
        digest.update(source.read_bytes())
    return 'napi-vm-' + profile + '-' + digest.hexdigest()


def checkout(directory, url, revision, patterns=None):
    if (directory/'.git').exists():
        actual = run(['git', '-C', directory, 'rev-parse', 'HEAD'], capture=True)
        if actual != revision:
            raise ValueError(f'Unexpected source revision in {directory}: {actual}')
        run(['git', '-C', directory, 'diff', '--quiet', 'HEAD', '--'])
        return
    directory.mkdir(parents=True, exist_ok=True)
    run(['git', 'init', directory])
    run(['git', '-C', directory, 'remote', 'add', 'origin', url])
    run(['git', '-C', directory, 'config', 'remote.origin.promisor', 'true'])
    run(['git', '-C', directory, 'config', 'remote.origin.partialclonefilter', 'blob:none'])
    run(['git', '-C', directory, 'fetch', '--depth=1', '--filter=blob:none', 'origin', revision])
    if callable(patterns):
        source = run(['git', '-C', directory, 'show', f'{revision}:gen/sources.gni'], capture=True)
        patterns = patterns(source)
    if patterns:
        run(['git', '-C', directory, 'sparse-checkout', 'set', '--no-cone', '--stdin'],
            input='\n'.join(patterns) + '\n')
    run(['git', '-C', directory, '-c', 'advice.detachedHead=false', 'checkout', '--detach', revision])


def boringssl_sources(source):
    # Match the runtime lists consumed by the SDK's third_party/boringssl/BUILD.gn.
    names = ['bcm_sources', 'bcm_internal_headers', 'bcm_sources_asm',
             'crypto_sources', 'crypto_headers', 'crypto_internal_headers', 'crypto_sources_asm',
             'ssl_sources', 'ssl_headers', 'ssl_internal_headers',
             'pki_sources', 'pki_headers', 'pki_internal_headers']
    paths = {'LICENSE', 'gen/sources.gni'}
    for name in names:
        match = re.search(r'^' + name + r' = \[(.*?)\]', source, re.M | re.S)
        if match is None:
            raise ValueError(f'Missing BoringSSL source list: {name}')
        paths.update(re.findall(r'"([^"\n]+)"', match[1]))
    return ['/' + path for path in sorted(paths)]


def cipd_client(directory, platform):
    client = directory/'cipd'
    expected = CIPD_SHA256[platform]
    if client.exists():
        if hashlib.sha256(client.read_bytes()).hexdigest() != expected:
            raise ValueError(f'CIPD client checksum mismatch: {client}')
        return client
    url = (f'https://chrome-infra-packages.appspot.com/client?platform={platform}'
           f'&version=git_revision:{CIPD_REVISION}')
    with tempfile.NamedTemporaryFile(dir=directory) as temporary:
        with urllib.request.urlopen(url, timeout=60) as response:
            digest = hashlib.sha256()
            size = 0
            while block := response.read(1024 * 1024):
                size += len(block)
                if size > 64 * 1024 * 1024:
                    raise ValueError('CIPD client exceeds its size limit')
                digest.update(block)
                temporary.write(block)
        if digest.hexdigest() != expected:
            raise ValueError('CIPD client checksum mismatch')
        temporary.flush()
        shutil.copyfile(temporary.name, client)
    client.chmod(0o755)
    return client


def copy_runtime(sdk):
    runtime = sdk/'runtime/napi'
    marker = runtime/'.napi-vm-cache'
    if runtime.exists():
        legacy = runtime/'.napi-linux-cache'
        owned = ((marker.is_file() and marker.read_text() == 'napi-vm-cache\n') or
                 (legacy.is_file() and legacy.read_text() == 'napi-linux-cache\n'))
        if not owned:
            raise ValueError(f'Refusing to overwrite an existing SDK customization: {runtime}')
    else:
        runtime.mkdir()
        marker.write_text('napi-vm-cache\n')
    for source in (ROOT/'native/runtime').iterdir():
        if source.is_file():
            target = runtime/source.name
            if not target.exists() or target.read_bytes() != source.read_bytes():
                shutil.copyfile(source, target)


def prepare(directory, jobs):
    _, cpu, target, args = configuration()
    cipd_platform = target + '-' + ('amd64' if cpu == 'x64' else cpu)
    directory.mkdir(parents=True, exist_ok=True)
    sdk = directory/'sdk'
    checkout(sdk, 'https://github.com/dart-lang/sdk.git', SDK_REVISION,
             ['/*', '!/*/', '/runtime/', '/sdk/', '/tools/', '/build/',
              '/build_overrides/', '/buildtools/', '/third_party/', '/utils/'])
    checkout(sdk/'third_party/boringssl/src', 'https://boringssl.googlesource.com/boringssl.git',
             '2e508c973d634b3aa51b71db5062bc6b096e5031', boringssl_sources)
    checkout(sdk/'third_party/icu', 'https://chromium.googlesource.com/chromium/deps/icu.git',
             'a86a32e67b8d1384b33f8fa48c83a6079b86f8cd',
             ['/*', '!/*/', '/source/', '!/source/*/', '/source/common/', '/source/stubdata/'])
    checkout(sdk/'third_party/zlib', 'https://chromium.googlesource.com/chromium/src/third_party/zlib.git',
             '3008c4b3a06bd65392c31db8846000a21e3d03c5')
    checkout(sdk/'third_party/perfetto/src', 'https://chromium.googlesource.com/external/github.com/google/perfetto',
             '13ce0c9e13b0940d2476cd0cff2301708a9a2e2b', ['*.gn', '*.gni', '*.py', '/LICENSE'])
    ensure = directory/'tools.ensure'
    ensure.write_text(f'''@Subdir buildtools
gn/gn/{cipd_platform} git_revision:{GN_REVISION}
@Subdir buildtools/ninja
infra/3pp/tools/ninja/{cipd_platform} {NINJA_VERSION}
@Subdir buildtools/{target}-{cpu}/clang
fuchsia/third_party/clang/{cipd_platform} git_revision:{CLANG_REVISION}
''')
    if target == 'linux':
        with ensure.open('a') as output:
            output.write(f'''@Subdir buildtools/sysroot/linux
fuchsia/third_party/sysroot/linux git_revision:{SYSROOT_REVISION}
''')
    run([cipd_client(directory, cipd_platform), 'ensure', '-root', sdk, '-ensure-file', ensure])
    # Normally generated by gclient from the pinned DEPS gclient_gn_args.
    (sdk/'build/config/gclient_args.gni').write_text('build_devtools_from_sources = false\n')
    copy_runtime(sdk)
    cache = sdk/('out' if target == 'linux' else 'xcodebuild')/('Product'+cpu.upper())
    run([sdk/'buildtools/gn', 'gen', cache, '--root-target=//runtime/napi:napi_runtime',
         '--args=' + args], cwd=sdk)
    # Compile the shared VM/IO dependency closure, not the unused intermediate .so.
    run([sdk/'buildtools/ninja/ninja', '-C', cache, '-j', str(jobs),
         f'clang_{cpu}_shared/phony/runtime/napi/napi_runtime_set'])
    print(f'SDK source: {sdk}\nVM cache: {cache}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=ROOT/'.dart_tool/native-vm')
    parser.add_argument('--jobs', type=int, default=min(os.cpu_count() or 1, 4))
    parser.add_argument('--cache-key', action='store_true')
    args = parser.parse_args()
    if args.cache_key:
        print(cache_key())
        return
    if args.jobs < 1:
        parser.error('--jobs must be positive')
    prepare(args.directory.resolve(), args.jobs)


if __name__ == '__main__':
    main()
