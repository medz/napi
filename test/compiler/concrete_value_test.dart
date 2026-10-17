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
class Box<T> {
  T value;
  Box<T>? next;
  Box(this.value, {this.next});
}
@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
typedef IntBox = Box<int>;
@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
typedef TextBox = Box<String>;
@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
typedef NullableBox = Box<int?>;
@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
typedef NestedBox = Box<IntBox>;
@NAPI() (IntBox, TextBox) pair((IntBox, TextBox) value) => value;
@NAPI() NestedBox nested(NestedBox value) => value;
''';
const _selections = ExternalLibrary([
  ExternalClass(
    'IntBox',
    config: NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new'),
  ),
  ExternalClass(
    'TextBox',
    config: NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new'),
  ),
  ExternalClass(
    'NullableBox',
    config: NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new'),
  ),
  ExternalClass(
    'NestedBox',
    config: NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new'),
  ),
  ExternalFunction('pair'),
  ExternalFunction('nested'),
]);

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  late File input;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-concrete-value-');
    addTearDown(() => directory.delete(recursive: true));
    input = await File('${directory.path}/business.dart')
        .writeAsString(_source);
  });
  Future<BindingModule> read({bool native = false}) => AnnotationFrontend(
    packagesPath: packages,
    native: native,
  ).read(input.uri);
  Matcher diagnostic(String code) =>
      isA<BindingDiagnostic>().having((error) => error.code, 'code', code);

  for (final native in [false, true]) {
    test(
      'distinct concrete schemas preserve recursive directions ($native)',
      () async {
        final annotated = await read(native: native);
        final external = await ExternalFrontend(
          _selections,
          packagesPath: packages,
          native: native,
        ).read(input.uri);
        for (final module in [annotated, external]) {
          final plan = lower(validate(module));
          final vm = validateNative(module);
          expect(plan.classes, isEmpty);
          expect(plan.valueSchemas, hasLength(4));
          final pair = plan.functions.first.inputs.single as RecordConversion;
          final integer = pair.positional[0] as ValueClassConversion;
          final text = pair.positional[1] as ValueClassConversion;
          expect(integer.classBinding.exportName, 'IntBox');
          expect(text.classBinding.exportName, 'TextBox');
          expect(integer.fields.first.conversion.dartType, 'int');
          expect(text.fields.first.conversion.dartType, 'String');
          expect(identical(integer, text), isFalse);
          final next = integer.fields.last.conversion as ValueClassConversion;
          expect(next.nullable, isTrue);
          expect(identical(next.fields.last.conversion, next), isTrue);
          final nested =
              plan.functions.last.inputs.single as ValueClassConversion;
          expect(
            (nested.fields.first.conversion as ValueClassConversion)
                .classBinding,
            same(integer.classBinding),
          );
          expect(conversionGraph([nested]).length, lessThan(10));
          for (final declarations in [
            emitDeclarations(plan),
            emitNativeDeclarations(vm),
          ]) {
            expect(declarations, contains('export type IntBox ='));
            expect(declarations, contains('export type TextBox ='));
            expect(declarations, isNot(contains('declare class IntBox')));
            expect(declarations, contains('"value": number'));
            expect(declarations, contains('"value": string'));
            expect(declarations, contains('"value": number | null'));
          }
          for (final code in [emitDart(plan), emitNativeDart(vm)]) {
            expect(code, contains('target.IntBox('));
            expect(code, contains('target.TextBox('));
            expect(code, contains('target.NestedBox('));
            expect(code, isNot(contains('target.Box<')));
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
      },
    );
  }

  test(
    'later specialization cannot borrow an input constructor from its origin',
    () async {
      await input.writeAsString(
        _source.replaceFirst(
          "@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')\ntypedef TextBox",
          '@NAPI(classPolicy: ClassPolicy.value)\ntypedef TextBox',
        ),
      );
      final module = await read();
      expect(() => validate(module), throwsA(diagnostic('NAPI_VALUE_INPUT')));
      expect(
        () => validateNative(module),
        throwsA(diagnostic('NAPI_VALUE_INPUT')),
      );
    },
  );

  test(
    'external constructor and field overrides stay per specialization',
    () async {
      await input.writeAsString('''
class Box<T> {
  T value;
  Box.named(T source) : value = source;
  Box.other(this.value);
}
typedef IntBox = Box<int>;
typedef TextBox = Box<String>;
IntBox integer(IntBox value) => value;
TextBox text(TextBox value) => value;
''');
      final module = await ExternalFrontend(
        const ExternalLibrary([
          ExternalClass(
            'IntBox',
            config: NAPI(
              classPolicy: ClassPolicy.value,
              valueConstructor: 'named',
              valueFields: {'source': 'value'},
            ),
            members: [
              ExternalMember.field('value', config: NAPI(name: 'number')),
              ExternalMember.constructor('other', config: NAPI(exclude: true)),
            ],
          ),
          ExternalClass(
            'TextBox',
            config: NAPI(
              classPolicy: ClassPolicy.value,
              valueConstructor: 'other',
            ),
            members: [
              ExternalMember.field('value', config: NAPI(name: 'text')),
              ExternalMember.constructor('named', config: NAPI(exclude: true)),
            ],
          ),
          ExternalFunction('integer'),
          ExternalFunction('text'),
        ]),
        packagesPath: packages,
      ).read(input.uri);
      for (final schema in validateValueClasses(module)) {
        expect(
          schema.inputFields.single.field.name,
          schema.binding.exportName == 'IntBox' ? 'number' : 'text',
        );
      }
      for (final code in [
        emitDart(lower(validate(module))),
        emitNativeDart(validateNative(module)),
      ]) {
        expect(code, contains('target.IntBox.named('));
        expect(code, contains('target.TextBox.other('));
      }
    },
  );

  test(
    'value projections coexist with distinct reference specializations',
    () async {
      await input.writeAsString('''
import 'package:napi/napi.dart';
class Box<T> { T value; Box(this.value); }
@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new') typedef IntBox = Box<int>;
@NAPI() typedef NullableBox = Box<int?>;
@NAPI() (IntBox, NullableBox) pair((IntBox, NullableBox) value) => value;
class Marker<T> { Marker(); }
@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new') typedef VoidMarker = Marker<void>;
@NAPI() typedef ObjectMarker = Marker<Object?>;
''');
      final module = await read();
      final plan = lower(validate(module));
      final pair = plan.functions.single.inputs.single as RecordConversion;
      expect(pair.positional[0], isA<ValueClassConversion>());
      expect(pair.positional[1], isA<ReferenceConversion>());
      expect(
        (pair.positional[1] as ReferenceConversion).classBinding.exportName,
        'NullableBox',
      );
      expect(plan.classes.map((c) => c.binding.exportName), [
        'NullableBox',
        'ObjectMarker',
      ]);
      expect(validateNative(module).classes, hasLength(2));
      await input.writeAsString(
        input.readAsStringSync().replaceFirst('Box<int?>', 'Box<int>'),
      );
      final duplicate = await read();
      expect(() => validate(duplicate), throwsA(diagnostic('NAPI_GENERIC')));
      expect(
        () => validateNative(duplicate),
        throwsA(diagnostic('NAPI_GENERIC')),
      );
    },
  );

  test(
    'type-only value aliases do not require distinct Dart runtime tests',
    () async {
      await input.writeAsString('''
import 'package:napi/napi.dart';
class Marker<T> { Marker(); }
@NAPI(classPolicy: ClassPolicy.value) typedef VoidMarker = Marker<void>;
@NAPI(classPolicy: ClassPolicy.value) typedef ObjectMarker = Marker<Object?>;
''');
      final module = await read();
      final plan = lower(validate(module));
      expect(plan.calls, isEmpty);
      final declaration = emitDeclarations(plan);
      expect(declaration, contains('export type VoidMarker ='));
      expect(declaration, contains('export type ObjectMarker ='));
      expect(
        emitNativeDeclarations(validateNative(module))
            .split('\n')
            .where(
              (line) =>
                  line.startsWith('type ') || line.startsWith('export type '),
            ),
        declaration
            .split('\n')
            .where(
              (line) =>
                  line.startsWith('type ') || line.startsWith('export type '),
            ),
      );
    },
  );

  test('opaque names may shadow hidden concrete value arguments', () async {
    await input.writeAsString('''
import 'package:napi/napi.dart';
@NAPI() class Leaf { Leaf(); }
class Box<T> { T value; Box(this.value); }
@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
typedef LeafBox = Box<Leaf>;
@NAPI() LeafBox echo<Leaf>(LeafBox value, Leaf payload) => value;
''');
    final module = await read();
    expect(
      emitDeclarations(lower(validate(module))),
      contains('<Leaf = unknown>'),
    );
    expect(
      emitNativeDeclarations(validateNative(module)),
      contains('<Leaf = unknown>'),
    );
  });

  test('value bounds and F-bounds use resolved concrete arguments', () async {
    await input.writeAsString('''
import 'package:napi/napi.dart';
@NAPI() class Ranked implements Comparable<Ranked> {
  Ranked();
  @override int compareTo(Ranked other) => 0;
}
class Box<T extends Comparable<T>> { final T value; Box(this.value); }
@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
typedef RankedValue = Box<Ranked>;
@NAPI() RankedValue echo(RankedValue value) => value;
''');
    final module = await read();
    final plan = lower(validate(module));
    final value = plan.functions.single.inputs.single as ValueClassConversion;
    expect(value.fields.single.conversion, isA<ReferenceConversion>());
    expect(validateNative(module).valueSchemas, hasLength(1));
    for (final declaration in [
      'class Box<T extends num> {}',
      'class Box<T extends Comparable<T>> {}',
    ]) {
      await input.writeAsString(
        "import 'package:napi/napi.dart';\n$declaration\n"
        '@NAPI(classPolicy: ClassPolicy.value) typedef Invalid = Box<String?>;',
      );
      await expectLater(read(), throwsA(diagnostic('NAPI_DART')));
    }
  });

  for (final (name, source, code) in [
    (
      'unselected expanding recursion',
      'class Node<T> { Node<List<T>>? child; } @NAPI(classPolicy: ClassPolicy.value) typedef Selected = Node<int>;',
      'NAPI_TYPE',
    ),
    (
      'open value',
      '@NAPI(classPolicy: ClassPolicy.value) class Box<T> { T value; Box(this.value); }',
      'NAPI_GENERIC',
    ),
    (
      'dynamic argument',
      'class Box<T> {} @NAPI(classPolicy: ClassPolicy.value) typedef Selected = Box<dynamic>;',
      'NAPI_GENERIC',
    ),
    (
      'callback field',
      'class Box<T> { T value; Box(this.value); } @NAPI(classPolicy: ClassPolicy.value) typedef Selected = Box<void Function()>;',
      'NAPI_CALLBACK',
    ),
  ]) {
    test('concrete value rejects $name', () async {
      await input.writeAsString("import 'package:napi/napi.dart';\n$source");
      final module = await read();
      expect(() => validate(module), throwsA(diagnostic(code)));
      expect(() => validateNative(module), throwsA(diagnostic(code)));
    });
  }
}
