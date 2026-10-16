import '../analysis/validate.dart';
import '../ir/model.dart';
import '../lowering/plan.dart' show ScalarConversion;

enum NativeCallKind { function, constructor, method, getter, setter }

/// Synchronous call metadata, without a Wasm export kind or externref ABI.
final class NativeCallPlan {
  final String callback;
  final String context;
  final NativeCallKind kind;
  final FunctionBinding? function;
  final ClassBinding? owner;
  final MemberBinding? member;
  final List<ParameterBinding> parameters;
  final List<ScalarConversion> inputs;
  final ScalarConversion? output;
  NativeCallPlan._({
    required this.callback,
    required this.context,
    required this.kind,
    required this.parameters,
    required this.inputs,
    required this.output,
    this.function,
    this.owner,
    this.member,
  });

  bool get isStatic => member?.isStatic ?? false;
  bool get isConstructor => kind == NativeCallKind.constructor;
  int get javascriptArity =>
      parameters.any(
        (parameter) => parameter.kind != ParameterKind.requiredPositional,
      )
      ? 0
      : parameters.length;
  String get exportName =>
      function?.exportName ?? member?.exportName ?? member!.declaration.name;
}

final class NativeClassPlan {
  final ClassBinding binding;
  final NativeCallPlan constructor;
  final List<NativeCallPlan> members;
  NativeClassPlan._(this.binding, this.constructor, this.members);
}

final class NativeModulePlan {
  final BindingModule bindings;
  final List<NativeCallPlan> functions;
  final List<NativeClassPlan> classes;
  NativeModulePlan._(this.bindings, this.functions, this.classes);
  Iterable<NativeCallPlan> get calls sync* {
    yield* functions;
    for (final binding in classes) {
      yield binding.constructor;
      yield* binding.members;
    }
  }
}

final _identifier = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');
const _reserved = {
  'await',
  'break',
  'case',
  'catch',
  'class',
  'const',
  'continue',
  'debugger',
  'default',
  'delete',
  'do',
  'else',
  'enum',
  'export',
  'extends',
  'false',
  'finally',
  'for',
  'function',
  'if',
  'implements',
  'import',
  'in',
  'instanceof',
  'interface',
  'let',
  'new',
  'null',
  'package',
  'private',
  'protected',
  'public',
  'return',
  'static',
  'super',
  'switch',
  'this',
  'throw',
  'true',
  'try',
  'typeof',
  'var',
  'void',
  'while',
  'with',
  'yield',
  'eval',
  'arguments',
};

/// Select exactly the capabilities implemented by the synchronous native ABI.
/// Unsupported declarations fail before generating or publishing artifacts.
NativeModulePlan validateNative(BindingModule module) {
  validateDeclarations(module);
  var next = 0;
  NativeCallPlan call({
    required String context,
    required NativeCallKind kind,
    required List<ParameterBinding> parameters,
    required BindingType? result,
    required SourceLocation source,
    bool bigint = false,
    FunctionBinding? function,
    ClassBinding? owner,
    MemberBinding? member,
  }) {
    validateCallParameters(parameters, source, scalarOnly: true);
    if (result != null && result is! VoidType) {
      validateScalarType(result, source);
    }
    return NativeCallPlan._(
      callback: '_native${next++}',
      context: context,
      kind: kind,
      parameters: List.unmodifiable(parameters),
      inputs: List.unmodifiable([
        for (final parameter in parameters)
          ScalarConversion(
            parameter.type,
            '$context.${parameter.name}',
            bigint: bigint,
          ),
      ]),
      output: result == null || result is VoidType
          ? null
          : ScalarConversion(result, '$context result', bigint: bigint),
      function: function,
      owner: owner,
      member: member,
    );
  }

  final functions = <NativeCallPlan>[];
  for (final binding in module.functions) {
    _name(binding.exportName, binding.source, topLevel: true);
    _path(binding.callPath, binding.source);
    if (binding.exportSurface != module.source) {
      _reject(
        'NAPI_LIBRARY',
        'The call path must be exposed by the selected entry library.',
        binding.source,
      );
    }
    _executable(
      binding.typeParameters,
      binding.isAsync,
      binding.isGenerator,
      binding.isExternal,
      binding.source,
    );
    functions.add(
      call(
        context: binding.exportName,
        kind: NativeCallKind.function,
        parameters: binding.parameters,
        result: binding.result,
        source: binding.source,
        bigint: binding.bigint,
        function: binding,
      ),
    );
  }
  final classes = <NativeClassPlan>[];
  for (final shape in validateReferenceClasses(module)) {
    final binding = shape.binding;
    NativeCallPlan member(ReferenceMemberShape selected) => call(
      context: selected.kind == ReferenceMemberKind.constructor
          ? binding.exportName
          : '${binding.exportName}.${selected.binding.exportName ?? selected.binding.declaration.name}',
      kind: switch (selected.kind) {
        ReferenceMemberKind.constructor => NativeCallKind.constructor,
        ReferenceMemberKind.method => NativeCallKind.method,
        ReferenceMemberKind.getter => NativeCallKind.getter,
        ReferenceMemberKind.setter => NativeCallKind.setter,
      },
      parameters: selected.parameters,
      result: selected.result,
      source: selected.binding.source,
      owner: binding,
      member: selected.binding,
    );
    classes.add(
      NativeClassPlan._(
        binding,
        member(shape.constructor),
        List.unmodifiable(shape.members.map(member)),
      ),
    );
  }
  return NativeModulePlan._(
    module,
    List.unmodifiable(functions),
    List.unmodifiable(classes),
  );
}

void _name(String name, SourceLocation source, {bool topLevel = false}) {
  if (!_identifier.hasMatch(name) ||
      (!topLevel && name.startsWith('_')) ||
      _reserved.contains(name) ||
      (topLevel && name == 'then')) {
    _reject('NAPI_NAME', 'Unsupported native public identifier $name.', source);
  }
}

void _path(String path, SourceLocation source) {
  for (final segment in path.split('.')) {
    if (!_identifier.hasMatch(segment) || segment.startsWith('_')) {
      _reject('NAPI_NAME', 'Unsupported native Dart call path $path.', source);
    }
  }
}

void _executable(
  List<TypeParameterBinding> types,
  bool async,
  bool generator,
  bool external,
  SourceLocation source,
) {
  if (types.isNotEmpty) {
    _reject(
      'NAPI_GENERIC',
      'Native generic specialization is not implemented.',
      source,
    );
  }
  if (async || generator) {
    _reject(
      'NAPI_TYPE',
      'The native backend currently supports synchronous calls only.',
      source,
    );
  }
  if (external) {
    _reject(
      'NAPI_EXTERNAL',
      'Dart external declarations are not supported by the native backend.',
      source,
    );
  }
}

Never _reject(String code, String message, SourceLocation source) =>
    throw BindingDiagnostic(code, message, source);
