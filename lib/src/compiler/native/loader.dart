import 'dart:convert';

import '../analysis/reference_views.dart' show hasCompositeReferenceViews;
import '../emit/js/callbacks.dart';
import '../emit/js/binary.dart';
import '../emit/js/cancellation.dart';
import '../emit/js/reference_views.dart';
import '../emit/js/settlement.dart';
import '../emit/js/shared_bytes.dart';
import 'plan.dart';

/// Public export names are aliases, never local loader bindings.
String emitNativeLoader(
  List<String> exports, {
  List<NativeClassPlan> classes = const [],
  bool hasFutures = false,
  bool hasCallbacks = false,
  bool hasAsyncCallbacks = false,
  bool hasSignals = false,
  bool hasBinary = false,
  String? streamClassName,
}) {
  final hasResources = classes.any((binding) => binding.shape.cleanup != null);
  final shapes = [for (final binding in classes) binding.shape];
  final hasCompositeViews = hasCompositeReferenceViews(shapes);
  // Allocation is available inside ordinary Dart business functions even when
  // no exported signature mentions SharedBytes. The helper itself stays lazy.
  final code = StringBuffer('''
import {createRequire} from 'node:module';
import {fileURLToPath} from 'node:url';
if (process.platform !== 'darwin' || process.arch !== 'arm64') {
  throw new Error('This native artifact requires macOS arm64. Build a matching target.');
}
const require = createRequire(import.meta.url);
''');
  if (hasCompositeViews) {
    code.writeln(r'''const $napiCreate = Object.create;
function $napiResolveReferenceShape(views, context) {
  const prototype = $napiCompositePrototype(views, context);
  return () => $napiCreate(prototype);
}
''');
  }
  if (hasFutures) {
    code.writeln(r'''const $napiPromise = globalThis.Promise;
function $napiCreatePromise() {
  let resolve, reject;
  const promise = new $napiPromise((yes, no) => { resolve = yes; reject = no; });
  return [promise, resolve, reject, undefined];
}
''');
  }
  if (hasResources) {
    code.write(
      settlementObserver.replaceFirst(
        'export function createSettlementObserver(',
        r'function $napiCreateSettlementObserver(',
      ),
    );
  }
  if (hasSignals) code.write(cancellationPolicy);
  if (hasBinary) code.write(binaryPolicy);
  code.write(sharedBytesPolicy);
  if (hasAsyncCallbacks) {
    code.write(callbackPromisePolicy);
  }
  code.writeln(r'''const $napiCallbackWeakMap = WeakMap;
const $napiCallbackGet = WeakMap.prototype.get;
const $napiCallbackSet = WeakMap.prototype.set;
''');
  if (!hasAsyncCallbacks) {
    code.writeln(r'const $napiCallbackApply = Reflect.apply;');
  }
  code.writeln(r'''function $napiCallbackHelper(kind, deliver) {
  if (kind === 0) {
    const functions = new $napiCallbackWeakMap();
    let next = 0;
    return function identify(callback, kind, nullable, path) {
''');
  if (hasBinary) {
    code.writeln(
      r'      if (arguments.length === 4) return $napiBinaryView(callback, kind, nullable, path);',
    );
  }
  code.writeln(r'''      if (arguments.length === 2 && kind === 3) {
        return $napiAllocateSharedBytes(callback);
      }
      if (arguments.length === 3 && kind === 2) {
        return $napiSharedBytesControl(callback, nullable);
      }''');
  code.writeln(r'''      let id = $napiCallbackApply($napiCallbackGet, functions, [callback]);
      if (id === undefined) {
        if (next === 9007199254740991) throw new RangeError('Native callback identity space exhausted');
        id = ++next;
        $napiCallbackApply($napiCallbackSet, functions, [callback, id]);
      }
      return id;
    };
  }
''');
  if (hasAsyncCallbacks || hasSignals) {
    code.writeln(r'''  return function observe(callback, token, ...args) {''');
    if (hasSignals) {
      code.writeln(r'''    if (callback === null) {
      $napiCheckAbortSignal(token, false, args[0]);
      const signal = $napiCreateSignalCompanion(token,
        target => deliver(target, false, undefined));
      return function control(operation, target) {
        switch (operation) {
          case 0: return signal.aborted();
          case 1: if (signal.aborted()) throw signal.reason(); return;
          case 2: signal.arm(target); return;
          case 3: signal.detach(); return;
          default: throw new Error('Unknown private signal operation');
        }
      };
    }''');
    }
    if (hasAsyncCallbacks) {
      code.writeln(r'''
    const value = $napiCallbackApply(callback, undefined, args);
    $napiObserveCallbackPromise(value,
      value => deliver(token, false, value),
      error => deliver(token, true, error));
''');
    } else {
      code.writeln(
        "    throw new Error('Async callbacks were not generated');",
      );
    }
    code.writeln('  };\n}');
  } else {
    code.writeln("  throw new Error('Async callbacks were not generated');\n}");
  }
  final factories = [
    hasCompositeViews ? r'$napiResolveReferenceShape' : 'null',
    hasFutures ? r'$napiCreatePromise' : 'null',
    hasResources ? r'$napiCreateSettlementObserver' : 'null',
    r'$napiCallbackHelper',
  ];
  code.writeln(
    "const bindings = require('./bridge.node').load(fileURLToPath(new URL('./module.aot', import.meta.url)), ${factories.join(', ')});",
  );
  if (streamClassName != null ||
      classes.any((binding) => binding.members.isNotEmpty)) {
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
  if (streamClassName != null) {
    final privateName = jsonEncode(streamClassName);
    code.writeln(
      """const \$napiStreamPrototype = bindings[$privateName].prototype;
\$napiCallable(\$napiStreamPrototype, 'next', 'value');
\$napiCallable(\$napiStreamPrototype, 'return', 'value');
Object.defineProperty(\$napiStreamPrototype, Symbol.asyncIterator, {
  value: {[Symbol.asyncIterator]() { return this; }}[Symbol.asyncIterator],
  writable: true, configurable: true,
});
delete bindings[$privateName];
""",
    );
  }
  // Capture the original concise callback functions before installing effective
  // inherited/interface descriptors, so defaults remain owned by the source.
  final references = hasCompositeViews
      ? {
          for (final binding in classes)
            for (final (index, member) in binding.members.indexed)
              if (!member.isStatic)
                (classId: binding.shape.classId, memberIndex: index),
        }
      : {
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
  if (hasCompositeViews) {
    code.write(
      emitCompositeReferencePrototypes(
        shapes,
        (ref) => '\$member${ref.classId}_${ref.memberIndex}',
      ),
    );
  }
  for (final (index, name) in exports.indexed) {
    code.writeln(
      'const \$napi$index = bindings[${jsonEncode(name)}]; export {\$napi$index as $name};',
    );
  }
  return code.toString();
}
