import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;
const _items = '''
import 'package:napi/napi.dart';
@NAPI() class Item {}
@NAPI() class Small extends Item {}
''';
const _selection = ExternalLibrary([
  ExternalClass('Item'),
  ExternalClass('Small'),
  ExternalClass('Base'),
  ExternalClass('Child'),
]);

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'napi-inherited-contract-',
    );
    addTearDown(() => directory.delete(recursive: true));
  });
  File write(String source, [String name = 'entry.dart']) =>
      File('${directory.path}/$name')..writeAsStringSync(source);
  Future<BindingModule> read(File file, {bool external = false}) => external
      ? ExternalFrontend(_selection, packagesPath: _packages).read(file.uri)
      : AnnotationFrontend(packagesPath: _packages).read(file.uri);
  void rejectBoth(BindingModule module, {SourceLocation? source}) {
    for (final check in [
      () => validate(module),
      () => validateNative(module),
    ]) {
      expect(
        check,
        throwsA(
          isA<BindingDiagnostic>()
              .having((e) => e.code, 'code', 'NAPI_INHERITANCE')
              .having(
                (e) => source == null || e.source == source,
                'implementation source',
                isTrue,
              ),
        ),
      );
    }
  }

  for (final entry in {
    'method': '''
@NAPI() class Base { void accept(Item value) {} }
class _Middle extends Base {
  @override void accept(covariant Small value) {}
}
@NAPI() class Child extends _Middle {}
''',
    'generic substitution': '''
@NAPI() class Base { void accept(Item value) {} }
class _Middle<T extends Item> extends Base {
  @override void accept(covariant T value) {}
}
@NAPI() class Child extends _Middle<Small> {}
''',
    'mixin': '''
@NAPI() class Base { void accept(Item value) {} }
mixin _Middle on Base {
  @override void accept(covariant Small value) {}
}
@NAPI() class Child extends Base with _Middle {}
''',
    'setter': '''
@NAPI() class Base { set value(Item next) {} }
class _Middle extends Base {
  @override set value(covariant Small next) {}
}
@NAPI() class Child extends _Middle {}
''',
    'field setter': '''
@NAPI() class Base { Item value = Item(); }
class _Middle extends Base {
  @override covariant Small value = Small();
}
@NAPI() class Child extends _Middle {}
''',
  }.entries) {
    test(
      'rejects unselected ${entry.key} parameter narrowing in both frontends',
      () async {
        final file = write('$_items\n${entry.value}');
        for (final external in [false, true]) {
          final module = await read(file, external: external);
          final child = module.classes.singleWhere(
            (c) => c.exportName == 'Child',
          );
          final inherited = child.inheritedInstanceMembers.singleWhere(
            (m) => !m.isCompatible,
          );
          expect(inherited.member.declaration.owner!.name, '_Middle');
          expect(inherited.contract.owner!.name, 'Base');
          expect(
            (inherited.member.parameters.single.type as DeclaredType)
                .declaration
                .name,
            'Small',
          );
          expect(
            module.classes.map((c) => c.declaration.name),
            isNot(contains('_Middle')),
          );
          rejectBoth(module, source: inherited.member.source);
        }
      },
    );
  }

  test(
    'safe inherited signatures keep selected declaration defaults and exports',
    () async {
      final file = write('''
$_items
class _PrivateItem extends Item {}
@NAPI() class Base {
  void accept(Item value) {}
  Item result() => Item();
  Item get value => Item();
  set value(Item next) {}
  int defaults([int value = 1]) => value;
  void discard() {}
  @NAPI(name: 'renamed') int original() => 1;
}
class _Middle extends Base {
  @override void accept(Object value) {}
  @override _PrivateItem result() => _PrivateItem();
  @override _PrivateItem get value => _PrivateItem();
  @override set value(Object next) {}
  @override int defaults([int value = 2]) => value;
  @override int discard() => 42;
  @override int original() => 2;
}
@NAPI() class Child extends _Middle {}
''');
      for (final external in [false, true]) {
        final module = await read(file, external: external);
        final child = module.classes.singleWhere(
          (c) => c.exportName == 'Child',
        );
        expect(child.inheritedInstanceMembers, hasLength(7));
        expect(
          child.inheritedInstanceMembers.every((m) => m.isCompatible),
          isTrue,
        );
        final plan = lower(validate(module));
        expect(validateNative(module).classes, hasLength(4));
        final parent = plan.classes.singleWhere(
          (c) => c.binding.exportName == 'Base',
        );
        expect(
          (parent.members
                      .singleWhere((m) => m.exportName == 'defaults')
                      .parameters
                      .single
                      .defaultValue
                  as ScalarDefault)
              .value,
          1,
        );
        expect(
          parent.members.singleWhere((m) => m.exportName == 'discard').output,
          isNull,
        );
        expect(
          plan.classes
              .singleWhere((c) => c.binding.exportName == 'Child')
              .shape
              .prototypeProperties,
          isEmpty,
        );
        expect(
          parent.members.map((m) => m.exportName),
          contains(external ? 'original' : 'renamed'),
        );
      }
    },
  );

  test(
    'an inherited getter retains the existing void compatibility rule',
    () async {
      final module = await read(
        write('''
$_items
@NAPI() class Base { void get value {} }
class _Middle extends Base { @override int get value => 1; }
@NAPI() class Child extends _Middle {}
'''),
      );
      rejectBoth(module);
    },
  );

  test(
    'Dart rejects an incompatible inherited nonvoid result before lowering',
    () async {
      final file = write('''
$_items
@NAPI() class Base { int result() => 1; }
class _Middle extends Base { @override dynamic result() => 'wrong'; }
@NAPI() class Child extends _Middle {}
''');
      for (final external in [false, true]) {
        await expectLater(
          read(file, external: external),
          throwsA(
            isA<BindingDiagnostic>().having((e) => e.code, 'code', 'NAPI_DART'),
          ),
        );
      }
    },
  );

  for (final config in ["exclude: true", "name: 'different'"]) {
    test(
      'known hidden annotated override cannot change selection: $config',
      () async {
        write('''
$_items
@NAPI() class Base { int run() => 1; }
@NAPI() class Middle extends Base {
  @NAPI($config) @override int run() => 2;
}
@NAPI() class Child extends Middle {}
''', 'origin.dart');
        final file = write(
          "export 'origin.dart' show Item, Small, Base, Child;",
        );
        rejectBoth(await read(file));
        // External configuration remains the sole authority in external mode.
        final external = await read(file, external: true);
        expect(validate(external).classes, hasLength(4));
        expect(validateNative(external).classes, hasLength(4));
      },
    );
  }
}
