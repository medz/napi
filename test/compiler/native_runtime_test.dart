import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:napi/src/build/native_bundle.dart';
import 'package:napi/src/build/native_runtime.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

final _supported = Platform.isMacOS && Abi.current() == Abi.macosArm64;

void main() {
  for (final scenario in [
    'cold-warm',
    'parallel',
    'corrupt',
    'override',
    'redirect',
    'http-error',
    'truncated',
    'oversized',
    'wrong-hash',
    'write-failure',
    'bad-redirect',
    'redirect-loop',
    'overlap',
    'unsupported',
  ]) {
    final needsArchive = const {
      'cold-warm',
      'parallel',
      'corrupt',
      'override',
      'redirect',
    }.contains(scenario);
    final archive = Platform.environment['NAPI_TEST_RUNTIME_ARCHIVE'];
    test(
      'native runtime $scenario',
      () async {
        final root = await Directory(
          await Directory.systemTemp.resolveSymbolicLinks(),
        ).createTemp('napi runtime test ');
        addTearDown(() => root.delete(recursive: true));
        if (needsArchive) {
          expect(
            File(archive!).existsSync(),
            isTrue,
            reason: 'Locked runtime ZIP: $archive',
          );
        }
        await _scenario(scenario, root);
      },
      skip: scenario == 'unsupported'
          ? (_supported ? 'Requires an unsupported native host.' : false)
          : !_supported
          ? 'Automatic downloads currently support macOS arm64 only.'
          : needsArchive && archive == null
          ? 'Set NAPI_TEST_RUNTIME_ARCHIVE to the published locked ZIP.'
          : false,
      timeout: const Timeout(Duration(seconds: 60)),
    );
  }
}

Future<void> _scenario(String scenario, Directory root) async {
  final cache = Directory('${root.path}/cache');
  final output = Directory('${root.path}/output');
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  final urls = <Uri>[];
  final overrides = _LocalDownload(server.port, urls);
  server.listen((request) async {
    final response = request.response;
    if (scenario == 'http-error') {
      response.statusCode = HttpStatus.serviceUnavailable;
    } else if (scenario == 'bad-redirect' ||
        scenario == 'redirect-loop' ||
        (scenario == 'redirect' && urls.length == 1)) {
      response.statusCode = HttpStatus.found;
      response.headers.set(
        HttpHeaders.locationHeader,
        scenario == 'bad-redirect'
            ? 'http://example.com/runtime.zip'
            : scenario == 'redirect-loop'
            ? nativeRuntimeArchiveUrl
            : 'https://release-assets.githubusercontent.com/locked.zip?token=test',
      );
    } else if (scenario == 'truncated') {
      response.add([1, 2, 3]);
    } else if (scenario == 'oversized' ||
        scenario == 'wrong-hash' ||
        scenario == 'write-failure') {
      if (scenario == 'write-failure') {
        final staging = (await cache.list().toList()).single;
        await Directory('${staging.path}/runtime.zip').create();
      }
      response.add(
        List<int>.filled(
          nativeRuntimeArchiveBytes + (scenario == 'oversized' ? 1 : 0),
          0,
        ),
      );
    } else {
      if (scenario == 'parallel') {
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      final archive = File(Platform.environment['NAPI_TEST_RUNTIME_ARCHIVE']!);
      response.contentLength = await archive.length();
      await response.addStream(archive.openRead());
    }
    await response.close();
  });
  try {
    await HttpOverrides.runWithHttpOverrides(() async {
      Future<NativeRuntimeBundle> resolve() =>
          resolveNativeRuntime(output: output, cache: cache);
      if (scenario == 'unsupported') {
        await expectLater(resolve(), throwsA(isA<SdkCompatibilityException>()));
        expect(urls, isEmpty);
        expect(await cache.exists(), isFalse);
        return;
      }
      if (scenario == 'overlap') {
        for (final target in [
          cache,
          Directory('${cache.path}/package'),
          root,
          Directory('${root.path}/CACHE'),
          Directory('${root.path}/CACHE/package'),
        ]) {
          await expectLater(
            resolveNativeRuntime(output: target, cache: cache),
            throwsArgumentError,
          );
        }
        expect(urls, isEmpty);
        expect(await cache.exists(), isFalse);
        return;
      }
      if (const {
        'http-error',
        'truncated',
        'oversized',
        'wrong-hash',
        'bad-redirect',
        'redirect-loop',
        'write-failure',
      }.contains(scenario)) {
        await expectLater(
          resolve(),
          scenario == 'write-failure'
              ? throwsA(isA<FileSystemException>())
              : throwsA(anyOf(isA<FormatException>(), isA<HttpException>())),
        );
        expect(await cache.list().toList(), isEmpty);
        expect(urls.length, scenario == 'redirect-loop' ? 6 : 1);
        return;
      }
      final bundles = scenario == 'parallel'
          ? await Future.wait([resolve(), resolve()])
          : [await resolve()];
      final bundle = bundles.first;
      expect(
        bundle.directory.path,
        '${cache.path}/$nativeRuntimeArchiveSha256',
      );
      expect(urls.first.toString(), nativeRuntimeArchiveUrl);
      for (final other in bundles) {
        expect(other.directory.path, bundle.directory.path);
        expect(other.hashes, bundle.hashes);
      }
      expect(await cache.list().length, 1);
      final requests = urls.length;
      // Offline reuse must never even construct a network client.
      await HttpOverrides.runWithHttpOverrides(() async {
        if (scenario == 'corrupt') {
          final bridge = File('${bundle.directory.path}/bridge.node');
          await bridge.writeAsString('corrupt cached input');
          await expectLater(resolve(), throwsA(isA<FileSystemException>()));
          expect(await bridge.readAsString(), 'corrupt cached input');
        } else if (scenario == 'override') {
          final explicit = await bundle.directory.rename(
            '${root.path}/explicit',
          );
          await cache.delete();
          final selected = await resolveNativeRuntime(
            runtime: explicit,
            cache: cache,
            output: output,
          );
          expect(selected.directory.path, explicit.path);
          expect(await cache.exists(), isFalse);
        } else {
          expect((await resolve()).directory.path, bundle.directory.path);
        }
      }, _NoDownload());
      expect(urls.length, requests);
      if (scenario == 'redirect') {
        expect(urls.length, 2);
        expect(urls.last.host, 'release-assets.githubusercontent.com');
      }
    }, overrides);
  } finally {
    await server.close(force: true);
  }
}

final class _NoDownload extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      throw StateError('Unexpected network access');
}

final class _LocalDownload extends HttpOverrides {
  final int port;
  final List<Uri> urls;
  _LocalDownload(this.port, this.urls);
  @override
  HttpClient createHttpClient(SecurityContext? context) =>
      _LocalClient(super.createHttpClient(context), port, urls);
}

final class _LocalClient implements HttpClient {
  final HttpClient client;
  final int port;
  final List<Uri> urls;
  _LocalClient(this.client, this.port, this.urls);
  @override
  set autoUncompress(bool value) => client.autoUncompress = value;
  @override
  set connectionTimeout(Duration? value) => client.connectionTimeout = value;
  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    urls.add(url);
    return client.getUrl(Uri.http('127.0.0.1:$port', '/runtime.zip'));
  }

  @override
  void close({bool force = false}) => client.close(force: force);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
