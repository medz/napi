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
    _inputKey = _unique('_napiInput');
    _inputOf = _unique('_NapiInput');
    _same = _unique('_NapiSame');
    _projection = _unique('_NapiProjection');
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
  final _differences = <ExportClass, _Difference>{};
  final _parameterTypes =
      <ExportTypeParameter, ({String output, String input})>{};
  late final String _inputKey;
  late final String _inputOf;
  late final String _same;
  late final String _projection;

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
  }) {
    if (parameters.isEmpty) return '';
    if (!defaults) {
      return '<${parameters.map(_parameterDeclaration).join(', ')}>';
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
        ),
    ];
    return '<${declarations.join(', ')}>';
  }

  String _parameterDeclaration(
    ExportTypeParameter parameter, [
    ExportType? defaultType,
  ]) {
    final name = _parameterNames[parameter]!;
    final bound = parameter.bound;
    final constraint =
        bound.kind == ValueKind.dynamicValue ||
            bound.kind == ValueKind.opaque && bound.nullable
        ? ''
        : ' extends ${_type(bound)}';
    if (defaultType == null) return '$name$constraint';
    final value = defaultType.kind == ValueKind.dynamicValue
        ? 'unknown'
        : _type(defaultType);
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

  String _objectParameters(ExportClass cls) => cls.typeParameters.isEmpty
      ? ''
      : '<${[
          for (var i = 0; i < cls.typeParameters.length; ++i) ...[_parameterDeclaration(cls.typeParameters[i]), _objects[cls]!.inputs[i]],
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
    }
    try {
      return body();
    } finally {
      _parameterTypes
        ..clear()
        ..addAll(saved);
    }
  }

  void _analyzeDifferences() {
    for (final cls in _objects.keys) {
      final difference = _differences[cls] = _Difference();
      final constructor = cls.constructor;
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
      if (inputs.length != cls.properties.length ||
          cls.properties.any((p) => !inputs.containsKey(p.name)) ||
          inputs.values.any((p) => !p.required)) {
        difference.always = true;
        continue;
      }
      for (final property in cls.properties) {
        _collectDifference(
          property.readType!,
          inputs[property.name]!.type,
          difference,
        );
      }
    }
    bool reaches(ExportClass from, ExportClass to, Set<ExportClass> seen) {
      if (from == to) return true;
      if (!seen.add(from)) return false;
      return _differences[from]!.edges.values.any(
        (edge) => reaches(edge.left.classExport!, to, seen),
      );
    }

    var changed = true;
    while (changed) {
      changed = false;
      for (final entry in _differences.entries) {
        final difference = entry.value;
        if (difference.always) continue;
        for (final edge in difference.edges.values.toList()) {
          final nested = edge.left.classExport!;
          final source = _differences[nested]!;
          if (source.always) {
            difference.always = true;
            changed = true;
            break;
          }
          final left = {
            for (var i = 0; i < nested.typeParameters.length; ++i)
              nested.typeParameters[i]: edge.left.typeArguments[i],
          };
          final right = {
            for (var i = 0; i < nested.typeParameters.length; ++i)
              nested.typeParameters[i]: edge.right.typeArguments[i],
          };
          for (final pair in source.pairs.values.toList()) {
            final next = _Difference();
            _collectDifference(
              _substituteType(pair.left, left),
              _substituteType(pair.right, right),
              next,
            );
            if (next.always) {
              difference.always = true;
              changed = true;
              break;
            }
            for (final value in next.pairs.entries) {
              if (difference.pairs.containsKey(value.key)) continue;
              if (reaches(nested, entry.key, {}) &&
                  difference.pairs.values.any(
                    (old) =>
                        _pairParameters(old) == _pairParameters(value.value) &&
                        _pairDepth(old) < _pairDepth(value.value),
                  )) {
                throw FormatException(
                  '@NAPI.object ${entry.key.name}: recursive input/output projections expand at different rates.',
                );
              }
              difference.pairs[value.key] = value.value;
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
    _Difference result,
  ) {
    if (result.always) return;
    void pair() {
      final value = (left: left, right: right);
      result.pairs['${_typeKey(left)}|${_typeKey(right)}'] = value;
    }

    if (left.nullable != right.nullable) {
      pair();
      return;
    }
    if (left.kind == ValueKind.typeParameter ||
        right.kind == ValueKind.typeParameter) {
      if (left.parameter == right.parameter &&
          left.parameter != null &&
          !_objects.keys.any(
            (cls) => cls.typeParameters.contains(left.parameter),
          )) {
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
      pair();
      return;
    }
    if (left.kind == ValueKind.object) {
      if (left.classExport == right.classExport && left.classExport!.isObject) {
        result.edges['${_typeKey(left)}|${_typeKey(right)}'] = (
          left: left,
          right: right,
        );
      } else if (_typeKey(left) != _typeKey(right)) {
        pair();
      }
      return;
    }
    if (left.kind == ValueKind.future) {
      pair();
      return;
    }
    if (left.kind == ValueKind.stream) {
      result.always = true;
      return;
    }
    if (left.element != null && right.element != null) {
      _collectDifference(left.element!, right.element!, result);
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
      for (var i = 0; i < x.typeParameters.length; ++i) {
        _collectDifference(
          x.typeParameters[i].bound,
          _substituteType(y.typeParameters[i].bound, parameters),
          result,
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
        );
      }
      _collectDifference(
        x.result,
        _substituteType(y.result, parameters),
        result,
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
        _collectDifference(x.positional[i], y.positional[i], result);
      }
      for (final name in x.named.keys) {
        _collectDifference(x.named[name]!, y.named[name]!, result);
      }
      return;
    }
    if (_typeKey(left) != _typeKey(right)) pair();
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

  int _parameterId(ExportTypeParameter parameter) =>
      _parameterIds.putIfAbsent(parameter, () => _parameterIds.length);

  String _typeKey(ExportType type) =>
      '${type.kind}:${type.nullable}:${type.parameter == null ? '' : _parameterId(type.parameter!)}:${type.classExport?.name}:${type.typedDataKind}:${type.simdKind}:${type.referenceKind}:${type.enumExport?.name}'
      '${type.element == null ? '' : '[${_typeKey(type.element!)}]'}'
      '<${type.typeArguments.map(_typeKey).join(',')}>'
      '${type.signature == null ? '' : '(${type.signature!.typeParameters.map(_parameterId).join(',')};${type.signature!.positional.map((p) => '${p.required}:${_typeKey(p.type)}').join(',')};${type.signature!.named.map((p) => '${p.name}:${p.required}:${_typeKey(p.type)}').join(',')};${_typeKey(type.signature!.result)})'}'
      '${type.recordFields == null ? '' : '(${type.recordFields!.positional.map(_typeKey).join(',')};${type.recordFields!.named.entries.map((p) => '${p.key}:${_typeKey(p.value)}').join(',')})'}';

  String _pairParameters(_TypePair pair) {
    final values = <int>{};
    void visit(ExportType type) {
      if (type.parameter != null) values.add(_parameterId(type.parameter!));
      if (type.element != null) visit(type.element!);
      for (final a in type.typeArguments) {
        visit(a);
      }
    }

    visit(pair.left);
    visit(pair.right);
    return (values.toList()..sort()).join(',');
  }

  int _pairDepth(_TypePair pair) {
    int depth(ExportType type) {
      final children = [
        if (type.element != null) type.element!,
        ...type.typeArguments,
      ];
      return 1 +
          (children.isEmpty
              ? 0
              : children.map(depth).reduce((a, b) => a > b ? a : b));
    }

    return depth(pair.left) + depth(pair.right);
  }

  String _condition(ExportClass cls) {
    final difference = _differences[cls]!;
    if (difference.always) return 'false';
    final pairs = difference.pairs.values;
    if (pairs.isEmpty) return 'true';
    return '[${pairs.map((pair) => '$_same<${_type(pair.left, metadata: false)}, ${_type(pair.right, output: false, metadata: false)}>').join(', ')}] extends true[] ? true : false';
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
    final parents = {
      for (final cls in exports.classes)
        if (cls.superclass != null) cls.superclass!.classExport!,
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
      output.writeln(
        '${prefix}declare class ${cls.name}${_generics(cls.typeParameters)}'
        '${cls.superclass == null ? '' : ' extends ${_type(cls.superclass!)}'} {',
      );
      var brand = '__napiBrand';
      while (!brands.add(brand)) {
        brand += '_';
      }
      output.writeln('  private readonly $brand: never;');
      if (_objects.isNotEmpty) output.writeln('  readonly [$_inputKey]: this;');
      final constructor = cls.constructor;
      output.writeln(
        constructor == null
            ? '  ${parents.contains(cls) ? 'protected' : 'private'} constructor();'
            : '  constructor(${_parameters(constructor.signature)});',
      );
      for (final function in cls.methods) {
        output.writeln(
          '  ${_member(function.name)}${_generics(function.signature.typeParameters, defaults: false)}(${_parameters(function.signature)}): ${_type(function.signature.result)};',
        );
      }
      for (final function in cls.staticMethods) {
        output.writeln(
          '  static ${_member(function.name)}${_generics(function.signature.typeParameters, defaults: false)}(${_parameters(function.signature)}): ${_type(function.signature.result)};',
        );
      }
      void property(ExportProperty property, {required bool static}) {
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

      for (final value in cls.properties) {
        property(value, static: false);
      }
      for (final value in cls.staticProperties) {
        property(value, static: true);
      }
      output.writeln('}');
    }
    for (final function in exports.functions) {
      output.writeln(
        '${prefix}declare function ${function.name}${_generics(function.signature.typeParameters, defaults: false)}(${_parameters(function.signature)}): ${_type(function.signature.result)};',
      );
    }
    for (final value in exports.constants) {
      output.writeln(
        '${prefix}declare const ${value.name}: ${_type(value.type)};',
      );
    }
    if (esm || commonJsObject) _binding(output);
    if (_objects.isNotEmpty) {
      output.writeln('declare const $_inputKey: unique symbol;');
      output.writeln(
        'type $_same<A, B> = 0 extends (1 & A) ? 0 extends (1 & B) ? true : false : 0 extends (1 & B) ? false : [A] extends [B] ? [B] extends [A] ? true : false : false;',
      );
      output.writeln(
        'type $_projection<O, I> = O & ($_same<$_inputOf<O>, I> extends true ? {} : { readonly [$_inputKey]: I });',
      );
      output.writeln(
        'type $_inputOf<T> = T extends { readonly [$_inputKey]: infer I } ? I',
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

  String _parameters(ExportSignature function, {bool output = true}) {
    final required = function.positional
        .where((parameter) => parameter.required)
        .length;
    final tuples = <String>[];
    final options = function.named.isEmpty
        ? null
        : '{ ${function.named.map((parameter) => '${jsonEncode(parameter.name)}${parameter.required ? '' : '?'}: ${_type(parameter.type, output: !output)};').join(' ')} }';
    for (var count = required; count <= function.positional.length; ++count) {
      final parameters = [
        for (var i = 0; i < count; ++i)
          '${_label(function.positional[i].name, i)}: ${_type(function.positional[i].type, output: !output)}',
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
        'globalThis.Set<${_type(type.element!, output: output)}>',
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
      ValueKind.object => _objectType(type, output: output),
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
        '(${_generics(type.signature!.typeParameters, defaults: false)}(${_parameters(type.signature!, output: output)}) => ${_type(type.signature!.result, output: output)})',
      ValueKind.future =>
        output
            ? 'globalThis.Promise<globalThis.Awaited<${_type(type.element!, output: output)}>>'
            : 'globalThis.Promise<${_type(type.element!, output: output)}>',
      ValueKind.record => _record(type, output: output),
      ValueKind.stream =>
        'globalThis.${output ? 'AsyncIterableIterator' : 'AsyncIterable'}<${_type(type.element!, output: output)}>',
      ValueKind.list =>
        type.element!.nullable
            ? '(${_type(type.element!, output: output)})[]'
            : '${_type(type.element!, output: output)}[]',
      ValueKind.map =>
        '{ [key: string]: ${_type(type.element!, output: output)} }',
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
    final projected =
        metadata &&
            output &&
            _objects.isNotEmpty &&
            (type.kind == ValueKind.function || type.kind == ValueKind.future)
        ? '$_projection<$value, ${_type(_copyType(type, nullable: false), output: false, metadata: false)}>'
        : value;
    return type.nullable && type.kind != ValueKind.opaque
        ? '$projected | null'
        : projected;
  }

  String _objectType(ExportType type, {required bool output}) {
    final cls = type.classExport!;
    if (!cls.isObject) {
      return '${cls.name}${type.typeArguments.isEmpty ? '' : '<${type.typeArguments.map((argument) => _type(argument)).join(', ')}>'}';
    }
    if (!output && cls.constructor == null) return 'never';
    final pairs = [
      for (final argument in type.typeArguments)
        (output: _type(argument), input: _type(argument, output: false)),
    ];
    final template = !output || type.typeArguments.any(_containsParameter);
    if (!template) {
      return '${cls.name}${pairs.isEmpty ? '' : '<${pairs.map((pair) => pair.output).join(', ')}>'}';
    }
    final name = output ? _objects[cls]!.output : _input(cls);
    return '$name${pairs.isEmpty ? '' : '<${[
            for (final pair in pairs) ...[pair.output, pair.input],
          ].join(', ')}>'}';
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

  String _record(ExportType type, {required bool output}) {
    final fields = type.recordFields!;
    if (fields.named.isEmpty) {
      return '[${fields.positional.map((field) => _type(field, output: output)).join(', ')}]';
    }
    final properties = [
      for (var i = 0; i < fields.positional.length; ++i)
        '${jsonEncode('\$${i + 1}')}: ${_type(fields.positional[i], output: output)};',
      for (final entry in fields.named.entries)
        '${jsonEncode(entry.key)}: ${_type(entry.value, output: output)};',
    ];
    return '{ ${properties.join(' ')} }';
  }
}

typedef _TypePair = ({ExportType left, ExportType right});

final class _Difference {
  bool always = false;
  final pairs = <String, _TypePair>{};
  final edges = <String, _TypePair>{};
}

ExportType _substituteType(
  ExportType type,
  Map<ExportTypeParameter, ExportType> arguments,
) {
  final replacement = arguments[type.parameter];
  if (replacement != null) {
    if (!type.nullable || replacement.nullable) return replacement;
    return _copyType(replacement, nullable: true);
  }
  ExportParameter parameter(ExportParameter value) => ExportParameter(
    name: value.name,
    type: _substituteType(value.type, arguments),
    required: value.required,
    defaultValue: value.defaultValue,
  );
  final signature = type.signature;
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
            typeParameters: signature.typeParameters,
            positional: signature.positional.map(parameter).toList(),
            named: signature.named.map(parameter).toList(),
            result: _substituteType(signature.result, arguments),
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
