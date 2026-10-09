import 'dart:convert';
import 'dart:io';

import 'package:napi/src/exports.dart';
import 'package:napi/src/typescript.dart';
import 'package:path/path.dart' as path;
import 'package:test/test.dart';

void main() {
  late Directory fixture;
  var sourceCount = 0;

  setUpAll(() async {
    fixture = await Directory.systemTemp.createTemp('napi_exports_');
    final original = File(
      path.join(Directory.current.path, '.dart_tool', 'package_config.json'),
    );
    final configuration =
        jsonDecode(await original.readAsString()) as Map<String, dynamic>;
    for (final package in configuration['packages'] as List<dynamic>) {
      package['rootUri'] = original.absolute.uri
          .resolve(package['rootUri'] as String)
          .toString();
    }
    final toolDirectory = Directory(path.join(fixture.path, '.dart_tool'));
    await toolDirectory.create();
    await File(path.join(toolDirectory.path, 'package_config.json'))
        .writeAsString(jsonEncode(configuration));
    await File(path.join(fixture.path, 'pubspec.yaml')).writeAsString('''
name: napi_exports_fixture
environment:
  sdk: ^3.13.5
''');
  });

  tearDownAll(() => fixture.delete(recursive: true));

  Future<List<Export>> analyze(String source) async {
    final file = File(path.join(fixture.path, 'source_${sourceCount++}.dart'));
    await file.writeAsString(source);
    return readExports(file.path);
  }

  test('named records keep mixed scalar fields and canonical order', () async {
    final exports = await analyze('''
import 'dart:core' as core;
import 'package:napi/napi.dart';

@napi
({core.String name, core.int age, core.bool? active, core.double? score}) echo(
  ({core.double? score, core.bool? active, core.int age, core.String name}) user,
) => user;
@napi
({core.int value})? nullable(({core.int value})? value) => value;
''');
    final record = exports.first.returnType;
    expect(record.kind, ValueKind.recordType);
    expect(record.recordAlias, isNull);
    expect(record.recordFields.map((field) => field.name), [
      'active',
      'age',
      'name',
      'score',
    ]);
    expect(
      record.recordFields.map(
        (field) => (field.type.kind, field.type.nullable),
      ),
      [
        (ValueKind.boolType, true),
        (ValueKind.intType, false),
        (ValueKind.stringType, false),
        (ValueKind.doubleType, true),
      ],
    );
    expect(
      exports.first.parameters.single.type.recordFields.map(
        (field) => (field.name, field.type.kind, field.type.nullable),
      ),
      record.recordFields.map(
        (field) => (field.name, field.type.kind, field.type.nullable),
      ),
    );
    expect(exports.last.returnType.nullable, isTrue);
    expect(generateTypescript(exports), '''
export declare function echo(user: { "active": boolean | null; "age": number; "name": string; "score": number | null }): { "active": boolean | null; "age": number; "name": string; "score": number | null };
export declare function nullable(value: { "value": number } | null): { "value": number } | null;
''');
  });

  test('record aliases emit once with nullable and Future uses', () async {
    final exports = await analyze('''
import 'dart:async' as tasks;
import 'package:napi/napi.dart';

typedef User = ({String name, int age, bool? active});
@napi
User echo(User user) => user;
@napi
tasks.Future<User?> later(User? user) async => user;
@napi
tasks.Future<({double? score})?> inline(({double? score})? value) => tasks.Future.value(value);
''');
    final alias = exports.first.returnType.recordAlias!;
    expect(alias.name, 'User');
    expect(alias.libraryUri, startsWith('file:'));
    expect(alias.nullable, isFalse);
    expect(exports[1].returnType.nullable, isTrue);
    expect(exports[1].returnType.recordAlias, alias);
    expect(exports[1].isAsync, isTrue);
    expect(exports[2].returnType.recordAlias, isNull);
    expect(generateTypescript(exports), '''
export type User = { "active": boolean | null; "age": number; "name": string };
export declare function echo(user: User): User;
export declare function later(user: User | null): Promise<User | null>;
export declare function inline(value: { "score": number | null } | null): Promise<{ "score": number | null } | null>;
''');
  });

  test('record alias chains preserve outer names and nullable RHSs', () async {
    final exports = await analyze('''
import 'package:napi/napi.dart';

typedef Base = ({int count});
typedef Maybe = Base?;
typedef Outer = Maybe;
typedef Present = Base;
typedef Direct = ({String name})?;
@napi
Outer echo(Outer value) => value;
@napi
Future<Outer?> later(Outer? value) async => value;
@napi
Present present(Present value) => value;
@napi
Direct direct(Direct? value) => value;
''');
    expect(exports.first.returnType.recordAlias!.name, 'Outer');
    expect(exports.first.returnType.recordAlias!.nullable, isTrue);
    expect(exports.first.returnType.nullable, isTrue);
    expect(exports[2].returnType.recordAlias!.name, 'Present');
    expect(exports[2].returnType.recordAlias!.nullable, isFalse);
    expect(exports[2].returnType.nullable, isFalse);
    expect(generateTypescript(exports), '''
export type Direct = { "name": string } | null;
export type Outer = { "count": number } | null;
export type Present = { "count": number };
export declare function echo(value: Outer): Outer;
export declare function later(value: Outer): Promise<Outer>;
export declare function present(value: Present): Present;
export declare function direct(value: Direct): Direct;
''');
  });

  test('structurally equal aliases retain different public names', () async {
    final exports = await analyze('''
import 'package:napi/napi.dart';
typedef First = ({String name});
typedef Second = ({String name});
@napi
Second echo(First value) => value;
''');
    expect(generateTypescript(exports), '''
export type First = { "name": string };
export type Second = { "name": string };
export declare function echo(value: First): Second;
''');
  });

  test(
    'prefixed and re-exported aliases use their original identity',
    () async {
      final models = File(path.join(fixture.path, 'record_models.dart'));
      await models.writeAsString('typedef User = ({String name, int age});\n');
      await File(path.join(fixture.path, 'record_reexport.dart'))
          .writeAsString("export 'record_models.dart' show User;\n");
      final exports = await analyze('''
import 'package:napi/napi.dart';
import 'record_models.dart' as models;
import 'record_reexport.dart' as exposed;
@napi
models.User echo(exposed.User value) => value;
''');
      expect(
        exports.single.returnType.recordAlias!.libraryUri,
        models.uri.toString(),
      );
      expect(
        exports.single.returnType.recordAlias,
        exports.single.parameters.single.type.recordAlias,
      );
      expect(generateTypescript(exports), '''
export type User = { "age": number; "name": string };
export declare function echo(value: User): User;
''');
    },
  );

  test('record typedefs and functions in parts share a library', () async {
    final library = File(path.join(fixture.path, 'record_library.dart'));
    await library.writeAsString(
      "import 'package:napi/napi.dart';\npart 'record_part.dart';\n",
    );
    await File(path.join(fixture.path, 'record_part.dart')).writeAsString('''
part of 'record_library.dart';
typedef User = ({String name});
@napi
User echo(User user) => user;
''');
    final exports = await readExports(library.path);
    expect(
      exports.single.returnType.recordAlias!.libraryUri,
      library.uri.toString(),
    );
    expect(generateTypescript(exports), '''
export type User = { "name": string };
export declare function echo(user: User): User;
''');
  });

  test('type aliases and function values may share a TS name', () async {
    await File(path.join(fixture.path, 'record_value_models.dart'))
        .writeAsString('typedef User = ({int age});\n');
    final exports = await analyze('''
import 'package:napi/napi.dart';
import 'record_value_models.dart' as models;
@napi
models.User User(models.User value) => value;
''');
    expect(generateTypescript(exports), '''
export type User = { "age": number };
export declare function User(value: User): User;
''');
  });

  test('pure named record properties need no TS binding renaming', () async {
    final exports = await analyze(r'''
import 'package:napi/napi.dart';
typedef $User = ({String constructor, bool then, double $1});
@napi
$User echo($User value) => value;
''');
    expect(generateTypescript(exports), r'''
export type $User = { "$1": number; "constructor": string; "then": boolean };
export declare function echo(value: $User): $User;
''');
  });

  test(
    'different originating aliases cannot silently share a TS name',
    () async {
      final first = File(path.join(fixture.path, 'record_first.dart'));
      final second = File(path.join(fixture.path, 'record_second.dart'));
      await first.writeAsString('typedef User = ({String name});\n');
      await second.writeAsString('typedef User = ({String name});\n');
      await expectLater(
        analyze('''
import 'package:napi/napi.dart';
import 'record_first.dart' as first;
import 'record_second.dart' as second;
@napi
second.User echo(first.User value) => value;
'''),
        throwsA(
          isA<ExportError>()
              .having((error) => error.line, 'line', 5)
              .having(
                (error) => error.message,
                'message',
                contains('Conflicting'),
              )
              .having(
                (error) => error.message,
                'first origin',
                contains(first.uri.toString()),
              )
              .having(
                (error) => error.message,
                'second origin',
                contains(second.uri.toString()),
              ),
        ),
      );
    },
  );

  for (final name in [
    'any',
    'unknown',
    'never',
    'number',
    'bigint',
    'boolean',
    'string',
    'symbol',
    'object',
    'undefined',
    'Promise',
    'Array',
    'Record',
    'Uint8Array',
    'await',
  ]) {
    test('rejects TS record alias name $name before compilation', () async {
      await expectLater(
        analyze('''
import 'package:napi/napi.dart';
typedef $name = ({int value});
@napi
$name echo($name value) => value;
'''),
        throwsA(
          isA<ExportError>().having(
            (error) => error.message,
            'message',
            contains('TypeScript record alias name'),
          ),
        ),
      );
    });
  }

  for (final entry in {
    'positional': '(int, String)',
    'mixed': '(int, {String name})',
    'empty': '()',
    'nested': '({({int value}) child})',
    'List field': '({List<int> values})',
    'Map field': '({Map<String, int> values})',
    'bytes field': '({Uint8List bytes})',
    'Object field': '({Object value})',
    'dynamic field': '({dynamic value})',
    'num field': '({num value})',
    'void field': '({void value})',
    'Future field': '({Future<int> value})',
    'callback field': '({int Function() value})',
  }.entries) {
    test('rejects ${entry.key} records with source context', () async {
      await expectLater(
        analyze('''
import 'dart:typed_data';
import 'package:napi/napi.dart';
@napi
${entry.value} echo(${entry.value} value) => value;
'''),
        throwsA(
          isA<ExportError>()
              .having((error) => error.line, 'line', 4)
              .having((error) => error.message, 'message', contains('record')),
        ),
      );
    });
  }

  for (final declaration in [
    'typedef Box<T> = ({T value});',
    'typedef Base<T> = ({T value}); typedef Box = Base<int>;',
    'typedef Box<T> = ({int value});',
  ]) {
    test('rejects generic record alias $declaration', () async {
      final generic = declaration.startsWith('typedef Box<T>');
      final type = generic ? 'Box<int>' : 'Box';
      await expectLater(
        analyze('''
import 'package:napi/napi.dart';
$declaration
@napi
$type echo($type value) => value;
'''),
        throwsA(
          isA<ExportError>().having(
            (error) => error.message,
            'message',
            contains('Generic @napi record aliases'),
          ),
        ),
      );
    });
  }

  test('private record aliases remain private boundary errors', () async {
    await expectLater(
      analyze('''
import 'package:napi/napi.dart';
typedef _User = ({String name});
@napi
_User echo(_User value) => value;
'''),
      throwsA(
        isA<ExportError>().having(
          (error) => error.message,
          'message',
          contains('record aliases must be public'),
        ),
      ),
    );
  });

  test('record scalar field aliases keep the alias restriction', () async {
    await expectLater(
      analyze('''
import 'package:napi/napi.dart';
typedef Count = int;
typedef User = ({Count age});
@napi
User echo(User value) => value;
'''),
      throwsA(
        isA<ExportError>()
            .having((error) => error.line, 'line', 3)
            .having((error) => error.column, 'column', 18)
            .having((error) => error.message, 'message', contains('User.age')),
      ),
    );
  });

  test('inline record failures point at the invalid field type', () async {
    await expectLater(
      analyze('''
import 'package:napi/napi.dart';
@napi
({String name, List<int> tags}) echo(({String name, List<int> tags}) value) => value;
'''),
      throwsA(
        isA<ExportError>()
            .having((error) => error.line, 'line', 3)
            .having((error) => error.column, 'column', 53)
            .having(
              (error) => error.message,
              'message',
              contains('"tags" type "List<int>"'),
            ),
      ),
    );
  });

  test('imported chain failures point to the defining record field', () async {
    final model = File(path.join(fixture.path, 'record_invalid_model.dart'));
    await model.writeAsString('''
typedef Base = ({
  String name,
  List<int> tags,
});
typedef User = Base;
''');
    await expectLater(
      analyze('''
import 'package:napi/napi.dart';
import 'record_invalid_model.dart' as models;
@napi
models.User echo(models.User value) => value;
'''),
      throwsA(
        isA<ExportError>()
            .having((error) => error.path, 'path', model.path)
            .having((error) => error.line, 'line', 3)
            .having((error) => error.column, 'column', 3)
            .having((error) => error.message, 'message', contains('User.tags')),
      ),
    );
  });

  for (final name in [
    '_age',
    'toString',
    'hashCode',
    'runtimeType',
    'noSuchMethod',
  ]) {
    test(
      'invalid imported record field $name fails before compilation',
      () async {
        final model = File(
          path.join(fixture.path, 'record_invalid_$name.dart'),
        );
        await model.writeAsString('''
typedef User = ({
  int $name,
});
''');
        await expectLater(
          analyze('''
import 'package:napi/napi.dart';
import 'record_invalid_$name.dart' as models;
@napi
models.User echo(models.User value) => value;
'''),
          throwsA(
            isA<ExportError>()
                .having((error) => error.path, 'path', model.path)
                .having((error) => error.line, 'line', 2)
                .having((error) => error.column, 'column', 7)
                .having(
                  (error) => error.message,
                  'message',
                  contains('Invalid @napi record field "User.$name"'),
                ),
          ),
        );
      },
    );
  }

  test(
    'duplicate imported record fields locate the second declaration',
    () async {
      final model = File(
        path.join(fixture.path, 'record_duplicate_model.dart'),
      );
      await model.writeAsString('''
typedef Base = ({
  int age,
  int age,
});
typedef User = Base;
''');
      await expectLater(
        analyze('''
import 'package:napi/napi.dart';
import 'record_duplicate_model.dart' as models;
@napi
models.User echo(models.User value) => value;
'''),
        throwsA(
          isA<ExportError>()
              .having((error) => error.path, 'path', model.path)
              .having((error) => error.line, 'line', 3)
              .having((error) => error.column, 'column', 7)
              .having(
                (error) => error.message,
                'message',
                contains('Duplicate @napi record field "User.age"'),
              ),
        ),
      );
    },
  );

  test('part record failures point to the part field declaration', () async {
    final library = File(
      path.join(fixture.path, 'record_invalid_library.dart'),
    );
    final part = File(path.join(fixture.path, 'record_invalid_part.dart'));
    await part.writeAsString('''
part of 'record_invalid_library.dart';
typedef User = ({
  String name,
  Uint8List bytes,
});
''');
    await library.writeAsString(
      "import 'dart:typed_data';\nimport 'package:napi/napi.dart';\n"
      "part 'record_invalid_part.dart';\n@napi\nUser echo(User value) => value;\n",
    );
    await expectLater(
      readExports(library.path),
      throwsA(
        isA<ExportError>()
            .having((error) => error.path, 'path', part.path)
            .having((error) => error.line, 'line', 4)
            .having((error) => error.column, 'column', 3)
            .having(
              (error) => error.message,
              'message',
              contains('User.bytes'),
            ),
      ),
    );
  });

  test(
    'resolved Dart signatures produce matching TypeScript declarations',
    () async {
      final exports = await analyze('''
import 'dart:typed_data' as bytes;
import 'package:napi/napi.dart' as api;

@api.napi
bool? flag(bool? value) => value;
@api.napi
int count(int value) => value;
@api.napi
double? scale(double? value) => value;
@api.napi
String? text(String? value) => value;
@api.napi
bytes.Uint8List? buffer(bytes.Uint8List? value) => value;
@api.napi
void reset() {}
''');

      expect(exports.map((export) => export.name), [
        'flag',
        'count',
        'scale',
        'text',
        'buffer',
        'reset',
      ]);
      expect(exports.every((export) => !export.isAsync), isTrue);
      expect(
        exports.map(
          (export) => (export.returnType.kind, export.returnType.nullable),
        ),
        [
          (ValueKind.boolType, true),
          (ValueKind.intType, false),
          (ValueKind.doubleType, true),
          (ValueKind.stringType, true),
          (ValueKind.uint8ListType, true),
          (ValueKind.voidType, false),
        ],
      );
      for (final export in exports.take(5)) {
        expect(export.parameters.single.type.kind, export.returnType.kind);
        expect(
          export.parameters.single.type.nullable,
          export.returnType.nullable,
        );
      }
      expect(generateTypescript(exports), '''
export declare function flag(value: boolean | null): boolean | null;
export declare function count(value: number): number;
export declare function scale(value: number | null): number | null;
export declare function text(value: string | null): string | null;
export declare function buffer(value: Uint8Array | null): Uint8Array | null;
export declare function reset(): void;
''');
    },
  );

  test(
    'SDK Future return signatures produce precise Promise declarations',
    () async {
      final exports = await analyze('''
import 'dart:async' as tasks;
import 'dart:typed_data' as bytes;
import 'package:napi/napi.dart';

@napi
tasks.Future<bool> flag(bool value) async => value;
@napi
tasks.Future<int> count(int value) => tasks.Future<int>.value(value);
@napi
tasks.Future<double> scale(double value) async => value;
@napi
tasks.Future<String> text(String value) async {
  await tasks.Future<void>.value();
  return value;
}
@napi
tasks.Future<bytes.Uint8List> buffer(bytes.Uint8List value) => tasks.Future.value(value);
@napi
tasks.Future<void> reset() async {}
@napi
int syncCount(int value) => value;
''');
      expect(exports.map((export) => export.isAsync), [
        true,
        true,
        true,
        true,
        true,
        true,
        false,
      ]);
      expect(exports.map((export) => export.returnType.kind), [
        ValueKind.boolType,
        ValueKind.intType,
        ValueKind.doubleType,
        ValueKind.stringType,
        ValueKind.uint8ListType,
        ValueKind.voidType,
        ValueKind.intType,
      ]);
      expect(exports.every((export) => !export.returnType.nullable), isTrue);
      expect(generateTypescript(exports), '''
export declare function flag(value: boolean): Promise<boolean>;
export declare function count(value: number): Promise<number>;
export declare function scale(value: number): Promise<number>;
export declare function text(value: string): Promise<string>;
export declare function buffer(value: Uint8Array): Promise<Uint8Array>;
export declare function reset(): Promise<void>;
export declare function syncCount(value: number): number;
''');
    },
  );

  test(
    'Future nullable completion values retain null in Promise types',
    () async {
      final exports = await analyze('''
import 'dart:async' show Future;
import 'dart:typed_data';
import 'package:napi/napi.dart';

@napi
Future<bool?> flag() => Future<bool?>.value(null);
@napi
Future<int?> count() async => null;
@napi
Future<double?> scale() => Future<double?>.value(null);
@napi
Future<String?> text() async => null;
@napi
Future<Uint8List?> buffer() => Future<Uint8List?>.value(null);
@napi
Future<void> done() => Future<void>.value();
''');
      expect(exports.every((export) => export.isAsync), isTrue);
      expect(
        exports.take(5).every((export) => export.returnType.nullable),
        isTrue,
      );
      expect(exports.last.returnType.kind, ValueKind.voidType);
      expect(generateTypescript(exports), '''
export declare function flag(): Promise<boolean | null>;
export declare function count(): Promise<number | null>;
export declare function scale(): Promise<number | null>;
export declare function text(): Promise<string | null>;
export declare function buffer(): Promise<Uint8Array | null>;
export declare function done(): Promise<void>;
''');
    },
  );

  test('flat SDK collections resolve through prefixed imports', () async {
    final exports = await analyze('''
import 'dart:core' as core;
import 'package:napi/napi.dart' as api;

@api.napi
core.List<core.bool> flags(core.List<core.bool> values) => values;
@api.napi
core.List<core.int> doubleAll(core.List<core.int> values) => [for (final v in values) v * 2];
@api.napi
core.List<core.double> scales(core.List<core.double> values) => values;
@api.napi
core.List<core.String> texts(core.List<core.String> values) => values;
@api.napi
core.Map<core.String, core.bool> flagLabels(core.Map<core.String, core.bool> values) => values;
@api.napi
core.Map<core.String, core.int> counts(core.Map<core.String, core.int> values) => values;
@api.napi
core.Map<core.String, core.double> weights(core.Map<core.String, core.double> values) => values;
@api.napi
core.Map<core.String, core.String> labels(core.Map<core.String, core.String> values) => {...values};
''');
    expect(exports.every((export) => !export.isAsync), isTrue);
    expect(exports.map((export) => export.returnType.kind), [
      ...List.filled(4, ValueKind.listType),
      ...List.filled(4, ValueKind.mapType),
    ]);
    expect(exports.map((export) => export.returnType.elementType!.kind), [
      ValueKind.boolType,
      ValueKind.intType,
      ValueKind.doubleType,
      ValueKind.stringType,
      ValueKind.boolType,
      ValueKind.intType,
      ValueKind.doubleType,
      ValueKind.stringType,
    ]);
    for (final export in exports) {
      final input = export.parameters.single.type;
      final result = export.returnType;
      expect(input.kind, result.kind);
      expect(input.elementType!.kind, result.elementType!.kind);
      expect(input.nullable, isFalse);
      expect(input.elementType!.nullable, isFalse);
      expect(input.elementType!.elementType, isNull);
      expect(result.nullable, isFalse);
      expect(result.elementType!.nullable, isFalse);
    }
    expect(generateTypescript(exports), '''
export declare function flags(values: boolean[]): boolean[];
export declare function doubleAll(values: number[]): number[];
export declare function scales(values: number[]): number[];
export declare function texts(values: string[]): string[];
export declare function flagLabels(values: Record<string, boolean>): Record<string, boolean>;
export declare function counts(values: Record<string, number>): Record<string, number>;
export declare function weights(values: Record<string, number>): Record<string, number>;
export declare function labels(values: Record<string, string>): Record<string, string>;
''');
  });

  test('collection and scalar leaf nullability remain independent', () async {
    final exports = await analyze('''
import 'package:napi/napi.dart';
@napi
List<int?> leaf(List<int?> values) => values;
@napi
List<int>? container(List<int>? values) => values;
@napi
List<int?>? both(List<int?>? values) => values;
@napi
Map<String, String?> mapLeaf(Map<String, String?> values) => values;
@napi
Map<String, String>? mapContainer(Map<String, String>? values) => values;
@napi
Map<String, String?>? mapBoth(Map<String, String?>? values) => values;
@napi
List<bool?>? flags(List<bool?>? values) => values;
@napi
Map<String, double?>? weights(Map<String, double?>? values) => values;
''');
    expect(
      exports.map(
        (export) => (
          export.returnType.nullable,
          export.returnType.elementType!.nullable,
        ),
      ),
      [
        (false, true),
        (true, false),
        (true, true),
        (false, true),
        (true, false),
        (true, true),
        (true, true),
        (true, true),
      ],
    );
    for (final export in exports) {
      expect(
        export.parameters.single.type.nullable,
        export.returnType.nullable,
      );
      expect(
        export.parameters.single.type.elementType!.nullable,
        export.returnType.elementType!.nullable,
      );
    }
    expect(generateTypescript(exports), '''
export declare function leaf(values: Array<number | null>): Array<number | null>;
export declare function container(values: number[] | null): number[] | null;
export declare function both(values: Array<number | null> | null): Array<number | null> | null;
export declare function mapLeaf(values: Record<string, string | null>): Record<string, string | null>;
export declare function mapContainer(values: Record<string, string> | null): Record<string, string> | null;
export declare function mapBoth(values: Record<string, string | null> | null): Record<string, string | null> | null;
export declare function flags(values: Array<boolean | null> | null): Array<boolean | null> | null;
export declare function weights(values: Record<string, number | null> | null): Record<string, number | null> | null;
''');
  });

  test(
    'ordinary and async Futures retain collection completion types',
    () async {
      final exports = await analyze('''
import 'dart:async' as tasks;
import 'dart:core' as core;
import 'package:napi/napi.dart';
@napi
tasks.Future<core.List<core.int?>?> later(core.List<core.int?>? values) async => values;
@napi
tasks.Future<core.Map<core.String, core.String?>?> labels(core.Map<core.String, core.String?>? values) => tasks.Future.value(values);
@napi
tasks.Future<core.List<core.bool>> flags() => tasks.Future.value([true]);
''');
      expect(exports.every((export) => export.isAsync), isTrue);
      expect(exports.map((export) => export.returnType.kind), [
        ValueKind.listType,
        ValueKind.mapType,
        ValueKind.listType,
      ]);
      expect(exports.map((export) => export.returnType.nullable), [
        true,
        true,
        false,
      ]);
      expect(exports.map((export) => export.returnType.elementType!.nullable), [
        true,
        true,
        false,
      ]);
      expect(generateTypescript(exports), '''
export declare function later(values: Array<number | null> | null): Promise<Array<number | null> | null>;
export declare function labels(values: Record<string, string | null> | null): Promise<Record<string, string | null> | null>;
export declare function flags(): Promise<boolean[]>;
''');
    },
  );

  final unsupportedCollections = <String, (String, String)>{
    'raw List': ('List', 'collection leaf type "dynamic"'),
    'raw Map': ('Map', 'Map keys must be non-nullable String'),
    'non-String Map key': (
      'Map<int, String>',
      'Map keys must be non-nullable String',
    ),
    'nullable Map key': (
      'Map<String?, int>',
      'Map keys must be non-nullable String',
    ),
    'dynamic List leaf': ('List<dynamic>', 'collection leaf type "dynamic"'),
    'num List leaf': ('List<num>', 'collection leaf type "num"'),
    'object Map leaf': (
      'Map<String, Object?>',
      'collection leaf type "Object?"',
    ),
    'byte List leaf': ('List<Uint8List>', 'collection leaf type "Uint8List"'),
    'byte Map leaf': (
      'Map<String, Uint8List?>',
      'collection leaf type "Uint8List?"',
    ),
    'nested List': ('List<List<int>>', 'collection leaf type "List<int>"'),
    'Map inside List': (
      'List<Map<String, int>>',
      'collection leaf type "Map<String, int>"',
    ),
    'List inside Map': (
      'Map<String, List<int>>',
      'collection leaf type "List<int>"',
    ),
    'nested Map': (
      'Map<String, Map<String, String>>',
      'collection leaf type "Map<String, String>"',
    ),
    'Future List leaf': (
      'List<Future<int>>',
      'collection leaf type "Future<int>"',
    ),
    'callback Map leaf': (
      'Map<String, void Function()>',
      'collection leaf type "void Function()"',
    ),
  };
  for (final entry in unsupportedCollections.entries) {
    test('rejects ${entry.key} at the collection parameter type', () async {
      await expectLater(
        analyze('''
import 'dart:async';
import 'dart:typed_data';
import 'package:napi/napi.dart';
@napi
void inspect(${entry.value.$1} value) {}
'''),
        throwsA(
          isA<ExportError>()
              .having((error) => error.path, 'path', startsWith(fixture.path))
              .having((error) => error.line, 'line', 5)
              .having((error) => error.column, 'column', 14)
              .having(
                (error) => error.message,
                'message',
                contains(entry.value.$2),
              ),
        ),
      );
    });
  }

  for (final type in ['List<int>', 'Map<String, int>']) {
    test('same-named user $type is not an SDK collection', () async {
      await expectLater(
        analyze('''
import 'package:napi/napi.dart';
class List<T> {}
class Map<K, V> {}
@napi
void inspect($type value) {}
'''),
        throwsA(
          isA<ExportError>()
              .having((error) => error.line, 'line', 5)
              .having((error) => error.column, 'column', 14)
              .having(
                (error) => error.message,
                'message',
                contains('Unsupported @napi type "$type"'),
              ),
        ),
      );
    });
  }

  for (final type in [
    'Counts',
    'List<Count>',
    'Map<Key, int>',
    'Map<String, Count>',
  ]) {
    test(
      'rejects the collection alias in $type with a source location',
      () async {
        await expectLater(
          analyze('''
import 'package:napi/napi.dart';
typedef Counts = List<int>;
typedef Count = int;
typedef Key = String;
@napi
void inspect($type value) {}
'''),
          throwsA(
            isA<ExportError>()
                .having((error) => error.line, 'line', 6)
                .having((error) => error.column, 'column', 14)
                .having(
                  (error) => error.message,
                  'message',
                  contains('Type aliases are not supported'),
                ),
          ),
        );
      },
    );
  }

  test(
    'unsupported Future collection completion reports the return type',
    () async {
      await expectLater(
        analyze('''
import 'dart:async';
import 'dart:typed_data';
import 'package:napi/napi.dart';
@napi
Future<List<Uint8List>> bad() => throw UnimplementedError();
'''),
        throwsA(
          isA<ExportError>()
              .having((error) => error.line, 'line', 5)
              .having((error) => error.column, 'column', 1)
              .having(
                (error) => error.message,
                'message',
                contains('collection leaf type "Uint8List"'),
              ),
        ),
      );
    },
  );

  test('a user class named Future is not treated as an SDK Future', () async {
    await expectLater(
      analyze('''
import 'package:napi/napi.dart';
class Future<T> {}
@napi
Future<int> count() => Future<int>();
'''),
      throwsA(
        isA<ExportError>().having(
          (error) => error.message,
          'message',
          contains('Unsupported @napi type "Future<int>"'),
        ),
      ),
    );
  });

  test(
    'Future typedefs keep the existing signature alias restriction',
    () async {
      await expectLater(
        analyze('''
import 'dart:async' as tasks;
import 'package:napi/napi.dart';
typedef Pending = tasks.Future<int>;
@napi
Pending count() => tasks.Future<int>.value(1);
'''),
        throwsA(
          isA<ExportError>().having(
            (error) => error.message,
            'message',
            contains('Type aliases are not supported'),
          ),
        ),
      );
    },
  );

  test(
    'resolved annotation provenance ignores a same-named annotation',
    () async {
      final exports = await analyze('''
import 'package:napi/napi.dart' as api;
class Napi { const Napi(); }
const napi = Napi();
@napi
dynamic unrelated(dynamic value) => value;
@api.Napi()
int add(int a, int b) => a + b;
''');
      expect(exports.single.name, 'add');
      expect(exports.single.returnType.kind, ValueKind.intType);
    },
  );

  test('the supported Uint8List is identified by its SDK library', () async {
    await expectLater(
      analyze('''
import 'package:napi/napi.dart';
class Uint8List {}
@napi
Uint8List echo(Uint8List value) => value;
'''),
      throwsA(
        isA<ExportError>().having(
          (error) => error.message,
          'message',
          contains('Unsupported @napi type "Uint8List"'),
        ),
      ),
    );
  });

  test(
    'rejects aliases even when their underlying type is supported',
    () async {
      await expectLater(
        analyze('''
import 'package:napi/napi.dart';
typedef Count = int;
@napi
Count count(Count value) => value;
'''),
        throwsA(
          isA<ExportError>().having(
            (error) => error.message,
            'message',
            contains('Type aliases are not supported'),
          ),
        ),
      );
    },
  );

  final unsupported = <String, (String, String)>{
    'private function': ('int _add(int a) => a;', 'must be public'),
    'named parameter': (
      'int add({required int a}) => a;',
      'required positional',
    ),
    'optional parameter': (
      'int add(int a, [int b = 0]) => a + b;',
      'required positional',
    ),
    'generic function': (
      'T echo<T>(T value) => value;',
      'Generic @napi functions',
    ),
    'async void': ('void clear() async {}', 'must return Future<T>'),
    'generator': (
      'Iterable<int> values() sync* { yield 1; }',
      'cannot be generators',
    ),
    'Future parameter': (
      'int inspect(Future<int> value) => 1;',
      'Unsupported @napi type "Future<int>"',
    ),
    'nullable Future return': (
      'Future<int>? add() => null;',
      'Nullable Future returns are not supported',
    ),
    'FutureOr return': (
      'FutureOr<int> add() => 1;',
      'Unsupported @napi type "FutureOr<int>"',
    ),
    'nested Future return': (
      'Future<Future<int>> add() => throw UnimplementedError();',
      'Unsupported @napi type "Future<int>"',
    ),
    'raw Future return': (
      'Future add() => Future.value(1);',
      'Unsupported @napi type "dynamic"',
    ),
    'Stream return': (
      'Stream<int> values() => Stream<int>.empty();',
      'Unsupported @napi type "Stream<int>"',
    ),
    'Future Stream completion': (
      'Future<Stream<int>> values() => throw UnimplementedError();',
      'Unsupported @napi type "Stream<int>"',
    ),
    'callback parameter': (
      'int invoke(int Function(int) callback) => callback(1);',
      'Unsupported @napi type "int Function(int)"',
    ),
    'Future callback completion': (
      'Future<int Function(int)> callback() => throw UnimplementedError();',
      'Unsupported @napi type "int Function(int)"',
    ),
    'async generator': (
      'Stream<int> values() async* { yield 1; }',
      'cannot be generators',
    ),
    'dynamic parameter': (
      'int add(dynamic value) => 1;',
      'Unsupported @napi type "dynamic"',
    ),
    'implicit dynamic return': (
      'add(int value) => value;',
      'Unsupported @napi type "dynamic"',
    ),
    'class': ('class Counter {}', 'top-level functions only'),
    'variable': ('const answer = 42;', 'top-level functions only'),
    'JavaScript reserved name': (
      'int delete(int a) => a;',
      'reserved JavaScript export name',
    ),
    'Promise-like module export': (
      'int then(int a) => a;',
      'JavaScript dynamic import treats it as a Promise callback',
    ),
  };
  for (final entry in unsupported.entries) {
    test('rejects ${entry.key} with a source location', () async {
      await expectLater(
        analyze(
          "import 'dart:async';\nimport 'package:napi/napi.dart';\n@napi\n${entry.value.$1}\n",
        ),
        throwsA(
          isA<ExportError>()
              .having((error) => error.path, 'path', startsWith(fixture.path))
              .having((error) => error.line, 'line', greaterThanOrEqualTo(2))
              .having(
                (error) => error.column,
                'column',
                greaterThanOrEqualTo(1),
              )
              .having(
                (error) => error.message,
                'message',
                contains(entry.value.$2),
              ),
        ),
      );
    });
  }

  test(
    'rejects method annotations instead of silently ignoring them',
    () async {
      await expectLater(
        analyze('''
import 'package:napi/napi.dart';
class Counter {
  @napi
  int increment(int value) => value + 1;
}
'''),
        throwsA(
          isA<ExportError>()
              .having((error) => error.line, 'line', 3)
              .having((error) => error.column, 'column', 3)
              .having(
                (error) => error.message,
                'message',
                contains('top-level functions only'),
              ),
        ),
      );
    },
  );

  test('rejects duplicate annotations', () async {
    await expectLater(
      analyze(
        "import 'package:napi/napi.dart';\n@napi\n@napi\nint add(int value) => value;\n",
      ),
      throwsA(
        isA<ExportError>().having(
          (error) => error.message,
          'message',
          contains('Duplicate @napi'),
        ),
      ),
    );
  });

  test('reports analyzer errors before generating a bridge', () async {
    await expectLater(
      analyze(
        "import 'package:napi/napi.dart';\n@napi\nint add(int a) => missing;\n",
      ),
      throwsA(
        isA<ExportError>()
            .having((error) => error.line, 'line', 3)
            .having(
              (error) => error.message,
              'message',
              contains("Undefined name 'missing'"),
            ),
      ),
    );
  });

  test(
    'an unannotated library cannot silently produce an empty package',
    () async {
      await expectLater(
        analyze('int add(int a, int b) => a + b;\n'),
        throwsA(
          isA<ExportError>().having(
            (error) => error.message,
            'message',
            'No @napi functions found.',
          ),
        ),
      );
    },
  );

  test('annotations in part files belong to the input library', () async {
    final library = File(path.join(fixture.path, 'library.dart'));
    await library.writeAsString(
      "import 'package:napi/napi.dart';\npart 'library_part.dart';\n",
    );
    final part = File(path.join(fixture.path, 'library_part.dart'));
    await part.writeAsString(
      "part of 'library.dart';\n@napi\nint add(int a, int b) => a + b;\n",
    );
    expect((await readExports(library.path)).single.name, 'add');
    await expectLater(
      readExports(part.path),
      throwsA(
        isA<ExportError>().having(
          (error) => error.message,
          'message',
          contains('not a part file'),
        ),
      ),
    );
  });

  test(
    'TypeScript parameter bindings cannot use JavaScript reserved words',
    () async {
      final exports = await analyze(
        "import 'package:napi/napi.dart';\n@napi\nint inspect(int delete) => delete;\n",
      );
      expect(
        generateTypescript(exports),
        'export declare function inspect(arg0: number): number;\n',
      );
    },
  );

  test(
    'TypeScript fallback parameters cannot collide with Dart names',
    () async {
      final exports = await analyze('''
import 'package:napi/napi.dart';
@napi
int inspect(int delete, int arg0, int typeof, int arg1) => delete + arg0 + typeof + arg1;
''');
      expect(
        generateTypescript(exports),
        'export declare function inspect(arg2: number, arg0: number, arg3: number, arg1: number): number;\n',
      );
    },
  );

  test('then remains a valid parameter name', () async {
    final exports = await analyze(
      "import 'package:napi/napi.dart';\n@napi\nint inspect(int then) => then;\n",
    );
    expect(
      generateTypescript(exports),
      'export declare function inspect(then: number): number;\n',
    );
  });

  for (final name in [r'$invokeMain', r'$wasmI16ArrayGet']) {
    test('rejects the SDK export $name at its source location', () async {
      await expectLater(
        analyze("import 'package:napi/napi.dart';\n@napi\nint $name() => 1;\n"),
        throwsA(
          isA<ExportError>()
              .having((error) => error.path, 'path', startsWith(fixture.path))
              .having((error) => error.line, 'line', 3)
              .having((error) => error.column, 'column', 5)
              .having(
                (error) => error.message,
                'message',
                '"$name" is a reserved Dart Wasm export name.',
              ),
        ),
      );
    });
  }

  test(
    'ordinary dollar exports remain valid near SDK reserved names',
    () async {
      final exports = await analyze(r'''
import 'package:napi/napi.dart';
@napi
int $napiReadFile() => 1;
@napi
int $invokeMainBusiness() => 2;
@napi
int $wasmI16ArrayGetBusiness() => 3;
''');
      expect(exports.map((export) => export.name), [
        r'$napiReadFile',
        r'$invokeMainBusiness',
        r'$wasmI16ArrayGetBusiness',
      ]);
    },
  );
}
