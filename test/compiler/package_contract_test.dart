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
    root = Directory(await root.resolveSymbolicLinks());
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

  for (final source in [
    '''@NAPI(classPolicy: ClassPolicy.value)
class Box<T> { Box(this.value); final T value; }''',
    '''class Pair<A, B> { Pair(this.first, this.value); final A first; final B value; }
@NAPI(classPolicy: ClassPolicy.value) typedef Label<T> = Pair<String, T>;''',
  ]) {
    test(
      'generic value declarations have a dual-target contract: $source',
      () async {
        expect(await compare(source, source), contains('<T>'));
      },
    );
  }

  test('generic value output differences remain incompatible', () async {
    await expectLater(
      compare(
        '@NAPI(classPolicy: ClassPolicy.value) class Box<T> { Box(this.value); final T value; }',
        '@NAPI(classPolicy: ClassPolicy.value) class Box<T> { Box(this.value); final List<T> value; }',
      ),
      throwsA(
        isA<BindingDiagnostic>().having(
          (error) => error.code,
          'code',
          'NAPI_PACKAGE_CONTRACT',
        ),
      ),
    );
  });

  final incompatible = <String, (String, String)>{
    'default': (
      '@NAPI() int run([int n = 1]) => n;',
      '@NAPI() int run([int n = 2]) => n;',
    ),
    'structural actual const type': (
      '@NAPI() bool run([List<int> n = const <Never>[]]) => true;',
      '@NAPI() bool run([List<int> n = const <int>[]]) => true;',
    ),
    'structural map order': (
      "@NAPI() bool run([Map<String,int> n = const {'a':1,'b':2}]) => true;",
      "@NAPI() bool run([Map<String,int> n = const {'b':2,'a':1}]) => true;",
    ),
    'structural signed NaN': (
      '@NAPI() bool run([List<double> n = const [double.nan]]) => true;',
      '@NAPI() bool run([List<double> n = const [-double.nan]]) => true;',
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
    'binary collection sharing despite equal TS declarations': (
      "import 'dart:typed_data'; @NAPI() JsArray<Uint8List> run(JsArray<Uint8List> value) => value;",
      '@NAPI() JsArray<SharedBytes> run(JsArray<SharedBytes> value) => value;',
    ),
    'copied collection integer policy despite equal TS declarations': (
      '@NAPI() JsArray<List<int>> run(JsArray<List<int>> value) => value;',
      '@NAPI() JsArray<List<double>> run(JsArray<List<double>> value) => value;',
    ),
    'copied collection deep sharing despite equal TS declarations': (
      "import 'dart:typed_data'; @NAPI() JsMap<List<int>, Dictionary<Uint8List>> run(JsMap<List<int>, Dictionary<Uint8List>> value) => value;",
      '@NAPI() JsMap<List<int>, Dictionary<SharedBytes>> run(JsMap<List<int>, Dictionary<SharedBytes>> value) => value;',
    ),
    'opaque collection leaf nullability': (
      '@NAPI() JsArray<T> run<T>(JsArray<T> value) => value;',
      '@NAPI() JsArray<T?> run<T>(JsArray<T?> value) => value;',
    ),
    'opaque collection logical parameter order': (
      '@NAPI() JsMap<K,V> run<K,V>(JsMap<K,V> value) => value;',
      '@NAPI() JsMap<V,K> run<K,V>(JsMap<V,K> value) => value;',
    ),
    'copied opaque collection leaf nullability': (
      '@NAPI() JsArray<Dictionary<List<T>>> run<T>(JsArray<Dictionary<List<T>>> value) => value;',
      '@NAPI() JsArray<Dictionary<List<T?>>> run<T>(JsArray<Dictionary<List<T?>>> value) => value;',
    ),
    'copied opaque collection logical parameter order': (
      '@NAPI() JsArray<(List<K>, JsMap<String, V>)> run<K,V>(JsArray<(List<K>, JsMap<String, V>)> value) => value;',
      '@NAPI() JsArray<(List<V>, JsMap<String, K>)> run<K,V>(JsArray<(List<V>, JsMap<String, K>)> value) => value;',
    ),
    'copied reference leaf nullability': (
      '@NAPI() class Item { Item(); } @NAPI() JsArray<List<Item>> run(JsArray<List<Item>> value) => value;',
      '@NAPI() class Item { Item(); } @NAPI() JsArray<List<Item?>> run(JsArray<List<Item?>> value) => value;',
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
      '@NAPI(classPolicy: ClassPolicy.value) class Value { final int n; Value({this.n = 1}); } '
          '@NAPI() int run(Value value) => value.n;',
      '@NAPI(classPolicy: ClassPolicy.value) class Value { final int n; Value({this.n = 2}); } '
          '@NAPI() int run(Value value) => value.n;',
    ),
    'lazy value constructor default': (
      '@NAPI(classPolicy: ClassPolicy.value) class Value { final int n; Value({this.n = 1}); } '
          '@NAPI() JsArray<Value> run() => throw UnimplementedError();',
      '@NAPI(classPolicy: ClassPolicy.value) class Value { final int n; Value({this.n = 2}); } '
          '@NAPI() JsArray<Value> run() => throw UnimplementedError();',
    ),
    'lazy value constructor scalar policy': (
      '@NAPI(classPolicy: ClassPolicy.value) class Value { Value(int source); final int n = 1; } '
          '@NAPI() JsArray<Value> run() => throw UnimplementedError();',
      '@NAPI(classPolicy: ClassPolicy.value) class Value { Value(double source); final int n = 1; } '
          '@NAPI() JsArray<Value> run() => throw UnimplementedError();',
    ),
    'lazy value input availability': (
      '@NAPI(classPolicy: ClassPolicy.value) class Value { Value._(); final int n = 1; } '
          '@NAPI() JsArray<Value> run() => throw UnimplementedError();',
      '@NAPI(classPolicy: ClassPolicy.value) class Value { Value(); final int n = 1; } '
          '@NAPI() JsArray<Value> run() => throw UnimplementedError();',
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
        '@NAPI(classPolicy: ClassPolicy.value) '
        'class Node { final int value; final Node? next; Node(this.value, [this.next]); } '
        '@NAPI() Node run(Node node) => node;';
    expect(await compare(source, source), contains('export type Node'));
  });

  test(
    'unused value input constructors do not affect output contracts',
    () async {
      for (final call in ['', '@NAPI() Value run() => Value(null);']) {
        final declarations = await compare(
          '@NAPI(classPolicy: ClassPolicy.value) class Value { '
              'Value(Object? source); final int n = 1; } $call',
          '@NAPI(classPolicy: ClassPolicy.value) class Value { '
              'Value(DateTime? source); final int n = 1; } $call',
        );
        expect(declarations, contains('export type Value'));
        expect(declarations, isNot(contains('source')));
      }
      expect(
        await compare(
          '@NAPI(classPolicy: ClassPolicy.value) class Value { '
              'Value._(); final int n = 1; } '
              '@NAPI() Value run() => Value._();',
          '@NAPI(classPolicy: ClassPolicy.value) class Value { '
              'Value(Object source); final int n = 1; } '
              '@NAPI() Value run() => Value(1);',
        ),
        contains('export type Value'),
      );
    },
  );

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

  test('copied handle elements share writable declarations in both directions', () async {
    const source =
        '@NAPI() JsMap<List<int>, Dictionary<({int n, bool? flag})>> run('
        'JsMap<List<int>, Dictionary<({int n, bool? flag})>> value) => value;';
    for (final external in [false, true]) {
      final declarations = await compare(source, source, external: external);
      expect(declarations, contains('globalThis.Map<Array<number>,'));
      expect(declarations, isNot(contains('ReadonlyArray')));
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

  test(
    'equivalent const graphs compare evaluated values and record names',
    () async {
      for (final external in [false, true]) {
        await compare(
          '@NAPI() bool run([(List<int>,{int x,int y}) n = (const [1+1],x:3,y:4)]) => true;',
          '@NAPI() bool run([(List<int>,{int x,int y}) n = (const [2],y:4,x:3)]) => true;',
          external: external,
        );
      }
    },
  );

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

  for (final (type, first, second) in [
    ('int', '7', '8'),
    ('Type', 'String', 'int'),
  ]) {
    test('inaccessible defaults compare stored $type values', () async {
      await File('${root.path}/model.dart').writeAsString('''
import 'package:napi/napi.dart';
@NAPI() class Point {
  final $type _value;
  const Point._(this._value);
}
const first = Point._($first);
const second = Point._($second);
''');
      String source(String expression) =>
          '''
import 'model.dart';
export 'model.dart';
const _origin = $expression;
@NAPI() bool run({Point point = _origin}) => true;
''';
      await compare(
        source('true ? first : second'),
        source('false ? second : first'),
      );
      await expectLater(
        compare(
          source('true ? first : second'),
          source('false ? first : second'),
        ),
        throwsA(
          isA<BindingDiagnostic>().having(
            (error) => error.code,
            'code',
            'NAPI_PACKAGE_CONTRACT',
          ),
        ),
      );
    });
  }

  test('copied opaque and nested handle contracts agree across targets', () async {
    const source =
        '@NAPI() JsArray<List<({T payload, JsMap<String,T?> handle})>> run<T>('
        'JsArray<List<({T payload, JsMap<String,T?> handle})>> value) => value;';
    for (final external in [false, true]) {
      final declarations = await compare(source, source, external: external);
      expect(declarations, contains('payload: T'));
      expect(declarations, contains('globalThis.Map<string, T | null>'));
      expect(declarations, isNot(contains('ReadonlyArray')));
    }
  });

  test(
    'stored Type defaults normalize nested runtime-equivalent types',
    () async {
      await File('${root.path}/model.dart').writeAsString('''
import 'dart:async';
import 'package:napi/napi.dart';
typedef Original = (List<Never?>, FutureOr<Object?>);
typedef Normalized = (List<Null>, Object?);
@NAPI() class Metadata {
  final Type _type;
  const Metadata._(this._type);
}
const first = Metadata._(Original);
const second = Metadata._(Normalized);
''');
      String source(String expression) =>
          '''
import 'model.dart';
export 'model.dart';
const _origin = $expression;
@NAPI() bool run({Metadata value = _origin}) => true;
''';
      await compare(
        source('true ? first : second'),
        source('false ? first : second'),
      );
    },
  );

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

  test('stored Type defaults erase extension type representations', () async {
    await File('${root.path}/model.dart').writeAsString('''
import 'package:napi/napi.dart';
extension type Count(int value) {}
@NAPI() class Metadata {
  final Type _type;
  const Metadata._(this._type);
}
const first = Metadata._(Count);
const second = Metadata._(int);
''');
    String source(String expression) =>
        '''
import 'model.dart';
export 'model.dart';
const _origin = $expression;
@NAPI() bool run({Metadata value = _origin}) => true;
''';
    await compare(
      source('true ? first : second'),
      source('false ? first : second'),
    );
  });

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

  test(
    'dual contract mismatch fails before automatic runtime acquisition',
    () async {
      final entry = await File('${root.path}/entry.dart').writeAsString(
        "export 'wasm.dart' if (dart.library.ffi) 'native.dart';",
      );
      await File('${root.path}/wasm.dart').writeAsString(
        "import 'package:napi/napi.dart'; @NAPI() int run() => 1;",
      );
      await File('${root.path}/native.dart').writeAsString(
        "import 'package:napi/napi.dart'; @NAPI() String run() => 'one';",
      );
      final output = Directory('${root.path}/absent/package');
      await HttpOverrides.runZoned(
        () async {
          await expectLater(
            buildPackage(
              library: entry.uri,
              output: output,
              metadata: {'name': 'test-dual', 'version': '0.0.0'},
              packagesPath: packages,
              targets: {BuildTarget.wasm, BuildTarget.native},
            ),
            throwsA(
              isA<BindingDiagnostic>().having(
                (e) => e.code,
                'code',
                'NAPI_PACKAGE_CONTRACT',
              ),
            ),
          );
        },
        createHttpClient: (_) =>
            throw StateError('Unexpected runtime download'),
      );
      expect(await output.parent.exists(), isFalse);
    },
  );

  test(
    'native declarations fail before automatic runtime acquisition',
    () async {
      final entry = await File('${root.path}/entry.dart').writeAsString(
        "import 'package:napi/napi.dart'; @NAPI() Object run() => Object();",
      );
      final output = Directory('${root.path}/absent/package');
      await HttpOverrides.runZoned(
        () async {
          await expectLater(
            buildPackage(
              library: entry.uri,
              output: output,
              metadata: {'name': 'test-native', 'version': '0.0.0'},
              packagesPath: packages,
              target: BuildTarget.native,
            ),
            throwsA(isA<BindingDiagnostic>()),
          );
        },
        createHttpClient: (_) =>
            throw StateError('Unexpected runtime download'),
      );
      expect(await output.parent.exists(), isFalse);
    },
  );
}
