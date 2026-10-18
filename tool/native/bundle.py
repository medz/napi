#!/usr/bin/env python3
"""Fetch or prepare one reviewed native bundle; never builds or loads native code."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import tempfile
import urllib.parse
import urllib.request
import zipfile

from build import SOURCE_FILES, digest

ROOT = Path(__file__).resolve().parents[2]
MAX_BYTES = 64 * 1024 * 1024
PROFILE = ('sdkVersion', 'sdkRevision', 'platform', 'architecture',
           'minimumOsVersion', 'abi', 'identity')


def no_symlinks(path):
    path = path.absolute()
    for part in [*reversed(path.parents), path]:
        if part.is_symlink():
            raise ValueError(f'Symlinks are not allowed: {part}')
    return path


def regular(path):
    path = no_symlinks(path)
    if not path.is_file():
        raise ValueError(f'Expected a regular file: {path}')
    return path


def bounded_bytes(path, maximum, message):
    with regular(path).open('rb') as source:
        data = source.read(maximum + 1)
    if len(data) > maximum:
        raise ValueError(message)
    return data


def json_file(path):
    return json.loads(bounded_bytes(path, 1024 * 1024, 'Native metadata exceeds its size limit'))


def sha(value):
    return isinstance(value, str) and re.fullmatch('[0-9a-f]{64}', value) is not None


def provenance(manifest, repository):
    if not isinstance(manifest, dict) or not isinstance(manifest.get('build'), dict):
        raise ValueError('Bundle has no build-time provenance; rebuild it')
    proof = manifest['build'].get('provenance', {})
    if not isinstance(proof, dict) or not isinstance(proof.get('producer'), dict):
        raise ValueError('Bundle has no producer provenance; rebuild it')
    producer = proof.get('producer', {})
    files = producer.get('files', {})
    if (proof.get('format') != 1 or not isinstance(files, dict)
            or set(files) != set(SOURCE_FILES)
            or not isinstance(producer.get('dirty'), bool)
            or not isinstance(producer.get('commit'), str)
            or not re.fullmatch('[0-9a-f]{40}', producer['commit'])):
        raise ValueError('Bundle has no complete build-time source provenance; rebuild it')
    for name, expected in files.items():
        if not sha(expected) or digest(regular(repository/name)) != expected:
            raise ValueError(f'Bundle source input differs: {name}; rebuild the bundle')
    compiler = proof.get('compiler', {})
    if (not isinstance(compiler, dict) or not sha(compiler.get('sha256')) or not compiler.get('version')
            or not compiler.get('macosSdkVersion')):
        raise ValueError('Missing native compiler provenance')
    for key in ['headers', 'cacheRecipe']:
        values = proof.get(key, {})
        if not isinstance(values, dict) or not values or not all(sha(v) for v in values.values()):
            raise ValueError(f'Missing native {key} provenance')
    return proof


def verify(bundle, repository, dart):
    manifest_path = regular(bundle/'manifest.json')
    manifest_bytes = bounded_bytes(manifest_path, 1024 * 1024, 'Native metadata exceeds its size limit')
    manifest = json.loads(manifest_bytes)
    provenance(manifest, repository)
    # The application builder remains the sole SDK/profile/payload validator.
    result = subprocess.run([dart, 'run', str(ROOT/'tool/native/verify_bundle.dart'),
                             str(bundle)], cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        raise ValueError(f'Native bundle validation failed:\n{result.stdout}{result.stderr}')
    if bounded_bytes(manifest_path, 1024 * 1024, 'Native metadata exceeds its size limit') != manifest_bytes:
        raise ValueError('Native manifest changed during validation')
    return manifest


def read_lock(path):
    lock = json_file(path)
    if not isinstance(lock, dict):
        raise ValueError('Invalid native bundle lock')
    archive = lock.get('archive', {})
    profile = lock.get('profile', {})
    if (not isinstance(archive, dict) or not isinstance(profile, dict)
            or lock.get('format') != 1 or not sha(lock.get('manifestSha256'))
            or not sha(archive.get('sha256')) or type(archive.get('bytes')) is not int
            or not 0 < archive['bytes'] <= MAX_BYTES
            or set(profile) != set(PROFILE)
            or not isinstance(profile.get('identity'), str)
            or not re.fullmatch('[A-Za-z0-9_.-]{1,200}', profile['identity'])):
        raise ValueError('Invalid native bundle lock; prepare it from an actual built bundle')
    url = archive.get('url')
    if url is not None:
        check_url(url)
    return lock


def check_url(url):
    if not isinstance(url, str):
        raise ValueError('Native release asset URL must be a string')
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != 'https' or parsed.hostname != 'github.com'
            or parsed.username or parsed.password or parsed.port not in [None, 443]
            or parsed.query or parsed.fragment
            or not re.fullmatch('/medz/napi/releases/download/[^/]+/[^/]+', parsed.path)
            or '/latest/' in parsed.path):
        raise ValueError('Use a fixed HTTPS medz/napi release asset URL')


class Redirects(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, message, headers, newurl):
        parsed = urllib.parse.urlsplit(newurl)
        if (parsed.scheme != 'https' or parsed.username or parsed.password
                or parsed.hostname not in ['github.com', 'release-assets.githubusercontent.com']):
            raise ValueError('Unexpected native asset redirect')
        return super().redirect_request(request, fp, code, message, headers, newurl)


def acquire(lock, destination, archive=None):
    expected = lock['archive']
    if archive is None:
        url = expected.get('url')
        if url is None:
            raise ValueError('Native bundle has no published source. Supply --archive for local validation.')
        check_url(url)
        source = urllib.request.build_opener(Redirects()).open(url, timeout=30)
    else:
        source = regular(archive).open('rb')
    count = 0
    actual = hashlib.sha256()
    with source, destination.open('xb') as output:
        while chunk := source.read(1024 * 1024):
            count += len(chunk)
            if count > expected['bytes']:
                raise ValueError('Native archive exceeds its locked size')
            actual.update(chunk)
            output.write(chunk)
    if count != expected['bytes'] or actual.hexdigest() != expected['sha256']:
        raise ValueError('Native archive integrity mismatch')


def unpack(archive, destination, lock):
    with zipfile.ZipFile(archive) as zipped:
        entries = zipped.infolist()
        names = [entry.filename for entry in entries]
        runtime = 'libnapi_runtime_'+lock['profile']['identity']+'.dylib'
        expected = {'manifest.json', 'bridge.node', runtime,
                    'DART_LICENSE', 'DART_AUTHORS', 'NAPI_LICENSE'}
        if len(entries) != 6 or set(names) != expected:
            raise ValueError('Native archive must contain exactly the six flat bundle files')
        if sum(entry.file_size for entry in entries) > MAX_BYTES:
            raise ValueError('Expanded native archive exceeds its size limit')
        for entry in entries:
            mode = entry.external_attr >> 16
            if ('/' in entry.filename or '\\' in entry.filename or entry.is_dir()
                    or stat.S_IFMT(mode) not in [0, stat.S_IFREG]
                    or entry.flag_bits & 1):
                raise ValueError('Native archive contains a non-regular or encrypted file')
        destination.mkdir()
        for entry in entries:
            with zipped.open(entry) as source, (destination/entry.filename).open('xb') as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)


def check_locked(bundle, lock, repository, dart):
    if digest(regular(bundle/'manifest.json')) != lock['manifestSha256']:
        raise ValueError('Native manifest differs from its reviewed lock')
    manifest = verify(bundle, repository, dart)
    if digest(regular(bundle/'manifest.json')) != lock['manifestSha256']:
        raise ValueError('Native manifest differs from its reviewed lock')
    if {key: manifest.get(key) for key in PROFILE} != lock['profile']:
        raise ValueError('Native bundle profile differs from its lock')


def publish(source, destination, dart):
    result = subprocess.run([dart, 'run', str(ROOT/'tool/native/verify_bundle.dart'),
                             str(source), str(destination)], cwd=ROOT,
                            text=True, capture_output=True)
    if result.returncode:
        raise ValueError(f'Native cache publication failed:\n{result.stdout}{result.stderr}')


def fetch(lock_path, cache, dart, archive=None, repository=ROOT):
    lock = read_lock(lock_path)
    cache = no_symlinks(cache)
    cache.mkdir(parents=True, exist_ok=True)
    output = cache/lock['archive']['sha256']
    if os.path.lexists(output):
        check_locked(output, lock, repository, dart)
        return output
    with tempfile.TemporaryDirectory(prefix='.bundle-', dir=cache) as directory:
        stage = Path(directory)
        acquire(lock, stage/'bundle.zip', archive)
        unpack(stage/'bundle.zip', stage/'bundle', lock)
        check_locked(stage/'bundle', lock, repository, dart)
        # Reuse atomic no-replace publication, including a racing empty
        # directory or symlink. There is no replacing-rename fallback.
        try:
            publish(stage/'bundle', output, dart)
        except ValueError:
            if not os.path.lexists(output):
                raise
            check_locked(output, lock, repository, dart)
        check_locked(output, lock, repository, dart)
    return output


def pack(bundle, archive, lock_path, dart, url=None, repository=ROOT):
    archive = no_symlinks(archive)
    lock_path = no_symlinks(lock_path)
    if archive == lock_path:
        raise ValueError('Archive and lock require different output paths')
    if url is not None:
        check_url(url)
    if os.path.lexists(archive) or os.path.lexists(lock_path):
        raise FileExistsError('Archive and lock output must both be new paths')
    manifest_hash = digest(regular(bundle/'manifest.json'))
    manifest = verify(bundle, repository, dart)
    if digest(regular(bundle/'manifest.json')) != manifest_hash:
        raise ValueError('Native manifest changed while preparing its archive')
    names = ['manifest.json', *manifest['files']]
    archive.parent.mkdir(parents=True, exist_ok=True)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.pack-', dir=archive.parent) as directory:
        staged = Path(directory)/'bundle.zip'
        expanded_bytes = 0
        with zipfile.ZipFile(staged, 'x', compression=zipfile.ZIP_DEFLATED) as zipped:
            for name in sorted(names):
                data = bounded_bytes(bundle/name, MAX_BYTES - expanded_bytes,
                                     'Expanded native archive exceeds its size limit')
                expanded_bytes += len(data)
                expected = manifest_hash if name == 'manifest.json' else manifest['files'][name]
                if hashlib.sha256(data).hexdigest() != expected:
                    raise ValueError('Native bundle changed while preparing its archive')
                entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                entry.compress_type = zipfile.ZIP_DEFLATED
                entry.external_attr = (stat.S_IFREG | 0o644) << 16
                zipped.writestr(entry, data)
        if staged.stat().st_size > MAX_BYTES:
            raise ValueError('Native archive exceeds its size limit')
        lock = {'format': 1, 'profile': {key: manifest[key] for key in PROFILE},
                'manifestSha256': manifest_hash,
                'archive': {'url': url, 'sha256': digest(staged), 'bytes': staged.stat().st_size}}
        # Hard-link publication is no-replace; the staging file is on this
        # filesystem. A racing output remains untouched.
        os.link(staged, archive)
        try:
            with lock_path.open('x') as output:
                output.write(json.dumps(lock, indent=2)+'\n')
        except Exception as error:
            # Another process may already have replaced this path. Never
            # unlink it as rollback, even after an inode/stat comparison.
            raise ValueError(f'Archive was published at {archive}; lock publication failed. '
                             'The archive path was preserved.') from error
    return lock


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dart', default='dart')
    commands = parser.add_subparsers(dest='command', required=True)
    get = commands.add_parser('fetch')
    get.add_argument('--lock', type=Path, required=True)
    get.add_argument('--cache', type=Path, default=ROOT/'.dart_tool/native-runtime')
    get.add_argument('--archive', type=Path)
    prepare = commands.add_parser('pack')
    prepare.add_argument('bundle', type=Path)
    prepare.add_argument('--archive', type=Path, required=True)
    prepare.add_argument('--lock', type=Path, required=True)
    prepare.add_argument('--url')
    args = parser.parse_args()
    if args.command == 'fetch':
        print(fetch(args.lock, args.cache, args.dart, args.archive))
    else:
        print(json.dumps(pack(args.bundle, args.archive, args.lock, args.dart, args.url), indent=2))


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile) as error:
        raise SystemExit(str(error)) from error
