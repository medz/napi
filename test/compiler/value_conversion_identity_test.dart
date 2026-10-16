import 'dart:io';

import 'package:napi/napi.dart' show ClassPolicy, NAPI;
import 'package:napi/src/compiler/analysis/validate.dart';
import 'package:napi/src/compiler/emit/dart/entrypoint.dart';
import 'package:napi/src/compiler/emit/js/arguments.dart';
import 'package:napi/src/compiler/emit/js/boundary.dart';
import 'package:napi/src/compiler/emit/js/references.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:napi/src/compiler/linker/dart_module_linker.dart';
import 'package:napi/src/compiler/lowering/plan.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:napi/src/compiler/sdk_adapter/dart_sdk_adapter.dart';
import 'package:test/test.dart';

const _source = '''
import 'dart:core' as core;
import 'package:napi/napi.dart';
@NAPI(name: 'PublicList') class List {
  List(this.value);
  core.int value;
  List self() => this;
}
@NAPI() List identity(List value) => value;
@NAPI() core.List<core.int> integers(core.List<core.int> value) => value;
@NAPI() core.List<List> nested(core.List<List> value) => value;
''';
const _selection = ExternalLibrary([
  ExternalClass('List', config: NAPI(name: 'PublicList')),
  ExternalFunction('identity'),
  ExternalFunction('integers'),
  ExternalFunction('nested'),
]);

DeclaredType _list(BindingType element) => DeclaredType(
  DeclarationId(
    Uri.parse('dart:core'),
    'List',
    kind: DeclarationKind.classType,
  ),
  ValueSemantics.structural,
  typeArguments: [element],
);

void main() {
  late Directory directory;
  late File input;
  final packages = File('.dart_tool/package_config.json').absolute.path;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('napi-list-identity-');
    addTearDown(() => directory.delete(recursive: true));
    input = await File('${directory.path}/business.dart')
        .writeAsString(_source);
  });

  for (final external in [false, true]) {
    test(
      '${external ? 'external' : 'annotation'} List class is a reference on both plans',
      () async {
        final frontend = external
            ? ExternalFrontend(_selection, packagesPath: packages)
            : AnnotationFrontend(packagesPath: packages);
        final module = await frontend.read(input.uri);
        final wasm = lower(validate(module));
        final identity = wasm.functions.singleWhere(
          (f) => f.binding.exportName == 'identity',
        );
        expect(identity.inputs.single, isA<ReferenceConversion>());
        expect(identity.output, isA<ReferenceConversion>());
        expect(identity.representation, ExportRepresentation.callableGlobal);
        final conversion = identity.output as ReferenceConversion;
        expect(conversion.classBinding.declaration.name, 'List');
        expect(conversion.dartType, 'target.List');
        expect(conversion.typescriptType, 'PublicList');
        expect(
          wasm.classes.single.members
              .singleWhere((m) => m.exportName == 'self')
              .output,
          isA<ReferenceConversion>(),
        );
        final integers = wasm.functions.singleWhere(
          (f) => f.binding.exportName == 'integers',
        );
        expect(integers.inputs.single, isA<ListConversion>());
        expect(integers.output, isA<ListConversion>());
        final nativeFrontend = external
            ? ExternalFrontend(_selection, packagesPath: packages, native: true)
            : AnnotationFrontend(packagesPath: packages, native: true);
        final nativeModule = await nativeFrontend.read(input.uri);
        final native = validateNative(nativeModule);
        final nativeIdentity = native.functions.singleWhere(
          (f) => f.exportName == 'identity',
        );
        final nested = wasm.functions.singleWhere(
          (f) => f.binding.exportName == 'nested',
        );
        expect(
          (nested.inputs.single as ListConversion).element,
          isA<ReferenceConversion>(),
        );
        final nativeNested = native.functions.singleWhere(
          (f) => f.exportName == 'nested',
        );
        expect(
          (nativeNested.inputs.single as ListConversion).element,
          isA<ReferenceConversion>(),
        );
        expect(nativeIdentity.inputs.single, isA<ReferenceConversion>());
        expect(nativeIdentity.output, isA<ReferenceConversion>());
        expect(
          native.classes.single.members
              .singleWhere((m) => m.exportName == 'self')
              .output,
          isA<ReferenceConversion>(),
        );
      },
    );
  }

  test('shared result validation allows nested selected refs and rejects unknown leaves', () {
    final source = SourceLocation(input.uri, 0, 1);
    final owner = DeclarationId(
      input.uri,
      'Box',
      kind: DeclarationKind.classType,
    );
    final binding = ClassBinding(
      declaration: owner,
      exportName: 'Box',
      source: source,
    );
    final reference = DeclaredType(owner, ValueSemantics.reference);
    for (final type in <BindingType>[
      const SafeIntType(),
      _list(const SafeIntType()),
      RecordTypeBinding(positional: [_list(const SafeIntType())]),
      reference,
      _list(reference),
      RecordTypeBinding(named: {'value': reference}),
      DeclaredType(
        owner,
        ValueSemantics.reference,
        nullability: TypeNullability.nullable,
      ),
    ]) {
      expect(
        () => validateValueType(type, source, referenceClasses: [binding]),
        returnsNormally,
      );
    }
    for (final type in <BindingType>[
      _list(
        DeclaredType(
          DeclarationId(input.uri, 'Missing', kind: DeclarationKind.classType),
          ValueSemantics.reference,
        ),
      ),
      RecordTypeBinding(
        named: {
          'value': DeclaredType(
            DeclarationId(
              input.uri,
              'Missing',
              kind: DeclarationKind.classType,
            ),
            ValueSemantics.reference,
          ),
        },
      ),
      DeclaredType(
        owner,
        ValueSemantics.reference,
        typeArguments: [const SafeIntType()],
      ),
      DeclaredType(
        owner,
        ValueSemantics.reference,
        nullability: TypeNullability.legacy,
      ),
      const DynamicType(),
      const VoidType(),
    ]) {
      expect(
        () => validateValueType(type, source, referenceClasses: [binding]),
        throwsA(
          isA<BindingDiagnostic>()
              .having((e) => e.code, 'code', 'NAPI_TYPE')
              .having((e) => e.source, 'source', source),
        ),
      );
    }
    for (final policy in [ClassPolicy.value, ClassPolicy.resource]) {
      final unsupported = ClassBinding(
        declaration: owner,
        exportName: 'Box',
        source: source,
        classPolicy: policy,
      );
      expect(
        () => validateValueType(
          reference,
          source,
          referenceClasses: [unsupported],
        ),
        throwsA(isA<BindingDiagnostic>()),
      );
    }
  });

  test('structural class members use the shared value conversions', () async {
    await input.writeAsString('''import 'package:napi/napi.dart';
@NAPI() class Box { List<int> values() => [1]; }
''');
    final module = await AnnotationFrontend(packagesPath: packages)
        .read(input.uri);
    final wasm = lower(validate(module));
    expect(wasm.classes.single.members.single.output, isA<ListConversion>());
    final native = validateNative(module);
    expect(native.classes.single.members.single.output, isA<ListConversion>());
  });

  test(
    'a class named List runs beside actual core Lists in generated Wasm',
    () async {
      final module = await AnnotationFrontend(packagesPath: packages)
          .read(input.uri);
      final plan = lower(validate(module));
      final entry = await File('${directory.path}/entry.dart')
          .writeAsString(emitDart(plan));
      final compiled = await DartSdkAdapter().compile(
        sourcePath: entry.path,
        outputPath: '${directory.path}/raw.wasm',
        packagesPath: packages,
      );
      final linked = linkDartModule(
        rawWasmBytes: await File(compiled.wasmPath).readAsBytes(),
        rawMjsText: await File(compiled.jsPath).readAsString(),
        hostSpecifier: './host.mjs',
        coreSpecifier: './core.wasm',
        additionalImports: {'napi': './boundary.mjs'},
      );
      await File('${directory.path}/core.wasm').writeAsBytes(linked.wasmBytes);
      await File('${directory.path}/references.mjs')
          .writeAsString(emitReferences());
      await File('${directory.path}/host.mjs')
          .writeAsString(linked.hostJavaScript);
      await File('${directory.path}/boundary.mjs')
          .writeAsString(emitBoundary(plan));
      await File('${directory.path}/calls.mjs')
          .writeAsString(emitArgumentCalls(plan));
      await File('${directory.path}/test.mjs').writeAsString('''
import assert from 'node:assert/strict';
import {PublicList, identity} from './calls.mjs';
import {integers, nested} from './core.wasm';
const selected = new PublicList(17);
assert.equal(selected.value, 17);
assert.equal(selected.self(), selected);
assert.equal(identity(selected), selected);
const nestedSource = [selected, selected];
const nestedResult = nested(nestedSource);
assert.notEqual(nestedResult, nestedSource);
assert.equal(nestedResult[0], selected);
assert.equal(nestedResult[1], selected);
const source = [1, 2];
const output = integers(source);
assert.deepEqual(output, source);
assert.notEqual(output, source);
assert.throws(() => identity(source), TypeError);
assert.throws(() => integers(selected), TypeError);
''');
      final execution = await Process.run('node', [
        'test.mjs',
      ], workingDirectory: directory.path);
      expect(
        execution.exitCode,
        0,
        reason: '${execution.stdout}${execution.stderr}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
