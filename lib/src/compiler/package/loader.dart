import 'dart:convert';

import 'artifact.dart';

String commonJsLoader(String name, Map<NativePlatform, String>? packages) {
  if (packages == null) {
    return "'use strict';\n\nmodule.exports = require('./addon.node');\n";
  }
  final platforms = {
    for (final entry in packages.entries)
      entry.key.runtimeKey: {
        'package': entry.value,
        'file': 'platforms/${entry.key.id}/addon.node',
        if (entry.key.libc != null) 'libc': entry.key.libc,
      },
  };
  return ''''use strict';

const { existsSync } = require('fs');
const { join } = require('path');
const platforms = ${const JsonEncoder.withIndent('  ').convert(platforms)};
const key = process.platform + '-' + process.arch;
const platform = platforms[key];
if (!platform) {
  throw new Error(${jsonEncode('$name has no native addon for ')} + key);
}
if (platform.libc === 'glibc' && !(process.report && process.report.getReport && process.report.getReport().header.glibcVersionRuntime)) {
  throw new Error(${jsonEncode('$name requires glibc on ')} + key);
}
const local = join(__dirname, platform.file);
if (existsSync(local)) {
  module.exports = require(local);
} else {
  let resolved;
  try {
    resolved = require.resolve(platform.package);
  } catch (cause) {
    if (cause.code !== 'MODULE_NOT_FOUND') throw cause;
    const error = new Error('Install ' + platform.package + ' to use ' + ${jsonEncode(name)} + ' on ' + key);
    error.cause = cause;
    throw error;
  }
  module.exports = require(resolved);
}
''';
}

String esmLoader(List<({String name, String kind})> exports) {
  final output = StringBuffer("import binding from './index.cjs';\n\n");
  for (var i = 0; i < exports.length; ++i) {
    final name = exports[i].name;
    output.writeln('const _napi$i = binding[${jsonEncode(name)}];');
    output.writeln('export { _napi$i as $name };');
  }
  output.writeln('\nexport default binding;');
  return output.toString();
}

String esmDeclarations(List<({String name, String kind})> exports) =>
    '''import binding = require('./index.cjs');
export { ${exports.map((entry) => entry.name).join(', ')} } from './index.cjs';
export default binding;
''';
