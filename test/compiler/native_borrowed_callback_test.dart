import 'dart:io';

import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/native/entrypoint.dart';
import 'package:napi/src/compiler/native/plan.dart';
import 'package:test/test.dart';

void main() {
  final packages = File('.dart_tool/package_config.json').absolute.path;

  test(
    'typed borrowed adapters compile with nullable and structural values',
    () async {
      final directory = await Directory.systemTemp.createTemp('napi-callback-');
      addTearDown(() => directory.delete(recursive: true));
      final source = File('${directory.path}/business.dart');
      await source.writeAsString('''
import 'package:napi/napi.dart';
@NAPI() int apply(int Function(int) callback) => callback(1);
@NAPI() int optional([int? Function(int?)? callback]) => callback?.call(null) ?? 0;
@NAPI() int notify(void Function() callback) { callback(); return 1; }
@NAPI() int list(List<int> Function(List<int>) callback) => callback([1]).length;
@NAPI() String record((int, {String label}) Function((int, {String label})) callback) => callback((1, label: 'a')).label;
@NAPI(classPolicy: ClassPolicy.resource, cleanup: 'close')
class Resource {
  Resource();
  int call(int Function(int) callback) => callback(1);
  void close() {}
}
''');
      final plan = validateNative(
        await AnnotationFrontend(
          packagesPath: packages,
          native: true,
        ).read(source.uri),
      );
      final generated = emitNativeDart(plan);
      expect(generated, contains('final int Function(int) a0;'));
      expect(generated, contains('borrowed.invoke<void>'));
      expect(
        generated,
        contains('borrowed.close();\n    operation.release();'),
      );
      // Structures only occur inside callback signatures in this module.
      expect(generated, contains('final class _NativeReadState'));
      expect(generated, contains('callback argument 1'));
      expect(generated, contains('callback result'));
      final entry = File('${directory.path}/entry.dart');
      await entry.writeAsString(generated);
      final compiled = await Process.run(Platform.resolvedExecutable, [
        'compile',
        'aot-snapshot',
        '--packages=$packages',
        entry.path,
        '--output=${directory.path}/module.aot',
      ]);
      expect(
        compiled.exitCode,
        0,
        reason: '${compiled.stdout}${compiled.stderr}',
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
