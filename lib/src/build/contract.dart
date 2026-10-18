import 'dart:convert';

import '../compiler/analysis/reference_views.dart';
import '../compiler/analysis/result.dart';
import '../compiler/analysis/validate.dart';
import '../compiler/emit/typescript/declarations.dart';
import '../compiler/ir/model.dart';
import '../compiler/lowering/plan.dart';
import '../compiler/native/plan.dart';

/// Compare public behavior after resolving each target's conditional imports.
/// Declaration locations and private implementation names need not agree.
String validatePackageContracts(BindingModule wasm, BindingModule native) {
  final a = validate(wasm);
  final b = validateNative(native);
  final nativeClasses = b.classes.map((c) => c.shape).toList();
  final left = _contract(a.bindings, a.classes, a.valueSchemas);
  final right = _contract(b.bindings, nativeClasses, b.valueSchemas);
  for (final key in {...left.keys, ...right.keys}) {
    if (jsonEncode(left[key]) != jsonEncode(right[key])) {
      throw BindingDiagnostic(
        'NAPI_PACKAGE_CONTRACT',
        'Native and Wasm package contracts differ at $key. '
            'Use matching ordered public declarations, conversion policies and defaults.',
        _location(native, key),
      );
    }
  }
  final declarations = emitBindingDeclarations(
    functions: wasm.functions,
    classes: wasm.classes,
    references: a.classes,
    values: a.valueSchemas,
  );
  if (declarations !=
      emitBindingDeclarations(
        functions: native.functions,
        classes: native.classes,
        references: nativeClasses,
        values: b.valueSchemas,
      )) {
    throw BindingDiagnostic(
      'NAPI_PACKAGE_CONTRACT',
      'Native and Wasm public TypeScript declarations differ.',
      SourceLocation(native.source, 0, 0),
    );
  }
  return declarations;
}

SourceLocation _location(BindingModule module, String key) {
  for (final function in module.functions) {
    if (key == 'function ${function.exportName}') return function.source;
  }
  for (final binding in module.classes) {
    if (key == 'class ${binding.exportName}' ||
        key == 'value ${binding.exportName}') {
      return binding.source;
    }
  }
  return SourceLocation(module.source, 0, 0);
}

Map<String, Object?> _contract(
  BindingModule bindings,
  List<ReferenceClassShape> classes,
  List<ValueClassSchema> values,
) {
  Object call(
    List<ParameterBinding> parameters,
    BindingType? result,
    List<TypeParameterBinding> types, {
    bool bigint = false,
    bool cleanup = false,
  }) {
    final opaque = opaqueParameterIds(types);
    final payload = resultPayload(result);
    return [
      cleanup || isFutureType(result),
      isStreamType(result),
      for (final parameter in parameters) _parameter(parameter),
      _Values().encodeAll([
        for (final parameter in parameters)
          conversionFor(
            parameter.type,
            parameter.name,
            bigint: bigint,
            classes: bindings.classes,
            valueSchemas: values,
            direction: ValueDirection.input,
            opaqueParameters: opaque,
          ),
        payload == null
            ? null
            : conversionFor(
                payload,
                'result',
                bigint: bigint,
                classes: bindings.classes,
                valueSchemas: values,
                opaqueParameters: opaque,
              ),
      ]),
    ];
  }

  final owners = resourcePolicies(classes);
  return {
    for (final function in bindings.functions)
      'function ${function.exportName}': call(
        function.parameters,
        function.result,
        function.typeParameters,
        bigint: function.bigint,
      ),
    for (final c in classes)
      'class ${c.binding.exportName}': [
        c.binding.classPolicy.name,
        c.memberships.toList()..sort(),
        c.superclassId,
        if (c.ancestorArguments.isNotEmpty)
          [
            for (final id in c.ancestorArguments.keys.toList()..sort())
              [id, c.ancestorArguments[id]],
          ],
        owners[c.classId],
        if (c.constructor case final constructor?)
          call(
            constructor.parameters,
            constructor.result,
            c.binding.typeParameters,
          ),
        for (final member in c.members)
          [
            member.exportName,
            member.kind.name,
            member.isStatic,
            member.isCleanup,
            if (member.binding.typeParameters.isNotEmpty)
              member.binding.typeParameters.length,
            call(
              member.parameters,
              member.result,
              referenceCallTypeParameters(c.binding, member.binding),
              cleanup: member.isCleanup,
            ),
          ],
      ],
    'reference views': _views(classes),
    for (final schema in values)
      'value ${schema.binding.exportName}': [
        schema.constructor != null,
        for (final field in schema.inputFields)
          [field.field.name, _parameter(field.parameter)],
        _Values().encodeAll([
          for (final direction in [
            ValueDirection.output,
            if (schema.constructor != null) ValueDirection.input,
          ])
            conversionFor(
              schema.binding.instantiatedType ??
                  DeclaredType(
                    schema.binding.declaration,
                    ValueSemantics.reference,
                  ),
              schema.binding.exportName,
              bigint: false,
              classes: bindings.classes,
              valueSchemas: values,
              direction: direction,
            ),
        ]),
      ],
  };
}

// Compare target equivalence, not implementation spelling. Getter/setter pairs
// also need the same Dart target even though their operation contracts differ.
Object _views(List<ReferenceClassShape> classes) {
  final contracts = referenceViewContracts(classes);
  final targets = <(String, String, String), int>{};
  int target(ReferencePropertyShape property) {
    final ref = property.method ?? property.getter ?? property.setter!;
    final member = classes[ref.classId].members[ref.memberIndex].binding;
    return targets.putIfAbsent((
      property.name,
      member.declaration.name,
      member.callPath ?? member.declaration.name,
    ), () => targets.length);
  }

  return [
    for (final c in classes)
      [
        for (final property in c.prototypeProperties)
          [
            property.name,
            target(property),
            for (final ref in [
              property.method,
              property.getter,
              property.setter,
            ])
              ref == null ? null : contracts.ids[ref],
          ],
      ],
    [for (final accepted in contracts.accepts) accepted.toList()..sort()],
    concreteReferenceGroups(classes),
  ];
}

Object _parameter(ParameterBinding parameter) {
  var value = parameter.defaultValue?.value;
  if (value is int) {
    if (parameter.type case DeclaredType(:final declaration)
        when declaration.library == Uri.parse('dart:core') &&
            declaration.name == 'double') {
      value = value.toDouble();
    }
  }
  return [
    parameter.name,
    parameter.kind.name,
    parameter.presence.name,
    // String encoding retains NaN/infinity and the sign of zero, unlike JSON
    // numbers. Compare the actual omitted Dart value, including implicit null
    // and an integer constant normalized to its declared double parameter type.
    if (value != null)
      [value.runtimeType.toString(), value.toString()]
    else
      null,
  ];
}

/// Finite conversion nodes keep recursive value classes bounded. This is a
/// build-time comparison only, not a persisted schema or runtime registry.
final class _Values {
  final _seen = <ValueConversion, int>{};
  Object encodeAll(List<ValueConversion?> values) => [
    for (final value in values) encode(value),
  ];

  Object? encode(ValueConversion? value) {
    if (value == null) return null;
    if (_seen[value] case final index?) return ['ref', index];
    _seen[value] = _seen.length;
    return [
      value.nullable,
      switch (value) {
        ScalarConversion() => [
          'scalar',
          value.kind.name,
          value.kind == ScalarKind.integer && value.bigint,
        ],
        BinaryConversion() => ['binary', value.kind.name],
        SharedBytesConversion() => ['sharedBytes'],
        JsCollectionConversion() => [
          'jsCollection',
          value.isMap,
          encode(value.key),
          encode(value.value),
        ],
        AbortSignalConversion() => ['abortSignal'],
        OpaqueConversion() => ['opaque', value.parameter.name],
        ReferenceConversion() => ['reference', value.typescriptType],
        CallbackConversion() => [
          'callback',
          value.returnsFuture,
          encodeAll(value.inputs),
          encode(value.output),
        ],
        ListConversion() => ['list', encode(value.element)],
        MapConversion() => ['map', encode(value.key), encode(value.value)],
        DictionaryConversion() => ['dictionary', encode(value.value)],
        RecordConversion() => [
          'record',
          encodeAll(value.positional),
          for (final name in value.named.keys.toList()..sort())
            [name, encode(value.named[name])],
        ],
        ValueClassConversion() => [
          'value',
          value.classBinding.exportName,
          value.direction.name,
          for (final field in value.fields)
            [
              field.name,
              field.parameter == null ? null : _parameter(field.parameter!),
              encode(field.conversion),
            ],
        ],
      },
    ];
  }
}
