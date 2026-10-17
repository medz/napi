import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;

const _hierarchy = '''
import 'package:napi/napi.dart';

@NAPI(classPolicy: ClassPolicy.value)
class Data { final int value = 1; }

@NAPI()
class Base {
  Base();
  Base.named();
  int _value = 1;
  int get value => _value;
  set value(int next) { _value = next; }
  int run([int count = 1]) => count;
  int named({int count = 3}) => count;
  Base self() => this;
  String inherited() => 'base';
  static int staticOnly() => 1;
}

@NAPI()
class Feature {
  String feature() => 'feature';
}

class _Middle extends Base implements Feature {
  @override
  String feature() => 'middle';
}

@NAPI()
class Child extends _Middle {
  @override
  int get value => super.value + 1;
  @override
  int run([int count = 2]) => count;
  @override
  int named({int count = 4}) => count;
  @override
  Child self() => this;
}

@NAPI()
class GrandChild extends Child {}

@NAPI()
class SetterChild extends Base {
  @override
  set value(int next) { super.value = next + 1; }
}

@NAPI()
class ReadOnly {
  int get value => 1;
}

@NAPI()
class WriteChild extends ReadOnly {
  set value(int next) {}
}
''';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-hierarchy-');
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<BindingModule> read(String source) async {
    final file = File('${directory.path}/entry.dart')
      ..writeAsStringSync(source);
    return AnnotationFrontend(packagesPath: _packages).read(file.uri);
  }

  test('resolved ancestry bridges unselected classes and matches external selection', () async {
    final module = await read(_hierarchy);
    final external = await ExternalFrontend(
      const ExternalLibrary([
        ExternalClass('Base'),
        ExternalClass('Feature'),
        ExternalClass('Child'),
        ExternalClass('GrandChild'),
        ExternalClass('SetterChild'),
        ExternalClass('ReadOnly'),
        ExternalClass('WriteChild'),
      ]),
      packagesPath: _packages,
    ).read(module.source);
    final annotated = module.classes.singleWhere(
      (c) => c.exportName == 'Child',
    );
    final selected = external.classes.singleWhere(
      (c) => c.exportName == 'Child',
    );
    expect(selected.allSupertypes, annotated.allSupertypes);
    expect(selected.superclassChain, annotated.superclassChain);
    expect(
      annotated.allSupertypes.map((id) => id.name),
      containsAll(['Base', 'Feature', '_Middle']),
    );
    expect(annotated.superclassChain.map((id) => id.name), [
      '_Middle',
      'Base',
      'Object',
    ]);
    expect(
      annotated.members.map((m) => m.declaration.name),
      isNot(contains('feature')),
    );
  });

  test('both plans retain stable IDs, full membership and local complete descriptors', () async {
    final module = await read(_hierarchy);
    final wasm = lower(validate(module));
    final native = validateNative(module);
    final classes = {for (final c in wasm.classes) c.binding.exportName: c};
    final base = classes['Base']!;
    final child = classes['Child']!;
    final feature = classes['Feature']!;
    final grand = classes['GrandChild']!;
    expect(
      wasm.classes.map((c) => c.binding.exportName),
      isNot(contains('Data')),
    );
    for (final (id, binding) in wasm.classes.indexed) {
      expect(binding.shape.classId, id);
      expect(native.classes[id].shape.classId, id);
      expect(native.classes[id].shape.memberships, binding.shape.memberships);
      expect(native.classes[id].shape.superclassId, binding.shape.superclassId);
      for (final ancestor in binding.shape.memberships.where((a) => a != id)) {
        expect(
          wasm.referenceClassOrder.indexOf(id),
          lessThan(wasm.referenceClassOrder.indexOf(ancestor)),
        );
      }
    }
    expect(native.referenceClassOrder, wasm.referenceClassOrder);
    expect(child.shape.memberships, {
      child.shape.classId,
      base.shape.classId,
      feature.shape.classId,
    });
    expect(child.shape.superclassId, base.shape.classId);
    expect(grand.shape.memberships, containsAll(child.shape.memberships));
    expect(grand.shape.superclassId, child.shape.classId);
    expect(grand.shape.prototypeProperties, isEmpty);
    ReferencePropertyShape property(ClassPlan owner, String name) =>
        owner.shape.prototypeProperties.singleWhere((p) => p.name == name);
    final value = property(child, 'value');
    expect(value.getter!.classId, child.shape.classId);
    expect(value.setter!.classId, base.shape.classId);
    expect(property(child, 'feature').method!.classId, feature.shape.classId);
    expect(
      child.shape.prototypeProperties.map((p) => p.name),
      isNot(contains('inherited')),
    );
    final setter = property(classes['SetterChild']!, 'value');
    expect(setter.getter!.classId, base.shape.classId);
    expect(setter.setter!.classId, classes['SetterChild']!.shape.classId);
    final writable = property(classes['WriteChild']!, 'value');
    expect(writable.getter!.classId, classes['ReadOnly']!.shape.classId);
    expect(writable.setter!.classId, classes['WriteChild']!.shape.classId);
    for (final name in ['run', 'named']) {
      final ref = property(child, name).method!;
      final selected = wasm.classes[ref.classId].members[ref.memberIndex];
      expect(
        selected.parameters.single.defaultValue!.value,
        name == 'run' ? 2 : 4,
      );
      final inherited = base.members.singleWhere(
        (m) => !m.isStatic && m.exportName == name,
      );
      expect(
        inherited.parameters.single.defaultValue!.value,
        name == 'run' ? 1 : 3,
      );
    }
  });

  test('declarations inherit instances, preserve both accessor halves and exclude inherited statics', () async {
    final module = await read(_hierarchy);
    final declarations = {
      'wasm': emitDeclarations(lower(validate(module))),
      'native': emitNativeDeclarations(validateNative(module)),
    };
    for (final entry in declarations.entries) {
      expect(
        entry.value,
        contains('export interface Child extends Base, Feature {}'),
      );
      expect(entry.value, isNot(contains('declare class Child extends')));
      File('${directory.path}/${entry.key}.d.mts')
          .writeAsStringSync(entry.value);
      File('${directory.path}/${entry.key}.consumer.mts').writeAsStringSync('''
import {Base, Child, GrandChild, SetterChild, ReadOnly, WriteChild, Feature} from './${entry.key}.mjs';
const child = new Child();
const base: Base = child;
const feature: Feature = child;
const grand: Base = new GrandChild();
const own: Child = child.self();
child.value = 2;
const n: number = child.value + child.run(undefined) + child.named({count: undefined});
const text: string = child.feature() + child.inherited();
new SetterChild().value = 3;
const getter: number = new SetterChild().value;
new WriteChild().value = 4;
const readonly: ReadOnly = new WriteChild();
Base.staticOnly();
Base.named();
// @ts-expect-error Instance inheritance does not copy static methods.
Child.staticOnly();
// @ts-expect-error Named constructors are own static methods.
Child.named();
// @ts-expect-error The inherited setter retains its input type.
child.value = 'wrong';
// @ts-expect-error A getter-only base remains readonly.
new ReadOnly().value = 4;
''');
      for (final mode in ['NodeNext', 'Bundler']) {
        final result = await Process.run(Platform.environment['NODE'] ?? 'node', [
          '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc',
          '--strict',
          '--exactOptionalPropertyTypes',
          '--noEmit',
          '--target',
          'ES2022',
          '--moduleResolution',
          mode,
          '--module',
          mode == 'NodeNext' ? 'NodeNext' : 'ESNext',
          '${directory.path}/${entry.key}.consumer.mts',
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${entry.key}/$mode: ${result.stdout}${result.stderr}',
        );
      }
    }
  });

  for (final conflict in {
    'exclude': '''
@NAPI() class Base { int run() => 1; }
@NAPI() class Child extends Base {
  @NAPI(exclude: true) @override int run() => 2;
}
''',
    'rename': '''
@NAPI() class Base { int run() => 1; }
@NAPI() class Child extends Base {
  @NAPI(name: 'renamed') @override int run() => 2;
}
''',
    'implicit rename loss': '''
@NAPI() class Base { @NAPI(name: 'renamed') int run() => 1; }
@NAPI() class Child extends Base { @override int run() => 2; }
''',
    'different Dart members': '''
@NAPI() class Base { @NAPI(name: 'shared') int left() => 1; }
@NAPI() class Child extends Base { @NAPI(name: 'shared') int right() => 2; }
''',
    'excluded getter half': '''
@NAPI() class Base { int value = 1; }
@NAPI() class Child extends Base {
  @NAPI(exclude: true) @override int get value => 2;
}
''',
    'covariant input narrowing': '''
@NAPI() class Item {}
@NAPI() class Small extends Item {}
@NAPI() class Base { void accept(Item value) {} }
@NAPI() class Child extends Base {
  @override void accept(covariant Small value) {}
}
''',
    'getter void output is not a method result discard': '''
@NAPI() class Base { void get value {} }
@NAPI() class Child extends Base { @override int get value => 1; }
''',
  }.entries) {
    test('rejects inherited contract conflict: ${conflict.key}', () async {
      final module = await read(
        "import 'package:napi/napi.dart';\n${conflict.value}",
      );
      for (final check in [
        () => validate(module),
        () => validateNative(module),
      ]) {
        expect(
          check,
          throwsA(
            isA<BindingDiagnostic>().having(
              (e) => e.code,
              'code',
              'NAPI_INHERITANCE',
            ),
          ),
        );
      }
    });
  }

  test(
    'compatible optional widening and reference variance remain supported',
    () async {
      final module = await read('''
import 'package:napi/napi.dart';
@NAPI() class Item {}
@NAPI() class Small extends Item {}
@NAPI() class Base {
  Item accept(Small value) => value;
  int run(int value) => value;
  int named({required int value}) => value;
}
@NAPI() class Child extends Base {
  @override Small accept(Item value) => Small();
  @override int run([int value = 2, int extra = 3]) => value + extra;
  @override int named({int value = 2, int extra = 3}) => value + extra;
}
''');
      expect(validate(module).classes, hasLength(4));
      expect(validateNative(module).classes, hasLength(4));
    },
  );

  test('a derived method may return a value under a void base contract', () async {
    final module = await read('''
import 'package:napi/napi.dart';
@NAPI() class Base { void run() {} }
@NAPI() class Child extends Base { @override int run() => 42; }
''');
    final wasm = lower(validate(module));
    final native = validateNative(module);
    for (final (name, expected) in [('Base', null), ('Child', 'number')]) {
      expect(
        wasm.classes
            .singleWhere((c) => c.binding.exportName == name)
            .members
            .single
            .output
            ?.typescriptType,
        expected,
      );
      expect(
        native.classes
            .singleWhere((c) => c.binding.exportName == name)
            .members
            .single
            .output
            ?.typescriptType,
        expected,
      );
    }
    for (final entry in {
      'wasm': emitDeclarations(wasm),
      'native': emitNativeDeclarations(native),
    }.entries) {
      File('${directory.path}/${entry.key}.d.mts')
          .writeAsStringSync(entry.value);
      File('${directory.path}/${entry.key}.consumer.mts').writeAsStringSync('''
import {Base, Child} from './${entry.key}.mjs';
const child = new Child();
const base: Base = child;
const value: number = child.run();
const discarded: void = base.run();
const borrowed: void = Base.prototype.run.call(child);
// @ts-expect-error The base binding retains its void result contract.
const invalid: number = Base.prototype.run.call(child);
''');
      for (final mode in ['NodeNext', 'Bundler']) {
        final result = await Process.run(Platform.environment['NODE'] ?? 'node', [
          '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc',
          '--strict',
          '--noEmit',
          '--target',
          'ES2022',
          '--moduleResolution',
          mode,
          '--module',
          mode == 'NodeNext' ? 'NodeNext' : 'ESNext',
          '${directory.path}/${entry.key}.consumer.mts',
        ]);
        expect(
          result.exitCode,
          0,
          reason: '${entry.key}/$mode: ${result.stdout}${result.stderr}',
        );
      }
    }
  });

  test('a common selected child precedes both unrelated ancestors', () async {
    final module = await read('''
import 'package:napi/napi.dart';
@NAPI() class Left {
  Left self() => this;
  int left() => 1;
}
@NAPI() class Right {
  Right self() => this;
  int right() => 2;
}
@NAPI() class Both extends Left implements Right {
  @override Both self() => this;
  @override int right() => 3;
}
''');
    final plan = lower(validate(module));
    final classes = {for (final c in plan.classes) c.binding.exportName: c};
    final both = classes['Both']!;
    final left = classes['Left']!;
    final right = classes['Right']!;
    expect(both.shape.memberships, {
      both.shape.classId,
      left.shape.classId,
      right.shape.classId,
    });
    expect(plan.referenceClassOrder.first, both.shape.classId);
    expect(both.shape.superclassId, left.shape.classId);
    final self = both.shape.prototypeProperties
        .singleWhere((p) => p.name == 'self')
        .method!;
    expect(self.classId, both.shape.classId);
    expect(
      emitDeclarations(plan),
      contains('export interface Both extends Left, Right {}'),
    );
  });

  test('handwritten IR derives ancestry without new frontend metadata', () {
    final uri = Uri.file('/fixture/hierarchy.dart');
    final source = SourceLocation(uri, 0, 1);
    final parent = DeclarationId(uri, 'Base', kind: DeclarationKind.classType);
    final child = DeclarationId(uri, 'Child', kind: DeclarationKind.classType);
    final shapes = validateReferenceClasses(
      BindingModule(
        source: uri,
        classes: [
          ClassBinding(
            declaration: child,
            exportName: 'Child',
            source: source,
            supertype: DeclaredType(parent, ValueSemantics.reference),
          ),
          ClassBinding(declaration: parent, exportName: 'Base', source: source),
        ],
      ),
    );
    expect(shapes[0].memberships, {0, 1});
    expect(shapes[0].superclassId, 1);
    expect(referenceClassOrder(shapes), [0, 1]);
  });

  test('interface copies choose a declaration compatible with every selected contract', () async {
    final module = await read('''
import 'package:napi/napi.dart';
@NAPI() class Item {}
@NAPI() class Small extends Item {}
@NAPI() class Wide { Item item() => Item(); }
@NAPI() class Narrow { Small item() => Small(); }
class _Implementation extends Wide implements Narrow {
  @override Small item() => Small();
}
@NAPI() class Selected extends _Implementation {}
''');
    final plan = lower(validate(module));
    final selected = plan.classes.singleWhere(
      (c) => c.binding.exportName == 'Selected',
    );
    final property = selected.shape.prototypeProperties.singleWhere(
      (p) => p.name == 'item',
    );
    expect(plan.classes[property.method!.classId].binding.exportName, 'Narrow');
    final declarations = emitDeclarations(plan);
    expect(
      declarations,
      contains(
        'export declare class Selected {\n  constructor();\n  item(): Small;\n}',
      ),
    );
    File('${directory.path}/module.d.mts').writeAsStringSync(declarations);
    File('${directory.path}/consumer.mts').writeAsStringSync('''
import {Selected, Wide, Narrow, Small} from './module.mjs';
const selected = new Selected();
const wide: Wide = selected;
const narrow: Narrow = selected;
const small: Small = selected.item();
''');
    for (final mode in ['NodeNext', 'Bundler']) {
      final result = await Process.run(Platform.environment['NODE'] ?? 'node', [
        '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc',
        '--strict',
        '--noEmit',
        '--target',
        'ES2022',
        '--moduleResolution',
        mode,
        '--module',
        mode == 'NodeNext' ? 'NodeNext' : 'ESNext',
        '${directory.path}/consumer.mts',
      ]);
      expect(
        result.exitCode,
        0,
        reason: '$mode: ${result.stdout}${result.stderr}',
      );
    }
  });
}
