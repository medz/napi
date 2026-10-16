import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:test/test.dart';

final source = Uri.file('/fixtures/entry.dart');
final origin = Uri.file('/fixtures/implementation.dart');
final location = SourceLocation(source, 12, 4, line: 2, column: 3);

FunctionBinding function({
  BindingType result = const SafeIntType(),
  Iterable<ParameterBinding> parameters = const [],
  Iterable<TypeParameterBinding> typeParameters = const [],
  DeclarationId? declaration,
  String? callPath,
  Uri? exportSurface,
}) => FunctionBinding(
  declaration: declaration ?? DeclarationId(source, 'run'),
  exportName: 'run',
  source: location,
  parameters: parameters,
  result: result,
  typeParameters: typeParameters,
  callPath: callPath,
  exportSurface: exportSurface,
);

Matcher diagnostic(String code) => throwsA(
  isA<BindingDiagnostic>().having((error) => error.code, 'code', code),
);

void main() {
  test('identity retains origin, owner and declaration kind', () {
    final first = DeclarationId(
      source,
      'First',
      kind: DeclarationKind.classType,
    );
    final second = DeclarationId(
      source,
      'Second',
      kind: DeclarationKind.classType,
    );
    DeclarationId member(DeclarationId owner, DeclarationKind kind) =>
        DeclarationId(source, 'value', owner: owner, kind: kind);
    final identities = {
      member(first, DeclarationKind.field),
      member(first, DeclarationKind.getter),
      member(first, DeclarationKind.setter),
      member(second, DeclarationKind.getter),
      DeclarationId(
        origin,
        'value',
        owner: first,
        kind: DeclarationKind.getter,
      ),
    };
    expect(identities, hasLength(5));
    expect(
      member(first, DeclarationKind.getter),
      member(
        DeclarationId(source, 'First', kind: DeclarationKind.classType),
        DeclarationKind.getter,
      ),
    );
    expect(
      member(first, DeclarationKind.getter).hashCode,
      member(first, DeclarationKind.getter).hashCode,
    );
    expect(location.line, 2);
    expect(location.column, 3);
    expect(location.toString(), '$source:2:3');
  });

  test('all compound metadata defensively freezes its collections', () {
    final owner = DeclarationId(source, 'Box', kind: DeclarationKind.classType);
    final arguments = <BindingType>[const SafeIntType()];
    final named = <String, BindingType>{'value': const SafeIntType()};
    final parameters = [const ParameterBinding('value', SafeIntType())];
    final typeParameters = [
      TypeParameterBinding(
        declaration: DeclarationId(
          source,
          'T',
          owner: owner,
          kind: DeclarationKind.typeParameter,
        ),
      ),
    ];
    final alias = TypeAliasBinding(
      declaration: DeclarationId(
        source,
        'Alias',
        kind: DeclarationKind.typedefType,
      ),
      typeArguments: arguments,
    );
    final declared = DeclaredType(
      owner,
      ValueSemantics.reference,
      typeArguments: arguments,
    );
    final record = RecordTypeBinding(positional: arguments, named: named);
    final callback = FunctionTypeBinding(
      result: declared,
      parameters: parameters,
      typeParameters: typeParameters,
    );
    final member = MemberBinding(
      declaration: DeclarationId(
        source,
        'map',
        owner: owner,
        kind: DeclarationKind.method,
      ),
      source: location,
      kind: MemberKind.method,
      selection: MemberSelection.explicit,
      parameters: parameters,
      typeParameters: typeParameters,
      result: callback,
    );
    final members = [member];
    final binding = ClassBinding(
      declaration: owner,
      exportName: 'Box',
      source: location,
      members: members,
      typeParameters: typeParameters,
      interfaces: arguments,
      mixins: arguments,
    );
    final classes = [binding];
    final functions = [
      function(parameters: parameters, typeParameters: typeParameters),
    ];
    final module = BindingModule(
      source: source,
      functions: functions,
      classes: classes,
    );
    arguments.clear();
    named.clear();
    parameters.clear();
    typeParameters.clear();
    members.clear();
    classes.clear();
    functions.clear();

    for (final collection in [
      alias.typeArguments,
      declared.typeArguments,
      record.positional,
      callback.parameters,
      callback.typeParameters,
      member.parameters,
      member.typeParameters,
      binding.members,
      binding.typeParameters,
      binding.interfaces,
      binding.mixins,
      module.functions,
      module.functions.single.parameters,
      module.functions.single.typeParameters,
      module.classes,
    ]) {
      expect(collection, hasLength(1));
      expect(() => collection.clear(), throwsUnsupportedError);
    }
    expect(record.named, hasLength(1));
    expect(() => record.named.clear(), throwsUnsupportedError);
  });

  test(
    'parameter defaults and presence are normalized without losing syntax',
    () {
      const optional = ParameterBinding(
        'value',
        SafeIntType(nullability: TypeNullability.nullable),
        kind: ParameterKind.optionalNamed,
        defaultSource: 'null',
        documentation: 'A value.',
        isInitializingFormal: true,
        isSuperFormal: true,
        isCovariant: true,
      );
      expect(optional.hasDefault, isTrue);
      expect(optional.defaultSource, 'null');
      expect(optional.presence, ParameterPresence.optional);
      expect(optional.documentation, 'A value.');
      expect(optional.isInitializingFormal, isTrue);
      expect(optional.isSuperFormal, isTrue);
      expect(optional.isCovariant, isTrue);
      expect(optional.type.nullability, TypeNullability.nullable);
      const named = ParameterBinding(
        'value',
        SafeIntType(),
        kind: ParameterKind.requiredNamed,
      );
      expect(named.presence, ParameterPresence.required);
      expect(named.hasDefault, isFalse);
      const legacy = ParameterBinding(
        'value',
        SafeIntType(),
        presence: ParameterPresence.opaqueOptional,
      );
      expect(legacy.presence, ParameterPresence.opaqueOptional);
    },
  );

  test('declaration validation retains rich types and generic metadata', () {
    final owner = DeclarationId(source, 'run');
    final parameter = TypeParameterBinding(
      declaration: DeclarationId(
        source,
        'T',
        owner: owner,
        kind: DeclarationKind.typeParameter,
      ),
      source: location,
      bound: DeclaredType(
        DeclarationId(Uri.parse('dart:core'), 'Object'),
        ValueSemantics.reference,
      ),
      defaultType: const DynamicType(),
      documentation: 'The element type.',
    );
    final variable = TypeParameterType(parameter.declaration);
    final list = DeclaredType(
      DeclarationId(Uri.parse('dart:core'), 'List'),
      ValueSemantics.structural,
      typeArguments: [variable],
      nullability: TypeNullability.nullable,
    );
    final callback = FunctionTypeBinding(
      result: const VoidType(),
      parameters: [ParameterBinding('', variable)],
      typeParameters: [parameter],
      nullability: TypeNullability.nullable,
      alias: TypeAliasBinding(
        declaration: DeclarationId(
          origin,
          'Callback',
          kind: DeclarationKind.typedefType,
        ),
        typeArguments: [variable],
      ),
    );
    final record = RecordTypeBinding(
      positional: [list],
      named: {'callback': callback, 'never': const NeverType()},
    );
    final binding = function(
      typeParameters: [parameter],
      parameters: [
        ParameterBinding(
          'callback',
          callback,
          kind: ParameterKind.optionalNamed,
          defaultSource: 'null',
          source: location,
        ),
      ],
      result: record,
    );
    final module = BindingModule(source: source, functions: [binding]);
    final validated = validateDeclarations(module);
    expect(validated.bindings.functions.single, same(binding));
    expect(binding.callPath, 'run');
    expect(binding.exportSurface, source);
    expect(binding.result, same(record));
    expect(list.typeArguments.single, same(variable));
    expect(callback.alias!.declaration.library, origin);
    expect(callback.typeParameters.single.bound, isA<DeclaredType>());
    expect(callback.parameters.single.name, isEmpty);
    expect(() => validate(module), diagnostic('NAPI_GENERIC'));
  });

  test(
    'all class members survive descriptive validation; backend fails closed',
    () {
      final owner = DeclarationId(
        source,
        'Box',
        kind: DeclarationKind.classType,
      );
      MemberBinding member(
        String name,
        MemberKind kind,
        DeclarationKind declarationKind, {
        MemberSelection selection = MemberSelection.implicit,
        bool isFactory = false,
      }) => MemberBinding(
        declaration: DeclarationId(
          source,
          name,
          owner: owner,
          kind: declarationKind,
        ),
        source: location,
        kind: kind,
        selection: selection,
        isFactory: isFactory,
        result: const SafeIntType(),
        type: kind == MemberKind.field ? const SafeIntType() : null,
      );
      final binding = ClassBinding(
        declaration: owner,
        exportName: 'Box',
        source: location,
        documentation: 'A documented class.',
        members: [
          member('', MemberKind.constructor, DeclarationKind.constructor),
          member(
            'make',
            MemberKind.constructor,
            DeclarationKind.constructor,
            isFactory: true,
          ),
          member('read', MemberKind.method, DeclarationKind.method),
          member('value', MemberKind.getter, DeclarationKind.getter),
          member('value', MemberKind.setter, DeclarationKind.setter),
          member(
            '_hidden',
            MemberKind.field,
            DeclarationKind.field,
            selection: MemberSelection.excluded,
          ),
        ],
      );
      final module = BindingModule(source: source, classes: [binding]);
      final validated = validateDeclarations(module);
      expect(validated.bindings.classes.single.members, hasLength(6));
      expect(binding.members[1].isFactory, isTrue);
      expect(binding.members.last.selection, MemberSelection.excluded);
      expect(() => validate(module), diagnostic('NAPI_CLASS'));
      expect(
        () => validate(
          BindingModule(
            source: source,
            functions: [function()],
            classes: [binding],
          ),
        ),
        diagnostic('NAPI_CLASS'),
      );
    },
  );

  test('unsupported parameter kinds keep the presence diagnostic', () {
    for (final kind in ParameterKind.values.skip(1)) {
      final module = BindingModule(
        source: source,
        functions: [
          function(
            parameters: [
              ParameterBinding('value', const SafeIntType(), kind: kind),
            ],
          ),
        ],
      );
      expect(validateDeclarations(module).bindings.functions, hasLength(1));
      expect(() => validate(module), diagnostic('NAPI_PRESENCE'));
    }
  });

  test('legacy integer nullability cannot reach scalar lowering', () {
    for (final type in [
      const SafeIntType(nullability: TypeNullability.legacy),
    ]) {
      for (final binding in [
        function(result: type),
        function(parameters: [ParameterBinding('value', type)]),
      ]) {
        final module = BindingModule(source: source, functions: [binding]);
        expect(validateDeclarations(module).bindings.functions, hasLength(1));
        expect(() => validate(module), diagnostic('NAPI_TYPE'));
      }
    }
  });

  test(
    'reexport origin is retained while entry surface and call path drive emit',
    () {
      final binding = function(
        declaration: DeclarationId(origin, 'original'),
        callPath: 'Facade.run',
        exportSurface: source,
      );
      final plan = lower(
        validate(BindingModule(source: source, functions: [binding])),
      );
      expect(plan.source, source);
      expect(plan.functions.single.binding.declaration.library, origin);
      expect(emitDart(plan), contains('import "$source" as target;'));
      expect(emitDart(plan), contains('target.Facade.run()'));
      expect(emitDart(plan), isNot(contains('target.original()')));
      expect(
        () => validate(
          BindingModule(
            source: source,
            functions: [function(declaration: DeclarationId(origin, 'run'))],
          ),
        ),
        diagnostic('NAPI_LIBRARY'),
      );
    },
  );

  test('generic alias metadata does not change a resolved safe-int ABI', () {
    final integer = SafeIntType(
      alias: TypeAliasBinding(
        declaration: DeclarationId(
          source,
          'Identity',
          kind: DeclarationKind.typedefType,
        ),
        typeArguments: [const SafeIntType()],
      ),
    );
    final module = BindingModule(
      source: source,
      functions: [function(result: integer)],
    );
    expect(
      lower(validate(module)).functions.single.binding.result,
      same(integer),
    );
  });

  test('call paths cannot inject generated Dart code', () {
    for (final path in [
      '_hidden',
      'api._hidden',
      'run(); throw 1',
      'api..run',
    ]) {
      expect(
        () => validate(
          BindingModule(
            source: source,
            functions: [function(callPath: path)],
          ),
        ),
        diagnostic('NAPI_NAME'),
      );
    }
  });

  test('function and class export names share one namespace', () {
    expect(
      () => validateDeclarations(
        BindingModule(
          source: source,
          functions: [function()],
          classes: [
            ClassBinding(
              declaration: DeclarationId(
                source,
                'Box',
                kind: DeclarationKind.classType,
              ),
              exportName: 'run',
              source: location,
            ),
          ],
        ),
      ),
      diagnostic('NAPI_DUPLICATE'),
    );
  });

  group('member export integrity', () {
    final owner = DeclarationId(source, 'Box', kind: DeclarationKind.classType);
    MemberBinding member(
      String name,
      MemberKind kind, {
      String? exportName,
      MemberSelection selection = MemberSelection.implicit,
      bool isStatic = false,
      bool isOperator = false,
    }) => MemberBinding(
      declaration: DeclarationId(
        source,
        name,
        owner: owner,
        kind: switch (kind) {
          MemberKind.constructor => DeclarationKind.constructor,
          MemberKind.method => DeclarationKind.method,
          MemberKind.getter => DeclarationKind.getter,
          MemberKind.setter => DeclarationKind.setter,
          MemberKind.field => DeclarationKind.field,
        },
      ),
      source: location,
      kind: kind,
      selection: selection,
      exportName: exportName,
      hasExplicitExportName: exportName != null,
      isStatic: isStatic,
      isOperator: isOperator,
    );
    ValidatedDeclarations check(List<MemberBinding> members) =>
        validateDeclarations(
          BindingModule(
            source: source,
            classes: [
              ClassBinding(
                declaration: owner,
                exportName: 'Box',
                source: location,
                members: members,
              ),
            ],
          ),
        );

    test('paired accessors can share one name and alias', () {
      expect(
        check([
          member('value', MemberKind.getter, exportName: 'renamed'),
          member('value', MemberKind.setter, exportName: 'renamed'),
        ]).bindings.classes.single.members,
        hasLength(2),
      );
    });
    test('same namespace collisions are rejected for unrelated members', () {
      for (final pair in [
        [
          member('read', MemberKind.method, exportName: 'value'),
          member('value', MemberKind.field),
        ],
        [
          member('first', MemberKind.getter, exportName: 'value'),
          member('second', MemberKind.setter, exportName: 'value'),
        ],
      ]) {
        expect(() => check(pair), diagnostic('NAPI_DUPLICATE'));
      }
    });
    test('paired accessors cannot select inconsistent aliases', () {
      expect(
        () => check([
          member('value', MemberKind.getter, exportName: 'renamed'),
          member('value', MemberKind.setter),
        ]),
        diagnostic('NAPI_SELECTION'),
      );
    });
    test('an excluded accessor does not constrain the selected accessor', () {
      expect(
        check([
          member('value', MemberKind.getter, exportName: 'renamed'),
          member(
            'value',
            MemberKind.setter,
            selection: MemberSelection.excluded,
          ),
        ]).bindings.classes.single.members,
        hasLength(2),
      );
    });
    test('static and instance properties have separate namespaces', () {
      expect(
        check([
          member('first', MemberKind.method, exportName: 'value'),
          member(
            'second',
            MemberKind.method,
            exportName: 'value',
            isStatic: true,
          ),
        ]).bindings.classes.single.members,
        hasLength(2),
      );
    });
    test('constructors have a separate name namespace', () {
      expect(
        check([
          member('named', MemberKind.constructor, exportName: 'make'),
          member(
            'method',
            MemberKind.method,
            exportName: 'make',
            isStatic: true,
          ),
        ]).bindings.classes.single.members,
        hasLength(2),
      );
      expect(
        () => check([
          member('first', MemberKind.constructor, exportName: 'make'),
          member('second', MemberKind.constructor, exportName: 'make'),
        ]),
        diagnostic('NAPI_DUPLICATE'),
      );
    });
    test(
      'operator metadata is kept without accepting invalid explicit aliases',
      () {
        expect(
          check([member('+', MemberKind.method, isOperator: true)])
              .bindings
              .classes
              .single
              .members,
          hasLength(1),
        );
        expect(
          () => check([
            member('+', MemberKind.method, exportName: '+', isOperator: true),
          ]),
          diagnostic('NAPI_NAME'),
        );
        expect(
          () => check([
            member('value', MemberKind.field, exportName: '_private'),
          ]),
          diagnostic('NAPI_NAME'),
        );
      },
    );
  });
}
