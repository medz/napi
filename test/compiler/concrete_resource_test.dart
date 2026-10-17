import 'dart:io';

import 'package:napi/napi.dart';
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

const _source = '''
import 'package:napi/napi.dart';
class Session<T> {
  T value;
  Session(this.value);
  void close([int code = 7]) {}
  Future<void> shutdown() => Future.value();
  Session<T> self() => this;
}
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
typedef IntSession = Session<int>;
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'shutdown')
typedef NullableSession = Session<int?>;
''';
const _selections = ExternalLibrary([
  ExternalClass(
    'IntSession',
    config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close'),
  ),
  ExternalClass(
    'NullableSession',
    config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'shutdown'),
  ),
]);

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'napi-concrete-resource-',
    );
    addTearDown(() => directory.delete(recursive: true));
  });
  File source(String value) =>
      File('${directory.path}/business.dart')..writeAsStringSync(value);
  Future<BindingModule> read(File file, {bool native = false}) =>
      AnnotationFrontend(packagesPath: packages, native: native).read(file.uri);
  Matcher diagnostic(String code) =>
      isA<BindingDiagnostic>().having((error) => error.code, 'code', code);

  for (final native in [false, true]) {
    test('concrete resource selection preserves cleanup policy ($native)', () async {
      final file = source(_source);
      final annotated = await read(file, native: native);
      final external = await ExternalFrontend(
        _selections,
        packagesPath: packages,
        native: native,
      ).read(file.uri);
      for (final module in [annotated, external]) {
        final shapes = validate(module).classes;
        expect(
          shapes.map((shape) => shape.binding.classPolicy),
          everyElement(ClassPolicy.resource),
        );
        expect(shapes[0].binding.cleanup!.name, 'close');
        expect(shapes[1].binding.cleanup!.name, 'shutdown');
        expect(shapes[0].binding.cleanup!.owner, shapes[0].binding.declaration);
        expect(shapes[0].cleanup!.parameters.single.defaultValue!.value, 7);
        expect(shapes.every((shape) => shape.cleanup!.returnsFuture), isTrue);
        expect(resourcePolicies(shapes), {0: 0, 1: 1});
        final wasm = lower(validate(module));
        final vm = validateNative(module);
        for (final declarations in [
          emitDeclarations(wasm),
          emitNativeDeclarations(vm),
        ]) {
          expect(
            declarations,
            contains('close(code?: number): globalThis.Promise<void>;'),
          );
          expect(
            declarations,
            contains('shutdown(): globalThis.Promise<void>;'),
          );
          expect(declarations, contains('self(): IntSession;'));
          expect(declarations, contains('self(): NullableSession;'));
        }
        for (final emitted in [emitDart(wasm), emitNativeDart(vm)]) {
          final controls = emitted
              .split('ResourceControl? _resourceControl')
              .last
              .split('return policy')
              .first;
          expect(controls, contains('value is target.IntSession'));
          expect(
            controls,
            contains(
              'value is target.NullableSession && value is! target.IntSession',
            ),
          );
          expect(emitted, isNot(contains('target.Session<')));
        }
      }
      expect(
        emitDeclarations(lower(validate(annotated))),
        emitDeclarations(lower(validate(external))),
      );
      expect(
        emitNativeDeclarations(validateNative(annotated)),
        emitNativeDeclarations(validateNative(external)),
      );
    });
  }

  test(
    'external alias cleanup rename and exclusion remain per selection',
    () async {
      final file = source(_source);
      final module = await ExternalFrontend(
        const ExternalLibrary([
          ExternalClass(
            'IntSession',
            config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close'),
            members: [
              ExternalMember.method('close', config: NAPI(name: 'release')),
              ExternalMember.method('shutdown', config: NAPI(exclude: true)),
            ],
          ),
          ExternalClass(
            'NullableSession',
            config: NAPI(
              classPolicy: ClassPolicy.resource,
              cleanup: 'shutdown',
            ),
            members: [
              ExternalMember.method('close', config: NAPI(exclude: true)),
            ],
          ),
        ]),
        packagesPath: packages,
      ).read(file.uri);
      final shapes = validate(module).classes;
      expect(shapes[0].cleanup!.exportName, 'release');
      expect(shapes[1].cleanup!.exportName, 'shutdown');
      expect(
        shapes[0].members.any((member) => member.exportName == 'shutdown'),
        isFalse,
      );
      expect(
        shapes[1].members.any((member) => member.exportName == 'close'),
        isFalse,
      );
      expect(validateNative(module).classes, hasLength(2));
    },
  );

  test('cleanup result is checked after concrete type substitution', () async {
    final file = source('''
import 'package:napi/napi.dart';
class Finish<T> { Finish(); Future<T> close() => Future<T>.value(); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
typedef Completion = Finish<void>;
''');
    final module = await read(file);
    expect(validate(module).classes.single.cleanup!.returnsFuture, isTrue);
    expect(
      validateNative(module).classes.single.shape.cleanup!.returnsFuture,
      isTrue,
    );
    file.writeAsStringSync(
      file.readAsStringSync().replaceAll('Finish<void>', 'Finish<int>'),
    );
    final invalid = await read(file);
    expect(() => validate(invalid), throwsA(diagnostic('NAPI_RESOURCE')));
    expect(() => validateNative(invalid), throwsA(diagnostic('NAPI_RESOURCE')));
  });

  for (final (name, body, code) in [
    (
      'excluded cleanup',
      '@NAPI(exclude: true) void close() {}',
      'NAPI_RESOURCE',
    ),
    ('nonvoid cleanup', 'int close() => 1;', 'NAPI_RESOURCE'),
    ('static cleanup', 'static void close() {}', 'NAPI_SELECTION'),
    ('missing cleanup', 'void other() {}', 'NAPI_SELECTION'),
  ]) {
    test('concrete resource diagnoses $name', () async {
      final file = source(
        "import 'package:napi/napi.dart';\n"
        'class Session<T> { Session(); $body }\n'
        "@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') "
        'typedef IntSession = Session<int>;',
      );
      await expectLater(
        () async => validate(await read(file)),
        throwsA(diagnostic(code)),
      );
      await expectLater(
        () async => validateNative(await read(file, native: true)),
        throwsA(diagnostic(code)),
      );
    });
  }

  test('open resource generics and selected generic hierarchies stay diagnosed', () async {
    for (final body in [
      "@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') "
          'class Session<T> { T value; Session(this.value); void close() {} }',
      '@NAPI() class Base {} class Session<T> extends Base { void close() {} } '
          "@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') "
          'typedef IntSession = Session<int>;',
    ]) {
      final module = await read(
        source("import 'package:napi/napi.dart';\n$body"),
      );
      expect(() => validate(module), throwsA(diagnostic('NAPI_GENERIC')));
      expect(() => validateNative(module), throwsA(diagnostic('NAPI_GENERIC')));
    }
  });
}
