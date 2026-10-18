import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/js/boundary.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-opaque-policy-');
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<File> source(String text) async =>
      File('${directory.path}/entry.dart')
        ..writeAsStringSync("import 'package:napi/napi.dart';\n$text");
  Future<BindingModule> read(String text) async =>
      AnnotationFrontend(packagesPath: _packages)
          .read((await source(text)).uri);

  const router = '''
@NAPI()
class Router<T> {
  Router();
  Router.withValue(T value) : current = value;
  T? current;
  T identity(T value) => value;
  T? optional([T? value]) => value;
  T? named({required T? value}) => value;
  Router<T> self() => this;
}
''';

  test('selected IDs, presence and carrier types survive both plans', () async {
    final module = await read('''
$router
@NAPI() T identity<T>(T value) => value;
@NAPI() Router<T> forward<T>(Router<T> value) => value;
@NAPI() Future<int> wait<T>(T value) => Future.value(1);
''');
    final wasm = lower(validate(module));
    final native = validateNative(module);
    final binding = module.classes.single;
    final parameter = binding.typeParameters.single;
    expect(parameter.opaque, isTrue);
    expect(dartReferenceClassType(binding), 'target.Router<_NapiHostValue>');
    final identity = wasm.functions.first;
    expect(identity.representation, ExportRepresentation.callableGlobal);
    expect(identity.inputs.single, isA<OpaqueConversion>());
    expect(
      (identity.inputs.single as OpaqueConversion).parameter,
      module.functions.first.typeParameters.single.declaration,
    );
    expect(
      identity.parameters.single.presence,
      ParameterPresence.opaqueRequired,
    );
    final forward = wasm.functions[1].inputs.single as ReferenceConversion;
    expect(forward.dartType, 'target.Router<_NapiHostValue>');
    expect(forward.typescriptType, 'Router<T>');
    expect(forward.typeArguments.single, isA<TypeParameterType>());
    final fieldSetter = wasm.classes.single.members.singleWhere(
      (m) => m.kind == MemberCallKind.setter && m.exportName == 'current',
    );
    expect(
      fieldSetter.parameters.single.presence,
      ParameterPresence.opaqueRequired,
    );
    expect(fieldSetter.inputs.single.dartType, '_NapiHostValue?');
    final factory = native.classes.single.members.singleWhere(
      (m) => m.member!.kind == MemberKind.constructor,
    );
    expect(factory.output!.typescriptType, 'Router<T>');
    expect(native.functions.last.returnsFuture, isTrue);
    expect(native.functions.last.inputs.single, isA<OpaqueConversion>());
  });

  test(
    'annotations and external selection use the same explicit policy',
    () async {
      final file = await source('''
$router
@NAPI() class Pair<A, B> {
  Pair(this.first, this.second);
  A first;
  B second;
}
@NAPI() T echo<T>(T value) => value;
''');
      final annotated = await AnnotationFrontend(packagesPath: _packages)
          .read(file.uri);
      final external = await ExternalFrontend(
        const ExternalLibrary([
          ExternalClass('Router'),
          ExternalClass('Pair'),
          ExternalFunction('echo'),
        ]),
        packagesPath: _packages,
      ).read(file.uri);
      expect(
        emitDeclarations(lower(validate(external))),
        emitDeclarations(lower(validate(annotated))),
      );
      expect(
        emitNativeDeclarations(validateNative(external)),
        emitNativeDeclarations(validateNative(annotated)),
      );
      expect(
        annotated.classes.last.typeParameters.map((p) => p.declaration.name),
        ['A', 'B'],
      );
      expect(
        dartOpaqueTypeArguments(annotated.classes.last.typeParameters),
        '<_NapiHostValue, _NapiHostValue>',
      );
    },
  );

  test(
    'declarations preserve optional prefixes and mutable invariance',
    () async {
      final module = await read('''
$router
@NAPI() T? choose<T>([T? first, int index = 7, T? last]) => first;
''');
      final declarations = [
        emitDeclarations(lower(validate(module))),
        emitNativeDeclarations(validateNative(module)),
      ];
      for (final code in declarations) {
        expect(code, contains('class Router<in out T = unknown>'));
        expect(
          code,
          contains(r'private readonly $napiOpaque: (types: [T]) => [T];'),
        );
        expect(
          code,
          contains('static withValue<T = unknown>(value: T): Router<T>;'),
        );
        expect(code, contains('optional(): T | null;'));
        expect(code, contains('optional(value: T | null): T | null;'));
        expect(
          code,
          contains('named(options: { value: T | null }): T | null;'),
        );
        expect(code, contains('<T = unknown>(): T | null;'));
        expect(code, contains('<T = unknown>(first: T | null): T | null;'));
        expect(
          code,
          contains(
            '<T = unknown>(first: T | null, index: number | undefined): T | null;',
          ),
        );
        expect(
          code,
          contains(
            '<T = unknown>(first: T | null, index: number | undefined, last: T | null): T | null;',
          ),
        );
        expect(code, isNot(contains('first?:')));
      }
    },
  );

  test(
    'Object bounds and resolved aliases retain unrestricted opaque payloads',
    () async {
      final module = await read('''
typedef Payload<T> = T;
@NAPI() Payload<T> echo<T extends Object>(Payload<T> value) => value;
@NAPI() T? nullable<T extends Object?>([T? value = null]) => value;
''');
      final plan = lower(validate(module));
      validateNative(module);
      expect(plan.functions.first.inputs.single.typescriptType, 'T');
      expect(plan.functions.last.inputs.single.typescriptType, 'T | null');
      expect(
        plan.functions.last.parameters.single.presence,
        ParameterPresence.opaqueOptional,
      );
    },
  );

  test(
    'optional named opaque values share presence and declarations',
    () async {
      final file = await source('''
typedef Payload<T> = T;
@NAPI() T? choose<T>(String options, {Payload<T>? first, T? second = null, int count = 7}) => first;
@NAPI() T? required<T>({required T value, T? first, T? second, int count = 7}) => first;
@NAPI() class NamedStore<T> {
  NamedStore({T? first, T? second});
  NamedStore.named({required String key, T? first, T? second});
  T? put({T? first, T? second, int count = 7}) => first;
  T? mixed({required T value, T? first, T? second}) => first;
}
@NAPI() class RequiredStore<T> {
  RequiredStore({required String key, T? first, T? second});
}
''');
      final annotated = await AnnotationFrontend(packagesPath: _packages)
          .read(file.uri);
      final external = await ExternalFrontend(
        const ExternalLibrary([
          ExternalFunction('choose'),
          ExternalFunction('required'),
          ExternalClass('NamedStore'),
          ExternalClass('RequiredStore'),
        ]),
        packagesPath: _packages,
      ).read(file.uri);
      final wasm = lower(validate(annotated));
      final native = validateNative(annotated);
      for (final parameters in [
        wasm.functions.first.parameters,
        native.functions.first.parameters,
      ]) {
        expect(parameters.map((p) => p.presence), [
          ParameterPresence.required,
          ParameterPresence.opaqueOptional,
          ParameterPresence.opaqueOptional,
          ParameterPresence.optional,
        ]);
        expect(parameters[1].kind, ParameterKind.optionalNamed);
        expect(parameters[1].defaultValue?.value, isNull);
        expect(parameters[2].defaultValue?.value, isNull);
      }
      final wasmTypes = emitDeclarations(wasm);
      final nativeTypes = emitNativeDeclarations(native);
      expect(emitDeclarations(lower(validate(external))), wasmTypes);
      expect(emitNativeDeclarations(validateNative(external)), nativeTypes);
      for (final code in [wasmTypes, nativeTypes]) {
        expect(
          code,
          contains(
            'choose: <T = unknown>(options: string, options1?: { first?: T | null; second?: T | null; count?: number | undefined }) => T | null;',
          ),
        );
        expect(
          code,
          contains(
            'required: <T = unknown>(options: { value: T; first?: T | null; second?: T | null; count?: number | undefined }) => T | null;',
          ),
        );
        expect(
          code,
          contains(
            'constructor(options?: { first?: T | null; second?: T | null });',
          ),
        );
        expect(
          code,
          contains(
            'constructor(options: { key: string; first?: T | null; second?: T | null });',
          ),
        );
        expect(
          code,
          contains(
            'static named<T = unknown>(options: { key: string; first?: T | null; second?: T | null }): NamedStore<T>;',
          ),
        );
        expect(
          code,
          contains(
            'put(options?: { first?: T | null; second?: T | null; count?: number | undefined }): T | null;',
          ),
        );
        expect(
          code,
          contains(
            'mixed(options: { value: T; first?: T | null; second?: T | null }): T | null;',
          ),
        );
        expect(code, isNot(contains('T | null | undefined')));
      }
    },
  );

  test(
    'optional named opaque values still validate presence and defaults',
    () async {
      final module = await read('@NAPI() T? echo<T>({T? value}) => value;');
      final function = module.functions.single;
      final type = function.typeParameters.single.declaration;
      final nullable = TypeParameterType(
        type,
        nullability: TypeNullability.nullable,
      );
      for (final (parameter, code) in [
        (
          ParameterBinding(
            'value',
            nullable,
            kind: ParameterKind.optionalNamed,
          ),
          'NAPI_PRESENCE',
        ),
        (
          ParameterBinding(
            'value',
            TypeParameterType(type),
            kind: ParameterKind.optionalNamed,
            presence: ParameterPresence.opaqueOptional,
          ),
          'NAPI_DEFAULT',
        ),
        (
          ParameterBinding(
            'value',
            nullable,
            kind: ParameterKind.optionalNamed,
            presence: ParameterPresence.opaqueOptional,
            defaultValue: const ScalarDefault(1),
          ),
          'NAPI_DEFAULT',
        ),
        (
          ParameterBinding(
            'value',
            nullable,
            kind: ParameterKind.optionalNamed,
            presence: ParameterPresence.opaqueOptional,
            defaultSource: 'unresolved',
          ),
          'NAPI_DEFAULT',
        ),
      ]) {
        expect(
          () => validateCallParameters(
            [parameter],
            function.source,
            opaqueParameters: {type},
          ),
          throwsA(isA<BindingDiagnostic>().having((e) => e.code, 'code', code)),
        );
      }
    },
  );

  test('opaque names preserve built-in TypeScript types in both backends', () async {
    final module = await read('''
@NAPI() List<int> array<Array>(Array value) => [1];
@NAPI() () record<Record>(Record value) => ();
@NAPI() () keyRecord<PropertyKey>(PropertyKey value) => ();
@NAPI() Future<Map<String, int>> globals<globalThis>(globalThis value) async => {'x': 1};
@NAPI()
class Storage<Array, Record, PropertyKey, globalThis> {
  Storage(Array value);
  List<Map<String, ()>> nested() => [];
  Future<Map<String, int>> future(globalThis value) async => {'x': 1};
}
@NAPI(name: 'T') class Router<U> { Router(); }
@NAPI() List<int> ordinary<T>(T value) => [];
''');
    final declarations = {
      'wasm': emitDeclarations(lower(validate(module))),
      'native': emitNativeDeclarations(validateNative(module)),
    };
    for (final entry in declarations.entries) {
      final code = entry.value;
      expect(code, contains('value: Array'));
      expect(code, contains('globalThis.Array<number>'));
      expect(
        code,
        contains('globalThis.Record<globalThis.PropertyKey, never>'),
      );
      expect(
        code,
        contains('globalThis.Promise<globalThis.Map<string, number>>'),
      );
      expect(
        code,
        contains(
          'globalThis.Array<globalThis.Map<string, globalThis.Record<globalThis.PropertyKey, never>>>',
        ),
      );
      expect(code, contains('(value: T) => Array<number>'));
      await File('${directory.path}/${entry.key}.d.mts').writeAsString(code);
      await File('${directory.path}/${entry.key}-consumer.mts')
          .writeAsString('''
import * as api from './${entry.key}.mjs';
const array: number[] = api.array('payload');
const record: Record<PropertyKey, never> = api.record(Symbol());
const keyRecord: Record<PropertyKey, never> = api.keyRecord('payload');
const future: Promise<Map<string, number>> = api.globals({value: 1});
const storage = new api.Storage<string, symbol, boolean, Date>('payload');
const nested: Array<Map<string, Record<PropertyKey, never>>> = storage.nested();
const member: Promise<Map<string, number>> = storage.future(new Date());
type Equal<A, B> = (<T>() => T extends A ? 1 : 2) extends (<T>() => T extends B ? 1 : 2) ? true : false;
type Assert<T extends true> = T;
type KeyHygiene = Assert<Equal<ReturnType<typeof api.keyRecord<'payload'>>, Record<PropertyKey, never>>>;
void [array, record, keyRecord, future, nested, member];
''');
    }
    final tsc =
        Platform.environment['NAPI_TSC'] ??
        '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
    for (final mode in ['NodeNext', 'Bundler']) {
      final result = await Process.run(Platform.environment['NODE'] ?? 'node', [
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
        for (final backend in declarations.keys)
          '${directory.path}/$backend-consumer.mts',
      ]);
      expect(
        result.exitCode,
        0,
        reason: '$mode: ${result.stdout}${result.stderr}',
      );
    }
  });

  test('generic Future references use ordinary Promise resolution', () async {
    for (final member in [
      'static int then() => 0;',
      '@NAPI(exclude: true) void then() {}',
      'void other() {}',
      'void then() {}',
      "@NAPI(name: 'then') T? get value => null;",
      'T? then;',
    ]) {
      final module = await read(
        '@NAPI() class Box<T> { Box(); $member Future<Box<T>> self() async => this; } '
        '@NAPI() Future<Box<T>> pending<T>() async => Box<T>();',
      );
      expect(() => lower(validate(module)), returnsNormally);
      expect(() => validateNative(module), returnsNormally);
    }
  });

  test('exported generic class names preserve built-in container declarations', () async {
    final module = await read("""
@NAPI(name: 'Array') class Storage<T> {
  Storage(T value);
  List<int> values() => [1, 2];
  List<List<int>> nested(List<int> value) => [value];
}
@NAPI(name: 'Record') class Empty<T> { Empty(); () empty() => (); }
@NAPI(name: 'PropertyKey') class Key<T> { Key(); }
""");
    final declarations = {
      'wasm': emitDeclarations(lower(validate(module))),
      'native': emitNativeDeclarations(validateNative(module)),
    };
    for (final entry in declarations.entries) {
      expect(entry.value, contains('globalThis.Array<number>'));
      expect(
        entry.value,
        contains('globalThis.Record<globalThis.PropertyKey, never>'),
      );
      await File('${directory.path}/${entry.key}.d.mts')
          .writeAsString(entry.value);
      await File('${directory.path}/${entry.key}-consumer.mts')
          .writeAsString("""
import * as api from './${entry.key}.mjs';
const box = new api.Array('payload');
const values: number[] = box.values();
const nested: number[][] = box.nested([1]);
const empty: Record<PropertyKey, never> = new api.Record().empty();
// @ts-expect-error Public Array<T> is a bound class, not a JS array.
const wrong: api.Array<number> = box.values();
void [values, nested, empty, wrong];
""");
    }
    final tsc =
        Platform.environment['NAPI_TSC'] ??
        '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
    for (final mode in ['NodeNext', 'Bundler']) {
      final result = await Process.run(Platform.environment['NODE'] ?? 'node', [
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
        for (final backend in declarations.keys)
          '${directory.path}/$backend-consumer.mts',
      ]);
      expect(
        result.exitCode,
        0,
        reason: '$mode: ${result.stdout}${result.stderr}',
      );
    }
  });

  test('nested opaque leaves preserve structural shape and logical arguments', () async {
    final module = await read('''
$router
@NAPI() List<List<T?>> nested<T>(List<List<T?>> values) => values;
@NAPI() Map<String,T> map<T>(Map<String,T> values) => values;
@NAPI() Dictionary<T> dictionary<T>(Dictionary<T> values) => values;
@NAPI() ({T value, List<T?> rest}) record<T>(({T value, List<T?> rest}) value) => value;
@NAPI() List<Router<T>> references<T>(List<Router<T>> values) => values;
@NAPI() Map<Router<T>, T> referenceKeys<T>(Map<Router<T>, T> values) => values;
@NAPI() Future<({T then})> thenRoot<T>(T value) async => (then: value);
@NAPI() Future<Dictionary<T>> thenDictionary<T>(Dictionary<T> value) async => value;
@NAPI() Future<List<T>> futureList<T>(List<T> value) async => value;
@NAPI() Stream<({T then})> streamThen<T>(T value) => Stream.value((then: value));
''');
    final wasm = lower(validate(module));
    final native = validateNative(module);
    final nested = wasm.functions.first.inputs.single as ListConversion;
    expect((nested.element as ListConversion).element, isA<OpaqueConversion>());
    expect((nested.element as ListConversion).element.nullable, isTrue);
    expect(
      wasm.functions.first.representation,
      ExportRepresentation.nativeFunction,
    );
    expect(wasm.functions[4].inputs.single.typescriptType, 'Array<Router<T>>');
    final types = emitDeclarations(wasm);
    expect(emitNativeDeclarations(native), types);
    expect(types, contains(r'globalThis.Promise<$napiAwaited<{ then: T }>>'));
    expect(
      types,
      contains(
        r'globalThis.Promise<{ [key: string]: T } | $napiAwaited<{ [key: string]: T }>>',
      ),
    );
    expect(types, contains('globalThis.Promise<Array<T>>'));
    expect(
      types,
      contains(
        'globalThis.AsyncIterableIterator<{ then: T }, undefined, undefined>',
      ),
    );
    // Exercise all emitter branches without treating generated-source reads as
    // proof of runtime ownership.
    expect(emitDart(wasm), contains('_boxOpaque'));
    expect(emitBoundary(wasm), contains('function boxOpaque'));
    expect(emitNativeDart(native), contains('pendingInputs'));
    await File('${directory.path}/nested.d.mts').writeAsString(types);
    await File('${directory.path}/consumer.mts').writeAsString('''
import { thenRoot, thenDictionary, futureList, streamThen } from './nested.mjs';
type Then = (resolve: (value: number) => void) => void;
const then: Then = (resolve) => resolve(42);
const record: Promise<number> = thenRoot<Then>(then);
const absent: Promise<Record<string, Then> | number> = thenDictionary<Then>({ value: then });
const present: Promise<Record<string, Then> | number> = thenDictionary<Then>({ then });
// A dictionary index signature does not guarantee an own `then` property.
// @ts-expect-error the absent-then branch may resolve to the dictionary itself
const onlyNumber: Promise<number> = thenDictionary<Then>({ value: then });
const list: Promise<Then[]> = futureList<Then>([then]);
const stream: AsyncIterableIterator<{ then: Then }, undefined, undefined> = streamThen<Then>(then);
''');
    final tsc =
        Platform.environment['NAPI_TSC'] ??
        '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
    final checked = await Process.run(Platform.environment['NODE'] ?? 'node', [
      tsc,
      '--ignoreConfig',
      '--noEmit',
      '--strict',
      '--target',
      'ES2022',
      '--module',
      'NodeNext',
      '${directory.path}/consumer.mts',
    ]);
    expect(checked.exitCode, 0, reason: '${checked.stdout}${checked.stderr}');
  });

  final rejected = <String, (String, String)>{
    'semantic bound': (
      "@NAPI() T echo<T extends num>(T value) => value;",
      'NAPI_TYPE',
    ),
    'Function bound': (
      "@NAPI() T echo<T extends Function>(T value) => value;",
      'NAPI_TYPE',
    ),
    'cross parameter bound': (
      "@NAPI() U echo<T, U extends T>(U value) => value;",
      'NAPI_TYPE',
    ),
    'opaque Map key': (
      '@NAPI() Map<T,int> echo<T>(Map<T,int> values) => values;',
      'NAPI_OPAQUE_KEY',
    ),
    'opaque nested Map key': (
      '@NAPI() Map<(T,int),String> echo<T>(Map<(T,int),String> values) => values;',
      'NAPI_OPAQUE_KEY',
    ),
    'reference with structural specialization': (
      '$router @NAPI() List<Router<List<T>>> echo<T>(List<Router<List<T>>> values) => values;',
      'NAPI_TYPE',
    ),
    'nested reference with nullable specialization': (
      '$router @NAPI() List<Router<T?>> echo<T>(List<Router<T?>> values) => values;',
      'NAPI_TYPE',
    ),
    'nested opaque callback': (
      '@NAPI() void echo<T>(void Function(List<T>) value) {}',
      'NAPI_CALLBACK',
    ),
    'dynamic is not opaque': (
      "@NAPI() dynamic echo<T>(dynamic value) => value;",
      'NAPI_TYPE',
    ),
    'concrete reference': (
      "$router @NAPI() Router<String> echo(Router<String> value) => value;",
      'NAPI_TYPE',
    ),
    'raw reference': (
      "$router @NAPI() Router echo(Router value) => value;",
      'NAPI_TYPE',
    ),
    'nullable parameter reference': (
      "$router @NAPI() Router<T?> echo<T>(Router<T?> value) => value;",
      'NAPI_TYPE',
    ),
    'generic method': (
      "$router @NAPI() class Other { Other(); T echo<T>(T value) => value; }",
      'NAPI_GENERIC',
    ),
    'selected generic hierarchy': (
      "$router @NAPI() class Child extends Router<String> { Child(); }",
      'NAPI_GENERIC',
    ),
    'generic resource': (
      "@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') class Resource<T> { Resource(); void close() {} }",
      'NAPI_GENERIC',
    ),
    'generic value': (
      "@NAPI(classPolicy: ClassPolicy.value) class Value<T> { Value(this.value); final T value; }",
      'NAPI_GENERIC',
    ),
    'TypeScript type keyword': (
      "@NAPI() unknown echo<unknown>(unknown value) => value;",
      'NAPI_PARAMETER',
    ),
    'exported class shadows its own parameter': (
      "@NAPI(name: 'T') class Router<T> { Router(); Router<T> self() => this; }",
      'NAPI_NAME',
    ),
    'referenced export shadows function parameter': (
      "@NAPI(name: 'T') class Router<U> { Router(); } @NAPI() Router<T> forward<T>(Router<T> value) => value;",
      'NAPI_NAME',
    ),
    'nested reference export shadows function parameter': (
      "@NAPI(name: 'T') class Ordinary { Ordinary(); } @NAPI() List<Ordinary> output<T>(T value) => [];",
      'NAPI_NAME',
    ),
  };
  for (final entry in rejected.entries) {
    test('rejects ${entry.key} in both backends', () async {
      final (text, code) = entry.value;
      BindingModule module;
      try {
        module = await read(text);
      } on BindingDiagnostic catch (error) {
        expect(error.code, code);
        return;
      }
      final error = throwsA(
        isA<BindingDiagnostic>().having((e) => e.code, 'code', code),
      );
      expect(() => validate(module), error);
      expect(() => validateNative(module), error);
    });
  }
}
