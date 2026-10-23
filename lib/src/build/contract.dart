import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import '../compiler/analysis/reference_views.dart';
import '../compiler/analysis/result.dart';
import '../compiler/analysis/validate.dart';
import '../compiler/emit/typescript/declarations.dart';
import '../compiler/ir/model.dart';
import '../compiler/ir/defaults.dart';
import '../compiler/lowering/plan.dart';
import '../compiler/native/plan.dart';

/// A portable public-contract fingerprint for separately built artifacts.
/// Native platform selection must not change defaults or conversion policies
/// that are invisible in the shared TypeScript declarations.
Future<Map<String, Object?>> createModuleContract(
  BindingModule bindings,
  List<ReferenceClassShape> classes,
  List<ValueClassSchema> values,
  String declarations, {
  String? packagesPath,
}) async {
  final uris = await _ContractUris.read(
    bindings.source,
    bindings.packageConfigPath ?? packagesPath,
  );
  String declaration(DeclarationId value) => value.owner == null
      ? '${uris.key(value.library)}#${value.name}'
      : '${declaration(value.owner!)}.${value.name}';
  final exports = [
    for (final function in bindings.functions) function.exportName,
    for (final binding in classes) binding.binding.exportName,
  ];
  final contract = _contract(
    bindings,
    classes,
    values,
    parameterKey: (parameter) => parameterDefaultKey(
      parameter,
      declarationSource: declaration,
      omissionKey: (key) => _portableOmissionKey(key, uris.key),
    ),
  );
  return {
    'format': 1,
    'exports': exports,
    'sha256': sha256
        .convert(utf8.encode(jsonEncode([contract, declarations, exports])))
        .toString(),
  };
}

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
  List<ValueClassSchema> values, {
  String Function(ParameterBinding) parameterKey = parameterDefaultKey,
}) {
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
      for (final parameter in parameters) _parameter(parameter, parameterKey),
      _Values(parameterKey).encodeAll([
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
      'value ${schema.binding.exportName}': _Values(parameterKey).encode(
        conversionFor(
          schema.binding.instantiatedType ??
              DeclaredType(
                schema.binding.declaration,
                ValueSemantics.reference,
                typeArguments: [
                  for (final parameter in schema.binding.typeParameters)
                    TypeParameterType(parameter.declaration),
                ],
              ),
          schema.binding.exportName,
          bigint: false,
          classes: bindings.classes,
          valueSchemas: values,
          opaqueParameters: opaqueParameterIds(schema.binding.typeParameters),
        ),
      ),
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

Object _parameter(
  ParameterBinding parameter,
  String Function(ParameterBinding) key,
) => [
  parameter.name,
  parameter.kind.name,
  parameter.presence.name,
  key(parameter),
];

/// Finite conversion nodes keep recursive value classes bounded. This is a
/// build-time comparison; persisted artifacts retain only its fingerprint.
final class _Values {
  final String Function(ParameterBinding) parameterKey;
  _Values(this.parameterKey);
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
          encode(value.inputKey),
          encode(value.inputValue),
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
          if (value.direction == ValueDirection.input)
            value.constructor != null,
          for (final field in value.fields)
            [
              field.name,
              field.parameter == null
                  ? null
                  : _parameter(field.parameter!, parameterKey),
              encode(field.conversion),
            ],
        ],
      },
    ];
  }
}

final class _ContractUris {
  final Uri source;
  final List<(String, Uri)> packages;
  _ContractUris(this.source, this.packages);

  static Future<_ContractUris> read(Uri source, String? packagesPath) async {
    final config = packagesPath == null ? null : File(packagesPath).absolute;
    final packages = <(String, Uri)>[];
    if (config != null && await config.exists()) {
      final value = jsonDecode(await config.readAsString()) as Map;
      for (final package in value['packages'] as List) {
        final root = config.uri.resolve(package['rootUri'] as String);
        final directory = root.path.endsWith('/')
            ? root
            : root.replace(path: '${root.path}/');
        var library = directory.resolve(package['packageUri'] as String? ?? '');
        if (library.scheme == 'file') {
          if (!library.path.endsWith('/')) {
            library = library.replace(path: '${library.path}/');
          }
          packages.add((package['name'] as String, library));
        }
      }
      packages.sort((a, b) => b.$2.path.length.compareTo(a.$2.path.length));
    }
    return _ContractUris(source, packages);
  }

  String key(Uri uri) {
    if (uri.scheme != 'file') return uri.toString();
    for (final (name, root) in packages) {
      if (uri.authority == root.authority && uri.path.startsWith(root.path)) {
        // Keep file imports distinct from package imports of the same library.
        return 'file-package:$name/${uri.path.substring(root.path.length)}';
      }
    }
    if (uri.authority != source.authority) return uri.toString();
    return 'file:${path.posix.relative(uri.path, from: source.resolve('.').path)}';
  }
}

// constantStorageKey contains user strings as well as library URIs. Rewrite
// only type identities so a string default resembling a path stays observable.
String _portableOmissionKey(String key, String Function(Uri) library) {
  Object type(Object value) {
    if (value is! List) return value;
    if (value.first == 'Never') return value;
    if (value.first == 'record') {
      return [
        ...value.take(2),
        for (final field in value.skip(2))
          if (field is List && field.length == 2 && field[1] is! bool)
            [field[0], type(field[1] as Object)]
          else
            type(field as Object),
      ];
    }
    return [
      library(Uri.parse(value[0] as String)),
      ...value.skip(1).take(2),
      for (final argument in value.skip(3)) type(argument as Object),
    ];
  }

  Object? constant(Object? value) {
    if (value is! List) return value;
    return switch (value[0]) {
      'type' => ['type', type(value[1] as Object)],
      'list' || 'set' => [
        value[0],
        type(value[1] as Object),
        for (final child in value.skip(2)) constant(child),
      ],
      'map' => [
        'map',
        type(value[1] as Object),
        for (final pair in value.skip(2))
          [constant((pair as List)[0]), constant(pair[1])],
      ],
      'record' => [
        'record',
        type(value[1] as Object),
        [for (final child in value[2] as List) constant(child)],
        [
          for (final pair in value[3] as List)
            [(pair as List)[0], constant(pair[1])],
        ],
      ],
      'object' => [
        'object',
        type(value[1] as Object),
        for (final pair in value.skip(2))
          [(pair as List)[0], constant(pair[1])],
      ],
      _ => value,
    };
  }

  return jsonEncode(constant(jsonDecode(key)));
}
