import 'dart:io';

import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;

  test(
    'typed retained adapters compile with nullable and structural values',
    () async {
      final directory = await Directory.systemTemp.createTemp('napi-callback-');
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/business.dart');
      await source.writeAsString('''
import 'package:napi/napi.dart';
@NAPI() int apply(int Function(int) callback) => callback(1);
@NAPI() int optional([int? Function(int?)? callback]) => callback?.call(null) ?? 0;
@NAPI() int notify(void Function() callback) { callback(); return 1; }
@NAPI() Future<int> later(Future<int> Function(int) callback) => callback(42);
@NAPI() Future<void> laterVoid(Future<void> Function() callback) => callback();
@NAPI() int list(List<int> Function(List<int>) callback) => callback([1]).length;
@NAPI() String record((int, {String label}) Function((int, {String label})) callback) => callback((1, label: 'a')).label;
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  Resource();
  int call(int Function(int) callback) => callback(1);
  void close() {}
}
''');
      final plan = validateNative(
        await AnnotationFrontend(
          packagesPath: packages,
          native: true,
        ).read(source.uri),
      );
      final generated = emitNativeDart(plan);
      expect(generated, contains('final int Function(int) a0;'));
      expect(generated, contains('callback.invoke<void>'));
      expect(generated, contains('callback.invokeFuture<int>'));
      expect(generated, isNot(contains('NativeBorrowFrame')));
      expect(generated, contains('Object? acceptCallback('));
      expect(
        generated,
        contains('late final Future<int> Function(int) adapter'),
      );
      expect(generated, contains('callback.invokeFuture<int>(adapter, '));
      expect(generated, contains('_api.callback<int Function(int)>'));
      // Structures only occur inside callback signatures in this module.
      expect(generated, contains('final class _NativeReadState'));
      expect(generated, contains('callback argument 1'));
      expect(generated, contains('callback result'));
      final entry = File('${directory.path}/entry.dart');
      await entry.writeAsString(generated);
      final compiled = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'aot-snapshot',
        '--packages=$packages',
        entry.path,
        '--output=${directory.path}/module.aot',
      ]);
      expect(
        compiled.exitCode,
        0,
        reason: '${compiled.stdout}${compiled.stderr}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('optional and named callback adapters compile as native AOT', () async {
    final directory = await Directory.systemTemp.createTemp(
      'napi-optional-callback-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = await File('${directory.path}/business.dart')
        .writeAsString('''
import 'dart:typed_data';
import 'package:napi/napi.dart';
@NAPI() int positional(int Function(int, [int?, String?]) callback) => callback(1) + callback(1, null) + callback(1, 2, 'a');
@NAPI() int nonnull(int Function([int]) callback) => callback() + callback(1);
@NAPI() void options(void Function({int? count, List<int>? values}) callback) { callback(); callback(count: null); callback(values: [1]); }
@NAPI() int named(int Function({required int callback, String? adapter, int? operation, String? env, int? state, int? result, int? c0}) callback) => callback(callback: 1, env: null);
@NAPI() int requiredNamed(int Function({required int env}) callback) => callback(env: 1);
@NAPI() T opaque<T>(T Function([T]) callback, T value) => callback(value);
@NAPI() Future<T> later<T>(Future<T> Function({T value, Uint8List? bytes}) callback, T value) => callback(value: value);
@NAPI() int nullable(int Function({int? value})? callback) => callback?.call() ?? 0;
@NAPI() Ref? references(Ref? Function({Ref? value}) callback, Ref value) => callback(value: value);
@NAPI() class Ref { Ref(); }
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource extends Ref { Resource(); void close() {} }
''');
    final plan = validateNative(
      await AnnotationFrontend(
        packagesPath: packages,
        native: true,
      ).read(source.uri),
    );
    final entry = await File('${directory.path}/entry.dart')
        .writeAsString(emitNativeDart(plan));
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'aot-snapshot',
      '--packages=$packages',
      entry.path,
      '--output=${directory.path}/module.aot',
    ]);
    expect(
      compiled.exitCode,
      0,
      reason: '${compiled.stdout}${compiled.stderr}',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('JS collection-only functions compile as native AOT', () async {
    final directory = await Directory.systemTemp.createTemp(
      'napi-collection-functions-',
    );
    addTearDown(() => directory.delete(recursive: true));
    final source = await File('${directory.path}/business.dart')
        .writeAsString('''
import 'package:napi/napi.dart';
@NAPI() JsArray<int Function(int)> functions(JsArray<int Function(int)> values) {
  final first = values.get(0);
  values.set(1, (value) => value + 1);
  first?.call(2);
  return values;
}
''');
    final plan = validateNative(
      await AnnotationFrontend(
        packagesPath: packages,
        native: true,
      ).read(source.uri),
    );
    final entry = await File('${directory.path}/entry.dart')
        .writeAsString(emitNativeDart(plan));
    final compiled = await Process.run(Platform.resolvedExecutable, [
      'compile',
      'aot-snapshot',
      '--packages=$packages',
      entry.path,
      '--output=${directory.path}/module.aot',
    ]);
    expect(
      compiled.exitCode,
      0,
      reason: '${compiled.stdout}${compiled.stderr}',
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('function outputs and nested functions compile as native AOT', () async {
    final directory = await Directory.systemTemp.createTemp(
      'napi-function-values-',
    );
    addTearDown(() => directory.delete(recursive: true));
    for (final sourceText in [
      '''
import 'package:napi/napi.dart';
@NAPI() int Function(int) adder(int delta) => (value) => value + delta;
''',
      '''
import 'package:napi/napi.dart';
typedef Unary = int Function(int);
@NAPI() Unary adder(int delta) => (value) => value + delta;
@NAPI() Unary? nullable(bool present) => present ? (value) => value : null;
@NAPI() Unary echo(Unary value) => value;
@NAPI() List<Unary?> functions(List<Unary?> values) => values;
@NAPI() (Map<String, Unary>, {Dictionary<Unary> values}) containers((Map<String, Unary>, {Dictionary<Unary> values}) value) => value;
@NAPI() Unary transform(Unary Function(Unary) callback) => callback((value) => value + 1);
@NAPI() int Function([int, int]) positional() => ([int first = 7, int second = 9]) => first + second;
@NAPI() int Function({int value, int extra}) named() => ({int value = 7, int extra = 9}) => value + extra;
@NAPI() Future<Unary> later() async => (int value) => value + 1;
@NAPI() Future<int> Function(int) asynchronous() => (value) async => value + 1;
@NAPI() T Function() capture<T>(T value) => () => value;
@NAPI() Resource Function(Resource) resourceFunction() => (value) => value;
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource { Resource(); void close() {} }
''',
    ]) {
      final source = await File('${directory.path}/business.dart')
          .writeAsString(sourceText);
      final plan = validateNative(
        await AnnotationFrontend(
          packagesPath: packages,
          native: true,
        ).read(source.uri),
      );
      final entry = await File('${directory.path}/entry.dart')
          .writeAsString(emitNativeDart(plan));
      final compiled = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'aot-snapshot',
        '--packages=$packages',
        entry.path,
        '--output=${directory.path}/module.aot',
      ]);
      expect(
        compiled.exitCode,
        0,
        reason: '${compiled.stdout}${compiled.stderr}',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  for (final (name, source, binary, shared) in [
    (
      'binary',
      '''
import 'dart:typed_data';
import 'package:napi/napi.dart';
@NAPI() int bytes(Uint8List? Function(Uint8List?) callback) => callback(Uint8List.fromList([1]))?.length ?? -1;
@NAPI() int buffer(ByteBuffer? Function(ByteBuffer?)? callback) => callback?.call(null)?.lengthInBytes ?? -1;
@NAPI() Future<int> later(Future<Uint8List?> Function(Uint8List?) callback) async => (await callback(null))?.length ?? -1;
@NAPI() Future<int> laterBuffer(Future<ByteBuffer?> Function(ByteBuffer?) callback) async => (await callback(null))?.lengthInBytes ?? -1;
''',
      true,
      false,
    ),
    (
      'shared bytes',
      '''
import 'package:napi/napi.dart';
@NAPI() int shared(SharedBytes? Function(SharedBytes?) callback) => callback(SharedBytes.allocate(1))?.length ?? -1;
@NAPI() int nullable(SharedBytes? Function(SharedBytes?)? callback) => callback?.call(null)?.length ?? -1;
@NAPI() Future<int> later(Future<SharedBytes?> Function(SharedBytes?) callback) async => (await callback(null))?.length ?? -1;
''',
      false,
      true,
    ),
    (
      'nested binary and shared bytes',
      '''
import 'dart:typed_data';
import 'package:napi/napi.dart';
typedef Packet = (Uint8List?, {ByteBuffer? buffer, SharedBytes? shared});
@NAPI() int list(List<Uint8List?>? Function(List<Uint8List?>?) callback) => callback([null])?.length ?? -1;
@NAPI() int sharedList(List<SharedBytes?>? Function(List<SharedBytes?>?) callback) => callback([null])?.length ?? -1;
@NAPI() int record(Packet? Function(Packet?) callback) => callback((null, buffer: null, shared: null))?.\$1?.length ?? -1;
@NAPI() Future<int> later(Future<List<Packet?>?> Function(List<Packet?>?) callback) async => (await callback([null]))?.length ?? -1;
''',
      true,
      true,
    ),
  ]) {
    test('$name callback-only payloads compile as native AOT', () async {
      final directory = await Directory.systemTemp.createTemp(
        'napi-binary-callback-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final business = await File('${directory.path}/business.dart')
          .writeAsString(source);
      final plan = validateNative(
        await AnnotationFrontend(
          packagesPath: packages,
          native: true,
        ).read(business.uri),
      );
      expect(plan.hasBinary, binary);
      expect(plan.hasSharedBytesTypes, shared);
      final entry = await File('${directory.path}/entry.dart')
          .writeAsString(emitNativeDart(plan));
      final compiled = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'aot-snapshot',
        '--packages=$packages',
        entry.path,
        '--output=${directory.path}/module.aot',
      ]);
      expect(
        compiled.exitCode,
        0,
        reason: '${compiled.stdout}${compiled.stderr}',
      );
    }, timeout: const Timeout(Duration(minutes: 2)));
  }

  test(
    'copied, reference and opaque callbacks compile with and without resources',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'napi-value-callback-',
      );
      addTearDown(() => directory.delete(recursive: true));
      const source = '''
import 'package:napi/napi.dart';
@NAPI() class Ref { Ref(this.id); final int id; }
@NAPI(classPolicy: ClassPolicy.value)
class Value { Value(this.id, {this.extra = 2}); final int id; final int extra; }
@NAPI(classPolicy: ClassPolicy.value)
class Output { Output._(this.id); final int id; }
@NAPI() int maps(Map<Ref, List<Ref?>> Function(Map<Ref, List<Ref?>>) callback, Ref value) => callback({value: [value, null]}).length;
@NAPI() int dictionaries<T>(Dictionary<T?> Function(Dictionary<T?>) callback, T value) => callback(Dictionary({'key': value})).length;
@NAPI() Value values(Value Function(Output) callback) => callback(Output._(1));
@NAPI() Ref? reference(Ref? Function(Ref?) callback, Ref? value) => callback(value);
@NAPI() Future<Ref> later(Future<Ref> Function(Ref) callback, Ref value) => callback(value);
@NAPI() T opaque<T>(T Function(T) callback, T value) => callback(value);
@NAPI() Future<T?> laterOpaque<T>(Future<T?> Function(T?) callback, T? value) => callback(value);
@NAPI() (T, Value) result<T>((T, Value) Function() callback) => callback();
''';
      for (final resources in [false, true]) {
        final business = await File('${directory.path}/business.dart')
            .writeAsString(
              source +
                  (resources
                      ? '''
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource extends Ref { Resource(super.id); void close() {} }
@NAPI() int resource(int Function(Ref) callback) => callback(Resource(1));
'''
                      : ''),
            );
        final plan = validateNative(
          await AnnotationFrontend(
            packagesPath: packages,
            native: true,
          ).read(business.uri),
        );
        final entry = await File('${directory.path}/entry.dart')
            .writeAsString(emitNativeDart(plan));
        final compiled = await Process.run(Platform.resolvedExecutable, [
          'compile',
          'aot-snapshot',
          '--packages=$packages',
          entry.path,
          '--output=${directory.path}/module.aot',
        ]);
        expect(
          compiled.exitCode,
          0,
          reason: '${compiled.stdout}${compiled.stderr}',
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
