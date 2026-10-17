import 'dart:io';

import 'package:napi/src/build/build.dart';
import 'package:napi/src/compiler/emit/js/cancellation.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp(
      'napi-wasm-cancellation-',
    );
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<void> run(String source) async {
    await File('${directory.path}/check.mjs').writeAsString(source);
    final result = await Process.run('node', [
      '--expose-gc',
      'check.mjs',
    ], workingDirectory: directory.path);
    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
  }

  test(
    'signal registry survives replaced intrinsics and false abort events',
    () async {
      await File('${directory.path}/signals.mjs')
          .writeAsString('$cancellationPolicy\n$wasmCancellationPolicy');
      await run(r'''
import assert from 'node:assert/strict';
import {getEventListeners} from 'node:events';
import * as host from './signals.mjs';
const turn = () => new Promise(resolve => setImmediate(resolve));
const controller = new AbortController();
const token = {};
const notified = [];
const notify = value => notified.push(value);
const restores = [];
function replace(object, key) {
  const previous = Object.getOwnPropertyDescriptor(object, key);
  Object.defineProperty(object, key, {configurable: true, value() { throw Error('replaced ' + key); }});
  restores.push(() => {
    if (previous) Object.defineProperty(object, key, previous);
    else delete object[key];
  });
}
let companion;
try {
  for (const key of ['get', 'set']) replace(WeakMap.prototype, key);
  replace(WeakRef.prototype, 'deref');
  for (const key of ['register', 'unregister']) replace(FinalizationRegistry.prototype, key);
  for (const key of ['signal', 'notify', 'target', 'listener', 'adapter']) {
    const previous = Object.getOwnPropertyDescriptor(Object.prototype, key);
    Object.defineProperty(Object.prototype, key, {configurable: true, set() { throw Error('inherited ' + key); }});
    restores.push(() => {
      if (previous) Object.defineProperty(Object.prototype, key, previous);
      else delete Object.prototype[key];
    });
  }
  companion = host.readAbortSignal(controller.signal, notify);
  host.bindAbortSignal(companion, token);
  assert.equal(host.readAbortSignal(controller.signal, notify), companion);
  assert.equal(host.abortSignalTarget(companion), token);
  // Node's own Listener constructor assigns an inherited `listener` property;
  // limit this check to our companion's construction and adapter binding.
  for (let i = 0; i < 5; i++) restores.pop()();
  assert.equal(host.armAbortSignal(companion), null);
  controller.signal.dispatchEvent(new Event('abort'));
  await turn();
  assert.deepEqual(notified, []);
  controller.signal.dispatchEvent(new Event('abort'));
  controller.abort(null);
  assert.equal(host.abortSignalAborted(companion), 1);
  assert.equal(host.abortSignalReason(companion).value, null);
  await turn();
  assert.deepEqual(notified, [token]);
  host.detachAbortSignal(companion);
} finally { for (const restore of restores.reverse()) restore(); }
assert.equal(getEventListeners(controller.signal, 'abort').length, 0);
assert.throws(() => host.checkAbortSignal(new Proxy(new AbortController().signal, {}), false, 'signal'), TypeError);
const revivalSource = new AbortController();
const revival = host.readAbortSignal(revivalSource.signal, notify);
const previous = (() => {
  const token = {};
  host.bindAbortSignal(revival, token);
  host.armAbortSignal(revival);
  return new WeakRef(token);
})();
for (let i = 0; i < 80 && previous.deref() !== undefined; i++) {
  await turn(); global.gc(); await turn();
}
assert.equal(previous.deref(), undefined);
assert.equal(getEventListeners(revivalSource.signal, 'abort').length, 1);
const replacement = {};
host.bindAbortSignal(revival, replacement);
assert.equal(host.abortSignalTarget(revival), replacement);
assert.equal(getEventListeners(revivalSource.signal, 'abort').length, 0,
    'a replacement token has no inherited registration');
revivalSource.abort('no new registration');
await turn();
assert.deepEqual(notified, [token]);
''');
    },
  );

  test(
    'signal-only Wasm modules keep raw reasons and weak Dart token ownership',
    () async {
      final input = await File('${directory.path}/business.dart')
          .writeAsString('''
import 'dart:async';
import 'package:napi/napi.dart';
AbortSignal? saved;
WeakReference<AbortSignal>? weak;
int entered = 0;
int notified = 0;
List<int> allocation = [];
@NAPI() int entries() => entered;
@NAPI() int notifications() => notified;
@NAPI() bool same(AbortSignal first, AbortSignal second) => identical(first, second);
@NAPI() int keep(AbortSignal signal) { entered++; saved = signal; return 0; }
@NAPI() int drop() { saved = null; return 0; }
@NAPI() bool peek() => saved!.aborted;
@NAPI() int check() { saved!.throwIfAborted(); return 0; }
@NAPI() int observe(AbortSignal signal) {
  weak = WeakReference(signal);
  signal.onAbort(() { notified++; });
  return 0;
}
@NAPI() bool alive() => weak?.target != null;
@NAPI() int pressure(int seed) {
  allocation = List<int>.generate(100000, (i) => i + seed);
  return allocation.last;
}
@NAPI() Future<int> later(AbortSignal signal) async {
  entered++;
  await Future<void>.delayed(Duration(milliseconds: 1));
  signal.throwIfAborted();
  return 7;
}
@NAPI() Stream<int> events(AbortSignal signal) => StreamController<int>().stream;
''');
      await buildLibrary(
        library: input.uri,
        output: Directory('${directory.path}/module'),
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
      );
      await run(r'''
import assert from 'node:assert/strict';
import {getEventListeners} from 'node:events';
import * as api from './module/module.wasm';
const turn = () => new Promise(resolve => setImmediate(resolve));
const controller = new AbortController();
assert.equal(api.same(controller.signal, controller.signal), true);
api.keep(controller.signal);
api.observe(controller.signal);
for (let i = 0; i < 4; i++) {
  await turn(); global.gc(); api.pressure(i); await turn();
  assert.equal(api.alive(), true);
}
assert.equal(api.peek(), false);
controller.abort(null);
assert.equal(api.peek(), true);
assert.throws(() => api.check(), error => error === null);
assert.equal(api.notifications(), 0);
await turn();
assert.equal(api.notifications(), 1);
assert.equal(getEventListeners(controller.signal, 'abort').length, 0);
const count = api.entries();
assert.throws(() => api.keep(controller.signal), error => error === null);
const rejected = api.later(controller.signal);
assert(rejected instanceof Promise);
await assert.rejects(rejected, error => error === null);
assert.equal(api.entries(), count);
api.drop();

const live = new AbortController();
api.observe(live.signal);
for (let i = 0; i < 80 && (api.alive() || getEventListeners(live.signal, 'abort').length); i++) {
  await turn(); global.gc(); api.pressure(i); await turn();
}
assert.equal(api.alive(), false, 'JS signal alone must not retain Dart token');
assert.equal(getEventListeners(live.signal, 'abort').length, 0);
live.abort('no token');
await turn();
assert.equal(api.notifications(), 1);

for (const reason of [null, Symbol('reason'), Object.freeze({tag: 'same'})]) {
  const source = new AbortController();
  const work = api.later(source.signal);
  source.abort(reason);
  await assert.rejects(work, error => error === reason);
  const streamSource = new AbortController();
  const stream = api.events(streamSource.signal);
  const read = stream.next();
  streamSource.abort(reason);
  await assert.rejects(read, error => error === reason);
  assert.equal((await stream.next()).done, true);
}
''');
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
