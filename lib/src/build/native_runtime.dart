import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../compiler/native/platform.dart';
import 'native_bundle.dart';
import 'publish.dart';

typedef NativeRuntimeArchive = ({
  String url,
  String sha256,
  int bytes,
  String manifestSha256,
});

const _runtimeArchives = {
  NativePlatform.macosArm64: (
    url:
        'https://github.com/medz/napi/releases/download/runtime-dart-3.13.5-abi15/'
        'napi-runtime-dart-3.13.5-macos-arm64-abi15-b07f81272d03.zip',
    sha256: 'b07f81272d03682ec2661db28ee2d986e80daf3c81d9a9e16b86a9fc33b4bcb2',
    bytes: 1919213,
    manifestSha256:
        '600733d9dc5df77a81354ee12314310e2f27f9337174b3655e7a16de93f00cfb',
  ),
  NativePlatform.macosX64: (
    url:
        'https://github.com/medz/napi/releases/download/runtime-dart-3.13.5-macos-x64-abi15/'
        'napi-runtime-dart-3.13.5-macos-x64-abi15-1b6f44af6574.zip',
    sha256: '1b6f44af65747f186c3eed234de398d6171d46498c358685e1e97aa7fe8ec005',
    bytes: 2409868,
    manifestSha256:
        '1ea9ddaca3b6aa625ba1b5cc92defeada54455ea39408e383939aaeccacf0a68',
  ),
  NativePlatform.linuxArm64: (
    url:
        'https://github.com/medz/napi/releases/download/runtime-dart-3.13.5-linux-arm64-abi15/'
        'napi-runtime-dart-3.13.5-linux-arm64-abi15-9bfb01fd7f31.zip',
    sha256: '9bfb01fd7f3116338349ae50a622ace0a31ae4fe2ca2a834654eb0a1819d9068',
    bytes: 2323990,
    manifestSha256:
        '16ba5a3c8b5ec22371368097f1db7f1c614037599dea775fd5615b8d11088777',
  ),
  NativePlatform.linuxX64: (
    url:
        'https://github.com/medz/napi/releases/download/runtime-dart-3.13.5-linux-x64-abi15/'
        'napi-runtime-dart-3.13.5-linux-x64-abi15-a695d8aa09f2.zip',
    sha256: 'a695d8aa09f211ad410ce0726c3463e0aaf106305333b65ad3c71e759f4022d4',
    bytes: 2336729,
    manifestSha256:
        'e8997486de1114a4bf1ea0c41d3a8c59f5dd02f0bb7e16f66acdce3e21287cc7',
  ),
};

NativeRuntimeArchive get nativeRuntimeArchive =>
    _runtimeArchives[verifyNativeHost()]!;

const _networkTimeout = Duration(seconds: 30);

/// The whole cache root is an input: output must not enclose its staging files.
Directory nativeRuntimeCacheDirectory() {
  final configured = Platform.environment['NAPI_RUNTIME_CACHE'];
  if (configured != null) {
    if (configured.isEmpty) {
      throw ArgumentError('NAPI_RUNTIME_CACHE must not be empty.');
    }
    return Directory(configured).absolute;
  }
  if (Platform.isWindows) {
    final local = Platform.environment['LOCALAPPDATA'];
    if (local == null || local.isEmpty || !path.isAbsolute(local)) {
      throw StateError(
        'Set NAPI_RUNTIME_CACHE when LOCALAPPDATA is unavailable.',
      );
    }
    return Directory(path.join(local, 'napi', 'Cache'));
  }
  if (Platform.isLinux) {
    final xdg = Platform.environment['XDG_CACHE_HOME'];
    if (xdg != null && xdg.isNotEmpty && path.isAbsolute(xdg)) {
      return Directory(path.join(xdg, 'napi'));
    }
  }
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError('Set NAPI_RUNTIME_CACHE when HOME is unavailable.');
  }
  final base = Directory(home).resolveSymbolicLinksSync();
  return Directory(
    Platform.isLinux
        ? path.join(base, '.cache', 'napi')
        : path.join(base, 'Library', 'Caches', 'napi'),
  );
}

/// Resolve only the bundled, hash-pinned profile. No native code is loaded here.
Future<NativeRuntimeBundle> resolveNativeRuntime({
  Directory? runtime,
  Directory? cache,
  required Directory output,
}) async {
  if (runtime != null) {
    final bundle = await NativeRuntimeBundle.read(runtime);
    bundle.verifyHost();
    return bundle;
  }
  final cacheDirectory = (cache ?? nativeRuntimeCacheDirectory()).absolute;
  await _checkCacheOutput(cacheDirectory, output);
  final lock = nativeRuntimeArchive;
  final entry = Directory(path.join(cacheDirectory.path, lock.sha256));
  if (await _exists(entry.path)) return _readCached(entry, lock);

  await cacheDirectory.create(recursive: true);
  await checkNativePath(cacheDirectory.path);
  final staging = await cacheDirectory.createTemp('.download-');
  try {
    final extractor = Platform.isWindows
        ? path.join(
            Platform.environment['SystemRoot'] ?? r'C:\Windows',
            'System32',
            'WindowsPowerShell',
            'v1.0',
            'powershell.exe',
          )
        : Platform.isLinux
        ? '/usr/bin/unzip'
        : '/usr/bin/ditto';
    if (Platform.isLinux && !await File(extractor).exists()) {
      throw FileSystemException(
        'Cannot extract the native runtime. Install unzip or supply '
        'nativeRuntime explicitly.',
        extractor,
      );
    }
    final archive = File(path.join(staging.path, 'runtime.zip'));
    await _download(archive, lock);
    final extracted = Directory(path.join(staging.path, 'bundle'));
    // These exact ZIP bytes contain six flat regular files, prepared by the
    // maintainer packer. Never extract before both size and SHA-256 match.
    final result = await Process.run(
      extractor,
      Platform.isWindows
          ? [
              '-NoLogo',
              '-NoProfile',
              '-NonInteractive',
              '-Command',
              r'Expand-Archive -LiteralPath $env:NAPI_RUNTIME_ARCHIVE '
                  r'-DestinationPath $env:NAPI_RUNTIME_DIRECTORY -ErrorAction Stop',
            ]
          : Platform.isLinux
          ? ['-q', archive.path, '-d', extracted.path]
          : ['-x', '-k', archive.path, extracted.path],
      includeParentEnvironment: false,
      environment: {
        'LC_ALL': 'C',
        if (Platform.isWindows) ...{
          'SystemRoot': Platform.environment['SystemRoot'] ?? r'C:\Windows',
          'NAPI_RUNTIME_ARCHIVE': archive.path,
          'NAPI_RUNTIME_DIRECTORY': extracted.path,
        },
      },
    );
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Cannot extract the native runtime: ${result.stderr}',
        archive.path,
      );
    }
    final bundle = await NativeRuntimeBundle.read(
      extracted,
      expectedManifestSha256: lock.manifestSha256,
    );
    bundle.verifyHost();
    try {
      publishDirectory(extracted, entry);
    } on FileSystemException {
      if (!await _exists(entry.path)) rethrow;
      // A concurrent publisher is reusable only after complete validation.
    }
    return await _readCached(entry, lock);
  } finally {
    if (await staging.exists()) await staging.delete(recursive: true);
  }
}

Future<NativeRuntimeBundle> _readCached(
  Directory entry,
  NativeRuntimeArchive lock,
) async {
  try {
    final bundle = await NativeRuntimeBundle.read(
      entry,
      expectedManifestSha256: lock.manifestSha256,
    );
    bundle.verifyHost();
    return bundle;
  } catch (error) {
    throw FileSystemException(
      'Invalid native runtime cache. Remove this entry and retry: $error',
      entry.path,
    );
  }
}

Future<void> _download(File destination, NativeRuntimeArchive lock) async {
  final client = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = _networkTimeout;
  final deadline = Timer(_networkTimeout, () => client.close(force: true));
  try {
    var uri = Uri.parse(lock.url);
    for (var redirects = 0; ; redirects++) {
      final request = await client.getUrl(uri).timeout(_networkTimeout);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close().timeout(_networkTimeout);
      if (const [301, 302, 303, 307, 308].contains(response.statusCode)) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.listen((_) {}).cancel();
        if (location == null || redirects == 5) {
          throw const HttpException('Invalid native runtime redirect.');
        }
        uri = uri.resolve(location);
        if (uri.scheme != 'https' ||
            uri.userInfo.isNotEmpty ||
            uri.port != 443 ||
            !const [
              'github.com',
              'release-assets.githubusercontent.com',
            ].contains(uri.host)) {
          throw const HttpException('Unexpected native runtime redirect.');
        }
        continue;
      }
      if (response.statusCode != HttpStatus.ok) {
        throw HttpException(
          'Native runtime download failed (HTTP ${response.statusCode}). '
          'Retry when the asset is available, or supply nativeRuntime explicitly.',
          uri: uri,
        );
      }
      if (response.contentLength != -1 &&
          response.contentLength != lock.bytes) {
        throw const FormatException('Native runtime archive size mismatch.');
      }
      final sink = destination.openWrite();
      // Observe an early disk error immediately; close() below still reports
      // that same failure to the caller after the response is stopped.
      sink.done.ignore();
      var bytes = 0;
      try {
        final hash = await sha256
            .bind(
              response.timeout(_networkTimeout).map((chunk) {
                bytes += chunk.length;
                if (bytes > lock.bytes) {
                  throw const FormatException(
                    'Native runtime archive exceeds its locked size.',
                  );
                }
                sink.add(chunk);
                return chunk;
              }),
            )
            .first;
        if (bytes != lock.bytes || hash.toString() != lock.sha256) {
          throw const FormatException(
            'Native runtime archive integrity mismatch.',
          );
        }
      } finally {
        await sink.close();
      }
      return;
    }
  } finally {
    deadline.cancel();
    client.close(force: true);
  }
}

Future<bool> _exists(String value) async =>
    await FileSystemEntity.type(value, followLinks: false) !=
    FileSystemEntityType.notFound;

Future<void> _checkCacheOutput(Directory cache, Directory output) async {
  final source = path.normalize(cache.absolute.path);
  final target = path.normalize(output.absolute.path);
  await checkNativePath(cache.absolute.path);
  await checkNativePath(output.absolute.path);
  // Neither leaf need exist yet. Conservatively reject case aliases on the
  // supported host before creating a cache that could occupy the output.
  final sourceName = (Platform.isMacOS || Platform.isWindows)
      ? source.toLowerCase()
      : source;
  final targetName = (Platform.isMacOS || Platform.isWindows)
      ? target.toLowerCase()
      : target;
  if (path.equals(sourceName, targetName) ||
      path.isWithin(sourceName, targetName) ||
      path.isWithin(targetName, sourceName) ||
      await _containsExistingPath(source, target) ||
      await _containsExistingPath(target, source)) {
    throw ArgumentError(
      'Native runtime cache and output must not contain one another: $source',
    );
  }
}

Future<bool> _containsExistingPath(String parent, String child) async {
  // A missing leaf can still overlap through a DOS short name or another
  // filesystem alias of its existing ancestor.
  var ancestor = parent;
  while (!await _exists(ancestor)) {
    final next = path.dirname(ancestor);
    if (next == ancestor) return false;
    ancestor = next;
  }
  var current = child;
  while (true) {
    if (await _exists(current) &&
        await FileSystemEntity.identical(ancestor, current)) {
      var source = path.relative(parent, from: ancestor);
      var target = path.relative(child, from: current);
      if (Platform.isMacOS || Platform.isWindows) {
        source = source.toLowerCase();
        target = target.toLowerCase();
      }
      return source == '.' ||
          path.equals(source, target) ||
          path.isWithin(source, target);
    }
    final next = path.dirname(current);
    if (next == current) return false;
    current = next;
  }
}
