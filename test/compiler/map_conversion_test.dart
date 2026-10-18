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
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/linker/dart_module_linker.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

const _source = '''
import 'dart:core' hide Map;
import 'dart:core' as core;
import 'package:napi/napi.dart';
@NAPI() class Map { Map(this.value); int value; }
@NAPI() Map identity(Map value) => value;
@NAPI() core.Map<String, List<Map?>> echo(core.Map<String, List<Map?>> value) => value;
@NAPI() core.Map<String, List<int>> arrays(core.Map<String, List<int>> value) => value;
@NAPI() core.Map<({int id}), String> records(core.Map<({int id}), String> value) => value;
@NAPI() core.Map<double, String> doubles(core.Map<double, String> value) => value;
@NAPI() core.Map<String, Map> fresh() => {'fresh': Map(8)};
@NAPI() core.Map<double, String> duplicateNaN() => {double.nan: 'first', double.nan: 'second'};
@NAPI() core.Map<String, int>? optional([core.Map<String, int>? value]) => value;
@NAPI() core.Map<String, int>? named({core.Map<String, int>? value}) => value;
@NAPI() int globalThis() => 17;
@NAPI() class Holder {
  Holder(this.values);
  core.Map<String, List<Map?>> values;
  core.Map<String, List<Map?>> echo(core.Map<String, List<Map?>> value) => value;
}
@NAPI() class Key {
  Key(this.id, [this.explode = false]);
  final int id;
  bool explode;
  @NAPI(exclude: true) int get hashCode {
    if (explode) throw StateError('hash exploded');
    return id.hashCode;
  }
  @NAPI(exclude: true) bool operator ==(Object other) => other is Key && other.id == id;
}
@NAPI() core.Map<Key, int> keys(core.Map<Key, int> value) => value;
''';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  late File input;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-map-conversion-');
    addTearDown(() => directory.delete(recursive: true));
    input = await File('${directory.path}/business.dart')
        .writeAsString(_source);
  });
  Future<ModulePlan> plan() async => lower(
    validate(await AnnotationFrontend(packagesPath: packages).read(input.uri)),
  );

  test('Map conversions preserve both children and exact declaration identity', () async {
    final module = await plan();
    final echo = module.functions.singleWhere(
      (f) => f.binding.exportName == 'echo',
    );
    final conversion = echo.inputs.single as MapConversion;
    expect(conversion.key, isA<ScalarConversion>());
    expect(
      (conversion.value as ListConversion).element,
      isA<ReferenceConversion>(),
    );
    expect(conversion.dartType, 'Map<String, List<target.Map?>>');
    expect(
      conversion.typescriptType,
      'globalThis.Map<string, ReadonlyArray<Map | null>>',
    );
    expect(echo.representation, ExportRepresentation.nativeFunction);
    expect(module.functions.first.inputs.single, isA<ReferenceConversion>());
    expect(module.classes[1].constructor!.inputs.single, isA<MapConversion>());
    expect(
      module.classes[1].members.where((m) => m.output is MapConversion),
      isNotEmpty,
    );
    final declarations = emitDeclarations(module);
    expect(declarations, contains('export declare class Map'));
    expect(declarations, contains('globalThis.Map<string, Array<Map | null>>'));
    expect(
      declarations,
      contains('value?: globalThis.Map<string, number> | null'),
    );
    await File('${directory.path}/module.d.ts').writeAsString(declarations);
    final tsc =
        Platform.environment['TSC_PATH'] ??
        '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
    final types = await Process.run(Platform.environment['NODE'] ?? 'node', [
      tsc,
      '--noEmit',
      '--strict',
      '--exactOptionalPropertyTypes',
      '--target',
      'ES2022',
      '${directory.path}/module.d.ts',
    ]);
    expect(types.exitCode, 0, reason: '${types.stdout}${types.stderr}');

    final external = lower(
      validate(
        await ExternalFrontend(
          const ExternalLibrary([
            ExternalClass('Map'),
            ExternalFunction('identity'),
            ExternalFunction('echo'),
            ExternalFunction('arrays'),
            ExternalFunction('records'),
            ExternalFunction('doubles'),
            ExternalFunction('duplicateNaN'),
            ExternalFunction('fresh'),
            ExternalFunction('optional'),
            ExternalFunction('named'),
            ExternalFunction('globalThis'),
            ExternalClass('Holder'),
            ExternalClass(
              'Key',
              members: [
                ExternalMember.getter('hashCode', config: NAPI(exclude: true)),
                ExternalMember.method('==', config: NAPI(exclude: true)),
              ],
            ),
            ExternalFunction('keys'),
          ]),
          packagesPath: packages,
        ).read(input.uri),
      ),
    );
    expect(emitDart(external), emitDart(module));
    expect(emitDeclarations(external), declarations);

    final source = SourceLocation(input.uri, 0, 1);
    for (final declaration in [
      DeclarationId(input.uri, 'Map', kind: DeclarationKind.classType),
      DeclarationId(
        Uri.parse('dart:core'),
        'Map',
        kind: DeclarationKind.extensionType,
      ),
    ]) {
      expect(
        () => validateValueType(
          DeclaredType(
            declaration,
            ValueSemantics.structural,
            typeArguments: [const SafeIntType(), const SafeIntType()],
          ),
          source,
        ),
        throwsA(isA<BindingDiagnostic>()),
      );
    }
  });

  test('unsupported Map children remain diagnosed', () async {
    for (final source in [
      "import 'package:napi/napi.dart'; @NAPI() Map<String,dynamic> bad(Map<String,dynamic> value) => value;",
      "import 'package:napi/napi.dart'; @NAPI() Map<Set<int>,int> bad(Map<Set<int>,int> value) => value;",
    ]) {
      await input.writeAsString(source);
      await expectLater(plan, throwsA(isA<BindingDiagnostic>()));
    }
  });

  test('real Wasm Maps snapshot entries, reject collisions and preserve class leaves', () async {
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
    await File('${directory.path}/host.mjs')
        .writeAsString(linked.hostJavaScript);
    await File('${directory.path}/calls.mjs')
        .writeAsString(emitArgumentCalls(module));
    await File('${directory.path}/boundary.mjs')
        .writeAsString(emitBoundary(module));
    await File('${directory.path}/references.mjs')
        .writeAsString(emitReferences());
    await File('${directory.path}/test.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import vm from 'node:vm';
import * as core from './core.wasm';
import {Map as Ref, Holder, Key, optional, named} from './calls.mjs';
const value = new Ref(7);
const input = new Map([['row', [value, null, value]]]);
const output = core.echo(input);
assert.notEqual(output, input);
assert.deepEqual(output.get('row'), [value, null, value]);
assert.notEqual(output.get('row'), input.get('row'));
const holder = new Holder(input);
assert.deepEqual(holder.values.get('row'), [value, null, value]);
holder.values = new Map([['other', [value]]]);
assert.equal(holder.echo(input).get('row')[0], value);
assert.equal(holder.values.get('other')[0], value);
assert.equal(optional(), null); assert.equal(optional(undefined), null);
assert.equal(named(), null); assert.equal(named({value: undefined}), null);
assert.deepEqual(optional(new Map([['x', 3]])), new Map([['x', 3]]));
assert.throws(() => core.echo({}), e => e instanceof TypeError && e.message.includes('echo.value: expected a Map'));
assert.throws(() => core.echo(new Proxy(input, {})), TypeError);
const realm = vm.runInNewContext('new Map([[2, "realm"]])');
assert.deepEqual(core.doubles(realm), new Map([[2, 'realm']]));
class SubMap extends Map { get size() { throw Error('size'); } entries() { throw Error('entries'); } [Symbol.iterator]() { throw Error('iterator'); } }
assert.deepEqual(core.arrays(new SubMap([['x', [1]]])), new Map([['x', [1]]]));
const parent = new Map();
let changed = 0;
const child = new Proxy([3], {getOwnPropertyDescriptor(target, key) { if (key === '0') { changed++; parent.set('later', [99]); } return Reflect.getOwnPropertyDescriptor(target, key); }});
parent.set('first', child);
assert.deepEqual(core.arrays(parent), new Map([['first', [3]]]));
assert.equal(changed, 1);
assert.throws(() => core.records(new Map([[{id: 1}, 'a'], [{id: 1}, 'b']])), e => e instanceof TypeError && e.message.includes('records.value[1].key: duplicate converted Map key'));
assert.throws(() => core.duplicateNaN(), e => e instanceof TypeError && e.message.includes('duplicateNaN result[1].key: duplicate converted Map key'));
const nan = core.doubles(new Map([[NaN, 'kept']]));
assert.equal(nan.size, 1); assert.equal(nan.get(NaN), 'kept');
assert.equal(core.doubles(new Map([[-0, 'zero']])).get(0), 'zero');
const a = new Key(1); const b = new Key(1);
assert.throws(() => core.keys(new Map([[a, 1], [b, 2]])), e => e instanceof TypeError && e.message.includes('keys.value[1].key: duplicate converted Map key'));
a.explode = true;
assert.throws(() => core.keys(new Map([[a, 1]])), e => e.constructor === Error && e.message.includes('hash exploded'));
a.explode = false;
assert.equal(core.keys(new Map([[a, 1]])).get(a), 1);
assert.throws(() => core.arrays(new Map(Array.from({length: 5000}, (_, i) => [String(i), []]))), RangeError);
let setters = 0;
Object.defineProperty(Array.prototype, '0', {configurable: true, set() { setters++; throw Error('prototype setter'); }});
let result;
try { result = core.fresh(); }
finally { delete Array.prototype[0]; }
assert.equal(setters, 0); assert.equal(result.get('fresh').value, 8);
assert.equal(core.globalThis(), 17);
console.log('map-ok');
''');
    final result = await Process.run(Platform.environment['NODE'] ?? 'node', [
      '${directory.path}/test.mjs',
    ]);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    expect(result.stdout, contains('map-ok'));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
