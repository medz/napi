import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../compiler/native/platform.dart';
import '../compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'native_bundle.dart';
import 'publish.dart';

const nativeRuntimeArchiveUrl =
    'https://github.com/medz/napi/releases/download/runtime-dart-3.13.5-abi15/'
    'napi-runtime-dart-3.13.5-macos-arm64-abi15-b07f81272d03.zip';
const nativeRuntimeArchiveSha256 =
    'b07f81272d03682ec2661db28ee2d986e80daf3c81d9a9e16b86a9fc33b4bcb2';
const nativeRuntimeArchiveBytes = 1919213;
const nativeRuntimeManifestSha256 =
    '600733d9dc5df77a81354ee12314310e2f27f9337174b3655e7a16de93f00cfb';
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
  final home = Platform.environment['HOME'];
  if (home == null || home.isEmpty) {
    throw StateError('Set NAPI_RUNTIME_CACHE when HOME is unavailable.');
  }
  final base = Directory(home).resolveSymbolicLinksSync();
  return Directory(path.join(base, 'Library', 'Caches', 'napi'));
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
  if (verifyNativeHost() != NativePlatform.macosArm64) {
    throw const SdkCompatibilityException(
      'NAPI_NATIVE_RUNTIME',
      'Linux native builds require a local runtime bundle. '
          'Pass nativeRuntime to buildLibrary or buildPackage.',
    );
  }
  final cacheDirectory = (cache ?? nativeRuntimeCacheDirectory()).absolute;
  await _checkCacheOutput(cacheDirectory, output);
  final entry = Directory(
    path.join(cacheDirectory.path, nativeRuntimeArchiveSha256),
  );
  if (await _exists(entry.path)) return _readCached(entry);

  await cacheDirectory.create(recursive: true);
  await checkNativePath(cacheDirectory.path);
  final staging = await cacheDirectory.createTemp('.download-');
  try {
    final archive = File(path.join(staging.path, 'runtime.zip'));
    await _download(archive);
    final extracted = Directory(path.join(staging.path, 'bundle'));
    // These exact ZIP bytes contain six flat regular files, prepared by the
    // maintainer packer. Never extract before both size and SHA-256 match.
    final result = await Process.run(
      '/usr/bin/ditto',
      ['-x', '-k', archive.path, extracted.path],
      includeParentEnvironment: false,
      environment: const {'LC_ALL': 'C'},
    );
    if (result.exitCode != 0) {
      throw FileSystemException(
        'Cannot extract the native runtime: ${result.stderr}',
        archive.path,
      );
    }
    await NativeRuntimeBundle.read(
      extracted,
      expectedManifestSha256: nativeRuntimeManifestSha256,
    );
    try {
      publishDirectory(extracted, entry);
    } on FileSystemException {
      if (!await _exists(entry.path)) rethrow;
      // A concurrent publisher is reusable only after complete validation.
    }
    return await _readCached(entry);
  } finally {
    if (await staging.exists()) await staging.delete(recursive: true);
  }
}

Future<NativeRuntimeBundle> _readCached(Directory entry) async {
  try {
    return await NativeRuntimeBundle.read(
      entry,
      expectedManifestSha256: nativeRuntimeManifestSha256,
    );
  } catch (error) {
    throw FileSystemException(
      'Invalid native runtime cache. Remove this entry and retry: $error',
      entry.path,
    );
  }
}

Future<void> _download(File destination) async {
  final client = HttpClient()
    ..autoUncompress = false
    ..connectionTimeout = _networkTimeout;
  final deadline = Timer(_networkTimeout, () => client.close(force: true));
  try {
    var uri = Uri.parse(nativeRuntimeArchiveUrl);
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
          response.contentLength != nativeRuntimeArchiveBytes) {
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
                if (bytes > nativeRuntimeArchiveBytes) {
                  throw const FormatException(
                    'Native runtime archive exceeds its locked size.',
                  );
                }
                sink.add(chunk);
                return chunk;
              }),
            )
            .first;
        if (bytes != nativeRuntimeArchiveBytes ||
            hash.toString() != nativeRuntimeArchiveSha256) {
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
  final sourceName = Platform.isMacOS ? source.toLowerCase() : source;
  final targetName = Platform.isMacOS ? target.toLowerCase() : target;
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
  if (!await _exists(parent)) return false;
  var current = child;
  while (true) {
    if (await _exists(current) &&
        await FileSystemEntity.identical(parent, current)) {
      return true;
    }
    final next = path.dirname(current);
    if (next == current) return false;
    current = next;
  }
}
