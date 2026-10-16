import 'dart:io';

import 'package:napi/src/compiler/front_end/frontend.dart';
import 'package:napi/src/compiler/front_end/external.dart';
import 'package:napi/src/compiler/ir/model.dart';
import 'package:test/test.dart';

void main() {
  test(
    'native annotation and external analysis choose the AOT environment',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'napi-native-analysis-',
      );
      addTearDown(() => root.delete(recursive: true));
      final entry = File('${root.path}/entry.dart');
      await entry.writeAsString(
        "export 'other.dart' if (dart.library.ffi) 'native.dart' if (dart.library.mirrors) 'other.dart';",
      );
      await File('${root.path}/other.dart')
          .writeAsString('double selected(double x) => x;');
      await File('${root.path}/native.dart').writeAsString('''
import 'package:napi/napi.dart';
import 'dart:io';
import 'dart:ffi';
@NAPI()
int selected(int x) => x + (Platform.isMacOS ? sizeOf<Int64>() : 0);
''');
      final packages = File('.dart_tool/package_config.json').absolute.path;
      for (final frontend in <BindingFrontend>[
        AnnotationFrontend(native: true, packagesPath: packages),
        ExternalFrontend(
          ExternalLibrary([ExternalFunction('selected')]),
          native: true,
          packagesPath: packages,
        ),
      ]) {
        final result = await frontend.read(entry.uri);
        final function = result.functions.single;
        expect(
          function.declaration.library,
          File('${root.path}/native.dart').uri,
        );
        expect(function.result, isA<SafeIntType>());
        expect(function.parameters.single.type, isA<SafeIntType>());
      }
    },
  );
}
