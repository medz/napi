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
  ]) {
    test('diagnoses $name without omitting a selected contract', () async {
      final module = await read(source);
      for (final check in [validate, validateNative]) {
        expect(() => check(module), throwsA(diagnostic(code)));
      }
    });
  }

  test(
    'independent alpha-equivalent generic methods share composite coverage',
    () async {
      final module = await read('''
@NAPI() class A { A(); int marker<U>() => 1; }
@NAPI() class B { B(); int marker<V>() => 2; }
''');
      final classes = validate(module).classes;
      final a = classes[0].members.single;
      final b = classes[1].members.single;
      expect(referenceMemberAccepts(a, a, classes), isTrue);
      expect(referenceMemberAccepts(a, b, classes), isTrue);
      final contracts = referenceViewContracts(classes);
      expect(contracts.ids.values.toSet(), hasLength(1));
      expect(contracts.accepts.every((coverage) => coverage.isEmpty), isTrue);
    },
  );

  test(
    'inherits method binders through overrides, interfaces and aliases',
    () async {
      final module = await read(r'''
@NAPI() class Base<T> {
  Base();
  (T, U) pair<U>(T first, U second) => (first, second);
  U? optional<U>([U? value]) => value;
}
@NAPI() class Child<X> extends Base<X> {
  Child();
  @override (X, V) pair<V>(X first, V second) => (first, second);
}
class Business<T> {
  Business();
  (T, U) pair<U>(T first, U second) => (first, second);
  U? optional<U>([U? value]) => value;
}
@NAPI() class Interface<U> extends Business<U> implements Base<U> {
  Interface();
}
class Plain<T> { Plain(); U echo<U>(U value) => value; }
@NAPI() typedef IntPlain = Plain<int>;
@NAPI() class IntChild extends IntPlain { IntChild(); }
''');
      for (final types in [
        emitDeclarations(lower(validate(module))),
        emitNativeDeclarations(validateNative(module)),
      ]) {
        expect(
          types,
          contains(
            r'pair<V = unknown>(first: X, second: V): { $1: X; $2: V };',
          ),
        );
        expect(
          types,
          contains(
            r'pair<U$1 = unknown>(first: U, second: U$1): { $1: U; $2: U$1 };',
          ),
        );
        expect(types, contains('echo<U = unknown>(value: U): U;'));
      }
    },
  );

  for (final (name, source, code) in [
    (
      'arity',
      '@NAPI() class A { U echo<U>(U value) => value; } @NAPI() class B extends A { V echo<V, W>(V value) => value; }',
      'NAPI_DART',
    ),
    (
      'bound mismatch',
      '@NAPI() class A { U echo<U>(U value) => value; } @NAPI() class B extends A { V echo<V extends Object>(V value) => value; }',
      'NAPI_DART',
    ),
    (
      'optional becomes required',
      '@NAPI() class A { U? echo<U>([U? value]) => value; } @NAPI() class B extends A { V? echo<V>(V? value) => value; }',
      'NAPI_DART',
    ),
    (
      'unselected semantic bound',
      '@NAPI() class A { U echo<U>(U value) => value; } class Hidden extends A { V echo<V extends num>(V value) => value; } @NAPI() class B extends Hidden {}',
      'NAPI_DART',
    ),
    (
      'inherited generic cleanup',
      "@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') class A { void close() {} } class Hidden extends A { void close<U>() {} } @NAPI() class B extends Hidden {}",
      'NAPI_DART',
    ),
  ]) {
    test('rejects inherited $name precisely', () async {
      await expectLater(read(source), throwsA(diagnostic(code)));
    });
  }

  test('alpha-equivalence keeps class scope and presence distinct', () async {
    final module = await read('''
@NAPI() class A<T> { A(); (T, U?) echo<U>([U? value]) => (throw 1, value); }
@NAPI() class B<T> { B(); (T, V?) echo<V>([V? value]) => (throw 1, value); }
@NAPI() class C { C(); U? echo<U>([U? value]) => value; }
@NAPI() class D { D(); V? echo<V>(V? value) => value; }
@NAPI() class E { E(); V? echo<V extends Object?>([V? value]) => value; }
''');
    final classes = validate(module).classes;
    final members = [for (final c in classes) c.members.single];
    expect(referenceMemberAccepts(members[0], members[1], classes), isFalse);
    expect(referenceMemberAccepts(members[3], members[2], classes), isFalse);
    expect(referenceMemberAccepts(members[2], members[4], classes), isTrue);
    expect(referenceMemberAccepts(members[4], members[2], classes), isTrue);
  });

  for (final middle in [false, true]) {
    test(
      'rejects ${middle ? 'unselected' : 'own'} generic covariant narrowing',
      () async {
        final module = await read('''
@NAPI() class A { void accept<U>(U? value) {} }
${middle ? '' : '@NAPI()'} class Narrow extends A {
  @override void accept<V>(covariant V value) {}
}
${middle ? '@NAPI() class Child extends Narrow {}' : ''}
''');
        for (final check in [validate, validateNative]) {
          expect(() => check(module), throwsA(diagnostic('NAPI_INHERITANCE')));
        }
      },
    );
  }

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
