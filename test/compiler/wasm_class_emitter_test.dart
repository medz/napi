import 'dart:convert';
import 'dart:io';

import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/js/arguments.dart';
import 'package:napi/src/compiler/emit/js/boundary.dart';
import 'package:napi/src/compiler/emit/js/references.dart';
import 'package:napi/src/compiler/emit/typescript/declarations.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:test/test.dart';

const _source = '''
import 'package:napi/napi.dart';
@NAPI() int direct(int value) => value;
@NAPI() List<int> structure(List<int> value) => value;
@NAPI() int optional([int value = 42]) => value;
@NAPI(name: 'Counter')
class DartCounter {
  DartCounter({int initial = 0});
  int value = 0;
  final String label = 'counter';
  int add(int amount) => amount;
  int increment([int amount = 1]) => amount;
  int named({required int amount, int extra = 2}) => amount + extra;
  void clear() {}
  void get empty {}
  static int total = 0;
  static int sum(int left, int right) => left + right;
}
@NAPI()
class Other { Other(int initial); int get value => 4; }
@NAPI()
class Named {
  Named();
  static int name() => 1;
  @NAPI(name: 'constructor') static int make() => 1;
}
''';

void main() {
  late Directory directory;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-wasm-class-js-');
    addTearDown(() => directory.delete(recursive: true));
  });

  Future<ModulePlan> plan(String source) async {
    final input = File('${directory.path}/business.dart');
    await input.writeAsString(source);
    return lower(
      validate(
        await AnnotationFrontend(
          packagesPath: File('.dart_tool/package_config.json').absolute.path,
        ).read(input.uri),
      ),
    );
  }

  // This substitutes only the core dependency to isolate the generated JS
  // contract. Source-to-Wasm integration separately exercises actual Dart.
  Future<void> javascript(ModulePlan plan, String check) async {
    final core = StringBuffer('export const history = [];\n');
    core.writeln('''
const classify = reference => reference.classId;
export {classify as 'napi:class:classify'};
''');
    for (final (index, call) in plan.calls.indexed) {
      final constructor =
          call is MemberCallPlan && call.kind == MemberCallKind.constructor;
      final classId = call is MemberCallPlan
          ? plan.classes.indexWhere(
              (c) => c.binding.declaration == call.owner.declaration,
            )
          : -1;
      core.writeln('''
const call$index = (...args) => {
  const result = {classId: $classId};
  history.push({name: ${jsonEncode(call.coreExportName)}, args, result});
  return ${constructor ? 'result' : 'null'};
};
export {call$index as ${jsonEncode(call.coreExportName)}};
''');
    }
    for (final child in ['', '/independent']) {
      final output = await Directory('${directory.path}$child').create();
      await File('${output.path}/core.mjs').writeAsString(core.toString());
      await File('${output.path}/references.mjs')
          .writeAsString(emitReferences());
      await File('${output.path}/boundary.mjs')
          .writeAsString(emitBoundary(plan));
      await File('${output.path}/calls.mjs').writeAsString(
        emitArgumentCalls(plan).replaceFirst('./core.wasm', './core.mjs'),
      );
    }
    await File('${directory.path}/test.mjs').writeAsString(check);
    final execution = await Process.run('node', [
      'test.mjs',
    ], workingDirectory: directory.path);
    expect(
      execution.exitCode,
      0,
      reason: '${execution.stdout}${execution.stderr}',
    );
  }

  test(
    'class callables retain references and reject unbranded receivers',
    () async {
      final module = await plan(_source);
      await javascript(module, r'''
import assert from 'node:assert/strict';
import {Counter, Other, Named, optional} from './calls.mjs';
import {Counter as IndependentCounter} from './independent/calls.mjs';
import {history} from './core.mjs';
assert.equal(Counter.name, 'Counter');
assert.equal(Counter.length, 0);
assert.equal(Other.length, 1);
assert.equal(typeof Named.name, 'function', 'business static name is preserved');
assert.equal(typeof Named.constructor, 'function');
assert.equal(Counter.prototype.add.length, 1);
assert.equal(Counter.prototype.increment.length, 0);
assert.equal(Counter.prototype.named.length, 0);
assert.equal(Counter.sum.length, 2);
const descriptor = Object.getOwnPropertyDescriptor(Counter.prototype, 'value');
assert.equal(descriptor.get.length, 0);
assert.equal(descriptor.set.length, 1);
const total = Object.getOwnPropertyDescriptor(Counter, 'total');
assert.equal(total.get.length, 0);
assert.equal(total.set.length, 1);
assert.equal(Object.getOwnPropertyDescriptor(Counter.prototype, 'label').set, undefined);
assert.throws(() => Counter(), TypeError);
assert.throws(() => new Other(), TypeError);
const one = new Counter();
const reference = history.at(-1).result;
assert.deepEqual(history.at(-1).args, [1, undefined]);
assert.deepEqual(Reflect.ownKeys(one), [], 'Dart reference is private');
one.increment();
assert.deepEqual(history.at(-1).args, [reference, 1, undefined]);
one.increment(undefined);
assert.deepEqual(history.at(-1).args, [reference, 1, undefined]);
one.increment(0);
assert.deepEqual(history.at(-1).args, [reference, 0, 0]);
one.add(3, 99);
assert.deepEqual(history.at(-1).args, [reference, 3]);
one.named({amount: 2});
assert.deepEqual(history.at(-1).args, [reference, 2, 1, undefined]);
one.named(Object.assign(Object.create(null), {amount: 3, extra: undefined}));
assert.deepEqual(history.at(-1).args, [reference, 3, 1, undefined]);
assert.equal(descriptor.set.call(one, 8), undefined);
assert.deepEqual(history.at(-1).args, [reference, 8]);
descriptor.get.call(one);
assert.deepEqual(history.at(-1).args, [reference]);
Counter.sum(2, 3);
assert.deepEqual(history.at(-1).args, [2, 3]);
assert.equal(total.set.call(Counter, 5), undefined);
assert.deepEqual(history.at(-1).args, [5]);
total.get.call(Counter);
assert.deepEqual(history.at(-1).args, []);
assert.equal(one.clear(), undefined, 'void discards the private core ABI result');
assert.equal(one.empty, undefined, 'void getter discards the private core ABI result');
optional();
assert.deepEqual(history.at(-1).args, [1, undefined]);
const beforeInvalid = history.length;
let reads = 0;
for (const options of [null, [], {unknown: 1}, {}, {amount: undefined},
  {get amount() { reads++; return 1; }}, {amount: 1, get extra() { reads++; return 2; }}]) {
  assert.throws(() => one.named(options), TypeError);
}
const foreign = new IndependentCounter();
const other = new Other(4);
const revoked = Proxy.revocable(one, {});
revoked.revoke();
const receivers = [{}, Object.create(Counter.prototype), other, foreign,
  new Proxy(one, {}), revoked.proxy, Reflect.construct(Object, [], Counter),
  null, undefined, 1, false, 'text', Symbol('brand'), () => {}];
const beforeBrands = history.length;
for (const receiver of receivers) {
  assert.throws(() => Counter.prototype.named.call(receiver, {get amount() { reads++; }}), TypeError);
  assert.throws(() => descriptor.get.call(receiver), TypeError);
  assert.throws(() => descriptor.set.call(receiver, 1), TypeError);
}
assert.equal(reads, 0);
assert.equal(history.length, beforeBrands);
assert.equal(beforeBrands, beforeInvalid + 1, 'only valid Other constructor entered this core');
assert.throws(() => new one.add(1), TypeError);
assert.throws(() => new Counter.sum(1, 2), TypeError);
assert.throws(() => new descriptor.get(), TypeError);
assert.throws(() => new descriptor.set(1), TypeError);
class Subclass extends Counter {}
const sub = new Subclass();
sub.add(9);
assert.equal(history.at(-1).args[1], 9);
one.add(7);
assert.deepEqual(history.at(-1).args, [reference, 7], 'invalid calls did not alter the retained reference');
''');
      final types = emitDeclarations(module);
      expect(types, contains('export declare function direct(value: number)'));
      expect(types, contains('export declare class Counter {'));
      expect(
        types,
        contains('constructor(options?: { initial?: number | undefined });'),
      );
      expect(types, contains('increment(amount?: number): number;'));
      expect(types, contains('get value(): number;'));
      expect(types, contains('set value(value: number);'));
      expect(types, contains('clear(): void;'));
      expect(types, contains('get empty(): void;'));
      expect(types, contains('static get total(): number;'));
      expect(types, contains('static set total(value: number);'));
      expect(types, contains('static ["constructor"](): number;'));
    },
  );

  test(
    'class-only modules supply argument helpers and aligned contexts',
    () async {
      final module = await plan('''
import 'package:napi/napi.dart';
@NAPI() class Counter {
  Counter({int initial = 0});
  int named({required bool enabled, String label = 'ok'}) => 1;
}
''');
      final call = module.classes.single.members.single;
      final input = call.inputContexts.first;
      final output = call.outputContext!;
      await javascript(module, '''
import assert from 'node:assert/strict';
import {Counter} from './calls.mjs';
import {readValue, writeValue} from './boundary.mjs';
new Counter().named({enabled: true});
assert.equal(readValue(true, $input), true);
assert.throws(() => readValue(1, $input), error => error instanceof TypeError && error.message.startsWith('Counter.named.enabled:'));
assert.equal(writeValue(2, $output), 2);
assert.throws(() => writeValue(1.5, $output), error => error instanceof RangeError && error.message.startsWith('Counter.named result:'));
''');
    },
  );
}
