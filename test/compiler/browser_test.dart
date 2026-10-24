import 'dart:convert';
import 'dart:io';

import 'package:napi/build.dart';
import 'package:test/test.dart';

import '../support/commands.dart' show typescript;
import '../support/process.dart';

void main() {
  final configured = Platform.environment['NAPI_TEST_BROWSER'];
  final browser =
      configured ??
      (Platform.isMacOS
          ? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'
          : '/usr/bin/google-chrome');
  test(
    'browser ESM loads the shared Wasm with normal imports',
    () async {
      final temp = Directory(await Directory.systemTemp.resolveSymbolicLinks());
      final root = await temp.createTemp('napi-browser-');
      HttpServer? server;
      try {
        final output = await buildPackage(
          library: File('test/fixtures/browser.dart').absolute.uri,
          packagesPath: File('.dart_tool/package_config.json').absolute.path,
          output: Directory('${root.path}/bindings'),
          metadata: {'name': '@napi/browser-test', 'version': '0.0.0'},
        );
        final package = jsonDecode(
          await File('${output.path}/package.json').readAsString(),
        ) as Map;
        expect(package['exports']['./browser'], {
          'types': './browser.d.mts',
          'import': './browser.mjs',
        });
        final wasm = await output
            .list()
            .where((file) => file.path.endsWith('.wasm'))
            .toList();
        expect(wasm.map((file) => file.uri.pathSegments.last).toSet(), {
          'core.wasm',
          'module.wasm',
        });
        for (final name in (package['files'] as List).whereType<String>().where(
          (name) => name.startsWith('browser-') && name.endsWith('.mjs'),
        )) {
          final text = await File('${output.path}/$name').readAsString();
          expect(text, isNot(contains('node:')), reason: name);
          expect(text, isNot(contains("from './core.wasm'")), reason: name);
        }
        final scalar = File('${root.path}/scalar.dart');
        await scalar.writeAsString('''
import 'package:napi/napi.dart';
@NAPI() int add(int left, int right) => left + right;
''');
        await buildPackage(
          library: scalar.uri,
          packagesPath: File('.dart_tool/package_config.json').absolute.path,
          output: Directory('${root.path}/scalar'),
          metadata: {'name': '@napi/browser-scalar-test', 'version': '0.0.0'},
        );
        await File('${root.path}/consumer.mts').writeAsString(_consumer);
        await typescript(root, 'consumer.mts');
        await File('${root.path}/index.html').writeAsString(_page);
        final requests = <String>[];
        server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        server.listen((request) async {
          requests.add(request.uri.path);
          final name = request.uri.path == '/'
              ? '/index.html'
              : request.uri.path;
          final file = File('${root.path}$name');
          if (!await file.exists()) {
            request.response.statusCode = 404;
          } else {
            request.response.headers.contentType = ContentType.parse(
              name.endsWith('.wasm')
                  ? 'application/wasm'
                  : name.endsWith('.mjs')
                  ? 'text/javascript'
                  : 'text/html',
            );
            request.response.add(await file.readAsBytes());
          }
          await request.response.close();
        });
        final version = await runProcess(browser, [
          '--version',
        ], timeout: const Duration(seconds: 10));
        stdout.write(version.stdout);
        final result = await runProcess(browser, [
          '--headless=new',
          '--no-first-run',
          '--no-default-browser-check',
          '--disable-background-networking',
          '--disable-extensions',
          '--user-data-dir=${root.path}/profile',
          '--timeout=30000',
          '--virtual-time-budget=10000',
          '--dump-dom',
          'http://127.0.0.1:${server.port}/',
        ], timeout: const Duration(seconds: 45));
        expect(result.exitCode, 0, reason: result.stderr.toString());
        expect(
          result.stdout,
          contains('data-result="passed"'),
          reason: result.stdout.toString(),
        );
        expect(requests.where((name) => name.endsWith('.wasm')).toList(), [
          '/bindings/core.wasm',
          '/scalar/module.wasm',
        ]);
        expect(requests, isNot(contains('/bindings/module.wasm')));
      } finally {
        await server?.close(force: true);
        await root.delete(recursive: true);
      }
    },
    skip: configured == null && !File(browser).existsSync()
        ? 'Set NAPI_TEST_BROWSER to a Chrome executable.'
        : false,
    timeout: const Timeout(Duration(minutes: 3)),
  );
}

const _page =
    r'''<!doctype html><html><body data-result="pending"><script type="module">
try {
  const api = await import('./bindings/browser.mjs');
  const again = await import('./bindings/browser.mjs');
  const scalar = await import('./scalar/browser.mjs');
  function equal(actual, expected) { if (!Object.is(actual, expected)) throw new Error('Expected ' + expected + ', got ' + actual); }
  function fails(action, text) { try { action(); } catch (error) { if (String(error).includes(text)) return; throw error; } throw new Error('Expected failure: ' + text); }
  async function rejects(promise, matches) {
    try { await promise; }
    catch (error) { if (matches(error)) return; throw new Error('Unexpected rejection: ' + String(error)); }
    throw new Error('Expected rejection');
  }
  equal(scalar.add(2, 3), 5);
  equal(api.Counter, again.Counter);
  const counter = new api.Counter(2);
  equal(counter.increment(), 3);
  equal(counter.increment({by: 2}), 5);
  equal(counter.self(), counter);
  equal(await counter.later(), 5);
  equal(api.identity(undefined), undefined);
  equal(api.identity(null), null);
  equal(api.callback(3, value => value + 2), 5);
  equal(await api.asyncCallback(async () => 9), 9);
  let fakeThenCalls = 0;
  await rejects(api.asyncCallback(() => ({then() { fakeThenCalls++; }})), error => error instanceof TypeError);
  equal(fakeThenCalls, 0);
  for (const reason of [new TypeError('species'), Symbol('species'), null, undefined]) {
    const promise = Promise.resolve(9);
    Object.defineProperty(promise, 'constructor', {value: {
      get [Symbol.species]() { throw reason; },
    }});
    await rejects(api.asyncCallback(() => promise), error => Object.is(error, reason));
  }
  equal(api.numbers([1, 2]).join(','), '1,2');
  equal(api.counts(new Map([['count', 7]])).get('count'), 7);
  const bytes = new Uint8Array([1, 2, 3]);
  const copied = api.bytes(bytes.subarray(1));
  equal(copied.join(','), '2,3'); copied[0] = 9; equal(bytes[1], 2);
  equal(new Uint8Array(api.buffer(bytes.buffer)).join(','), '1,2,3');
  equal(api.shared(bytes), 2); equal(bytes[0], 2);
  equal(api.mapValue(new Map([['count', 11]])), 11);
  fails(() => api.arrayLength([]), 'JsArray');
  fails(() => new api.Resource(), 'Resource');
  fails(() => api.resourceAsCounter(), 'Resource');
  const originalSetHas = Set.prototype.has;
  const originalApply = Reflect.apply;
  try {
    Set.prototype.has = () => false;
    Reflect.apply = () => false;
    fails(() => new api.Resource(), 'Resource');
    fails(() => api.resourceAsCounter(), 'Resource');
  } finally {
    Set.prototype.has = originalSetHas;
    Reflect.apply = originalApply;
  }
  const frame = document.createElement('iframe');
  document.body.append(frame);
  const foreign = frame.contentWindow;
  const foreignBytes = new foreign.Uint8Array([4, 5, 6]);
  const foreignMap = new foreign.Map([['count', 12]]);
  equal(api.bytes(foreignBytes.subarray(1)).join(','), '5,6');
  equal(new Uint8Array(api.buffer(foreignBytes.buffer)).join(','), '4,5,6');
  equal(api.shared(foreignBytes), 5);
  equal(foreignBytes[0], 5);
  equal(api.counts(foreignMap).get('count'), 12);
  equal(api.mapValue(foreignMap), 12);
  let traps = 0;
  const handler = {
    get() { traps++; throw new Error('proxy get'); },
    getPrototypeOf() { traps++; throw new Error('proxy prototype'); },
    ownKeys() { traps++; throw new Error('proxy keys'); },
    getOwnPropertyDescriptor() { traps++; throw new Error('proxy descriptor'); },
  };
  fails(() => api.bytes(new Proxy(foreignBytes, handler)), 'Uint8Array');
  fails(() => api.shared(new Proxy(foreignBytes, handler)), 'Uint8Array');
  fails(() => api.buffer(new Proxy(foreignBytes.buffer, handler)), 'ArrayBuffer');
  fails(() => api.counts(new Proxy(foreignMap, handler)), 'Map');
  fails(() => api.mapValue(new Proxy(foreignMap, handler)), 'Map');
  equal(traps, 0);
  frame.remove();
  let reads = 0;
  const value = {get then() { reads++; return reads === 1 ? undefined : resolve => resolve('changed'); }};
  equal(await api.later(value), value); equal(reads, 1);
  await rejects(api.canceled(new Proxy(new AbortController().signal, handler)), error => error instanceof TypeError);
  equal(traps, 0);
  const controller = new AbortController();
  controller.signal.addEventListener('abort', event => event.stopImmediatePropagation());
  const reason = {canceled: true};
  const canceled = api.canceled(controller.signal).catch(error => error);
  controller.signal.dispatchEvent(new Event('abort'));
  controller.abort(reason);
  equal(await canceled, reason);
  const values = [];
  for await (const value of api.sequence()) values.push(value);
  equal(values.join(','), '1,2');
  document.body.dataset.result = 'passed';
} catch (error) {
  document.body.dataset.result = 'failed';
  document.body.append(String(error.stack ?? error));
}
</script></body></html>''';

const _consumer = r'''
import {
  Counter, identity, later, callback, asyncCallback, numbers, counts,
  bytes, buffer, shared, mapValue, canceled, sequence,
} from './bindings/browser.mjs';
import {add} from './scalar/browser.mjs';
const counter: Counter = new Counter(2);
const count: number = counter.increment({by: 3});
const same: Counter = counter.self();
const delayed: Promise<number> = counter.later();
const opaque: {value: number} = identity({value: 1});
const future: Promise<number> = later(2);
const called: number = callback(3, value => value + 1);
const asynchronous: Promise<number> = asyncCallback(async () => 9);
const values: number[] = numbers([1, 2]);
const mapped: Map<string, number> = counts(new Map([['count', 3]]));
const copied: Uint8Array<ArrayBuffer> = bytes(new Uint8Array([1, 2]));
const raw: ArrayBuffer = buffer(new ArrayBuffer(2));
const changed: number = shared(new Uint8Array([1]));
const selected: number = mapValue(new Map([['count', 4]]));
const cancellation: Promise<number> = canceled(new AbortController().signal);
const stream: AsyncIterableIterator<number, undefined, undefined> = sequence();
const sum: number = add(1, 2);
// @ts-expect-error Counter options preserve the Dart integer input.
counter.increment({by: '3'});
// @ts-expect-error Future callbacks must return an actual Promise.
asyncCallback(() => 9);
// @ts-expect-error Callback parameters preserve their declared type.
callback(1, (value: string) => value.length);
// @ts-expect-error Byte inputs require Uint8Array.
bytes(new Uint16Array(2));
// @ts-expect-error Map values preserve their declared type.
counts(new Map([['count', '3']]));
// @ts-expect-error Cancellation requires a real AbortSignal interface.
canceled({aborted: false});
// @ts-expect-error Scalar-only bindings have the same strict declarations.
add(1, '2');
void [count, same, delayed, opaque, future, called, asynchronous, values,
  mapped, copied, raw, changed, selected, cancellation, stream, sum];
''';
