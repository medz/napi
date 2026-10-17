import 'dart:io';
import 'dart:mirrors';

import 'package:napi/build.dart' show NAPI, ClassPolicy;
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-class-policy-');
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<File> source(String text) async =>
      File('${directory.path}/entry.dart')
        ..writeAsStringSync("import 'package:napi/napi.dart';\n$text");
  Future<BindingModule> annotated(File file) =>
      AnnotationFrontend(packagesPath: _packages).read(file.uri);
  Future<BindingModule> external(File file, ExternalLibrary selections) =>
      ExternalFrontend(selections, packagesPath: _packages).read(file.uri);

  const declarations = '''
@NAPI()
class Ordinary<T> { Ordinary(this.value); T value; }
@NAPI(classPolicy: ClassPolicy.reference)
class Reference {}
@NAPI(classPolicy: ClassPolicy.value)
class Value { Value(this.value); final int value; }
/// Explicit asynchronous resource policy.
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource<T extends num> {
  Resource(this.value);
  T value;
  /// Cleanup signature and defaults remain original metadata.
  @NAPI(name: 'shutdown')
  Future<void> close<R extends num>({R? reason, int attempts = 2}) async {}
  static void staticClose() {}
}
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'release')
class HiddenCleanup {
  @NAPI(exclude: true)
  void release() {}
}
''';
  const selections = ExternalLibrary([
    ExternalClass('Ordinary'),
    ExternalClass(
      'Reference',
      config: NAPI(classPolicy: ClassPolicy.reference),
    ),
    ExternalClass('Value', config: NAPI(classPolicy: ClassPolicy.value)),
    ExternalClass(
      'Resource',
      config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close'),
      members: [ExternalMember.method('close', config: NAPI(name: 'shutdown'))],
    ),
    ExternalClass(
      'HiddenCleanup',
      config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'release'),
      members: [ExternalMember.method('release', config: NAPI(exclude: true))],
    ),
  ]);

  test(
    'both frontends produce equivalent complete class policy metadata',
    () async {
      final input = await source(declarations);
      final fromAnnotations = await annotated(input);
      final fromExternal = await external(
        input,
        ExternalLibrary(selections.declarations.reversed.toList()),
      );
      expect(_snapshot(fromExternal), _snapshot(fromAnnotations));
      final classes = {
        for (final binding in fromAnnotations.classes)
          binding.declaration.name: binding,
      };
      for (final name in ['Ordinary', 'Reference']) {
        expect(classes[name]!.classPolicy, ClassPolicy.reference);
        expect(classes[name]!.cleanup, isNull);
      }
      expect(classes['Value']!.classPolicy, ClassPolicy.value);
      expect(classes['Value']!.cleanup, isNull);
      final resource = classes['Resource']!;
      expect(resource.classPolicy, ClassPolicy.resource);
      final cleanup = resource.members.singleWhere(
        (member) => member.declaration == resource.cleanup,
      );
      expect(cleanup.declaration.name, 'close');
      expect(cleanup.declaration.owner, resource.declaration);
      expect(cleanup.exportName, 'shutdown');
      expect(cleanup.kind, MemberKind.method);
      expect(cleanup.isAsync, isTrue);
      expect(cleanup.documentation, contains('signature and defaults'));
      final result = cleanup.result! as DeclaredType;
      expect(result.declaration.name, 'Future');
      expect(result.typeArguments.single, isA<VoidType>());
      expect(resource.typeParameters.single.declaration.name, 'T');
      expect(
        cleanup.typeParameters.single.declaration.owner,
        cleanup.declaration,
      );
      expect(
        (cleanup.parameters.first.type as TypeParameterType).declaration,
        cleanup.typeParameters.single.declaration,
      );
      expect(cleanup.parameters.last.defaultValue!.value, 2);
      await _expectSource(cleanup.source, 'close');
      final hidden = classes['HiddenCleanup']!;
      expect(
        hidden.members
            .singleWhere((member) => member.declaration == hidden.cleanup)
            .selection,
        MemberSelection.excluded,
      );
    },
  );

  test(
    'reexported policies preserve part source and original cleanup identity',
    () async {
      final entry = await source("export 'origin.dart';");
      final origin = File('${directory.path}/origin.dart');
      final part = File('${directory.path}/resource_part.dart');
      await origin.writeAsString(
        "import 'package:napi/napi.dart';\npart 'resource_part.dart';\n",
      );
      await part.writeAsString(
        "part of 'origin.dart';\n@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')\nclass PartResource { Future<void> close() async {} }\n",
      );
      final fromAnnotations = await annotated(entry);
      final fromExternal = await external(
        entry,
        const ExternalLibrary([
          ExternalClass(
            'PartResource',
            config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close'),
          ),
        ]),
      );
      expect(_snapshot(fromExternal), _snapshot(fromAnnotations));
      final resource = fromAnnotations.classes.single;
      final cleanup = resource.members.singleWhere(
        (member) => member.declaration == resource.cleanup,
      );
      expect(resource.declaration.library, origin.uri);
      expect(cleanup.declaration.library, origin.uri);
      expect(resource.source.uri, part.uri);
      expect(cleanup.source.uri, part.uri);
      await _expectSource(resource.source, 'PartResource');
      await _expectSource(cleanup.source, 'close');
    },
  );

  test('runtime gates allow reference and structural value classes', () async {
    final module = await annotated(await source(declarations));
    for (final binding in module.classes) {
      final single = BindingModule(source: module.source, classes: [binding]);
      expect(() => validateDeclarations(single), returnsNormally);
      if (const {'Reference', 'Value'}.contains(binding.declaration.name)) {
        expect(() => validate(single), returnsNormally);
        continue;
      }
      expect(
        () => validate(single),
        throwsA(
          isA<BindingDiagnostic>().having(
            (error) => error.code,
            'code',
            binding.declaration.name == 'HiddenCleanup'
                ? 'NAPI_RESOURCE'
                : 'NAPI_GENERIC',
          ),
        ),
      );
    }
  });

  for (final (label, annotation, config, body, code, token)
      in <(String, String, NAPI, String, String, String)>[
        (
          'resource without cleanup',
          'classPolicy: ClassPolicy.resource',
          const NAPI(classPolicy: ClassPolicy.resource),
          'class Bad {}',
          'NAPI_SELECTION',
          'Bad',
        ),
        (
          'implicit reference with cleanup',
          "cleanup: 'close'",
          const NAPI(cleanup: 'close'),
          'class Bad { void close() {} }',
          'NAPI_SELECTION',
          'Bad',
        ),
        (
          'reference with cleanup',
          "classPolicy: ClassPolicy.reference, cleanup: 'close'",
          const NAPI(classPolicy: ClassPolicy.reference, cleanup: 'close'),
          'class Bad { void close() {} }',
          'NAPI_SELECTION',
          'Bad',
        ),
        (
          'value with cleanup',
          "classPolicy: ClassPolicy.value, cleanup: 'close'",
          const NAPI(classPolicy: ClassPolicy.value, cleanup: 'close'),
          'class Bad { void close() {} }',
          'NAPI_SELECTION',
          'Bad',
        ),
        (
          'missing cleanup',
          "classPolicy: ClassPolicy.resource, cleanup: 'missing'",
          const NAPI(classPolicy: ClassPolicy.resource, cleanup: 'missing'),
          'class Bad {}',
          'NAPI_SELECTION',
          'Bad',
        ),
        (
          'private cleanup',
          "classPolicy: ClassPolicy.resource, cleanup: '_close'",
          const NAPI(classPolicy: ClassPolicy.resource, cleanup: '_close'),
          'class Bad { void _close() {} }',
          'NAPI_VISIBILITY',
          '_close',
        ),
        (
          'static cleanup',
          "classPolicy: ClassPolicy.resource, cleanup: 'close'",
          const NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close'),
          'class Bad { static void close() {} }',
          'NAPI_SELECTION',
          'close',
        ),
        (
          'getter cleanup',
          "classPolicy: ClassPolicy.resource, cleanup: 'close'",
          const NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close'),
          'class Bad { int get close => 0; }',
          'NAPI_SELECTION',
          'close',
        ),
        (
          'field cleanup',
          "classPolicy: ClassPolicy.resource, cleanup: 'close'",
          const NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close'),
          'class Bad { int close = 0; }',
          'NAPI_SELECTION',
          'close',
        ),
        (
          'ambiguous accessors',
          "classPolicy: ClassPolicy.resource, cleanup: 'close'",
          const NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close'),
          'class Bad { int get close => 0; set close(int value) {} }',
          'NAPI_AMBIGUOUS',
          'close',
        ),
        (
          'inherited cleanup',
          "classPolicy: ClassPolicy.resource, cleanup: 'close'",
          const NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close'),
          'class Bad extends Parent {}\nclass Parent { void close() {} }',
          'NAPI_SELECTION',
          'Bad',
        ),
        (
          'cleanup selected by JS rename',
          "classPolicy: ClassPolicy.resource, cleanup: 'shutdown'",
          const NAPI(classPolicy: ClassPolicy.resource, cleanup: 'shutdown'),
          "class Bad { @NAPI(name: 'shutdown') void close() {} }",
          'NAPI_SELECTION',
          'Bad',
        ),
      ]) {
    test(
      '$label has the same precise source diagnostic in both frontends',
      () async {
        final input = await source('@NAPI($annotation)\n$body');
        for (final read in [
          () => annotated(input),
          () => external(
            input,
            ExternalLibrary([ExternalClass('Bad', config: config)]),
          ),
        ]) {
          BindingDiagnostic? diagnostic;
          try {
            await read();
          } on BindingDiagnostic catch (error) {
            diagnostic = error;
          }
          expect(diagnostic, isNotNull);
          expect(diagnostic!.code, code);
          expect(diagnostic.source!.uri, input.uri);
          await _expectSource(diagnostic.source!, token);
        }
      },
    );
  }

  for (final (annotation, declaration, selection)
      in <(String, String, ExternalDeclaration)>[
        (
          'classPolicy: ClassPolicy.reference',
          'int bad() => 0;',
          const ExternalFunction(
            'bad',
            config: NAPI(classPolicy: ClassPolicy.reference),
          ),
        ),
        (
          "cleanup: 'close'",
          'int bad() => 0;',
          const ExternalFunction('bad', config: NAPI(cleanup: 'close')),
        ),
        (
          'classPolicy: ClassPolicy.value',
          'void close() {}',
          const ExternalClass(
            'Bad',
            members: [
              ExternalMember.method(
                'close',
                config: NAPI(classPolicy: ClassPolicy.value),
              ),
            ],
          ),
        ),
      ]) {
    test(
      'class options reject non-class placement: $annotation / $declaration',
      () async {
        final isMember = selection is ExternalClass;
        final input = await source(
          isMember
              ? '@NAPI() class Bad { @NAPI($annotation) $declaration }'
              : '@NAPI($annotation) $declaration',
        );
        await expectLater(
          annotated(input),
          throwsA(
            isA<BindingDiagnostic>().having(
              (error) => error.code,
              'code',
              'NAPI_PLACEMENT',
            ),
          ),
        );
        await expectLater(
          external(input, ExternalLibrary([selection])),
          throwsA(
            isA<BindingDiagnostic>().having(
              (error) => error.code,
              'code',
              'NAPI_PLACEMENT',
            ),
          ),
        );
      },
    );
  }

  test(
    'explicit null class option is still a class-only source option',
    () async {
      await expectLater(
        annotated(await source('@NAPI(classPolicy: null) int bad() => 0;')),
        throwsA(
          isA<BindingDiagnostic>().having(
            (error) => error.code,
            'code',
            'NAPI_PLACEMENT',
          ),
        ),
      );
    },
  );

  test('handwritten IR rejects dangling, foreign and non-method cleanup identities', () async {
    final module = await annotated(await source(declarations));
    final resource = module.classes.singleWhere(
      (binding) => binding.declaration.name == 'Resource',
    );
    final field = resource.members.singleWhere(
      (member) => member.kind == MemberKind.field,
    );
    final staticMethod = resource.members.singleWhere(
      (member) => member.declaration.name == 'staticClose',
    );
    for (final (policy, cleanup) in <(ClassPolicy, DeclarationId?)>[
      (ClassPolicy.resource, null),
      (ClassPolicy.reference, resource.cleanup),
      (ClassPolicy.value, resource.cleanup),
      (
        ClassPolicy.resource,
        DeclarationId(
          resource.declaration.library,
          'missing',
          owner: resource.declaration,
          kind: DeclarationKind.method,
        ),
      ),
      (
        ClassPolicy.resource,
        DeclarationId(
          Uri.parse('package:foreign/api.dart'),
          'close',
          owner: resource.declaration,
          kind: DeclarationKind.method,
        ),
      ),
      (ClassPolicy.resource, field.declaration),
      (ClassPolicy.resource, staticMethod.declaration),
    ]) {
      final binding = ClassBinding(
        declaration: resource.declaration,
        exportName: resource.exportName,
        source: resource.source,
        members: resource.members,
        classPolicy: policy,
        cleanup: cleanup,
      );
      expect(
        () => validateDeclarations(
          BindingModule(source: module.source, classes: [binding]),
        ),
        throwsA(
          isA<BindingDiagnostic>().having(
            (error) => error.code,
            'code',
            'NAPI_SELECTION',
          ),
        ),
      );
    }
  });
}

Future<void> _expectSource(SourceLocation source, String token) async {
  final text = await File.fromUri(source.uri).readAsString();
  expect(text.substring(source.offset, source.offset + source.length), token);
  final prefix = text.substring(0, source.offset);
  expect(source.line, '\n'.allMatches(prefix).length + 1);
  expect(source.column, source.offset - prefix.lastIndexOf('\n'));
}

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
