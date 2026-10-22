import 'dart:io';

import 'package:napi/napi.dart';
import 'package:napi/src/build/build.dart';
import 'package:napi/src/compiler/analysis/reference_views.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-opaque-hierarchy-');
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<BindingModule> read(String source, {bool native = false}) async {
    final file = File('${directory.path}/entry.dart');
    await file.writeAsString("import 'package:napi/napi.dart';\n$source");
    return AnnotationFrontend(
      packagesPath: packages,
      native: native,
    ).read(file.uri);
  }

  Matcher diagnostic(String code) =>
      isA<BindingDiagnostic>().having((e) => e.code, 'code', code);

  for (final native in [false, true]) {
    test(
      'bijections project inherited contracts, not runtime owners ($native)',
      () async {
        final source = File('test/fixtures/opaque_hierarchy.dart').absolute;
        final module = await AnnotationFrontend(
          packagesPath: packages,
          native: native,
        ).read(source.uri);
        final external = await ExternalFrontend(
          ExternalLibrary([
            for (final c in module.classes)
              ExternalClass(
                c.exportName,
                members: c.exportName == 'OpaqueThen'
                    ? const [
                        ExternalMember.field(
                          'hook',
                          config: NAPI(name: 'then'),
                        ),
                      ]
                    : const [],
              ),
            for (final f in module.functions) ExternalFunction(f.exportName),
          ]),
          packagesPath: packages,
          native: native,
        ).read(source.uri);
        final plan = lower(validate(module));
        final vm = validateNative(module);
        final shapes = plan.classes.map((c) => c.shape).toList();
        final byName = {for (final s in shapes) s.binding.exportName: s};
        final base = byName['OpaqueBase']!;
        final child = byName['OpaqueChild']!;
        final pair = byName['OpaquePair']!;
        final slot = byName['OpaqueSlot']!;
        final pairChild = byName['OpaquePairChild']!;
        final leaf = byName['OpaqueLeaf']!;
        expect(child.ancestorArguments, {
          base.classId: [0],
        });
        expect(pairChild.ancestorArguments, {
          pair.classId: [1, 0],
          slot.classId: [1, 0],
        });
        expect(leaf.ancestorArguments, {
          pairChild.classId: [1, 0],
          pair.classId: [0, 1],
          slot.classId: [0, 1],
        });
        final read = base.members.singleWhere((m) => m.exportName == 'read');
        final projected = referenceMemberInScope(read, base, child)!;
        expect(identical(projected.binding, read.binding), isTrue);
        expect(
          (projected.result as TypeParameterType).declaration,
          child.binding.typeParameters.single.declaration,
        );
        expect(referenceMemberInScope(read, base, pair), isNull);
        final contracts = referenceViewContracts(shapes);
        ReferenceMemberRef ref(ReferenceClassShape c, String name) => (
          classId: c.classId,
          memberIndex: c.members.indexWhere((m) => m.exportName == name),
        );
        expect(
          contracts.ids[ref(base, 'read')],
          contracts.ids[ref(child, 'read')],
        );
        final types = emitDeclarations(plan);
        expect(
          types,
          contains(r'type $napiInvariant<in out T> = { readonly value: T };'),
        );
        expect(types, contains(r': $napiInvariant<[X, Y]>;'));
        expect(types, emitNativeDeclarations(vm));
        expect(types, emitDeclarations(lower(validate(external))));
        expect(types, emitNativeDeclarations(validateNative(external)));
        expect(
          types,
          contains(
            'export interface OpaqueChild<in out U = unknown> extends OpaqueBase<U> {}',
          ),
        );
        expect(
          types,
          contains('extends OpaquePair<Y, X>, OpaqueSlot<Y, X> {}'),
        );
        expect(types, contains('get slot(): X;'));
        expect(types, contains('set slot(value: X);'));
        expect(types, contains('extends OpaquePairChild<Q, P> {}'));
        expect(
          types,
          contains(
            'writeArray(values: globalThis.Array<A>, value: A): globalThis.Array<A>;',
          ),
        );
        expect(
          types,
          contains(
            'writeMap(values: globalThis.Map<Y, X>, key: Y, value: X): globalThis.Map<Y, X>;',
          ),
        );
        for (final code in [emitDart(plan), emitNativeDart(vm)]) {
          expect(code, contains('target.OpaqueBase<_NapiHostValue>'));
          expect(
            code,
            contains('target.OpaquePair<_NapiHostValue, _NapiHostValue>'),
          );
        }
      },
    );
  }

  for (final native in [false, true]) {
    test(
      'generic resource ancestors share a mapped cleanup policy ($native)',
      () async {
        final module = await read('''
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Base<A, B> {
  Base(this.first, this.second);
  A first;
  B second;
  Base<A, B> self() => this;
  void close() {}
}
class Middle<C, D> extends Base<D, C> { Middle(super.first, super.second); }
@NAPI()
class Child<X, Y> extends Middle<Y, X> {
  Child(super.first, super.second);
  @override void close() => super.close();
}
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Leaf<P, Q> extends Child<Q, P> {
  Leaf(super.first, super.second);
  @override void close() => super.close();
}
''', native: native);
        final plan = lower(validate(module));
        final vm = validateNative(module);
        final shapes = plan.classes.map((c) => c.shape).toList();
        final base = shapes[0], child = shapes[1], leaf = shapes[2];
        expect(child.ancestorArguments[base.classId], [0, 1]);
        expect(leaf.ancestorArguments[base.classId], [1, 0]);
        expect(leaf.ancestorArguments[child.classId], [1, 0]);
        final policies = resourcePolicies(shapes);
        expect(policies.keys.toSet(), {
          base.classId,
          child.classId,
          leaf.classId,
        });
        expect(policies.values.toSet(), hasLength(1));
        expect(emitDeclarations(plan), emitNativeDeclarations(vm));
        expect(emitDeclarations(plan), contains('extends Base<X, Y>'));
        expect(emitDeclarations(plan), contains('extends Child<Q, P>'));
        expect(
          emitDeclarations(plan),
          contains('close(): globalThis.Promise<void>'),
        );
      },
    );
  }

  test('generic resource overrides retain cleanup defaults', () async {
    final module = await read('''
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Base<T> { Base(); void close([int code = 7]) {} }
@NAPI()
class Child<U> extends Base<U> {
  Child();
  @override void close([int code = 8]) {}
}
''');
    for (final check in [validate, validateNative]) {
      expect(() => check(module), throwsA(diagnostic('NAPI_RESOURCE')));
    }
  });

  final rejected = {
    'fixed':
        '@NAPI() class Base<T> {} @NAPI() class Child extends Base<String> {}',
    'nested': '@NAPI() class Base<T> {} @NAPI() class Child<U> extends Base<List<U>> {}',
    'nullable':
        '@NAPI() class Base<T> {} @NAPI() class Child<U> extends Base<U?> {}',
    'repeated': '@NAPI() class Base<A,B> {} @NAPI() class Child<U,V> extends Base<U,U> {}',
    'dropped':
        '@NAPI() class Base<T> {} @NAPI() class Child<U,V> extends Base<U> {}',
    'resource via intermediate': "@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') class Base { void close() {} } class Middle<T> extends Base {} @NAPI() class Child<U> extends Middle<U> {}",
    'resource interface': "@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close') class Base { void close() {} } @NAPI() class Child<U> implements Base { void close() {} }",
  };
  for (final entry in rejected.entries) {
    test('rejects ${entry.key} before lowering', () async {
      final module = await read(entry.value);
      for (final check in [validate, validateNative]) {
        expect(() => check(module), throwsA(diagnostic('NAPI_GENERIC')));
      }
    });
  }

  test(
    'logical generic reference arguments stay invariant after projection',
    () async {
      final module = await read("""
@NAPI() class Base<T> { Base<T> self() => this; }
@NAPI() class Child<U> extends Base<U?> {
  @override Child<U> self() => this;
}
""");
      // Erased carrier equality must never admit the nullable ancestor edge.
      expect(() => validate(module), throwsA(diagnostic('NAPI_GENERIC')));
    },
  );

  test('reference result comparison follows the exact mapped tuple', () async {
    final module = await read("""
@NAPI() class Base<A, B> { Base<A, B> self() => this; }
@NAPI() class Child<X, Y> extends Base<Y, X> {
  @override Child<X, Y> self() => this;
  Base<X, Y> unswapped() => throw StateError('not called');
}
""");
    final shapes = validate(module).classes;
    final base = shapes.first, child = shapes.last;
    final contract = referenceMemberInScope(base.members.single, base, child)!;
    expect(
      referenceMemberAccepts(
        child.members.singleWhere((m) => m.exportName == 'self'),
        contract,
        shapes,
      ),
      isTrue,
    );
    expect(
      referenceMemberAccepts(
        child.members.singleWhere((m) => m.exportName == 'unswapped'),
        contract,
        shapes,
      ),
      isFalse,
    );
  });

  test('empty selected interfaces retain renamed and permuted slots', () async {
    final module = await read("""
@NAPI() class Parent<A, B> {}
@NAPI() class Child<X, Y> implements Parent<Y, X> {}
""");
    final shapes = validate(module).classes;
    expect(shapes.last.ancestorArguments, {
      0: [1, 0],
    });
    expect(
      emitDeclarations(lower(validate(module))),
      contains('extends Parent<Y, X> {}'),
    );
  });

  test(
    'malformed and conflicting handwritten mappings fail before lowering',
    () async {
      final module = await read("""
@NAPI() class Parent<A, B> {}
@NAPI() class Child<X, Y> implements Parent<Y, X> {}
""");
      final parent = module.classes.first;
      final child = module.classes.last;
      final x = TypeParameterType(child.typeParameters[0].declaration);
      final y = TypeParameterType(child.typeParameters[1].declaration);
      DeclaredType ancestor(List<BindingType> args) => DeclaredType(
        parent.declaration,
        ValueSemantics.reference,
        typeArguments: args,
      );
      for (final ancestors in [
        [
          ancestor([x]),
        ],
        [
          ancestor([x, x]),
        ],
        [
          ancestor([x, y]),
          ancestor([y, x]),
        ],
        [
          ancestor([
            TypeParameterType(parent.typeParameters.first.declaration),
            y,
          ]),
        ],
      ]) {
        final malformed = BindingModule(
          source: module.source,
          classes: [
            parent,
            ClassBinding(
              declaration: child.declaration,
              exportName: child.exportName,
              source: child.source,
              members: child.members,
              typeParameters: child.typeParameters,
              allSupertypes: ancestors,
            ),
          ],
        );
        for (final check in [validate, validateNative]) {
          expect(() => check(malformed), throwsA(diagnostic('NAPI_GENERIC')));
        }
      }
    },
  );

  test(
    'nested opaque references preserve inherited logical arguments',
    () async {
      final module = await read("""
@NAPI() class Base<T> { Base(); }
@NAPI() class Child<U> extends Base<U> { Child(); }
@NAPI() (Base<T>, int) run<T>() => (Child<T>(), 1);
""");
      final plan = lower(validate(module));
      final native = validateNative(module);
      final types = emitDeclarations(plan);
      expect(types, emitNativeDeclarations(native));
      expect(
        types,
        contains(r'run<T = unknown>(): { $1: Base<T>; $2: number }'),
      );
      expect(types, contains('extends Base<U> {}'));
      expect(emitDart(plan), contains('target.run<_NapiHostValue>()'));
      expect(emitNativeDart(native), contains('target.run<_NapiHostValue>()'));
    },
  );

  test('ancestor names are checked in the actual child scope', () async {
    for (final name in ['Base', 'Renamed']) {
      await File('${directory.path}/base.dart').writeAsString("""
import 'package:napi/napi.dart';
@NAPI(name: '$name') class Base<T> { Base(); }
@NAPI() class Other { Other(); }
""");
      final entry = File('${directory.path}/entry.dart');
      await entry.writeAsString("""
import 'package:napi/napi.dart';
import 'base.dart' as p;
export 'base.dart';
@NAPI() class Child<$name> extends p.Base<$name> { Child(); }
""");
      for (final native in [false, true]) {
        for (final external in [false, true]) {
          final frontend = external
              ? ExternalFrontend(
                  ExternalLibrary([
                    ExternalClass('Base', config: NAPI(name: name)),
                    const ExternalClass('Other'),
                    const ExternalClass('Child'),
                  ]),
                  packagesPath: packages,
                  native: native,
                )
              : AnnotationFrontend(packagesPath: packages, native: native);
          final module = await frontend.read(entry.uri);
          for (final check in [validate, validateNative]) {
            expect(() => check(module), throwsA(diagnostic('NAPI_NAME')));
          }
        }
      }
    }
  });

  test(
    'projected member references cannot shadow their emitted class names',
    () async {
      await File('${directory.path}/base.dart').writeAsString("""
import 'package:napi/napi.dart';
@NAPI() class Box<T> { Box(); }
@NAPI() class View<T> { Box<T> make() => Box<T>(); }
class Middle<T> implements View<T> { Box<T> make() => Box<T>(); }
""");
      final entry = File('${directory.path}/entry.dart');
      await entry.writeAsString("""
import 'package:napi/napi.dart';
import 'base.dart' as p;
export 'base.dart';
@NAPI() class Child<Box> extends p.Middle<Box> { Child(); }
""");
      for (final external in [false, true]) {
        final frontend = external
            ? ExternalFrontend(
                const ExternalLibrary([
                  ExternalClass('Box'),
                  ExternalClass('View'),
                  ExternalClass('Child'),
                ]),
                packagesPath: packages,
              )
            : AnnotationFrontend(packagesPath: packages);
        final module = await frontend.read(entry.uri);
        expect(
          () => emitDeclarations(lower(validate(module))),
          throwsA(diagnostic('NAPI_NAME')),
        );
        expect(
          () => emitNativeDeclarations(validateNative(module)),
          throwsA(diagnostic('NAPI_NAME')),
        );
        for (final target in BuildTarget.values) {
          final output = Directory('${directory.path}/not-created/output');
          await expectLater(
            buildModule(
              bindings: module,
              output: output,
              target: target,
              sdk: DartSdkAdapter(executable: 'does-not-exist'),
              nativeRuntime: target == BuildTarget.native
                  ? Directory('${directory.path}/missing-runtime')
                  : null,
            ),
            throwsA(diagnostic('NAPI_NAME')),
          );
          expect(await output.parent.exists(), isFalse);
        }
      }
    },
  );

  test('associated read views check the setter owner scope', () async {
    final module = await read("""
@NAPI() class Base<T> { Base(); }
@NAPI() class Derived<T> extends Base<T> { Derived(); }
@NAPI() class Write<Derived> { set value(Base<Derived> value) {} }
@NAPI() class Read<U> extends Write<U> {
  Derived<U> get value => Derived<U>();
}
""");
    expect(
      () => emitDeclarations(lower(validate(module))),
      throwsA(diagnostic('NAPI_NAME')),
    );
    expect(
      () => emitNativeDeclarations(validateNative(module)),
      throwsA(diagnostic('NAPI_NAME')),
    );
  });

  test('unrelated and lexically inherited class names remain legal parameters', () async {
    final module = await read("""
@NAPI() class Box<T> { Box(); }
@NAPI() class View<T> { Box<T> make() => Box<T>(); }
@NAPI() class Parent<T> extends View<T> { Parent(); }
@NAPI() class Child<Box> extends Parent<Box> { Child(); }
@NAPI() class Leaf<View> extends Parent<View> { Leaf(); }
""");
    final types = emitDeclarations(lower(validate(module)));
    expect(types, emitNativeDeclarations(validateNative(module)));
    expect(types, contains('Child<in out Box = unknown> extends Parent<Box>'));
    expect(types, contains('Leaf<in out View = unknown> extends Parent<View>'));
    final file = File('${directory.path}/valid.d.mts');
    await file.writeAsString(types);
    final tsc =
        Platform.environment['NAPI_TSC'] ??
        '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
    final result = await Process.run(Platform.environment['NODE'] ?? 'node', [
      tsc,
      '--ignoreConfig',
      '--strict',
      '--noEmit',
      '--target',
      'ES2022',
      '--module',
      'NodeNext',
      file.path,
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });

  test('unrelated generic contracts remain distinct', () async {
    final module = await read("""
@NAPI() class Left<T> { T read(T value) => value; }
@NAPI() class Right<U> { U read(U value) => value; }
""");
    final shapes = validate(module).classes;
    final contracts = referenceViewContracts(shapes);
    expect(contracts.ids.values.toSet(), hasLength(2));
    expect(contracts.accepts.every((s) => s.isEmpty), isTrue);
  });
}
