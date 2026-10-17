import '../analysis/result.dart';
import '../analysis/validate.dart';
import '../ir/model.dart';
import '../lowering/plan.dart'
    show
        BinaryConversion,
        SharedBytesConversion,
        ValueConversion,
        conversionFor,
        conversionGraph;

enum NativeCallKind { function, constructor, method, getter, setter }

/// Native call metadata, without a Wasm export kind or externref ABI.
final class NativeCallPlan {
  final String callback;
  final String context;
  final NativeCallKind kind;
  final FunctionBinding? function;
  final ClassBinding? owner;
  final MemberBinding? member;
  final List<ParameterBinding> parameters;
  final List<ValueConversion> inputs;
  final ValueConversion? output;
  final bool returnsFuture;
  final bool returnsStream;
  final bool isCleanup;
  final bool isStatic;
  final int? classId;
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
    this.returnsFuture = false,
    this.returnsStream = false,
    this.isCleanup = false,
    this.isStatic = false,
    this.classId,
  });

  bool get isConstructor => kind == NativeCallKind.constructor;
  int get javascriptArity =>
      parameters.any(
        (parameter) => parameter.kind != ParameterKind.requiredPositional,
      )
      ? 0
      : parameters.length;
  String get exportName =>
      function?.exportName ??
      member?.exportName ??
      member?.declaration.name ??
      owner!.exportName;
}

final class NativeClassPlan {
  final ReferenceClassShape shape;
  final ClassBinding binding;
  final NativeCallPlan constructor;
  final List<NativeCallPlan> members;
  NativeClassPlan._(this.shape, this.constructor, this.members)
    : binding = shape.binding;
  bool get hasPublicConstructor => constructor.member != null;
}

final class NativeModulePlan {
  final BindingModule bindings;
  final List<NativeCallPlan> functions;
  final List<NativeClassPlan> classes;
  final List<ValueClassSchema> valueSchemas;
  final List<int> referenceClassOrder;
  bool get hasBinary => calls.any(
    (call) =>
        conversionGraph([...call.inputs, if (call.output != null) call.output!])
            .any((value) => value is BinaryConversion),
  );
  bool get hasSharedBytesTypes => calls.any(
    (call) =>
        conversionGraph([...call.inputs, if (call.output != null) call.output!])
            .any((value) => value is SharedBytesConversion),
  );
  bool get hasStreams => calls.any((call) => call.returnsStream);
  int get streamClassId => classes.length;
  // Public export identifiers cannot contain $, so this private class cannot
  // collide with a selected Dart declaration.
  String get streamClassName => r'$napiStream';
  NativeModulePlan._(
    this.bindings,
    this.functions,
    this.classes,
    this.valueSchemas,
    this.referenceClassOrder,
  );
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

/// Select exactly the capabilities implemented by the native ABI.
/// Unsupported declarations fail before generating or publishing artifacts.
NativeModulePlan validateNative(BindingModule module) {
  validateDeclarations(module);
  final valueSchemas = validateValueClasses(module);
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
    bool isStatic = false,
    bool isCleanup = false,
    int? classId,
  }) {
    final opaque = opaqueParameterIds(
      function?.typeParameters ?? owner?.typeParameters ?? const [],
    );
    validateCallParameters(
      parameters,
      source,
      referenceClasses: module.classes,
      opaqueParameters: opaque,
    );
    validateCallResult(
      result,
      source,
      referenceClasses: module.classes,
      isAsync: function?.isAsync ?? member?.isAsync ?? false,
      isGenerator: function?.isGenerator ?? member?.isGenerator ?? false,
      opaqueParameters: opaque,
    );
    final payload = resultPayload(result);
    return NativeCallPlan._(
      callback: '_native${next++}',
      context: context,
      kind: kind,
      parameters: List.unmodifiable(parameters),
      inputs: List.unmodifiable([
        for (final parameter in parameters)
          conversionFor(
            parameter.type,
            '$context.${parameter.name}',
            bigint: bigint,
            classes: module.classes,
            valueSchemas: valueSchemas,
            direction: ValueDirection.input,
            opaqueParameters: opaque,
          ),
      ]),
      returnsFuture: isCleanup || isFutureType(result),
      returnsStream: isStreamType(result),
      isCleanup: isCleanup,
      output: payload == null
          ? null
          : conversionFor(
              payload,
              '$context result',
              bigint: bigint,
              classes: module.classes,
              valueSchemas: valueSchemas,
              direction: ValueDirection.output,
              opaqueParameters: opaque,
            ),
      function: function,
      owner: owner,
      member: member,
      isStatic: isStatic,
      classId: classId,
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
    _executable(binding.typeParameters, binding.isExternal, binding.source);
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
  final shapes = validateReferenceClasses(module);
  for (final shape in shapes) {
    final binding = shape.binding;
    final classId = classes.length;
    NativeCallPlan member(
      ReferenceMemberShape selected, {
      bool constructor = false,
    }) => call(
      context: constructor
          ? binding.exportName
          : '${binding.exportName}.${selected.exportName}',
      kind: switch (selected.kind) {
        ReferenceMemberKind.constructor =>
          constructor ? NativeCallKind.constructor : NativeCallKind.method,
        ReferenceMemberKind.method => NativeCallKind.method,
        ReferenceMemberKind.getter => NativeCallKind.getter,
        ReferenceMemberKind.setter => NativeCallKind.setter,
      },
      parameters: selected.parameters,
      result: selected.kind == ReferenceMemberKind.constructor && !constructor
          ? binding.instantiatedType ??
                DeclaredType(
                  binding.declaration,
                  ValueSemantics.reference,
                  typeArguments: binding.typeParameters.map(
                    (p) => TypeParameterType(p.declaration),
                  ),
                )
          : selected.result,
      source: selected.binding.source,
      owner: binding,
      member: selected.binding,
      isStatic: !constructor && selected.isStatic,
      isCleanup: selected.isCleanup,
      classId: classId,
    );
    classes.add(
      NativeClassPlan._(
        shape,
        shape.constructor != null
            ? member(shape.constructor!, constructor: true)
            : call(
                context: binding.exportName,
                kind: NativeCallKind.constructor,
                parameters: const [],
                result: null,
                source: binding.source,
                owner: binding,
                classId: classId,
              ),
        List.unmodifiable(shape.members.map(member)),
      ),
    );
  }
  return NativeModulePlan._(
    module,
    List.unmodifiable(functions),
    List.unmodifiable(classes),
    List.unmodifiable(valueSchemas),
    referenceClassOrder(shapes),
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
  bool external,
  SourceLocation source,
) {
  validateOpaqueParameters(types, source);
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
