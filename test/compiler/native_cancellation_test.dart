import 'dart:io';

import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/loader.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

void main() {
  test(
    'signal inputs compile across call forms with final admission guards',
    () async {
      final packages = File('.dart_tool/package_config.json').absolute.path;
      final directory = await Directory.systemTemp.createTemp('napi-signal-');
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/business.dart');
      await source.writeAsString('''
import 'package:napi/napi.dart';
typedef Cancellation = AbortSignal;
@NAPI() bool state(Cancellation signal, int Function() callback) => signal.aborted;
@NAPI() bool optional([AbortSignal? signal]) => signal?.aborted ?? false;
@NAPI() Future<int> work({required AbortSignal signal}) async => 42;
@NAPI() Stream<int> values(AbortSignal signal, AbortSignal? other) => Stream.value(42);
@NAPI() class Holder {
  AbortSignal _signal;
  Holder(this._signal);
  set signal(AbortSignal value) { _signal = value; }
  bool get aborted => _signal.aborted;
}
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  Resource();
  void close(AbortSignal signal) {}
}
''');
      final plan = validateNative(
        await AnnotationFrontend(
          packagesPath: packages,
          native: true,
        ).read(source.uri),
      );
      final generated = emitNativeDart(plan);
      expect(generated, contains("import 'package:napi/napi.dart' as napi;"));
      expect(generated, contains('Object? acceptCallback('));
      expect(generated, contains('a0?.throwIfAborted();'));
      expect(generated, contains('signals: [a0, if (a1 != null) a1]'));
      String callBody(String callback) {
        final start = generated.indexOf('int $callback(');
        expect(start, greaterThanOrEqualTo(0));
        final end = generated.indexOf('\n}', start);
        expect(end, greaterThan(start));
        return generated.substring(start, end + 2);
      }

      final state = plan.functions.singleWhere(
        (call) => call.exportName == 'state',
      );
      final stateBody = callBody(state.callback);
      expect(stateBody, contains('a1 = _readNativeCallback'));
      expect(
        stateBody.indexOf('a0.throwIfAborted();'),
        greaterThan(stateBody.indexOf('a1 = _readNativeCallback')),
      );
      expect(
        stateBody.indexOf('a0.throwIfAborted();'),
        lessThan(stateBody.indexOf('target.state(')),
      );
      final cleanup = plan.calls.singleWhere((call) => call.isCleanup);
      final cleanupBody = callBody(cleanup.callback);
      expect(cleanupBody, contains('a0.throwIfAborted();'));
      expect(
        cleanupBody.indexOf('a0.throwIfAborted();'),
        lessThan(cleanupBody.indexOf('_api.bindCleanupFuture(')),
      );
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

  test('signal-only loader installs owner delivery lazily', () {
    final ordinary = emitNativeLoader(['state']);
    expect(ordinary, isNot(contains('AbortSignal')));
    expect(ordinary, contains(r'$napiSharedBytesControl'));
    expect(ordinary, isNot(contains('target => deliver')));
    final signal = emitNativeLoader(['state'], hasSignals: true);
    expect(signal, contains('callback === null'));
    expect(signal, contains('target => deliver(target, false, undefined)'));
    expect(signal, contains('signal.arm(target)'));
    expect(signal, contains('signal.detach()'));
    expect(signal, isNot(contains(r'$napiCreatePromise')));
  });
}
