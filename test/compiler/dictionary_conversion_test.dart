import 'dart:io';

import 'package:napi/napi.dart';
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
import 'dart:collection';
import 'package:napi/napi.dart' as napi;
import 'exports.dart' as re;
typedef Alias<T> = napi.Dictionary<T>;
typedef Again<T> = Alias<T>;
@napi.NAPI() class Dictionary { Dictionary(this.value); int value; }
@napi.NAPI() Dictionary identity(Dictionary value) => value;
@napi.NAPI() class Record { Record(); }
@napi.NAPI() napi.Dictionary<int> echo(napi.Dictionary<int> value) => value;
@napi.NAPI() Again<List<Dictionary?>> refs(Again<List<Dictionary?>> value) => value;
@napi.NAPI() re.Dictionary<int> reexport(re.Dictionary<int> value) => value;
@napi.NAPI() napi.Dictionary<List<int>> arrays(napi.Dictionary<List<int>> value) => value;
@napi.NAPI() napi.Dictionary<napi.Dictionary<int>> recursive(napi.Dictionary<napi.Dictionary<int>> value) => value;
@napi.NAPI() napi.Dictionary<int>? optional([napi.Dictionary<int>? value]) => value;
@napi.NAPI(bigint: true) napi.Dictionary<Map<int, BigInt?>> wide(napi.Dictionary<Map<int, BigInt?>> value) => value;
@napi.NAPI() class Holder {
  Holder(this.values);
  napi.Dictionary<int> values;
  napi.Dictionary<int> echo(napi.Dictionary<int> value) => value;
}
@napi.NAPI() napi.Dictionary<int> duplicate() => napi.Dictionary<int>(_Duplicate());
class _Duplicate extends MapBase<String, int> {
  int get length => 2;
  Iterable<MapEntry<String, int>> get entries => const [MapEntry('same', 1), MapEntry('same', 2)];
  Iterable<String> get keys => const ['same', 'same'];
  int? operator [](Object? key) => 1;
  void operator []=(String key, int value) => throw UnimplementedError();
  void clear() => throw UnimplementedError();
  int? remove(Object? key) => throw UnimplementedError();
}
''';

void main() {
  test(
    'Dictionary has no runtime wrapper and uses ordinary Map operations',
    () {
      final source = <String, int>{'answer': 42};
      final dictionary = Dictionary<int>(source);
      expect(identical(source, dictionary), isTrue);
      dictionary['next'] = 3;
      expect(source['next'], 3);
    },
  );

  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  late File input;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-dictionary-');
    addTearDown(() => directory.delete(recursive: true));
    input = await File('${directory.path}/business.dart')
        .writeAsString(_source);
    await File('${directory.path}/exports.dart')
        .writeAsString("export 'package:napi/napi.dart';");
  });
  Future<ModulePlan> plan() async => lower(
    validate(await AnnotationFrontend(packagesPath: packages).read(input.uri)),
  );

  test('canonical Dictionary survives aliases/reexports and same-name classes stay references', () async {
    final module = await plan();
    final identity = module.functions.singleWhere(
      (f) => f.binding.exportName == 'identity',
    );
    expect(identity.inputs.single, isA<ReferenceConversion>());
    final echo = module.functions.singleWhere(
      (f) => f.binding.exportName == 'echo',
    );
    final dictionary = echo.inputs.single as DictionaryConversion;
    expect(dictionary.dartType, 'napi.Dictionary<int>');
    expect(dictionary.typescriptType, '{ [key: string]: number }');
    expect(echo.representation, ExportRepresentation.nativeFunction);
    final refs =
        module.functions
                .singleWhere((f) => f.binding.exportName == 'refs')
                .inputs
                .single
            as DictionaryConversion;
    expect((refs.value as ListConversion).element, isA<ReferenceConversion>());
    expect(
      module.functions
          .singleWhere((f) => f.binding.exportName == 'reexport')
          .inputs
          .single,
      isA<DictionaryConversion>(),
    );
    final wide =
        module.functions
                .singleWhere((f) => f.binding.exportName == 'wide')
                .inputs
                .single
            as DictionaryConversion;
    expect(
      ((wide.value as MapConversion).key as ScalarConversion).usesBigInt,
      isTrue,
    );
    expect(
      module.classes.last.constructor!.inputs.single,
      isA<DictionaryConversion>(),
    );
    expect(
      emitDart(module),
      contains("import 'package:napi/napi.dart' as napi;"),
    );
    expect(emitDart(module), isNot(contains('target.Dictionary<int>')));
    final external = lower(
      validate(
        await ExternalFrontend(
          const ExternalLibrary([
            ExternalClass('Dictionary'),
            ExternalFunction('identity'),
            ExternalClass('Record'),
            ExternalFunction('echo'),
            ExternalFunction('refs'),
            ExternalFunction('reexport'),
            ExternalFunction('arrays'),
            ExternalFunction('recursive'),
            ExternalFunction('optional'),
            ExternalFunction('wide', config: NAPI(bigint: true)),
            ExternalClass('Holder'),
            ExternalFunction('duplicate'),
          ]),
          packagesPath: packages,
        ).read(input.uri),
      ),
    );
    expect(emitDart(external), emitDart(module));
    expect(emitDeclarations(external), emitDeclarations(module));
    final types = await File('${directory.path}/module.d.ts')
        .writeAsString(emitDeclarations(module));
    final tsc =
        Platform.environment['NAPI_TSC'] ??
        '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
    final checked = await Process.run(Platform.environment['NODE'] ?? 'node', [
      tsc,
      '--ignoreConfig',
      '--noEmit',
      '--strict',
      '--exactOptionalPropertyTypes',
      '--target',
      'ES2022',
      types.path,
    ]);
    expect(checked.exitCode, 0, reason: '${checked.stdout}${checked.stderr}');
    for (final declaration in [
      DeclarationId(
        input.uri,
        'Dictionary',
        kind: DeclarationKind.extensionType,
      ),
      DeclarationId(
        dictionaryDeclaration.library,
        'Dictionary',
        kind: DeclarationKind.classType,
      ),
    ]) {
      expect(
        () => validateValueType(
          DeclaredType(
            declaration,
            ValueSemantics.structural,
            typeArguments: [const SafeIntType()],
          ),
          SourceLocation(input.uri, 0, 1),
        ),
        throwsA(isA<BindingDiagnostic>()),
      );
    }
  });

  test('unsupported Dictionary leaves remain diagnosed', () async {
    for (final source in [
      "import 'package:napi/napi.dart'; @NAPI() Dictionary<dynamic> bad(Dictionary<dynamic> value) => value;",
    ]) {
      await input.writeAsString(source);
      await expectLater(plan, throwsA(isA<BindingDiagnostic>()));
    }
  });

  test(
    'real Wasm Dictionary uses own data keys and null-prototype copied outputs',
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
import * as core from './core.wasm';
import {Dictionary as Ref, Holder, optional} from './calls.mjs';
const source = Object.create(null);
for (const key of ['', 'a.b', '__proto__', 'constructor', '10', '2', '\0', '\ud800', '😀', '"', '\\', '\u2028', '\u2029']) {
  Object.defineProperty(source, key, {value: 3, enumerable: false, writable: true, configurable: true});
}
const copied = core.echo(source);
assert.equal(Object.getPrototypeOf(copied), null);
assert.notEqual(copied, source);
assert.deepEqual(Reflect.ownKeys(copied), Reflect.ownKeys(source));
for (const key of Reflect.ownKeys(source)) { assert.equal(copied[key], 3); assert(Object.getOwnPropertyDescriptor(copied, key).enumerable); }
copied.__proto__ = 7; assert.equal(source.__proto__, 3);
for (const bad of [null, undefined, [], new Map(), new Date(), Object.create({})]) assert.throws(() => core.echo(bad), TypeError);
assert.equal(optional(), null); assert.equal(optional(undefined), null); assert.equal(optional(null), null);
const ref = new Ref(9);
const refs = core.refs({one: [ref, null, ref]});
assert.equal(Object.getPrototypeOf(refs), null); assert.deepEqual(refs.one, [ref, null, ref]);
assert.equal(core.reexport({x: 1}).x, 1);
const holder = new Holder({x: 2}); holder.values = {y: 3};
assert.equal(holder.values.y, 3); assert.equal(holder.echo({z: 4}).z, 4);
assert.equal(Object.getPrototypeOf(holder.values), null);
assert.equal(core.wide({x: new Map([[1n, 1n << 100n]])}).x.get(1n), 1n << 100n);
let getter = 0;
const accessor = Object.defineProperty({}, 'secret', {get() { getter++; throw Error('getter'); }});
assert.throws(() => core.echo(accessor), e => e instanceof TypeError && e.message.startsWith('echo.value["secret"]:'));
assert.equal(getter, 0);
assert.throws(() => core.echo({[Symbol('x')]: 1}), e => e instanceof TypeError && e.message === 'echo.value: expected string Dictionary keys');
for (const key of Reflect.ownKeys(source)) {
  const bad = Object.defineProperty({}, key, {value: 'wrong'});
  assert.throws(() => core.echo(bad), e => e instanceof TypeError && e.message.startsWith('echo.value[' + JSON.stringify(key) + ']:'));
}
const events = [];
const parent = new Proxy({first: ['wrong'], later: [1]}, {
  ownKeys(target) { events.push('keys'); return Reflect.ownKeys(target); },
  getOwnPropertyDescriptor(target, key) { events.push(key); return Reflect.getOwnPropertyDescriptor(target, key); },
});
assert.throws(() => core.arrays(parent), TypeError); assert.deepEqual(events, ['keys', 'first']);
const mutated = {first: null, later: [1]};
mutated.first = new Proxy([2], {getOwnPropertyDescriptor(target, key) { if (key === '0') delete mutated.later; return Reflect.getOwnPropertyDescriptor(target, key); }});
assert.throws(() => core.arrays(mutated), e => e instanceof TypeError && e.message.startsWith('arrays.value["later"]:'));
const cycle = {}; cycle.self = cycle;
assert.throws(() => core.recursive(cycle), e => e instanceof TypeError && e.message.startsWith('recursive.value["self"]: cyclic'));
const large = Object.fromEntries(Array.from({length: 9999}, (_, i) => [String(i), i]));
assert.equal(Object.keys(core.echo(large)).length, 9999);
large.overflow = 1; assert.throws(() => core.echo(large), RangeError);
assert.throws(() => core.duplicate(), e => e instanceof TypeError && e.message === 'duplicate result["same"]: duplicate Dictionary key');
const originalProto = Object.getOwnPropertyDescriptor(Object.prototype, '__proto__');
let setters = 0; Object.defineProperty(Object.prototype, '__proto__', {configurable: true, set() { setters++; throw Error('setter'); }});
let safe;
try { safe = core.echo(source); }
finally { Object.defineProperty(Object.prototype, '__proto__', originalProto); }
assert.equal(setters, 0); assert.equal(Object.getPrototypeOf(safe), null); assert.equal(safe.__proto__, 3);
assert.equal(core.echo({ok: 1}).ok, 1);
console.log('dictionary-ok');
''');
      final result = await Process.run(Platform.environment['NODE'] ?? 'node', [
        '${directory.path}/test.mjs',
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
      expect(result.stdout, contains('dictionary-ok'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
