import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/js/arguments.dart';
import 'package:napi/src/compiler/emit/js/boundary.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

final _packages = File('.dart_tool/package_config.json').absolute.path;

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-wasm-callback-');
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<ModulePlan> plan(String source) async {
    final input = File('${directory.path}/business.dart');
    await input.writeAsString(source);
    return lower(
      validate(
        await AnnotationFrontend(packagesPath: _packages).read(input.uri),
      ),
    );
  }

  test(
    'borrowed adapters compile both conversion directions and expiry',
    () async {
      final module = await plan('''
import 'package:napi/napi.dart';
@NAPI() int invoke(int Function(int) callback) => callback(2);
@NAPI() int optional([int Function(int)? callback]) => callback?.call(2) ?? 0;
@NAPI() BigInt wide(BigInt Function(BigInt) callback) => callback(BigInt.one);
@NAPI() (List<int>, {String label}) structured(
  (List<int>, {String label}) Function((List<int>, {String label})) callback,
) => callback(([1], label: 'a'));
@NAPI() int discard(void Function() callback) { callback(); return 0; }
@NAPI() Future<int> later() => Future.error(StateError('later'));
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  Resource();
  int apply(int Function(int) callback) => callback(2);
  void close() {}
}
''');
      final code = emitDart(module);
      expect(code, contains('final class _CallbackThrown'));
      expect(code, contains('if (error is _CallbackThrown)'));
      expect(code, contains('return _throwCallbackError(error.envelope)'));
      expect(
        code,
        contains('_rejectCallbackPromise(capability, error.envelope)'),
      );
      expect(code, contains('BigInt.parse((value as JSString).toDart)'));
      final calls = emitArgumentCalls(module);
      expect(calls, contains('finally { expireCallbacks(borrowed); }'));
      expect(
        calls,
        contains('expireCallbacks(borrowed); finishResourceCall(capability);'),
      );
      final boundary = emitBoundary(module);
      expect(boundary, contains('const callbackApply = Reflect.apply;'));
      expect(
        boundary,
        contains('catch (value) { return {threw: true, value}; }'),
      );
      final entry = File('${directory.path}/entrypoint.dart');
      await entry.writeAsString(code);
      final compiled = await DartSdkAdapter().compile(
        sourcePath: entry.path,
        outputPath: '${directory.path}/module.wasm',
        packagesPath: _packages,
      );
      expect(File(compiled.wasmPath).lengthSync(), greaterThan(0));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('ordinary modules have no callback state or exception checks', () async {
    final module = await plan('''
import 'package:napi/napi.dart';
@NAPI() int increment(int value) => value + 1;
''');
    expect(emitDart(module), isNot(contains('_CallbackThrown')));
    expect(emitArgumentCalls(module), isNot(contains('borrowed')));
    expect(emitBoundary(module), isNot(contains('callbackApply')));
  });
}
