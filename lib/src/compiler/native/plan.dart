import '../../api/annotation.dart';
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
    _parameters(parameters, source);
    for (final parameter in parameters) {
      _scalar(parameter.type, parameter.source ?? source);
    }
    if (result != null && result is! VoidType) _scalar(result, source);
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
  for (final binding in module.classes) {
    _name(binding.exportName, binding.source, topLevel: true);
    _path(binding.callPath, binding.source);
    if (binding.exportSurface != module.source) {
      _reject(
        'NAPI_LIBRARY',
        'The class must be exposed by the selected entry library.',
        binding.source,
      );
    }
    if (binding.classPolicy != ClassPolicy.reference || binding.isAbstract) {
      _reject(
        'NAPI_CLASS',
        'Native bindings require a concrete reference class.',
        binding.source,
      );
    }
    if (binding.typeParameters.isNotEmpty) {
      _reject(
        'NAPI_GENERIC',
        'Native generic specialization is not implemented.',
        binding.source,
      );
    }
    NativeCallPlan? constructor;
    final members = <NativeCallPlan>[];
    for (final member in binding.members) {
      if (member.selection == MemberSelection.excluded) continue;
      _executable(
        member.typeParameters,
        member.isAsync,
        member.isGenerator,
        member.isExternal,
        member.source,
      );
      if (member.kind == MemberKind.constructor) {
        if (member.declaration.name != 'new' ||
            member.isFactory ||
            member.hasExplicitExportName) {
          _reject(
            'NAPI_CONSTRUCTOR',
            'Native named, factory and renamed constructors are not implemented.',
            member.source,
          );
        }
        constructor = call(
          context: binding.exportName,
          kind: NativeCallKind.constructor,
          parameters: member.parameters,
          result: null,
          source: member.source,
          owner: binding,
          member: member,
        );
        continue;
      }
      final memberName = member.exportName ?? member.declaration.name;
      _name(memberName, member.source);
      if ((!member.isStatic && memberName == 'constructor') ||
          (member.isStatic &&
              const {'length', 'prototype'}.contains(memberName))) {
        _reject(
          'NAPI_NAME',
          'Native member $memberName conflicts with the JavaScript class shape.',
          member.source,
        );
      }
      if (member.isOperator) {
        _reject(
          'NAPI_MEMBER',
          'Native operators are not implemented.',
          member.source,
        );
      }
      _path(member.callPath ?? member.declaration.name, member.source);
      final context =
          '${binding.exportName}.${member.exportName ?? member.declaration.name}';
      if (member.kind == MemberKind.field) {
        if (member.type == null) {
          _reject(
            'NAPI_TYPE',
            'A field requires its resolved type.',
            member.source,
          );
        }
        members.add(
          call(
            context: context,
            kind: NativeCallKind.getter,
            parameters: const [],
            result: member.type,
            source: member.source,
            owner: binding,
            member: member,
          ),
        );
        if (!member.isFinal && !member.isConst) {
          members.add(
            call(
              context: context,
              kind: NativeCallKind.setter,
              parameters: [ParameterBinding('value', member.type!)],
              result: null,
              source: member.source,
              owner: binding,
              member: member,
            ),
          );
        }
      } else {
        if (member.result == null) {
          _reject(
            'NAPI_TYPE',
            'A member requires its resolved result type.',
            member.source,
          );
        }
        final kind = switch (member.kind) {
          MemberKind.method => NativeCallKind.method,
          MemberKind.getter => NativeCallKind.getter,
          MemberKind.setter => NativeCallKind.setter,
          _ => throw StateError('Handled above'),
        };
        if ((kind == NativeCallKind.getter && member.parameters.isNotEmpty) ||
            (kind == NativeCallKind.setter &&
                (member.parameters.length != 1 ||
                    member.parameters.single.kind !=
                        ParameterKind.requiredPositional))) {
          _reject(
            'NAPI_MEMBER',
            'Invalid getter or setter parameter shape.',
            member.source,
          );
        }
        members.add(
          call(
            context: context,
            kind: kind,
            parameters: member.parameters,
            result: member.kind == MemberKind.setter ? null : member.result,
            source: member.source,
            owner: binding,
            member: member,
          ),
        );
      }
    }
    if (constructor == null) {
      _reject(
        'NAPI_CONSTRUCTOR',
        'Native classes require a selected public unnamed constructor.',
        binding.source,
      );
    }
    classes.add(
      NativeClassPlan._(binding, constructor, List.unmodifiable(members)),
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

void _scalar(BindingType type, SourceLocation source) {
  if (type.nullability != TypeNullability.legacy &&
      (type is SafeIntType ||
          type is DeclaredType &&
              type.declaration.library == Uri.parse('dart:core') &&
              type.declaration.kind == DeclarationKind.classType &&
              type.declaration.owner == null &&
              type.typeArguments.isEmpty &&
              type.semantics == ValueSemantics.scalar &&
              const {
                'bool',
                'String',
                'double',
                'BigInt',
              }.contains(type.declaration.name))) {
    return;
  }
  _reject(
    'NAPI_TYPE',
    'No native scalar conversion for this ${type.semantics.name} type.',
    source,
  );
}

void _parameters(List<ParameterBinding> parameters, SourceLocation source) {
  var optionalPositional = false;
  var named = false;
  for (final parameter in parameters) {
    final location = parameter.source ?? source;
    if (!_identifier.hasMatch(parameter.name) ||
        (_reserved.contains(parameter.name) &&
            !const {'eval', 'arguments'}.contains(parameter.name))) {
      _reject(
        'NAPI_PARAMETER',
        'Unsupported native parameter identifier.',
        location,
      );
    }
    final optional =
        parameter.kind == ParameterKind.optionalPositional ||
        parameter.kind == ParameterKind.optionalNamed;
    if (parameter.presence !=
        (optional ? ParameterPresence.optional : ParameterPresence.required)) {
      _reject(
        'NAPI_PRESENCE',
        'Opaque presence requires the opaque conversion engine.',
        location,
      );
    }
    switch (parameter.kind) {
      case ParameterKind.requiredPositional:
        if (optionalPositional || named) {
          _reject(
            'NAPI_PARAMETER',
            'Required positional parameters must come first.',
            location,
          );
        }
      case ParameterKind.optionalPositional:
        if (named) {
          _reject(
            'NAPI_PARAMETER',
            'Optional positional and named parameters cannot mix.',
            location,
          );
        }
        optionalPositional = true;
      case ParameterKind.requiredNamed || ParameterKind.optionalNamed:
        if (optionalPositional) {
          _reject(
            'NAPI_PARAMETER',
            'Optional positional and named parameters cannot mix.',
            location,
          );
        }
        named = true;
    }
    if (!optional && parameter.hasDefault) {
      _reject(
        'NAPI_DEFAULT',
        'Required parameters cannot have defaults.',
        location,
      );
    }
    if (optional) validateParameterDefault(parameter, source);
  }
}

Never _reject(String code, String message, SourceLocation source) =>
    throw BindingDiagnostic(code, message, source);
