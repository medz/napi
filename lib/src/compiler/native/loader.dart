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
  // Capture the original concise callback functions before installing effective
  // inherited/interface descriptors, so defaults remain owned by the source.
  final references = {
    for (final binding in classes)
      for (final property in binding.shape.prototypeProperties) ...[
        ?property.method,
        ?property.getter,
        ?property.setter,
      ],
  };
  for (final ref in references) {
    final owner = classes[ref.classId];
    final member = owner.members[ref.memberIndex];
    final kind = switch (member.kind) {
      NativeCallKind.method => 'value',
      NativeCallKind.getter => 'get',
      NativeCallKind.setter => 'set',
      _ => throw StateError('Unsupported prototype callback'),
    };
    code.writeln(
      'const \$member${ref.classId}_${ref.memberIndex} = Object.getOwnPropertyDescriptor(bindings[${jsonEncode(owner.binding.exportName)}].prototype, ${jsonEncode(member.exportName)}).$kind;',
    );
  }
  for (final binding in classes) {
    final target =
        'bindings[${jsonEncode(binding.binding.exportName)}].prototype';
    final parent = binding.shape.superclassId;
    if (parent != null) {
      code.writeln(
        'Object.setPrototypeOf($target, bindings[${jsonEncode(classes[parent].binding.exportName)}].prototype);',
      );
    }
    for (final property in binding.shape.prototypeProperties) {
      String callback(({int classId, int memberIndex}) ref) =>
          '\$member${ref.classId}_${ref.memberIndex}';
      final fields = property.method != null
          ? 'value: ${callback(property.method!)}, writable: true'
          : [
              if (property.getter != null) 'get: ${callback(property.getter!)}',
              if (property.setter != null) 'set: ${callback(property.setter!)}',
            ].join(', ');
      code.writeln(
        'Object.defineProperty($target, ${jsonEncode(property.name)}, {$fields, enumerable: false, configurable: true});',
      );
    }
  }
  for (final (index, name) in exports.indexed) {
    code.writeln(
      'const \$napi$index = bindings[${jsonEncode(name)}]; export {\$napi$index as $name};',
    );
  }
  return code.toString();
}
