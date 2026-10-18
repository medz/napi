import 'dart:io';
import 'dart:mirrors';

import 'package:napi/napi.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;

void main() {
  late Directory directory;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi external sources ');
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<File> source(String text, [String name = 'entry.dart']) async =>
      File('${directory.path}/$name')..writeAsStringSync(text);

  Future<BindingModule> read(File input, ExternalLibrary selections) =>
      ExternalFrontend(selections, packagesPath: _packages).read(input.uri);

  test(
    'annotation and external selections normalize to identical complete IR',
    () async {
      final input = await source('''
import 'package:napi/napi.dart';
/// Generic function documentation.
@NAPI(name: 'identity')
T echo<T extends num>(T value, {String label = 'default'}) => value;
@NAPI(bigint: true)
int integer(int value) => value;
/// A class retains generic identity and its member declarations.
@NAPI(name: 'Container')
class Box<T extends num> {
  @NAPI(name: 'create')
  Box(this.value);
  Box.named(this.value);
  /// Mutable storage.
  @NAPI(name: 'stored')
  T value;
  @NAPI(name: 'size')
  int get count => 1;
  @NAPI(name: 'size')
  set count(int value) {}
  @NAPI(name: 'apply')
  R map<R extends num>(R value, [int extra = 42]) => value;
  @NAPI(exclude: true)
  void hidden() {}
}
''');
      const selections = ExternalLibrary([
        ExternalFunction('echo', config: NAPI(name: 'identity')),
        ExternalFunction('integer', config: NAPI(bigint: true)),
        ExternalClass(
          'Box',
          config: NAPI(name: 'Container'),
          members: [
            ExternalMember.constructor('new', config: NAPI(name: 'create')),
            ExternalMember.field('value', config: NAPI(name: 'stored')),
            ExternalMember.getter('count', config: NAPI(name: 'size')),
            ExternalMember.setter('count', config: NAPI(name: 'size')),
            ExternalMember.method('map', config: NAPI(name: 'apply')),
            ExternalMember.method('hidden', config: NAPI(exclude: true)),
          ],
        ),
      ]);
      final annotated = await AnnotationFrontend(packagesPath: _packages)
          .read(input.uri);
      final external = await read(
        input,
        ExternalLibrary(selections.declarations.reversed.toList()),
      );
      expect(_snapshot(external), _snapshot(annotated));
      final box = external.classes.single;
      expect(box.members.map((e) => e.kind), containsAll(MemberKind.values));
      expect(box.typeParameters.single.declaration.owner, box.declaration);
      expect(
        (external.functions.first.parameters.last.defaultValue as ScalarDefault)
            .value,
        'default',
      );
      expect(box.documentation, contains('retains generic identity'));
      final stored = box.members.singleWhere((e) => e.kind == MemberKind.field);
      expect(stored.type!.semantics, ValueSemantics.opaque);
      expect(box.supertype!.semantics, ValueSemantics.reference);
    },
  );

  test('keeps structural and reference semantics without claiming executable classes', () async {
    final input = await source('''
class Resource {}
List<Resource?> copy(List<Resource?> value) => value;
(int, {String label}) record((int, {String label}) value) => value;
''');
    final module = await read(
      input,
      const ExternalLibrary([
        ExternalFunction('copy'),
        ExternalFunction('record'),
      ]),
    );
    final list = module.functions.first.result as DeclaredType;
    expect(list.semantics, ValueSemantics.structural);
    expect(list.typeArguments.single.semantics, ValueSemantics.reference);
    expect(list.typeArguments.single.nullability, TypeNullability.nullable);
    expect(module.functions.last.result, isA<RecordTypeBinding>());
  });

  test(
    'selects only public reexports while retaining the original source',
    () async {
      final origin = await source('''
/// Original function.
int exposed([int value = 42]) => value;
int hidden() => 0;
''', 'origin.dart');
      final input = await source("export 'origin.dart' show exposed;\n");
      final module = await read(
        input,
        const ExternalLibrary([
          ExternalFunction('exposed', config: NAPI(name: 'answer')),
        ]),
      );
      final function = module.functions.single;
      expect(function.exportName, 'answer');
      expect(function.callPath, 'exposed');
      expect(function.exportSurface, input.uri);
      expect(function.declaration.library, origin.uri);
      expect(function.source.uri, origin.uri);
      expect(
        (function.parameters.single.defaultValue as ScalarDefault).value,
        42,
      );
      await _expectSource(function.source, 'exposed');
    },
  );

  test(
    'missing selection reports an explicitly supplied build-script location',
    () async {
      final input = await source('int present() => 0;\n');
      final script = await source(
        "const selection = 'missing';\n",
        'build.dart',
      );
      final location = SourceLocation(script.uri, 19, 7, line: 1, column: 20);
      await expectLater(
        read(
          input,
          ExternalLibrary([ExternalFunction('missing', source: location)]),
        ),
        throwsA(
          isA<BindingDiagnostic>()
              .having((e) => e.code, 'code', 'NAPI_SELECTION')
              .having((e) => e.message, 'message', contains('missing'))
              .having((e) => e.source, 'source', same(location)),
        ),
      );
      await _expectSource(location, 'missing');
    },
  );

  for (final (name, text, selections, code, token) in [
    (
      'private function',
      'int _secret() => 0;',
      const ExternalLibrary([ExternalFunction('_secret')]),
      'NAPI_VISIBILITY',
      '_secret',
    ),
    (
      'wrong kind',
      'class Box {}',
      const ExternalLibrary([ExternalFunction('Box')]),
      'NAPI_SELECTION',
      'Box',
    ),
    (
      'top-level collision',
      'int first() => 1; int second() => 2;',
      const ExternalLibrary([
        ExternalFunction('first', config: NAPI(name: 'same')),
        ExternalFunction('second', config: NAPI(name: 'same')),
      ]),
      'NAPI_DUPLICATE',
      'second',
    ),
    (
      'duplicate selection',
      'int first() => 1;',
      const ExternalLibrary([
        ExternalFunction('first'),
        ExternalFunction('first'),
      ]),
      'NAPI_DUPLICATE',
      'first',
    ),
    (
      'private member',
      'class Box { void _secret() {} }',
      const ExternalLibrary([
        ExternalClass('Box', members: [ExternalMember.method('_secret')]),
      ]),
      'NAPI_VISIBILITY',
      '_secret',
    ),
    (
      'missing member',
      'class Box {}',
      const ExternalLibrary([
        ExternalClass('Box', members: [ExternalMember.method('missing')]),
      ]),
      'NAPI_SELECTION',
      'Box',
    ),
    (
      'member collision',
      'class Box { void first() {} void second() {} }',
      const ExternalLibrary([
        ExternalClass(
          'Box',
          members: [
            ExternalMember.method('first', config: NAPI(name: 'same')),
            ExternalMember.method('second', config: NAPI(name: 'same')),
          ],
        ),
      ]),
      'NAPI_DUPLICATE',
      'second',
    ),
    (
      'bigint class',
      'class Box {}',
      const ExternalLibrary([ExternalClass('Box', config: NAPI(bigint: true))]),
      'NAPI_PLACEMENT',
      'Box',
    ),
  ]) {
    test('$name has a precise original source diagnostic', () async {
      final input = await source(text);
      BindingDiagnostic? diagnostic;
      try {
        await read(input, selections);
      } on BindingDiagnostic catch (error) {
        diagnostic = error;
      }
      expect(diagnostic, isNotNull);
      expect(diagnostic!.code, code);
      expect(diagnostic.source!.uri, input.uri);
      await _expectSource(diagnostic.source!, token);
    });
  }

  test(
    'ambiguous exports identify both origins and the export directive',
    () async {
      final first = await source('int duplicate() => 1;\n', 'first.dart');
      final second = await source('int duplicate() => 2;\n', 'second.dart');
      final input = await source(
        "export 'first.dart';\nexport 'second.dart';\n",
      );
      BindingDiagnostic? diagnostic;
      try {
        await read(
          input,
          const ExternalLibrary([ExternalFunction('duplicate')]),
        );
      } on BindingDiagnostic catch (error) {
        diagnostic = error;
      }
      expect(diagnostic!.code, 'NAPI_AMBIGUOUS');
      expect(diagnostic.message, contains(first.uri.pathSegments.last));
      expect(diagnostic.message, contains(second.uri.pathSegments.last));
      expect(diagnostic.source!.uri, input.uri);
      await _expectSource(diagnostic.source!, "'second.dart'");
    },
  );
}

Future<void> _expectSource(SourceLocation source, String token) async {
  final text = await File.fromUri(source.uri).readAsString();
  expect(text.substring(source.offset, source.offset + source.length), token);
  final prefix = text.substring(0, source.offset);
  expect(source.line, '\n'.allMatches(prefix).length + 1);
  expect(source.column, source.offset - prefix.lastIndexOf('\n'));
}

// Compare every IR field, including inherited type metadata, across sessions.
// This prevents an equivalence test from silently omitting a newly added field.
Object? _snapshot(Object? value) {
  if (value == null || value is String || value is num || value is bool) {
    return value;
  }
  if (value is Uri) return value.toString();
  if (value is Enum) return value.toString();
  if (value is Iterable) return value.map(_snapshot).toList();
  if (value is Map) {
    return value.map((key, value) => MapEntry(key, _snapshot(value)));
  }
  final instance = reflect(value);
  final fields = <String, Object?>{'@type': value.runtimeType.toString()};
  for (
    ClassMirror? type = instance.type;
    type != null;
    type = type.superclass
  ) {
    for (final entry in type.declarations.entries) {
      if (entry.value case VariableMirror(isStatic: false)) {
        fields[MirrorSystem.getName(entry.key)] = _snapshot(
          instance.getField(entry.key).reflectee,
        );
      }
    }
  }
  return fields;
}
