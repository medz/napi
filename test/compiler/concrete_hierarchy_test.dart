import 'dart:io';

import 'package:napi/napi.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

const _hierarchy = '''
import 'package:napi/napi.dart';
class Base<T> {
  T value;
  Base(this.value);
  T echo(T value) => value;
  int count([int value = 7]) => value;
  Base<T> self() => this;
}
class Feature<T> { T feature(T value) => value; }
class Middle<U> extends Base<List<U>> implements Feature<List<U>> {
  Middle(super.value);
  @override List<U> feature(List<U> value) => value;
}
class Child<V> extends Middle<V> {
  Child(super.value);
  @override int count([int value = 9]) => value;
  @override Child<V> self() => this;
}
@NAPI() typedef IntBase = Base<List<int>>;
@NAPI() typedef TextBase = Base<List<String>>;
@NAPI() typedef IntFeature = Feature<List<int>>;
@NAPI() typedef TextFeature = Feature<List<String>>;
@NAPI() typedef IntChild = Child<int>;
@NAPI() typedef TextChild = Child<String>;
''';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  late File input;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'napi-concrete-hierarchy-',
    );
    addTearDown(() => directory.delete(recursive: true));
    input = File('${directory.path}/business.dart');
  });
  Future<BindingModule> read(String source, {bool native = false}) async {
    await input.writeAsString(source);
    return AnnotationFrontend(
      packagesPath: packages,
      native: native,
    ).read(input.uri);
  }

  Matcher diagnostic(String code) =>
      isA<BindingDiagnostic>().having((e) => e.code, 'code', code);

  for (final native in [false, true]) {
    test(
      'resolved nested ancestry keeps each selected specialization ($native)',
      () async {
        final module = await read(_hierarchy, native: native);
        final plan = lower(validate(module));
        final vm = validateNative(module);
        expect(plan.classes[4].shape.memberships, {0, 2, 4});
        expect(plan.classes[5].shape.memberships, {1, 3, 5});
        expect(plan.classes[4].shape.superclassId, 0);
        expect(plan.classes[5].shape.superclassId, 1);
        expect(vm.classes[4].shape.memberships, {0, 2, 4});
        expect(vm.classes[5].shape.memberships, {1, 3, 5});
        final ancestor = module.classes[4].allSupertypes.singleWhere(
          (t) => t.declaration.name == 'Base',
        );
        expect(
          (ancestor.typeArguments.single as DeclaredType).typeArguments.single,
          isA<SafeIntType>(),
        );
        final feature = module.classes[4].inheritedInstanceMembers.singleWhere(
          (m) => m.contract.name == 'feature',
        );
        expect(
          referenceClassMatches(module.classes[2], feature.contractType),
          isTrue,
        );
        expect(
          referenceClassMatches(module.classes[3], feature.contractType),
          isFalse,
        );
        expect(
          emitDeclarations(plan),
          contains('export interface IntChild extends IntBase, IntFeature {}'),
        );
        expect(
          emitDeclarations(plan),
          contains(
            'export interface TextChild extends TextBase, TextFeature {}',
          ),
        );
        for (final code in [emitDart(plan), emitNativeDart(vm)]) {
          expect(code, contains('target.IntChild('));
          expect(code, contains('target.TextChild('));
        }
      },
    );
  }

  test(
    'external overrides remain scoped to the exact ancestor alias',
    () async {
      await input.writeAsString(_hierarchy);
      final module = await ExternalFrontend(
        const ExternalLibrary([
          ExternalClass(
            'IntBase',
            members: [
              ExternalMember.field('value', config: NAPI(name: 'integer')),
            ],
          ),
          ExternalClass(
            'TextBase',
            members: [
              ExternalMember.field('value', config: NAPI(name: 'text')),
            ],
          ),
          ExternalClass('IntFeature'),
          ExternalClass('TextFeature'),
          ExternalClass('IntChild'),
          ExternalClass('TextChild'),
        ]),
        packagesPath: packages,
      ).read(input.uri);
      final plan = lower(validate(module));
      expect(plan.classes[4].shape.memberships, {0, 2, 4});
      expect(plan.classes[5].shape.memberships, {1, 3, 5});
      final declarations = emitDeclarations(plan);
      expect(declarations, contains('get integer(): Array<number>;'));
      expect(declarations, contains('get text(): Array<string>;'));
      expect(
        declarations,
        contains('export interface IntChild extends IntBase, IntFeature {}'),
      );
      expect(validateNative(module).classes[4].shape.memberships, {0, 2, 4});
    },
  );

  test(
    'an inherited covariant view does not grant a wider alias membership',
    () async {
      final module = await read('''
import 'package:napi/napi.dart';
class Base<T> { T value; Base(this.value); }
class Child<T> extends Base<T> { Child(super.value); }
@NAPI() typedef Integer = Base<int>;
@NAPI() typedef Nullable = Base<int?>;
@NAPI() typedef IntegerChild = Child<int>;
@NAPI() class PlainChild extends Base<int> { PlainChild(super.value); }
''');
      final plan = lower(validate(module));
      expect(plan.classes[2].shape.memberships, {0, 2});
      expect(plan.classes[3].shape.memberships, {0, 3});
      final tests = DartReferenceClassTests(
        plan.allClasses.where((c) => c.classPolicy != ClassPolicy.value),
      );
      final nullable = tests.declarations;
      expect(nullable, contains('!_napiClass2'));
      expect(nullable, contains('!_napiClass3'));
      expect(nullable, contains('!_napiClass0'));
      final code = emitDart(plan);
      expect(
        code,
        isNot(contains('export interface IntegerChild extends Nullable')),
      );
    },
  );

  test(
    'selected resources share one compatible inherited cleanup policy',
    () async {
      final module = await read('''
import 'package:napi/napi.dart';
class Owner<T> { T value; Owner(this.value); void close([int code = 7]) {} }
class Child<T> extends Owner<T> {
  Child(super.value);
  @override void close([int code = 7]) => super.close(code);
}
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') typedef IntOwner = Owner<int>;
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') typedef TextOwner = Owner<String>;
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') typedef IntChild = Child<int>;
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') typedef TextChild = Child<String>;
''');
      final shapes = validate(module).classes;
      expect(shapes[2].memberships, {0, 2});
      expect(shapes[3].memberships, {1, 3});
      final policies = resourcePolicies(shapes);
      expect(policies[2], policies[0]);
      expect(policies[3], policies[1]);
      expect(validateNative(module).classes, hasLength(4));
      final conflict = await read(
        input.readAsStringSync().replaceFirst(
          'void close([int code = 7]) =>',
          'void close([int code = 8]) =>',
        ),
      );
      expect(() => validate(conflict), throwsA(diagnostic('NAPI_RESOURCE')));
      expect(
        () => validateNative(conflict),
        throwsA(diagnostic('NAPI_RESOURCE')),
      );
    },
  );

  test('ordinary overrides inherit selected resource cleanup', () async {
    const source = """
import 'package:napi/napi.dart';
class Owner<T> { Owner(); void close([int code = 7]) {} }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') typedef IntOwner = Owner<int>;
@NAPI() class Child extends Owner<int> {
  @override void close([int code = 7]) {}
}
@NAPI() class GrandChild extends Child {
  @override Future<void> close([int code = 7]) async {}
}
""";
    final annotated = await read(source);
    final external = await ExternalFrontend(
      const ExternalLibrary([
        ExternalClass(
          'IntOwner',
          config: NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close'),
        ),
        ExternalClass('Child'),
        ExternalClass('GrandChild'),
      ]),
      packagesPath: packages,
    ).read(input.uri);
    for (final module in [annotated, external]) {
      for (final shapes in [
        validate(module).classes,
        validateNative(module).classes.map((c) => c.shape).toList(),
      ]) {
        expect(shapes.map((c) => c.cleanup?.isCleanup), everyElement(isTrue));
        expect(resourcePolicies(shapes), {0: 0, 1: 0, 2: 0});
      }
      expect(
        emitDeclarations(lower(validate(module))),
        contains('close(code?: number): globalThis.Promise<void>;'),
      );
    }
    for (final (replacement, code) in [
      ('void close([int code = 8]) {}', 'NAPI_RESOURCE'),
      ('int close([int code = 7]) => 1;', 'NAPI_RESOURCE'),
      (
        "@NAPI(name: 'release') void close([int code = 7]) {}",
        'NAPI_INHERITANCE',
      ),
      (
        '@NAPI(exclude: true) void close([int code = 7]) {}',
        'NAPI_INHERITANCE',
      ),
    ]) {
      final invalid = await read(
        source
            .split('@NAPI() class GrandChild')
            .first
            .replaceFirst(
              '@override void close([int code = 7]) {}',
              '@override $replacement',
            ),
      );
      expect(() => validate(invalid), throwsA(diagnostic(code)));
      expect(() => validateNative(invalid), throwsA(diagnostic(code)));
    }
  });

  test(
    'inherited cleanup cannot replace an unrelated ordinary contract',
    () async {
      final module = await read("""
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Owner { void close() {} }
@NAPI() class Ordinary { void close() {} }
@NAPI() class Child extends Owner implements Ordinary {
  @override void close() {}
}
""");
      expect(() => validate(module), throwsA(diagnostic('NAPI_INHERITANCE')));
      expect(
        () => validateNative(module),
        throwsA(diagnostic('NAPI_INHERITANCE')),
      );
    },
  );

  test('ordinary overrides retain conflicting cleanup diagnostics', () async {
    for (final selection in [
      '@NAPI()',
      "@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'shutdown')",
    ]) {
      final module = await read("""
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Owner { void close() {} }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'shutdown')
class Other { void shutdown() {} }
$selection class Child extends Owner implements Other {
  @override void close() {}
  @override void shutdown() {}
}
""");
      for (final check in [validate, validateNative]) {
        expect(() => check(module), throwsA(isA<BindingDiagnostic>()));
      }
    }
  });

  test('nested open opaque hierarchies remain unsupported', () async {
    final module = await read('''
import 'package:napi/napi.dart';
@NAPI() class Base<T> { Base(); }
@NAPI() class Child<T> extends Base<List<T>> { Child(); }
''');
    expect(() => validate(module), throwsA(diagnostic('NAPI_GENERIC')));
    expect(() => validateNative(module), throwsA(diagnostic('NAPI_GENERIC')));
  });
  test(
    'a wider child alias cannot suppress the narrower valid ancestor',
    () async {
      final module = await read('''
import 'package:napi/napi.dart';
class Base<T> { T value; Base(this.value); }
class Child<T> extends Base<T> { Child(super.value); }
@NAPI() typedef Integer = Base<int>;
@NAPI() typedef Nullable = Base<int?>;
@NAPI() typedef IntegerChild = Child<int>;
@NAPI() typedef NullableChild = Child<int?>;
''');
      final shapes = validate(module).classes;
      expect(shapes[2].memberships, {0, 2});
      expect(shapes[3].memberships, {1, 3});
      final check = DartReferenceClassTests(module.classes).declarations;
      expect(check, contains('object is target.NullableChild && !_napiClass2'));
      expect(validateNative(module).classes[2].shape.memberships, {0, 2});
    },
  );
  test(
    'effective predicates retain complete deep composite memberships',
    () async {
      final module = await read('''
import 'package:napi/napi.dart';
class Base<T> { T value; Base(this.value); }
class Middle<T> extends Base<T> { Middle(super.value); }
@NAPI() typedef IntBase = Base<int>;
@NAPI() typedef NullableBase = Base<int?>;
@NAPI() typedef NullableMiddle = Middle<int?>;
@NAPI() class Child extends Middle<int> { Child(super.value); }
@NAPI() class Extra { int extra() => 9; }
class Mixed extends Child implements Extra {
  Mixed(super.value);
  @override int extra() => 9;
}
class Hidden extends Middle<int> { Hidden(super.value); }
class MixedHidden extends Hidden implements Extra {
  MixedHidden(super.value);
  @override int extra() => 9;
}
''');
      final shapes = validate(module).classes;
      expect(shapes[3].memberships, {0, 3});
      final tests = DartReferenceClassTests(module.classes);
      final check = File('${directory.path}/check.dart');
      await check.writeAsString('''
import '${input.uri}' as target;
List<int> views(Object object) {
${tests.declarations}
  return [${[for (final (i, binding) in module.classes.indexed) 'if (${tests.test(binding)}) $i'].join(', ')}];
}
void main() {
  for (final (object, expected) in <(Object, String)>[
    (target.IntBase(1), '0'),
    (target.NullableBase(null), '1'),
    (target.NullableMiddle(null), '1,2'),
    (target.Child(1), '0,3'),
    (target.Mixed(1), '0,3,4'),
    (target.Hidden(1), '1,2'),
    (target.MixedHidden(1), '1,2,4'),
  ]) {
    final actual = views(object).join(',');
    if (actual != expected) throw StateError('Expected \$expected, got \$actual');
  }
}
''');
      final result = await Process.run(Platform.resolvedExecutable, [
        '--packages=$packages',
        check.path,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(validateNative(module).classes[3].shape.memberships, {0, 3});
    },
  );
  test(
    'deep diamond checks grow with edges instead of expanded paths',
    () async {
      final lengths = <int>[];
      for (final depth in [4, 8]) {
        final declarations = StringBuffer("import 'package:napi/napi.dart';\n");
        declarations.writeln('class A0<T> {} class B0<T> {}');
        for (var i = 1; i <= depth; i++) {
          final parent = i - 1;
          for (final name in ['A', 'B']) {
            declarations.writeln(
              'class $name$i<T> extends A$parent<T> implements B$parent<T> {}',
            );
          }
        }
        for (var i = 0; i <= depth; i++) {
          final argument = i.isEven ? 'int' : 'String';
          for (final name in ['A', 'B']) {
            declarations.writeln(
              '@NAPI() typedef Selected$name$i = $name$i<$argument>;',
            );
          }
        }
        declarations.writeln(
          '@NAPI() class Leaf extends A$depth<int> implements B$depth<int> {}',
        );
        final module = await read(declarations.toString());
        final shapes = validate(module).classes;
        final tests = DartReferenceClassTests(module.classes);
        lengths.add(tests.declarations.length);
        expect(
          RegExp(r'final _napiClass').allMatches(tests.declarations),
          hasLength(module.classes.length),
        );
        final check = File('${directory.path}/diamond.dart');
        final expected = shapes.last.memberships.toList()..sort();
        await check.writeAsString('''
import '${input.uri}' as target;
void main() {
  final object = target.Leaf();
${tests.declarations}
  final actual = [${[for (final (i, binding) in module.classes.indexed) 'if (${tests.test(binding)}) $i'].join(', ')}].join(',');
  if (actual != '${expected.join(',')}') throw StateError('Wrong diamond views: \$actual');
}
''');
        final result = await Process.run(Platform.resolvedExecutable, [
          '--packages=$packages',
          check.path,
        ]);
        expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      }
      // Doubling this diamond has quadratic edges but exponentially many paths.
      expect(lengths[1], lessThan(lengths[0] * 5));
    },
  );
}
