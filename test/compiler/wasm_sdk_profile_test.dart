import 'dart:convert';
import 'dart:io';

import 'package:napi/src/compiler/front_end/fixture_frontend.dart';
import 'package:napi/src/compiler/front_end/wasm_sdk_profile.dart';
import 'package:napi/src/compiler/ir/binding.dart';
import 'package:napi/src/compiler/ir/diagnostic.dart';
import 'package:napi/src/compiler/lowering/lower.dart';
import 'package:napi/src/compiler/lowering/plans.dart';
import 'package:test/test.dart';

void main() {
  late Directory directory;
  setUp(
    () => directory = Directory.systemTemp.createTempSync('napi-wasm-profile-'),
  );
  tearDown(() => directory.deleteSync(recursive: true));
  File write(String name, String content) =>
      File('${directory.path}/$name')..writeAsStringSync(content);

  test('compiling SDK supplies immutable default Wasm declared variables', () {
    final profile = WasmSdkProfile.load(sourceUri: Uri.file('/fixture.dart'));
    // Verified against actual String.fromEnvironment results from Dart 3.13.5
    // compiled with the same default wasm target.
    expect(profile.declaredVariables.keys.toSet(), {
      for (final name in [
        'async',
        'collection',
        'convert',
        'core',
        'developer',
        'isolate',
        'js_interop',
        'js_interop_unsafe',
        'math',
        'nativewrappers',
        'typed_data',
      ])
        'dart.library.$name',
    });
    expect(profile.declaredVariables['dart.library.js_interop'], 'true');
    expect(profile.declaredVariables['dart.library.core'], 'true');
    expect(profile.declaredVariables.containsKey('dart.library.io'), isFalse);
    expect(profile.declaredVariables.containsKey('dart.library.ffi'), isFalse);
    expect(profile.declaredVariables.containsKey('dart.library.html'), isFalse);
    expect(
      profile.declaredVariables.keys.any(
        (key) => key.startsWith('dart.library._'),
      ),
      isFalse,
    );
    expect(() => profile.declaredVariables.clear(), throwsUnsupportedError);
  });

  for (final transitive in [false, true]) {
    test(
      'safe integer plan follows ${transitive ? 'transitive export' : 'direct import'} Wasm branch',
      () async {
        write('stub.dart', 'typedef Scalar = double;');
        write('web.dart', 'typedef Scalar = int;');
        const conditional =
            "'stub.dart' if (dart.library.js_interop) 'web.dart'";
        if (transitive) write('types.dart', 'export $conditional;');
        final source = write('source.dart', '''
import ${transitive ? "'types.dart'" : conditional};
Scalar unsafe() => 9007199254740992 + 1;
''');
        final module = await FixtureFrontend().resolve(
          path: source.path,
          functionNames: ['unsafe'],
        );
        expect(module.functions.single.returnType.kind, PrimitiveKind.integer);
        expect(
          lowerModule(module).calls.single.result.operation,
          ConversionOperation.safeIntegerToJs,
        );
      },
    );
  }

  test(
    'unavailable conditions remain undefined, not the string false',
    () async {
      write('stub.dart', 'typedef Scalar = int;');
      write('wrong.dart', 'typedef Scalar = double;');
      final source = write('source.dart', '''
import 'stub.dart'
  if (dart.library.io == 'false') 'wrong.dart'
  if (dart.library.ffi) 'wrong.dart';
Scalar add() => 1;
''');
      final module = await FixtureFrontend().resolve(
        path: source.path,
        functionNames: ['add'],
      );
      expect(module.functions.single.returnType.kind, PrimitiveKind.integer);
    },
  );

  test(
    'unsupported selected Wasm branch is diagnosed before generation',
    () async {
      write('stub.dart', 'typedef Scalar = double;');
      write('web.dart', 'typedef Scalar = List<int>;');
      final source = write('source.dart', '''
import 'stub.dart' if (dart.library.js_interop) 'web.dart';
Scalar add() => throw UnimplementedError();
''');
      await expectLater(
        FixtureFrontend().resolve(path: source.path, functionNames: ['add']),
        throwsA(
          isA<BindingCompilationException>().having(
            (e) => e.diagnostics.single.code,
            'code',
            'unsupported_type',
          ),
        ),
      );
    },
  );

  test('missing or malformed SDK profile has a source-located diagnostic', () {
    final sourceUri = Uri.file('/fixture.dart');
    void check() => expect(
      () => WasmSdkProfile.load(sourceUri: sourceUri, sdkPath: directory.path),
      throwsA(
        isA<BindingCompilationException>()
            .having((e) => e.diagnostics.single.code, 'code', 'sdk_profile')
            .having((e) => e.diagnostics.single.source.uri, 'uri', sourceUri)
            .having((e) => e.diagnostics.single.source.line, 'line', 1),
      ),
    );
    check();
    Directory('${directory.path}/lib').createSync();
    write('lib/libraries.json', 'not json');
    check();
    write(
      'lib/libraries.json',
      jsonEncode({
        'wasm': {
          'include': [
            {'target': 'wasm'},
          ],
          'libraries': {},
        },
      }),
    );
    check();
  });
}
