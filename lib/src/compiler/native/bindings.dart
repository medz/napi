import 'dart:convert';
import 'dart:io';

/// Writes the internal embedder entry used by the native prototype.
///
/// The source must provide initialize, afterPump and dispose with these
/// signatures. Exporting ordinary Dart declarations is a separate compiler step.
File writeBindings(File source, Directory workspace) {
  final uri = jsonEncode(source.absolute.uri.toString())
      .replaceAll(r'$', r'\$');
  return File('${workspace.path}/entry.dart')..writeAsStringSync('''
import $uri as addon;

@pragma('vm:entry-point')
int initialize(
  int environment,
  int exports,
  int callJs,
  int owner,
  int finalizer,
  int hasLivePorts,
) => addon.initialize(environment, exports, callJs, owner, finalizer, hasLivePorts);

@pragma('vm:entry-point')
void afterPump() => addon.afterPump();

@pragma('vm:entry-point')
void dispose() => addon.dispose();

void main() {}
''');
}
