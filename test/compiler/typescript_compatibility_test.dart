import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/emit/typescript/documentation.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

void main() {
  late String declarations;
  late Directory directory;
  Future<String> emit(String text, String fileName) async {
    final source = File('${directory.path}/$fileName.dart');
    await source.writeAsString(text);
    final module = await AnnotationFrontend(
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
    ).read(source.uri);
    final wasm = emitDeclarations(lower(validate(module)));
    expect(emitNativeDeclarations(validateNative(module)), wasm);
    return wasm;
  }

  setUpAll(() async {
    directory = await Directory.systemTemp.createTemp('napi-ts-compat-');
    addTearDown(() => directory.delete(recursive: true));
    declarations = await emit('''
import 'package:napi/napi.dart';
/// A public row with mutable output values.
typedef Row = ({String label, List<int> values});
/// A nullable record alias.
typedef MaybeRow = ({int value})?;
/// An outer alias keeps its own comment.
typedef OtherRow = Row;
typedef Unused = ({int value});
typedef _Private = ({int value});
typedef Generic<T> = ({T value});
/// Echo **rows** without losing [Row].
///
/// Literal */ text remains inside the comment.
@NAPI() List<Row> rows(List<Row> input) => input;
@NAPI() MaybeRow? maybe(MaybeRow? input) => input;
@NAPI() OtherRow outer(OtherRow input) => input;
@NAPI() Row? nullableUse(Row? input) => input;
@NAPI(bigint: true) Row bigRow(Row input) => input;
@NAPI() _Private privateRow(_Private input) => input;
@NAPI() Generic<int> genericRow(Generic<int> input) => input;
@NAPI() List<int> callback(List<int> Function(List<int>) transform) => transform([1]);
/// A documented reference class.
@NAPI() class Counter {
  /// Make a counter.
  Counter();
  /// Make a seeded counter.
  Counter.seed(this.value);
  /// Current count.
  int value = 1;
  /// Read the doubled count.
  int get doubled => value * 2;
  /// Advance the count.
  int increment() => ++value;
}
/// A documented value class.
@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new') class Packet {
  /// Packet values.
  final List<int> values;
  const Packet(this.values);
}
@NAPI() Packet packet(Packet input) => input;
@NAPI() List<int> shadow<ReadonlyArray>(List<int> input, ReadonlyArray value) => input;
''', 'entry');
  });

  test('copied List inputs are recursively readonly and outputs mutable', () {
    expect(
      declarations,
      contains(
        'rows(input: ReadonlyArray<{ label: string; values: ReadonlyArray<number> }>):',
      ),
    );
    expect(
      declarations,
      contains('Array<{ label: string; values: Array<number> }>'),
    );
    expect(
      declarations,
      contains('transform: (arg0: Array<number>) => ReadonlyArray<number>'),
    );
    expect(declarations, contains('input: globalThis.ReadonlyArray<number>'));
  });

  test('Dartdoc reaches functions, classes, constructors and properties', () {
    for (final text in [
      'Echo **rows** without losing [Row].',
      r'Literal *\/ text remains inside the comment.',
      'A documented reference class.',
      'Make a counter.',
      'Make a seeded counter.',
      'Current count.',
      'Read the doubled count.',
      'Advance the count.',
      'A documented value class.',
      'Packet values.',
    ]) {
      expect(declarations, contains(' * $text'));
    }
  });

  test(
    'public record aliases retain names, declaration nullability and docs',
    () {
      expect(
        declarations,
        contains('export type Row = { label: string; values: Array<number> };'),
      );
      expect(
        declarations,
        contains('export type MaybeRow = { value: number } | null;'),
      );
      expect(
        declarations,
        contains(
          'export type OtherRow = { label: string; values: Array<number> };',
        ),
      );
      expect(
        declarations,
        contains('A public row with mutable output values.'),
      );
      expect(declarations, contains('An outer alias keeps its own comment.'));
      expect(declarations, contains('values: ReadonlyArray<bigint>'));
      for (final omitted in ['Unused', '_Private', 'Generic']) {
        expect(declarations, isNot(contains('export type $omitted')));
      }
    },
  );

  test('record alias names cannot collide with selected exports', () async {
    await expectLater(
      emit('''
import 'package:napi/napi.dart';
typedef Row = ({int value});
@NAPI() Row echo(Row value) => value;
@NAPI(name: 'Row') class Counter { Counter(); }
''', 'collision'),
      throwsA(predicate((error) => error.toString().contains('NAPI_NAME'))),
    );
    await File('${directory.path}/first.dart')
        .writeAsString('typedef Row = ({int value});');
    await File('${directory.path}/second.dart')
        .writeAsString('typedef Row = ({String value});');
    await expectLater(
      emit('''
import 'package:napi/napi.dart';
import 'first.dart' as first;
import 'second.dart' as second;
@NAPI() first.Row a(first.Row value) => value;
@NAPI() second.Row b(second.Row value) => value;
''', 'libraries'),
      throwsA(predicate((error) => error.toString().contains('NAPI_NAME'))),
    );
  });

  test(
    'block Dartdoc preserves formatting and empty comments emit nothing',
    () {
      expect(
        emitDocumentation(
          '/**\n * Example:\n *\n *   ```ts\n *   call();\n *   ```\n */',
        ),
        '/**\n * Example:\n *\n *   ```ts\n *   call();\n *   ```\n */',
      );
      expect(emitDocumentation('/**/'), isEmpty);
      expect(emitDocumentation('///'), isEmpty);
      expect(emitDocumentation('A value.'), '/**\n * A value.\n */');
      expect(emitDocumentation('x'), '/**\n * x\n */');
      expect(emitDocumentation('*/'), '/**\n * *\\/\n */');
    },
  );
}
