import 'dart:io';

import 'package:napi/napi.dart' show NAPI;
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/js/arguments.dart';
import 'package:napi/src/compiler/emit/js/boundary.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/linker/dart_module_linker.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

const _source = '''
import 'package:napi/napi.dart';
@NAPI() int add(int a, int b) => a + b;
int _constructions = 0;
DartCounter? _held;
WeakReference<DartCounter>? _last;
@NAPI() int constructions() => _constructions;
@NAPI() int hold(DartCounter? value) { _held = value; return 0; }
@NAPI() DartCounter? held() => _held;
@NAPI() int alive() => _last?.target == null ? 0 : 1;
@NAPI() DartCounter identity(DartCounter value) => value;
@NAPI() DartCounter? nullable(DartCounter? value) => value;
@NAPI() DartCounter? optional([DartCounter? value]) => value;
@NAPI() DartCounter? named({DartCounter? value}) => value;
@NAPI(name: 'Counter') class DartCounter {
  DartCounter([this.value = 0]) { _constructions++; _last = WeakReference(this); }
  @NAPI(name: 'from') DartCounter.named(this.value);
  @NAPI(name: 'cached') factory DartCounter.shared() => _cached;
  int value;
  DartCounter? peer;
  DartCounter self() => this;
  int sum(DartCounter other) => value + other.value;
}
final _cached = DartCounter(99);
@NAPI() class Cached {
  factory Cached() => _shared;
  Cached._();
  Cached self() => this;
}
final _shared = Cached._();
@NAPI() abstract class AbstractFactory {
  factory AbstractFactory() => _Concrete();
  int get value;
}
class _Concrete implements AbstractFactory { int get value => 23; }
@NAPI() class NamedOnly {
  NamedOnly.make(this.value);
  int value;
}
@NAPI() class Base { Base(); }
@NAPI() class Child extends Base {
  Child();
  Base asBase() => this;
}
''';

void main() {
  late Directory directory;
  final packages = File('.dart_tool/package_config.json').absolute.path;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-wasm-reference-');
    addTearDown(() => directory.delete(recursive: true));
  });
  Future<ModulePlan> plan(String source) async {
    final input = File('${directory.path}/business.dart');
    await input.writeAsString(source);
    return lower(
      validate(
        await AnnotationFrontend(packagesPath: packages).read(input.uri),
      ),
    );
  }

  test(
    'direct reference plan preserves class identity and constructor selection',
    () async {
      final module = await plan(_source);
      expect(
        module.functions.first.representation,
        ExportRepresentation.nativeFunction,
      );
      expect(
        module.functions
            .where(
              (f) => !const {
                'add',
                'constructions',
                'alive',
              }.contains(f.binding.exportName),
            )
            .every(
              (f) => f.representation == ExportRepresentation.callableGlobal,
            ),
        isTrue,
      );
      final conversion =
          module.functions
                  .singleWhere((f) => f.binding.exportName == 'identity')
                  .inputs
                  .single
              as ReferenceConversion;
      expect(conversion.classId, 0);
      expect(
        identical(conversion.classBinding, module.classes.first.binding),
        isTrue,
      );
      expect(conversion.dartType, 'target.DartCounter');
      expect(conversion.typescriptType, 'Counter');
      expect(
        module.classes
            .singleWhere((c) => c.binding.exportName == 'NamedOnly')
            .constructor,
        isNull,
      );
      final named = module.classes.first.members
          .where((m) => m.kind == MemberCallKind.constructor)
          .toList();
      expect(named.map((m) => m.exportName), ['from', 'cached']);
      expect(named.every((m) => m.isStatic), isTrue);
      final types = emitDeclarations(module);
      expect(types, contains('static from(value: number): Counter;'));
      expect(types, contains('static cached(): Counter;'));
      expect(types, contains('private constructor();'));
      expect(types, contains('value?: Counter | null'));
      final boundary = emitBoundary(module);
      expect(boundary, isNot(contains("from './calls.mjs'")));
      expect(boundary, isNot(contains('structure')));
    },
  );

  test(
    'excluded unnamed constructors preserve named and renamed creation',
    () async {
      final module = await plan('''import 'package:napi/napi.dart';
@NAPI(name: 'PublicBox') class Box {
  @NAPI(exclude: true) Box();
  @NAPI(name: 'constructor') Box.named();
  @NAPI(name: 'name') factory Box.shared() => Box.named();
}
''');
      final binding = module.classes.single;
      expect(binding.constructor, isNull);
      expect(binding.members.map((m) => m.exportName), ['constructor', 'name']);
      expect(
        binding.members.every(
          (m) => m.kind == MemberCallKind.constructor && m.isStatic,
        ),
        isTrue,
      );
      expect(emitDart(module), contains('target.Box.named()'));
      expect(emitDart(module), contains('target.Box.shared()'));
      final types = emitDeclarations(module);
      expect(types, contains('private constructor();'));
      expect(types, contains('static ["constructor"](): PublicBox;'));
      expect(types, contains('static name(): PublicBox;'));
    },
  );

  test(
    'annotation and external reference and factory selections agree',
    () async {
      const text = '''import 'package:napi/napi.dart';
@NAPI() Box identity(Box value) => value;
@NAPI(name: 'PublicBox') class Box {
  Box();
  @NAPI(name: 'from') Box.named();
  factory Box.shared() => _shared;
  Box self() => this;
}
final _shared = Box();
''';
      final annotated = await plan(text);
      final external = lower(
        validate(
          await ExternalFrontend(
            const ExternalLibrary([
              ExternalFunction('identity'),
              ExternalClass(
                'Box',
                config: NAPI(name: 'PublicBox'),
                members: [
                  ExternalMember.constructor(
                    'named',
                    config: NAPI(name: 'from'),
                  ),
                ],
              ),
            ]),
            packagesPath: packages,
          ).read(File('${directory.path}/business.dart').uri),
        ),
      );
      expect(emitDart(external), emitDart(annotated));
      expect(emitArgumentCalls(external), emitArgumentCalls(annotated));
      expect(emitDeclarations(external), emitDeclarations(annotated));
    },
  );

  for (final (label, declaration, code) in [
    (
      'unselected reference',
      'class Other {} @NAPI() Other identity(Other x) => x;',
      'NAPI_TYPE',
    ),
    (
      'nested list reference',
      '@NAPI() class Box {} @NAPI() List<Box> identity(List<Box> x) => x;',
      'NAPI_TYPE',
    ),
    (
      'nested record reference',
      '@NAPI() class Box {} @NAPI() (Box,) identity((Box,) x) => x;',
      'NAPI_TYPE',
    ),
    (
      'nonnull class default',
      '@NAPI() class Box { const Box(); } @NAPI() Box identity([Box x = const Box()]) => x;',
      'NAPI_DEFAULT',
    ),
    (
      'named static collision',
      '@NAPI() class Box { Box.named(); @NAPI(name: "named") static void make() {} }',
      'NAPI_DUPLICATE',
    ),
    (
      'renamed unnamed constructor',
      '@NAPI() class Box { @NAPI(name: "make") Box(); }',
      'NAPI_CONSTRUCTOR',
    ),
  ]) {
    test('$label is diagnosed before emit', () async {
      await expectLater(
        plan("import 'package:napi/napi.dart'; $declaration"),
        throwsA(
          isA<BindingDiagnostic>()
              .having((e) => e.code, 'code', code)
              .having(
                (e) => e.source?.uri.path,
                'source',
                '${directory.path}/business.dart',
              ),
        ),
      );
    });
  }

  test(
    'real Dart refs share wrappers without a reverse boundary import',
    () async {
      final module = await plan(_source);
      final entry = File('${directory.path}/entry.dart');
      await entry.writeAsString(emitDart(module));
      final compiled = await DartSdkAdapter().compile(
        sourcePath: entry.path,
        outputPath: '${directory.path}/raw.wasm',
        packagesPath: packages,
      );
      final linked = linkDartModule(
        rawWasmBytes: await File(compiled.wasmPath).readAsBytes(),
        rawMjsText: await File(compiled.jsPath).readAsString(),
        hostSpecifier: './host.mjs',
        coreSpecifier: './core.wasm',
        additionalImports: {'napi': './boundary.mjs'},
      );
      await File('${directory.path}/core.wasm').writeAsBytes(linked.wasmBytes);
      await File('${directory.path}/host.mjs')
          .writeAsString(linked.hostJavaScript);
      await File('${directory.path}/calls.mjs')
          .writeAsString(emitArgumentCalls(module));
      await File('${directory.path}/boundary.mjs')
          .writeAsString(emitBoundary(module));
      final other = await Directory('${directory.path}/other').create();
      for (final name in [
        'core.wasm',
        'host.mjs',
        'calls.mjs',
        'boundary.mjs',
      ]) {
        await File('${directory.path}/$name').copy('${other.path}/$name');
      }
      await File('${directory.path}/test.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import {Counter, Cached, AbstractFactory, NamedOnly, Child, identity, nullable, optional, named, hold, held} from './calls.mjs';
import {constructions, alive} from './core.wasm';
import {Counter as Foreign} from './other/calls.mjs';
const value = new Counter(17);
const before = constructions();
assert.equal(identity(value), value);
assert.equal(constructions(), before, "wrapping does not call Dart constructor");
assert.equal(identity.length, 1);
assert.throws(() => new identity(value), TypeError);
assert.equal(value.self(), value);
assert.equal(value.sum(new Counter(5)), 22);
assert.equal(nullable(value), value);
assert.equal(nullable(null), null);
assert.throws(() => nullable(undefined), TypeError);
assert.equal(optional(), null);
assert.equal(optional(undefined), null);
assert.equal(optional(value), value);
assert.equal(named({value}), value);
assert.equal(named(), null);
assert.throws(() => identity(new Foreign()), TypeError);
assert.throws(() => identity(new Proxy(value, {})), TypeError);
assert.throws(() => identity(Object.create(Counter.prototype)), TypeError);
assert.throws(() => identity(null), TypeError);
value.peer = value;
assert.equal(value.peer, value);
value.peer = null;
assert.equal(value.peer, null);
assert.equal(Counter.from(12).value, 12);
assert.equal(Counter.from.length, 1);
assert.equal(Counter.cached(), Counter.cached());
assert.equal(Counter.cached().value, 99);
assert.equal(new Cached(), new Cached());
assert.equal(new Cached().self(), new Cached());
assert.equal(new AbstractFactory().value, 23);
assert.throws(() => new NamedOnly(), TypeError);
assert.equal(NamedOnly.make(14).value, 14);
assert.throws(() => new Counter.from(12), TypeError);
assert.throws(() => new Child().asBase(), /conflicting public class identity/);
assert.equal(identity(value), value, 'failure leaves cache and calls usable');
const tick = () => new Promise(resolve => setImmediate(resolve));
async function collect(predicate) {
  for (let i = 0; i < 80; i++) {
    await tick(); global.gc();
    if (predicate()) return;
  }
  assert.fail('bounded GC did not collect reference');
}
const weak = (() => {
  const wrapper = new Counter(31);
  hold(wrapper);
  return new WeakRef(wrapper);
})();
await collect(() => weak.deref() === undefined);
assert.equal(alive(), 1, 'Dart still retains object');
const revived = (() => {
  const wrapper = held();
  assert.equal(wrapper.value, 31);
  assert.equal(held(), wrapper, 'recreated wrapper is interned');
  return new WeakRef(wrapper);
})();
hold(null);
await collect(() => revived.deref() === undefined && alive() === 0);
''');
      final execution = await Process.run('node', [
        '--expose-gc',
        'test.mjs',
      ], workingDirectory: directory.path);
      expect(
        execution.exitCode,
        0,
        reason: '${execution.stdout}${execution.stderr}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
