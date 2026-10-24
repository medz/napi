import 'dart:async';
import 'dart:io';

import 'package:napi/src/build/native_bundle.dart';
import 'package:napi/src/build/native_runtime.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';
import 'package:path/path.dart' as path;

final _supported = _supportsNativeRuntime();

bool _supportsNativeRuntime() {
  try {
    verifyNativeHost();
    return true;
  } on SdkCompatibilityException {
    return false;
  }
}

void main() {
  test('native runtime cache honors host cache conventions', () async {
    final root = await Directory(
      await Directory.systemTemp.resolveSymbolicLinks(),
    ).createTemp('napi cache paths ');
    addTearDown(() => root.delete(recursive: true));
    final home = await Directory('${root.path}/home').create();
    final script = await File('${root.path}/cache.dart').writeAsString('''
import 'package:napi/src/build/native_runtime.dart';
void main() => print(nativeRuntimeCacheDirectory().path);
''');
    final environment = {
      'HOME': home.path,
      if (Platform.isWindows) 'LOCALAPPDATA': home.path,
    };
    final fallback = Platform.isWindows
        ? '${home.path}/napi/Cache'
        : Platform.isLinux
        ? '${home.path}/.cache/napi'
        : '${home.path}/Library/Caches/napi';
    final cases = <({Map<String, String> environment, String? expected})>[
      (environment: environment, expected: fallback),
      (
        environment: {
          ...environment,
          'NAPI_RUNTIME_CACHE': '${root.path}/override',
          'XDG_CACHE_HOME': '${root.path}/xdg',
        },
        expected: '${root.path}/override',
      ),
      (
        environment: {...environment, 'XDG_CACHE_HOME': '${root.path}/xdg'},
        expected: Platform.isLinux ? '${root.path}/xdg/napi' : fallback,
      ),
      if (Platform.isLinux) ...[
        (
          environment: {'HOME': home.path, 'XDG_CACHE_HOME': 'relative'},
          expected: fallback,
        ),
        (
          environment: {'XDG_CACHE_HOME': '${root.path}/xdg'},
          expected: '${root.path}/xdg/napi',
        ),
      ],
      (environment: {...environment, 'NAPI_RUNTIME_CACHE': ''}, expected: null),
    ];
    for (final entry in cases) {
      final result = await Process.run(
        Platform.resolvedExecutable,
        [
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          script.path,
        ],
        includeParentEnvironment: false,
        environment: entry.environment,
      );
      if (entry.expected == null) {
        expect(result.exitCode, isNot(0));
        expect(result.stderr, contains('NAPI_RUNTIME_CACHE must not be empty'));
      } else {
        expect(result.exitCode, 0, reason: '${result.stderr}');
        expect(
          path.normalize((result.stdout as String).trim()),
          path.normalize(entry.expected!),
        );
      }
    }
  }, skip: !_supported);
  test('native runtime rejects overlap through an aliased ancestor', () async {
    final root = await Directory(
      await Directory.systemTemp.resolveSymbolicLinks(),
    ).createTemp('napi runtime aliases ');
    addTearDown(() => root.delete(recursive: true));
    final ancestor = await Directory(
      path.join(root.path, Platform.isWindows ? 'long directory name' : 'café'),
    ).create();
    final String alias;
    if (Platform.isWindows) {
      await File(path.join(root.path, 'short-path.cmd')).writeAsString(
        '@echo off\r\nfor %%I in ("%NAPI_TEST_LONG_PATH%") do @echo %%~sI\r\n',
      );
      final result = await Process.run(
        'cmd.exe',
        ['/d', '/c', 'short-path.cmd'],
        workingDirectory: root.path,
        environment: {'NAPI_TEST_LONG_PATH': ancestor.path},
      );
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      alias = result.stdout.toString().trim();
      if (path.basename(alias).toLowerCase() ==
          path.basename(ancestor.path).toLowerCase()) {
        markTestSkipped('DOS short names are disabled on this volume.');
        return;
      }
    } else {
      alias = path.join(root.path, 'cafe\u0301');
      if (!await Directory(alias).exists()) {
        markTestSkipped('This volume distinguishes Unicode normalization.');
        return;
      }
    }
    expect(await FileSystemEntity.identical(ancestor.path, alias), isTrue);
    await HttpOverrides.runWithHttpOverrides(() async {
      for (final (cacheParent, outputParent) in [
        (ancestor.path, alias),
        (alias, ancestor.path),
      ]) {
        for (final (cacheSuffix, outputSuffix) in [
          ('output', 'output'),
          ('output/cache', 'output'),
          ('output', 'output/cache'),
        ]) {
          final cache = Directory(path.join(cacheParent, cacheSuffix));
          final output = Directory(path.join(outputParent, outputSuffix));
          expect(await cache.exists(), isFalse);
          expect(await output.exists(), isFalse);
          await expectLater(
            resolveNativeRuntime(cache: cache, output: output),
            throwsArgumentError,
          );
          expect(await ancestor.list().toList(), isEmpty);
        }
      }
    }, _NoDownload());
  }, skip: !_supported || !(Platform.isMacOS || Platform.isWindows));
  for (final scenario in [
    'cold-warm',
    'foreign-cache',
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
      'foreign-cache',
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
          ? 'Requires a supported native host.'
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
            ? nativeRuntimeArchive.url
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
          nativeRuntimeArchive.bytes + (scenario == 'oversized' ? 1 : 0),
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
          if (Platform.isMacOS || Platform.isWindows) ...[
            Directory('${root.path}/CACHE'),
            Directory('${root.path}/CACHE/package'),
          ],
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
      final foreign = Directory('${cache.path}/${'0' * 64}');
      if (scenario == 'foreign-cache') {
        await foreign.create(recursive: true);
        await File('${foreign.path}/manifest.json')
            .writeAsString('other runtime');
      }
      final bundles = scenario == 'parallel'
          ? await Future.wait([resolve(), resolve()])
          : [await resolve()];
      final bundle = bundles.first;
      expect(
        bundle.directory.path,
        path.join(cache.path, nativeRuntimeArchive.sha256),
      );
      expect(urls.first.toString(), nativeRuntimeArchive.url);
      expect(bundle.platform, verifyNativeHost());
      for (final other in bundles) {
        expect(other.directory.path, bundle.directory.path);
        expect(other.hashes, bundle.hashes);
      }
      expect(await cache.list().length, scenario == 'foreign-cache' ? 2 : 1);
      if (scenario == 'foreign-cache') {
        expect(
          await File('${foreign.path}/manifest.json').readAsString(),
          'other runtime',
        );
      }
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
