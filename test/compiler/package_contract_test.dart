import 'dart:io';

import 'package:napi/build.dart';
import 'package:napi/src/build/build.dart' show readLibraryBindings;
import 'package:napi/src/build/contract.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

void main() {
  late Directory root;
  final packages = File('.dart_tool/package_config.json').absolute.path;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('napi package contract ');
  });
  tearDown(() => root.delete(recursive: true));

  Future<String> compare(
    String wasm,
    String native, {
    bool external = false,
    String nativeName = 'run',
  }) async {
    final entry = File('${root.path}/entry.dart');
    await entry.writeAsString(
      "export 'wasm.dart' if (dart.library.ffi) 'native.dart';",
    );
    for (final item in {'wasm': wasm, 'native': native}.entries) {
      await File('${root.path}/${item.key}.dart')
          .writeAsString("import 'package:napi/napi.dart';\n${item.value}");
    }
    final selections = external
        ? ExternalLibrary([ExternalFunction('run')])
        : null;
    final a = await readLibraryBindings(
      library: entry.uri,
      packagesPath: packages,
      external: selections,
    );
    final b = await readLibraryBindings(
      library: entry.uri,
      packagesPath: packages,
      external: external
          ? ExternalLibrary([
              ExternalFunction(nativeName, config: const NAPI(name: 'run')),
            ])
          : null,
      target: BuildTarget.native,
    );
    final declarations = validatePackageContracts(a, b);
    expect(emitNativeDeclarations(validateNative(b)), declarations);
    return declarations;
  }

  test('one emitter accepts target-specific implementations and evaluated defaults', () async {
    for (final external in [false, true]) {
      final types = await compare(
        '@NAPI() int run([int n = 1 + 1]) => n;',
        '@NAPI() int run([int n = 2]) => n + 10;',
        external: external,
      );
      expect(types, contains('run: (n?: number) => number'));
    }
  });

  final incompatible = <String, (String, String)>{
    'default': (
      '@NAPI() int run([int n = 1]) => n;',
      '@NAPI() int run([int n = 2]) => n;',
    ),
    'signed zero default': (
      '@NAPI() double run([double n = -0.0]) => n;',
      '@NAPI() double run([double n = 0.0]) => n;',
    ),
    'integer policy despite equal TS number': (
      '@NAPI() int run(int n) => n;',
      '@NAPI() double run(double n) => n;',
    ),
    'bounded bigint despite equal TS bigint': (
      '@NAPI(bigint: true) int run(int n) => n;',
      '@NAPI() BigInt run(BigInt n) => n;',
    ),
    'required presence': (
      '@NAPI() int run(int? n) => n ?? 0;',
      '@NAPI() int run([int? n]) => n ?? 0;',
    ),
    'callback policy': (
      '@NAPI() int run(int Function(int) callback) => callback(1);',
      '@NAPI() int run(double Function(double) callback) => callback(1).toInt();',
    ),
    'JavaScript array handle versus snapshot': (
      '@NAPI() JsArray<int> run(JsArray<int> value) => value;',
      '@NAPI() List<int> run(List<int> value) => value;',
    ),
    'JavaScript map handle versus snapshot': (
      '@NAPI() JsMap<String, int> run(JsMap<String, int> value) => value;',
      '@NAPI() Map<String, int> run(Map<String, int> value) => value;',
    ),
    'JavaScript handle integer policy': (
      '@NAPI() JsArray<int> run(JsArray<int> value) => value;',
      '@NAPI() JsArray<double> run(JsArray<double> value) => value;',
    ),
    'JavaScript handle bounded bigint': (
      '@NAPI(bigint: true) JsArray<int> run(JsArray<int> value) => value;',
      '@NAPI() JsArray<BigInt> run(JsArray<BigInt> value) => value;',
    ),
    'opaque collection leaf nullability': (
      '@NAPI() JsArray<T> run<T>(JsArray<T> value) => value;',
      '@NAPI() JsArray<T?> run<T>(JsArray<T?> value) => value;',
    ),
    'opaque collection logical parameter order': (
      '@NAPI() JsMap<K,V> run<K,V>(JsMap<K,V> value) => value;',
      '@NAPI() JsMap<V,K> run<K,V>(JsMap<V,K> value) => value;',
    ),
    'cleanup ownership despite equal Promise declarations': (
      "@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') "
          'class Box { Box(); Future<void> close() async {} }',
      '@NAPI() class Box { Box(); Future<void> close() async {} }',
    ),
    'cleanup mapping': (
      "@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') "
          'class Box { Box(); Future<void> close() async {} Future<void> stop() async {} }',
      "@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'stop') "
          'class Box { Box(); Future<void> close() async {} Future<void> stop() async {} }',
    ),
    'value constructor default': (
      '@NAPI(classPolicy: ClassPolicy.value, valueConstructor: "new") class Value { final int n; Value({this.n = 1}); } '
          '@NAPI() int run(Value value) => value.n;',
      '@NAPI(classPolicy: ClassPolicy.value, valueConstructor: "new") class Value { final int n; Value({this.n = 2}); } '
          '@NAPI() int run(Value value) => value.n;',
    ),
    'exported value scalar policy without a call': (
      '@NAPI(classPolicy: ClassPolicy.value) class Value { final int n = 1; }',
      '@NAPI(classPolicy: ClassPolicy.value) class Value { final double n = 1; }',
    ),
    'empty opaque ancestor permutation': (
      '@NAPI() class Base<A, B> {} @NAPI() class Child<X, Y> extends Base<X, Y> {}',
      '@NAPI() class Base<A, B> {} @NAPI() class Child<X, Y> extends Base<Y, X> {}',
    ),
    'empty opaque interface permutation': (
      '@NAPI() class Base<A, B> {} @NAPI() class Child<X, Y> implements Base<X, Y> {}',
      '@NAPI() class Base<A, B> {} @NAPI() class Child<X, Y> implements Base<Y, X> {}',
    ),
    'export names': ('@NAPI() int run() => 1;', '@NAPI() int changed() => 1;'),
  };
  for (final item in incompatible.entries) {
    test('rejects target-specific ${item.key}', () async {
      await expectLater(
        compare(item.value.$1, item.value.$2),
        throwsA(
          isA<BindingDiagnostic>().having(
            (e) => e.code,
            'diagnostic',
            'NAPI_PACKAGE_CONTRACT',
          ),
        ),
      );
    });
  }

  test('recursive value conversions compare finitely', () async {
    const source =
        '@NAPI(classPolicy: ClassPolicy.value, valueConstructor: "new") '
        'class Node { final int value; final Node? next; Node(this.value, [this.next]); } '
        '@NAPI() Node run(Node node) => node;';
    expect(await compare(source, source), contains('export type Node'));
  });

  test('JavaScript handles share canonical declarations in both backends', () async {
    const source =
        '@NAPI() JsMap<String, int?>? run(JsMap<String, int?>? value) => value;';
    for (final external in [false, true]) {
      expect(
        await compare(source, source, external: external),
        contains('globalThis.Map<string, number | null> | null'),
      );
    }
  });

  test('equivalent omitted defaults compare by their Dart value', () async {
    for (final external in [false, true]) {
      for (final (type, left, right) in [
        ('int?', '', ' = null'),
        ('double', ' = 1', ' = 1.0'),
        ('double', ' = double.nan', ' = 0.0 / 0.0'),
      ]) {
        await compare(
          '@NAPI() $type run([$type n$left]) => n;',
          '@NAPI() $type run([$type n$right]) => n;',
          external: external,
        );
      }
    }
  });

  test('opaque collection public contracts agree across targets', () async {
    const source =
        '@NAPI() JsMap<String,T> run<T>(JsMap<String,T> value) => value;';
    for (final external in [false, true]) {
      expect(
        await compare(source, source, external: external),
        contains('globalThis.Map<string, T>'),
      );
    }
  });

  test(
    'native call paths use native validation for source and external IR',
    () async {
      for (final external in [false, true]) {
        expect(
          await compare(
            '@NAPI() int run(int n) => n;',
            "@NAPI(name: 'run') int delete(int n) => n;",
            external: external,
            nativeName: 'delete',
          ),
          contains('run(n: number): number;'),
        );
      }
    },
  );

  test(
    'public cleanup remains equal after private implementation renaming',
    () async {
      String source(String name) =>
          "@NAPI(classPolicy: ClassPolicy.resource, cleanup: '$name') "
          "class Box { Box(); @NAPI(name: 'close') void $name() {} }";
      expect(
        await compare(source('finishWasm'), source('finishNative')),
        contains('close(): globalThis.Promise<void>'),
      );
    },
  );

  test('reference view target equivalence permits consistent private renaming', () async {
    String source(String name) =>
        "@NAPI() abstract class A { A._(); @NAPI(name: 'read') int $name(); } "
        "@NAPI() abstract class B { B._(); @NAPI(name: 'read') int $name(); }";
    await compare(source('read'), source('different'));
  });

  for (final getterSetter in [false, true]) {
    test('rejects different composite ${getterSetter ? 'accessor' : 'method'} targets', () async {
      final a = getterSetter ? 'int get read;' : 'int read();';
      final b = getterSetter ? 'set read(int value);' : 'int read();';
      final other = getterSetter
          ? 'set different(int value);'
          : 'int different();';
      await expectLater(
        compare(
          '@NAPI() abstract class A { A._(); $a } @NAPI() abstract class B { B._(); $b }',
          "@NAPI() abstract class A { A._(); $a } @NAPI() abstract class B { B._(); @NAPI(name: 'read') $other }",
        ),
        throwsA(
          isA<BindingDiagnostic>().having(
            (e) => e.code,
            'diagnostic',
            'NAPI_PACKAGE_CONTRACT',
          ),
        ),
      );
    });
  }

  test('rejects different concrete alias composition groups', () async {
    await expectLater(
      compare(
        'class Box<T> { Box(); } '
            '@NAPI() typedef IntBox = Box<int>; '
            '@NAPI() typedef StringBox = Box<String>;',
        'class A<T> { A(); } class B<T> { B(); } '
            '@NAPI() typedef IntBox = A<int>; '
            '@NAPI() typedef StringBox = B<String>;',
      ),
      throwsA(
        isA<BindingDiagnostic>().having(
          (e) => e.code,
          'diagnostic',
          'NAPI_PACKAGE_CONTRACT',
        ),
      ),
    );
  });

  test('public reference aliases do not compare private origins', () async {
    final declarations = await compare(
      "@NAPI(name: 'Box') class WasmBox { WasmBox(); int value = 1; } "
          '@NAPI() WasmBox run(WasmBox value) => value;',
      "@NAPI(name: 'Box') class NativeBox { NativeBox(); int value = 2; } "
          '@NAPI() NativeBox run(NativeBox value) => value;',
    );
    expect(declarations, contains('export declare class Box'));
    expect(declarations, isNot(contains('WasmBox')));
    expect(declarations, isNot(contains('NativeBox')));
  });

  test('different declaration order is explicitly rejected', () async {
    await expectLater(
      compare(
        '@NAPI() class A { A(); } @NAPI() class B { B(); }',
        '@NAPI() class B { B(); } @NAPI() class A { A(); }',
      ),
      throwsA(
        isA<BindingDiagnostic>().having(
          (e) => e.code,
          'diagnostic',
          'NAPI_PACKAGE_CONTRACT',
        ),
      ),
    );
  });

  test(
    'native-only export names do not pass through Wasm validation',
    () async {
      final file = File('${root.path}/native.dart');
      await file.writeAsString('''
import 'package:napi/napi.dart';
@NAPI(name: 'clear') void eval() {}
@NAPI(name: 'callback') int arguments(int Function(int) fn) => fn(1);
@NAPI(name: 'wasm_custom') int ordinary(int value) => value;
''');
      final module = await readLibraryBindings(
        library: file.uri,
        packagesPath: packages,
        target: BuildTarget.native,
      );
      final declarations = emitNativeDeclarations(validateNative(module));
      expect(declarations, contains('clear(): void;'));
      expect(declarations, contains('const callback:'));
      expect(declarations, contains('wasm_custom(value: number): number;'));
    },
  );

  test(
    'dual target configuration fails before source or output creation',
    () async {
      for (final targets in [
        <BuildTarget>{},
        {BuildTarget.native},
        {BuildTarget.wasm, BuildTarget.native},
      ]) {
        await expectLater(
          buildPackage(
            library: File('${root.path}/missing.dart').uri,
            output: Directory('${root.path}/parent/out'),
            metadata: {'name': 'test-dual', 'version': '0.0.0'},
            targets: targets,
          ),
          throwsArgumentError,
        );
        expect(await root.list().length, 0);
      }
    },
  );
}
