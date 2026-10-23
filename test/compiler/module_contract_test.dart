import 'dart:convert';
import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:napi/src/build/contract.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  final packages = File('.dart_tool/package_config.json').absolute.path;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('napi module contract ');
    root = Directory(await root.resolveSymbolicLinks());
  });
  tearDown(() => root.delete(recursive: true));

  Future<Map<String, Object?>> contract(
    String directory,
    String source, {
    BuildTarget target = BuildTarget.native,
    String filename = 'bindings.dart',
  }) async {
    final entry = File('${root.path}/$directory/$filename');
    await entry.parent.create(recursive: true);
    await entry.writeAsString("import 'package:napi/napi.dart';\n$source");
    final bindings = await readLibraryBindings(
      library: entry.uri,
      packagesPath: packages,
      target: target,
    );
    final List<ReferenceClassShape> classes;
    final List<ValueClassSchema> values;
    if (target == BuildTarget.native) {
      final plan = validateNative(bindings);
      classes = plan.classes.map((c) => c.shape).toList();
      values = plan.valueSchemas;
    } else {
      final analysis = validate(bindings);
      classes = analysis.classes;
      values = analysis.valueSchemas;
    }
    final declarations = emitBindingDeclarations(
      functions: bindings.functions,
      classes: bindings.classes,
      references: classes,
      values: values,
    );
    return createModuleContract(
      bindings,
      classes,
      values,
      declarations,
      packagesPath: packages,
    );
  }

  test('separate native and Wasm builds share one portable contract', () async {
    const source = '''
@NAPI() class Counter { Counter(); int value = 0; }
@NAPI(classPolicy: ClassPolicy.value)
class Value { Value(this.value); final int value; }
@NAPI() int add([int value = 1 + 1]) => value;
''';
    final native = await contract('macos', source);
    expect(native['format'], 1);
    expect(native['exports'], ['add', 'Counter']);
    expect(native['sha256'], matches(RegExp(r'^[a-f0-9]{64}$')));
    expect(await contract('linux', source), native);
    expect(await contract('wasm', source, target: BuildTarget.wasm), native);
  });

  test(
    'defaults and conversion policies remain part of the contract',
    () async {
      for (final (first, second) in [
        (
          '@NAPI() int run([int n = 1]) => n;',
          '@NAPI() int run([int n = 2]) => n;',
        ),
        ('@NAPI() int run(int n) => n;', '@NAPI() double run(double n) => n;'),
        (
          '@NAPI(bigint: true) int run(int n) => n;',
          '@NAPI() BigInt run(BigInt n) => n;',
        ),
      ]) {
        expect(
          (await contract('first', first))['sha256'],
          isNot((await contract('second', second))['sha256']),
        );
      }
    },
  );

  test(
    'reconstructed and omitted object defaults relocate with the source',
    () async {
      for (final source in [
        '''
@NAPI() class Point { const Point(this.value); final int value; }
@NAPI() int run([Point value = const Point(7)]) => value.value;
''',
        '''
class Hidden {}
@NAPI() class Point {
  const Point._(this._value);
  final ({Type type, List<Type> types}) _value;
}
const _origin = Point._((type: Hidden, types: [Hidden]));
@NAPI() bool run({Point value = _origin}) => true;
''',
      ]) {
        expect(
          await contract('macos', source),
          await contract('linux', source),
        );
      }
    },
  );

  test('different default libraries retain distinct identities', () async {
    const source = '''
@NAPI() class Point { const Point(this.value); final int value; }
@NAPI() int run([Point value = const Point(7)]) => value.value;
''';
    expect(
      (await contract('first', source, filename: 'one.dart'))['sha256'],
      isNot((await contract('second', source, filename: 'two.dart'))['sha256']),
    );
  });

  test(
    'uses the analyzed source package config outside the current project',
    () async {
      const model = '''
import 'package:napi/napi.dart';
@NAPI() class Point { const Point(this.value); final int value; }
''';
      Future<Map<String, Object?>> relocated(
        String directory,
        String dependency,
      ) async {
        final dependencyRoot = Directory('${root.path}/$dependency');
        final modelFile = File('${dependencyRoot.path}/lib/model.dart');
        await modelFile.parent.create(recursive: true);
        await modelFile.writeAsString(model);
        final project = Directory('${root.path}/$directory');
        final config = File('${project.path}/.dart_tool/package_config.json');
        await config.parent.create(recursive: true);
        await File('${project.path}/pubspec.yaml')
            .writeAsString('name: fixture_app\nenvironment:\n  sdk: ^3.13.0\n');
        final originalConfig = File(packages);
        final original = jsonDecode(await originalConfig.readAsString()) as Map;
        await config.writeAsString(
          jsonEncode({
            'configVersion': 2,
            'packages': [
              for (final package in original['packages'] as List)
                {
                  ...package as Map,
                  'rootUri': originalConfig.uri
                      .resolve(package['rootUri'] as String)
                      .toString(),
                },
              {
                'name': 'fixture',
                'rootUri': dependencyRoot.uri.toString(),
                'packageUri': 'lib/',
              },
            ],
          }),
        );
        final entry = File('${project.path}/lib/bindings.dart');
        await entry.parent.create(recursive: true);
        await entry.writeAsString('''
import 'package:napi/napi.dart';
import '${modelFile.uri}';
export '${modelFile.uri}';
@NAPI() int run([Point value = const Point(7)]) => value.value;
''');
        Map<String, Object?>? expected;
        for (final packagePath in [config.path, null]) {
          final bindings = await readLibraryBindings(
            library: entry.uri,
            packagesPath: packagePath,
            target: BuildTarget.native,
          );
          expect(bindings.packageConfigPath, config.path);
          final plan = validateNative(bindings);
          final classes = plan.classes.map((c) => c.shape).toList();
          final actual = await createModuleContract(
            bindings,
            classes,
            plan.valueSchemas,
            emitBindingDeclarations(
              functions: bindings.functions,
              classes: bindings.classes,
              references: classes,
              values: plan.valueSchemas,
            ),
            packagesPath: packagePath,
          );
          if (expected != null) expect(actual, expected);
          expected = actual;
        }
        return expected!;
      }

      expect(
        await relocated('macos/project', 'macos/packages/fixture'),
        await relocated('linux/source', 'cache/deep/fixture'),
      );
    },
  );

  test(
    'path-like user strings in private default storage are not normalized',
    () async {
      String source(String value) =>
          '''
@NAPI() class Value { const Value._(this._value); final String _value; }
const _default = Value._('$value');
@NAPI() bool run({Value value = _default}) => true;
''';
      final first = File('${root.path}/first/bindings.dart').uri.toString();
      final second = File('${root.path}/second/bindings.dart').uri.toString();
      expect(
        (await contract('first', source(first)))['sha256'],
        isNot((await contract('second', source(second)))['sha256']),
      );
    },
  );
}
