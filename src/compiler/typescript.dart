import 'dart:convert';

import 'exports.dart';

String typeScriptDeclarations(ExportModule exports, {bool esm = false}) =>
    _Writer(exports, esm: esm).write();

final class _Writer {
  _Writer(this.exports, {required this.esm})
    : _names = {
        ...exports.classes.map((value) => value.name),
        ...exports.functions.map((value) => value.name),
        ...exports.enums.map((value) => value.name),
        ...exports.constants.map((value) => value.name),
        ...exports.properties.map((value) => value.name),
      } {
    for (final cls in exports.classes) {
      _registerParameters(cls.typeParameters);
      for (final function in [
        if (cls.constructor != null) cls.constructor!,
        ...cls.methods,
        ...cls.staticMethods,
      ]) {
        _registerSignature(function.signature, enclosing: cls.typeParameters);
      }
      for (final property in [...cls.properties, ...cls.staticProperties]) {
        if (property.readType != null) {
          _registerType(property.readType!, cls.typeParameters);
        }
        if (property.writeType != null) {
          _registerType(property.writeType!, cls.typeParameters);
        }
      }
    }
    for (final function in exports.functions) {
      _registerSignature(function.signature);
    }
    for (final constant in exports.constants) {
      _registerType(constant.type, const []);
    }
    for (final property in exports.properties) {
      if (property.readType != null) {
        _registerType(property.readType!, const []);
      }
      if (property.writeType != null) {
        _registerType(property.writeType!, const []);
      }
    }
    for (final cls in exports.classes.where((cls) => cls.isObject)) {
      _objects[cls] = (
        output: _unique('_NapiObjectOutput${_objects.length}'),
        fields: _unique('_NapiObjectFields${_objects.length}'),
        input: _unique('_NapiObjectInput${_objects.length}'),
        inputs: [
          for (final parameter in cls.typeParameters)
            _unique('${_parameterNames[parameter]}Input'),
        ],
      );
    }
    for (final cls in exports.classes.where((cls) => !cls.isObject)) {
      if (cls.typeParameters.isEmpty &&
          !_classes.containsKey(cls.superclass?.classExport)) {
        continue;
      }
      _classes[cls] = (
        shape: _unique('_NapiClass${_classes.length}'),
        inputs: [
          for (final parameter in cls.typeParameters)
            _unique('${_parameterNames[parameter]}Input'),
        ],
        modes: [
          for (final parameter in cls.typeParameters)
            _unique('${_parameterNames[parameter]}Mode'),
        ],
      );
      _classParameters.addAll(cls.typeParameters);
    }
    _inputKey = _unique('_napiInput');
    _inputOf = _unique('_NapiInput');
    _same = _unique('_NapiSame');
    _projection = _unique('_NapiProjection');
    _scalar = _unique('_NapiScalar');
    _awaited = _unique('_NapiAwaited');
    _opaqueKey = _unique('_napiOpaque');
    _opaque = _unique('_NapiOpaque');
    _mode = _unique('_NapiMode');
    for (final cls in _objects.keys) {
      _classParameters.addAll(cls.typeParameters);
      final arguments = <ExportTypeParameter, ExportType>{};
      final parameters = _substituteParameters(cls.typeParameters, arguments);
      _inputParameters[cls] = parameters;
      _classParameters.addAll(parameters);
    }
    _analyzeDifferences();
  }
  final ExportModule exports;
  final bool esm;
  final Set<String> _names;
  final _parameterNames = <ExportTypeParameter, String>{};
  final _parameterIds = <ExportTypeParameter, int>{};
  final _objects =
      <
        ExportClass,
        ({String output, String fields, String input, List<String> inputs})
      >{};
  final _rawObjects = <ExportClass, ({String output, String input})>{};
  final _classes =
      <
        ExportClass,
        ({String shape, List<String> inputs, List<String> modes})
      >{};
  final _rawViews = <({ExportClass cls, bool output})>{};
  final _differences = <_ObjectPair, _Difference>{};
  final _pendingDifferences = <_ObjectPair>[];
  final _inputParameters = <ExportClass, List<ExportTypeParameter>>{};
  final _classParameters = <ExportTypeParameter>{};
  final _mixedPairs = <_TypePair>[];
  final _parameterTypes =
      <ExportTypeParameter, ({String output, String input})>{};
  final _parameterModes = <ExportTypeParameter, String>{};
  final _opaqueParameters = <ExportTypeParameter>{};
  late final String _inputKey;
  late final String _inputOf;
  late final String _same;
  late final String _projection;
  late final String _scalar;
  late final String _awaited;
  late final String _opaqueKey;
  late final String _opaque;
  late final String _mode;

  bool get _hasMetadata => _objects.isNotEmpty || _classes.isNotEmpty;

  String _unique(String name) {
    while (_names.contains(name) || _parameterNames.containsValue(name)) {
      name += '_';
    }
    _names.add(name);
    return name;
  }

  void _registerParameters(
    List<ExportTypeParameter> parameters, {
    List<ExportTypeParameter> enclosing = const [],
  }) {
    final used = {
      for (final parameter in enclosing) _parameterNames[parameter]!,
    };
    for (final parameter in parameters) {
      final existing = _parameterNames[parameter];
      if (existing != null) {
        used.add(existing);
        continue;
      }
      var name = RegExp(r'^[a-zA-Z_$][a-zA-Z0-9_$]*$').hasMatch(parameter.name)
          ? parameter.name
          : 'T';
      while (_reservedParameterNames.contains(name) ||
          _names.contains(name) ||
          used.contains(name)) {
        name += '_';
      }
      _parameterNames[parameter] = name;
      used.add(name);
    }
  }

  void _registerSignature(
    ExportSignature signature, {
    List<ExportTypeParameter> enclosing = const [],
  }) {
    _registerParameters(signature.typeParameters, enclosing: enclosing);
    final parameters = [...enclosing, ...signature.typeParameters];
    for (final parameter in [...signature.positional, ...signature.named]) {
      _registerType(parameter.type, parameters);
    }
    _registerType(signature.result, parameters);
  }

  void _registerType(ExportType type, List<ExportTypeParameter> enclosing) {
    final signature = type.signature;
    if (signature != null) {
      _registerSignature(signature, enclosing: enclosing);
    }
    if (type.element != null) _registerType(type.element!, enclosing);
    for (final argument in type.typeArguments) {
      _registerType(argument, enclosing);
    }
    final fields = type.recordFields;
    if (fields != null) {
      for (final field in [...fields.positional, ...fields.named.values]) {
        _registerType(field, enclosing);
      }
    }
  }

  String _generics(
    List<ExportTypeParameter> parameters, {
    bool defaults = true,
    bool metadata = true,
  }) {
    if (parameters.isEmpty) return '';
    if (!defaults) {
      return '<${parameters.map((p) => _parameterDeclaration(p, null, metadata)).join(', ')}>';
    }
    final pending = {for (final parameter in parameters) parameter.target};
    final defaultTypes = <ExportType>[];
    var firstDefault = 0;
    for (var i = 0; i < parameters.length; ++i) {
      final parameter = parameters[i];
      final bound = parameter.bound;
      final defaultType =
          bound.kind == ValueKind.typeParameter ||
              parameter.defaultType.kind == ValueKind.dynamicValue &&
                  !(bound.kind == ValueKind.opaque && bound.nullable) &&
                  bound.kind != ValueKind.dynamicValue
          ? bound
          : parameter.defaultType;
      defaultTypes.add(defaultType);
      if (defaultType.kind == ValueKind.typeParameter &&
          pending.contains(defaultType.parameter!.target)) {
        // Defaults must form a suffix and can only refer to earlier parameters.
        firstDefault = i + 1;
      }
      pending.remove(parameter.target);
    }
    final declarations = [
      for (var i = 0; i < parameters.length; ++i)
        _parameterDeclaration(
          parameters[i],
          i >= firstDefault ? defaultTypes[i] : null,
          metadata,
        ),
    ];
    return '<${declarations.join(', ')}>';
  }

  String _parameterDeclaration(
    ExportTypeParameter parameter, [
    ExportType? defaultType,
    bool metadata = true,
  ]) {
    final name = _parameterNames[parameter]!;
    final bound = parameter.bound;
    final constraint =
        bound.kind == ValueKind.dynamicValue ||
            bound.kind == ValueKind.opaque && bound.nullable
        ? ''
        : ' extends ${_type(bound, metadata: metadata)}';
    if (defaultType == null) return '$name$constraint';
    final value = defaultType.kind == ValueKind.dynamicValue
        ? 'unknown'
        : _type(defaultType, metadata: metadata);
    return '$name$constraint = $value';
  }

  String _parameterArguments(List<ExportTypeParameter> parameters) =>
      parameters.isEmpty
      ? ''
      : '<${parameters.map((parameter) => _parameterNames[parameter]!).join(', ')}>';

  String _input(ExportClass cls) {
    if (cls.constructor == null) {
      throw FormatException(
        '@NAPI.object ${cls.name}: has no annotated input constructor.',
      );
    }
    return _objects[cls]!.input;
  }

  String _objectParameters(ExportClass cls, {bool metadata = true}) =>
      cls.typeParameters.isEmpty
      ? ''
      : '<${[
          for (var i = 0; i < cls.typeParameters.length; ++i) ...[_parameterDeclaration(cls.typeParameters[i], null, metadata), _objects[cls]!.inputs[i]],
        ].join(', ')}>';

  String _objectArguments(ExportClass cls) => cls.typeParameters.isEmpty
      ? ''
      : '<${[
          for (final parameter in cls.typeParameters) ...[_parameterTypes[parameter]!.output, _parameterTypes[parameter]!.input],
        ].join(', ')}>';

  T _withObjectParameters<T>(ExportClass cls, T Function() body) {
    final saved = Map<ExportTypeParameter, ({String output, String input})>.of(
      _parameterTypes,
    );
    for (var i = 0; i < cls.typeParameters.length; ++i) {
      final parameter = cls.typeParameters[i];
      _parameterTypes[parameter] = (
        output: _parameterNames[parameter]!,
        input: _objects[cls]!.inputs[i],
      );
      _parameterTypes[_inputParameters[cls]![i]] = _parameterTypes[parameter]!;
    }
    try {
      return body();
    } finally {
      _parameterTypes
        ..clear()
        ..addAll(saved);
    }
  }

  T _withClassParameters<T>(ExportClass cls, T Function() body) {
    final savedTypes = {..._parameterTypes};
    final savedModes = {..._parameterModes};
    final names = _classes[cls]!;
    for (var i = 0; i < cls.typeParameters.length; ++i) {
      final parameter = cls.typeParameters[i];
      _parameterTypes[parameter] = (
        output: _parameterNames[parameter]!,
        input: names.inputs[i],
      );
      _parameterModes[parameter] = names.modes[i];
    }
    try {
      return body();
    } finally {
      _parameterTypes
        ..clear()
        ..addAll(savedTypes);
      _parameterModes
        ..clear()
        ..addAll(savedModes);
    }
  }

  String _classParametersDeclaration(ExportClass cls) =>
      cls.typeParameters.isEmpty
      ? ''
      : '<${[
          for (var i = 0; i < cls.typeParameters.length; ++i) ...[_parameterDeclaration(cls.typeParameters[i]), _classes[cls]!.inputs[i], _classes[cls]!.modes[i]],
        ].join(', ')}>';

  String _classShape(ExportType type, {bool metadata = true}) =>
      !_classes.containsKey(type.classExport)
      ? type.classExport!.name
      : '${_classes[type.classExport]!.shape}${type.typeArguments.isEmpty ? '' : '<${[
                for (final argument in type.typeArguments) ...[_classArgumentOutput(argument, metadata: metadata), _type(argument, output: false, metadata: metadata), _opaqueParameters.contains(argument.parameter) ? '$_mode<${_classArgumentOutput(argument, metadata: metadata)}>' : _typeMode(argument)],
              ].join(', ')}>'}';

  String _opaqueArgument(
    ExportTypeParameter parameter, [
    Set<ExportTypeParameter>? seen,
  ]) {
    final name = _parameterNames[parameter]!;
    final visited = seen ?? <ExportTypeParameter>{};
    if (!visited.add(parameter)) return '$_opaque<$name>';
    var bound = parameter.bound;
    final bounds = <ExportTypeParameter>{};
    while (bound.kind == ValueKind.typeParameter &&
        bounds.add(bound.parameter!)) {
      bound = bound.parameter!.bound;
    }
    if (_scalarKey(bound) != null &&
            bound.kind != ValueKind.opaque &&
            bound.kind != ValueKind.dynamicValue ||
        bound.kind == ValueKind.object && !bound.classExport!.isObject ||
        bound.kind == ValueKind.enumeration ||
        bound.kind == ValueKind.jsReference &&
            bound.referenceKind == JsReferenceKind.symbol) {
      return name;
    }
    final parent = parameter.bound.parameter;
    return parent == null
        ? '$_opaque<$name>'
        : '$_opaque<$name> & (${_opaqueArgument(parent, visited)}${parameter.bound.nullable ? ' | null' : ''})';
  }

  String _constructorResult(ExportClass cls) =>
      '${cls.name}${cls.typeParameters.isEmpty ? '' : '<${cls.typeParameters.map(_opaqueArgument).join(', ')}>'}';

  String _classArgumentOutput(ExportType type, {bool metadata = true}) =>
      _opaqueParameters.contains(type.parameter)
      ? '${_opaqueArgument(type.parameter!)}${type.nullable ? ' | null' : ''}'
      : _type(type, metadata: metadata);

  String _functionResult(ExportFunction function) {
    if (function.constructor) return _constructorResult(function.owner!);
    final signature = function.signature;
    final anchors = <ExportTypeParameter>{
      for (final parameter in [...signature.positional, ...signature.named])
        if (parameter.type.kind == ValueKind.object &&
            !parameter.type.classExport!.isObject)
          for (final argument in parameter.type.typeArguments)
            if (argument.parameter != null) argument.parameter!,
    };
    final saved = {..._opaqueParameters};
    _opaqueParameters.addAll(
      signature.typeParameters.where(
        (parameter) => !anchors.contains(parameter),
      ),
    );
    try {
      return _type(signature.result);
    } finally {
      _opaqueParameters
        ..clear()
        ..addAll(saved);
    }
  }

  String _typeMode(ExportType type) {
    final parameter = _parameterModes[type.parameter];
    if (parameter != null)
      return type.nullable ? '$parameter | "stable"' : parameter;
    if (!_mentions(type, _parameterModes.keys.toSet())) {
      return '$_mode<${_type(type)}>';
    }
    final value = switch (type.kind) {
      ValueKind.list => '{ readonly array: ${_typeMode(type.element!)} }',
      ValueKind.set => '{ readonly set: ${_typeMode(type.element!)} }',
      ValueKind.stream => '{ readonly async: ${_typeMode(type.element!)} }',
      ValueKind.map =>
        '{ readonly [key: string]: ${_typeMode(type.element!)} }',
      ValueKind.record =>
        type.recordFields!.named.isEmpty
            ? '{ readonly array: ${type.recordFields!.positional.map(_typeMode).join(' | ')} }'
            : '{ ${_recordProperties(type).entries.map((entry) => 'readonly ${jsonEncode(entry.key)}: ${_typeMode(entry.value)};').join(' ')} }',
      _ => '$_mode<${_type(type)}>',
    };
    return type.nullable ? '$value | "stable"' : value;
  }

  _Difference _requireDifference(
    ExportClass left,
    ExportClass right, {
    bool inputOnly = false,
  }) {
    final key = (left: left, right: right, inputOnly: inputOnly);
    return _differences.putIfAbsent(key, () {
      _pendingDifferences.add(key);
      return _Difference();
    });
  }

  ExportType _declaredObject(ExportClass cls) => ExportType(
    cls.dartType,
    ValueKind.object,
    classExport: cls,
    typeArguments: [
      for (final parameter in cls.typeParameters)
        ExportType(
          parameter.invocationType,
          ValueKind.typeParameter,
          parameter: parameter,
          representation: parameter.defaultType,
        ),
    ],
  );

  Map<ExportTypeParameter, ExportType> _edgeArguments(_TypePair edge) => {
    for (var i = 0; i < edge.left.classExport!.typeParameters.length; ++i)
      edge.left.classExport!.typeParameters[i]: edge.left.typeArguments[i],
    for (var i = 0; i < edge.right.classExport!.typeParameters.length; ++i)
      _inputParameters[edge.right.classExport!]![i]:
          edge.right.typeArguments[i],
  };

  void _buildDifferences() {
    while (_pendingDifferences.isNotEmpty) {
      final key = _pendingDifferences.removeLast();
      final difference = _differences[key]!;
      final output = key.left, input = key.right;
      final constructor = input.constructor;
      if (key.inputOnly) {
        if (constructor != null) {
          for (final parameter in [
            ...constructor.signature.positional,
            ...constructor.signature.named,
          ]) {
            _collectShapeIdentity(parameter.type, false, difference);
          }
        }
        for (final pair in difference.pairs.entries) {
          difference.paths[pair.key] = [(node: key, pair: pair.value)];
        }
        continue;
      }
      if (constructor == null) {
        difference.always = true;
        continue;
      }
      final inputs = {
        for (final p in [
          ...constructor.signature.positional,
          ...constructor.signature.named,
        ])
          p.name: p,
      };
      if (output != input &&
          inputs.isEmpty &&
          output.properties.every(
            (property) => _objectMemberNames.contains(property.name),
          )) {
        final own = _declaredObject(output);
        _collectDifference(own, own, difference);
        _collectDifference(
          own,
          ExportType(
            input.dartType,
            ValueKind.jsReference,
            referenceKind: JsReferenceKind.object,
          ),
          difference,
        );
        for (final pair in difference.pairs.entries) {
          difference.paths[pair.key] = [(node: key, pair: pair.value)];
        }
        continue;
      }
      if (inputs.length != output.properties.length ||
          output.properties.any((p) => !inputs.containsKey(p.name)) ||
          inputs.values.any((p) => !p.required)) {
        difference.always = true;
        continue;
      }
      final own = _declaredObject(output);
      _collectDifference(own, own, difference);
      final arguments = {
        for (var i = 0; i < input.typeParameters.length; ++i)
          input.typeParameters[i]: ExportType(
            _inputParameters[input]![i].invocationType,
            ValueKind.typeParameter,
            parameter: _inputParameters[input]![i],
          ),
      };
      for (final property in output.properties) {
        _collectDifference(
          property.readType!,
          _substituteType(inputs[property.name]!.type, arguments),
          difference,
        );
      }
      for (final pair in difference.pairs.entries) {
        difference.paths[pair.key] = [(node: key, pair: pair.value)];
      }
    }
  }

  void _analyzeDifferences() {
    for (final cls in _objects.keys) {
      _requireDifference(cls, cls);
    }
    _solveDifferences();
  }

  void _solveDifferences() {
    if (_pendingDifferences.isEmpty) return;
    var changed = true;
    while (changed || _pendingDifferences.isNotEmpty) {
      _buildDifferences();
      changed = false;
      for (final entry in _differences.entries.toList()) {
        final difference = entry.value;
        if (difference.always) continue;
        for (final edge in difference.edges.values.toList()) {
          final source =
              _differences[(
                left: edge.left.classExport!,
                right: edge.right.classExport!,
                inputOnly: edge.inputOnly,
              )]!;
          if (source.always) {
            difference.always = true;
            changed = true;
            break;
          }
          final arguments = _edgeArguments(edge);
          for (final pair in source.pairs.entries.toList()) {
            final next = _substituteDifference(
              pair.value,
              arguments,
              arguments,
              locals: edge.locals,
            );
            if (next.always) {
              difference.always = true;
              changed = true;
              break;
            }
            for (final value in next.pairs.entries) {
              if (difference.pairs.containsKey(value.key)) continue;
              final path = source.paths[pair.key]!;
              final parameters = _pairParameters(value.value);
              if (parameters.isNotEmpty &&
                  path.any(
                    (step) =>
                        step.node == entry.key &&
                        _pairParameters(step.pair) == parameters &&
                        _pairDepth(step.pair) < _pairDepth(value.value),
                  )) {
                throw FormatException(
                  '@NAPI.object ${entry.key.left.name}: recursive input/output projections expand at different rates.',
                );
              }
              difference.pairs[value.key] = value.value;
              difference.paths[value.key] = [
                ...path,
                (node: entry.key, pair: value.value),
              ];
              changed = true;
            }
            for (final value in next.edges.entries) {
              if (!difference.edges.containsKey(value.key)) {
                difference.edges[value.key] = value.value;
                changed = true;
              }
            }
          }
          if (difference.always) break;
        }
      }
    }
  }

  void _collectDifference(
    ExportType left,
    ExportType right,
    _Difference result, {
    List<ExportTypeParameter> locals = const [],
  }) {
    if (result.always) return;
    void pair() {
      _collectShapeIdentity(left, true, result, locals: locals);
      _collectShapeIdentity(right, false, result, locals: locals);
      final value = _TypePair(left, right, locals: locals);
      result.pairs[_pairKey(value)] = value;
    }

    if (_fixedTopDifference(left, right)) {
      result.always = true;
      return;
    }
    if (left.nullable != right.nullable) {
      final a = _includesNull(left), b = _includesNull(right);
      if (a == null || b == null) {
        pair();
        return;
      }
      if (a != b) {
        result.always = true;
        return;
      }
    }
    if (left.kind == ValueKind.typeParameter ||
        right.kind == ValueKind.typeParameter) {
      if (left.parameter == right.parameter &&
          left.parameter != null &&
          !_classParameters.contains(left.parameter)) {
        return;
      }
      pair();
      return;
    }
    final a = _scalarKey(left), b = _scalarKey(right);
    if (a != null && b != null) {
      if (a != b) pair();
      return;
    }
    if (left.kind != right.kind) {
      if (_knownRepresentationDifference(left, right)) {
        result.always = true;
      } else if (_isMapObject(left, right)) {
        _collectMapObject(left, right, result, locals);
      } else if (_isMixedRecordObject(left, right)) {
        _collectMixedRecordObject(left, right, result, locals);
      } else {
        pair();
      }
      return;
    }
    if (left.kind == ValueKind.object) {
      if (left.classExport!.isObject != right.classExport!.isObject) {
        result.always = true;
      } else if (left.classExport!.isObject) {
        _requireDifference(left.classExport!, right.classExport!);
        final value = _TypePair(left, right, locals: locals);
        result.edges[_pairKey(value)] = value;
      } else if (_typeKey(left) != _typeKey(right)) {
        pair();
      }
      return;
    }
    if (left.kind == ValueKind.future) {
      _collectAwaitedDifference(left.element!, right.element!, result, locals);
      return;
    }
    if (left.kind == ValueKind.stream) {
      result.always = true;
      return;
    }
    if (left.element != null && right.element != null) {
      _collectDifference(left.element!, right.element!, result, locals: locals);
      return;
    }
    if (left.kind == ValueKind.function) {
      final x = left.signature!, y = right.signature!;
      if (x.positional.length != y.positional.length ||
          x.named.length != y.named.length ||
          x.typeParameters.length != y.typeParameters.length) {
        result.always = true;
        return;
      }
      final parameters = {
        for (var i = 0; i < x.typeParameters.length; ++i)
          y.typeParameters[i]: ExportType(
            x.typeParameters[i].invocationType,
            ValueKind.typeParameter,
            parameter: x.typeParameters[i],
            representation: x.typeParameters[i].defaultType,
          ),
      };
      final scope = [...locals, ...x.typeParameters];
      for (var i = 0; i < x.typeParameters.length; ++i) {
        _collectDifference(
          x.typeParameters[i].bound,
          _substituteType(y.typeParameters[i].bound, parameters),
          result,
          locals: scope,
        );
      }
      final xs = [...x.positional, ...x.named],
          ys = [...y.positional, ...y.named];
      for (var i = 0; i < xs.length; ++i) {
        if (xs[i].required != ys[i].required ||
            i >= x.positional.length && xs[i].name != ys[i].name) {
          result.always = true;
          return;
        }
        _collectDifference(
          _substituteType(ys[i].type, parameters),
          xs[i].type,
          result,
          locals: scope,
        );
      }
      _collectDifference(
        x.result,
        _substituteType(y.result, parameters),
        result,
        locals: scope,
      );
      return;
    }
    if (left.kind == ValueKind.record) {
      final x = left.recordFields!, y = right.recordFields!;
      if (x.positional.length != y.positional.length ||
          x.named.keys.join(',') != y.named.keys.join(',')) {
        result.always = true;
        return;
      }
      for (var i = 0; i < x.positional.length; ++i) {
        _collectDifference(
          x.positional[i],
          y.positional[i],
          result,
          locals: locals,
        );
      }
      for (final name in x.named.keys) {
        _collectDifference(
          x.named[name]!,
          y.named[name]!,
          result,
          locals: locals,
        );
      }
      return;
    }
    if (_typeKey(left) != _typeKey(right)) pair();
  }

  void _collectShapeIdentity(
    ExportType type,
    bool output,
    _Difference result, {
    List<ExportTypeParameter> locals = const [],
  }) {
    if (output &&
        type.kind == ValueKind.typeParameter &&
        _classParameters.contains(type.parameter)) {
      final pair = _TypePair(type, type, locals: locals);
      result.pairs[_pairKey(pair)] = pair;
      return;
    }
    if (type.kind == ValueKind.object) {
      final cls = type.classExport!;
      if (cls.isObject) {
        _requireDifference(cls, cls, inputOnly: !output);
        final edge = _TypePair(type, type, locals: locals, inputOnly: !output);
        result.edges[_pairKey(edge)] = edge;
      } else {
        for (final argument in type.typeArguments) {
          _collectShapeIdentity(argument, true, result, locals: locals);
        }
      }
      return;
    }
    if (output &&
        (type.kind == ValueKind.function || type.kind == ValueKind.future)) {
      _collectDifference(type, type, result, locals: locals);
      return;
    }
    if (type.signature case final signature?) {
      final scope = [...locals, ...signature.typeParameters];
      for (final parameter in signature.typeParameters) {
        _collectShapeIdentity(parameter.bound, true, result, locals: scope);
      }
      for (final parameter in [...signature.positional, ...signature.named]) {
        _collectShapeIdentity(parameter.type, !output, result, locals: scope);
      }
      _collectShapeIdentity(signature.result, output, result, locals: scope);
      return;
    }
    for (final child in _typeChildren(type)) {
      _collectShapeIdentity(child, output, result, locals: locals);
    }
  }

  String? _scalarKey(ExportType type) => switch (type.kind) {
    ValueKind.integer || ValueKind.doubleValue || ValueKind.number => 'number',
    ValueKind.boolean ||
    ValueKind.string ||
    ValueKind.bigint ||
    ValueKind.nullValue ||
    ValueKind.undefined ||
    ValueKind.voidValue ||
    ValueKind.never ||
    ValueKind.opaque ||
    ValueKind.dynamicValue => '${type.kind}:${type.nullable}',
    _ => null,
  };

  bool? _includesNull(ExportType type) => switch (type.kind) {
    ValueKind.typeParameter ||
    ValueKind.dynamicValue ||
    ValueKind.opaque => null,
    _ => type.nullable || type.kind == ValueKind.nullValue,
  };

  bool _requiredObjectKey(String name, ExportType type) =>
      !_objectMemberNames.contains(name) || !_mayCall(type);

  void _collectAwaitedDifference(
    ExportType left,
    ExportType right,
    _Difference result,
    List<ExportTypeParameter> locals,
  ) {
    for (final branch in _awaitedTypes(left)) {
      if (branch.resolve) {
        if (_knownRepresentationDifference(branch.type, right)) {
          result.always = true;
        } else {
          _collectShapeIdentity(branch.type, true, result, locals: locals);
          _collectShapeIdentity(right, false, result, locals: locals);
          final value = _TypePair(
            branch.type,
            right,
            locals: locals,
            awaitLeft: true,
          );
          result.pairs[_pairKey(value)] = value;
        }
      } else {
        _collectDifference(branch.type, right, result, locals: locals);
      }
    }
  }

  bool _isMixedRecordObject(ExportType left, ExportType right) =>
      left.kind == ValueKind.object &&
          left.classExport!.isObject &&
          right.kind == ValueKind.record &&
          right.recordFields!.named.isNotEmpty ||
      right.kind == ValueKind.object &&
          right.classExport!.isObject &&
          left.kind == ValueKind.record &&
          left.recordFields!.named.isNotEmpty;

  Map<String, ExportType> _recordProperties(ExportType type) => {
    for (var i = 0; i < type.recordFields!.positional.length; ++i)
      '\$${i + 1}': type.recordFields!.positional[i],
    ...type.recordFields!.named,
  };

  bool _sameMixedSchema(_TypePair left, _TypePair right) {
    bool same(ExportType a, ExportType b) =>
        a.kind == b.kind &&
        (a.kind == ValueKind.object
            ? a.classExport == b.classExport
            : a.dartType == b.dartType);
    return same(left.left, right.left) && same(left.right, right.right);
  }

  bool _enterSchemaPair(_TypePair pair) {
    final key = _pairKey(pair);
    if (_mixedPairs.any((old) => _pairKey(old) == key)) return false;
    if (_mixedPairs.any(
      (old) =>
          _sameMixedSchema(old, pair) &&
          _pairDepth(old) < _pairDepth(pair) &&
          _embedsType(old.left, pair.left) &&
          _embedsType(old.right, pair.right),
    )) {
      throw FormatException(
        '@NAPI.object: recursive input/output projections expand at different rates.',
      );
    }
    _mixedPairs.add(pair);
    return true;
  }

  bool _isMapObject(ExportType left, ExportType right) =>
      left.kind == ValueKind.map &&
          right.kind == ValueKind.object &&
          right.classExport!.isObject ||
      right.kind == ValueKind.map &&
          left.kind == ValueKind.object &&
          left.classExport!.isObject;

  void _collectMapObject(
    ExportType left,
    ExportType right,
    _Difference result,
    List<ExportTypeParameter> locals,
  ) {
    if (left.kind == ValueKind.object) {
      _collectDifference(left, left, result, locals: locals);
    }
    if (!_enterSchemaPair(_TypePair(left, right, locals: locals))) return;
    try {
      if (left.kind == ValueKind.map) {
        final cls = right.classExport!;
        final constructor = cls.constructor;
        if (constructor == null) {
          result.always = true;
          return;
        }
        final parameters = [
          ...constructor.signature.positional,
          ...constructor.signature.named,
        ];
        if (parameters.isEmpty) {
          final element = left.element!;
          _collectDifference(
            element,
            ExportType(element.dartType, ValueKind.dynamicValue),
            result,
            locals: locals,
          );
        }
        final arguments = {
          for (var i = 0; i < right.typeArguments.length; ++i)
            cls.typeParameters[i]: right.typeArguments[i],
        };
        for (final parameter in parameters) {
          _collectDifference(
            left.element!,
            _substituteType(parameter.type, arguments),
            result,
            locals: locals,
          );
        }
      } else {
        final cls = left.classExport!;
        if (cls.properties.isEmpty) {
          _collectDifference(
            ExportType(left.dartType, ValueKind.dynamicValue),
            right.element!,
            result,
            locals: locals,
          );
        }
        final arguments = {
          for (var i = 0; i < left.typeArguments.length; ++i)
            cls.typeParameters[i]: left.typeArguments[i],
        };
        for (final property in cls.properties) {
          _collectDifference(
            _substituteType(property.readType!, arguments),
            right.element!,
            result,
            locals: locals,
          );
        }
      }
    } finally {
      _mixedPairs.removeLast();
    }
  }

  void _collectMixedRecordObject(
    ExportType left,
    ExportType right,
    _Difference result,
    List<ExportTypeParameter> locals,
  ) {
    if (left.kind == ValueKind.object) {
      _collectDifference(left, left, result, locals: locals);
    }
    final pair = _TypePair(left, right, locals: locals);
    if (!_enterSchemaPair(pair)) return;
    try {
      final output = left.kind == ValueKind.record
          ? _recordProperties(left)
          : {
              for (final property in left.classExport!.properties)
                property.name: _substituteType(property.readType!, {
                  for (var i = 0; i < left.typeArguments.length; ++i)
                    left.classExport!.typeParameters[i]: left.typeArguments[i],
                }),
            };
      final input = <String, ExportType>{};
      var optional = false;
      if (right.kind == ValueKind.record) {
        input.addAll(_recordProperties(right));
      } else {
        final cls = right.classExport!;
        final constructor = cls.constructor;
        if (constructor == null) {
          result.always = true;
          return;
        }
        final arguments = {
          for (var i = 0; i < right.typeArguments.length; ++i)
            cls.typeParameters[i]: right.typeArguments[i],
        };
        for (final parameter in [
          ...constructor.signature.positional,
          ...constructor.signature.named,
        ]) {
          input[parameter.name] = _substituteType(parameter.type, arguments);
          optional |= !parameter.required;
        }
      }
      if (input.isEmpty && output.keys.every(_objectMemberNames.contains)) {
        _collectDifference(
          left,
          ExportType(
            right.dartType,
            ValueKind.jsReference,
            referenceKind: JsReferenceKind.object,
            nullable: right.nullable,
          ),
          result,
          locals: locals,
        );
        return;
      }
      if (output.isEmpty && input.keys.every(_objectMemberNames.contains)) {
        _collectDifference(
          ExportType(
            left.dartType,
            ValueKind.jsReference,
            referenceKind: JsReferenceKind.object,
            nullable: left.nullable,
          ),
          right,
          result,
          locals: locals,
        );
        return;
      }
      if (output.length != input.length ||
          output.keys.any((name) => !input.containsKey(name)) ||
          optional) {
        result.always = true;
        return;
      }
      for (final entry in output.entries) {
        _collectDifference(
          entry.value,
          input[entry.key]!,
          result,
          locals: locals,
        );
      }
    } finally {
      _mixedPairs.removeLast();
    }
  }

  bool _fixedTopDifference(ExportType left, ExportType right) {
    final leftTop =
        left.kind == ValueKind.opaque || left.kind == ValueKind.dynamicValue;
    final rightTop =
        right.kind == ValueKind.opaque || right.kind == ValueKind.dynamicValue;
    return leftTop != rightTop &&
        left.kind != ValueKind.typeParameter &&
        right.kind != ValueKind.typeParameter;
  }

  bool _knownRepresentationDifference(ExportType left, ExportType right) {
    if (left.kind == ValueKind.typeParameter ||
        right.kind == ValueKind.typeParameter) {
      return false;
    }
    if (_fixedTopDifference(left, right)) return true;
    if (left.nullable != right.nullable) {
      final a = _includesNull(left), b = _includesNull(right);
      if (a != null && b != null && a != b) return true;
    }
    final leftArray = _isJsArray(left), rightArray = _isJsArray(right);
    final leftPrimitive = _isJsPrimitive(left),
        rightPrimitive = _isJsPrimitive(right);
    final leftCallable = _isJsCallable(left),
        rightCallable = _isJsCallable(right);
    return leftArray != null && rightArray != null && leftArray != rightArray ||
        leftCallable != null &&
            rightCallable != null &&
            leftCallable != rightCallable ||
        leftPrimitive != null &&
            rightPrimitive != null &&
            leftPrimitive != rightPrimitive ||
        left.kind != right.kind && leftArray == true && rightArray == true ||
        _plainObjectBuiltinDifference(left, right) ||
        left.kind == ValueKind.function &&
            right.kind == ValueKind.jsReference &&
            right.referenceKind == JsReferenceKind.function ||
        right.kind == ValueKind.function &&
            left.kind == ValueKind.jsReference &&
            left.referenceKind == JsReferenceKind.function ||
        _mapObjectDifference(left, right) ||
        _rawObjectDifference(left, right);
  }

  bool _plainObjectBuiltinDifference(ExportType left, ExportType right) {
    bool plain(ExportType type) => switch (type.kind) {
      ValueKind.object => type.classExport!.isObject,
      ValueKind.map => true,
      ValueKind.record => type.recordFields!.named.isNotEmpty,
      _ => false,
    };
    return plain(left) && _isBuiltinObject(right) ||
        _isBuiltinObject(left) && plain(right);
  }

  // These interfaces require nominal brands or symbol-keyed members.
  bool _isBuiltinObject(ExportType type) => switch (type.kind) {
    ValueKind.object => !type.classExport!.isObject,
    ValueKind.dateTime ||
    ValueKind.set ||
    ValueKind.byteBuffer ||
    ValueKind.byteData ||
    ValueKind.typedData ||
    ValueKind.simd ||
    ValueKind.simdList ||
    ValueKind.future ||
    ValueKind.stream => true,
    _ => false,
  };

  bool _mapObjectDifference(ExportType left, ExportType right) {
    if (right.kind == ValueKind.map) {
      return _hasRequiredObjectFields(left, output: true);
    }
    if (left.kind == ValueKind.map) {
      return _hasRequiredObjectFields(right, output: false);
    }
    return false;
  }

  bool _rawObjectDifference(ExportType left, ExportType right) {
    final rawLeft =
        left.kind == ValueKind.jsReference &&
        left.referenceKind == JsReferenceKind.object;
    final rawRight =
        right.kind == ValueKind.jsReference &&
        right.referenceKind == JsReferenceKind.object;
    if (!rawLeft && !rawRight) return false;
    final type = rawLeft ? right : left;
    if (_isJsArray(type) == true ||
        _isBuiltinObject(type) ||
        type.kind == ValueKind.function ||
        type.kind == ValueKind.jsReference &&
            type.referenceKind == JsReferenceKind.function) {
      return true;
    }
    return _hasRequiredObjectFields(type, output: rawRight);
  }

  bool _hasRequiredObjectFields(ExportType type, {required bool output}) {
    if (type.kind == ValueKind.record && type.recordFields!.named.isNotEmpty) {
      return _recordProperties(
        type,
      ).entries.any((field) => _requiredObjectKey(field.key, field.value));
    }
    if (type.kind != ValueKind.object || !type.classExport!.isObject) {
      return false;
    }
    final cls = type.classExport!;
    if (output) {
      return cls.properties.any(
        (property) => _requiredObjectKey(property.name, property.readType!),
      );
    }
    final constructor = cls.constructor;
    return constructor != null &&
        [
          ...constructor.signature.positional,
          ...constructor.signature.named,
        ].any(
          (parameter) =>
              parameter.required &&
              _requiredObjectKey(parameter.name, parameter.type),
        );
  }

  bool? _isJsArray(ExportType type) => switch (type.kind) {
    ValueKind.list => true,
    ValueKind.record => type.recordFields!.named.isEmpty,
    ValueKind.typeParameter ||
    ValueKind.dynamicValue ||
    ValueKind.opaque => null,
    ValueKind.jsReference when type.referenceKind == JsReferenceKind.object =>
      null,
    _ => false,
  };

  bool? _isJsCallable(ExportType type) => switch (type.kind) {
    ValueKind.function => true,
    ValueKind.jsReference when type.referenceKind == JsReferenceKind.function =>
      true,
    ValueKind.typeParameter ||
    ValueKind.dynamicValue ||
    ValueKind.opaque => null,
    ValueKind.jsReference when type.referenceKind == JsReferenceKind.object =>
      null,
    _ => false,
  };

  bool? _isJsPrimitive(ExportType type) => switch (type.kind) {
    ValueKind.boolean ||
    ValueKind.integer ||
    ValueKind.doubleValue ||
    ValueKind.number ||
    ValueKind.string ||
    ValueKind.bigint ||
    ValueKind.nullValue ||
    ValueKind.undefined ||
    ValueKind.enumeration => true,
    ValueKind.jsReference when type.referenceKind == JsReferenceKind.symbol =>
      true,
    ValueKind.typeParameter ||
    ValueKind.dynamicValue ||
    ValueKind.opaque ||
    ValueKind.voidValue ||
    ValueKind.never => null,
    ValueKind.jsReference when type.referenceKind == JsReferenceKind.object =>
      null,
    _ => false,
  };

  int _parameterId(ExportTypeParameter parameter) =>
      _parameterIds.putIfAbsent(parameter, () => _parameterIds.length);

  String _typeKey(
    ExportType type, [
    Map<ExportTypeParameter, int> locals = const {},
  ]) {
    final signature = type.signature;
    final scope = {
      ...locals,
      if (signature != null)
        for (var i = 0; i < signature.typeParameters.length; ++i)
          signature.typeParameters[i]: locals.length + i,
    };
    String key(ExportType child) => _typeKey(child, scope);
    final parameter = type.parameter;
    return '${type.kind}:${type.nullable}:${parameter == null
            ? ''
            : locals.containsKey(parameter)
            ? 'local${locals[parameter]}'
            : _parameterId(parameter)}:${type.classExport?.name}:${type.typedDataKind}:${type.simdKind}:${type.referenceKind}:${type.enumExport?.name}'
        '${type.element == null ? '' : '[${key(type.element!)}]'}'
        '<${type.typeArguments.map(key).join(',')}>'
        '${signature == null ? '' : '(${signature.typeParameters.map((p) => key(p.bound)).join(',')};${signature.positional.map((p) => '${p.required}:${key(p.type)}').join(',')};${signature.named.map((p) => '${p.name}:${p.required}:${key(p.type)}').join(',')};${key(signature.result)})'}'
        '${type.recordFields == null ? '' : '(${type.recordFields!.positional.map(key).join(',')};${type.recordFields!.named.entries.map((p) => '${p.key}:${key(p.value)}').join(',')})'}';
  }

  String _pairParameters(_TypePair pair) {
    String parameters(ExportType value) {
      final values = <int>{};
      void visit(ExportType type, Set<ExportTypeParameter> locals) {
        if (type.parameter != null && !locals.contains(type.parameter)) {
          values.add(_parameterId(type.parameter!));
        }
        final nested = {...locals, ...?type.signature?.typeParameters};
        for (final child in _typeChildren(type)) {
          visit(child, nested);
        }
      }

      visit(value, pair.locals.toSet());
      return (values.toList()..sort()).join(',');
    }

    final left = parameters(pair.left), right = parameters(pair.right);
    return left.isEmpty && right.isEmpty ? '' : '$left|$right';
  }

  String _pairKey(_TypePair pair) {
    final parameters = _usedLocals(pair.left, pair.right, pair.locals);
    final locals = {
      for (var i = 0; i < parameters.length; ++i) parameters[i]: i,
    };
    return '${pair.awaitLeft}:${pair.inputOnly}:${parameters.map((p) => _typeKey(p.bound, locals)).join(',')};'
        '${_typeKey(pair.left, locals)}|${_typeKey(pair.right, locals)}';
  }

  List<ExportTypeParameter> _usedLocals(
    ExportType left,
    ExportType right,
    Iterable<ExportTypeParameter> parameters,
  ) {
    final candidates = parameters.toSet();
    final used = <ExportTypeParameter>{};
    void visit(ExportType type) {
      final parameter = type.parameter;
      if (candidates.contains(parameter) && used.add(parameter!)) {
        visit(parameter.bound);
        visit(parameter.defaultType);
      }
      for (final child in _typeChildren(type)) {
        visit(child);
      }
    }

    visit(left);
    visit(right);
    return used.toList();
  }

  int _typeDepth(ExportType type) {
    final children = _typeChildren(type).toList();
    return 1 +
        (children.isEmpty
            ? 0
            : children.map(_typeDepth).reduce((a, b) => a > b ? a : b));
  }

  int _pairDepth(_TypePair pair) =>
      _typeDepth(pair.left) + _typeDepth(pair.right);

  Iterable<ExportType> _typeChildren(ExportType type) sync* {
    if (type.element != null) yield type.element!;
    yield* type.typeArguments;
    final signature = type.signature;
    if (signature != null) {
      yield* signature.typeParameters.map((p) => p.bound);
      yield* signature.positional.map((p) => p.type);
      yield* signature.named.map((p) => p.type);
      yield signature.result;
    }
    final fields = type.recordFields;
    if (fields != null) {
      yield* fields.positional;
      yield* fields.named.values;
    }
  }

  bool _awaitPreserves(ExportType type, [Set<ExportTypeParameter>? seen]) {
    switch (type.kind) {
      case ValueKind.typeParameter:
        final parameter = type.parameter!;
        final visited = seen ?? <ExportTypeParameter>{};
        return visited.add(parameter) &&
            (parameter.bound.kind == ValueKind.typeParameter
                ? _awaitPreserves(parameter.bound, visited)
                : _scalarKey(parameter.bound) != null &&
                      parameter.bound.kind != ValueKind.opaque &&
                      parameter.bound.kind != ValueKind.dynamicValue);
      case ValueKind.object:
      case ValueKind.record:
        final then = _thenType(type);
        return then == null || !_mayCall(then);
      case ValueKind.map:
        return !_mayCall(type.element!);
      case ValueKind.jsReference:
        return type.referenceKind == JsReferenceKind.symbol;
      case ValueKind.opaque:
      case ValueKind.dynamicValue:
      case ValueKind.future:
        return false;
      default:
        return true;
    }
  }

  bool _mayCall(ExportType type) => switch (type.kind) {
    ValueKind.function || ValueKind.opaque || ValueKind.dynamicValue => true,
    ValueKind.typeParameter => !_awaitPreserves(type),
    ValueKind.jsReference => type.referenceKind != JsReferenceKind.symbol,
    _ => false,
  };

  ExportType? _thenType(ExportType type) {
    if (type.kind == ValueKind.record) return type.recordFields!.named['then'];
    final cls = type.classExport!;
    ExportType? then;
    for (final property in cls.properties) {
      if (property.name == 'then') then = property.readType;
    }
    for (final method in cls.methods) {
      if (method.name == 'then') {
        then = ExportType(
          method.signature.type,
          ValueKind.function,
          signature: method.signature,
        );
      }
    }
    final arguments = {
      for (var i = 0; i < cls.typeParameters.length; ++i)
        cls.typeParameters[i]: type.typeArguments[i],
    };
    if (then != null) return _substituteType(then, arguments);
    return cls.superclass == null
        ? null
        : _thenType(_substituteType(cls.superclass!, arguments));
  }

  bool _embedsType(ExportType from, ExportType to) {
    if (_typeKey(from) == _typeKey(to)) return true;
    final children = _typeChildren(to).toList();
    if (children.any((child) => _embedsType(from, child))) return true;
    if (from.kind != to.kind ||
        from.nullable != to.nullable ||
        from.classExport != to.classExport ||
        from.parameter != to.parameter ||
        from.typedDataKind != to.typedDataKind ||
        from.simdKind != to.simdKind ||
        from.referenceKind != to.referenceKind ||
        from.enumExport != to.enumExport) {
      return false;
    }
    final original = _typeChildren(from).toList();
    return original.length == children.length &&
        original.isNotEmpty &&
        [
          for (var i = 0; i < original.length; ++i)
            _embedsType(original[i], children[i]),
        ].every((value) => value);
  }

  List<_AwaitedBranch> _awaitedTypes(
    ExportType type, [
    List<({ExportType type, bool stop})> path = const [],
  ]) {
    if (_awaitPreserves(type)) return [(type: type, resolve: false)];
    final base = _copyType(type, nullable: false);
    final values = <_AwaitedBranch>[
      if (type.nullable)
        (type: ExportType(type.dartType, ValueKind.nullValue), resolve: false),
    ];
    final key = _typeKey(base);
    final repeated = path.indexWhere((step) => _typeKey(step.type) == key);
    if (repeated >= 0) {
      if (type.nullable || path.skip(repeated).any((step) => step.stop)) {
        return values;
      }
      throw FormatException(
        '@NAPI ${type.classExport?.name ?? 'Future'}: thenable resolution does not have a finite type.',
      );
    }
    if (base.kind == ValueKind.object &&
        path.any(
          (step) =>
              step.type.classExport == base.classExport &&
              _typeDepth(step.type) < _typeDepth(base) &&
              _embedsType(step.type, base),
        )) {
      throw FormatException(
        '@NAPI ${type.classExport!.name}: thenable resolution does not have a finite type.',
      );
    }
    ExportType? then;
    if (base.kind == ValueKind.future) {
      then = base.element;
    } else if (base.kind == ValueKind.map) {
      values.add((type: base, resolve: false));
      then = base.element;
    } else if (base.kind == ValueKind.object || base.kind == ValueKind.record) {
      then = _thenType(base);
    } else {
      values.add((type: base, resolve: true));
      return _normalizeAwaited(values);
    }
    final nullableThen =
        base.kind != ValueKind.future && then?.nullable == true;
    final stop = type.nullable || nullableThen || base.kind == ValueKind.map;
    if (nullableThen) values.add((type: base, resolve: false));
    if (base.kind != ValueKind.future) {
      final signature = then?.signature;
      final callbackType = signature?.positional.firstOrNull?.type;
      final callback = callbackType?.signature;
      if (signature != null &&
          callback == null &&
          (callbackType == null || !_mayCall(callbackType)) &&
          needsFunctionAdapter(signature)) {
        if (values.isEmpty) {
          values.add((
            type: ExportType(type.dartType, ValueKind.never),
            resolve: false,
          ));
        }
        return _normalizeAwaited(values);
      }
      then = callback?.positional.firstOrNull?.type;
      if (callback?.positional.firstOrNull?.required == false) then = null;
      if (then == null ||
          _mentions(then, {
            ...?signature?.typeParameters,
            ...?callback?.typeParameters,
          })) {
        values.add((
          type: ExportType(type.dartType, ValueKind.opaque, nullable: true),
          resolve: false,
        ));
        return _normalizeAwaited(values);
      }
    }
    if (then != null) {
      values.addAll(_awaitedTypes(then, [...path, (type: base, stop: stop)]));
    }
    return _normalizeAwaited(values);
  }

  List<_AwaitedBranch> _normalizeAwaited(List<_AwaitedBranch> branches) {
    final nullable = branches.any(
      (branch) => branch.type.kind == ValueKind.nullValue,
    );
    final values = <String, _AwaitedBranch>{};
    for (final branch in branches) {
      if (nullable && branch.type.kind == ValueKind.nullValue) continue;
      final value = (
        type: nullable ? _copyType(branch.type, nullable: true) : branch.type,
        resolve: branch.resolve,
      );
      values['${value.resolve}:${_typeKey(value.type)}'] = value;
    }
    return values.isEmpty && branches.isNotEmpty
        ? [branches.first]
        : values.values.toList();
  }

  String _awaitedBranchType(_AwaitedBranch branch, {bool metadata = true}) {
    final value = _type(branch.type, metadata: metadata);
    if (!branch.resolve) return value;
    final bound = _awaitBound(branch.type);
    return bound == null
        ? 'globalThis.Awaited<$value>'
        : '$_awaited<$value, ${_type(bound, metadata: metadata)}>';
  }

  bool _mentions(ExportType type, Set<ExportTypeParameter> parameters) =>
      parameters.contains(type.parameter) ||
      _typeChildren(type).any((child) => _mentions(child, parameters));

  ExportType? _awaitBound(ExportType type) {
    final seen = <ExportTypeParameter>{};
    while (type.kind == ValueKind.typeParameter) {
      final parameter = type.parameter!;
      if (!seen.add(parameter)) return null;
      if (_classParameters.contains(parameter)) {
        return seen.length > 1 ? type : null;
      }
      type = parameter.bound;
    }
    return null;
  }

  String? _localFutureCondition(_TypePair pair) {
    if (!pair.awaitLeft) return null;
    final left = pair.left, right = pair.right;
    if (left.kind != ValueKind.typeParameter ||
        left.parameter != right.parameter ||
        left.nullable != right.nullable ||
        !pair.locals.contains(left.parameter)) {
      return null;
    }
    final bound = _awaitBound(left);
    return bound == null ? null : '$_scalar<${_type(bound, metadata: false)}>';
  }

  String _differenceCondition(_Difference difference) {
    if (difference.always) return 'false';
    final pairs = difference.pairs.values;
    if (pairs.isEmpty) return 'true';
    final conditions = <String>{};
    for (final pair in pairs) {
      final locals = pair.locals.toSet();
      if (_mentions(pair.left, locals) || _mentions(pair.right, locals)) {
        // A local binder stays scoped; an outer scalar bound can prove stability.
        final condition = _localFutureCondition(pair);
        if (condition == null) return 'false';
        conditions.add(condition);
      } else {
        conditions.add(
          '$_same<${pair.awaitLeft ? _awaitedBranchType((type: pair.left, resolve: true), metadata: false) : _type(pair.left, metadata: false)}, ${_type(pair.right, output: false, metadata: false)}>',
        );
      }
    }
    return '[${conditions.join(', ')}] extends true[] ? true : false';
  }

  String _condition(ExportClass cls) => _differenceCondition(
    _differences[(left: cls, right: cls, inputOnly: false)]!,
  );

  String _functionCondition(ExportType type) {
    // Schema leaves avoid asking TypeScript to compare a recursive signature.
    final difference = _Difference();
    _collectDifference(type, type, difference);
    _solveDifferences();
    final pending = difference.edges.values.toList();
    final seen = <String>{};
    while (pending.isNotEmpty && !difference.always) {
      final edge = pending.removeLast();
      if (!seen.add(_pairKey(edge))) continue;
      _solveDifferences();
      final source =
          _differences[(
            left: edge.left.classExport!,
            right: edge.right.classExport!,
            inputOnly: edge.inputOnly,
          )]!;
      if (source.always) return 'false';
      final arguments = _edgeArguments(edge);
      for (final pair in source.pairs.values) {
        final next = _substituteDifference(
          pair,
          arguments,
          arguments,
          locals: edge.locals,
        );
        difference.always |= next.always;
        difference.pairs.addAll(next.pairs);
        pending.addAll(next.edges.values);
      }
    }
    return _differenceCondition(difference);
  }

  String _recoveryCondition(ExportType type) {
    if (type.kind == ValueKind.typeParameter) {
      if (!_parameterTypes.containsKey(type.parameter) &&
          _awaitPreserves(type)) {
        return 'true';
      }
      return '$_same<$_inputOf<${_type(type)}>, ${_type(type, output: false)}>';
    }
    if (type.kind == ValueKind.object ||
        type.kind == ValueKind.function ||
        type.kind == ValueKind.future) {
      return 'true';
    }
    final conditions = [
      for (final child in _typeChildren(type)) _recoveryCondition(child),
    ].where((value) => value != 'true').toSet();
    return conditions.isEmpty
        ? 'true'
        : '[${conditions.join(', ')}] extends true[] ? true : false';
  }

  String? _futureCondition(ExportType type) {
    final element = type.element!;
    if (_awaitPreserves(element)) return _recoveryCondition(element);
    final conditions = <String>{};
    for (final branch in _awaitedTypes(element)) {
      if (!branch.resolve && _typeKey(branch.type) == _typeKey(element)) {
        conditions.add(_recoveryCondition(element));
        continue;
      }
      final condition =
          '$_same<$_inputOf<${_awaitedBranchType(branch, metadata: false)}>, ${_type(element, output: false, metadata: false)}>';
      final bound = branch.resolve ? _awaitBound(branch.type) : null;
      conditions.add(
        bound == null
            ? condition
            : '($_scalar<${_type(bound, metadata: false)}> extends true ? true : $condition)',
      );
    }
    conditions.remove('true');
    return conditions.isEmpty
        ? 'true'
        : '[${conditions.join(', ')}] extends true[] ? true : false';
  }

  void _writeProperty(
    StringBuffer output,
    ExportProperty property, {
    bool static = false,
  }) {
    final prefix = static ? 'static ' : '';
    output.writeln(
      '  ${prefix}get ${_member(property.name)}(): ${property.readType == null ? 'undefined' : _type(property.readType!)};',
    );
    if (property.writeType != null) {
      output.writeln(
        '  ${prefix}set ${_member(property.name)}(value: ${_type(property.writeType!, output: false)});',
      );
    }
  }

  void _writeClass(
    StringBuffer output,
    ExportClass cls,
    String prefix,
    Set<String> brands,
  ) {
    var brand = '__napiBrand';
    while (!brands.add(brand)) {
      brand += '_';
    }
    if (!_classes.containsKey(cls)) {
      output.writeln(
        '${prefix}declare class ${cls.name}'
        '${cls.superclass == null ? '' : ' extends ${_type(cls.superclass!)}'} {',
      );
      output.writeln('  private readonly $brand: never;');
      if (_hasMetadata) output.writeln('  readonly [$_inputKey]: this;');
      final constructor = cls.constructor;
      final parent = exports.classes.any(
        (child) => child.superclass?.classExport == cls,
      );
      output.writeln(
        constructor == null
            ? '  ${parent ? 'protected' : 'private'} constructor();'
            : '  constructor(${_parameters(constructor.signature)});',
      );
      for (final function in cls.methods) {
        output.writeln(
          '  ${_member(function.name)}${_generics(function.signature.typeParameters, defaults: false)}(${_parameters(function.signature)}): ${_functionResult(function)};',
        );
      }
      for (final function in cls.staticMethods) {
        output.writeln(
          '  static ${_member(function.name)}${_generics(function.signature.typeParameters, defaults: false)}(${_parameters(function.signature)}): ${_functionResult(function)};',
        );
      }
      for (final property in cls.properties) {
        _writeProperty(output, property);
      }
      for (final property in cls.staticProperties) {
        _writeProperty(output, property, static: true);
      }
      output.writeln('}');
      return;
    }
    final names = _classes[cls]!;
    _withClassParameters(cls, () {
      output.writeln(
        'declare class ${names.shape}${_classParametersDeclaration(cls)}'
        '${cls.superclass == null ? '' : ' extends ${_classShape(cls.superclass!)}'} {',
      );
      output.writeln(
        '  private readonly $brand: ${names.modes.isEmpty ? 'never' : '[${names.modes.join(', ')}]'};',
      );
      output.writeln('  readonly [$_inputKey]: this;');
      for (final function in cls.methods) {
        output.writeln(
          '  ${_member(function.name)}${_generics(function.signature.typeParameters, defaults: false)}(${_parameters(function.signature)}): ${_functionResult(function)};',
        );
      }
      for (final property in cls.properties) {
        _writeProperty(output, property);
      }
      output.writeln('}');
    });
    final arguments = cls.typeParameters.isEmpty
        ? ''
        : '<${[
            for (final parameter in cls.typeParameters) ...[_parameterNames[parameter]!, '$_inputOf<${_parameterNames[parameter]!}>', '$_mode<${_parameterNames[parameter]!}>'],
          ].join(', ')}>';
    output.writeln(
      '${prefix}type ${cls.name}${_generics(cls.typeParameters)} = ${names.shape}$arguments;',
    );
    output.writeln('${prefix}declare const ${cls.name}: {');
    final prototype =
        '${names.shape}${names.inputs.isEmpty ? '' : '<${List.filled(names.inputs.length * 3, 'any').join(', ')}>'}';
    output.writeln('  readonly prototype: $prototype;');
    if (cls.constructor case final constructor?) {
      final result = _constructorResult(cls);
      output.writeln(
        '  new${_generics(cls.typeParameters)}(${_parameters(constructor.signature)}): $result;',
      );
    } else {
      output.writeln(
        '  [globalThis.Symbol.hasInstance](value: unknown): value is $prototype;',
      );
    }
    final methods = <String, ExportFunction>{};
    final properties = <String, ExportProperty>{};
    for (
      ExportClass? owner = cls;
      owner != null;
      owner = owner.superclass?.classExport
    ) {
      for (final function in owner.staticMethods) {
        methods.putIfAbsent(function.name, () => function);
      }
      for (final property in owner.staticProperties) {
        properties.putIfAbsent(property.name, () => property);
      }
    }
    for (final function in methods.values) {
      output.writeln(
        '  ${_member(function.name)}${_generics(function.signature.typeParameters, defaults: false)}(${_parameters(function.signature)}): ${_functionResult(function)};',
      );
    }
    for (final property in properties.values) {
      _writeProperty(output, property);
    }
    output.writeln(
      cls.constructor == null
          ? '} & globalThis.Omit<globalThis.Function, "prototype">;'
          : '};',
    );
  }

  String write() {
    final output = StringBuffer();
    final commonJsObject = !esm && exports.properties.isNotEmpty;
    final prefix = commonJsObject ? '' : 'export ';
    final brands = <String>{
      for (final cls in exports.classes) ...[
        ...cls.methods.map((member) => member.name),
        ...cls.properties.map((member) => member.name),
      ],
    };
    for (final enumeration in exports.enums) {
      output.writeln('${prefix}declare const ${enumeration.name}: {');
      for (final value in enumeration.cases) {
        output.writeln('  readonly ${jsonEncode(value.name)}: ${value.index};');
      }
      output.writeln('};');
      output.writeln(
        '${prefix}type ${enumeration.name} = typeof ${enumeration.name}[keyof typeof ${enumeration.name}];',
      );
    }
    for (final cls in exports.classes) {
      if (cls.isObject) {
        final names = _objects[cls]!;
        _withObjectParameters(cls, () {
          final parameters = _objectParameters(cls);
          final arguments = _objectArguments(cls);
          output.writeln('interface ${names.fields}$parameters {');
          for (final property in cls.properties) {
            output.writeln(
              '  ${jsonEncode(property.name)}: ${_type(property.readType!)};',
            );
          }
          output.writeln('}');
          output.writeln(
            'type ${names.output}$parameters = object & ${names.fields}$arguments & ((${_condition(cls)}) extends true ? {} : { readonly [$_inputKey]: ${cls.constructor == null ? 'never' : '${names.input}$arguments'} });',
          );
          if (cls.constructor case final constructor?) {
            output.writeln('type ${names.input}$parameters = object & {');
            for (final parameter in [
              ...constructor.signature.positional,
              ...constructor.signature.named,
            ]) {
              output.writeln(
                '  ${jsonEncode(parameter.name)}${parameter.required ? '' : '?'}: ${_type(parameter.type, output: false)};',
              );
            }
            output.writeln('};');
          }
        });
        final arguments = cls.typeParameters.isEmpty
            ? ''
            : '<${[
                for (final parameter in cls.typeParameters) ...[_parameterNames[parameter]!, '$_inputOf<${_parameterNames[parameter]!}>'],
              ].join(', ')}>';
        output.writeln(
          '${prefix}type ${cls.name}${_generics(cls.typeParameters)} = ${names.output}$arguments;',
        );
        continue;
      }
      _writeClass(output, cls, prefix, brands);
    }
    for (final function in exports.functions) {
      output.writeln(
        '${prefix}declare function ${function.name}${_generics(function.signature.typeParameters, defaults: false)}(${_parameters(function.signature)}): ${_functionResult(function)};',
      );
    }
    for (final value in exports.constants) {
      output.writeln(
        '${prefix}declare const ${value.name}: ${_type(value.type)};',
      );
    }
    if (esm || commonJsObject) _binding(output);
    if (_hasMetadata) {
      output.writeln('declare const $_inputKey: unique symbol;');
      output.writeln('declare const $_opaqueKey: unique symbol;');
      output.writeln(
        'type $_scalar<B> = 0 extends (1 & B) ? false : [B] extends [string | number | boolean | bigint | symbol | null | undefined] ? true : false;',
      );
      output.writeln(
        'type $_awaited<T, B> = $_scalar<B> extends true ? T : globalThis.Awaited<T>;',
      );
      output.writeln(
        'type $_same<A, B> = 0 extends (1 & A) ? 0 extends (1 & B) ? true : false : 0 extends (1 & B) ? false : [A] extends [B] ? [B] extends [A] ? true : false : false;',
      );
      output.writeln(
        'type $_projection<O, I, S extends boolean = $_same<$_inputOf<O>, I>> = O & (S extends true ? {} : { readonly [$_inputKey]: I });',
      );
      output.writeln(
        'type $_inputOf<T> = T extends { readonly [$_opaqueKey]: infer I } ? I : T extends { readonly [$_inputKey]: infer I } ? I',
      );
      output.writeln(
        '  : T extends globalThis.ReadonlyArray<unknown> ? { [K in keyof T]: $_inputOf<T[K]> }',
      );
      output.writeln(
        '  : T extends globalThis.Map<infer K, infer V> ? globalThis.Map<$_inputOf<K>, $_inputOf<V>>',
      );
      output.writeln(
        '  : T extends globalThis.Set<infer V> ? globalThis.Set<$_inputOf<V>>',
      );
      output.writeln(
        '  : T extends globalThis.Promise<infer V> ? globalThis.Promise<$_inputOf<V>>',
      );
      output.writeln(
        '  : T extends globalThis.AsyncIterable<infer V> ? globalThis.AsyncIterable<$_inputOf<V>>',
      );
      output.writeln(
        '  : T extends globalThis.Function | globalThis.Date | globalThis.ArrayBuffer | globalThis.ArrayBufferView ? T',
      );
      output.writeln(
        '  : T extends object ? keyof T extends never ? T : object & { [K in keyof T]: $_inputOf<T[K]> } : T;',
      );
      output.writeln(
        'type $_opaque<T> = $_same<T, $_inputOf<T>> extends true ? T : T & { readonly [$_opaqueKey]: T };',
      );
      output.writeln(
        'type $_mode<T> = unknown extends T ? unknown : T extends { readonly [$_opaqueKey]: infer I } ? { readonly raw: I }',
      );
      output.writeln(
        '  : T extends { readonly [$_inputKey]: unknown } ? $_same<T, $_inputOf<T>> extends true ? "stable" : { readonly mapped: T }',
      );
      output.writeln(
        '  : T extends globalThis.ReadonlyArray<unknown> ? { readonly array: $_mode<T[number]> }',
      );
      output.writeln(
        '  : T extends globalThis.Map<infer K, infer V> ? { readonly map: [$_mode<K>, $_mode<V>] }',
      );
      output.writeln(
        '  : T extends globalThis.Set<infer V> ? { readonly set: $_mode<V> }',
      );
      output.writeln(
        '  : T extends globalThis.Promise<infer V> ? { readonly promise: $_mode<V> }',
      );
      output.writeln(
        '  : T extends globalThis.AsyncIterable<infer V> ? { readonly async: $_mode<V> }',
      );
      output.writeln(
        '  : T extends globalThis.Function | globalThis.Date | globalThis.ArrayBuffer | globalThis.ArrayBufferView ? "stable"',
      );
      output.writeln(
        '  : T extends object ? { readonly [K in keyof T]: $_mode<T[K]> } : "stable";',
      );
    }
    final emitted = <({ExportClass cls, bool output})>{};
    while (emitted.length < _rawViews.length) {
      for (final view in _rawViews.toList()) {
        if (!emitted.add(view)) continue;
        final cls = view.cls;
        _withObjectParameters(cls, () {
          final names = _rawObjects[cls]!;
          final name = view.output ? names.output : names.input;
          output.writeln(
            'type $name${_objectParameters(cls, metadata: false)} = object & {',
          );
          if (view.output) {
            for (final property in cls.properties) {
              output.writeln(
                '  ${jsonEncode(property.name)}: ${_type(property.readType!, metadata: false)};',
              );
            }
          } else {
            final signature = cls.constructor!.signature;
            for (final parameter in [
              ...signature.positional,
              ...signature.named,
            ]) {
              output.writeln(
                '  ${jsonEncode(parameter.name)}${parameter.required ? '' : '?'}: ${_type(parameter.type, output: false, metadata: false)};',
              );
            }
          }
          output.writeln('};');
        });
      }
    }
    if (!commonJsObject) output.writeln('export {};');
    return output.toString();
  }

  void _binding(StringBuffer output) {
    final binding = _unique('_NapiBinding');
    output.writeln('declare const $binding: {');
    for (final name in [
      ...exports.classes
          .where((value) => !value.isObject)
          .map((value) => value.name),
      ...exports.functions.map((value) => value.name),
      ...exports.enums.map((value) => value.name),
      ...exports.constants.map((value) => value.name),
    ]) {
      output.writeln('  readonly ${jsonEncode(name)}: typeof $name;');
    }
    for (final property in exports.properties) {
      output.writeln(
        '  get ${_member(property.name)}(): ${property.readType == null ? 'undefined' : _type(property.readType!)};',
      );
      if (property.writeType != null) {
        output.writeln(
          '  set ${_member(property.name)}(value: ${_type(property.writeType!, output: false)});',
        );
      }
    }
    output.writeln('};');
    final aliases =
        <String, ({String alias, List<ExportTypeParameter> parameters})>{};
    void alias(String name, List<ExportTypeParameter> parameters) {
      final alias = _unique('_NapiType${aliases.length}');
      aliases[name] = (alias: alias, parameters: parameters);
      output.writeln(
        'type $alias${_generics(parameters)} = $name${_parameterArguments(parameters)};',
      );
    }

    for (final cls in exports.classes) {
      alias(cls.name, cls.typeParameters);
    }
    for (final enumeration in exports.enums) {
      alias(enumeration.name, const []);
    }
    if (aliases.isNotEmpty) {
      output.writeln('declare namespace $binding {');
      for (final entry in aliases.entries) {
        final parameters = entry.value.parameters;
        output.writeln(
          '  type ${entry.key}${_generics(parameters)} = ${entry.value.alias}${_parameterArguments(parameters)};',
        );
      }
      output.writeln('}');
    }
    output.writeln(esm ? 'export default $binding;' : 'export = $binding;');
  }

  String _parameters(
    ExportSignature function, {
    bool output = true,
    bool metadata = true,
  }) {
    final required = function.positional
        .where((parameter) => parameter.required)
        .length;
    final tuples = <String>[];
    final options = function.named.isEmpty
        ? null
        : '{ ${function.named.map((parameter) => '${jsonEncode(parameter.name)}${parameter.required ? '' : '?'}: ${_type(parameter.type, output: !output, metadata: metadata)};').join(' ')} }';
    for (var count = required; count <= function.positional.length; ++count) {
      final parameters = [
        for (var i = 0; i < count; ++i)
          '${_label(function.positional[i].name, i)}: ${_type(function.positional[i].type, output: !output, metadata: metadata)}',
      ];
      if (options == null ||
          !function.named.any((parameter) => parameter.required)) {
        tuples.add('[${parameters.join(', ')}]');
      }
      if (options != null) {
        tuples.add('[${[...parameters, 'options: $options'].join(', ')}]');
      }
    }
    return '...args: ${tuples.join(' | ')}';
  }

  String _type(ExportType type, {bool output = true, bool metadata = true}) {
    final value = switch (type.kind) {
      ValueKind.boolean => 'boolean',
      ValueKind.integer ||
      ValueKind.doubleValue ||
      ValueKind.number => 'number',
      ValueKind.string => 'string',
      ValueKind.bigint => 'bigint',
      ValueKind.simd || ValueKind.simdList =>
        'globalThis.${switch (type.simdKind!) {
          SimdKind.float32x4 => 'Float32Array',
          SimdKind.int32x4 => 'Int32Array',
          SimdKind.float64x2 => 'Float64Array',
        }}',
      ValueKind.dateTime => 'globalThis.Date',
      ValueKind.set =>
        'globalThis.Set<${_type(type.element!, output: output, metadata: metadata)}>',
      ValueKind.byteBuffer => 'globalThis.ArrayBuffer',
      ValueKind.byteData => 'globalThis.DataView',
      ValueKind.nullValue => 'null',
      ValueKind.voidValue => 'void',
      ValueKind.never => 'never',
      ValueKind.typeParameter =>
        (output
                ? _parameterTypes[type.parameter]?.output
                : _parameterTypes[type.parameter]?.input) ??
            _parameterNames[type.parameter!]!,
      ValueKind.object => _objectType(type, output: output, metadata: metadata),
      ValueKind.enumeration => type.enumExport!.name,
      ValueKind.undefined => 'undefined',
      ValueKind.dynamicValue => 'any',
      ValueKind.opaque => type.nullable ? 'unknown' : '({} | undefined)',
      ValueKind.jsReference => switch (type.referenceKind!) {
        JsReferenceKind.object => 'object',
        JsReferenceKind.function => 'globalThis.Function',
        JsReferenceKind.symbol => 'symbol',
      },
      ValueKind.function =>
        '(${_generics(type.signature!.typeParameters, defaults: false, metadata: metadata)}(${_parameters(type.signature!, output: output, metadata: metadata)}) => ${_type(type.signature!.result, output: output, metadata: metadata)})',
      ValueKind.future =>
        output
            ? 'globalThis.Promise<${_awaitedTypes(type.element!).map((branch) => _awaitedBranchType(branch, metadata: metadata)).join(' | ')}>'
            : 'globalThis.Promise<${_type(type.element!, output: output, metadata: metadata)}>',
      ValueKind.record => _record(type, output: output, metadata: metadata),
      ValueKind.stream =>
        'globalThis.${output ? 'AsyncIterableIterator' : 'AsyncIterable'}<${_type(type.element!, output: output, metadata: metadata)}>',
      ValueKind.list =>
        type.element!.nullable
            ? '(${_type(type.element!, output: output, metadata: metadata)})[]'
            : '${_type(type.element!, output: output, metadata: metadata)}[]',
      ValueKind.map =>
        '{ [key: string]: ${_type(type.element!, output: output, metadata: metadata)} }',
      ValueKind.typedData =>
        'globalThis.${switch (type.typedDataKind!) {
          TypedDataKind.int8 => 'Int8Array',
          TypedDataKind.uint8 => 'Uint8Array',
          TypedDataKind.uint8Clamped => 'Uint8ClampedArray',
          TypedDataKind.int16 => 'Int16Array',
          TypedDataKind.uint16 => 'Uint16Array',
          TypedDataKind.int32 => 'Int32Array',
          TypedDataKind.uint32 => 'Uint32Array',
          TypedDataKind.int64 => 'BigInt64Array',
          TypedDataKind.uint64 => 'BigUint64Array',
          TypedDataKind.float32 => 'Float32Array',
          TypedDataKind.float64 => 'Float64Array',
        }}',
    };
    final project =
        metadata &&
        output &&
        _hasMetadata &&
        (type.kind == ValueKind.function || type.kind == ValueKind.future);
    final condition = !project
        ? null
        : type.kind == ValueKind.function
        ? _functionCondition(type)
        : type.kind == ValueKind.future
        ? _futureCondition(type)
        : null;
    final projected = project
        ? condition == 'true'
              ? value
              : '$_projection<$value, ${_type(_copyType(type, nullable: false), output: false)}${condition == null ? '' : ', $condition'}>'
        : value;
    return type.nullable && type.kind != ValueKind.opaque
        ? '$projected | null'
        : projected;
  }

  String _objectType(
    ExportType type, {
    required bool output,
    bool metadata = true,
  }) {
    final cls = type.classExport!;
    if (!cls.isObject) {
      for (final argument in type.typeArguments) {
        if (!_containsParameter(argument)) _checkClassArgument(argument, cls);
      }
      if (_mentions(type, _parameterTypes.keys.toSet())) {
        return _classShape(type, metadata: metadata);
      }
      return '${cls.name}${type.typeArguments.isEmpty ? '' : '<${type.typeArguments.map((argument) => _classArgumentOutput(argument, metadata: metadata)).join(', ')}>'}';
    }
    if (!output && cls.constructor == null) return 'never';
    final pairs = [
      for (final argument in type.typeArguments)
        (
          output: _type(argument, metadata: metadata),
          input: _type(argument, output: false, metadata: metadata),
        ),
    ];
    if (!metadata) {
      final names = _rawObjects.putIfAbsent(
        cls,
        () => (
          output: _unique('_NapiObjectShape${_rawObjects.length}'),
          input: _unique('_NapiObjectInputShape${_rawObjects.length}'),
        ),
      );
      _rawViews.add((cls: cls, output: output));
      final name = output ? names.output : names.input;
      return '$name${pairs.isEmpty ? '' : '<${[
              for (final pair in pairs) ...[pair.output, pair.input],
            ].join(', ')}>'}';
    }
    final template = !output || type.typeArguments.any(_containsParameter);
    if (!template) {
      return '${cls.name}${pairs.isEmpty ? '' : '<${pairs.map((pair) => pair.output).join(', ')}>'}';
    }
    final name = output ? _objects[cls]!.output : _input(cls);
    return '$name${pairs.isEmpty ? '' : '<${[
            for (final pair in pairs) ...[pair.output, pair.input],
          ].join(', ')}>'}';
  }

  void _checkClassArgument(ExportType type, ExportClass owner) {
    if (type.kind == ValueKind.future &&
        const {
          ValueKind.object,
          ValueKind.record,
          ValueKind.map,
        }.contains(type.element!.kind) &&
        !_classFuturePreserves(type.element!)) {
      throw FormatException(
        '@NAPI ${owner.name}: thenable Future class arguments need different input and output types and are not supported yet: ${type.dartType}.',
      );
    }
    for (final child in _typeChildren(type)) {
      _checkClassArgument(child, owner);
    }
  }

  bool _classFuturePreserves(ExportType type) {
    if (!_awaitPreserves(type)) return false;
    if (type.kind != ValueKind.object || type.classExport!.isObject) {
      return true;
    }
    for (final cls in exports.classes) {
      var parent = cls.superclass?.classExport;
      while (parent != null && parent != type.classExport) {
        parent = parent.superclass?.classExport;
      }
      if (parent == null) continue;
      final then = _thenType(
        ExportType(
          cls.dartType,
          ValueKind.object,
          classExport: cls,
          typeArguments: [
            for (final parameter in cls.typeParameters) parameter.bound,
          ],
        ),
      );
      if (then != null && _mayCall(then)) return false;
    }
    return true;
  }

  bool _containsParameter(ExportType type) =>
      type.kind == ValueKind.typeParameter ||
      (type.element != null && _containsParameter(type.element!)) ||
      type.typeArguments.any(_containsParameter) ||
      (type.recordFields != null &&
          [
            ...type.recordFields!.positional,
            ...type.recordFields!.named.values,
          ].any(_containsParameter)) ||
      (type.signature != null &&
          [
            ...type.signature!.positional.map((p) => p.type),
            ...type.signature!.named.map((p) => p.type),
            type.signature!.result,
          ].any(_containsParameter));

  String _record(
    ExportType type, {
    required bool output,
    bool metadata = true,
  }) {
    final fields = type.recordFields!;
    if (fields.named.isEmpty) {
      return '[${fields.positional.map((field) => _type(field, output: output, metadata: metadata)).join(', ')}]';
    }
    final properties = [
      for (var i = 0; i < fields.positional.length; ++i)
        '${jsonEncode('\$${i + 1}')}: ${_type(fields.positional[i], output: output, metadata: metadata)};',
      for (final entry in fields.named.entries)
        '${jsonEncode(entry.key)}: ${_type(entry.value, output: output, metadata: metadata)};',
    ];
    return '{ ${properties.join(' ')} }';
  }

  List<ExportTypeParameter> _substituteParameters(
    List<ExportTypeParameter> originals,
    Map<ExportTypeParameter, ExportType> arguments,
  ) {
    final parameters = <ExportTypeParameter>[];
    for (final original in originals) {
      final parameter = ExportTypeParameter(
        original.target,
        original.actualType,
        reified: original.reified,
      );
      parameters.add(parameter);
      _parameterNames[parameter] = _parameterNames[original]!;
      arguments[original] = ExportType(
        parameter.invocationType,
        ValueKind.typeParameter,
        parameter: parameter,
      );
    }
    for (var i = 0; i < parameters.length; ++i) {
      parameters[i].bound = _substituteType(originals[i].bound, arguments);
      parameters[i].defaultType = _substituteType(
        originals[i].defaultType,
        arguments,
      );
    }
    return parameters;
  }

  _Difference _substituteDifference(
    _TypePair pair,
    Map<ExportTypeParameter, ExportType> left,
    Map<ExportTypeParameter, ExportType> right, {
    List<ExportTypeParameter> locals = const [],
  }) {
    final leftType = _substituteType(pair.left, left);
    final rightType = _substituteType(pair.right, right);
    final originals = _usedLocals(leftType, rightType, [
      ...locals,
      ...pair.locals,
    ]);
    final arguments = {...left};
    final scope = _substituteParameters(originals, arguments);
    // Callback constraints were compared separately; both sides share its binder.
    final localArguments = {
      for (final original in originals) original: arguments[original]!,
    };
    final result = _Difference();
    if (pair.awaitLeft) {
      _collectAwaitedDifference(
        _substituteType(leftType, localArguments),
        _substituteType(rightType, localArguments),
        result,
        scope,
      );
    } else {
      _collectDifference(
        _substituteType(leftType, localArguments),
        _substituteType(rightType, localArguments),
        result,
        locals: scope,
      );
    }
    return result;
  }

  ExportType _substituteType(
    ExportType type,
    Map<ExportTypeParameter, ExportType> arguments,
  ) {
    if (!_mentions(type, arguments.keys.toSet())) return type;
    final replacement = arguments[type.parameter];
    if (replacement != null) {
      if (!type.nullable || replacement.nullable) return replacement;
      return _copyType(replacement, nullable: true);
    }
    final signature = type.signature;
    final substitutions = {...arguments};
    final parameters = _substituteParameters(
      signature?.typeParameters ?? const [],
      substitutions,
    );
    ExportParameter parameter(ExportParameter value) => ExportParameter(
      name: value.name,
      type: _substituteType(value.type, substitutions),
      required: value.required,
      defaultValue: value.defaultValue,
    );
    return _copyType(
      type,
      element: type.element == null
          ? null
          : _substituteType(type.element!, arguments),
      typeArguments: [
        for (final argument in type.typeArguments)
          _substituteType(argument, arguments),
      ],
      signature: signature == null
          ? null
          : ExportSignature(
              type: signature.type,
              typeParameters: parameters,
              positional: signature.positional.map(parameter).toList(),
              named: signature.named.map(parameter).toList(),
              result: _substituteType(signature.result, substitutions),
            ),
      recordFields: type.recordFields == null
          ? null
          : (
              positional: [
                for (final field in type.recordFields!.positional)
                  _substituteType(field, arguments),
              ],
              named: {
                for (final entry in type.recordFields!.named.entries)
                  entry.key: _substituteType(entry.value, arguments),
              },
            ),
    );
  }
}

typedef _AwaitedBranch = ({ExportType type, bool resolve});
typedef _ObjectPair = ({ExportClass left, ExportClass right, bool inputOnly});

final class _TypePair {
  const _TypePair(
    this.left,
    this.right, {
    this.locals = const [],
    this.awaitLeft = false,
    this.inputOnly = false,
  });
  final ExportType left;
  final ExportType right;
  final List<ExportTypeParameter> locals;
  final bool awaitLeft;
  final bool inputOnly;
}

final class _Difference {
  bool always = false;
  final pairs = <String, _TypePair>{};
  final edges = <String, _TypePair>{};
  final paths = <String, List<({_ObjectPair node, _TypePair pair})>>{};
}

ExportType _copyType(
  ExportType type, {
  bool? nullable,
  ExportType? element,
  List<ExportType>? typeArguments,
  ExportSignature? signature,
  ({List<ExportType> positional, Map<String, ExportType> named})? recordFields,
}) => ExportType(
  type.dartType,
  type.kind,
  nullable: nullable ?? type.nullable,
  classExport: type.classExport,
  element: element ?? type.element,
  typedDataKind: type.typedDataKind,
  simdKind: type.simdKind,
  signature: signature ?? type.signature,
  recordFields: recordFields ?? type.recordFields,
  enumExport: type.enumExport,
  referenceKind: type.referenceKind,
  parameter: type.parameter,
  representation: type.representation,
  typeArguments: typeArguments ?? type.typeArguments,
);

String _label(String name, int index) =>
    RegExp(r'^[a-zA-Z_$][a-zA-Z0-9_$]*$').hasMatch(name) ? name : 'arg$index';

String _member(String name) => name == 'constructor' ? '["constructor"]' : name;

const _objectMemberNames = {
  'constructor',
  'toString',
  'toLocaleString',
  'valueOf',
  'hasOwnProperty',
  'isPrototypeOf',
  'propertyIsEnumerable',
};

const _reservedParameterNames = {
  'any',
  'unknown',
  'never',
  'number',
  'bigint',
  'boolean',
  'string',
  'symbol',
  'void',
  'object',
  'undefined',
  'globalThis',
};
