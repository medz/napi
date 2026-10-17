import 'dart:convert';
import 'dart:io';

import 'package:napi/src/compiler/analysis/reference_views.dart';
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/js/reference_views.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:test/test.dart';

const _source = '''
import 'package:napi/napi.dart';
@NAPI() class Item {}
@NAPI() class Small extends Item {}
@NAPI() class Base {
  int choose([int value = 1]) => value;
  int get value => 1;
  set value(int next) {}
  int inherited() => 1;
}
@NAPI() class Child extends Base {
  @override int choose([int value = 7]) => value;
  @override int get value => 2;
}
@NAPI() class Seven { int choose([int value = 7]) => value; }
@NAPI() class One { int choose([int value = 1]) => value; }
@NAPI() class Two { int choose([int value = 2]) => value; }
@NAPI() class Read { int get value => 1; }
@NAPI() class Write { set value(int next) {} }
@NAPI() class Method { int value() => 1; }
@NAPI() class Renamed { @NAPI(name: 'value') int other() => 1; }
@NAPI() class ReadRenamed {
  @NAPI(name: 'value') int get other => 1;
}
@NAPI() class Narrow { Item accept(Small value) => value; }
@NAPI() class Broad { Small accept(Item value) => Small(); }
@NAPI() class Required { int choose(int value) => value; }
@NAPI() class Extra { int choose([int value = 7, int extra = 0]) => value; }
@NAPI() class Named { int choose({int value = 7}) => value; }
@NAPI() class NamedExtra {
  int choose({int value = 7, int extra = 0}) => value;
}
@NAPI() class NamedOther { int choose({int value = 8}) => value; }
@NAPI() class MovedOptions {
  int choose(int position, {int value = 7}) => value;
}
@NAPI() class Discard { void run() {} }
@NAPI() class Result { int run() => 1; }
@NAPI() class NullImplicit { int? call([int? value]) => value; }
@NAPI() class NullExplicit { int? call([int? value = null]) => value; }
@NAPI() class DoubleInt { double call([double value = 1]) => value; }
@NAPI() class DoubleOne { double call([double value = 1.0]) => value; }
@NAPI() class NaNOne { double call([double value = double.nan]) => value; }
@NAPI() class NaNTwo { double call([double value = 0.0 / 0.0]) => value; }
@NAPI() class Zero { double call([double value = 0.0]) => value; }
@NAPI() class MinusZero { double call([double value = -0.0]) => value; }
@NAPI() class StaticOnly { static int value() => 1; }
''';

void main() {
  late Directory temporary;
  setUp(() async {
    temporary = await Directory.systemTemp.createTemp('napi-reference-views-');
    addTearDown(() => temporary.delete(recursive: true));
  });

  Future<List<ReferenceClassShape>> read(String source) async {
    final file = File('${temporary.path}/entry.dart')
      ..writeAsStringSync(source);
    final module = await AnnotationFrontend(
      packagesPath: File('.dart_tool/package_config.json').absolute.path,
    ).read(file.uri);
    return validate(module).classes;
  }

  test(
    'contracts preserve defaults, presence and legal conversion variance',
    () async {
      final classes = await read(_source);
      final contracts = referenceViewContracts(classes);
      int contract(String name) {
        final shape = classes.singleWhere((c) => c.binding.exportName == name);
        return contracts.ids[(classId: shape.classId, memberIndex: 0)]!;
      }

      bool covers(String actual, String expected) =>
          contract(actual) == contract(expected) ||
          contracts.accepts[contract(actual)].contains(contract(expected));
      expect(contract('One'), contract('Base'));
      expect(contract('One'), isNot(contract('Two')));
      expect(covers('One', 'Two'), isFalse);
      expect(covers('Broad', 'Narrow'), isTrue);
      expect(covers('Narrow', 'Broad'), isFalse);
      expect(covers('Seven', 'Required'), isTrue);
      expect(covers('Required', 'Seven'), isFalse);
      expect(covers('Extra', 'Seven'), isTrue);
      expect(covers('Extra', 'One'), isFalse);
      expect(covers('NamedExtra', 'Named'), isTrue);
      expect(covers('NamedExtra', 'NamedOther'), isFalse);
      expect(covers('MovedOptions', 'Named'), isFalse);
      expect(covers('Result', 'Discard'), isTrue);
      expect(covers('Discard', 'Result'), isFalse);
      expect(contract('NullExplicit'), contract('NullImplicit'));
      expect(contract('DoubleInt'), contract('DoubleOne'));
      expect(contract('NaNOne'), contract('NaNTwo'));
      expect(contract('Zero'), isNot(contract('MinusZero')));
      expect(covers('Zero', 'MinusZero'), isFalse);
      expect(covers('Method', 'Renamed'), isFalse);
      expect(hasCompositeReferenceViews(classes), isTrue);
    },
  );

  test('generated resolver composes effective surfaces and caches only successes', () async {
    final classes = await read(_source);
    String callback(ReferenceMemberRef ref) =>
        'callback${ref.classId}_${ref.memberIndex}';
    final callbacks = StringBuffer();
    for (final shape in classes) {
      for (final (index, member) in shape.members.indexed) {
        if (member.isStatic) continue;
        final ref = (classId: shape.classId, memberIndex: index);
        callbacks.writeln(
          'const ${callback(ref)} = function() { return '
          '${jsonEncode('${shape.binding.exportName}.${member.kind.name}.${member.exportName}')}};',
        );
      }
    }
    final script = File('${temporary.path}/resolver.mjs');
    script.writeAsStringSync('''
import assert from 'node:assert/strict';
$callbacks
${emitCompositeReferencePrototypes(classes, callback)}
const ids = ${jsonEncode({for (final shape in classes) shape.binding.exportName: shape.classId})};
function resolve(...names) {
  return \$napiCompositePrototype(names.map(name => ids[name]), 'return.value');
}
${r'''
const combined = resolve('Base', 'Child', 'Seven', 'Read', 'Write');
assert.equal(Object.getPrototypeOf(combined), Object.prototype);
assert.equal(combined.constructor, Object);
assert.equal(Object.hasOwn(combined, 'constructor'), false);
assert.equal(combined.choose(), 'Child.method.choose');
assert.equal(combined.inherited(), 'Base.method.inherited');
assert.equal(combined.value, 'Child.getter.value');
assert.equal(Object.getOwnPropertyDescriptor(combined, 'value').set(), 'Base.setter.value');
assert.equal(resolve('Write', 'Read', 'Seven', 'Child', 'Base'), combined);
assert.equal(resolve('Child', 'Seven', 'Read', 'Write'), combined);
const halves = resolve('Read', 'Write');
assert.equal(halves.value, 'Read.getter.value');
assert.equal(Object.getOwnPropertyDescriptor(halves, 'value').set(), 'Write.setter.value');
assert.equal(resolve('Broad', 'Narrow').accept(), 'Broad.method.accept');
assert.equal(resolve('Required', 'Seven').choose(), 'Seven.method.choose');
assert.equal(resolve('Discard', 'Result').run(), 'Result.method.run');
assert.equal(resolve('Named', 'NamedExtra').choose(), 'NamedExtra.method.choose');
assert.equal(resolve('StaticOnly', 'Read').value, 'Read.getter.value');
for (const names of [
  ['One', 'Two'], ['Method', 'Read'], ['Method', 'Renamed'],
  ['ReadRenamed', 'Write'], ['Zero', 'MinusZero'], ['Child', 'One'],
  ['Named', 'NamedOther'], ['Named', 'MovedOptions'],
]) {
  assert.throws(() => resolve(...names), error =>
    error instanceof TypeError && error.message.startsWith('return.value:') &&
    /conflicting reference views/.test(error.message));
  assert.throws(() => $napiCompositePrototype(names.map(name => ids[name]), 'retry.path'),
    error => error instanceof TypeError && error.message.startsWith('retry.path:'));
}
assert.equal(resolve('Read', 'Write'), halves);
for (const name of Object.getOwnPropertyNames(combined)) {
  const descriptor = Object.getOwnPropertyDescriptor(combined, name);
  assert.equal(descriptor.enumerable, false);
  assert.equal(descriptor.configurable, true);
}
const poison = Object.getOwnPropertyDescriptor(Array.prototype, '0');
let failure;
let hits = 0;
Object.defineProperty(Array.prototype, '0', {
  configurable: true,
  get() { hits++; throw Error('inherited index getter'); },
  set() { hits++; throw Error('inherited index setter'); },
});
try { resolve('Zero', 'Read', 'Seven'); } catch (error) { failure = error; }
finally {
  if (poison) Object.defineProperty(Array.prototype, '0', poison);
  else delete Array.prototype[0];
}
assert.equal(failure, undefined);
assert.equal(hits, 0);
'''}
''');
    final run = await Process.run(Platform.environment['NODE'] ?? 'node', [
      script.path,
    ]);
    expect(run.exitCode, 0, reason: '${run.stdout}${run.stderr}');
  });

  test(
    'equal contracts intern without pairwise output and inherited copies',
    () async {
      final classes = await read('''
import 'package:napi/napi.dart';
${List.generate(40, (i) => '@NAPI() class View$i { int run([int value = 1]) => value; }').join('\n')}
@NAPI() class Child extends View0 {}
@NAPI() class GrandChild extends Child {}
''');
      final contracts = referenceViewContracts(classes);
      expect(contracts.ids.length, 40);
      expect(contracts.ids.values.toSet(), {0});
      expect(contracts.accepts, [isEmpty]);
      expect(classes.last.prototypeProperties, isEmpty);
      expect(classes[classes.length - 2].prototypeProperties, isEmpty);
      expect(hasCompositeReferenceViews(classes), isTrue);
      expect(
        hasCompositeReferenceViews([
          classes.first,
          classes[classes.length - 2],
          classes.last,
        ]),
        isFalse,
      );
    },
  );
}
