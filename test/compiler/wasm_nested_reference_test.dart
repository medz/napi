import 'dart:io';

import 'package:napi/napi.dart' show NAPI;
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/js/arguments.dart';
import 'package:napi/src/compiler/emit/js/boundary.dart';
import 'package:napi/src/compiler/emit/js/references.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/linker/dart_module_linker.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

const _source = '''
import 'package:napi/napi.dart';
int _created = 0;
WeakReference<DartCounter>? _last;
List<DartCounter?>? _saved;
@NAPI() int created() => _created;
@NAPI() int alive() => _last?.target == null ? 0 : 1;
@NAPI() int hold(List<DartCounter?>? values) { _saved = values; return 0; }
@NAPI() List<DartCounter?>? saved() => _saved;
@NAPI() List<DartCounter?> echoRefs(List<DartCounter?> value) => value;
@NAPI() List<DartCounter?>? optional([List<DartCounter?>? value]) => value;
typedef Row = ({DartCounter item, List<DartCounter?> aliases});
@NAPI() List<Row> echoRows(List<Row> value) => value;
@NAPI(name: 'Counter') class DartCounter {
  DartCounter(this.value) { _created++; _last = WeakReference(this); }
  int value;
}
@NAPI(name: 'Collection') class DartCollection {
  DartCollection(this.values) : original = values;
  DartCollection.named({required this.values}) : original = values;
  List<DartCounter?> values;
  final List<DartCounter?> original;
  List<DartCounter?> echo(List<DartCounter?> value) => value;
  List<Row> rows(List<Row> value) => value;
  List<DartCounter?> get other => values;
  set other(List<DartCounter?> value) { values = value; }
  static List<DartCounter?> same(List<DartCounter?> value) => value;
}
@NAPI() class Base { Base(); }
@NAPI() class Child extends Base { Child(); List<Base> asBase() => [this]; }
''';

void main() {
  late Directory directory;
  late File input;
  final packages = File('.dart_tool/package_config.json').absolute.path;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-nested-reference-');
    addTearDown(() => directory.delete(recursive: true));
    input = await File('${directory.path}/business.dart')
        .writeAsString(_source);
  });
  Future<ModulePlan> plan() async => lower(
    validate(await AnnotationFrontend(packagesPath: packages).read(input.uri)),
  );

  test(
    'nested conversions retain selected class IDs and existing default policy',
    () async {
      final module = await plan();
      final rows = module.functions.singleWhere(
        (f) => f.binding.exportName == 'echoRows',
      );
      expect(rows.representation, ExportRepresentation.nativeFunction);
      final record =
          (rows.inputs.single as ListConversion).element as RecordConversion;
      expect((record.named['item'] as ReferenceConversion).classId, 0);
      expect(
        ((record.named['aliases'] as ListConversion).element
                as ReferenceConversion)
            .classId,
        0,
      );
      expect(
        emitDeclarations(module),
        contains('Array<{ aliases: Array<Counter | null>; item: Counter }>'),
      );
      expect(emitReferences(), isNot(contains('import ')));
      expect(emitBoundary(module), isNot(contains("from './calls.mjs'")));
      await input.writeAsString(
        "import 'package:napi/napi.dart'; @NAPI() class Box {} @NAPI() List<Box> bad([List<Box> value = const []]) => value;",
      );
      await expectLater(
        () async => lower(
          validate(
            await AnnotationFrontend(packagesPath: packages).read(input.uri),
          ),
        ),
        throwsA(
          isA<BindingDiagnostic>().having(
            (e) => e.code,
            'code',
            'NAPI_DEFAULT',
          ),
        ),
      );
    },
  );

  test(
    'external class structure selections use the same runtime mapping',
    () async {
      final annotated = await plan();
      final external = lower(
        validate(
          await ExternalFrontend(
            const ExternalLibrary([
              ExternalFunction('created'),
              ExternalFunction('alive'),
              ExternalFunction('hold'),
              ExternalFunction('saved'),
              ExternalFunction('echoRefs'),
              ExternalFunction('optional'),
              ExternalFunction('echoRows'),
              ExternalClass('DartCounter', config: NAPI(name: 'Counter')),
              ExternalClass('DartCollection', config: NAPI(name: 'Collection')),
              ExternalClass('Base'),
              ExternalClass('Child'),
            ]),
            packagesPath: packages,
          ).read(input.uri),
        ),
      );
      expect(emitDart(external), emitDart(annotated));
      expect(emitArgumentCalls(external), emitArgumentCalls(annotated));
      expect(emitDeclarations(external), emitDeclarations(annotated));
    },
  );

  test(
    'real public Wasm shares nested reference identity and releases wrappers',
    () async {
      final module = await plan();
      final entry = await File('${directory.path}/entry.dart')
          .writeAsString(emitDart(module));
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
      await File('${directory.path}/module.wasm').writeAsBytes(
        buildPublicWasmFacade(
          hostSpecifier: './calls.mjs',
          exportNames: [
            for (final f in module.functions)
              if (f.representation == ExportRepresentation.callableGlobal)
                f.binding.exportName,
            ...module.classes.map((c) => c.binding.exportName),
          ],
          nativeFunctions: {
            for (final f in module.functions)
              if (f.representation == ExportRepresentation.nativeFunction)
                f.binding.exportName: f.inputs.length,
          },
        ),
      );
      await File('${directory.path}/host.mjs')
          .writeAsString(linked.hostJavaScript);
      await File('${directory.path}/calls.mjs')
          .writeAsString(emitArgumentCalls(module));
      await File('${directory.path}/boundary.mjs')
          .writeAsString(emitBoundary(module));
      await File('${directory.path}/references.mjs')
          .writeAsString(emitReferences());
      final other = await Directory('${directory.path}/other').create();
      for (final name in [
        'core.wasm',
        'module.wasm',
        'host.mjs',
        'calls.mjs',
        'boundary.mjs',
        'references.mjs',
      ]) {
        await File('${directory.path}/$name').copy('${other.path}/$name');
      }
      await File('${directory.path}/test.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import * as api from './module.wasm';
import * as core from './core.wasm';
import * as foreign from './other/module.wasm';
assert.equal(api.created(), 0, 'registration must not invoke business construction');
assert.equal(api.echoRefs, core.echoRefs, 'required nested signatures stay direct Wasm functions');
const value = new api.Counter(17);
const source = [value, null, value];
const result = api.echoRefs(source);
assert.notEqual(result, source);
assert.equal(result[0], value); assert.equal(result[2], value);
assert.equal(api.optional(), null);
assert.equal(api.optional(undefined), null);
const row = {item: value, aliases: source};
const rows = api.echoRows([row, row]);
assert.notEqual(rows[0], rows[1]);
assert.notEqual(rows[0].aliases, rows[1].aliases);
assert.equal(rows[0].item, value); assert.equal(rows[1].aliases[2], value);
const collection = new api.Collection(source);
assert.equal(collection.values[0], value);
assert.equal(collection.original[0], value);
assert.throws(() => { collection.original = []; }, TypeError);
assert.equal(collection.echo(source)[2], value);
assert.equal(collection.rows([row])[0].item, value);
assert.equal(api.Collection.same(source)[0], value);
collection.other = [null, value];
assert.equal(collection.other[1], value);
collection.values = [value];
assert.equal(collection.values[0], value);
assert.equal(api.Collection.named({values: source}).values[2], value);
assert.throws(() => api.Collection.named({}), /missing required argument/);
const bad = new foreign.Counter(91);
for (const leaf of [bad, new Proxy(value, {}), Object.create(api.Counter.prototype), undefined]) {
  assert.throws(() => api.echoRows([{item: value, aliases: [leaf]}]), error =>
    error instanceof TypeError && error.message.startsWith('echoRows.value[0].aliases[0]: '));
}
const child = new api.Child();
assert.equal(child.asBase()[0], child, 'nested Base view preserves canonical Child identity');
assert.equal(api.echoRefs([value])[0], value, 'failed leaf must leave adapters usable');
const tick = () => new Promise(resolve => setImmediate(resolve));
async function collect(predicate) {
  for (let i = 0; i < 80; i++) { await tick(); global.gc(); if (predicate()) return; }
  assert.fail('bounded collection failed');
}
const weak = (() => {
  const item = new api.Counter(31);
  api.hold([item]);
  return new WeakRef(item);
})();
await collect(() => weak.deref() === undefined);
assert.equal(api.alive(), 1, 'Dart List retains its class leaf');
const revived = (() => {
  const first = api.saved();
  const second = api.saved();
  assert.notEqual(first, second);
  assert.equal(first[0], second[0]);
  assert.equal(first[0].value, 31);
  return new WeakRef(first[0]);
})();
api.hold(null);
await collect(() => revived.deref() === undefined && api.alive() === 0);
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
