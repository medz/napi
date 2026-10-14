import 'dart:io';

import 'package:napi/src/compiler/emit/dart/emitter.dart';
import 'package:napi/src/compiler/emit/js/emitter.dart';
import 'package:napi/src/compiler/emit/typescript/emitter.dart';
import 'package:napi/src/compiler/front_end/fixture_frontend.dart';
import 'package:napi/src/compiler/lowering/lower.dart';
import 'package:napi/src/compiler/ir/binding.dart';
import 'package:napi/src/compiler/lowering/plans.dart';
import 'package:test/test.dart';

void main() {
  final emitters = <String, String Function(ModulePlan)>{
    'dart': emitDart,
    'js': emitJavaScript,
    'typescript': emitTypeScript,
  };
  for (final entry in emitters.entries) {
    test('${entry.key} full-source golden from analyzer-independent IR', () {
      final plan = lowerModule(_syntheticAddModule());
      final expected = File('test/fixtures/goldens/add.${entry.key}.txt')
          .readAsStringSync();
      expect(entry.value(plan), equals(expected));
    });
  }

  test('three specialized outputs consume one lowered module', () async {
    final module = await FixtureFrontend().resolve(
      path: File('test/fixtures/primitives.dart').absolute.path,
      functionNames: ['add', 'echoString', 'accept', 'api', r'$echo'],
    );
    final plan = lowerModule(module);
    final dart = emitDart(plan);
    final js = emitJavaScript(plan);
    final ts = emitTypeScript(plan);
    expect(dart, contains('source.add(a0.toDartInt, a1.toDartInt)'));
    expect(dart, contains('runtime.checkedIntOutput'));
    expect(dart, contains(r'\$echo return value'));
    expect(dart, contains('@JSExport()'));
    expect(dart, isNot(contains('dart:_')));
    expect(js, contains('Number.isSafeInteger(a0)'));
    expect(js, contains('const api = await initialize();'));
    expect(js, contains('export { __napiCall3 as api };'));
    expect(js, isNot(contains('export function api')));
    expect(ts, contains('add(a0: number, a1: number): number;'));
    expect(ts, contains('echoString(a0: string): string;'));
    expect(ts, contains('accept(a0: string): void;'));
    expect(emitDart(plan), dart);
    expect(emitJavaScript(plan), js);
    expect(emitTypeScript(plan), ts);
  });
}

// This fixture bypasses parsing/resolution so emitter regressions are isolated
// from frontend behavior. Paths and source spans are deliberately fixed.
BindingModule _syntheticAddModule() {
  final uri = Uri.parse('package:fixture/math.dart');
  final source = SourceSpan(
    uri: uri,
    offset: 0,
    length: 44,
    line: 1,
    column: 1,
  );
  const integer = PrimitiveTypePolicy(PrimitiveKind.integer);
  return BindingModule(
    sourceUri: uri,
    functions: [
      FunctionBinding(
        identity: DeclarationIdentity(libraryUri: uri, name: 'add'),
        source: source,
        dartName: 'add',
        publicName: 'add',
        parameters: [
          ParameterBinding(name: 'left', type: integer, source: source),
          ParameterBinding(name: 'right', type: integer, source: source),
        ],
        returnType: integer,
      ),
    ],
  );
}
