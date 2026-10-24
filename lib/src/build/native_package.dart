import 'dart:convert';

import '../compiler/native/platform.dart';

/// Select one native artifact without changing its bindings or loading another.
String emitNativePackageLoader(
  Map<NativePlatform, String> modules,
  List<String> exports,
) {
  final paths = {
    for (final entry in modules.entries)
      '${entry.key.nodePlatform}/${entry.key.architecture}': entry.value,
  };
  final available = modules.keys
      .map((profile) => profile.description)
      .join(', ');
  final code = StringBuffer('''
import {release as \$napiRelease} from 'node:os';
import {createRequire as \$napiCreateRequire} from 'node:module';
const \$napiModules = ${jsonEncode(paths)};
const \$napiHost = process.platform + '/' + process.arch;
const \$napiModule = \$napiModules[\$napiHost];
if (\$napiModule === undefined) {
  throw new Error('This package has no native artifact for ' + \$napiHost + ${jsonEncode('. Available targets: $available.')});
}
''');
  if (modules.keys.any((platform) => platform.nodePlatform == 'darwin')) {
    code.writeln(r'''
if (process.platform === 'darwin') {
  const version = /^(\d+)\./.exec($napiRelease());
  if (version === null || Number(version[1]) < 23) {
    throw new Error('This native artifact requires macOS 14 or newer.');
  }
}
''');
  }
  if (modules.containsKey(NativePlatform.linuxX64)) {
    code.writeln(r'''
if (process.platform === 'linux') {
  const version = process.report?.getReport?.().header?.glibcVersionRuntime;
  const parts = typeof version === 'string' && /^(\d+)\.(\d+)(?:\.\d+)*$/.exec(version);
  if (!parts || Number(parts[1]) < 2 || (Number(parts[1]) === 2 && Number(parts[2]) < 28)) {
    throw new Error('This native artifact requires Linux x64 with glibc 2.28 or newer; musl is not supported.');
  }
}
''');
  }
  code.writeln(
    r'const $napiBindings = $napiCreateRequire(import.meta.url)($napiModule);',
  );
  for (final (index, name) in exports.indexed) {
    code.writeln(
      'const \$napi$index = \$napiBindings[${jsonEncode(name)}]; export {\$napi$index as ${jsonEncode(name)}};',
    );
  }
  return code.toString();
}
