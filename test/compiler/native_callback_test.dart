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
}
