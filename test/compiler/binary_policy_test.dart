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

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  late Directory directory;
  late File input;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-binary-policy-');
    input = File('${directory.path}/entry.dart');
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<BindingModule> read(String source) async {
    await input.writeAsString('''
import 'dart:typed_data' as data;
import 'package:napi/napi.dart';
$source
''');
    return AnnotationFrontend(packagesPath: packages).read(input.uri);
  }

  Map<String, String> declarations(BindingModule module) => {
    'wasm': emitDeclarations(lower(validate(module))),
    'native': emitNativeDeclarations(validateNative(module)),
  };

  test('canonical binary identity survives aliases and reexports', () async {
    await File('${directory.path}/exports.dart')
        .writeAsString("export 'dart:typed_data';");
    final module = await read('''
import 'exports.dart' as re;
typedef Bytes = data.Uint8List;
typedef Again = Bytes;
typedef Buffer = data.ByteBuffer;
@NAPI() data.Uint8List bytes(data.Uint8List value) => value;
@NAPI() Again alias(Again value) => value;
@NAPI() re.Uint8List exported(re.Uint8List value) => value;
@NAPI() Buffer buffer(Buffer value) => value;
@NAPI() data.Uint8List? nullable(data.Uint8List? value) => value;
''');
    expect(module.functions[1].parameters.single.type.alias, isNotNull);
    for (final conversions in [
      lower(validate(module)).functions.map((call) => call.inputs.single),
      validateNative(module).functions.map((call) => call.inputs.single),
    ]) {
      final values = conversions.cast<BinaryConversion>().toList();
      expect(values.map((value) => value.kind), [
        BinaryKind.uint8List,
        BinaryKind.uint8List,
        BinaryKind.uint8List,
        BinaryKind.byteBuffer,
        BinaryKind.uint8List,
      ]);
      expect(values.first.dartType, 'typed_data.Uint8List');
      expect(values[3].dartType, 'typed_data.ByteBuffer');
      expect(values.last.dartType, 'typed_data.Uint8List?');
      expect(values.first.jsType, 'object');
      expect(
        values.first.typescriptType,
        'globalThis.Uint8Array<globalThis.ArrayBuffer>',
      );
      expect(values[3].typescriptType, 'globalThis.ArrayBuffer');
      expect(
        values.last.typescriptType,
        'globalThis.Uint8Array<globalThis.ArrayBuffer> | null',
      );
      expect(conversionGraph([values.first]), [values.first]);
    }
    expect(BinaryConversion.maxByteLength, 2147483647);

    final external = await ExternalFrontend(
      const ExternalLibrary([
        ExternalFunction('bytes'),
        ExternalFunction('alias'),
        ExternalFunction('exported'),
        ExternalFunction('buffer'),
        ExternalFunction('nullable'),
      ]),
      packagesPath: packages,
    ).read(input.uri);
    expect(declarations(external), declarations(module));
  });

  test(
    'binary leaves compose with structural and value-class conversions',
    () async {
      final module = await read('''
@NAPI() List<data.Uint8List?> lists(List<data.Uint8List?> value) => value;
@NAPI() Map<data.Uint8List, data.ByteBuffer?> maps(Map<data.Uint8List, data.ByteBuffer?> value) => value;
@NAPI() Dictionary<data.ByteBuffer> dictionaries(Dictionary<data.ByteBuffer> value) => value;
@NAPI() (data.Uint8List, {data.ByteBuffer? buffer}) records((data.Uint8List, {data.ByteBuffer? buffer}) value) => value;
@NAPI(classPolicy: ClassPolicy.value)
class Packet {
  final data.Uint8List bytes;
  final data.ByteBuffer? buffer;
  Packet(this.bytes, {this.buffer});
}
@NAPI() Packet packet(Packet value) => value;
''');
      for (final roots in [
        lower(validate(module)).conversions,
        [
          for (final call in validateNative(module).calls) ...[
            ...call.inputs,
            ?call.output,
          ],
        ],
      ]) {
        expect(
          conversionGraph(roots).whereType<BinaryConversion>(),
          hasLength(16),
        );
        expect(conversionGraph(roots).whereType<ScalarConversion>(), isEmpty);
        expect(
          conversionGraph(roots).whereType<ValueClassConversion>(),
          hasLength(2),
        );
      }
      for (final code in declarations(module).values) {
        expect(
          code,
          contains(
            'Array<globalThis.Uint8Array<globalThis.ArrayBuffer> | null>',
          ),
        );
        expect(
          code,
          contains(
            'globalThis.Map<globalThis.Uint8Array<globalThis.ArrayBuffer>, globalThis.ArrayBuffer | null>',
          ),
        );
        expect(code, contains('{ [key: string]: globalThis.ArrayBuffer }'));
        expect(
          code,
          contains('"bytes": globalThis.Uint8Array<globalThis.ArrayBuffer>'),
        );
        expect(
          code,
          contains('"buffer"?: globalThis.ArrayBuffer | null | undefined'),
        );
      }
    },
  );

  test('Future and Stream deliver the binary payload shape', () async {
    final module = await read('''
@NAPI() Future<data.Uint8List> later(data.Uint8List value) async => value;
@NAPI() Stream<data.ByteBuffer> chunks(data.ByteBuffer value) async* { yield value; }
@NAPI() Future<List<data.ByteBuffer?>> nested(List<data.ByteBuffer?> value) async => value;
''');
    final wasm = lower(validate(module));
    final native = validateNative(module);
    expect(wasm.functions[0].returnsFuture, isTrue);
    expect(wasm.functions[1].returnsStream, isTrue);
    expect(native.functions[0].output, isA<BinaryConversion>());
    expect(native.functions[1].output, isA<BinaryConversion>());
    for (final code in declarations(module).values) {
      expect(
        code,
        contains(
          'globalThis.Promise<globalThis.Uint8Array<globalThis.ArrayBuffer>>',
        ),
      );
      expect(
        code,
        contains(
          'globalThis.AsyncIterableIterator<globalThis.ArrayBuffer, undefined, undefined>',
        ),
      );
      expect(
        code,
        contains('globalThis.Promise<Array<globalThis.ArrayBuffer | null>>'),
      );
      expect(code, isNot(contains(r'$napiAwaited')));
    }
  });

  test('nullable and optional binary inputs keep ordinary presence rules', () async {
    final module = await read('''
@NAPI() data.Uint8List? optional([data.Uint8List? value = null]) => value;
@NAPI() data.ByteBuffer named({required data.ByteBuffer buffer, data.Uint8List? bytes}) => buffer;
@NAPI() data.ByteBuffer? options({data.ByteBuffer? buffer}) => buffer;
@NAPI() class Holder {
  data.Uint8List? bytes;
  Holder([this.bytes]);
  data.ByteBuffer? getBuffer({data.ByteBuffer? value}) => value;
}
''');
    final plan = lower(validate(module));
    expect(
      plan.functions.first.parameters.single.presence,
      ParameterPresence.optional,
    );
    expect(
      plan.functions[1].parameters.map((parameter) => parameter.presence),
      [ParameterPresence.required, ParameterPresence.optional],
    );
    for (final code in declarations(module).values) {
      expect(
        code,
        contains(
          '(value?: globalThis.Uint8Array<globalThis.ArrayBuffer> | null)',
        ),
      );
      expect(
        code,
        contains(
          '(options: { buffer: globalThis.ArrayBuffer; bytes?: globalThis.Uint8Array<globalThis.ArrayBuffer> | null | undefined })',
        ),
      );
      expect(
        code,
        contains(
          '(options?: { buffer?: globalThis.ArrayBuffer | null | undefined })',
        ),
      );
      expect(
        code,
        contains(
          'constructor(bytes?: globalThis.Uint8Array<globalThis.ArrayBuffer> | null)',
        ),
      );
    }
  });

  test('same-name selected classes stay references and generic payloads stay opaque', () async {
    final module = await read('''
@NAPI() class Uint8List { Uint8List(); }
@NAPI() class ByteBuffer { ByteBuffer(); }
@NAPI() Uint8List userBytes(Uint8List value) => value;
@NAPI() ByteBuffer userBuffer(ByteBuffer value) => value;
@NAPI() T opaque<T>(T value) => value;
''');
    for (final inputs in [
      lower(validate(module)).functions
          .map((call) => call.inputs.single)
          .toList(),
      validateNative(module).functions
          .map((call) => call.inputs.single)
          .toList(),
    ]) {
      expect(inputs[0], isA<ReferenceConversion>());
      expect(inputs[1], isA<ReferenceConversion>());
      expect(inputs[2], isA<OpaqueConversion>());
    }
  });

  for (final type in [
    'Int8List',
    'Uint8ClampedList',
    'Int16List',
    'Uint16List',
    'Int32List',
    'Uint32List',
    'Int64List',
    'Uint64List',
    'Float32List',
    'Float64List',
    'Float32x4List',
    'Float64x2List',
    'Int32x4List',
    'ByteData',
    'TypedData',
  ]) {
    test('$type is an explicit unsupported binary type', () async {
      final module = await read(
        '@NAPI() List<data.$type> echo(List<data.$type> value) => value;',
      );
      for (final check in [
        () => validate(module),
        () => validateNative(module),
      ]) {
        expect(
          check,
          throwsA(
            isA<BindingDiagnostic>()
                .having((error) => error.code, 'code', 'NAPI_BINARY')
                .having((error) => error.message, 'message', contains(type)),
          ),
        );
      }
    });
  }

  for (final signature in [
    'void Function(data.Uint8List)',
    'void Function(List<data.ByteBuffer>)',
    'data.Uint8List Function()',
    'Future<data.ByteBuffer> Function()',
    '({data.Uint8List value}) Function()',
  ]) {
    test('binary callback signature remains rejected: $signature', () async {
      final module = await read(
        '@NAPI() int accept($signature callback) => 1;',
      );
      for (final check in [
        () => validate(module),
        () => validateNative(module),
      ]) {
        expect(
          check,
          throwsA(
            isA<BindingDiagnostic>()
                .having((error) => error.code, 'code', 'NAPI_CALLBACK')
                .having(
                  (error) => error.message,
                  'message',
                  contains('Binary values'),
                ),
          ),
        );
      }
    });
  }

  test('binary TypeScript preserves ArrayBuffer storage and name hygiene in all modes', () async {
    final module = await read('''
@NAPI() class Uint8Array { Uint8Array(); }
@NAPI() class ArrayBuffer { ArrayBuffer(); }
@NAPI() data.Uint8List bytes(data.Uint8List value) => value;
@NAPI() data.ByteBuffer buffer(data.ByteBuffer value) => value;
@NAPI() data.Uint8List? optional([data.Uint8List? value]) => value;
@NAPI() data.ByteBuffer named({required data.ByteBuffer buffer, data.Uint8List? bytes}) => buffer;
@NAPI() Future<data.Uint8List> later(data.Uint8List value) async => value;
@NAPI() Stream<data.ByteBuffer> chunks(data.ByteBuffer value) async* { yield value; }
@NAPI() Uint8Array generic<Uint8Array, ArrayBuffer>(Uint8Array payload, data.Uint8List bytes, ArrayBuffer other) => payload;
@NAPI() T opaque<T>(T value) => value;
''');
    final consumers = <String>[];
    for (final backend in declarations(module).entries) {
      await File('${directory.path}/${backend.key}.d.mts')
          .writeAsString(backend.value);
      final consumer = File('${directory.path}/${backend.key}-consumer.mts');
      consumers.add(consumer.path);
      await consumer.writeAsString('''
import * as api from './${backend.key}.mjs';
const bytes = new Uint8Array(new ArrayBuffer(4));
const buffer = new ArrayBuffer(4);
const copied: Uint8Array<ArrayBuffer> = api.bytes(bytes);
const copiedBuffer: ArrayBuffer = api.buffer(buffer);
const optional: Uint8Array<ArrayBuffer> | null = api.optional(undefined);
api.optional(null);
api.named({ buffer, bytes: undefined });
api.named({ buffer, bytes: null });
const later: Promise<Uint8Array<ArrayBuffer>> = api.later(bytes);
const chunks: AsyncIterableIterator<ArrayBuffer, undefined, undefined> = api.chunks(buffer);
const generic: string = api.generic<string, number>('payload', bytes, 1);
const shared = new Uint8Array(new SharedArrayBuffer(4));
const unchanged: typeof shared = api.opaque(shared);
// @ts-expect-error Shared storage cannot enter an ordinary binary snapshot binding.
api.bytes(shared);
// @ts-expect-error SharedArrayBuffer is outside the supported input contract.
api.buffer(new SharedArrayBuffer(4));
// @ts-expect-error Required binary values reject undefined.
api.bytes(undefined);
// @ts-expect-error Required binary values reject null.
api.buffer(null);
// @ts-expect-error Required named fields remain required.
api.named({ bytes });
// @ts-expect-error Ordinary arrays are not Uint8Array views.
api.bytes([1, 2]);
void [copied, copiedBuffer, optional, later, chunks, generic, unchanged];
''');
    }
    final tsc =
        Platform.environment['NAPI_TSC'] ??
        '${Directory.current.path}/.dart_tool/js/node_modules/typescript/bin/tsc';
    for (final mode in ['NodeNext', 'Bundler']) {
      for (final exact in ['true', 'false']) {
        for (final indexed in ['true', 'false']) {
          final result = await Process.run(
            Platform.environment['NODE'] ?? 'node',
            [
              tsc,
              '--ignoreConfig',
              '--noEmit',
              '--strict',
              '--target',
              'ES2022',
              '--module',
              mode == 'NodeNext' ? 'NodeNext' : 'ESNext',
              '--moduleResolution',
              mode,
              '--exactOptionalPropertyTypes',
              exact,
              '--noUncheckedIndexedAccess',
              indexed,
              ...consumers,
            ],
          );
          expect(
            result.exitCode,
            0,
            reason:
                '$mode exact=$exact indexed=$indexed: ${result.stdout}${result.stderr}',
          );
        }
      }
    }
  });
}
