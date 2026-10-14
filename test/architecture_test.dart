import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('compiler stages and runtime respect their import boundaries', () {
    final root = Directory('lib').absolute.path;
    for (final file in Directory(
      root,
    ).listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart')) continue;
      final source = p.relative(file.path, from: root).replaceAll('\\', '/');
      final imports = RegExp(r'''(?:import|export)\s+['"]([^'"]+)['"]''')
          .allMatches(file.readAsStringSync())
          .map((match) => match[1]!);
      for (final import in imports) {
        expect(
          import.startsWith('dart:_'),
          isFalse,
          reason: '$source: $import',
        );
        if (!source.startsWith('src/compiler/front_end/')) {
          expect(
            import.startsWith('package:analyzer/'),
            isFalse,
            reason: '$source: analyzer must stay in the frontend',
          );
          expect(
            import.startsWith('package:_fe_analyzer_shared/'),
            isFalse,
            reason: '$source: analyzer internals must stay in the frontend',
          );
        }
        final target = import.startsWith('package:napi/')
            ? import.substring('package:napi/'.length)
            : import.contains(':')
            ? import
            : p
                  .normalize(p.join(p.dirname(source), import))
                  .replaceAll('\\', '/');
        if (source.startsWith('src/runtime/') || source == 'runtime.dart') {
          expect(
            target.startsWith('src/compiler/'),
            isFalse,
            reason: '$source: runtime cannot import compiler',
          );
          expect(
            target.startsWith('src/build/'),
            isFalse,
            reason: '$source: runtime cannot import build',
          );
        }
        if (source.startsWith('src/api/') || source == 'napi.dart') {
          expect(
            target.startsWith('src/compiler/'),
            isFalse,
            reason: '$source: public declarations cannot import compiler',
          );
          expect(
            target.startsWith('src/runtime/'),
            isFalse,
            reason:
                '$source: author declarations cannot import interop runtime',
          );
        }
        if (source.startsWith('src/compiler/ir/')) {
          expect(
            target.startsWith('src/compiler/') &&
                !target.startsWith('src/compiler/ir/'),
            isFalse,
            reason: '$source: IR cannot import later compiler stages',
          );
        }
        if (source.startsWith('src/compiler/emit/')) {
          expect(
            target.startsWith('src/compiler/front_end/'),
            isFalse,
            reason: '$source: emitters cannot re-resolve source',
          );
        }
      }
    }
  });
}
