import 'dart:io';

import 'package:napi/napi.dart';
import 'package:napi/src/build/contract.dart';
import 'package:napi/src/compiler/analysis/reference_views.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi generic members ');
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<BindingModule> read(String source, {bool native = false}) async {
    final file = File('${directory.path}/entry.dart');
    await file.writeAsString("import 'package:napi/napi.dart';\n$source");
    return AnnotationFrontend(
      packagesPath: packages,
      native: native,
    ).read(file.uri);
  }

  Matcher diagnostic(String code) =>
      isA<BindingDiagnostic>().having((e) => e.code, 'code', code);

  test(
    'method binders are independent, including alias and external members',
    () async {
      const source = '''
@NAPI() class Box<T> {
  Box(this.value);
  T value;
  U echo<U>(U value) => value;
  U? optional<U>([U? value]) => value;
  U? named<U>({U? value}) => value;
  (T, U) both<U>(U value) => (this.value, value);
  Box<U> box<U>(U value) => Box(value);
  List<U?> list<U>(List<U?> value) => value;
  Dictionary<U> dictionary<U>(Dictionary<U> value) => value;
  JsArray<U> array<U>(JsArray<U> value) => value;
  JsMap<T, U> map<U>(JsMap<T, U> value) => value;
  Future<U> later<U>(U value) async => value;
  Stream<U> events<U>(U value) => Stream.value(value);
  static U staticEcho<U>(U value) => value;
  @NAPI(exclude: true) U semantic<U extends num>(U value) => value;
}
@NAPI() class Shadow<T> {
  Shadow();
  T echo<T>(T value) => value;
}
class Business<T> {
  Business(this.value);
  T value;
  (T, U) pair<U>(U value) => (this.value, value);
}
@NAPI() typedef IntBusiness = Business<int>;
''';
      for (final native in [false, true]) {
        final module = await read(source, native: native);
        final external = await ExternalFrontend(
          const ExternalLibrary([
            ExternalClass(
              'Box',
              members: [
                ExternalMember.method('semantic', config: NAPI(exclude: true)),
              ],
            ),
            ExternalClass('Shadow'),
            ExternalClass('IntBusiness'),
          ]),
          packagesPath: packages,
          native: native,
        ).read(File('${directory.path}/entry.dart').uri);
        final plan = lower(validate(module));
        final vm = validateNative(module);
        final types = emitDeclarations(plan);
        expect(types, emitNativeDeclarations(vm));
        expect(types, emitDeclarations(lower(validate(external))));
        expect(types, emitNativeDeclarations(validateNative(external)));
        expect(types, contains('echo<U = unknown>(value: U): U;'));
        expect(types, contains('static staticEcho<U = unknown>(value: U): U;'));
        expect(
          types,
          contains(r'both<U = unknown>(value: U): { $1: T; $2: U };'),
        );
        expect(
          types,
          contains(r'pair<U = unknown>(value: U): { $1: number; $2: U };'),
        );
        expect(types, contains('echo<T = unknown>(value: T): T;'));
        final box = module.classes.first;
        final echo = box.members.singleWhere(
          (m) => m.declaration.name == 'echo',
        );
        expect(echo.typeParameters.single.opaque, isTrue);
        expect(
          echo.parameters.single.presence,
          ParameterPresence.opaqueRequired,
        );
        final optional = box.members.singleWhere(
          (m) => m.declaration.name == 'optional',
        );
        expect(
          optional.parameters.single.presence,
          ParameterPresence.opaqueOptional,
        );
        expect(referenceCallTypeParameters(box, echo), hasLength(2));
        final static = box.members.singleWhere(
          (m) => m.declaration.name == 'staticEcho',
        );
        expect(referenceCallTypeParameters(box, static), hasLength(1));
        final shadow = module.classes[1];
        final shadowEcho = shadow.members.singleWhere(
          (m) => m.declaration.name == 'echo',
        );
        expect(
          shadow.typeParameters.single.declaration,
          isNot(shadowEcho.typeParameters.single.declaration),
        );
        for (final code in [emitDart(plan), emitNativeDart(vm)]) {
          expect(code, contains('object.echo<_NapiHostValue>(a0)'));
          expect(code, contains('target.Box.staticEcho<_NapiHostValue>(a0)'));
          expect(
            code,
            isNot(contains('target.Box<_NapiHostValue>.staticEcho')),
          );
        }
      }
    },
  );

  test('unused method binders still emit the carrier in an otherwise ordinary module', () async {
    final module = await read('''
@NAPI() class Marker {
  Marker();
  int own<U>() => 7;
  static int other<V>() => 8;
}
''');
    for (final code in [
      emitDart(lower(validate(module))),
      emitNativeDart(validateNative(module)),
    ]) {
      expect(code, contains('_NapiHostValue'));
      expect(code, contains('object.own<_NapiHostValue>()'));
      expect(code, contains('target.Marker.other<_NapiHostValue>()'));
    }
  });

  test(
    'ordinary ancestry permits new generic methods and resource work',
    () async {
      final module = await read('''
@NAPI() class Base { Base(); int read() => 1; }
@NAPI() class Child extends Base { Child(); U echo<U>(U value) => value; }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource { Resource(); void close() {} Future<U> work<U>(U value) async => value; }
''');
      expect(validate(module).classes, hasLength(3));
      expect(validateNative(module).classes, hasLength(3));
    },
  );

  test('unselected ancestry and static generic ancestors do not over-restrict own methods', () async {
    final module = await read('''
class Business { U echo<U>(U value) => value; }
@NAPI() class Own extends Business {
  Own();
  @override V echo<V>(V value) => value;
}
@NAPI() class StaticBase {
  StaticBase();
  static U echo<U>(U value) => value;
}
@NAPI() class StaticChild extends StaticBase { StaticChild(); }
''');
    expect(validate(module).classes, hasLength(3));
    expect(validateNative(module).classes, hasLength(3));
    final declarations = emitDeclarations(lower(validate(module)));
    expect(declarations, contains('echo<V = unknown>(value: V): V;'));
    expect(declarations, contains('static echo<U = unknown>(value: U): U;'));
  });

  for (final (name, source, code) in [
    (
      'bound',
      '@NAPI() class A { U echo<U extends num>(U value) => value; }',
      'NAPI_TYPE',
    ),
    (
      'dependent',
      '@NAPI() class A<T> { U echo<U extends T>(U value) => value; }',
      'NAPI_TYPE',
    ),
    (
      'callback',
      '@NAPI() class A { void call<U>(U Function(U) fn) {} }',
      'NAPI_CALLBACK',
    ),
    (
      'cleanup',
      "@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') class A { void close<U>() {} }",
      'NAPI_GENERIC',
    ),
    (
      'inherited',
      '@NAPI() class A { U echo<U>(U value) => value; } @NAPI() class B extends A {}',
      'NAPI_GENERIC',
    ),
    (
      'override',
      '@NAPI() class A { U echo<U>(U value) => value; } @NAPI() class B extends A { @override V echo<V>(V value) => value; }',
      'NAPI_GENERIC',
    ),
  ]) {
    test('diagnoses $name without omitting a selected contract', () async {
      final module = await read(source);
      for (final check in [validate, validateNative]) {
        expect(() => check(module), throwsA(diagnostic(code)));
      }
    });
  }

  test('independent generic methods do not gain composite coverage', () async {
    final module = await read('''
@NAPI() class A { A(); int marker<U>() => 1; }
@NAPI() class B { B(); int marker<V>() => 2; }
''');
    final classes = validate(module).classes;
    final a = classes[0].members.single;
    final b = classes[1].members.single;
    expect(referenceMemberAccepts(a, a, classes), isTrue);
    expect(referenceMemberAccepts(a, b, classes), isFalse);
    final contracts = referenceViewContracts(classes);
    expect(contracts.ids.values.toSet(), hasLength(2));
    expect(contracts.accepts.every((coverage) => coverage.isEmpty), isTrue);
  });

  test('dual contracts retain unused method binder arity', () async {
    final wasm = await read('@NAPI() class A { A(); int marker<U>() => 1; }');
    final same = await read(
      '@NAPI() class A { A(); int marker<U>() => 2; }',
      native: true,
    );
    expect(
      validatePackageContracts(wasm, same),
      contains('marker<U = unknown>(): number;'),
    );
    final other = await read(
      '@NAPI() class A { A(); int marker<U, V>() => 2; }',
      native: true,
    );
    expect(
      () => validatePackageContracts(wasm, other),
      throwsA(diagnostic('NAPI_PACKAGE_CONTRACT')),
    );
  });
}
