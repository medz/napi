import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

void main() {
  test('fresh consumer executes an unchanged dependency through external selections', () async {
    final root = await Directory.systemTemp.createTemp(
      'napi external consumer ',
    );
    addTearDown(() => root.delete(recursive: true));
    final dependency = await Directory('${root.path}/third_party/lib')
        .create(recursive: true);
    const thirdPartySource = '''
import 'package:external_primitives/primitives.dart' as self;
import 'package:external_primitives/src/defaults.dart' as defaults;

/// Add two integers from an ordinary package.
int add(int left, int right) => left + right;
const _answer = defaults.answer;
int optional([int value = _answer]) => value;
int named(int base, {required int? value, int extra = _answer}) => base + (value ?? 0) + extra;
String echoText(String value) => value;
int integer(int value) => value;
class Resource { int value = 42; }
int callCount = 0;
int incrementViaSelf() => ++self.callCount;
int currentCallCount() => callCount;
''';
    const thirdPartyManifest = '''
name: external_primitives
environment:
  sdk: ^3.13.5
''';
    final dependencySource = File('${dependency.path}/primitives.dart');
    final dependencyManifest = File('${dependency.parent.path}/pubspec.yaml');
    final dependencyDefaults = File('${dependency.path}/src/defaults.dart');
    const thirdPartyDefaults = 'const answer = 6 * 7;\n';
    await dependencySource.writeAsString(thirdPartySource);
    await dependencyManifest.writeAsString(thirdPartyManifest);
    await dependencyDefaults.parent.create();
    await dependencyDefaults.writeAsString(thirdPartyDefaults);
    final consumer = await Directory('${root.path}/consumer').create();
    await File('${consumer.path}/pubspec.yaml').writeAsString('''
name: external_binding_consumer
environment:
  sdk: ^3.13.5
dependencies:
  external_primitives:
    path: ../third_party
  napi:
    path: ${jsonEncode(Directory.current.path)}
''');
    await File('${consumer.path}/build.dart').writeAsString('''
import 'dart:io';
import 'package:napi/build.dart';

Future<void> main(List<String> arguments) async {
  final useDefaultPackages = arguments.contains('--default-packages');
  final library = Uri.parse('package:external_primitives/primitives.dart');
  final packages = File('.dart_tool/package_config.json').absolute.path;
  final built = await buildLibrary(
    library: library,
    output: Directory(useDefaultPackages ? '../external output' : 'output'),
    packagesPath: useDefaultPackages ? null : packages,
    external: const ExternalLibrary([
      ExternalFunction('add', config: NAPI(name: 'sum')),
      ExternalFunction('optional'),
      ExternalFunction('named'),
      ExternalFunction('echoText'),
      ExternalFunction('integer', config: NAPI(bigint: true)),
      ExternalFunction('incrementViaSelf'),
      ExternalFunction('currentCallCount'),
      ExternalClass('Resource'),
    ]),
  );
  if (!built.wasm.existsSync() || built.sdkVersion != '3.13.5') {
    throw StateError('Missing output or unexpected compiler');
  }
  try {
    await buildLibrary(
      library: library,
      output: Directory('unsupported'),
      packagesPath: packages,
      external: const ExternalLibrary([
        ExternalClass('Resource', config: NAPI(
          classPolicy: ClassPolicy.value,
          valueConstructor: 'new',
          valueFields: {'missing': 'value'},
        )),
      ]),
    );
    throw StateError('Invalid value construction must fail before publishing output');
  } on BindingDiagnostic catch (error) {
    if (error.code != 'NAPI_VALUE' || Directory('unsupported').existsSync()) {
      rethrow;
    }
  }
}
''');
    for (final arguments in [
      ['pub', 'get', '--offline'],
      ['analyze', '--fatal-infos'],
      ['run', 'build.dart'],
      ['run', 'build.dart', '--default-packages'],
    ]) {
      await _run(Platform.resolvedExecutable, arguments, consumer);
    }
    await File('${consumer.path}/check.mjs').writeAsString('''
import { strict as assert } from 'node:assert';
import { sum, optional, named, echoText, integer, incrementViaSelf, currentCallCount, Resource } from './output/module.wasm';
const resource = new Resource();
assert.equal(resource.value, 42);
resource.value = 43;
assert.equal(resource.value, 43);
assert.equal(currentCallCount(), 0);
assert.equal(incrementViaSelf(), 1);
assert.equal(currentCallCount(), 1, 'package self-import shares the selected library state');
assert.equal(incrementViaSelf(), 2);
assert.equal(currentCallCount(), 2);
assert.equal(sum(40, 2), 42);
assert.equal(optional(), 42);
assert.equal(optional(undefined), 42);
assert.equal(optional(0), 0);
assert.equal(named(1, {value: null}), 43);
assert.equal(named(1, {value: 0, extra: undefined}), 43);
assert.throws(() => named(1, {value: undefined}), TypeError);
assert.throws(() => sum(1.5, 2), RangeError);
assert.equal(integer(9007199254740993n), 9007199254740993n);
assert.equal(echoText('Dart \\ud800 \\udfff \\ud83d\\ude80'), 'Dart \\ud800 \\udfff \\ud83d\\ude80');
''');
    await _run('node', ['check.mjs'], consumer);
    await File('${consumer.path}/check_default_packages.mjs').writeAsString(
      (await File('${consumer.path}/check.mjs').readAsString()).replaceFirst(
        './output/module.wasm',
        '../external output/module.wasm',
      ),
    );
    await _run('node', ['check_default_packages.mjs'], consumer);
    await File('${consumer.path}/consumer.mts').writeAsString('''
import { sum, optional, named, echoText, integer, Resource } from './output/module.wasm';
const resource: Resource = new Resource();
resource.value = 43;
const answer: number = sum(40, 2);
const defaultValue: number = optional(undefined);
const namedValue: number = named(1, {value: null});
const text: string = echoText('hello');
const precise: bigint = integer(9007199254740993n);
// @ts-expect-error The external rename keeps scalar types.
sum(40n, 2n);
// @ts-expect-error Required named arguments remain required.
named(1, {});
// @ts-expect-error Bigint policy is shared with annotated functions.
integer(42);
void [answer, defaultValue, namedValue, text, precise];
''');
    final tsc =
        Platform.environment['NAPI_TSC'] ??
        '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
    expect(
      File(tsc).existsSync(),
      isTrue,
      reason: 'TypeScript is required for external binding conformance.',
    );
    for (final mode in ['NodeNext', 'Bundler']) {
      await _run('node', [
        tsc,
        '--ignoreConfig',
        '--strict',
        '--exactOptionalPropertyTypes',
        '--noEmit',
        '--target',
        'ES2022',
        '--module',
        mode == 'NodeNext' ? 'NodeNext' : 'ESNext',
        '--moduleResolution',
        mode,
        '--allowArbitraryExtensions',
        'consumer.mts',
      ], consumer);
    }
    expect(await dependencySource.readAsString(), thirdPartySource);
    expect(await dependencyManifest.readAsString(), thirdPartyManifest);
    expect(await dependencyDefaults.readAsString(), thirdPartyDefaults);
    expect(
      await dependency.parent
          .list()
          .map((e) => e.uri.pathSegments.where((s) => s.isNotEmpty).last)
          .toList(),
      unorderedEquals(['lib', 'pubspec.yaml']),
    );
  }, timeout: const Timeout(Duration(minutes: 3)));
}

Future<void> _run(
  String command,
  List<String> arguments,
  Directory directory,
) async {
  final result = await Process.run(
    command,
    arguments,
    workingDirectory: directory.path,
  );
  expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
}
