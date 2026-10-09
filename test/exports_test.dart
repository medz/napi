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

  Future<File> relatedLibrary(Map<String, String> sources) async {
    final directory = Directory(
      path.join(fixture.path, 'related_${sourceCount++}'),
    );
    await directory.create();
    for (final source in sources.entries) {
      await File(path.join(directory.path, source.key))
          .writeAsString(source.value);
    }
    return File(path.join(directory.path, 'api.dart'));
  }

  test(
    'record Lists preserve independent nullability and Future types',
    () async {
      final exports = await analyze('''
import 'dart:core' as core;
import 'dart:async' as tasks;
import 'package:napi/napi.dart';
typedef User = ({core.String name, core.int age, core.bool? active, core.double score});
@napi
core.List<User> users(core.List<User> values) => values;
@napi
core.List<User?> elements(core.List<User?> values) => values;
@napi
core.List<User>? container(core.List<User>? values) => values;
@napi
core.List<User?>? both(core.List<User?>? values) => values;
@napi
tasks.Future<core.List<User>> later(core.List<User> values) async => values;
@napi
tasks.Future<core.List<User?>?> laterBoth(core.List<User?>? values) => tasks.Future.value(values);
@napi
core.List<({core.String name, core.int id})> inline(core.List<({core.int id, core.String name})> values) => values;
@napi
tasks.Future<core.List<({core.double? score})?>?> nullableInline(core.List<({core.double? score})?>? values) async => values;
''');
      expect(
        exports
            .take(4)
            .map(
              (export) => (
                export.returnType.nullable,
                export.returnType.elementType!.nullable,
              ),
            ),
        [(false, false), (false, true), (true, false), (true, true)],
      );
      for (final export in exports) {
        expect(export.returnType.kind, ValueKind.listType);
        expect(export.returnType.elementType!.kind, ValueKind.recordType);
        expect(
          (
            export.parameters.single.type.nullable,
            export.parameters.single.type.elementType!.nullable,
          ),
          (export.returnType.nullable, export.returnType.elementType!.nullable),
        );
      }
      expect(exports[4].isAsync, isTrue);
      expect(exports[5].isAsync, isTrue);
      expect(exports[7].isAsync, isTrue);
      expect(generateTypescript(exports), '''
export type User = { "active": boolean | null; "age": number; "name": string; "score": number };
export declare function users(values: readonly User[]): User[];
export declare function elements(values: readonly (User | null)[]): Array<User | null>;
export declare function container(values: readonly User[] | null): User[] | null;
export declare function both(values: readonly (User | null)[] | null): Array<User | null> | null;
export declare function later(values: readonly User[]): Promise<User[]>;
export declare function laterBoth(values: readonly (User | null)[] | null): Promise<Array<User | null> | null>;
export declare function inline(values: readonly { "id": number; "name": string }[]): { "id": number; "name": string }[];
export declare function nullableInline(values: readonly ({ "score": number | null } | null)[] | null): Promise<Array<{ "score": number | null } | null> | null>;
''');
    },
  );

  test(
    'ReadonlyArray aliases keep mutable scalar, List and Future results',
    () async {
      final exports = await analyze('''
import 'package:napi/napi.dart';
typedef ReadonlyArray = ({int count});
@napi
ReadonlyArray scalar(ReadonlyArray value) => value;
@napi
List<ReadonlyArray> echoReadonlyArrays(List<ReadonlyArray> values) => values;
@napi
Future<List<ReadonlyArray?>?> later(List<ReadonlyArray?>? values) async => values;
''');
      expect(generateTypescript(exports), '''
export type ReadonlyArray = { "count": number };
export declare function scalar(value: ReadonlyArray): ReadonlyArray;
export declare function echoReadonlyArrays(values: readonly ReadonlyArray[]): ReadonlyArray[];
export declare function later(values: readonly (ReadonlyArray | null)[] | null): Promise<Array<ReadonlyArray | null> | null>;
''');
    },
  );

  test(
    'record byte fields preserve all independent nullable boundaries',
    () async {
      final exports = await analyze('''
import 'dart:typed_data' as bytes;
import 'package:napi/napi.dart';
typedef Payload = ({String name, bytes.Uint8List data, bytes.Uint8List? optional});
@napi
Payload echo(Payload value) => value;
@napi
Payload? nullable(Payload? value) => value;
@napi
Future<Payload?> later(Payload? value) async => value;
@napi
List<Payload> rows(List<Payload> values) => values;
@napi
List<Payload?> elements(List<Payload?> values) => values;
@napi
List<Payload>? container(List<Payload>? values) => values;
@napi
List<Payload?>? both(List<Payload?>? values) => values;
@napi
Future<List<Payload?>?> laterRows(List<Payload?>? values) async => values;
@napi
Future<({bytes.Uint8List? data, String name})?> inline(({String name, bytes.Uint8List? data})? value) async => value;
''');
      for (final export in exports.take(8)) {
        for (final type in [export.returnType, export.parameters.single.type]) {
          final record = type.kind == ValueKind.listType
              ? type.elementType!
              : type;
          expect(
            record.recordFields.map(
              (field) => (field.name, field.type.kind, field.type.nullable),
            ),
            [
              ('data', ValueKind.uint8ListType, false),
              ('name', ValueKind.stringType, false),
              ('optional', ValueKind.uint8ListType, true),
            ],
          );
        }
      }
      expect(
        exports
            .skip(3)
            .take(4)
            .map(
              (export) => (
                export.returnType.nullable,
                export.returnType.elementType!.nullable,
              ),
            ),
        [(false, false), (false, true), (true, false), (true, true)],
      );
      expect(exports[2].isAsync, isTrue);
      expect(exports[7].isAsync, isTrue);
      expect(exports[8].isAsync, isTrue);
      expect(exports[8].returnType.recordAlias, isNull);
      expect(generateTypescript(exports), '''
export type Payload = { "data": Uint8Array; "name": string; "optional": Uint8Array | null };
export declare function echo(value: Payload): Payload;
export declare function nullable(value: Payload | null): Payload | null;
export declare function later(value: Payload | null): Promise<Payload | null>;
export declare function rows(values: readonly Payload[]): Payload[];
export declare function elements(values: readonly (Payload | null)[]): Array<Payload | null>;
export declare function container(values: readonly Payload[] | null): Payload[] | null;
export declare function both(values: readonly (Payload | null)[] | null): Array<Payload | null> | null;
export declare function laterRows(values: readonly (Payload | null)[] | null): Promise<Array<Payload | null> | null>;
export declare function inline(value: { "data": Uint8Array | null; "name": string } | null): Promise<{ "data": Uint8Array | null; "name": string } | null>;
''');
    },
  );

  test(
    'imported byte record chains keep origin and nullable aliases',
    () async {
      final model = File(path.join(fixture.path, 'record_bytes_model.dart'));
      await model.writeAsString('''
import 'dart:typed_data' as bytes;
typedef Payload = ({bytes.Uint8List data, bytes.Uint8List? optional});
typedef MaybePayload = Payload?;
typedef Exposed = MaybePayload;
''');
      await File(path.join(fixture.path, 'record_bytes_reexport.dart'))
          .writeAsString("export 'record_bytes_model.dart';\n");
      final exports = await analyze('''
import 'package:napi/napi.dart';
import 'record_bytes_model.dart' as original;
import 'record_bytes_reexport.dart' as exposed;
@napi
original.Payload echo(exposed.Payload value) => value;
@napi
Future<List<original.Exposed>?> later(List<exposed.Exposed?>? values) async => values;
''');
      expect(
        exports.first.returnType.recordAlias!.libraryUri,
        model.uri.toString(),
      );
      expect(
        exports.first.parameters.single.type.recordAlias,
        exports.first.returnType.recordAlias,
      );
      final alias = exports.last.returnType.elementType!.recordAlias!;
      expect(alias.name, 'Exposed');
      expect(alias.libraryUri, model.uri.toString());
      expect(alias.nullable, isTrue);
      expect(generateTypescript(exports), '''
export type Exposed = { "data": Uint8Array; "optional": Uint8Array | null } | null;
export type Payload = { "data": Uint8Array; "optional": Uint8Array | null };
export declare function echo(value: Payload): Payload;
export declare function later(values: readonly Exposed[] | null): Promise<Array<Exposed> | null>;
''');
    },
  );

  test(
    'part byte record fields resolve the entry library SDK import',
    () async {
      final library = File(
        path.join(fixture.path, 'record_bytes_library.dart'),
      );
      await library.writeAsString('''
import 'dart:typed_data' as bytes;
import 'package:napi/napi.dart';
part 'record_bytes_part.dart';
''');
      await File(path.join(fixture.path, 'record_bytes_part.dart'))
          .writeAsString('''
part of 'record_bytes_library.dart';
typedef Payload = ({bytes.Uint8List data, bytes.Uint8List? optional});
@napi
Future<List<Payload?>?> echo(List<Payload?>? values) async => values;
''');
      final exports = await readExports(library.path);
      expect(
        exports.single.returnType.elementType!.recordAlias!.libraryUri,
        library.uri.toString(),
      );
      expect(generateTypescript(exports), '''
export type Payload = { "data": Uint8Array; "optional": Uint8Array | null };
export declare function echo(values: readonly (Payload | null)[] | null): Promise<Array<Payload | null> | null>;
''');
    },
  );

  test(
    'record Lists collect aliases once across chains and direct uses',
    () async {
      final exports = await analyze('''
import 'package:napi/napi.dart';
typedef Base = ({int id});
typedef Maybe = Base?;
typedef Outer = Maybe;
typedef Other = ({int id});
@napi
List<Outer> nullable(List<Outer?> values) => values;
@napi
Future<List<Outer>?> later(List<Outer>? values) async => values;
@napi
Base direct(Base value) => value;
@napi
List<Base> originals(List<Base> values) => values;
@napi
List<Other> other(List<Other> values) => values;
''');
      final alias = exports.first.returnType.elementType!.recordAlias!;
      expect(alias.name, 'Outer');
      expect(alias.nullable, isTrue);
      expect(exports.first.returnType.elementType!.nullable, isTrue);
      expect(generateTypescript(exports), '''
export type Base = { "id": number };
export type Other = { "id": number };
export type Outer = { "id": number } | null;
export declare function nullable(values: readonly Outer[]): Array<Outer>;
export declare function later(values: readonly Outer[] | null): Promise<Array<Outer> | null>;
export declare function direct(value: Base): Base;
export declare function originals(values: readonly Base[]): Base[];
export declare function other(values: readonly Other[]): Other[];
''');
    },
  );

  test('record Lists retain prefixed re-exported alias identity', () async {
    final model = File(path.join(fixture.path, 'record_list_model.dart'));
    await model.writeAsString('typedef User = ({String name});\n');
    await File(path.join(fixture.path, 'record_list_reexport.dart'))
        .writeAsString("export 'record_list_model.dart';\n");
    final exports = await analyze('''
import 'package:napi/napi.dart';
import 'record_list_model.dart' as original;
import 'record_list_reexport.dart' as exposed;
@napi
List<original.User> echo(List<exposed.User> values) => values;
''');
    final alias = exports.single.returnType.elementType!.recordAlias!;
    expect(alias.libraryUri, model.uri.toString());
    expect(
      exports.single.parameters.single.type.elementType!.recordAlias,
      alias,
    );
    expect(generateTypescript(exports), '''
export type User = { "name": string };
export declare function echo(values: readonly User[]): User[];
''');
  });

  test('record Lists retain aliases declared in entry library parts', () async {
    final library = File(path.join(fixture.path, 'record_list_library.dart'));
    await library.writeAsString(
      "import 'package:napi/napi.dart';\npart 'record_list_part.dart';\n",
    );
    await File(path.join(fixture.path, 'record_list_part.dart'))
        .writeAsString('''
part of 'record_list_library.dart';
typedef User = ({int id});
@napi
Future<List<User?>?> echo(List<User?>? values) async => values;
''');
    final exports = await readExports(library.path);
    expect(
      exports.single.returnType.elementType!.recordAlias!.libraryUri,
      library.uri.toString(),
    );
    expect(generateTypescript(exports), '''
export type User = { "id": number };
export declare function echo(values: readonly (User | null)[] | null): Promise<Array<User | null> | null>;
''');
  });

  test('record Lists reject alias collisions with direct boundaries', () async {
    final first = File(path.join(fixture.path, 'record_list_first.dart'));
    final second = File(path.join(fixture.path, 'record_list_second.dart'));
    await first.writeAsString('typedef User = ({int id});\n');
    await second.writeAsString('typedef User = ({int id});\n');
    await expectLater(
      analyze('''
import 'package:napi/napi.dart';
import 'record_list_first.dart' as first;
import 'record_list_second.dart' as second;
@napi
second.User echo(List<first.User> values) => values.first;
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
  });

  test(
    'record Lists reject shadowing alias names reachable only by List',
    () async {
      await expectLater(
        analyze('''
import 'package:napi/napi.dart';
typedef Promise = ({int id});
@napi
List<Promise> echo(List<Promise> values) => values;
'''),
        throwsA(
          isA<ExportError>().having(
            (error) => error.message,
            'message',
            contains('TypeScript record alias name'),
          ),
        ),
      );
    },
  );

  for (final entry in {
    'nested Lists': ('List<List<User>>', 'collection leaf type'),
    'Map record values': (
      'Map<String, User>',
      'Type aliases are not supported',
    ),
    'nested Map': ('List<Map<String, User>>', 'collection leaf type'),
    'aliased List': ('Users', 'Type aliases are not supported'),
    'record collection fields': ('List<({List<int> values})>', 'record field'),
    'generic record alias': ('List<Box<int>>', 'Generic @napi record aliases'),
    'positional records': ('List<(int, String)>', 'named fields only'),
    'empty records': ('List<()>', 'at least one field'),
  }.entries) {
    test('record Lists still exclude ${entry.key}', () async {
      await expectLater(
        analyze('''
import 'package:napi/napi.dart';
typedef User = ({int id});
typedef Users = List<User>;
typedef Box<T> = ({T value});
@napi
${entry.value.$1} echo(${entry.value.$1} values) => values;
'''),
        throwsA(
          isA<ExportError>().having(
            (error) => error.message,
            'message',
            contains(entry.value.$2),
          ),
        ),
      );
    });
  }

  test('record Lists locate unsupported inline field types inside List', () async {
    const signature =
        'List<({int id, List<int> tags})> echo(List<({int id, List<int> tags})> values) => values;';
    await expectLater(
      analyze("import 'package:napi/napi.dart';\n@napi\n$signature\n"),
      throwsA(
        isA<ExportError>()
            .having((error) => error.line, 'line', 3)
            .having(
              (error) => error.column,
              'column',
              signature.lastIndexOf('List<int>') + 1,
            )
            .having(
              (error) => error.message,
              'message',
              contains('"tags" type'),
            ),
      ),
    );
  });

  test('record Lists locate invalid fields in imported alias chains', () async {
    final model = File(path.join(fixture.path, 'record_list_invalid.dart'));
    await model.writeAsString('''
typedef Base = ({
  int _age,
});
typedef User = Base;
''');
    await expectLater(
      analyze('''
import 'package:napi/napi.dart';
import 'record_list_invalid.dart' as models;
@napi
Future<List<models.User>> echo(List<models.User> values) async => values;
'''),
      throwsA(
        isA<ExportError>()
            .having((error) => error.path, 'path', model.path)
            .having((error) => error.line, 'line', 2)
            .having((error) => error.column, 'column', 7)
            .having(
              (error) => error.message,
              'message',
              contains('Invalid @napi record field "User._age"'),
            ),
      ),
    );
  });

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

  test('Wasm analysis selects conditional imports and export chains', () async {
    final entry = await relatedLibrary({
      'stub.dart': '''
typedef Count = int;
typedef Profile = ({String name, Count count});
''',
      'web.dart': 'typedef Profile = ({String name, int count});\n',
      'models.dart':
          "export 'stub.dart' if (dart.library.js_interop) 'web.dart';\n",
      'public.dart': "export 'models.dart' show Profile;\n",
      'api.dart': '''
import 'package:napi/napi.dart';
import 'stub.dart' if (dart.library.js_interop) 'web.dart' as direct;
import 'public.dart' as models;
@napi
direct.Profile echo(models.Profile value) => value;
''',
    });
    final exports = await readExports(entry.path);
    final profile = exports.single.returnType.recordAlias;
    expect(
      profile!.libraryUri,
      File(path.join(entry.parent.path, 'web.dart')).uri.toString(),
    );
    expect(exports.single.parameters.single.type.recordAlias, profile);
    expect(generateTypescript(exports), '''
export type Profile = { "count": number; "name": string };
export declare function echo(value: Profile): Profile;
''');
  });

  test('Wasm analysis locates unsupported selected record fields', () async {
    final entry = await relatedLibrary({
      'stub.dart': 'typedef Profile = ({String name, int count});\n',
      'web.dart': '''
typedef Profile = ({
  String name,
  List<int> count,
});
''',
      'models.dart':
          "export 'stub.dart' if (dart.library.js_interop) 'web.dart';\n",
      'api.dart': '''
import 'package:napi/napi.dart';
import 'models.dart' as models;
@napi
models.Profile echo(models.Profile value) => value;
''',
    });
    await expectLater(
      readExports(entry.path),
      throwsA(
        isA<ExportError>()
            .having(
              (error) => error.path,
              'path',
              path.join(entry.parent.path, 'web.dart'),
            )
            .having((error) => error.line, 'line', 3)
            .having((error) => error.column, 'column', 3)
            .having(
              (error) => error.message,
              'message',
              contains('Profile.count'),
            ),
      ),
    );
  });

  test('Wasm analysis disables io html js and preserves fallback', () async {
    const unavailable = 'class Profile {}\nclass Fallback {}\n';
    final entry = await relatedLibrary({
      'fallback.dart': '''
typedef Profile = ({String name, int count});
typedef Fallback = ({bool available});
''',
      'web.dart': 'typedef Profile = ({String name, int count});\n',
      'io.dart': unavailable,
      'html.dart': unavailable,
      'js.dart': unavailable,
      'api.dart': '''
import 'package:napi/napi.dart';
import 'fallback.dart'
  if (dart.library.io == 'false') 'io.dart'
  if (dart.library.io) 'io.dart'
  if (dart.library.html) 'html.dart'
  if (dart.library.js) 'js.dart'
  if (dart.library.ffi) 'io.dart'
  if (dart.library._internal == 'false') 'io.dart'
  if (dart.library.unknown == '') 'io.dart'
  if (dart.library.js_interop) 'web.dart' as web;
import 'fallback.dart'
  if (dart.library.io) 'io.dart'
  if (dart.library.html) 'html.dart'
  if (dart.library.js) 'js.dart' as other;
@napi
web.Profile echo(web.Profile value) => value;
@napi
other.Fallback fallback(other.Fallback value) => value;
''',
    });
    final exports = await readExports(entry.path);
    expect(
      exports.first.returnType.recordAlias!.libraryUri,
      File(path.join(entry.parent.path, 'web.dart')).uri.toString(),
    );
    expect(
      exports.last.returnType.recordAlias!.libraryUri,
      File(path.join(entry.parent.path, 'fallback.dart')).uri.toString(),
    );
    expect(generateTypescript(exports), '''
export type Fallback = { "available": boolean };
export type Profile = { "count": number; "name": string };
export declare function echo(value: Profile): Profile;
export declare function fallback(value: Fallback): Fallback;
''');
  });

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
    'readonly',
    'keyof',
    'infer',
    'unique',
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

  for (final name in ['readonly', 'keyof', 'infer', 'unique']) {
    for (final signature in [
      'List<$name> echo(List<$name> values) => values;',
      'Future<List<$name?>?> echo(List<$name?>? values) async => values;',
    ]) {
      test('rejects $name record aliases in $signature', () async {
        await expectLater(
          analyze('''
import 'package:napi/napi.dart';
typedef $name = ({int count});
@napi
$signature
'''),
          throwsA(
            isA<ExportError>()
                .having((error) => error.line, 'line', 4)
                .having(
                  (error) => error.message,
                  'message',
                  '"$name" is a reserved or invalid TypeScript record alias name.',
                ),
          ),
        );
      });
    }
  }

  for (final name in ['readonly', 'keyof', 'infer', 'unique']) {
    test('$name remains a valid function and parameter name', () async {
      final exports = await analyze('''
import 'package:napi/napi.dart';
@napi
int $name(int $name) => $name;
''');
      expect(
        generateTypescript(exports),
        'export declare function $name($name: number): number;\n',
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
    'other typed List field': '({Uint16List bytes})',
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

  test(
    'SDK leaf aliases in imported records expand without leaf bindings',
    () async {
      final entry = await relatedLibrary({
        'models.dart': '''
import 'dart:typed_data' as bytes;
typedef _Enabled = bool;
typedef Count = int;
typedef Id = Count;
typedef MaybeId = Id?;
typedef Ratio = double;
typedef Name = String;
typedef MaybeName = Name?;
typedef Bytes = bytes.Uint8List;
typedef MaybeBytes = Bytes?;
typedef User = ({_Enabled active, MaybeId age, Bytes data, MaybeName name, MaybeBytes optional, Ratio? score});
''',
        'public.dart': "export 'models.dart' show User;\n",
        'api.dart': '''
import 'package:napi/napi.dart';
import 'public.dart' as models;
@napi
models.User echo(models.User value) => value;
''',
      });
      final exports = await readExports(entry.path);
      final record = exports.single.returnType;
      expect(
        record.recordAlias!.libraryUri,
        File(path.join(entry.parent.path, 'models.dart')).uri.toString(),
      );
      expect(
        record.recordFields.map(
          (field) => (field.type.kind, field.type.nullable),
        ),
        [
          (ValueKind.boolType, false),
          (ValueKind.intType, true),
          (ValueKind.uint8ListType, false),
          (ValueKind.stringType, true),
          (ValueKind.uint8ListType, true),
          (ValueKind.doubleType, true),
        ],
      );
      expect(generateTypescript(exports), '''
export type User = { "active": boolean; "age": number | null; "data": Uint8Array; "name": string | null; "optional": Uint8Array | null; "score": number | null };
export declare function echo(value: User): User;
''');
    },
  );

  for (final (label, declaration, type, isAlias) in [
    ('fake', 'class Uint8List {}', 'Uint8List', false),
    ('fake_nullable', 'class Uint8List {}', 'Uint8List?', false),
    (
      'generic_byte_alias',
      'typedef Bytes<T> = bytes.Uint8List;',
      'Bytes<int>',
      true,
    ),
    (
      'generic_nullable_byte_alias',
      'typedef Base<T> = bytes.Uint8List?; typedef Bytes = Base<int>;',
      'Bytes',
      true,
    ),
    ('other_typed_list', '', 'bytes.Uint16List', false),
    ('clamped_list', '', 'bytes.Uint8ClampedList', false),
    ('nested_byte_list', '', 'List<bytes.Uint8List>', false),
    ('nested_byte_map', '', 'Map<String, bytes.Uint8List?>', false),
    ('nested_record', '', '({bytes.Uint8List data})', false),
  ]) {
    test(
      'unsupported $label byte fields identify their defining source',
      () async {
        final model = File(path.join(fixture.path, 'record_bytes_$label.dart'));
        await model.writeAsString('''
import 'dart:typed_data' as bytes;
$declaration
typedef Payload = ({
  $type data,
});
typedef Exposed = Payload;
''');
        await expectLater(
          analyze('''
import 'package:napi/napi.dart';
import 'record_bytes_$label.dart' as models;
@napi
Future<List<models.Exposed?>?> echo(List<models.Exposed?>? values) async => values;
'''),
          throwsA(
            isA<ExportError>()
                .having((error) => error.path, 'path', model.path)
                .having((error) => error.line, 'line', 4)
                .having((error) => error.column, 'column', 3)
                .having(
                  (error) => error.message,
                  'message',
                  contains('"Exposed.data"'),
                )
                .having(
                  (error) => error.message,
                  'supported field guidance',
                  isAlias
                      ? startsWith(
                          'Type aliases are not supported in @napi record fields:',
                        )
                      : endsWith(
                          'Use bool, int, double, String, or Uint8List (optionally nullable).',
                        ),
                ),
          ),
        );
      },
    );
  }

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
  Uint16List bytes,
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
export declare function flags(values: readonly boolean[]): boolean[];
export declare function doubleAll(values: readonly number[]): number[];
export declare function scales(values: readonly number[]): number[];
export declare function texts(values: readonly string[]): string[];
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
export declare function leaf(values: readonly (number | null)[]): Array<number | null>;
export declare function container(values: readonly number[] | null): number[] | null;
export declare function both(values: readonly (number | null)[] | null): Array<number | null> | null;
export declare function mapLeaf(values: Record<string, string | null>): Record<string, string | null>;
export declare function mapContainer(values: Record<string, string> | null): Record<string, string> | null;
export declare function mapBoth(values: Record<string, string | null> | null): Record<string, string | null> | null;
export declare function flags(values: readonly (boolean | null)[] | null): Array<boolean | null> | null;
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
export declare function later(values: readonly (number | null)[] | null): Promise<Array<number | null> | null>;
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

  test(
    'SDK leaf aliases in collections retain nullability and String keys',
    () async {
      final entry = await relatedLibrary({
        'values.dart': '''
typedef Count = int;
typedef Id = Count;
typedef MaybeId = Id?;
typedef Enabled = bool;
typedef Ratio = double;
''',
        'names.dart': '''
typedef Count = String;
typedef Key = Count;
''',
        'public.dart': "export 'values.dart';\n",
        'api.dart': '''
import 'package:napi/napi.dart';
import 'public.dart' as values;
import 'names.dart' as names;
@napi
names.Count text(values.Id value) => value.toString();
@napi
List<values.MaybeId>? ids(List<values.MaybeId>? values) => values;
@napi
List<values.Enabled?> flags(List<values.Enabled?> values) => values;
@napi
Map<names.Key, values.Ratio?> scores(Map<names.Key, values.Ratio?> values) => values;
@napi
Map<names.Key, names.Count?> labels(Map<names.Key, names.Count?> values) => values;
@napi
Future<Map<names.Key, values.MaybeId>?> later(Map<names.Key, values.MaybeId>? values) async => values;
''',
      });
      final exports = await readExports(entry.path);
      expect(generateTypescript(exports), '''
export declare function text(value: number): string;
export declare function ids(values: readonly (number | null)[] | null): Array<number | null> | null;
export declare function flags(values: readonly (boolean | null)[]): Array<boolean | null>;
export declare function scores(values: Record<string, number | null>): Record<string, number | null>;
export declare function labels(values: Record<string, string | null>): Record<string, string | null>;
export declare function later(values: Record<string, number | null> | null): Promise<Record<string, number | null> | null>;
''');
    },
  );

  for (final type in ['Counts', 'Labels']) {
    test(
      'rejects the collection alias in $type with a source location',
      () async {
        await expectLater(
          analyze('''
import 'package:napi/napi.dart';
typedef Counts = List<int>;
typedef Labels = Map<String, String>;
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
    'SDK leaf aliases expand direct and Future values without bindings',
    () async {
      final exports = await analyze('''
import 'dart:typed_data' as bytes;
import 'package:napi/napi.dart';
typedef Enabled = bool;
typedef Promise = Enabled;
typedef Count = int;
typedef Id = Count;
typedef Ratio = double;
typedef _Name = String;
typedef Name = _Name;
typedef Bytes = bytes.Uint8List;
typedef MaybeId = Id?;
typedef MaybeBytes = Bytes?;
@napi
Promise flag(Promise value) => value;
@napi
Id count(Id value) => value;
@napi
Ratio ratio(Ratio value) => value;
@napi
Name name(Name value) => value;
@napi
Bytes buffer(Bytes value) => value;
@napi
MaybeId maybe(MaybeId value) => value;
@napi
Bytes? optional(Bytes? value) => value;
@napi
Future<Id?> later(Id? value) async => value;
@napi
Future<MaybeBytes> laterBytes(MaybeBytes value) async => value;
''');
      expect(exports.take(5).map((export) => export.returnType.kind), [
        ValueKind.boolType,
        ValueKind.intType,
        ValueKind.doubleType,
        ValueKind.stringType,
        ValueKind.uint8ListType,
      ]);
      expect(
        exports.skip(5).every((export) => export.returnType.nullable),
        isTrue,
      );
      expect(generateTypescript(exports), '''
export declare function flag(value: boolean): boolean;
export declare function count(value: number): number;
export declare function ratio(value: number): number;
export declare function name(value: string): string;
export declare function buffer(value: Uint8Array): Uint8Array;
export declare function maybe(value: number | null): number | null;
export declare function optional(value: Uint8Array | null): Uint8Array | null;
export declare function later(value: number | null): Promise<number | null>;
export declare function laterBytes(value: Uint8Array | null): Promise<Uint8Array | null>;
''');
    },
  );

  for (final type in [
    'Count',
    'List<Count>',
    'Map<String, Count>',
    'Map<Key, int>',
  ]) {
    test('generic leaf alias chains reject $type at the signature', () async {
      await expectLater(
        analyze('''
import 'package:napi/napi.dart';
typedef Base<T> = T;
typedef Count = Base<int>;
typedef Key = Base<String>;
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
    });
  }

  test(
    'generic leaf alias fields identify their imported declaration',
    () async {
      final entry = await relatedLibrary({
        'models.dart': '''
typedef Base<T> = T;
typedef Count = Base<int>;
typedef User = ({
  Count age,
});
''',
        'public.dart': "export 'models.dart' show User;\n",
        'api.dart': '''
import 'package:napi/napi.dart';
import 'public.dart' as models;
@napi
models.User echo(models.User value) => value;
''',
      });
      await expectLater(
        readExports(entry.path),
        throwsA(
          isA<ExportError>()
              .having(
                (error) => error.path,
                'path',
                path.join(entry.parent.path, 'models.dart'),
              )
              .having((error) => error.line, 'line', 4)
              .having((error) => error.column, 'column', 3)
              .having(
                (error) => error.message,
                'message',
                contains('User.age'),
              ),
        ),
      );
    },
  );

  for (final declaration in [
    'typedef Alias = int Function(int);',
    'class Uint8List {} typedef Alias = Uint8List;',
  ]) {
    test('SDK leaf aliases still exclude $declaration', () async {
      await expectLater(
        analyze('''
import 'package:napi/napi.dart';
$declaration
@napi
Alias echo(Alias value) => value;
'''),
        throwsA(
          isA<ExportError>()
              .having((error) => error.line, 'line', 4)
              .having((error) => error.column, 'column', 12)
              .having(
                (error) => error.message,
                'message',
                contains('Type aliases are not supported'),
              ),
        ),
      );
    });
  }

  for (final signature in [
    'Nothing clear() {}',
    'Future<Nothing> clear() async {}',
  ]) {
    test('void leaf aliases reject $signature', () async {
      await expectLater(
        analyze('''
import 'dart:async';
import 'package:napi/napi.dart';
typedef Nothing = void;
@napi
$signature
'''),
        throwsA(
          isA<ExportError>()
              .having((error) => error.line, 'line', 5)
              .having((error) => error.column, 'column', 1)
              .having(
                (error) => error.message,
                'message',
                contains('Type aliases are not supported'),
              ),
        ),
      );
    });
  }

  test('SDK leaf aliases do not admit nullable String Map keys', () async {
    await expectLater(
      analyze('''
import 'package:napi/napi.dart';
typedef Key = String?;
@napi
void inspect(Map<Key, int> values) {}
'''),
      throwsA(
        isA<ExportError>()
            .having((error) => error.line, 'line', 4)
            .having((error) => error.column, 'column', 14)
            .having(
              (error) => error.message,
              'message',
              contains('Map keys must be non-nullable String'),
            ),
      ),
    );
  });

  for (final type in ['List<Bytes>', 'Map<String, Bytes?>']) {
    test('SDK leaf aliases do not admit $type', () async {
      await expectLater(
        analyze('''
import 'dart:typed_data';
import 'package:napi/napi.dart';
typedef Bytes = Uint8List;
@napi
void inspect($type values) {}
'''),
        throwsA(
          isA<ExportError>()
              .having((error) => error.line, 'line', 5)
              .having((error) => error.column, 'column', 14)
              .having(
                (error) => error.message,
                'message',
                contains('collection leaf type'),
              ),
        ),
      );
    });
  }

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
