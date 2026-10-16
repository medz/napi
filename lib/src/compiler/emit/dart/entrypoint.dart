import 'dart:convert';

import '../../lowering/plan.dart';
import '../../sdk_adapter/entrypoint.dart';

String emitDart(ModulePlan plan) {
  final source = jsonEncode(plan.source.toString()).replaceAll(r'$', r'\$');
  final result = StringBuffer(
    "import $source as target;\n$entrypointPrelude\n",
  );
  var context = 0;
  for (var index = 0; index < plan.functions.length; index++) {
    final function = plan.functions[index];
    final parameters = function.binding.parameters;
    result.writeln("@pragma('wasm:export', '${function.binding.exportName}')");
    result.writeln(
      'WasmExternRef? _export$index(${[for (var i = 0; i < parameters.length; i++) 'WasmExternRef? p$i'].join(', ')}) {',
    );
    // Validate outside the Dart exception boundary: preserve JS TypeErrors.
    for (var i = 0; i < parameters.length; i++) {
      result.writeln(
        '  final a$i = _readInt(p$i, WasmI32.fromInt(${context++}))'
        '.toDouble().toInt();',
      );
    }
    result.writeln('  int value;\n  try {');
    result.writeln(
      '    value = target.${function.binding.callPath}(${[for (var i = 0; i < parameters.length; i++) 'a$i'].join(', ')});',
    );
    result.writeln(
      '  } catch (error) {\n    return _normalizeError(error);\n  }',
    );
    result.writeln(
      '  return _writeInt(WasmF64.fromDouble(value.toDouble()), '
      'WasmI32.fromInt(${context++}));\n}',
    );
  }
  return result.toString();
}
