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
@NAPI(classPolicy: ClassPolicy.value)
class Point {
  Point(this.x, {this.y = 7, this.child}) { constructions++; if (x == -1) throw StateError('domain'); }
  final int x;
  final int y;
  final Point? child;
  int get sum { reads++; return x + y; }
  int ignored() => 42;
}
@NAPI(classPolicy: ClassPolicy.value, valueFields: {'source': 'value'})
class Normalized {
  Normalized.parse(String source) : value = int.parse(source);
  @NAPI(name: 'answer') final int value;
}
@NAPI(classPolicy: ClassPolicy.value) abstract interface class Projection {
  int get x;
}
@NAPI() class Ref { Ref(this.value); int value; }
@NAPI(classPolicy: ClassPolicy.value)
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

  test('explicit value constructors override inferred entry points', () async {
    await input.writeAsString('''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.value) class Selected {
  Selected(this.value);
  @NAPI() Selected.parse(int source, {int offset = 7}) : value = source + offset;
  Selected.other(this.value);
  final int value;
}
@NAPI(classPolicy: ClassPolicy.value) abstract class FactoryValue {
  @NAPI() factory FactoryValue.parse(int source) = _FactoryValue;
  factory FactoryValue.other(int source) = _FactoryValue;
  int get value;
}
class _FactoryValue implements FactoryValue {
  _FactoryValue(this.value);
  final int value;
}
@NAPI(classPolicy: ClassPolicy.value) class Excluded {
  @NAPI(exclude: true) Excluded(this.value);
  @NAPI() Excluded.selected(this.value);
  Excluded.other(this.value);
  final int value;
}
@NAPI() Selected selected(Selected value) => value;
@NAPI() FactoryValue factoryValue(FactoryValue value) => value;
''');
    final annotated = await read();
    final external = await ExternalFrontend(
      const ExternalLibrary([
        ExternalClass(
          'Selected',
          config: NAPI(classPolicy: ClassPolicy.value),
          members: [ExternalMember.constructor('parse')],
        ),
        ExternalClass(
          'FactoryValue',
          config: NAPI(classPolicy: ClassPolicy.value),
          members: [ExternalMember.constructor('parse')],
        ),
        ExternalClass(
          'Excluded',
          config: NAPI(classPolicy: ClassPolicy.value),
          members: [
            ExternalMember.constructor('new', config: NAPI(exclude: true)),
            ExternalMember.constructor('selected'),
          ],
        ),
        ExternalFunction('selected'),
        ExternalFunction('factoryValue'),
      ]),
      packagesPath: packages,
    ).read(input.uri);
    for (final module in [annotated, external]) {
      for (final schemas in [
        validate(module).valueSchemas,
        validateNative(module).valueSchemas,
      ]) {
        final selected = schemas.singleWhere(
          (s) => s.binding.exportName == 'Selected',
        );
        expect(selected.constructor!.declaration.name, 'parse');
        expect(selected.inputFields.map((f) => f.name), ['source', 'offset']);
        expect(selected.inputFields.last.parameter.hasDefault, isTrue);
        expect(
          schemas
              .singleWhere((s) => s.binding.exportName == 'FactoryValue')
              .constructor!
              .isFactory,
          isTrue,
        );
        expect(
          schemas
              .singleWhere((s) => s.binding.exportName == 'Excluded')
              .constructor!
              .declaration
              .name,
          'selected',
        );
      }
      expect(
        emitDeclarations(lower(validate(module))),
        emitNativeDeclarations(validateNative(module)),
      );
    }
    expect(
      emitDeclarations(lower(validate(annotated))),
      emitDeclarations(lower(validate(external))),
    );
  });

  test('value constructor selections stay local to concrete aliases', () async {
    await input.writeAsString('''
class Box<T> {
  Box(this.value);
  Box.named(T source) : value = source;
  final T value;
}
typedef Integer = Box<int>;
typedef Text = Box<String>;
Integer integer(Integer value) => value;
Text text(Text value) => value;
''');
    final module = await ExternalFrontend(
      const ExternalLibrary([
        ExternalClass(
          'Integer',
          config: NAPI(classPolicy: ClassPolicy.value),
          members: [ExternalMember.constructor('named')],
        ),
        ExternalClass('Text', config: NAPI(classPolicy: ClassPolicy.value)),
        ExternalFunction('integer'),
        ExternalFunction('text'),
      ]),
      packagesPath: packages,
    ).read(input.uri);
    for (final schemas in [
      validate(module).valueSchemas,
      validateNative(module).valueSchemas,
    ]) {
      final integer = schemas.singleWhere(
        (s) => s.binding.exportName == 'Integer',
      );
      final text = schemas.singleWhere((s) => s.binding.exportName == 'Text');
      expect(integer.constructor!.declaration.name, 'named');
      expect(integer.inputFields.single.name, 'source');
      expect(integer.inputFields.single.parameter.type, isA<SafeIntType>());
      expect(text.constructor!.declaration.name, 'new');
      expect(text.inputFields.single.name, 'value');
      expect(
        (text.inputFields.single.parameter.type as DeclaredType)
            .declaration
            .name,
        'String',
      );
    }
  });

  test(
    'conflicting explicit value constructors name both candidates',
    () async {
      await input.writeAsString('''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.value) class Value {
  @NAPI() Value(this.value);
  @NAPI() Value.named(this.value);
  final int value;
}
''');
      final diagnostic = throwsA(
        isA<BindingDiagnostic>()
            .having((error) => error.code, 'code', 'NAPI_AMBIGUOUS')
            .having(
              (error) => error.message,
              'message',
              allOf(contains('Value'), contains('named')),
            ),
      );
      await expectLater(read(), diagnostic);
      await expectLater(
        ExternalFrontend(
          const ExternalLibrary([
            ExternalClass(
              'Value',
              config: NAPI(classPolicy: ClassPolicy.value),
              members: [
                ExternalMember.constructor('new'),
                ExternalMember.constructor('named'),
              ],
            ),
          ]),
          packagesPath: packages,
        ).read(input.uri),
        diagnostic,
      );
    },
  );

  test(
    'output projections ignore unused constructor input types and defaults',
    () async {
      const source = '''
import 'package:napi/napi.dart';
@NAPI() class Ref { const Ref._(); }
@NAPI(classPolicy: ClassPolicy.value)
class Projection { Projection(Object source); final int value = 1; }
@NAPI(classPolicy: ClassPolicy.value)
class Timestamp { Timestamp(DateTime source); final int value = 2; }
@NAPI(classPolicy: ClassPolicy.value)
class WithDefault { WithDefault([Ref source = const Ref._()]); final int value = 3; }
class Generic<T> { Generic(T source); final int value = 4; }
@NAPI(classPolicy: ClassPolicy.value) typedef GenericObject = Generic<Object>;
@NAPI() Projection project() => Projection(Object());
@NAPI() Timestamp timestamp() => Timestamp(DateTime.utc(2000));
@NAPI() WithDefault withDefault() => WithDefault();
@NAPI() GenericObject generic() => GenericObject(Object());
''';
      await input.writeAsString(source);
      final external = ExternalFrontend(
        const ExternalLibrary([
          ExternalClass('Ref'),
          ExternalClass(
            'Projection',
            config: NAPI(classPolicy: ClassPolicy.value),
          ),
          ExternalClass(
            'Timestamp',
            config: NAPI(classPolicy: ClassPolicy.value),
          ),
          ExternalClass(
            'WithDefault',
            config: NAPI(classPolicy: ClassPolicy.value),
          ),
          ExternalClass(
            'GenericObject',
            config: NAPI(classPolicy: ClassPolicy.value),
          ),
          ExternalFunction('project'),
          ExternalFunction('timestamp'),
          ExternalFunction('withDefault'),
          ExternalFunction('generic'),
        ]),
        packagesPath: packages,
      );
      for (final module in [await read(), await external.read(input.uri)]) {
        final wasm = lower(validate(module));
        final native = validateNative(module);
        expect(wasm.valueSchemas.every((s) => s.constructor != null), isTrue);
        expect(native.valueSchemas.every((s) => s.constructor != null), isTrue);
        final declarations = emitDeclarations(wasm);
        expect(emitNativeDeclarations(native), declarations);
        expect(declarations, contains('export type GenericObject ='));
      }
    },
  );

  test('actual value inputs validate constructor types and defaults', () async {
    for (final (parameter, constructor, code) in [
      ('Object source', '', 'NAPI_TYPE'),
      ('DateTime source', '', 'NAPI_TYPE'),
      (
        '[Ref source = const Ref._()]',
        '@NAPI() class Ref { const Ref._(); }',
        'NAPI_DEFAULT',
      ),
    ]) {
      for (final container in [
        'Projection',
        'List<Projection>',
        'JsArray<Projection>',
      ]) {
        await input.writeAsString('''
import 'package:napi/napi.dart';
$constructor
@NAPI(classPolicy: ClassPolicy.value)
class Projection { Projection($parameter); final int value = 1; }
@NAPI() int consume($container value) => 1;
''');
        final module = await read();
        final diagnostic = predicate<BindingDiagnostic>(
          (error) =>
              error.code ==
              (container.startsWith('JsArray') && code == 'NAPI_TYPE'
                  ? 'NAPI_JS_COLLECTION'
                  : code),
        );
        expect(
          () => validate(module),
          throwsA(diagnostic),
          reason: '$container constructor parameter $parameter',
        );
        expect(
          () => validateNative(module),
          throwsA(diagnostic),
          reason: '$container constructor parameter $parameter',
        );
      }
    }
  });

  test(
    'constructors and independent input properties follow Dart declarations',
    () async {
      await input.writeAsString('''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.value)
class DefaultValue { final int value = 1; }
@NAPI(classPolicy: ClassPolicy.value)
class Preferred {
  Preferred(this.value, {this.tag = 4});
  Preferred.named(this.value) : tag = 8;
  final int value;
  final int tag;
}
@NAPI(classPolicy: ClassPolicy.value)
class Parsed {
  Parsed.parse(String source) : value = int.parse(source);
  final int value;
}
@NAPI(classPolicy: ClassPolicy.value)
abstract class FactoryValue {
  factory FactoryValue.make(int source) = _FactoryValue;
  int get value;
}
class _FactoryValue implements FactoryValue {
  _FactoryValue(int source) : value = source;
  final int value;
}
@NAPI(classPolicy: ClassPolicy.value)
class Excluded {
  @NAPI(exclude: true) Excluded(this.value);
  Excluded.named(this.value);
  final int value;
}
@NAPI(classPolicy: ClassPolicy.value)
class Ambiguous {
  Ambiguous.first(this.value);
  Ambiguous.second(this.value);
  final int value;
}
@NAPI(classPolicy: ClassPolicy.value)
class PrivateValue { PrivateValue._(this.value); final int value; }
@NAPI(classPolicy: ClassPolicy.value)
class Independent {
  Independent(this._value, int arguments) : second = arguments;
  final int _value;
  final int second;
  int get value => _value;
}
@NAPI() Parsed parse(Parsed value) => value;
''');
      final module = await read();
      for (final schemas in [
        validate(module).valueSchemas,
        validateNative(module).valueSchemas,
      ]) {
        final byName = {
          for (final schema in schemas) schema.binding.exportName: schema,
        };
        expect(byName['DefaultValue']!.constructor!.declaration.name, 'new');
        expect(byName['DefaultValue']!.inputFields, isEmpty);
        expect(byName['Preferred']!.constructor!.declaration.name, 'new');
        expect(byName['Preferred']!.inputFields.map((f) => f.name), [
          'value',
          'tag',
        ]);
        expect(
          byName['Preferred']!.inputFields.last.parameter.defaultValue,
          isNotNull,
        );
        expect(byName['Parsed']!.constructor!.declaration.name, 'parse');
        expect(byName['Parsed']!.inputFields.single.name, 'source');
        expect(byName['Parsed']!.inputFields.single.field, isNull);
        expect(byName['FactoryValue']!.constructor!.declaration.name, 'make');
        expect(byName['FactoryValue']!.inputFields.single.name, 'source');
        expect(byName['Excluded']!.constructor!.declaration.name, 'named');
        expect(byName['Ambiguous']!.constructor, isNull);
        expect(byName['PrivateValue']!.constructor, isNull);
        expect(byName['Independent']!.inputFields.map((f) => f.name), [
          '_value',
          'arguments',
        ]);
      }
      final wasm = lower(validate(module));
      final constructor =
          (wasm.functions.single.inputs.single as ValueClassConversion)
              .fields
              .single;
      expect(constructor.name, 'source');
      expect(constructor.binding, isNull);
      expect(emitDeclarations(wasm), contains('"source": string'));
    },
  );

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
              config: NAPI(classPolicy: ClassPolicy.value),
            ),
            ExternalClass(
              'Normalized',
              config: NAPI(
                classPolicy: ClassPolicy.value,
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
              config: NAPI(classPolicy: ClassPolicy.value),
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
@NAPI(classPolicy: ClassPolicy.value) class Projection { Projection._(); final int x = 1; }
@NAPI(classPolicy: ClassPolicy.value) class Envelope { Envelope(this.value); final Projection value; }
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

  test(
    'value export collisions ignore methods and setters in both frontends',
    () async {
      for (final getter in [false, true]) {
        await input.writeAsString('''
import 'package:napi/napi.dart';
@NAPI(classPolicy: ClassPolicy.value)
class Value {
  Value(int source) : _source = source;
  int _source;
  ${getter ? "@NAPI(name: 'compute') int get source => _source; set source(int next) => _source = next;" : "@NAPI(name: 'compute') int source = 1;"}
  int compute() => _source + 1;
}
@NAPI() Value echo(Value value) => value;
''');
        final selection = ExternalLibrary([
          ExternalClass(
            'Value',
            config: const NAPI(classPolicy: ClassPolicy.value),
            members: [
              if (getter)
                const ExternalMember.getter(
                  'source',
                  config: NAPI(name: 'compute'),
                )
              else
                const ExternalMember.field(
                  'source',
                  config: NAPI(name: 'compute'),
                ),
            ],
          ),
          const ExternalFunction('echo'),
        ]);
        for (final external in [false, true]) {
          final bindings = external
              ? await ExternalFrontend(
                  selection,
                  packagesPath: packages,
                ).read(input.uri)
              : await read();
          final wasm = lower(validate(bindings));
          final schema = wasm.valueSchemas.single;
          expect(schema.outputFields.map((f) => f.name), ['compute']);
          expect(schema.inputFields.map((f) => f.name), ['compute']);
          expect(
            validateNative(bindings)
                .valueSchemas
                .single
                .outputFields
                .single
                .name,
            'compute',
          );
        }
      }
    },
  );

  test('explicit non-data value members still diagnose and reference collisions stay rejected', () async {
    for (final valuePolicy in [true, false]) {
      await input.writeAsString('''
import 'package:napi/napi.dart';
@NAPI(${valuePolicy ? "classPolicy: ClassPolicy.value" : ''})
class Value {
  Value(this.source);
  @NAPI(name: 'compute') final int source;
  ${valuePolicy ? "@NAPI(name: 'included')" : ''} int compute() => source + 1;
}
@NAPI() Value echo(Value value) => value;
''');
      final selection = ExternalLibrary([
        ExternalClass(
          'Value',
          config: valuePolicy
              ? const NAPI(classPolicy: ClassPolicy.value)
              : const NAPI(),
          members: [
            const ExternalMember.field('source', config: NAPI(name: 'compute')),
            if (valuePolicy)
              const ExternalMember.method(
                'compute',
                config: NAPI(name: 'included'),
              ),
          ],
        ),
        const ExternalFunction('echo'),
      ]);
      for (final external in [false, true]) {
        Future<BindingModule> load() => external
            ? ExternalFrontend(
                selection,
                packagesPath: packages,
              ).read(input.uri)
            : read();
        if (!valuePolicy) {
          await expectLater(
            load(),
            throwsA(
              isA<BindingDiagnostic>()
                  .having((e) => e.code, 'code', 'NAPI_DUPLICATE')
                  .having((e) => e.source?.uri, 'source', input.uri),
            ),
          );
          continue;
        }
        final bindings = await load();
        for (final backend in [
          () => validate(bindings),
          () => validateNative(bindings),
        ]) {
          expect(
            backend,
            throwsA(
              isA<BindingDiagnostic>()
                  .having(
                    (e) => e.code,
                    'code',
                    valuePolicy ? 'NAPI_VALUE' : 'NAPI_DUPLICATE',
                  )
                  .having((e) => e.source?.uri, 'source', input.uri),
            ),
          );
        }
      }
    }
  });

  test('invalid configuration diagnoses source instead of silently dropping selections', () async {
    for (final body in [
      "@NAPI(classPolicy: ClassPolicy.value, valueFields: {'unknown': 'x'}) class Bad { Bad(this.x); int x; }",
      "@NAPI(classPolicy: ClassPolicy.value) class Bad { @NAPI() int method() => 1; }",
      "@NAPI(classPolicy: ClassPolicy.value) class Bad { @NAPI() static int x = 0; }",
      "@NAPI(classPolicy: ClassPolicy.value, valueFields: {'x': 'x'}) class Bad { Bad._hidden(this.x); int x; }",
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
