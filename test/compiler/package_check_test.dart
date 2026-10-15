import 'package:test/test.dart';

import '../../tool/check_package.dart';

const warning = '''Publishing napi to pub.dev:\nlib/\nValidating package...
Package validation found the following potential issue:
* Your dependency on "analyzer" should allow more than one version. For example:

  dependencies:
    analyzer: ^14.5.0

  Constraints that are too tight will make it difficult for people to use your package
  along with other packages that also depend on "analyzer".
The server may enforce additional checks.

Package has 1 warning.
''';

void main() {
  bool accepted(String text, {int code = 65, String errors = ''}) =>
      isExpectedAnalyzerPinWarning(
        exitCode: code,
        output: text,
        errors: errors,
      );

  test('accepts only the intentional exact analyzer pin warning', () {
    expect(accepted(warning), isTrue);
    expect(accepted(warning.replaceAll('\n\n', '\n  \n')), isTrue);
    expect(accepted(warning.replaceAll('\n', '\r\n')), isTrue);
  });

  test('rejects extra, changed, missing, or malformed diagnostics', () {
    for (final output in [
      '',
      'Package has 1 warning.',
      warning.replaceAll('potential issue:', '2 potential issues:'),
      warning.replaceAll('1 warning.', '2 warnings.'),
      warning.replaceAll('1 warning.', '1 warning and 1 hint.'),
      warning.replaceAll('analyzer', 'another_package'),
      warning.replaceAll('14.5.0', '14.5.1'),
      warning.replaceAll(
        'The server may',
        '* Another warning.\nThe server may',
      ),
      'Package validation found the following error:\n* error\n$warning',
      '$warning\nUnexpected failure',
    ]) {
      expect(accepted(output), isFalse, reason: output);
    }
    expect(accepted(warning, code: 1), isFalse);
    expect(accepted(warning, code: 0), isFalse);
    expect(accepted(warning, errors: 'registry failed'), isFalse);
  });
}
