import 'dart:io';

import 'package:napi/napi.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi concrete aliases ');
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<File> source(String text, [String name = 'entry.dart']) async =>
      File('${directory.path}/$name')..writeAsStringSync(text);
  Future<BindingModule> read(File input, {bool native = false}) =>
      AnnotationFrontend(
        packagesPath: _packages,
        native: native,
      ).read(input.uri);
  Future<BindingModule> external(File input, ExternalLibrary selection) =>
      ExternalFrontend(selection, packagesPath: _packages).read(input.uri);
  Matcher diagnostic(String code) =>
      isA<BindingDiagnostic>().having((error) => error.code, 'code', code);

  const cells = '''
import 'package:napi/napi.dart';
class Cell<T extends num> {
  T value;
  final String label;
  Cell(this.value, {this.label = 'ready'});
  Cell.named(this.value) : label = 'named';
  T get current => value;
  set current(T next) => value = next;
  List<Map<String, T?>> nested() => [{'value': value}];
  Cell<T> self() => this;
  int hidden() => 7;
}
typedef NumericCell<N extends num> = Cell<N>;
@NAPI()
typedef IntCell = NumericCell<int>;
@NAPI(name: 'FloatingCell')
typedef DoubleCell = Cell<double>;
''';

  for (final native in [false, true]) {
    test(
      'concrete aliases retain substituted signatures (${native ? 'native' : 'wasm'} SDK)',
      () async {
        final input = await source(cells);
        final module = await read(input, native: native);
        expect(module.classes, hasLength(2));
        final integer = module.classes[0], floating = module.classes[1];
        expect(integer.declaration, floating.declaration);
        expect(integer.declaration.name, 'Cell');
        expect(integer.selectionDeclaration!.name, 'IntCell');
        expect(floating.selectionDeclaration!.name, 'DoubleCell');
        expect(integer.selectionDeclaration!.kind, DeclarationKind.typedefType);
        expect(integer.typeParameters, isEmpty);
        expect(floating.typeParameters, isEmpty);
        expect(integer.callPath, 'IntCell');
        expect(floating.callPath, 'DoubleCell');
        expect(floating.exportName, 'FloatingCell');
        expect(integer.instantiatedType!.declaration, integer.declaration);
        expect(
          integer.instantiatedType!.typeArguments.single,
          isA<SafeIntType>(),
        );
        expect(
          (floating.instantiatedType!.typeArguments.single as DeclaredType)
              .declaration
              .name,
          'double',
        );
        MemberBinding member(
          ClassBinding owner,
          String name,
          MemberKind kind,
        ) => owner.members.singleWhere(
          (value) => value.declaration.name == name && value.kind == kind,
        );
        expect(
          member(integer, 'value', MemberKind.field).type,
          isA<SafeIntType>(),
        );
        expect(
          (member(floating, 'value', MemberKind.field).type as DeclaredType)
              .declaration
              .name,
          'double',
        );
        expect(
          member(integer, 'current', MemberKind.getter).result,
          isA<SafeIntType>(),
        );
        expect(
          member(integer, 'current', MemberKind.setter).parameters.single.type,
          isA<SafeIntType>(),
        );
        final constructor = member(integer, 'new', MemberKind.constructor);
        expect(constructor.parameters.first.type, isA<SafeIntType>());
        expect(constructor.parameters.last.defaultValue!.value, 'ready');
        expect(constructor.parameters.last.kind, ParameterKind.optionalNamed);
        expect(
          member(
            integer,
            'named',
            MemberKind.constructor,
          ).parameters.single.type,
          isA<SafeIntType>(),
        );
        final list =
            member(integer, 'nested', MemberKind.method).result as DeclaredType;
        final map = list.typeArguments.single as DeclaredType;
        expect(map.typeArguments.last, isA<SafeIntType>());
        expect(map.typeArguments.last.nullability, TypeNullability.nullable);
        final self =
            member(integer, 'self', MemberKind.method).result as DeclaredType;
        expect(self.declaration, integer.declaration);
        expect(self.typeArguments.single, isA<SafeIntType>());
        for (final item in integer.members) {
          expect(item.declaration.owner, integer.declaration);
          expect(item.source.uri, input.uri);
        }
        final text = await input.readAsString();
        expect(
          text.substring(integer.source.offset).startsWith('IntCell'),
          isTrue,
        );
        expect(
          text
              .substring(constructor.parameters.last.source!.offset)
              .startsWith('label'),
          isTrue,
        );
        expect(validate(module).classes, hasLength(2));
        expect(validateNative(module).classes, hasLength(2));
      },
    );
  }

  test('concrete aliases map function inputs in both planners', () async {
    final input = await source('''
import 'package:napi/napi.dart';
class Cell<T> { T value; Cell(this.value); }
@NAPI() typedef IntCell = Cell<int>;
@NAPI() int read(IntCell value) => value.value;
''');
    final module = await read(input);
    expect(validate(module).classes, hasLength(1));
    expect(validateNative(module).classes, hasLength(1));
  });

  test(
    'concrete selection metadata cannot disguise an ordinary class',
    () async {
      final input = await source(cells);
      final original = (await read(input)).classes.first;
      BindingModule malformed({
        DeclarationId? selection,
        DeclaredType? instance,
      }) => BindingModule(
        source: input.uri,
        classes: [
          ClassBinding(
            declaration: original.declaration,
            exportName: original.exportName,
            source: original.source,
            selectionDeclaration: selection,
            instantiatedType: instance,
          ),
        ],
      );
      expect(
        () => validateDeclarations(
          malformed(selection: original.selectionDeclaration),
        ),
        throwsA(diagnostic('NAPI_DECLARATION')),
      );
      expect(
        () => validateDeclarations(
          malformed(instance: original.instantiatedType),
        ),
        throwsA(diagnostic('NAPI_DECLARATION')),
      );
      expect(
        () => validateDeclarations(
          malformed(
            selection: original.selectionDeclaration,
            instance: DeclaredType(
              DeclarationId(
                input.uri,
                'Other',
                kind: DeclarationKind.classType,
              ),
              ValueSemantics.reference,
            ),
          ),
        ),
        throwsA(diagnostic('NAPI_DECLARATION')),
      );
    },
  );

  test('external overrides are scoped independently to each alias', () async {
    final input = await source(cells);
    final module = await external(
      input,
      const ExternalLibrary([
        ExternalClass(
          'IntCell',
          members: [
            ExternalMember.field('value', config: NAPI(name: 'integer')),
            ExternalMember.method('hidden', config: NAPI(exclude: true)),
          ],
        ),
        ExternalClass(
          'DoubleCell',
          config: NAPI(name: 'Decimal'),
          members: [
            ExternalMember.field('value', config: NAPI(name: 'decimal')),
            ExternalMember.constructor('named', config: NAPI(name: 'create')),
          ],
        ),
      ]),
    );
    final integer = module.classes[0], floating = module.classes[1];
    MemberBinding member(ClassBinding owner, String name) =>
        owner.members.singleWhere((item) => item.declaration.name == name);
    expect(member(integer, 'value').exportName, 'integer');
    expect(member(floating, 'value').exportName, 'decimal');
    expect(member(integer, 'hidden').selection, MemberSelection.excluded);
    expect(member(floating, 'hidden').selection, MemberSelection.implicit);
    expect(member(integer, 'named').exportName, 'named');
    expect(member(floating, 'named').exportName, 'create');
    expect(floating.exportName, 'Decimal');
    expect(validateNative(module).classes, hasLength(2));
  });

  test('a class and its alias have independent external overrides', () async {
    final input = await source('''
class Cell<T> { T value; Cell(this.value); }
typedef IntCell = Cell<int>;
''');
    final module = await external(
      input,
      const ExternalLibrary([
        ExternalClass(
          'Cell',
          members: [
            ExternalMember.field('value', config: NAPI(name: 'payload')),
          ],
        ),
        ExternalClass(
          'IntCell',
          members: [
            ExternalMember.field('value', config: NAPI(name: 'number')),
          ],
        ),
      ]),
    );
    final open = module.classes[0], closed = module.classes[1];
    expect(open.typeParameters.single.opaque, isTrue);
    expect(open.instantiatedType, isNull);
    expect(
      open.members.singleWhere((m) => m.kind == MemberKind.field).exportName,
      'payload',
    );
    expect(
      closed.members.singleWhere((m) => m.kind == MemberKind.field).exportName,
      'number',
    );
    expect(
      closed.members.singleWhere((m) => m.kind == MemberKind.field).type,
      isA<SafeIntType>(),
    );
  });

  test(
    'selected alias permits source member configuration on its original class',
    () async {
      final input = await source('''
import 'package:napi/napi.dart';
class Cell<T> {
  @NAPI(name: 'stored') T value;
  Cell(this.value);
  @NAPI(exclude: true) dynamic hidden(dynamic value) => value;
}
@NAPI() typedef IntCell = Cell<int>;
@NAPI() typedef TextCell = Cell<String>;
''');
      final module = await read(input);
      for (final alias in module.classes) {
        expect(
          alias.members
              .singleWhere((m) => m.declaration.name == 'value')
              .exportName,
          'stored',
        );
        expect(
          alias.members
              .singleWhere((m) => m.declaration.name == 'hidden')
              .selection,
          MemberSelection.excluded,
        );
      }
    },
  );

  test(
    'reexported aliases preserve original member and selection sources',
    () async {
      final origin = await source('''
class Cell<T> { T value; Cell(this.value); }
''', 'origin.dart');
      final aliases = await source('''
import 'package:napi/napi.dart';
import 'origin.dart';
typedef Chain<T> = Cell<T>;
/// Selected alias documentation.
@NAPI() typedef IntCell = Chain<int>;
''', 'aliases.dart');
      final entry = await source("export 'aliases.dart' show IntCell;\n");
      final module = await read(entry);
      final alias = module.classes.single;
      expect(alias.declaration.library, origin.uri);
      expect(alias.selectionDeclaration!.library, aliases.uri);
      expect(alias.source.uri, aliases.uri);
      expect(alias.exportSurface, entry.uri);
      expect(alias.callPath, 'IntCell');
      expect(alias.documentation, contains('Selected alias documentation'));
      expect(alias.members.every((m) => m.source.uri == origin.uri), isTrue);
      expect(alias.instantiatedType!.typeArguments.single, isA<SafeIntType>());
      final selected = await external(
        entry,
        const ExternalLibrary([ExternalClass('IntCell')]),
      );
      expect(selected.classes.single.declaration, alias.declaration);
      expect(
        selected.classes.single.selectionDeclaration,
        alias.selectionDeclaration,
      );
    },
  );

  test(
    'aliases of one concrete type keep canonical declaration and arguments',
    () async {
      final input = await source('''
import 'package:napi/napi.dart';
class Cell<T> { T value; Cell(this.value); }
typedef Chain<T> = Cell<T>;
@NAPI() typedef One = Cell<int>;
@NAPI() typedef Two = Chain<int>;
''');
      final module = await read(input);
      final a = module.classes[0].instantiatedType!,
          b = module.classes[1].instantiatedType!;
      expect(a.declaration, b.declaration);
      expect(a.typeArguments.single, isA<SafeIntType>());
      expect(b.typeArguments.single, isA<SafeIntType>());
      expect(
        module.classes[0].selectionDeclaration,
        isNot(module.classes[1].selectionDeclaration),
      );
      expect(() => validate(module), throwsA(diagnostic('NAPI_GENERIC')));
    },
  );

  test(
    'ordinary open generic mappings remain opaque beside a concrete alias',
    () async {
      final input = await source('''
import 'package:napi/napi.dart';
@NAPI() class Box<T> { T value; Box(this.value); }
@NAPI() typedef IntBox = Box<int>;
@NAPI() T identity<T>(T value) => value;
''');
      final module = await read(input);
      final open = module.classes[0], concrete = module.classes[1];
      expect(open.selectionDeclaration, isNull);
      expect(open.instantiatedType, isNull);
      expect(open.typeParameters.single.opaque, isTrue);
      expect(
        open.members
            .singleWhere((m) => m.kind == MemberKind.field)
            .type!
            .semantics,
        ValueSemantics.opaque,
      );
      expect(concrete.typeParameters, isEmpty);
      expect(
        concrete.members.singleWhere((m) => m.kind == MemberKind.field).type,
        isA<SafeIntType>(),
      );
      expect(module.functions.single.typeParameters.single.opaque, isTrue);
      expect(() => validate(module), throwsA(diagnostic('NAPI_GENERIC')));
      expect(() => validateNative(module), throwsA(diagnostic('NAPI_GENERIC')));
    },
  );

  test('valid F-bound aliases use substituted reference arguments', () async {
    final input = await source('''
import 'package:napi/napi.dart';
class Ranked implements Comparable<Ranked> { int compareTo(Ranked value) => 0; }
class Cell<T extends Comparable<T>> { final T value; Cell(this.value); }
@NAPI() typedef RankedCell = Cell<Ranked>;
''');
    final module = await read(input);
    final argument =
        module.classes.single.instantiatedType!.typeArguments.single
            as DeclaredType;
    expect(argument.declaration.name, 'Ranked');
    final field = module.classes.single.members.singleWhere(
      (m) => m.kind == MemberKind.field,
    );
    expect((field.type as DeclaredType).declaration, argument.declaration);
  });

  test(
    'canonical matches preserve nested nullability but ignore alias spelling',
    () async {
      final input = await source('''
import 'package:napi/napi.dart';
class Cell<T> { T value; Cell(this.value); }
typedef Payload = List<(int, {String? name})>;
@NAPI() typedef Rows = Cell<Payload>;
@NAPI() typedef NullableRows = Cell<List<(int?, {String? name})>>;
@NAPI() Rows? roundtrip(Cell<List<(int, {String? name})>>? value) => value;
''');
      final module = await read(input);
      final rows = module.classes[0], nullable = module.classes[1];
      final inputType =
          module.functions.single.parameters.single.type as DeclaredType;
      expect(referenceClassMatches(rows, inputType), isTrue);
      expect(referenceClassMatches(nullable, inputType), isFalse);
      expect(isReferenceType(inputType, module.classes), isTrue);
      expect(validate(module).classes, hasLength(2));
      expect(validateNative(module).classes, hasLength(2));
    },
  );

  test('concrete subtype metadata orders nullable views without granting membership', () async {
    final input = await source('''
import 'package:napi/napi.dart';
class Cell<T> { T value; Cell(this.value); }
@NAPI() typedef IntCell = Cell<int>;
@NAPI() typedef DoubleCell = Cell<double>;
@NAPI() typedef NullableCell = Cell<int?>;
''');
    for (final module in [
      await read(input),
      await external(
        input,
        const ExternalLibrary([
          ExternalClass('IntCell'),
          ExternalClass('DoubleCell'),
          ExternalClass('NullableCell'),
        ]),
      ),
    ]) {
      final integer = module.classes[0],
          floating = module.classes[1],
          nullable = module.classes[2];
      expect(integer.concreteSupertypes, hasLength(1));
      expect(
        referenceClassMatches(nullable, integer.concreteSupertypes.single),
        isTrue,
      );
      expect(floating.concreteSupertypes, isEmpty);
      expect(nullable.concreteSupertypes, isEmpty);
      final shapes = validate(module).classes;
      for (final shape in shapes) {
        expect(shape.memberships, {shape.classId});
        expect(shape.superclassId, isNull);
      }
    }
  });

  test('selected concrete inheritance stays explicitly unsupported', () async {
    for (final declarations in [
      '@NAPI() class Base {} class Cell<T> extends Base {} @NAPI() typedef IntCell = Cell<int>;',
      'class Cell<T> {} @NAPI() typedef IntCell = Cell<int>; @NAPI() class Child extends Cell<int> {}',
      '@NAPI() class Base {} class Cell<T> implements Base {} @NAPI() typedef IntCell = Cell<int>;',
    ]) {
      final module = await read(
        await source("import 'package:napi/napi.dart';\n$declarations"),
      );
      expect(() => validate(module), throwsA(diagnostic('NAPI_GENERIC')));
      expect(() => validateNative(module), throwsA(diagnostic('NAPI_GENERIC')));
    }
  });

  test(
    'concrete boundary instances stay invariant in selected inherited results',
    () async {
      final module = await read(
        await source('''
import 'package:napi/napi.dart';
class Cell<T> { T value; Cell(this.value); }
@NAPI() typedef IntCell = Cell<int>;
@NAPI() typedef NullableCell = Cell<int?>;
@NAPI() class Base { NullableCell get cell => NullableCell(null); }
@NAPI() class Child extends Base { @override IntCell get cell => IntCell(1); }
'''),
      );
      expect(() => validate(module), throwsA(diagnostic('NAPI_INHERITANCE')));
      expect(
        () => validateNative(module),
        throwsA(diagnostic('NAPI_INHERITANCE')),
      );
    },
  );

  test('concrete aliases do not silently erase dynamic type arguments', () async {
    for (final argument in ['dynamic', 'List<dynamic>']) {
      final module = await read(
        await source(
          "import 'package:napi/napi.dart';\nclass Cell<T> {} @NAPI() typedef AnyCell = Cell<$argument>;",
        ),
      );
      expect(() => validate(module), throwsA(diagnostic('NAPI_GENERIC')));
      expect(() => validateNative(module), throwsA(diagnostic('NAPI_GENERIC')));
    }
  });

  test(
    'private TypeScript concrete brand cannot collide with a renamed member',
    () async {
      final input = await source('''
import 'package:napi/napi.dart';
class Cell<T> { @NAPI(name: r'\$napiConcrete') T value; Cell(this.value); }
@NAPI() typedef IntCell = Cell<int>;
''');
      final module = await read(input);
      expect(() => validate(module), throwsA(diagnostic('NAPI_NAME')));
      expect(() => validateNative(module), throwsA(diagnostic('NAPI_NAME')));
    },
  );

  test(
    'opaque names only conflict with the referenced concrete instance',
    () async {
      final input = await source('''
import 'package:napi/napi.dart';
class Cell<T> { T value; Cell(this.value); }
@NAPI() typedef IntCell = Cell<int>;
@NAPI() typedef DoubleCell = Cell<double>;
@NAPI() IntCell echo<DoubleCell>(IntCell value, DoubleCell payload) => value;
''');
      for (final module in [
        await read(input),
        await external(
          input,
          const ExternalLibrary([
            ExternalClass('IntCell'),
            ExternalClass('DoubleCell'),
            ExternalFunction('echo'),
          ]),
        ),
      ]) {
        expect(validate(module).classes, hasLength(2));
        expect(validateNative(module).classes, hasLength(2));
      }
    },
  );

  test('opaque names may shadow hidden concrete type arguments', () async {
    final input = await source('''
import 'package:napi/napi.dart';
class Cell<T> { T value; Cell(this.value); }
@NAPI() class Leaf { int value; Leaf(this.value); }
@NAPI() typedef LeafCell = Cell<Leaf>;
@NAPI() List<LeafCell> echo<Leaf>(List<LeafCell> value, Leaf payload) => value;
''');
    final module = await read(input);
    expect(validate(module).classes, hasLength(2));
    expect(validateNative(module).classes, hasLength(2));
  });

  test(
    'indistinguishable concrete type tests are diagnosed before planning',
    () async {
      for (final (first, second) in [
        ('void', 'Object?'),
        ('List<void>', 'List<Object?>'),
        ('void Function()', 'Object? Function()'),
      ]) {
        final input = await source(
          "import 'package:napi/napi.dart';\n"
          'class Marker<T> { Marker(); int get value => 1; }\n'
          '@NAPI() typedef First = Marker<$first>;\n'
          '@NAPI() typedef Second = Marker<$second>;',
        );
        for (final native in [false, true]) {
          await expectLater(
            read(input, native: native),
            throwsA(diagnostic('NAPI_GENERIC')),
          );
        }
        await expectLater(
          external(
            input,
            const ExternalLibrary([
              ExternalClass('First'),
              ExternalClass('Second'),
            ]),
          ),
          throwsA(diagnostic('NAPI_GENERIC')),
        );
      }
    },
  );

  test('scalar and container aliases retain placement diagnostics', () async {
    for (final type in ['int', 'List<int>', 'Map<String, int>']) {
      final input = await source(
        "import 'package:napi/napi.dart';\n@NAPI() typedef Selected = $type;",
      );
      await expectLater(read(input), throwsA(diagnostic('NAPI_PLACEMENT')));
      await expectLater(
        external(input, const ExternalLibrary([ExternalClass('Selected')])),
        throwsA(diagnostic('NAPI_PLACEMENT')),
      );
    }
  });

  for (final (name, body, code) in [
    (
      'open alias',
      'class Cell<T> {} @NAPI() typedef Selected<T> = Cell<T>;',
      'NAPI_GENERIC',
    ),
    (
      'nullable alias',
      'class Cell<T> {} @NAPI() typedef Selected = Cell<int>?;',
      'NAPI_GENERIC',
    ),
    (
      'function alias',
      '@NAPI() typedef Selected = int Function(int);',
      'NAPI_GENERIC',
    ),
    (
      'enum alias',
      'enum Item { one } @NAPI() typedef Selected = Item;',
      'NAPI_GENERIC',
    ),
    (
      'bound',
      'class Cell<T extends num> {} @NAPI() typedef Selected = Cell<String>;',
      'NAPI_DART',
    ),
    (
      'F-bound',
      'class Cell<T extends Comparable<T>> {} @NAPI() typedef Selected = Cell<int>;',
      'NAPI_DART',
    ),
  ]) {
    test('diagnoses unsupported $name at the source', () async {
      final input = await source("import 'package:napi/napi.dart';\n$body");
      await expectLater(read(input), throwsA(diagnostic(code)));
    });
  }

  test('duplicate member overrides remain invalid within one alias', () async {
    final input = await source(cells);
    await expectLater(
      external(
        input,
        const ExternalLibrary([
          ExternalClass(
            'IntCell',
            members: [
              ExternalMember.field('value', config: NAPI(name: 'one')),
              ExternalMember.field('value', config: NAPI(name: 'two')),
            ],
          ),
        ]),
      ),
      throwsA(diagnostic('NAPI_DUPLICATE')),
    );
  });
}
