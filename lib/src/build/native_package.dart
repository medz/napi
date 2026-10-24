import 'dart:convert';

import '../compiler/native/platform.dart';

/// Select one native artifact without changing its bindings or loading another.
String emitNativePackageLoader(
  Map<NativePlatform, String> modules,
  List<String> exports, {
  String? packageVersion,
}) {
  final paths = {
    for (final entry in modules.entries)
      '${entry.key.nodePlatform}/${entry.key.architecture}': entry.value,
  };
  final code = StringBuffer(_nativePlatformCheck(modules.keys))
    ..writeln(
      r'if ($napiUnsupported !== null) throw new Error($napiUnsupported);',
    )
    ..writeln('''
import {createRequire as \$napiCreateRequire} from 'node:module';
const \$napiModules = ${jsonEncode(paths)};
const \$napiModule = \$napiModules[\$napiHost];
const \$napiRequire = \$napiCreateRequire(import.meta.url);
''');
  if (packageVersion != null) {
    code.writeln('''
import {existsSync as \$napiExists} from 'node:fs';
import {join as \$napiJoin} from 'node:path';
try {
  \$napiRequire.resolve(\$napiModule);
} catch (error) {
  if (error.code !== 'MODULE_NOT_FOUND' ||
      (\$napiRequire.resolve.paths(\$napiModule) ?? []).some(directory =>
        \$napiExists(\$napiJoin(directory, \$napiModule)))) throw error;
  throw new Error('Missing optional native package ' + \$napiModule + ${jsonEncode('@$packageVersion. Install this package with npm optional dependencies enabled.')}, {cause: error});
}
''');
  }
  code.writeln(r'const $napiBindings = $napiRequire($napiModule);');
  _exports(code, exports);
  return code.toString();
}

/// Only unsupported native platforms select Wasm; loading errors propagate.
String emitWasmFallbackLoader(
  Iterable<NativePlatform> platforms,
  List<String> exports,
) {
  final code = StringBuffer(_nativePlatformCheck(platforms))
    ..writeln(r'''
const $napiBindings = await import($napiUnsupported === null
  ? './native/module.mjs' : './wasm/module.wasm');
''');
  _exports(code, exports);
  return code.toString();
}

String _nativePlatformCheck(Iterable<NativePlatform> platforms) {
  final available = platforms.map((profile) => profile.description).join(', ');
  final hosts = [
    for (final platform in platforms)
      '${platform.nodePlatform}/${platform.architecture}',
  ];
  final code = StringBuffer('''
import {release as \$napiRelease} from 'node:os';
const \$napiHost = process.platform + '/' + process.arch;
let \$napiUnsupported = ${jsonEncode(hosts)}.includes(\$napiHost) ? null
  : 'This package has no native artifact for ' + \$napiHost + ${jsonEncode('. Available targets: $available.')};
''');
  if (platforms.any((platform) => platform.nodePlatform == 'darwin')) {
    code.writeln(r'''
if ($napiUnsupported === null && process.platform === 'darwin') {
  const version = /^(\d+)\./.exec($napiRelease());
  if (version === null || Number(version[1]) < 23) {
    $napiUnsupported = 'This native artifact requires macOS 14 or newer.';
  }
}
''');
  }
  if (platforms.contains(NativePlatform.windowsX64)) {
    code.writeln(r'''
if ($napiUnsupported === null && process.platform === 'win32') {
  const version = /^(\d+)\./.exec($napiRelease());
  if (version === null || Number(version[1]) < 10) {
    $napiUnsupported = 'This native artifact requires Windows 10 or Server 2016 or newer.';
  }
}
''');
  }
  if (platforms.any((platform) => platform.nodePlatform == 'linux')) {
    code.writeln(r'''
if ($napiUnsupported === null && process.platform === 'linux') {
  const version = process.report?.getReport?.().header?.glibcVersionRuntime;
  const parts = typeof version === 'string' && /^(\d+)\.(\d+)(?:\.\d+)*$/.exec(version);
  if (!parts || Number(parts[1]) < 2 || (Number(parts[1]) === 2 && Number(parts[2]) < 28)) {
    $napiUnsupported = 'This native artifact requires Linux with glibc 2.28 or newer; musl is not supported.';
  }
}
''');
  }
  return code.toString();
}

void _exports(StringBuffer code, List<String> exports) {
  for (final (index, name) in exports.indexed) {
    code.writeln(
      'const \$napi$index = \$napiBindings[${jsonEncode(name)}]; export {\$napi$index as ${jsonEncode(name)}};',
    );
  }
}
