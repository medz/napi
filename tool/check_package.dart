import 'dart:io';

// The analyzer platform adapter uses version-specific APIs, so this dependency
// is intentionally exact. Do not suppress other package validation diagnostics.
const _expectedValidation =
    '''Package validation found the following potential issue:
* Your dependency on "analyzer" should allow more than one version. For example:

  dependencies:
    analyzer: ^14.5.0

  Constraints that are too tight will make it difficult for people to use your package
  along with other packages that also depend on "analyzer".
The server may enforce additional checks.

Package has 1 warning.''';

bool isExpectedAnalyzerPinWarning({
  required int exitCode,
  required String output,
  required String errors,
}) {
  if (exitCode != 65 || errors.trim().isNotEmpty) return false;
  final normalized = output
      .replaceAll('\r\n', '\n')
      .split('\n')
      .map((line) => line.trimRight())
      .join('\n')
      .trim();
  final start = normalized.indexOf('Package validation found');
  return start >= 0 && normalized.substring(start) == _expectedValidation;
}

Future<void> main() async {
  final result = await Process.run(Platform.resolvedExecutable, [
    'pub',
    'publish',
    '--dry-run',
  ]);
  stdout.write(result.stdout);
  stderr.write(result.stderr);
  if (result.exitCode == 0) return;
  if (isExpectedAnalyzerPinWarning(
    exitCode: result.exitCode,
    output: result.stdout as String,
    errors: result.stderr as String,
  )) {
    stdout.writeln('Accepted the intentional analyzer 14.5.0 pin warning.');
    return;
  }
  exitCode = result.exitCode;
}
