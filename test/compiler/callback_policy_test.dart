import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/js/boundary.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-callback-policy-');
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<BindingModule> read(String text) async {
    final file = File('${directory.path}/entry.dart');
    await file.writeAsString("import 'package:napi/napi.dart';\n$text");
    return AnnotationFrontend(packagesPath: _packages).read(file.uri);
  }

  test('direct callbacks use typed children and callable bindings', () async {
    final module = await read('''
typedef Transform = List<(int, String?)>? Function((bool, List<int?>) source);
@NAPI() int run(Transform callback) => callback((true, [1]))?.length ?? 0;
@NAPI(bigint: true) int big(int Function(int, List<int>) callback) => callback(1, [2]);
@NAPI() int notify(void Function() callback) { callback(); return 1; }
''');
    final wasm = lower(validate(module));
    final native = validateNative(module);
    for (final inputs in [
      wasm.functions.map((f) => f.inputs.single).toList(),
      native.functions.map((f) => f.inputs.single).toList(),
    ]) {
      final transform = inputs[0] as CallbackConversion;
      expect(transform.inputs.single, isA<RecordConversion>());
      expect(transform.output, isA<ListConversion>());
      expect(
        transform.dartType,
        'List<(int, String?)>? Function((bool, List<int?>))',
      );
      expect(transform.jsType, 'function');
      expect(transform.returnsFuture, isFalse);
      expect(transform.inputs.single.context, 'callback argument 1');
      expect(transform.output!.context, 'callback result');
      expect(
        conversionGraph([transform]).whereType<ScalarConversion>(),
        hasLength(4),
      );
      final big = inputs[1] as CallbackConversion;
      expect(big.inputs.first.typescriptType, 'bigint');
      expect(big.inputs.last.typescriptType, 'Array<bigint>');
      expect(big.output!.typescriptType, 'bigint');
      final notify = inputs[2] as CallbackConversion;
      expect(notify.output, isNull);
      expect(notify.dartType, 'void Function()');
      expect(notify.typescriptType, '() => void');
    }
    expect(
      wasm.functions.every(
        (f) => f.representation == ExportRepresentation.callableGlobal,
      ),
      isTrue,
    );
  });

  test('callback Future results carry their payload independently of the outer call', () async {
    final module = await read('''
typedef Later<T> = Future<T>;
typedef Transform = Later<List<(int, String?)>?> Function((bool, List<int?>) source);
@NAPI() Future<int> run(Transform callback) async => (await callback((true, [1])))?.length ?? 0;
@NAPI(bigint: true) Future<int> big(Future<int> Function(int, List<int>) callback) => callback(1, [2]);
@NAPI() Future<void> notify(Future<void> Function() callback) => callback();
@NAPI() int accept(Future<int> Function(int) callback) => 1;
@NAPI() Future<int> synchronous(int Function(int) callback) async => callback(1);
@NAPI() Future<void> syncVoid(void Function() callback) async { callback(); }
@NAPI() class Calls {
  Calls();
  Future<int> run(Future<int> Function(int) callback) => callback(1);
}
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') class Resource {
  Resource();
  void close(void Function() callback) { callback(); }
}
''');
    final wasm = lower(validate(module));
    final native = validateNative(module);
    for (final inputs in [
      wasm.functions.map((f) => f.inputs.single).toList(),
      native.functions.map((f) => f.inputs.single).toList(),
    ]) {
      final transform = inputs[0] as CallbackConversion;
      expect(transform.returnsFuture, isTrue);
      expect(transform.output, isA<ListConversion>());
      expect(transform.output!.nullable, isTrue);
      expect(
        transform.dartType,
        'Future<List<(int, String?)>?> Function((bool, List<int?>))',
      );
      expect(
        transform.typescriptType,
        '(arg0: { \$1: boolean; \$2: Array<number | null> }) => globalThis.Promise<ReadonlyArray<{ \$1: number; \$2: string | null }> | null>',
      );
      final big = inputs[1] as CallbackConversion;
      expect(big.returnsFuture, isTrue);
      expect(big.output!.typescriptType, 'bigint');
      expect(
        big.typescriptType,
        '(arg0: bigint, arg1: Array<bigint>) => globalThis.Promise<bigint>',
      );
      final notify = inputs[2] as CallbackConversion;
      expect(notify.returnsFuture, isTrue);
      expect(notify.output, isNull);
      expect(notify.dartType, 'Future<void> Function()');
      expect(notify.typescriptType, '() => globalThis.Promise<void>');
      expect((inputs[3] as CallbackConversion).returnsFuture, isTrue);
      expect((inputs[4] as CallbackConversion).returnsFuture, isFalse);
      expect((inputs[5] as CallbackConversion).returnsFuture, isFalse);
    }
    for (final code in [
      emitDeclarations(wasm),
      emitNativeDeclarations(native),
    ]) {
      expect(code, contains('callback: () => globalThis.Promise<void>'));
      expect(
        code,
        contains(
          'run(callback: (arg0: number) => globalThis.Promise<number>): globalThis.Promise<number>',
        ),
      );
      expect(
        code,
        contains('close(callback: () => void): globalThis.Promise<void>'),
      );
    }
    expect(wasm.functions[3].returnsFuture, isFalse);
    expect(native.functions[3].returnsFuture, isFalse);
    expect(wasm.functions[4].returnsFuture, isTrue);
    expect(native.functions[4].returnsFuture, isTrue);
  });

  test(
    'callback cache signatures describe conversion semantics across call sites',
    () async {
      final module = await read('''
@NAPI() int first(int Function(int named) callback) => 1;
@NAPI() int renamed(int Function(int other) value) => 1;
@NAPI() int nullable([int Function(int)? callback]) => 1;
@NAPI() int nullableInput(int Function(int?) callback) => 1;
@NAPI() int nullableOutput(int? Function(int) callback) => 1;
@NAPI() int floating(int Function(double) callback) => 1;
@NAPI(bigint: true) int wide(int Function(int) callback) => 1;
@NAPI() int bigInteger(BigInt Function(BigInt) callback) => 1;
@NAPI() int asyncResult(Future<int> Function(int) callback) => 1;
@NAPI() int list(int Function(List<int>) callback) => 1;
@NAPI() int listElement(int Function(List<int?>) callback) => 1;
@NAPI() int listNullable(int Function(List<int>?) callback) => 1;
@NAPI() int record(int Function(({int a, String b})) callback) => 1;
@NAPI() int recordOrder(int Function(({String b, int a})) renamed) => 1;
@NAPI() int recordName(int Function(({int a, String c})) callback) => 1;
@NAPI() int recordOutput(({int a, String b}) Function(int) callback) => 1;
''');
      final wasm = lower(validate(module));
      final native = validateNative(module);
      final keys = <String>[];
      for (final inputs in [
        wasm.functions.map((f) => f.inputs.single).toList(),
        native.functions.map((f) => f.inputs.single).toList(),
      ]) {
        final callbacks = inputs.cast<CallbackConversion>();
        expect(callbacks[0].signatureKey, callbacks[1].signatureKey);
        expect(callbacks[0].signatureKey, callbacks[2].signatureKey);
        expect(callbacks[12].signatureKey, callbacks[13].signatureKey);
        expect({
          for (final i in [0, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15])
            callbacks[i].signatureKey,
        }, hasLength(13));
        if (keys.isEmpty) {
          keys.addAll(callbacks.map((callback) => callback.signatureKey));
        } else {
          expect(callbacks.map((callback) => callback.signatureKey), keys);
        }
      }
    },
  );

  test(
    'binary callback signatures preserve copy and sharing policies',
    () async {
      final module = await read('''
import 'dart:typed_data';
typedef Bytes = Uint8List;
@NAPI() int bytes(Uint8List Function(Uint8List) callback) => 1;
@NAPI(bigint: true) int alias(Bytes Function(Bytes other) renamed) => 1;
@NAPI() int optional([Uint8List Function(Uint8List)? callback]) => 1;
@NAPI() int nullableInput(Uint8List Function(Uint8List?) callback) => 1;
@NAPI() int nullableOutput(Uint8List? Function(Uint8List) callback) => 1;
@NAPI() int buffer(ByteBuffer Function(ByteBuffer) callback) => 1;
@NAPI() int shared(SharedBytes Function(SharedBytes) callback) => 1;
@NAPI() int nullableShared(SharedBytes? Function(SharedBytes?) callback) => 1;
@NAPI() int future(Future<Uint8List?> Function(List<(ByteBuffer?, SharedBytes?)>) callback) => 1;
''');
      final wasm = lower(validate(module));
      final native = validateNative(module);
      List<String>? signatures;
      for (final inputs in [
        wasm.functions.map((function) => function.inputs.single),
        native.functions.map((function) => function.inputs.single),
      ]) {
        final callbacks = inputs.cast<CallbackConversion>().toList();
        final keys = callbacks
            .map((callback) => callback.signatureKey)
            .toList();
        expect(keys[0], keys[1]);
        expect(keys[0], keys[2]);
        expect(keys.toSet(), hasLength(7));
        expect(callbacks[0].inputs.single, isA<BinaryConversion>());
        expect(callbacks[5].inputs.single, isA<BinaryConversion>());
        expect(callbacks[6].inputs.single, isA<SharedBytesConversion>());
        expect(callbacks.last.inputs.single, isA<ListConversion>());
        expect(callbacks.last.returnsFuture, isTrue);
        expect(callbacks.last.output!.nullable, isTrue);
        if (signatures == null) {
          signatures = keys;
        } else {
          expect(keys, signatures);
        }
      }
      expect(emitDeclarations(wasm), emitNativeDeclarations(native));
    },
  );

  test(
    'callback handles preserve element policies and enclosing opaque types',
    () async {
      final module = await read('''
@NAPI() int first(JsArray<int> Function(JsArray<int>) callback) => 1;
@NAPI() int renamed(JsArray<int> Function(JsArray<int> other) value) => 1;
@NAPI() int nullableInput(JsArray<int> Function(JsArray<int>?) callback) => 1;
@NAPI() int nullableElement(JsArray<int?> Function(JsArray<int?>) callback) => 1;
@NAPI(bigint: true) int wide(JsArray<int> Function(JsArray<int>) callback) => 1;
@NAPI() int map(JsMap<String,int> Function(JsMap<String,int>) callback) => 1;
@NAPI() int opaque<T>(JsArray<T> Function(JsArray<T>) callback) => 1;
@NAPI() int other<U>(JsArray<U> Function(JsArray<U>) callback) => 1;
@NAPI() int nullableOpaque<T>(JsArray<T?> Function(JsArray<T?>) callback) => 1;
@NAPI() int future<T>(Future<List<(JsArray<T>?, JsMap<String,T>)>> Function(List<JsArray<T>>) callback) => 1;
@NAPI() class Calls<T> {
  Calls();
  int run(JsMap<String,T> Function(JsArray<T>) callback) => 1;
}
''');
      final wasm = lower(validate(module));
      final native = validateNative(module);
      for (final conversions in [
        wasm.functions.map((f) => f.inputs.single),
        native.functions.map((f) => f.inputs.single),
      ]) {
        final callbacks = conversions.cast<CallbackConversion>().toList();
        expect(callbacks[0].inputs.single, isA<JsCollectionConversion>());
        expect(callbacks[0].signatureKey, callbacks[1].signatureKey);
        expect(callbacks[6].signatureKey, callbacks[7].signatureKey);
        expect({
          for (final i in [0, 2, 3, 4, 5, 6, 8, 9]) callbacks[i].signatureKey,
        }, hasLength(8));
        expect(
          callbacks[6].dartType,
          'napi.JsArray<_NapiHostValue> Function(napi.JsArray<_NapiHostValue>)',
        );
        expect(
          callbacks[9].typescriptType,
          contains('globalThis.Promise<ReadonlyArray<'),
        );
        expect(
          callbacks[9].typescriptType,
          contains('globalThis.Array<T> | null'),
        );
      }
      expect(emitDeclarations(wasm), emitNativeDeclarations(native));
      expect(emitDeclarations(wasm), contains('globalThis.Map<string, T>'));
      expect(emitDart(wasm), contains('_writeJsCollection(c0,'));
      expect(
        emitDart(wasm),
        contains('c0 == null ? null : _writeJsCollection(c0,'),
      );
      expect(emitDart(wasm), contains('defer: true)'));
      expect(emitBoundary(wasm), contains(r'const $jcPolicies ='));
      expect(
        emitDart(wasm),
        isNot(contains('external WasmExternRef _boxOpaque')),
      );

      // With no structural or direct-handle export, callback results still need
      // their native reader definitions and the Wasm handle carrier.
      final direct = BindingModule(
        source: module.source,
        functions: [module.functions.first],
      );
      final nativeSource = emitNativeDart(validateNative(direct));
      expect(nativeSource, contains('final class _NativeReadState'));
      expect(
        nativeSource,
        matches(r'napi\.JsArray<int> _readNativeValueRoot\d+\('),
      );
      expect(
        emitDart(lower(validate(direct))),
        contains('final class _NapiHostValue'),
      );
    },
  );

  test(
    'outer calls retain presence, defaults and selected class behavior',
    () async {
      final module = await read('''
@NAPI() int optional([int Function(int)? callback]) => callback?.call(1) ?? 0;
@NAPI() int named({required int Function(int) callback, int Function(int)? fallback = null}) => callback(1);
@NAPI() class Calls {
  Calls(void Function() initialize) { initialize(); }
  Calls.named(void Function() initialize) { initialize(); }
  void Function()? _saved;
  set saved(void Function() callback) { _saved = callback; }
  int run(int Function(int value) callback) => callback(1);
}
@NAPI() class Child extends Calls {
  Child(void Function() initialize) : super(initialize);
  @override int run(int Function(int renamed) callback) => callback(2);
}
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') class Resource {
  Resource();
  int run(int Function(int) callback) => callback(1);
  void close() {}
}
''');
      final wasm = lower(validate(module));
      final native = validateNative(module);
      final optional = wasm.functions.first;
      expect(optional.parameters.single.presence, ParameterPresence.optional);
      expect(optional.inputs.single.dartType, 'int Function(int)?');
      expect(
        optional.inputs.single.typescriptType,
        '((arg0: number) => number) | null',
      );
      expect(
        native.classes.first.members.any(
          (m) =>
              m.kind == NativeCallKind.setter &&
              m.inputs.single is CallbackConversion,
        ),
        isTrue,
      );
      for (final code in [
        emitDeclarations(wasm),
        emitNativeDeclarations(native),
      ]) {
        expect(code, contains('callback?: ((arg0: number) => number) | null'));
        expect(
          code,
          contains(
            'options: { callback: (arg0: number) => number; fallback?: ((arg0: number) => number) | null | undefined }',
          ),
        );
        expect(code, contains('constructor(initialize: () => void);'));
        expect(code, contains('set saved(callback: () => void);'));
        expect(code, contains('static named(initialize: () => void): Calls;'));
      }
    },
  );

  test(
    'callback values share ordinary conversions and finite cache keys',
    () async {
      final module = await read('''
@NAPI() class Box { Box(); }
@NAPI() class Other { Other(); }
@NAPI(classPolicy: ClassPolicy.value) class Value {
  Value(this.n, {this.next, this.step = 7});
  final int n;
  final Value? next;
  final int step;
}
@NAPI(classPolicy: ClassPolicy.value) class Projection {
  Projection._();
  final int n = 1;
}
@NAPI() int value(Value Function(Value) callback) => 1;
@NAPI() int valueAlias(Value Function(Value other) renamed) => 1;
@NAPI(bigint: true) int wide(Value Function(Value) callback) => 1;
@NAPI() int nullable(Value? Function(Value?) callback) => 1;
@NAPI() int reference(Box Function(Box) callback) => 1;
@NAPI() int other(Other Function(Other) callback) => 1;
@NAPI() int map(Map<Box, List<Value?>> Function(Map<Box, List<Value?>>) callback) => 1;
@NAPI() int dictionary(Dictionary<Value> Function(Dictionary<Value>) callback) => 1;
@NAPI() int opaque<T>(T Function(T) callback) => 1;
@NAPI() int renamed<U>(U Function(U) callback) => 1;
@NAPI() int nullableOpaque<T>(T? Function(T?) callback) => 1;
@NAPI() int nestedOpaque<T>(Future<Map<String, T?>> Function(Dictionary<T?>) callback) => 1;
@NAPI() int outputOnly(int Function(Projection) callback) => 1;
@NAPI() int handle(Map<String, JsArray<int>> Function() callback) => 1;
''');
      final wasm = lower(validate(module));
      final native = validateNative(module);
      List<String>? signatures;
      for (final conversions in [
        wasm.functions.map((f) => f.inputs.single),
        native.functions.map((f) => f.inputs.single),
      ]) {
        final callbacks = conversions.cast<CallbackConversion>().toList();
        final keys = callbacks
            .map((callback) => callback.signatureKey)
            .toList();
        expect(keys[0], keys[1]);
        expect(keys[8], keys[9]);
        expect(keys.toSet(), hasLength(12));
        final argument = callbacks[0].inputs.single as ValueClassConversion;
        final result = callbacks[0].output! as ValueClassConversion;
        expect(argument.direction, ValueDirection.output);
        expect(result.direction, ValueDirection.input);
        expect(argument.schemaId, result.schemaId);
        expect(callbacks[6].inputs.single, isA<MapConversion>());
        expect(callbacks[7].output, isA<DictionaryConversion>());
        expect(callbacks[8].output, isA<OpaqueConversion>());
        expect(callbacks[11].returnsFuture, isTrue);
        expect(callbacks[12].inputs.single, isA<ValueClassConversion>());
        if (signatures == null) {
          signatures = keys;
        } else {
          expect(keys, signatures);
        }
      }
      expect(emitDeclarations(wasm), emitNativeDeclarations(native));
      expect(emitDeclarations(wasm), contains('"step"?: number'));
    },
  );

  test('stored resource callbacks scope later scalar exports', () async {
    final module = await read('''
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') class Resource {
  Resource();
  void close() {}
}
@NAPI() void save(Future<Resource> Function(Resource) callback) {}
@NAPI() int invoke() => 1;
''');
    final wasm = lower(validate(module));
    expect(wasm.hasResourceCollections, isFalse);
    expect(wasm.hasResourceCallbacks, isTrue);
    expect(wasm.hasScopedResourceAccess, isTrue);
    expect(
      wasm.functions.last.representation,
      ExportRepresentation.callableGlobal,
    );
    expect(wasm.needsResourceOperation(wasm.functions.last), isTrue);
  });

  test(
    'callback parameter shapes preserve kinds, names and cache identity',
    () async {
      final module = await read('''
@NAPI() int required(int Function(int) callback) => 1;
@NAPI() int optional(int Function([int value]) callback) => 1;
@NAPI() int renamed(int Function([int renamed]) callback) => 1;
@NAPI() int nullable(int Function([int?]) callback) => 1;
@NAPI() int named(int Function({int value}) callback) => 1;
@NAPI() int namedRename(int Function({int renamed}) callback) => 1;
@NAPI() int requiredNamed(int Function({required int value}) callback) => 1;
@NAPI() int ordered(int Function({int a, String b}) callback) => 1;
@NAPI() int reordered(int Function({String b, int a}) callback) => 1;
@NAPI() int mixed(int Function(String source, {required int c0, int? operation}) callback) => 1;
@NAPI() int opaque<T>(T Function([T]) callback) => 1;
@NAPI() int other<U>(U Function([U]) callback) => 1;
@NAPI() int future(Future<int> Function({int value}) callback) => 1;
@NAPI() class Calls<T> {
  Calls();
  U call<U>(U Function([U]) callback, U value) => callback(value);
  T named(T Function({T value}) callback, T value) => callback(value: value);
}
''');
      final wasm = lower(validate(module));
      final native = validateNative(module);
      List<String>? signatures;
      for (final conversions in [
        wasm.functions.map((f) => f.inputs.single),
        native.functions.map((f) => f.inputs.single),
      ]) {
        final callbacks = conversions.cast<CallbackConversion>().toList();
        final keys = callbacks
            .map((callback) => callback.signatureKey)
            .toList();
        expect(keys[1], keys[2]);
        expect(keys[7], keys[8]);
        expect(keys[10], keys[11]);
        expect(keys.toSet(), hasLength(10));
        expect(callbacks[0].hasParameterShape, isFalse);
        expect(callbacks[1].dartType, 'int Function([int])');
        expect(callbacks[1].typescriptType, '(arg0?: number) => number');
        expect(callbacks[3].dartType, 'int Function([int?])');
        expect(callbacks[4].dartType, 'int Function({int value})');
        expect(callbacks[6].dartType, 'int Function({required int value})');
        expect(
          callbacks[9].dartType,
          'int Function(String, {required int c0, int? operation})',
        );
        expect(
          callbacks[9].typescriptType,
          '(arg0: string, options: { "c0": number; "operation"?: number | null }) => number',
        );
        expect(
          callbacks[10].dartType,
          '_NapiHostValue Function([_NapiHostValue])',
        );
        expect(
          callbacks[12].typescriptType,
          '(options?: { "value"?: number }) => globalThis.Promise<number>',
        );
        if (signatures == null) {
          signatures = keys;
        } else {
          expect(keys, signatures);
        }
      }
      expect(emitDeclarations(wasm), emitNativeDeclarations(native));
    },
  );

  test(
    'reference views compare optional callback contracts contravariantly',
    () async {
      final module = await read('''
@NAPI() class Optional {
  Optional();
  int run(int Function([int?]) callback) => callback();
}
@NAPI() class Required {
  Required();
  int run(int Function(int?) callback) => callback(1);
}
@NAPI() class NamedOptional {
  NamedOptional();
  int run(int Function({int? value}) callback) => callback();
}
@NAPI() class NamedRequired {
  NamedRequired();
  int run(int Function({required int? value}) callback) => callback(value: 1);
}
@NAPI() class NamedExtra {
  NamedExtra();
  int run(int Function({int? value, String? extra}) callback) => callback();
}
@NAPI() class NamedOther {
  NamedOther();
  int run(int Function({int? other}) callback) => callback();
}
@NAPI() class Base {
  Base();
  int run(int Function([int?]) callback) => callback();
}
@NAPI() class Child extends Base {
  Child();
  @override int run(int Function([int?]) callback) => callback(1);
}
''');
      final classes = validate(module).classes;
      validateNative(module);
      bool accepts(String implementation, String contract) {
        final a = classes.singleWhere(
          (c) => c.binding.exportName == implementation,
        );
        final b = classes.singleWhere((c) => c.binding.exportName == contract);
        return referenceMemberAccepts(
          a.members.singleWhere((m) => m.binding.exportName == 'run'),
          b.members.singleWhere((m) => m.binding.exportName == 'run'),
          classes,
        );
      }

      expect(accepts('Required', 'Optional'), isTrue);
      expect(accepts('Optional', 'Required'), isFalse);
      expect(accepts('NamedRequired', 'NamedOptional'), isTrue);
      expect(accepts('NamedOptional', 'NamedRequired'), isFalse);
      expect(accepts('NamedOptional', 'NamedExtra'), isTrue);
      expect(accepts('NamedExtra', 'NamedOptional'), isFalse);
      expect(accepts('NamedOptional', 'NamedOther'), isFalse);
      expect(accepts('Child', 'Base'), isTrue);
    },
  );

  for (final entry in {
    'output-only result': (
      '''@NAPI(classPolicy: ClassPolicy.value) class Projection {
  Projection._(); final int value = 1;
} @NAPI() int run(Projection Function() callback) => 1;''',
      'NAPI_VALUE_INPUT',
    ),
    'opaque Map key': (
      '@NAPI() int run<T>(Map<T,int> Function() callback) => 1;',
      'NAPI_OPAQUE_KEY',
    ),
    'handle Map key': (
      '@NAPI() int run(Map<JsArray<int>,int> Function() callback) => 1;',
      'NAPI_JS_COLLECTION',
    ),
    'dynamic handle element': (
      '@NAPI() int run(JsArray<List<dynamic>> Function() callback) => 1;',
      'NAPI_JS_COLLECTION',
    ),
  }.entries) {
    test('callback preserves ${entry.key} diagnostic', () async {
      final module = await read(entry.value.$1);
      final diagnostic = throwsA(
        isA<BindingDiagnostic>().having(
          (error) => error.code,
          'code',
          entry.value.$2,
        ),
      );
      expect(() => validate(module), diagnostic);
      expect(() => validateNative(module), diagnostic);
    });
  }

  test('actual TypeScript consumers enforce callback payload contracts', () async {
    final module = await read('''
@NAPI() int run(int Function(int, String) callback) => callback(1, 'x');
@NAPI() int optional([int Function(int)? callback]) => callback?.call(1) ?? 0;
@NAPI(bigint: true) int big(int Function(int) callback) => callback(1);
@NAPI() int record(List<int> Function((int, {String text})) callback) => callback((1, text: 'x')).length;
@NAPI() List<int> list(List<int> Function(List<int>) callback) => callback([1, 2]);
@NAPI() Future<int> asynchronous(Future<int> Function(int) callback) => callback(1);
@NAPI() Future<void> asyncVoid(Future<void> Function() callback) => callback();
@NAPI(bigint: true) Future<int> asyncBig(Future<int> Function(int) callback) => callback(1);
@NAPI() Future<List<int>> asyncRecord(Future<List<int>> Function((int, {String text})) callback) => callback((1, text: 'x'));
@NAPI() Future<int> syncInFuture(int Function(int) callback) async => callback(1);
@NAPI() Future<int> asyncOptional([Future<int> Function(int)? callback]) async => callback == null ? 0 : await callback(1);
@NAPI() Future<int> globalName<globalThis>(globalThis value, Future<int> Function(int) callback) => callback(1);
@NAPI(name: 'Promise') class PromiseName { PromiseName(); }
@NAPI() class Calls {
  Calls(void Function() initialize) { initialize(); }
  int run(int Function(int) callback) => callback(1);
}
''');
    final declarations = {
      'wasm': emitDeclarations(lower(validate(module))),
      'native': emitNativeDeclarations(validateNative(module)),
    };
    for (final entry in declarations.entries) {
      await File('${directory.path}/${entry.key}.d.mts')
          .writeAsString(entry.value);
      await File('${directory.path}/${entry.key}-consumer.mts').writeAsString(
        r'''
import * as api from './BACKEND.mjs';
const value: number = api.run((n, s) => n + s.length);
const big: bigint = api.big(n => n + 1n);
api.optional(); api.optional(undefined); api.optional(null);
api.record(r => [r.$1, r.text.length]);
api.record(r => [r.$1, r.text.length] as const);
const list: number[] = api.list(values => { values.push(3); return values; });
api.list(() => [1, 2] as const);
const calls = new api.Calls(() => {});
calls.run(n => n * 2);
const asynchronous: Promise<number> = api.asynchronous(async n => n + 1);
const empty: Promise<void> = api.asyncVoid(async () => {});
const wide: Promise<bigint> = api.asyncBig(async n => n + 1n);
const record: Promise<number[]> = api.asyncRecord(async r => [r.$1, r.text.length]);
api.asyncRecord(async r => [r.$1, r.text.length] as const);
const syncInFuture: Promise<number> = api.syncInFuture(n => n + 1);
api.asyncOptional(); api.asyncOptional(null); api.asyncOptional(undefined);
api.asyncOptional(async n => n);
const globalName: Promise<number> = api.globalName('value', async n => n);
// @ts-expect-error A callback is required.
api.run();
// @ts-expect-error Callback result must match its Dart result.
api.run(() => 'wrong');
// @ts-expect-error A callback cannot narrow its input to a different scalar.
api.run((n: string, s: string) => n.length + s.length);
// @ts-expect-error A declared synchronous result does not accept a Promise.
api.run(async n => n);
// @ts-expect-error The callback uses the enclosing bigint policy.
api.big((n: number) => n);
// @ts-expect-error Nullable applies to the callback, not its result.
api.optional(() => null);
// @ts-expect-error Record and list child types remain exact.
api.record(r => [r.text]);
// @ts-expect-error Members retain callback result validation.
calls.run(() => 'wrong');
// @ts-expect-error Future-returning callbacks require a Promise result.
api.asynchronous(n => n);
// @ts-expect-error A structural thenable is not a genuine Promise contract.
api.asynchronous(n => ({then(resolve: (value: number) => void) { resolve(n); }}));
// @ts-expect-error Future payload conversion remains strict.
api.asynchronous(async n => String(n));
// @ts-expect-error Future<void> also requires a Promise.
api.asyncVoid(() => {});
// @ts-expect-error Nullable outer callback does not make its Future payload nullable.
api.asyncOptional(async () => null);
// @ts-expect-error Future callback payloads retain the enclosing bigint policy.
api.asyncBig(async (n: number) => n);
// @ts-expect-error Async callbacks retain record/list child conversion.
api.asyncRecord(async r => [r.text]);
void [value, big, asynchronous, empty, wide, record, syncInFuture, globalName, list];
'''
            .replaceAll('BACKEND', entry.key),
      );
    }
    final tsc =
        Platform.environment['NAPI_TSC'] ??
        '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
    for (final mode in ['NodeNext', 'Bundler']) {
      for (final exact in ['true', 'false']) {
        for (final indexed in ['true', 'false']) {
          final result = await Process.run(
            Platform.environment['NODE'] ?? 'node',
            [
              tsc,
              '--ignoreConfig',
              '--noEmit',
              '--strict',
              '--target',
              'ES2022',
              '--module',
              mode == 'NodeNext' ? 'NodeNext' : 'ESNext',
              '--moduleResolution',
              mode,
              '--exactOptionalPropertyTypes',
              exact,
              '--noUncheckedIndexedAccess',
              indexed,
              for (final backend in declarations.keys)
                '${directory.path}/$backend-consumer.mts',
            ],
          );
          expect(
            result.exitCode,
            0,
            reason:
                '$mode exact=$exact indexed=$indexed: ${result.stdout}${result.stderr}',
          );
        }
      }
    }
  });

  final rejected = <String, String>{
    for (final type in ['Int8List', 'Float64List', 'Uint8ClampedList'])
      'unsupported $type callback argument':
          "import 'dart:typed_data'; @NAPI() int run(int Function($type) callback) => 1;",
    'unsupported typed callback result': "import 'dart:typed_data'; @NAPI() int run(Future<Int32List> Function() callback) => 1;",
    'callback output': '@NAPI() int Function(int) output() => (n) => n;',
    'callback getter': '@NAPI() class Bad { Bad(); int Function(int) get callback => (n) => n; }',
    'callback field':
        '@NAPI() class Bad { Bad(); int Function(int) callback = (n) => n; }',
    'nested outer List':
        '@NAPI() int run(List<int Function()> callbacks) => 1;',
    'nested outer record': '@NAPI() int run((int Function(),) callbacks) => 1;',
    'nested callback parameter':
        '@NAPI() int run(int Function(void Function()) callback) => 1;',
    'nested callback result':
        '@NAPI() int run(int Function() Function() callback) => 1;',
    'generic callback': '@NAPI() int run(T Function<T>(T) callback) => 1;',
    'untyped Function': '@NAPI() int run(Function callback) => 1;',
    'callback FutureOr result': "import 'dart:async'; @NAPI() int run(FutureOr<int> Function(int) callback) => 1;",
    'nullable callback Future':
        '@NAPI() int run(Future<int>? Function(int) callback) => 1;',
    'nested callback Future':
        '@NAPI() int run(Future<Future<int>> Function(int) callback) => 1;',
    'callback Future argument':
        '@NAPI() int run(int Function(Future<int>) callback) => 1;',
    'callback FutureOr argument': "import 'dart:async'; @NAPI() int run(int Function(FutureOr<int>) callback) => 1;",
    'Future nested callback result':
        '@NAPI() int run(Future<int Function()> Function() callback) => 1;',
    'Future dynamic callback result':
        '@NAPI() int run(Future<dynamic> Function() callback) => 1;',
    'Future List dynamic callback result':
        '@NAPI() int run(Future<List<dynamic>> Function() callback) => 1;',
    'generic handle callback':
        '@NAPI() int run(JsArray<T> Function<T>(JsArray<T>) callback) => 1;',
    'dynamic callback payload':
        '@NAPI() int run(dynamic Function(dynamic) callback) => 1;',
  };
  for (final entry in rejected.entries) {
    test('rejects ${entry.key} in both backends', () async {
      final module = await read(entry.value);
      final diagnostic = throwsA(
        isA<BindingDiagnostic>().having((e) => e.code, 'code', 'NAPI_CALLBACK'),
      );
      expect(() => validate(module), diagnostic);
      expect(() => validateNative(module), diagnostic);
    });
  }

  test('enclosing opaque parameters are callback payloads', () {
    final source = SourceLocation(Uri.file('/callbacks.dart'), 0, 1);
    final parameter = DeclarationId(
      source.uri,
      'T',
      kind: DeclarationKind.typeParameter,
    );
    final type = TypeParameterType(parameter);
    expect(
      () => validateValueType(
        FunctionTypeBinding(
          result: type,
          parameters: [ParameterBinding('value', type)],
        ),
        source,
        direction: ValueDirection.input,
        opaqueParameters: {parameter},
        allowCallback: true,
      ),
      returnsNormally,
    );
  });
}
