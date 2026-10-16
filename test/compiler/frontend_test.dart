import 'dart:convert';
import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final _fixtures = Directory('test/fixtures/frontend').absolute;
final _packages = File('.dart_tool/package_config.json').absolute.path;
final _frontend = AnnotationFrontend(packagesPath: _packages);

void main() {
  group('resolved annotation discovery', () {
    late Directory directory;
    late BindingModule module;
    late Map<String, FunctionBinding> functions;
    late Map<String, ClassBinding> classes;

    setUpAll(() async {
      directory = await _copyFixture('valid');
      module = await _frontend.read(File('${directory.path}/entry.dart').uri);
      functions = {for (final f in module.functions) f.declaration.name: f};
      classes = {for (final c in module.classes) c.declaration.name: c};
    });

    test('resolves prefix, reexport, and typedef annotation identities', () {
      expect(functions['scalar']!.exportName, 'renamed');
      expect(functions['reexportAnnotation']!.exportName, 'reexportAnnotation');
      expect(functions['aliasSelected']!.exportName, 'aliasAnnotation');
      expect(functions, isNot(contains('lookalikeOnly')));
      expect(functions, isNot(contains('unannotated')));
      expect(
        module.functions.map((f) => f.exportName),
        isNot(contains('mustNotAppear')),
      );
    });

    test('selects the export namespace with show and hide, never imports', () {
      expect(functions, contains('kept'));
      expect(functions['kept']!.exportName, 'fromReexport');
      expect(functions, isNot(contains('hidden')));
      expect(functions, isNot(contains('notShown')));
      expect(functions, isNot(contains('importedOnly')));
      final kept = functions['kept']!;
      expect(
        kept.declaration.library,
        File('${directory.path}/exported.dart').uri,
      );
      expect(kept.exportSurface, module.source);
      expect(kept.callPath, 'kept');
      expect(kept.documentation, contains('originates in another library'));
    });

    test('preserves source locations and original part identity', () async {
      final scalar = functions['scalar']!;
      expect(scalar.declaration.kind, DeclarationKind.function);
      expect(scalar.declaration.owner, isNull);
      expect(scalar.documentation, '/// A renamed scalar function.');
      await _expectSource(scalar.source, 'scalar');
      await _expectSource(scalar.parameters.single.source!, 'value');
      final fromPart = functions['fromPart']!;
      expect(fromPart.declaration.library, module.source);
      expect(
        fromPart.source.uri,
        File('${directory.path}/entry_part.dart').uri,
      );
      expect(fromPart.documentation, contains('declared in a part'));
      await _expectSource(fromPart.source, 'fromPart');
    });

    test(
      'preserves int aliases without confusing double or generic aliases',
      () {
        final alias = functions['countAlias']!;
        expect(alias.result, isA<SafeIntType>());
        expect(alias.parameters.single.type, isA<SafeIntType>());
        expect(alias.result.alias!.declaration.name, 'Count');
        expect(
          alias.result.alias!.declaration.kind,
          DeclarationKind.typedefType,
        );
        expect(alias.result.alias!.typeArguments, isEmpty);
        final generic = functions['genericAlias']!;
        expect(generic.result, isA<SafeIntType>());
        expect(generic.result.alias!.declaration.name, 'Id');
        expect(generic.result.alias!.typeArguments.single, isA<SafeIntType>());
        expect(
          generic.parameters.single.type.alias!.typeArguments.single,
          isA<SafeIntType>(),
        );
        final floating = functions['floatingPoint']!.result as DeclaredType;
        expect(floating.declaration.library, Uri.parse('dart:core'));
        expect(floating.declaration.name, 'double');
        expect(floating.semantics, ValueSemantics.scalar);
      },
    );

    test('retains enum, mixin, and extension-type nominal identities', () {
      final choice = functions['choiceValue']!.result as DeclaredType;
      expect(choice.declaration.name, 'Choice');
      expect(choice.declaration.kind, DeclarationKind.enumType);
      final mixin = functions['mixinValue']!.result as DeclaredType;
      expect(mixin.declaration.name, 'Feature');
      expect(mixin.declaration.kind, DeclarationKind.mixinType);
      expect(mixin.nullability, TypeNullability.nullable);
      final wrapped = functions['extensionValue']!.result as DeclaredType;
      expect(wrapped.declaration.name, 'Wrapped');
      expect(wrapped.declaration.kind, DeclarationKind.extensionType);
    });

    test(
      'retains nullable nested generics and type-parameter identities',
      () async {
        final function = functions['describe']!;
        final typeParameter = function.typeParameters.single;
        expect(typeParameter.declaration.name, 'T');
        expect(typeParameter.declaration.kind, DeclarationKind.typeParameter);
        expect(typeParameter.declaration.owner, function.declaration);
        expect((typeParameter.bound! as DeclaredType).declaration.name, 'num');
        await _expectSource(typeParameter.source!, 'T');
        final result = function.result as DeclaredType;
        expect(result.declaration.name, 'Map');
        expect(result.semantics, ValueSemantics.structural);
        expect(result.nullability, TypeNullability.nullable);
        expect(
          (result.typeArguments[0] as DeclaredType).declaration.name,
          'String',
        );
        final list = result.typeArguments[1] as DeclaredType;
        expect(list.declaration.name, 'List');
        final item = list.typeArguments.single as TypeParameterType;
        expect(item.nullability, TypeNullability.nullable);
        expect(item.declaration, typeParameter.declaration);
        expect(
          (function.parameters.first.type as TypeParameterType).declaration,
          typeParameter.declaration,
        );
        expect(
          function.parameters.first.type.nullability,
          TypeNullability.nonNullable,
        );
      },
    );

    test('retains parameter and type-parameter documentation', () async {
      final function = functions['documented']!;
      expect(
        function.typeParameters.single.documentation,
        contains('documented type parameter'),
      );
      expect(
        function.parameters.single.documentation,
        contains('documented value parameter'),
      );
      await _expectSource(function.typeParameters.single.source!, 'T');
      await _expectSource(function.parameters.single.source!, 'value');
    });

    test('retains all four parameter kinds and exact explicit defaults', () {
      final named = functions['describe']!.parameters;
      expect(named.map((p) => p.kind), [
        ParameterKind.requiredPositional,
        ParameterKind.requiredNamed,
        ParameterKind.optionalNamed,
        ParameterKind.optionalNamed,
      ]);
      expect(named.map((p) => p.presence), [
        ParameterPresence.required,
        ParameterPresence.required,
        ParameterPresence.optional,
        ParameterPresence.optional,
      ]);
      expect(named[2].hasDefault, isTrue);
      expect(named[2].defaultSource, "'hello'");
      expect(named[3].hasDefault, isFalse);
      expect(named[3].defaultSource, isNull);
      final positional = functions['optionalValues']!.parameters;
      expect(positional.map((p) => p.kind), [
        ParameterKind.requiredPositional,
        ParameterKind.optionalPositional,
        ParameterKind.optionalPositional,
      ]);
      expect(positional[1].hasDefault, isTrue);
      expect(positional[1].defaultSource, '7');
      expect(positional[2].hasDefault, isFalse);
      expect(positional[2].type.nullability, TypeNullability.nullable);
      final explicitNull = functions['explicitNull']!.parameters.single;
      expect(explicitNull.hasDefault, isTrue);
      expect(explicitNull.defaultSource, 'null');
    });

    test('normalizes callback, generic function, and record signatures', () {
      final callback =
          functions['describe']!.parameters.last.type as FunctionTypeBinding;
      expect(callback.nullability, TypeNullability.nullable);
      expect(callback.result, isA<VoidType>());
      expect(callback.parameters.first.type, isA<SafeIntType>());
      expect(callback.parameters.last.name, 'label');
      expect(callback.parameters.last.kind, ParameterKind.optionalNamed);
      final mapper =
          functions['genericCallback']!.result as FunctionTypeBinding;
      expect(mapper.alias!.declaration.name, 'Mapper');
      expect(mapper.typeParameters.single.declaration.name, 'R');
      expect(
        (mapper.typeParameters.single.bound as DeclaredType).declaration.name,
        'num',
      );
      expect(
        (mapper.result as TypeParameterType).declaration,
        mapper.typeParameters.single.declaration,
      );
      expect(
        (mapper.parameters.single.type as TypeParameterType).declaration,
        mapper.typeParameters.single.declaration,
      );
      final record = functions['recordValue']!.result as RecordTypeBinding;
      expect(record.nullability, TypeNullability.nullable);
      expect(record.semantics, ValueSemantics.structural);
      expect(record.positional.single, isA<SafeIntType>());
      expect(record.named.keys, unorderedEquals(['label', 'weight']));
      expect(record.named['label']!.nullability, TypeNullability.nullable);
      expect(
        (record.named['weight'] as DeclaredType).declaration.name,
        'double',
      );
    });

    test(
      'scopes identical generic callback type-parameter names independently',
      () {
        final callbacks = functions['separateCallbacks']!.parameters;
        final first = callbacks[0].type as FunctionTypeBinding;
        final second = callbacks[1].type as FunctionTypeBinding;
        expect(
          first.typeParameters.single.declaration,
          isNot(second.typeParameters.single.declaration),
        );
        expect(
          (first.result as TypeParameterType).declaration,
          first.typeParameters.single.declaration,
        );
        expect(
          (second.result as TypeParameterType).declaration,
          second.typeParameters.single.declaration,
        );
      },
    );

    test(
      'retains dynamic, void, never, async, generator, and external metadata',
      () {
        expect(functions['dynamicValue']!.result, isA<DynamicType>());
        expect(functions['voidValue']!.result, isA<VoidType>());
        expect(functions['neverValue']!.result, isA<NeverType>());
        expect(functions['asyncValue']!.isAsync, isTrue);
        expect(functions['asyncValue']!.isGenerator, isFalse);
        expect(functions['generatorValue']!.isGenerator, isTrue);
        expect(functions['generatorValue']!.isAsync, isFalse);
        expect(functions['externalValue']!.isExternal, isTrue);
      },
    );

    test('discovers class metadata before backend capability validation', () {
      final box = classes['Container']!;
      expect(box.exportName, 'Box');
      expect(box.callPath, 'Container');
      expect(box.exportSurface, module.source);
      expect(box.declaration.kind, DeclarationKind.classType);
      expect(box.documentation, contains('own public members'));
      expect((box.supertype as DeclaredType).declaration.name, 'Base');
      expect((box.interfaces.single as DeclaredType).declaration.name, 'Sized');
      expect((box.mixins.single as DeclaredType).declaration.name, 'Feature');
      expect(box.typeParameters.single.declaration.owner, box.declaration);
      expect(classes['Immutable']!.isFinal, isTrue);
      expect(classes['AbstractValue']!.isAbstract, isTrue);
      expect(classes['BaseFlag']!.isBase, isTrue);
      expect(classes['SealedFlag']!.isSealed, isTrue);
      expect(classes['InterfaceFlag']!.isInterface, isTrue);
      expect(classes['MixinFlag']!.isMixinClass, isTrue);
      expect(() => validateDeclarations(module), returnsNormally);
      expect(() => validate(module), throwsA(_diagnostic('NAPI_CLASS')));
    });

    test('discovers annotated class aliases without inherited members', () {
      final combined = classes['Combined']!;
      expect(combined.declaration.kind, DeclarationKind.classType);
      expect((combined.supertype as DeclaredType).declaration.name, 'Base');
      expect(
        (combined.mixins.single as DeclaredType).declaration.name,
        'Feature',
      );
      expect(
        combined.members.where((m) => m.kind != MemberKind.constructor),
        isEmpty,
      );
      expect(
        combined.members.every(
          (m) => m.declaration.owner == combined.declaration,
        ),
        isTrue,
      );
    });

    test('scopes generic callback identities in class relationships', () {
      FunctionTypeBinding callback(BindingType type) =>
          (type as DeclaredType).typeArguments.single as FunctionTypeBinding;
      final owner = classes['CallbackOwner']!;
      final signatures = [
        callback(owner.supertype!),
        callback(owner.mixins.single),
        callback(owner.interfaces.single),
        callback(classes['OtherCallbackOwner']!.supertype!),
      ];
      expect(
        signatures.map((s) => s.typeParameters.single.declaration).toSet(),
        hasLength(4),
      );
      for (final signature in signatures) {
        expect(
          (signature.result as TypeParameterType).declaration,
          signature.typeParameters.single.declaration,
        );
        expect(
          (signature.parameters.single.type as TypeParameterType).declaration,
          signature.typeParameters.single.declaration,
        );
      }
    });

    test('assigns distinct slots to repeated wildcard type parameters', () {
      final callback =
          functions['wildcardCallback']!.parameters.single.type
              as FunctionTypeBinding;
      for (final parameters in [
        classes['GenericWildcards']!.typeParameters,
        functions['genericWildcards']!.typeParameters,
        callback.typeParameters,
      ]) {
        expect(parameters.map((p) => p.declaration.name), ['_', '_']);
        expect(parameters.map((p) => p.declaration.slot), [0, 1]);
        expect(parameters[0].declaration, isNot(parameters[1].declaration));
      }
      expect(
        functions['describe']!.typeParameters.single.declaration.slot,
        isNull,
      );
    });

    test('retains repeated wildcard positional parameters', () {
      final function = functions['wildcardValues']!;
      expect(function.parameters.map((p) => p.name), ['_', '_', 'p0']);
      expect(function.parameters.every((p) => p.type is SafeIntType), isTrue);
      final scalarModule = BindingModule(
        source: module.source,
        functions: [function],
      );
      expect(() => validate(scalarModule), returnsNormally);
    });

    test(
      'includes only own public members, preserving distinct accessor IDs',
      () {
        final box = classes['Container']!;
        final names = box.members.map((m) => m.declaration.name).toList();
        expect(names, isNot(contains('inherited')));
        expect(names, isNot(contains('inheritedMethod')));
        expect(names, isNot(contains('mixedInMethod')));
        expect(names, isNot(contains('_privateMethod')));
        expect(names, isNot(contains('_privateGetter')));
        expect(
          box.members.every((m) => m.declaration.owner == box.declaration),
          isTrue,
        );
        expect(
          box.members.where(
            (m) => m.kind == MemberKind.field && m.declaration.name == 'value',
          ),
          hasLength(1),
        );
        expect(
          box.members.where(
            (m) => m.kind != MemberKind.field && m.declaration.name == 'value',
          ),
          isEmpty,
        );
        final getter = box.members.singleWhere(
          (m) =>
              m.kind == MemberKind.getter &&
              m.declaration.name == 'nullableValue',
        );
        final setter = box.members.singleWhere(
          (m) =>
              m.kind == MemberKind.setter &&
              m.declaration.name == 'nullableValue',
        );
        expect(getter.declaration, isNot(setter.declaration));
        expect(getter.exportName, 'nullable');
        expect(setter.exportName, 'nullable');
        expect(getter.selection, MemberSelection.explicit);
        expect(setter.selection, MemberSelection.explicit);
        expect(getter.declaration.kind, DeclarationKind.getter);
        expect(setter.declaration.kind, DeclarationKind.setter);
        expect(getter.result!.nullability, TypeNullability.nullable);
        expect(
          setter.parameters.single.type.nullability,
          TypeNullability.nullable,
        );
      },
    );

    test(
      'records constructor, method, field, accessor, and selection metadata',
      () async {
        final box = classes['Container']!;
        MemberBinding member(String name) =>
            box.members.singleWhere((m) => m.declaration.name == name);
        final primary = box.members.singleWhere(
          (m) => m.kind == MemberKind.constructor && m.exportName == 'create',
        );
        expect(primary.selection, MemberSelection.explicit);
        expect(primary.documentation, contains('primary constructor'));
        await _expectSource(primary.source, 'Container');
        expect(primary.parameters.first.isInitializingFormal, isTrue);
        expect(primary.parameters.last.isSuperFormal, isTrue);
        expect(primary.parameters.last.defaultSource, '1');
        expect(member('empty').isFactory, isTrue);
        expect(member('named').kind, MemberKind.constructor);
        expect(member('value').isFinal, isTrue);
        expect(member('value').exportName, 'payload');
        expect(member('value').documentation, contains('stored payload'));
        expect(member('value').type, isA<TypeParameterType>());
        await _expectSource(member('value').source, 'value');
        expect(member('lazy').isLate, isTrue);
        expect(member('limit').isStatic, isTrue);
        expect(member('limit').isConst, isTrue);
        expect(member('limit').initializerSource, '4');
        expect(member('ratio').initializerSource, '1.5');
        expect(member('ignored').selection, MemberSelection.excluded);
        expect(member('ignored').kind, MemberKind.method);
        expect(member('twice').selection, MemberSelection.implicit);
        expect(member('twice').isStatic, isTrue);
        expect(member('visible').exportName, 'ignored');
        expect(member('visible').selection, MemberSelection.explicit);
        expect(member('instanceScope').exportName, 'shared');
        expect(member('instanceScope').isStatic, isFalse);
        expect(member('staticScope').exportName, 'shared');
        expect(member('staticScope').isStatic, isTrue);
        expect(member('+').isOperator, isTrue);
        expect(member('asyncMethod').isAsync, isTrue);
        expect(member('generatorMethod').isGenerator, isTrue);
        final map = member('map');
        expect(map.exportName, 'mapValue');
        expect(map.selection, MemberSelection.explicit);
        expect(map.typeParameters.single.declaration.owner, map.declaration);
        expect(
          (map.result as TypeParameterType).declaration,
          map.typeParameters.single.declaration,
        );
        expect(map.parameters.single.type, isA<FunctionTypeBinding>());
        expect(member('assign').parameters.single.isCovariant, isTrue);
        expect(
          classes['Immutable']!.members
              .singleWhere((m) => m.kind == MemberKind.constructor)
              .isConst,
          isTrue,
        );
        expect(
          classes['AbstractValue']!.members
              .singleWhere((m) => m.kind == MemberKind.getter)
              .isAbstract,
          isTrue,
        );
        expect(
          classes['AbstractValue']!.members
              .singleWhere((m) => m.kind == MemberKind.method)
              .isExternal,
          isTrue,
        );
        expect(
          classes['ImplicitConstructor']!.members.single.isSynthetic,
          isTrue,
        );
      },
    );

    test(
      'keeps declaration identities stable across analyzer sessions',
      () async {
        final again = await _frontend.read(module.source);
        expect(
          again.functions.map((f) => f.declaration),
          module.functions.map((f) => f.declaration),
        );
        expect(
          again.classes.map((c) => c.declaration),
          module.classes.map((c) => c.declaration),
        );
        final first = classes['Container']!;
        final second = again.classes.singleWhere(
          (c) => c.declaration.name == 'Container',
        );
        expect(
          second.members.map((m) => m.declaration),
          first.members.map((m) => m.declaration),
        );
      },
    );

    test('freezes normalized collections at every metadata level', () {
      expect(() => module.functions.clear(), throwsUnsupportedError);
      expect(() => module.classes.clear(), throwsUnsupportedError);
      expect(
        () => functions['describe']!.parameters.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => functions['describe']!.typeParameters.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => (functions['describe']!.result as DeclaredType).typeArguments
            .clear(),
        throwsUnsupportedError,
      );
      expect(
        () => classes['Container']!.members.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => (functions['recordValue']!.result as RecordTypeBinding).named
            .clear(),
        throwsUnsupportedError,
      );
    });
  });

  test('normalized declaration metadata matches the reviewed golden', () async {
    final directory = await _copyFixture('golden');
    final module = await _frontend.read(
      File('${directory.path}/entry.dart').uri,
    );
    final actual = _moduleJson(module, directory.uri);
    final golden = File('${_fixtures.path}/golden/metadata.json');
    expect(actual, jsonDecode(await golden.readAsString()));
  });

  group('annotation diagnostics', () {
    for (final (label, source, code) in _invalidCases) {
      test(label, () async {
        final directory = await Directory.systemTemp.createTemp(
          'napi-invalid-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/entry.dart');
        await file.writeAsString("import 'package:napi/napi.dart';\n$source\n");
        await expectLater(
          _frontend.read(file.uri),
          throwsA(
            _diagnostic(code)
                .having((e) => e.source?.uri, 'original source', file.uri),
          ),
        );
      });
    }

    test(
      'rejects a missing file and a non-file input before analysis',
      () async {
        await expectLater(
          _frontend.read(Uri.parse('https://example.test/api.dart')),
          throwsA(_diagnostic('NAPI_INPUT')),
        );
        await expectLater(
          _frontend.read(File('/no/such/napi/input.dart').uri),
          throwsA(_diagnostic('NAPI_INPUT')),
        );
      },
    );
  });
}

final _invalidCases = <(String, String, String)>[
  (
    'private function',
    '@NAPI() int _private(int value) => value;',
    'NAPI_VISIBILITY',
  ),
  ('private class', '@NAPI() class _Private {}', 'NAPI_VISIBILITY'),
  (
    'private member',
    '@NAPI() class Public { @NAPI() void _private() {} }',
    'NAPI_VISIBILITY',
  ),
  (
    'private constructor',
    '@NAPI() class Public { @NAPI() Public._private(); }',
    'NAPI_VISIBILITY',
  ),
  (
    'orphan member',
    'class Public { @NAPI() void method() {} }',
    'NAPI_SELECTION',
  ),
  ('typedef placement', '@NAPI() typedef Count = int;', 'NAPI_PLACEMENT'),
  ('variable placement', '@NAPI() final int value = 1;', 'NAPI_PLACEMENT'),
  (
    'parameter placement',
    'int function(@NAPI() int value) => value;',
    'NAPI_PLACEMENT',
  ),
  (
    'multiple field placement',
    '@NAPI() class Public { @NAPI() int first = 1, second = 2; }',
    'NAPI_PLACEMENT',
  ),
  (
    'extension placement',
    '@NAPI() extension Public on int { int doubled() => this * 2; }',
    'NAPI_PLACEMENT',
  ),
  ('mixin placement', '@NAPI() mixin Public {}', 'NAPI_PLACEMENT'),
  ('enum placement', '@NAPI() enum Public { first }', 'NAPI_PLACEMENT'),
  (
    'enum member placement',
    '@NAPI() int exported() => 0; enum Public { first; @NAPI() void method() {} }',
    'NAPI_PLACEMENT',
  ),
  (
    'mixin member placement',
    '@NAPI() int exported() => 0; mixin Public { @NAPI() void method() {} }',
    'NAPI_PLACEMENT',
  ),
  (
    'extension member placement',
    '@NAPI() int exported() => 0; extension Public on int { @NAPI() int method() => this; }',
    'NAPI_PLACEMENT',
  ),
  (
    'extension type member placement',
    '@NAPI() int exported() => 0; extension type Public(int value) { @NAPI() int method() => value; }',
    'NAPI_PLACEMENT',
  ),
  (
    'top-level getter placement',
    '@NAPI() int get value => 1;',
    'NAPI_PLACEMENT',
  ),

  (
    'duplicate annotations',
    '@NAPI() @NAPI() int function(int value) => value;',
    'NAPI_SELECTION',
  ),
  (
    'constant annotation object alias',
    'const selected = NAPI(); @selected int function(int value) => value;',
    'NAPI_ANNOTATION',
  ),
  (
    'conflicting member options',
    "@NAPI() class Public { @NAPI(name: 'renamed', exclude: true) void method() {} }",
    'NAPI_SELECTION',
  ),
  (
    'excluded top-level function',
    '@NAPI(exclude: true) int function(int value) => value;',
    'NAPI_PLACEMENT',
  ),
  ('excluded class', '@NAPI(exclude: true) class Public {}', 'NAPI_PLACEMENT'),
  (
    'duplicate function export names',
    "@NAPI(name: 'same') int first() => 1; @NAPI(name: 'same') int second() => 2;",
    'NAPI_DUPLICATE',
  ),
  (
    'duplicate function and class export names',
    "@NAPI(name: 'same') int first() => 1; @NAPI(name: 'same') class Second {}",
    'NAPI_DUPLICATE',
  ),
  (
    'duplicate member export names',
    "@NAPI() class Public { @NAPI(name: 'same') void first() {} @NAPI(name: 'same') void second() {} }",
    'NAPI_DUPLICATE',
  ),
  (
    'duplicate constructor export names',
    "@NAPI() class Public { @NAPI(name: 'same') Public.first(); @NAPI(name: 'same') Public.second(); }",
    'NAPI_DUPLICATE',
  ),
  (
    'inconsistent accessor export names',
    "@NAPI() class Public { @NAPI(name: 'first') int get value => 1; @NAPI(name: 'second') set value(int value) {} }",
    'NAPI_SELECTION',
  ),
  (
    'invalid export identifier',
    "@NAPI(name: 'not-valid') int function() => 1;",
    'NAPI_NAME',
  ),
  (
    'invalid member export identifier',
    "@NAPI() class Public { @NAPI(name: 'not-valid') void method() {} }",
    'NAPI_NAME',
  ),
  (
    'unresolved Dart type',
    '@NAPI() MissingType function(MissingType value) => value;',
    'NAPI_DART',
  ),
];

TypeMatcher<BindingDiagnostic> _diagnostic(String code) =>
    isA<BindingDiagnostic>().having((e) => e.code, 'diagnostic code', code);

Future<Directory> _copyFixture(String name) async {
  final directory = await Directory.systemTemp.createTemp('napi-frontend-');
  addTearDown(() => directory.delete(recursive: true));
  final fixture = Directory('${_fixtures.path}/$name');
  await for (final entity in fixture.list(recursive: true)) {
    if (entity is! File || !entity.path.endsWith('.dart.txt')) continue;
    final relative = p.relative(entity.path, from: fixture.path);
    final destination = File(
      p.join(directory.path, relative.substring(0, relative.length - 4)),
    );
    await destination.parent.create(recursive: true);
    await entity.copy(destination.path);
  }
  return directory;
}

Future<void> _expectSource(SourceLocation source, String name) async {
  final text = await File.fromUri(source.uri).readAsString();
  expect(text.substring(source.offset, source.offset + source.length), name);
  final prefix = text.substring(0, source.offset);
  expect(source.line, '\n'.allMatches(prefix).length + 1);
  expect(source.column, source.offset - prefix.lastIndexOf('\n'));
}

Map<String, Object?> _moduleJson(BindingModule module, Uri base) {
  String uri(Uri value) => value.toString().startsWith(base.toString())
      ? value.toString().substring(base.toString().length)
      : value.toString();
  Map<String, Object?> identity(DeclarationId value) => {
    'library': uri(value.library),
    'name': value.name,
    'kind': value.kind.name,
    if (value.slot != null) 'slot': value.slot,
    if (value.owner != null) 'owner': identity(value.owner!),
  };
  Map<String, Object?> location(SourceLocation value) => {
    'uri': uri(value.uri),
    'offset': value.offset,
    'length': value.length,
    'line': value.line,
    'column': value.column,
  };
  late Map<String, Object?> Function(BindingType) type;
  Map<String, Object?> typeParameter(TypeParameterBinding value) => {
    'declaration': identity(value.declaration),
    if (value.source != null) 'source': location(value.source!),
    if (value.documentation != null) 'documentation': value.documentation,
    if (value.bound != null) 'bound': type(value.bound!),
    if (value.defaultType != null) 'defaultType': type(value.defaultType!),
  };
  Map<String, Object?> parameter(ParameterBinding value) => {
    'name': value.name,
    'type': type(value.type),
    'kind': value.kind.name,
    'presence': value.presence.name,
    'hasDefault': value.hasDefault,
    if (value.defaultSource != null) 'defaultSource': value.defaultSource,
    if (value.documentation != null) 'documentation': value.documentation,
    if (value.source != null) 'source': location(value.source!),
    'flags': [
      if (value.isInitializingFormal) 'initializingFormal',
      if (value.isSuperFormal) 'superFormal',
      if (value.isCovariant) 'covariant',
    ],
  };
  type = (value) => {
    'kind': switch (value) {
      SafeIntType() => 'safeInt',
      DeclaredType() => 'declared',
      TypeParameterType() => 'typeParameter',
      DynamicType() => 'dynamic',
      VoidType() => 'void',
      NeverType() => 'never',
      FunctionTypeBinding() => 'function',
      RecordTypeBinding() => 'record',
    },
    'nullability': value.nullability.name,
    'semantics': value.semantics.name,
    if (value.alias != null)
      'alias': {
        'declaration': identity(value.alias!.declaration),
        'typeArguments': value.alias!.typeArguments.map(type).toList(),
      },
    if (value is DeclaredType) ...{
      'declaration': identity(value.declaration),
      'typeArguments': value.typeArguments.map(type).toList(),
    },
    if (value is TypeParameterType) 'declaration': identity(value.declaration),
    if (value is FunctionTypeBinding) ...{
      'result': type(value.result),
      'parameters': value.parameters.map(parameter).toList(),
      'typeParameters': value.typeParameters.map(typeParameter).toList(),
    },
    if (value is RecordTypeBinding) ...{
      'positional': value.positional.map(type).toList(),
      'named': {
        for (final entry in value.named.entries) entry.key: type(entry.value),
      },
    },
  };
  Map<String, Object?> member(MemberBinding value) => {
    'declaration': identity(value.declaration),
    'source': location(value.source),
    'kind': value.kind.name,
    'selection': value.selection.name,
    'exportName': value.exportName,
    'hasExplicitExportName': value.hasExplicitExportName,
    'callPath': value.callPath,
    if (value.documentation != null) 'documentation': value.documentation,
    'parameters': value.parameters.map(parameter).toList(),
    'typeParameters': value.typeParameters.map(typeParameter).toList(),
    if (value.result != null) 'result': type(value.result!),
    if (value.type != null) 'type': type(value.type!),
    if (value.initializerSource != null)
      'initializerSource': value.initializerSource,
    'flags': [
      if (value.isStatic) 'static',
      if (value.isFactory) 'factory',
      if (value.isConst) 'const',
      if (value.isAbstract) 'abstract',
      if (value.isExternal) 'external',
      if (value.isFinal) 'final',
      if (value.isLate) 'late',
      if (value.isSynthetic) 'synthetic',
      if (value.isAsync) 'async',
      if (value.isGenerator) 'generator',
      if (value.isOperator) 'operator',
    ],
  };
  return {
    'source': uri(module.source),
    'functions': [
      for (final value in module.functions)
        {
          'declaration': identity(value.declaration),
          'exportName': value.exportName,
          'source': location(value.source),
          'exportSurface': uri(value.exportSurface),
          'callPath': value.callPath,
          if (value.documentation != null) 'documentation': value.documentation,
          'parameters': value.parameters.map(parameter).toList(),
          'result': type(value.result),
          'typeParameters': value.typeParameters.map(typeParameter).toList(),
          'flags': [
            if (value.isExternal) 'external',
            if (value.isAsync) 'async',
            if (value.isGenerator) 'generator',
          ],
        },
    ],
    'classes': [
      for (final value in module.classes)
        {
          'declaration': identity(value.declaration),
          'exportName': value.exportName,
          'source': location(value.source),
          'exportSurface': uri(value.exportSurface),
          'callPath': value.callPath,
          if (value.documentation != null) 'documentation': value.documentation,
          'members': value.members.map(member).toList(),
          'typeParameters': value.typeParameters.map(typeParameter).toList(),
          if (value.supertype != null) 'supertype': type(value.supertype!),
          'interfaces': value.interfaces.map(type).toList(),
          'mixins': value.mixins.map(type).toList(),
          'flags': [
            if (value.isAbstract) 'abstract',
            if (value.isSealed) 'sealed',
            if (value.isBase) 'base',
            if (value.isInterface) 'interface',
            if (value.isFinal) 'final',
            if (value.isMixinClass) 'mixinClass',
          ],
        },
    ],
  };
}
