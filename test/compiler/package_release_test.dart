import 'dart:convert';
import 'dart:io';

import 'package:napi/build.dart';
import 'package:napi/src/compiler/native/platform.dart';
import 'package:test/test.dart';

import '../support/package_module.dart';
import '../support/process.dart';

void main() {
  late Directory root;
  late Directory output;
  late List<BuiltModule> modules;
  late HttpServer server;
  late Uri registry;
  late File script;
  final documents = <String, Map<String, dynamic>>{};
  final uploads = <String>[];
  String? fail;
  var acceptedThenFailed = false;
  const name = '@test/release-counter';
  const version = '1.0.0';

  PackageRelease release() => PackageRelease(
    modules: modules,
    output: output,
    name: name,
    version: version,
    metadata: {
      'publishConfig': {'registry': registry.toString(), 'access': 'public'},
    },
  );

  Future<ProcessResult> publish([List<String> arguments = const []]) =>
      runProcess(
        Platform.resolvedExecutable,
        [
          '--packages=${File('.dart_tool/package_config.json').absolute.path}',
          script.path,
          'publish',
          ...arguments,
        ],
        workingDirectory: root.path,
        checkExitCode: false,
        timeout: const Duration(minutes: 2),
      );

  setUp(() async {
    root = await Directory(await Directory.systemTemp.resolveSymbolicLinks())
        .createTemp('napi release ');
    output = Directory('${root.path}/release');
    modules = [
      for (final platform in NativePlatform.values)
        await createPackageModule(root, platform, {
          'format': 1,
          'exports': ['Counter'],
          'sha256': '1' * 64,
        }),
    ];
    documents.clear();
    uploads.clear();
    fail = null;
    acceptedThenFailed = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    registry = Uri.parse('http://127.0.0.1:${server.port}/');
    server.listen((request) async {
      final package = Uri.decodeComponent(request.uri.path.substring(1));
      request.response.headers.contentType = ContentType.json;
      if (request.method == 'PUT') {
        uploads.add(package);
        final document = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, dynamic>;
        if (package == fail) {
          if (acceptedThenFailed) documents[package] = document;
          request.response.statusCode = 503;
          request.response.write('{"error":"temporary failure"}');
        } else {
          documents[package] = document;
          request.response.statusCode = 201;
          request.response.write('{"ok":true}');
        }
      } else if (request.method == 'GET' && documents.containsKey(package)) {
        request.response.write(jsonEncode(documents[package]));
      } else {
        request.response.statusCode = 404;
        request.response.write('{"error":"Not found"}');
      }
      await request.response.close();
    });
    // Deliberately invalid credentials, scoped only to this loopback registry.
    await File('${root.path}/.npmrc').writeAsString(
      '//127.0.0.1:${server.port}/:_authToken=test-fixture\nfetch-retries=0\n',
    );
    script = File('${root.path}/release.dart');
    await script.writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';
Future<void> main(List<String> args) => PackageRelease(
  modules: [], output: Directory(${jsonEncode(output.path)}),
  name: '$name', version: '$version',
).run(args);
''');
  });
  tearDown(() async {
    await server.close(force: true);
    await root.delete(recursive: true);
  });

  test(
    'preparation packs all platforms and preserves an earlier preparation',
    () async {
      await release().prepare();
      final marker = File('${output.path}/.napi-release.json');
      final before = await marker.readAsString();
      final record = jsonDecode(before) as Map;
      final packages = record['packages'] as List;
      expect(packages.last['name'], name);
      expect(packages.every((p) => p['version'] == version), isTrue);
      for (final package in packages) {
        expect(
          File('${output.path}/${package['tarball']}').existsSync(),
          isTrue,
        );
        expect(package['integrity'], startsWith('sha512-'));
      }
      expect(uploads, isEmpty);
      await expectLater(release().prepare(), throwsArgumentError);
      expect(await marker.readAsString(), before);
    },
  );

  test('Wasm-only preparation has one publishable package', () async {
    final wasm = await createPackageModule(root, null, {
      'format': 1,
      'exports': ['Counter'],
      'sha256': '1' * 64,
    });
    await PackageRelease(
      modules: [wasm],
      output: output,
      name: name,
      version: version,
      target: BuildTarget.wasm,
      metadata: {
        'publishConfig': {'registry': registry.toString(), 'access': 'public'},
      },
    ).prepare();
    final result = await publish();
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(uploads, [name]);
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'publishes fixed native tarballs before root and resumes a partial failure',
    () async {
      await release().prepare();
      final names = [
        for (final p in NativePlatform.values) '$name-${p.packageId}',
      ]..sort();
      fail = names.last;
      final first = await publish();
      expect(first.exitCode, 1, reason: '${first.stdout}${first.stderr}');
      expect(documents.keys, names.take(names.length - 1));
      expect(first.stderr, contains('Confirmed: ${names.first}'));
      expect(first.stderr, contains('Pending: ${names.last}, $name'));
      fail = null;
      uploads.clear();
      final second = await publish();
      expect(second.exitCode, 0, reason: '${second.stdout}${second.stderr}');
      expect(uploads, [names.last, name]);
      final rootVersion = (documents[name]!['versions'] as Map)[version] as Map;
      expect(rootVersion['optionalDependencies'], {
        for (final n in names) n: version,
      });
      uploads.clear();
      final third = await publish(['--tag', 'another-tag']);
      expect(third.exitCode, 0, reason: '${third.stdout}${third.stderr}');
      expect(uploads, isEmpty);
      expect(documents[name]!['dist-tags'], {'latest': version});
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );

  test(
    'a conflicting existing root stops before uploading any native package',
    () async {
      await release().prepare();
      documents[name] = {
        'name': name,
        'dist-tags': {'latest': version},
        'versions': {
          version: {
            'name': name,
            'version': version,
            'dist': {'integrity': 'sha512-conflict'},
          },
        },
      };
      final result = await publish();
      expect(result.exitCode, 1, reason: '${result.stdout}${result.stderr}');
      expect(result.stderr, contains('Registry integrity differs'));
      expect(uploads, isEmpty);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'a failed response after acceptance is recovered by registry digest',
    () async {
      await release().prepare();
      fail = name;
      acceptedThenFailed = true;
      final result = await publish();
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(documents.keys.last, name);
      expect(uploads.where((n) => n == name), hasLength(1));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('edited prepared bytes are rejected before registry writes', () async {
    await release().prepare();
    final record = jsonDecode(
      await File('${output.path}/.napi-release.json').readAsString(),
    ) as Map;
    final package = (record['packages'] as List).first as Map;
    await File('${output.path}/${package['tarball']}').writeAsString('changed');
    final result = await publish();
    expect(result.exitCode, 1, reason: '${result.stdout}${result.stderr}');
    expect(result.stderr, contains('Prepared tarball changed'));
    expect(uploads, isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
