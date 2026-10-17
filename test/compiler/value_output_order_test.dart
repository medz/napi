import 'dart:io';

import 'package:napi/build.dart';
import 'package:test/test.dart';

const _source = '''
import 'dart:collection';
import 'package:napi/napi.dart';
int _reads = 0;
@NAPI() int reads() => _reads;
@NAPI() int reset() => _reads = 0;
@NAPI(classPolicy: ClassPolicy.value)
class Later {
  Later(this._throw);
  final bool _throw;
  int get value { _reads++; if (_throw) throw StateError('later getter'); return 3; }
}
@NAPI(classPolicy: ClassPolicy.value)
class Output {
  Output(bool throwing) : later = Later(throwing);
  final int bad = 9007199254740992;
  final Later later;
}
@NAPI() Output unsafe(bool throwing) => Output(throwing);
@NAPI() List<Output> list(bool throwing) => [Output(throwing)];
@NAPI() (Output, Later) record(bool throwing) => (Output(false), Later(throwing));
@NAPI() Dictionary<Output> dictionary(bool throwing) => Dictionary({'x': Output(throwing)});
@NAPI() class RefBase { int conflict([int value = 1]) => value; }
@NAPI() class RefChild extends RefBase {}
@NAPI() class RefOther { int conflict([int value = 2]) => value; }
class _Ambiguous extends RefBase implements RefOther {}
final _bad = _Ambiguous();
final _shared = RefChild();
final _fresh = RefChild();
@NAPI() RefChild child() => _shared;
@NAPI() RefChild freshChild() => _fresh;
@NAPI(classPolicy: ClassPolicy.value)
class ReferenceOutput {
  ReferenceOutput(bool throwing) : later = Later(throwing);
  final RefBase bad = _bad;
  final Later later;
}
@NAPI() ReferenceOutput reference(bool throwing) => ReferenceOutput(throwing);
@NAPI(classPolicy: ClassPolicy.value)
class MapOutput {
  MapOutput(bool throwing) : later = Later(throwing);
  final Map<double, int> bad = {double.nan: 1, double.nan: 2};
  final Later later;
}
@NAPI() MapOutput collision(bool throwing) => MapOutput(throwing);
@NAPI(classPolicy: ClassPolicy.value)
class RollbackOutput {
  final RefBase first = _fresh;
  final int bad = 9007199254740992;
  final Later later = Later(false);
}
@NAPI() RollbackOutput rollback() => RollbackOutput();
@NAPI() Dictionary<Later> duplicateDictionary() => Dictionary(_Duplicate());
class _Duplicate extends MapBase<String, Later> {
  int get length => 2;
  Iterable<MapEntry<String, Later>> get entries => [MapEntry('same', Later(false)), MapEntry('same', Later(false))];
  Iterable<String> get keys => const ['same', 'same'];
  Later? operator [](Object? key) => null;
  void operator []=(String key, Later value) => throw UnimplementedError();
  void clear() => throw UnimplementedError();
  Later? remove(Object? key) => throw UnimplementedError();
}
@NAPI() Later healthy() => Later(false);
''';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;
  final nativeRuntime = Platform.environment['NAPI_TEST_NATIVE_RUNTIME'];
  for (final target in BuildTarget.values) {
    test(
      '${target.name} value outputs finish Dart snapshots before host leaf checks',
      () async {
        final temporary = await Directory.systemTemp.createTemp(
          'napi-value-output-',
        );
        final directory = Directory(await temporary.resolveSymbolicLinks());
        addTearDown(() => directory.delete(recursive: true));
        final input = await File('${directory.path}/business.dart')
            .writeAsString(_source);
        final module = await buildLibrary(
          library: input.uri,
          output: Directory('${directory.path}/built'),
          packagesPath: packages,
          target: target,
          nativeRuntime: target == BuildTarget.native
              ? Directory(nativeRuntime!)
              : null,
        );
        final specifier = target == BuildTarget.wasm
            ? 'module.wasm'
            : 'module.mjs';
        final script = await File('${module.directory.path}/test.mjs')
            .writeAsString('''
import assert from 'node:assert/strict';
import * as api from './$specifier';
function fails(action, expected, reads) {
  api.reset();
  assert.throws(action, expected);
  assert.equal(api.reads(), reads);
  assert.deepEqual(api.healthy(), {value: 3});
}
const domain = error => error instanceof Error && error.constructor === Error && error.message.includes('later getter');
fails(() => api.unsafe(true), domain, 1);
fails(() => api.unsafe(false), RangeError, 1);
fails(() => api.list(true), domain, 1);
fails(() => api.list(false), RangeError, 1);
fails(() => api.record(true), domain, 2);
fails(() => api.record(false), RangeError, 2);
fails(() => api.dictionary(true), domain, 1);
fails(() => api.dictionary(false), RangeError, 1);
const child = api.child();
fails(() => api.reference(true), domain, 1);
fails(() => api.reference(false), TypeError, 1);
assert.equal(api.child(), child);
fails(() => api.collision(true), domain, 1);
fails(() => api.collision(false), error => error instanceof TypeError && error.message === 'collision result.bad[1].key: duplicate converted Map key', 1);
fails(() => api.duplicateDictionary(), error => error instanceof TypeError && error.message === 'duplicateDictionary result["same"]: duplicate Dictionary key', 0);
fails(() => api.rollback(), RangeError, 1);
assert(api.freshChild() instanceof api.RefChild);
assert.equal(api.child(), child);
console.log('value-output-order-ok');
''');
        final executed = await Process.run(
          Platform.environment['NODE'] ?? 'node',
          [script.path],
        );
        expect(
          executed.exitCode,
          0,
          reason: '${executed.stdout}${executed.stderr}',
        );
        expect(executed.stdout, contains('value-output-order-ok'));
      },
      skip: target == BuildTarget.native && nativeRuntime == null
          ? 'Set NAPI_TEST_NATIVE_RUNTIME to a precompiled runtime bundle.'
          : false,
      timeout: const Timeout(Duration(minutes: 2)),
    );
  }
}
