import 'dart:io';

import 'package:napi/napi.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
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
@NAPI(opaque: ['T'])
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
@NAPI(opaque: ['T']) T identity<T>(T value) => value;
@NAPI(opaque: ['T']) Router<T> forward<T>(Router<T> value) => value;
@NAPI(opaque: ['T']) Future<int> wait<T>(T value) => Future.value(1);
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
@NAPI(opaque: ['B', 'A']) class Pair<A, B> {
  Pair(this.first, this.second);
  A first;
  B second;
}
@NAPI(opaque: ['T']) T echo<T>(T value) => value;
''');
      final annotated = await AnnotationFrontend(packagesPath: _packages)
          .read(file.uri);
      final external = await ExternalFrontend(
        const ExternalLibrary([
          ExternalClass('Router', config: NAPI(opaque: ['T'])),
          ExternalClass('Pair', config: NAPI(opaque: ['B', 'A'])),
          ExternalFunction('echo', config: NAPI(opaque: ['T'])),
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
@NAPI(opaque: ['T']) T? choose<T>([T? first, int index = 7, T? last]) => first;
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
@NAPI(opaque: ['T']) Payload<T> echo<T extends Object>(Payload<T> value) => value;
@NAPI(opaque: ['T']) T? nullable<T extends Object?>([T? value = null]) => value;
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

  test('opaque names preserve built-in TypeScript types in both backends', () async {
    final module = await read('''
@NAPI(opaque: ['Array']) List<int> array<Array>(Array value) => [1];
@NAPI(opaque: ['Record']) () record<Record>(Record value) => ();
@NAPI(opaque: ['PropertyKey']) () keyRecord<PropertyKey>(PropertyKey value) => ();
@NAPI(opaque: ['globalThis']) Future<Map<String, int>> globals<globalThis>(globalThis value) async => {'x': 1};
@NAPI(opaque: ['Array', 'Record', 'PropertyKey', 'globalThis'])
class Storage<Array, Record, PropertyKey, globalThis> {
  Storage(Array value);
  List<Map<String, ()>> nested() => [];
  Future<Map<String, int>> future(globalThis value) async => {'x': 1};
}
@NAPI(name: 'T', opaque: ['U']) class Router<U> { Router(); }
@NAPI(opaque: ['T']) List<int> ordinary<T>(T value) => [];
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
      expect(
        code,
        contains(
          '(value: T)${entry.key == 'wasm' ? ' =>' : ':'} Array<number>',
        ),
      );
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

  final rejected = <String, (String, String)>{
    'unselected generic': (
      '@NAPI() T echo<T>(T value) => value;',
      'NAPI_GENERIC',
    ),
    'partial selection': (
      "@NAPI(opaque: ['T']) T echo<T, U>(T value) => value;",
      'NAPI_GENERIC',
    ),
    'duplicate selection': (
      "@NAPI(opaque: ['T', 'T']) T echo<T>(T value) => value;",
      'NAPI_SELECTION',
    ),
    'unknown selection': (
      "@NAPI(opaque: ['U']) T echo<T>(T value) => value;",
      'NAPI_SELECTION',
    ),
    'empty selection': (
      "@NAPI(opaque: []) int echo(int value) => value;",
      'NAPI_SELECTION',
    ),
    'member selection': (
      "@NAPI(opaque: ['T']) class Box<T> { Box(); @NAPI(opaque: ['T']) T echo(T value) => value; }",
      'NAPI_PLACEMENT',
    ),
    'semantic bound': (
      "@NAPI(opaque: ['T']) T echo<T extends num>(T value) => value;",
      'NAPI_TYPE',
    ),
    'Function bound': (
      "@NAPI(opaque: ['T']) T echo<T extends Function>(T value) => value;",
      'NAPI_TYPE',
    ),
    'cross parameter bound': (
      "@NAPI(opaque: ['T', 'U']) U echo<T, U extends T>(U value) => value;",
      'NAPI_TYPE',
    ),
    'optional named': (
      "@NAPI(opaque: ['T']) T? echo<T>({T? value}) => value;",
      'NAPI_PRESENCE',
    ),
    'nested input': (
      "@NAPI(opaque: ['T']) int echo<T>(List<T> value) => 1;",
      'NAPI_TYPE',
    ),
    'nested output': (
      "@NAPI(opaque: ['T']) List<T> echo<T>(T value) => [value];",
      'NAPI_TYPE',
    ),
    'opaque Future': (
      "@NAPI(opaque: ['T']) Future<T> echo<T>(T value) => Future.value(value);",
      'NAPI_TYPE',
    ),
    'nullable opaque Future': (
      "@NAPI(opaque: ['T']) Future<T?> echo<T>(T value) => Future.value(value);",
      'NAPI_TYPE',
    ),
    'dynamic is not opaque': (
      "@NAPI(opaque: ['T']) dynamic echo<T>(dynamic value) => value;",
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
      "$router @NAPI(opaque: ['T']) Router<T?> echo<T>(Router<T?> value) => value;",
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
      "@NAPI(opaque: ['T'], classPolicy: ClassPolicy.resource, cleanup: 'close') class Resource<T> { Resource(); void close() {} }",
      'NAPI_GENERIC',
    ),
    'generic value': (
      "@NAPI(opaque: ['T'], classPolicy: ClassPolicy.value) class Value<T> { Value(this.value); final T value; }",
      'NAPI_GENERIC',
    ),
    'TypeScript type keyword': (
      "@NAPI(opaque: ['unknown']) unknown echo<unknown>(unknown value) => value;",
      'NAPI_PARAMETER',
    ),
    'exported class shadows its own parameter': (
      "@NAPI(name: 'T', opaque: ['T']) class Router<T> { Router(); Router<T> self() => this; }",
      'NAPI_NAME',
    ),
    'referenced export shadows function parameter': (
      "@NAPI(name: 'T', opaque: ['U']) class Router<U> { Router(); } @NAPI(opaque: ['T']) Router<T> forward<T>(Router<T> value) => value;",
      'NAPI_NAME',
    ),
    'nested reference export shadows function parameter': (
      "@NAPI(name: 'T') class Ordinary { Ordinary(); } @NAPI(opaque: ['T']) List<Ordinary> output<T>(T value) => [];",
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
