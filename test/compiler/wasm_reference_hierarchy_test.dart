import 'dart:convert';
import 'dart:io';

import 'package:napi/build.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/js/arguments.dart';
import 'package:napi/src/compiler/emit/js/boundary.dart';
import 'package:napi/src/compiler/emit/js/references.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:test/test.dart';

const _source = '''
import 'package:napi/napi.dart';
int _made = 0;
@NAPI() int made() => _made;
@NAPI() int add(int a, int b) => a + b;
@NAPI() class Base {
  Base([this.value = 0]) { _made++; }
  int value;
  int defaults([int value = 1]) => value;
  Base self() => this;
  static int baseOnly() => 11;
}
class _Middle extends Base {
  _Middle(super.value);
  @override int defaults([int value = 5]) => value;
}
@NAPI() abstract class View { View._(); int view(); }
@NAPI() class Child extends _Middle implements View {
  Child([int value = 0]) : super(value);
  @override int view() => value;
  @override int defaults([int value = 7]) => value;
}
@NAPI() class Getter extends Child {
  Getter([super.value]);
  @override int get value => super.value * 2;
}
@NAPI() class Setter extends Child {
  Setter([super.value]);
  @override set value(int next) => super.value = next + 1;
}
@NAPI() Base asBase(Child value) => value;
@NAPI() Child asChild(Base value) => value as Child;
@NAPI() View asView(View value) => value;
@NAPI() Base create(int value) => Child(value);
@NAPI() (Base, Child, View) views(Child value) => (value, value, value);
@NAPI() class Left { Left(); int left() => 1; }
@NAPI() class Right { Right(); int right() => 2; }
class _Hidden implements Left, Right {
  int left() => 1;
  int right() => 2;
}
@NAPI() class Both implements Left, Right {
  Both();
  int left() => 3;
  int right() => 4;
}
@NAPI() Left hidden() => _Hidden();
@NAPI() Left both() => Both();
@NAPI() class Factory {
  Factory._();
  factory Factory() => _factory;
  Factory self() => this;
}
@NAPI() class FactoryChild extends Factory {
  FactoryChild() : super._() { _made++; }
  int child() => 42;
}
final _factory = FactoryChild();
''';

void main() {
  test(
    'canonical cache hits and dead-wrapper adoption skip classification',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'napi-wasm-hierarchy-cache-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final input = await File('${directory.path}/business.dart')
          .writeAsString('''
import 'package:napi/napi.dart';
@NAPI() class Base { Base(); Base self() => this; }
@NAPI() class Child extends Base { Child(); }
''');
      final plan = lower(
        validate(
          await AnnotationFrontend(
            packagesPath: File('.dart_tool/package_config.json').absolute.path,
          ).read(input.uri),
        ),
      );
      final core = StringBuffer('''
export const reference = {classId: 1};
export const fresh = {classId: 1};
export const ambiguous = {classId: -1};
export let scans = 0;
const classify = reference => { scans++; return reference.classId; };
export {classify as 'napi:class:classify'};
''');
      for (final (index, call) in plan.calls.indexed) {
        core.writeln('''
const call$index = (...args) => ${call is MemberCallPlan && call.kind == MemberCallKind.constructor ? 'reference' : 'args[0]'};
export {call$index as ${jsonEncode(call.coreExportName)}};
''');
      }
      await File('${directory.path}/core.mjs').writeAsString(core.toString());
      await File('${directory.path}/calls.mjs').writeAsString(
        emitArgumentCalls(plan).replaceFirst('./core.wasm', './core.mjs'),
      );
      await File('${directory.path}/boundary.mjs')
          .writeAsString(emitBoundary(plan));
      await File('${directory.path}/references.mjs')
          .writeAsString(emitReferences());
      final script = await File('${directory.path}/test.mjs').writeAsString(r'''
import assert from 'node:assert/strict';
import {Base, Child} from './calls.mjs';
import {reference, fresh, ambiguous, scans} from './core.mjs';
import {readReference, writeReference} from './references.mjs';
const weak = (() => {
  const wrapper = new Base();
  assert(wrapper instanceof Child);
  assert(wrapper instanceof Base);
  assert.equal(scans, 1);
  assert.equal(new Base(), wrapper);
  assert.equal(new Child(), wrapper);
  assert.equal(wrapper.self(), wrapper);
  assert.equal(writeReference(reference, 0, 'Base output'), wrapper);
  assert.equal(writeReference(reference, 1, 'Child output'), wrapper);
  assert.equal(readReference(wrapper, 0, false, 'Base input'), reference);
  assert.equal(readReference(wrapper, 1, false, 'Child input'), reference);
  assert.equal(scans, 1, 'all live-wrapper views reuse the canonical ID');
  return new WeakRef(wrapper);
})();
for (let i = 0; i < 80; i++) {
  await new Promise(resolve => setImmediate(resolve));
  global.gc();
  if (weak.deref() === undefined) break;
}
assert.equal(weak.deref(), undefined, 'Dart-held raw reference does not root wrapper');
const pendingOld = new Set();
const adopted = writeReference(reference, 0, 'readopt', pendingOld);
assert(adopted instanceof Child);
assert.equal(scans, 1, 'dead-wrapper adoption reuses its canonical ID');
assert.equal(pendingOld.size, 0, 'an established canonical claim is not rolled back');
const pending = new Set();
const unexposed = writeReference(fresh, 0, 'fresh output', pending);
assert(unexposed instanceof Child);
assert.equal(scans, 2);
assert.equal(pending.size, 1);
for (const undo of pending) undo();
const recovered = writeReference(fresh, 1, 'recovery');
assert.notEqual(recovered, unexposed);
assert.equal(scans, 3, 'failed new claims are independently classified again');
for (const undo of pending) undo();
assert.equal(writeReference(fresh, 0, 'after stale rollback'), recovered);
assert.equal(scans, 3, 'stale rollback cannot erase the current claim');
assert.throws(() => writeReference(ambiguous, 0, 'bad output'), error =>
  error instanceof TypeError && error.message === 'bad output: no unique most-specific selected class');
''');
      final execution = await Process.run('node', ['--expose-gc', script.path]);
      expect(
        execution.exitCode,
        0,
        reason: '${execution.stdout}${execution.stderr}',
      );
    },
  );

  test(
    'Wasm canonical wrappers preserve memberships and constructor targets',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'napi-wasm-hierarchy-',
      );
      final directory = Directory(await temporary.resolveSymbolicLinks());
      addTearDown(() => directory.delete(recursive: true));
      final input = await File('${directory.path}/business.dart')
          .writeAsString(_source);
      final module = await buildLibrary(
        library: input.uri,
        output: Directory('${directory.path}/built'),
        packagesPath: File('.dart_tool/package_config.json').absolute.path,
      );
      final script = await File('${module.directory.path}/test.mjs')
          .writeAsString(r'''
import assert from 'node:assert/strict';
import * as api from './module.wasm';
import * as core from './core.wasm';
assert.equal(api.add, core.add, 'required scalar calls keep direct exports');
const child = api.create(9);
assert.equal(Object.getPrototypeOf(child), api.Child.prototype);
assert(child instanceof api.Base);
assert(child instanceof api.Child);
assert.equal(api.asBase(child), child);
assert.equal(api.asChild(child), child);
assert.equal(api.asView(child), child);
assert.equal(api.View.prototype.view.call(child), 9);
assert.deepEqual(api.views(child), {$1: child, $2: child, $3: child});
assert.equal(child.defaults(), 7);
assert.equal(api.Base.prototype.defaults.call(child), 1,
  'an inherited callback retains its selected declaration defaults');
assert.equal(Object.getPrototypeOf(api.Child.prototype), api.Base.prototype);
assert.equal(Object.getPrototypeOf(api.Child), Function.prototype,
  'selected static members are not inherited');
assert.equal(api.Child.baseOnly, undefined);
const getter = new api.Getter(3);
getter.value = 8;
assert.equal(getter.value, 16, 'overridden getter retains inherited setter');
const setter = new api.Setter(3);
setter.value = 8;
assert.equal(setter.value, 9, 'overridden setter retains inherited getter');
assert.throws(() => api.hidden(), error => error instanceof TypeError &&
  /no unique most-specific selected class/.test(error.message));
const both = api.both();
assert(both instanceof api.Both);
assert.equal(api.Left.prototype.left.call(both), 3);
assert.equal(api.Right.prototype.right.call(both), 4);
assert.equal(both.right(), 4);
assert.throws(() => api.Right.prototype.right.call(child), TypeError);
for (const invalid of [new Proxy(child, {}), Object.create(api.Child.prototype), {}, null]) {
  assert.throws(() => api.asBase(invalid), TypeError);
  assert.throws(() => api.Base.prototype.self.call(invalid), TypeError);
}
class JSChild extends api.Child {
  #first = 10;
  local() { return this.#first; }
  defaults(...args) { return super.defaults(...args) + this.#first; }
}
class JSGrandchild extends JSChild {
  #second = 20;
  total() { return this.local() + this.#second; }
}
const js = new JSGrandchild(5);
assert(js instanceof JSGrandchild);
assert.equal(js.total(), 30);
assert.equal(js.defaults(), 17);
assert.equal(js.self(), js);
assert.equal(api.asView(js), js);
function OtherTarget() {}
const other = Reflect.construct(api.Child, [13], OtherTarget);
assert.equal(Object.getPrototypeOf(other), OtherTarget.prototype);
assert.equal(api.Base.prototype.self.call(other), other);
assert.equal(api.Child.prototype.view.call(other), 13);
const before = api.made();
const factory = new api.Factory();
assert(factory instanceof api.FactoryChild);
assert(factory instanceof api.Factory);
assert.equal(factory.child(), 42);
assert.equal(new api.Factory(), factory, 'a live canonical wrapper wins');
assert.equal(factory.self(), factory);
assert.equal(api.made(), before + 1, 'adoption never repeats business construction');
for (const prototype of [api.Base.prototype, api.Child.prototype, api.Both.prototype]) {
  for (const name of Object.getOwnPropertyNames(prototype)) {
    if (name === 'constructor') continue;
    const descriptor = Object.getOwnPropertyDescriptor(prototype, name);
    for (const callable of [descriptor.value, descriptor.get, descriptor.set]) {
      if (typeof callable !== 'function') continue;
      assert.equal(Object.hasOwn(callable, 'prototype'), false);
      assert.throws(() => Reflect.construct(Object, [], callable), TypeError);
    }
    assert.equal(descriptor.enumerable, false);
    assert.equal(descriptor.configurable, true);
  }
}
''');
      final execution = await Process.run('node', [script.path]);
      expect(
        execution.exitCode,
        0,
        reason: '${execution.stdout}${execution.stderr}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
