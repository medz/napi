import '../../../api/annotation.dart' show ClassPolicy;
import '../../analysis/validate.dart';
import '../../analysis/result.dart';
import '../../ir/model.dart';
import '../../lowering/plan.dart';
import 'values.dart';

String emitDeclarations(ModulePlan plan) => emitBindingDeclarations(
  functions: plan.functions.map((f) => f.binding).toList(),
  classes: plan.allClasses,
  references: plan.classes.map((c) => c.shape).toList(),
  values: plan.valueSchemas,
);

typedef _DeclarationCall = ({
  List<ParameterBinding> parameters,
  List<ValueConversion> inputs,
  ValueConversion? output,
  bool returnsFuture,
  bool returnsStream,
});

/// One declaration emitter consumes already-validated public shapes. It never
/// applies one backend's name or execution restrictions to the other backend.
String emitBindingDeclarations({
  required List<FunctionBinding> functions,
  required List<ClassBinding> classes,
  required List<ReferenceClassShape> references,
  required List<ValueClassSchema> values,
}) {
  _DeclarationCall call(
    List<ParameterBinding> parameters,
    BindingType? result,
    List<TypeParameterBinding> types, {
    bool bigint = false,
    bool cleanup = false,
  }) {
    final opaque = opaqueParameterIds(types);
    final payload = resultPayload(result);
    return (
      parameters: parameters,
      inputs: [
        for (final parameter in parameters)
          conversionFor(
            parameter.type,
            parameter.name,
            bigint: bigint,
            classes: classes,
            valueSchemas: values,
            direction: ValueDirection.input,
            opaqueParameters: opaque,
          ),
      ],
      output: payload == null
          ? null
          : conversionFor(
              payload,
              'result',
              bigint: bigint,
              classes: classes,
              valueSchemas: values,
              opaqueParameters: opaque,
            ),
      returnsFuture: cleanup || isFutureType(result),
      returnsStream: isStreamType(result),
    );
  }

  final functionCalls = {
    for (final function in functions)
      function: call(
        function.parameters,
        function.result,
        function.typeParameters,
        bigint: function.bigint,
      ),
  };
  final memberCalls = {
    for (final shape in references)
      for (final member in [?shape.constructor, ...shape.members])
        member: call(
          member.parameters,
          member.result,
          shape.binding.typeParameters,
          cleanup: member.isCleanup,
        ),
  };
  final projectedCalls = <(int, ReferenceMemberRef), _DeclarationCall>{};
  _DeclarationCall viewCall(ReferenceClassShape scope, ReferenceMemberRef ref) {
    final owner = references[ref.classId];
    final member = owner.members[ref.memberIndex];
    if (owner.classId == scope.classId ||
        scope.ancestorArguments.isEmpty && owner.ancestorArguments.isEmpty) {
      return memberCalls[member]!;
    }
    return projectedCalls.putIfAbsent((scope.classId, ref), () {
      final projected = referenceMemberInScope(member, owner, scope)!;
      for (final type in [
        for (final parameter in projected.parameters) parameter.type,
        ?projected.result,
      ]) {
        validateOpaqueReferenceNames(
          type,
          scope.binding.source,
          classes,
          opaqueParameterIds(scope.binding.typeParameters),
        );
      }
      return call(
        projected.parameters,
        projected.result,
        scope.binding.typeParameters,
        cleanup: member.isCleanup,
      );
    });
  }

  final genericHierarchy = references.any(
    (c) => c.ancestorArguments.isNotEmpty,
  );
  final calls = [...functionCalls.values, ...memberCalls.values];
  final conversions = [
    for (final call in calls) ...[...call.inputs, ?call.output],
  ];
  final hasResources = classes.any(
    (c) => c.classPolicy == ClassPolicy.resource,
  );
  bool callable(_DeclarationCall call) =>
      call.returnsFuture ||
      call.returnsStream ||
      call.parameters.any((p) => p.kind != ParameterKind.requiredPositional) ||
      call.inputs.any(
        (c) =>
            c is ReferenceConversion ||
            c is CallbackConversion ||
            c is OpaqueConversion ||
            c is AbortSignalConversion,
      ) ||
      call.output is ReferenceConversion ||
      call.output is OpaqueConversion ||
      (hasResources &&
          conversionGraph(call.inputs).any((c) => c is ReferenceConversion));
  return [
    if (genericHierarchy)
      r'type $napiInvariant<in out T> = { readonly value: T };',
    ...emitPromiseResolutionDeclarations(
      calls.where((call) => call.returnsFuture).map((call) => call.output),
    ),
    if (values.isNotEmpty)
      emitValueDeclarations(
        classes,
        values,
        conversions,
        reservedNames: {for (final function in functions) function.exportName},
      ),
    '// Generated declarations for the binding module.',
    for (final function in functions)
      ...emitFunctionDeclarations(
        function.exportName,
        function.parameters,
        functionCalls[function]!.inputs,
        functionCalls[function]!.output,
        function.typeParameters,
        returnsFuture: functionCalls[function]!.returnsFuture,
        returnsStream: functionCalls[function]!.returnsStream,
        callable: callable(functionCalls[function]!),
      ),
    for (final shape in references) ...[
      'export declare class ${shape.binding.exportName}${emitTypeParameters(shape.binding.typeParameters, invariant: true)} {',
      if (shape.binding.typeParameters.isNotEmpty)
        '  ${emitOpaquePhantom(shape.binding.typeParameters, classId: genericHierarchy ? shape.classId : null)}',
      '  private readonly \$napiReference${shape.classId}: void;',
      if (shape.constructor case final constructor?)
        for (final parameters in emitParameterVariants(
          constructor.parameters,
          memberCalls[constructor]!.inputs,
        ))
          '  constructor($parameters);'
      else
        '  private constructor();',
      for (final (member, declaration) in [
        for (final member in shape.members.where((member) => member.isStatic))
          (member, memberCalls[member]!),
        for (final property in shape.prototypeProperties)
          for (final ref in [
            ?property.method,
            ?property.getter,
            ?property.setter,
          ])
            (
              references[ref.classId].members[ref.memberIndex],
              viewCall(shape, ref),
            ),
      ])
        for (final parameters in emitParameterVariants(
          declaration.parameters,
          declaration.inputs,
        ))
          switch (member.kind) {
            ReferenceMemberKind.method =>
              '  ${member.isStatic ? 'static ' : ''}${emitMemberName(member.exportName)}($parameters): ${emitResult(declaration.output, returnsFuture: member.returnsFuture, returnsStream: member.returnsStream)};',
            ReferenceMemberKind.getter =>
              '  ${member.isStatic ? 'static ' : ''}get ${emitMemberName(member.exportName)}(): ${emitResult(declaration.output, returnsFuture: member.returnsFuture, returnsStream: member.returnsStream)};',
            ReferenceMemberKind.setter =>
              '  ${member.isStatic ? 'static ' : ''}set ${emitMemberName(member.exportName)}($parameters);',
            ReferenceMemberKind.constructor =>
              '  static ${emitMemberName(member.exportName)}${emitTypeParameters(shape.binding.typeParameters)}($parameters): ${shape.binding.exportName}${emitLogicalTypeArguments(shape.binding.typeParameters)};',
          },
      ...emitWriteOnlyReads(shape, references, (ref) {
        final member = references[ref.classId].members[ref.memberIndex];
        if (referenceMemberInScope(member, references[ref.classId], shape) !=
            null) {
          return emitResult(
            viewCall(shape, ref).output,
            returnsFuture: member.returnsFuture,
            returnsStream: member.returnsStream,
          );
        }
        return emitViewGetterResult(
          memberCalls[member]!.output,
          returnsFuture: member.returnsFuture,
          returnsStream: member.returnsStream,
        );
      }),
      '}',
      ...emitReferenceInheritance(shape, references),
    ],
    '',
  ].join('\n');
}

String emitTypeParameters(
  List<TypeParameterBinding> parameters, {
  bool invariant = false,
}) => parameters.isEmpty
    ? ''
    : '<${parameters.map((p) => '${invariant ? 'in out ' : ''}${p.declaration.name} = unknown').join(', ')}>';

String emitLogicalTypeArguments(List<TypeParameterBinding> parameters) =>
    parameters.isEmpty
    ? ''
    : '<${parameters.map((p) => p.declaration.name).join(', ')}>';

String emitOpaquePhantom(
  List<TypeParameterBinding> parameters, {
  int? classId,
}) {
  final tuple = '[${parameters.map((p) => p.declaration.name).join(', ')}]';
  return classId == null
      ? 'private readonly \$napiOpaque: (types: $tuple) => $tuple;'
      : 'private readonly \$napiOpaque$classId: \$napiInvariant<$tuple>;';
}

Iterable<String> emitFunctionDeclarations(
  String name,
  List<ParameterBinding> parameters,
  List<ValueConversion> inputs,
  ValueConversion? output,
  List<TypeParameterBinding> types, {
  required bool returnsFuture,
  bool returnsStream = false,
  required bool callable,
}) sync* {
  final variants = emitParameterVariants(parameters, inputs).toList();
  final generics = emitTypeParameters(types);
  final result = emitResult(
    output,
    returnsFuture: returnsFuture,
    returnsStream: returnsStream,
  );
  if (callable && variants.length > 1) {
    yield 'export declare const $name: {';
    for (final parameters in variants) {
      yield '  $generics($parameters): $result;';
    }
    yield '};';
  } else {
    for (final parameters in variants) {
      yield callable
          ? 'export declare const $name: $generics($parameters) => $result;'
          : 'export declare function $name$generics($parameters): $result;';
    }
  }
}

/// Opaque optional positions distinguish omission from supplied undefined.
Iterable<String> emitParameterVariants(
  List<ParameterBinding> parameters,
  List<ValueConversion> inputs,
) sync* {
  if (!parameters.any(
    (p) =>
        p.kind == ParameterKind.optionalPositional &&
        p.presence == ParameterPresence.opaqueOptional,
  )) {
    yield emitParameters(parameters, inputs);
    return;
  }
  final firstOptional = parameters.indexWhere(
    (p) => p.kind == ParameterKind.optionalPositional,
  );
  for (var length = firstOptional; length <= parameters.length; length++) {
    yield emitParameters(
      parameters.take(length).toList(),
      inputs.take(length).toList(),
      suppliedOptionals: true,
    );
  }
}

/// Promise resolution assimilates a root payload's callable `then` member.
String emitResult(
  ValueConversion? output, {
  required bool returnsFuture,
  bool returnsStream = false,
}) {
  final payload = output?.typescriptType ?? 'void';
  if (returnsStream) {
    return 'globalThis.AsyncIterableIterator<$payload, undefined, undefined>';
  }
  if (!returnsFuture) return payload;
  final resolved = _needsPromiseResolution(output)
      ? '\$napiAwaited<$payload>'
      : payload;
  return 'globalThis.Promise<$resolved>';
}

bool _needsPromiseResolution(ValueConversion? output) =>
    output is OpaqueConversion || output is ReferenceConversion;

/// Unlike TypeScript's Awaited, distribute a nullable or union-valued `then`:
/// its callable branch resolves, while its non-callable branch returns T.
/// Public export and generic identifiers cannot contain `$`.
Iterable<String> emitPromiseResolutionDeclarations(
  Iterable<ValueConversion?> outputs,
) sync* {
  if (outputs.any(_needsPromiseResolution)) {
    yield r'''type $napiAwaited<T> = unknown extends T ? unknown : T extends object
  ? 'then' extends keyof T
    ? T['then'] extends infer F
      ? unknown extends F ? unknown
        : F extends (onfulfilled: infer C, ...args: any[]) => any
          ? C extends (value: infer V, ...args: any[]) => any ? $napiAwaited<V> : never
          : F extends globalThis.Function ? unknown : T
      : never
    : T
  : T;''';
  }
}

/// A getter supplied by another view has no known generic arguments.
String emitViewGetterResult(
  ValueConversion? output, {
  required bool returnsFuture,
  bool returnsStream = false,
}) {
  if (output != null &&
      conversionGraph([output]).any(
        (value) =>
            value is OpaqueConversion ||
            value is ReferenceConversion && value.typeArguments.isNotEmpty,
      )) {
    return returnsStream
        ? 'globalThis.AsyncIterableIterator<unknown, undefined, undefined>'
        : returnsFuture
        ? 'globalThis.Promise<unknown>'
        : 'unknown';
  }
  return emitResult(
    output,
    returnsFuture: returnsFuture,
    returnsStream: returnsStream,
  );
}

/// Missing accessors read undefined, but composed views can supply a getter.
Iterable<String> emitWriteOnlyReads(
  ReferenceClassShape shape,
  List<ReferenceClassShape> classes,
  String Function(ReferenceMemberRef) getterType,
) sync* {
  for (final property in shape.prototypeProperties) {
    if (property.setter == null || property.getter != null) continue;
    final setter = classes[property.setter!.classId]
        .members[property.setter!.memberIndex]
        .binding;
    final types = <String>{'undefined'};
    for (final view in classes) {
      for (final candidate in view.prototypeProperties) {
        final ref = candidate.getter;
        if (candidate.name != property.name || ref == null) continue;
        final getter = classes[ref.classId].members[ref.memberIndex].binding;
        // Match the same target used by runtime composite descriptors. Different
        // Dart members renamed to one JS name conflict instead of composing.
        if (getter.declaration.name != setter.declaration.name ||
            (getter.callPath ?? getter.declaration.name) !=
                (setter.callPath ?? setter.declaration.name)) {
          continue;
        }
        var type = getterType(ref);
        // A newly referenced view type must not resolve to this class's generic.
        if (!shape.memberships.contains(ref.classId) &&
            !classes[ref.classId].memberships.contains(shape.classId) &&
            shape.binding.typeParameters.any(
              (parameter) =>
                  RegExp('\\b${parameter.declaration.name}\\b').hasMatch(type),
            )) {
          type = 'unknown';
        }
        types.add(type);
      }
    }
    final result = types.contains('unknown') ? 'unknown' : types.join(' | ');
    yield '  get ${emitMemberName(property.name)}(): $result;';
  }
  final staticGetters = {
    for (final member in shape.members)
      if (member.isStatic && member.kind == ReferenceMemberKind.getter)
        member.exportName,
  };
  for (final member in shape.members) {
    if (member.isStatic &&
        member.kind == ReferenceMemberKind.setter &&
        !staticGetters.contains(member.exportName)) {
      yield '  static get ${emitMemberName(member.exportName)}(): undefined;';
    }
  }
}

/// Merge only the instance type. `class Child extends Base` would incorrectly
/// expose inherited static methods and named constructors.
Iterable<String> emitReferenceInheritance(
  ReferenceClassShape shape,
  List<ReferenceClassShape> classes,
) sync* {
  final nearest = referenceParents(shape, classes);
  if (nearest.isNotEmpty) {
    String parent(int id) {
      final slots = shape.ancestorArguments[id];
      final arguments = slots == null
          ? ''
          : '<${slots.map((slot) => shape.binding.typeParameters[slot].declaration.name).join(', ')}>';
      return '${classes[id].binding.exportName}$arguments';
    }

    yield 'export interface ${shape.binding.exportName}${emitTypeParameters(shape.binding.typeParameters, invariant: true)} extends '
        '${nearest.map(parent).join(', ')} {}';
  }
}

/// TypeScript parses an unquoted constructor method as a class constructor.
String emitMemberName(String name) =>
    name == 'constructor' ? '["constructor"]' : name;

String emitParameters(
  List<ParameterBinding> parameters,
  List<ValueConversion> inputs, {
  bool suppliedOptionals = false,
}) {
  final positional = parameters.indexed.where(
    (entry) =>
        entry.$2.kind == ParameterKind.requiredPositional ||
        entry.$2.kind == ParameterKind.optionalPositional,
  );
  final named = parameters.indexed.where(
    (entry) =>
        entry.$2.kind == ParameterKind.requiredNamed ||
        entry.$2.kind == ParameterKind.optionalNamed,
  );
  final used = positional
      .where((entry) => entry.$2.name != '_')
      .map((entry) => entry.$2.name)
      .toSet();
  var wildcard = 0;
  final result = <String>[];
  for (final (index, parameter) in positional) {
    var name = parameter.name;
    if (name == '_') {
      do {
        name = 'arg${wildcard++}';
      } while (!used.add(name));
    }
    final optional = parameter.kind == ParameterKind.optionalPositional;
    final explicitUndefined =
        suppliedOptionals &&
        optional &&
        parameter.presence == ParameterPresence.optional;
    result.add(
      '$name${optional && !suppliedOptionals ? '?' : ''}: ${inputs[index].typescriptType}${explicitUndefined ? ' | undefined' : ''}',
    );
  }
  if (named.isNotEmpty) {
    var name = 'options';
    var suffix = 0;
    while (used.contains(name)) {
      name = 'options${++suffix}';
    }
    final required = named.any(
      (entry) => entry.$2.kind == ParameterKind.requiredNamed,
    );
    final properties = [
      for (final (index, parameter) in named)
        '${parameter.name}${parameter.kind == ParameterKind.optionalNamed ? '?' : ''}: ${inputs[index].typescriptType}${parameter.kind == ParameterKind.optionalNamed && parameter.presence == ParameterPresence.optional ? ' | undefined' : ''}',
    ].join('; ');
    result.add('$name${required ? '' : '?'}: { $properties }');
  }
  return result.join(', ');
}
