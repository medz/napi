import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:test/test.dart';

void main() {
  test('Wasm value defaults admit resources before later fields', () async {
    final temporary = await Directory.systemTemp.createTemp(
      'napi-wasm-value-resource-defaults-',
    );
    addTearDown(() => temporary.delete(recursive: true));
    final models = [
      for (final (name, id) in [
        ('Direct', 1),
        ('Callback', 2),
        ('AsyncCallback', 3),
        ('Lazy', 4),
      ])
        '''
@NAPI(classPolicy: ClassPolicy.value)
class $name {
  final Resource resource;
  final int marker;
  $name({this.resource = const Resource($id), this.marker = 7});
}
''',
    ].join();
    final source = await File('${temporary.path}/business.dart')
        .writeAsString('''
import 'package:napi/napi.dart';
import 'dart:async';
final closed = <int, int>{};
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  final int id;
  const Resource(this.id);
  void close() { closed[id] = (closed[id] ?? 0) + 1; }
}
@NAPI() Resource resource(int id) => switch (id) {
  1 => const Resource(1), 2 => const Resource(2),
  3 => const Resource(3), _ => const Resource(4),
};
@NAPI() int closedCount(int id) => closed[id] ?? 0;
$models
@NAPI() int direct(Direct value) => value.marker;
@NAPI() int callback(Callback Function() callback) => callback().marker;
@NAPI() Future<int> asyncCallback(Future<AsyncCallback> Function() callback) async =>
    (await callback()).marker;
@NAPI() int lazy(JsArray<Lazy> values) => values.get(0)!.marker;
@NAPI() class Plain { final int id; const Plain(this.id); }
@NAPI(classPolicy: ClassPolicy.value)
class PlainValue { final Plain value; PlainValue({this.value = const Plain(7)}); }
@NAPI(classPolicy: ClassPolicy.value)
class DetachedCallback {
  final Resource resource;
  DetachedCallback({this.resource = const Resource(5)});
}
@NAPI(classPolicy: ClassPolicy.value)
class DetachedHandle {
  final Resource resource;
  DetachedHandle({this.resource = const Resource(6)});
}
int state = 0;
@NAPI() int detachedState() => state;
@NAPI() Resource detachedResource(bool handle) => handle ? const Resource(6) : const Resource(5);
@NAPI() void detached(
  PlainValue Function() plain, DetachedCallback Function() resource,
  JsArray<PlainValue> plainValues, JsArray<DetachedHandle> resourceValues,
) {
  Timer(Duration.zero, () {
    if (plain().value.id == 7 && plainValues.get(0)!.value.id == 7) state |= 1;
    try { resource(); } catch (_) { state |= 2; }
    try { resourceValues.get(0); } catch (_) { state |= 4; }
  });
}
''');
    await buildLibrary(
      library: source.uri,
      output: Directory('${temporary.path}/module'),
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
    );
    await File('${temporary.path}/check.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import * as api from './module/module.wasm';
async function verify(id, invoke) {
  const resource = api.resource(id);
  let closing;
  const input = new Proxy({marker: 7}, {
    getOwnPropertyDescriptor(target, key) {
      if (key === 'marker' && closing === undefined) {
        closing = resource.close();
        assert.equal(api.closedCount(id), 0, 'the earlier resource default is already admitted');
      }
      return Reflect.getOwnPropertyDescriptor(target, key);
    },
  });
  assert.equal(await invoke(input), 7);
  await closing;
  assert.equal(api.closedCount(id), 1);
}
await verify(1, value => api.direct(value));
await verify(2, value => api.callback(() => value));
await verify(3, value => api.asyncCallback(async () => value));
await verify(4, value => api.lazy([value]));
api.detached(() => ({}), () => ({}), [{}], [{}]);
for (let i = 0; i < 20 && api.detachedState() !== 7; i++) {
  await new Promise(resolve => setTimeout(resolve, 2));
}
assert.equal(api.detachedState(), 7, 'detached ordinary references work while resource defaults reject');
for (const handle of [false, true]) {
  await api.detachedResource(handle).close();
  assert.equal(api.closedCount(handle ? 6 : 5), 1);
}
''');
    final result = await Process.run('node', [
      'check.mjs',
    ], workingDirectory: temporary.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  }, timeout: const Timeout(Duration(minutes: 2)));
}
