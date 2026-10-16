import 'dart:convert';

/// Public export names are aliases, never local loader bindings.
String emitNativeLoader(List<String> exports) =>
    '''
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
if (process.platform !== 'darwin' || process.arch !== 'arm64') {
  throw new Error('This native artifact requires macOS arm64. Build a matching target.');
}
const require = createRequire(import.meta.url);
const bindings = require('./bridge.node').load(fileURLToPath(new URL('./module.aot', import.meta.url)));
${exports.indexed.map((entry) => 'const \$napi${entry.$1} = bindings[${jsonEncode(entry.$2)}]; export {\$napi${entry.$1} as ${entry.$2}};').join('\n')}
''';
