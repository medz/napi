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
import 'package:napi/src/compiler/native/declarations.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

const _source = '''
import 'package:napi/napi.dart';
int constructions = 0;
int reads = 0;
@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class Point {
  Point(this.x, {this.y = 7, this.child}) { constructions++; if (x == -1) throw StateError('domain'); }
  final int x;
  final int y;
  final Point? child;
  int get sum { reads++; return x + y; }
  int ignored() => 42;
}
@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'parse', valueFields: {'source': 'value'})
class Normalized {
  Normalized.parse(String source) : value = int.parse(source);
  @NAPI(name: 'answer') final int value;
}
@NAPI(classPolicy: ClassPolicy.value) abstract interface class Projection {
  int get x;
}
@NAPI() class Ref { Ref(this.value); int value; }
@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new')
class Envelope { Envelope(this.point, this.ref); final Point point; final Ref ref; }
@NAPI() Point echo(Point value) => value;
@NAPI() List<Point> many(List<Point> value) => value;
@NAPI(bigint: true) Point wide(Point value) => value;
@NAPI() Normalized normalize(Normalized value) => value;
@NAPI() Envelope refs(Envelope value) => value;
@NAPI() int count() => constructions;
@NAPI() int getterCount() => reads;
@NAPI() Projection project() => _Projection();
class _Projection implements Projection { int get x => 19; }
''';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  late File input;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-values-');
    addTearDown(() => directory.delete(recursive: true));
    input = await File('${directory.path}/business.dart')
        .writeAsString(_source);
  });
  Future<BindingModule> read() =>
      AnnotationFrontend(packagesPath: packages).read(input.uri);
  Future<ModulePlan> plan() async => lower(validate(await read()));

  test('finite recursive schemas, strict mappings, direction and reference-only numbering', () async {
    final module = await read();
    final generated = lower(validate(module));
    expect(generated.valueSchemas, hasLength(4));
    expect(generated.classes.single.binding.exportName, 'Ref');
    final echo = generated.functions.first;
    final value = echo.inputs.single as ValueClassConversion;
    expect(value.direction, ValueDirection.input);
    expect(value.fields.map((f) => f.name), ['x', 'y', 'child']);
    expect(value.fields[1].optional, isTrue);
    final child = value.fields.last.conversion as ValueClassConversion;
    expect(identical(child.fields.last.conversion, child), isTrue);
    expect(conversionGraph([value]).length, lessThan(10));
    expect(containsValueClass(value), isTrue);
    final output = echo.output as ValueClassConversion;
    expect(output.fields.map((f) => f.name), ['x', 'y', 'child', 'sum']);
    expect(output.fields.every((f) => !f.optional), isTrue);
    final envelope =
        generated.functions
                .singleWhere((f) => f.binding.exportName == 'refs')
                .inputs
                .single
            as ValueClassConversion;
    expect((envelope.fields.last.conversion as ReferenceConversion).classId, 0);
    final normal = generated.functions.singleWhere(
      (f) => f.binding.exportName == 'normalize',
    );
    expect(
      (normal.inputs.single as ValueClassConversion).fields.single.name,
      'answer',
    );
    expect(
      (normal.inputs.single as ValueClassConversion)
          .fields
          .single
          .conversion
          .dartType,
      'String',
    );
    expect(
      (normal.output as ValueClassConversion).fields.single.conversion.dartType,
      'int',
    );
    final native = validateNative(module);
    expect(native.classes.single.binding.exportName, 'Ref');
    expect(emitNativeDeclarations(native), contains('export type Point ='));
    final external = lower(
      validate(
        await ExternalFrontend(
          const ExternalLibrary([
            ExternalClass(
              'Point',
              config: NAPI(
                classPolicy: ClassPolicy.value,
                valueConstructor: 'new',
              ),
            ),
            ExternalClass(
              'Normalized',
              config: NAPI(
                classPolicy: ClassPolicy.value,
                valueConstructor: 'parse',
                valueFields: {'source': 'value'},
              ),
              members: [
                ExternalMember.field('value', config: NAPI(name: 'answer')),
              ],
            ),
            ExternalClass(
              'Projection',
              config: NAPI(classPolicy: ClassPolicy.value),
            ),
            ExternalClass('Ref'),
            ExternalClass(
              'Envelope',
              config: NAPI(
                classPolicy: ClassPolicy.value,
                valueConstructor: 'new',
              ),
            ),
            ExternalFunction('echo'),
            ExternalFunction('many'),
            ExternalFunction('wide', config: NAPI(bigint: true)),
            ExternalFunction('normalize'),
            ExternalFunction('refs'),
            ExternalFunction('count'),
            ExternalFunction('getterCount'),
            ExternalFunction('project'),
          ]),
          packagesPath: packages,
        ).read(input.uri),
      ),
    );
    expect(emitDart(external), emitDart(generated));
    expect(emitDeclarations(external), emitDeclarations(generated));
  });

  test(
    'output-only input is rejected recursively in every supported container',
    () async {
      for (final type in [
        'Projection',
        'List<Projection>',
        'Map<Projection, int>',
        'Map<int, Projection>',
        'Dictionary<Projection>',
        '(Projection, int)',
        'Envelope',
      ]) {
        await input.writeAsString('''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.value) class Projection { final int x = 1; }
@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new') class Envelope { Envelope(this.value); final Projection value; }
@NAPI() int bad($type value) => 1;
''');
        await expectLater(
          plan,
          throwsA(
            isA<BindingDiagnostic>().having(
              (e) => e.code,
              'code',
              'NAPI_VALUE_INPUT',
            ),
          ),
        );
      }
    },
  );

  test('invalid configuration diagnoses source instead of silently dropping selections', () async {
    for (final body in [
      "@NAPI(classPolicy: ClassPolicy.value, valueConstructor: '_hidden') class Bad { Bad._hidden(this.x); int x; }",
      "@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new') class Bad { Bad(int x); int y = 0; }",
      "@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new', valueFields: {'unknown': 'x'}) class Bad { Bad(this.x); int x; }",
      "@NAPI(classPolicy: ClassPolicy.value) class Bad { @NAPI() int method() => 1; }",
      "@NAPI(classPolicy: ClassPolicy.value) class Bad { @NAPI() static int x = 0; }",
      "@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new') class Bad { Bad(this.x); @NAPI(exclude: true) int x; }",
      "@NAPI(classPolicy: ClassPolicy.value, valueConstructor: 'new') class Bad { Bad([this.x = const []]); List<int> x; }",
      "@NAPI(valueConstructor: 'new') class Bad { Bad(); }",
    ]) {
      await input.writeAsString("import 'package:napi/napi.dart'; $body");
      await expectLater(
        plan,
        throwsA(
          isA<BindingDiagnostic>().having(
            (e) => e.source?.uri,
            'source',
            input.uri,
          ),
        ),
      );
    }
  });

  test('recursive aliases preserve input optionality, output required fields and bigint policy', () async {
    final module = await plan();
    final source = emitDeclarations(module);
    expect(source, contains('export type Point ='));
    expect(source, isNot(contains('declare class Point')));
    final declaration = await File('${directory.path}/module.d.ts')
        .writeAsString(source);
    await File('${directory.path}/test.ts').writeAsString('''
import {echo, wide, Point, normalize} from './module.js';
const out: Point = echo({x: 1, child: {x: 2}});
const required: number = out.y;
wide({x: 1n, child: {x: 2n}});
normalize({answer: '7'});
// @ts-expect-error output-only getter must not be supplied as input
 echo({x: 1, sum: 8});
// @ts-expect-error exact optional input properties cannot use null for a number
 echo({x: 1, y: null});
// @ts-expect-error bigint direction is distinct
 wide({x: 1});
// @ts-expect-error output fields are required
const bad: Point = {x: 1};
void required; void bad;
''');
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
      declaration.path,
      '${directory.path}/test.ts',
    ]);
    expect(checked.exitCode, 0, reason: '${checked.stdout}${checked.stderr}');
  });

  test(
    'actual Wasm validates whole roots before real recursive constructors',
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
import {Ref} from './calls.mjs';
assert.equal('Point' in core, false);
let before = core.count();
assert.throws(() => core.echo({x: 1, child: {x: 'bad'}}), TypeError);
assert.equal(core.count(), before);
assert.throws(() => core.many([{x: 1}, {x: 'bad'}]), TypeError);
assert.equal(core.count(), before);
const out = core.echo({x: 1, child: {x: 2, y: undefined}, y: undefined});
assert.deepEqual(out, {x: 1, y: 7, child: {x: 2, y: 7, child: null, sum: 9}, sum: 8});
assert.equal(Object.getPrototypeOf(out), Object.prototype);
assert.equal(core.count(), before + 2);
assert.equal(core.getterCount(), 2);
assert.throws(() => core.echo({x: 1, sum: 8}), e => e instanceof TypeError && e.message === 'echo.value.sum: unknown record field');
let getters = 0;
assert.throws(() => core.echo(Object.defineProperty({x: 1}, 'y', {get(){ getters++; return 2; }})), TypeError);
assert.equal(getters, 0);
assert.throws(() => core.echo({x: -1}), e => e instanceof Error && !(e instanceof TypeError) && e.message.includes('domain'));
const value = {x: 3};
const clones = core.many([value, value]); assert.notEqual(clones[0], clones[1]);
assert.deepEqual(core.normalize({answer: '19'}), {answer: 19});
assert.deepEqual(core.wide({x: 3n}), {x: 3n, y: 7n, child: null, sum: 10n});
const ref = new Ref(9); assert.equal(core.refs({point: {x: 1}, ref}).ref, ref);
const cyclic = {x: 1}; cyclic.child = cyclic;
assert.throws(() => core.echo(cyclic), e => e instanceof TypeError && e.message.includes('cyclic'));
assert.deepEqual(core.project(), {x: 19});
assert.equal(core.echo({x: 8}).x, 8);
console.log('values-ok');
''');
      final executed = await Process.run(
        Platform.environment['NODE'] ?? 'node',
        ['${directory.path}/test.mjs'],
      );
      expect(
        executed.exitCode,
        0,
        reason: '${executed.stdout}${executed.stderr}',
      );
      expect(executed.stdout, contains('values-ok'));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
