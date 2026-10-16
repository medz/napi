import 'dart:convert';

import 'plan.dart';

/// Public export names are aliases, never local loader bindings.
String emitNativeLoader(
  List<String> exports, {
  List<NativeClassPlan> classes = const [],
}) {
  final code = StringBuffer('''
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
if (process.platform !== 'darwin' || process.arch !== 'arm64') {
  throw new Error('This native artifact requires macOS arm64. Build a matching target.');
}
const require = createRequire(import.meta.url);
const bindings = require('./bridge.node').load(fileURLToPath(new URL('./module.aot', import.meta.url)));
''');
  if (classes.any((binding) => binding.members.isNotEmpty)) {
    code.writeln(r'''const $napiApply = Reflect.apply;
function $napiCallable(target, name, kind) {
  const descriptor = Object.getOwnPropertyDescriptor(target, name);
  const callback = descriptor[kind];
  const callableName = kind === 'value' ? name : kind + ' ' + name;
  const callable = {[callableName](...args) {
    return $napiApply(callback, this, args);
  }}[callableName];
  Object.defineProperty(callable, 'name', {
    ...Object.getOwnPropertyDescriptor(callback, 'name'), value: callableName,
  });
  Object.defineProperty(callable, 'length', Object.getOwnPropertyDescriptor(callback, 'length'));
  descriptor[kind] = callable;
  Object.defineProperty(target, name, descriptor);
}
''');
    for (final binding in classes) {
      final target = 'bindings[${jsonEncode(binding.binding.exportName)}]';
      for (final member in binding.members) {
        final receiver = member.isStatic ? target : '$target.prototype';
        final kind = switch (member.kind) {
          NativeCallKind.method => 'value',
          NativeCallKind.getter => 'get',
          NativeCallKind.setter => 'set',
          _ => throw StateError('Unsupported native class callable'),
        };
        code.writeln(
          '\$napiCallable($receiver, ${jsonEncode(member.exportName)}, ${jsonEncode(kind)});',
        );
      }
    }
  }
  for (final (index, name) in exports.indexed) {
    code.writeln(
      'const \$napi$index = bindings[${jsonEncode(name)}]; export {\$napi$index as $name};',
    );
  }
  return code.toString();
}
