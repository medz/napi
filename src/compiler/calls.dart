import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/clone.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/type_algebra.dart';
import 'package:vm/modular/transformations/lowering.dart' as lowering;

import 'exports.dart';

/// Builds typed callbacks after CFE has resolved declarations and defaults.
final class Calls {
  Calls(this.component, this.library, this.envLibrary)
    : core = CoreTypes(component),
      hierarchy = ClassHierarchy(component, CoreTypes(component));

  final Library library;
  final Component component;
  final Library envLibrary;
  final CoreTypes core;
  final ClassHierarchy hierarchy;
  int _next = 0;
  bool usesClassBounds = false;
  final _objectReaders = <(ExportClass, bool), Procedure>{};
  final _objectWriters = <(ExportClass, bool), Procedure>{};
  bool _classArgumentConversion = false;
  final _objectNeeds = <(ExportClass, bool), Map<ExportTypeParameter, int>>{};
  Substitution _codecTypes = Substitution.empty;
  Map<ExportTypeParameter, PositionalParameter> _readCodecs = const {};
  Map<ExportTypeParameter, PositionalParameter> _writeCodecs = const {};
  Map<ExportTypeParameter, PositionalParameter> _codecDirections = const {};
  Map<ExportTypeParameter, LocalVariable?> _genericValues = const {};
  Map<ExportTypeParameter, Variable> _classCodecs = const {};

  DartType _dartType(ExportType type) =>
      _codecTypes.substituteType(type.dartType);

  FunctionType _signatureType(ExportSignature signature) =>
      _codecTypes.substituteType(signature.type) as FunctionType;

  Map<ExportTypeParameter, int> _codecNeeds(ExportClass cls, bool read) {
    var changed = true;
    while (changed) {
      changed = false;
      final active = <(ExportClass, bool)>{};
      void collect(ExportClass owner, bool reading) {
        final key = (owner, reading);
        final needs = _objectNeeds.putIfAbsent(key, () => {});
        if (!active.add(key)) return;
        void require(ExportType type, int bit) {
          if (!owner.typeParameters.contains(type.parameter)) return;
          final previous = needs[type.parameter] ?? 0;
          final bits = previous | bit;
          if (bits != previous) {
            needs[type.parameter!] = bits;
            changed = true;
          }
        }

        void direction(ExportType type) {
          if (usesDirectionalConversion(type)) return;
          if (type.kind == ValueKind.typeParameter) {
            require(type, 4);
          } else if (type.kind == ValueKind.list ||
              type.kind == ValueKind.map) {
            direction(type.element!);
          } else if (type.kind == ValueKind.record) {
            for (final field in [
              ...type.recordFields!.positional,
              ...type.recordFields!.named.values,
            ]) {
              direction(field);
            }
          } else if (type.kind == ValueKind.function) {
            for (final parameter in [
              ...type.signature!.positional,
              ...type.signature!.named,
            ]) {
              direction(parameter.type);
            }
            direction(type.signature!.result);
          }
        }

        void visit(ExportType type, bool input) {
          if (type.kind == ValueKind.typeParameter) {
            require(type, input ? 1 : 2);
          } else if (type.kind == ValueKind.object &&
              type.classExport!.isObject) {
            final nested = type.classExport!;
            collect(nested, input);
            final nestedNeeds = _objectNeeds[(nested, input)]!;
            for (var i = 0; i < nested.typeParameters.length; ++i) {
              final bits = nestedNeeds[nested.typeParameters[i]] ?? 0;
              if ((bits & 1) != 0) visit(type.typeArguments[i], true);
              if ((bits & 2) != 0) visit(type.typeArguments[i], false);
              if ((bits & 4) != 0) direction(type.typeArguments[i]);
            }
          } else if (type.kind == ValueKind.function) {
            final signature = type.signature!;
            for (final parameter in [
              ...signature.positional,
              ...signature.named,
            ]) {
              visit(parameter.type, !input);
            }
            visit(signature.result, input);
            if (!input && !needsFunctionAdapter(signature)) {
              direction(type);
            }
          } else if (type.kind == ValueKind.record) {
            for (final field in [
              ...type.recordFields!.positional,
              ...type.recordFields!.named.values,
            ]) {
              visit(field, input);
            }
          } else if (type.element != null) {
            visit(type.element!, input);
          }
        }

        if (reading) {
          final signature = owner.constructor?.signature;
          if (signature != null) {
            for (final parameter in [
              ...signature.positional,
              ...signature.named,
            ]) {
              visit(parameter.type, true);
            }
          }
        } else {
          for (final property in owner.properties) {
            visit(property.readType!, false);
          }
        }
        active.remove(key);
      }

      collect(cls, read);
    }
    return _objectNeeds[(cls, read)]!;
  }

  late final envClass = envLibrary.classes.singleWhere((c) => c.name == 'Env');
  late final objectClass = envLibrary.classes.singleWhere(
    (c) => c.name == 'JsObject',
  );
  late final argumentsClass = envLibrary.classes.singleWhere(
    (c) => c.name == 'JsArguments',
  );
  late final functionClass = envLibrary.classes.singleWhere(
    (c) => c.name == 'JsFunction',
  );
  late final referenceClass = envLibrary.classes.singleWhere(
    (c) => c.name == 'JsReference',
  );
  late final envType = InterfaceType(envClass, Nullability.nonNullable);
  late final objectType = InterfaceType(objectClass, Nullability.nonNullable);
  late final argumentsType = InterfaceType(
    argumentsClass,
    Nullability.nonNullable,
  );
  late final functionType = InterfaceType(
    functionClass,
    Nullability.nonNullable,
  );

  Procedure method(Class cls, String name) =>
      cls.procedures.singleWhere((p) => p.name.text == name);

  Expression call(
    Expression receiver,
    Procedure method,
    List<Expression> args, {
    List<NamedExpression> named = const [],
    List<DartType> types = const [],
  }) => InstanceInvocation(
    InstanceAccessKind.Instance,
    receiver,
    method.name,
    Arguments(args, named: named, types: types),
    interfaceTarget: method,
    functionType: FunctionTypeInstantiator.instantiate(
      method.function.computeFunctionType(Nullability.nonNullable),
      types,
    ),
  );

  Procedure procedure(
    String name,
    List<PositionalParameter> parameters,
    DartType result,
    Statement body,
  ) {
    final procedure = Procedure(
      Name(name, library),
      ProcedureKind.Method,
      FunctionNode(body, positionalParameters: parameters, returnType: result),
      isStatic: true,
      fileUri: library.fileUri,
    );
    library.addProcedure(procedure);
    _lower(procedure);
    return procedure;
  }

  void _lower(Procedure procedure) {
    lowering.transformProcedure(
      procedure,
      core,
      hierarchy,
      productMode: true,
      isClosureContextLoweringEnabled: false,
    );
  }

  LocalVariable local(
    List<Statement> statements,
    String name,
    DartType type,
    Expression initializer,
  ) {
    final variable = LocalVariable(
      name: name,
      type: type,
      isFinal: true,
      initializer: initializer,
    );
    statements.add(VariableStatement(VariableDeclaration(variable)));
    return variable;
  }

  Expression _present(PositionalParameter args, int index) => call(
    InstanceGet(
      InstanceAccessKind.Instance,
      VariableGet(args),
      Name('length'),
      interfaceTarget: method(argumentsClass, 'length'),
      resultType: core.intNonNullableRawType,
    ),
    method(core.numClass, '>'),
    [IntLiteral(index)],
  );

  Expression _default(ExportParameter parameter) =>
      parameter.defaultValue == null
      ? NullLiteral()
      : CloneVisitorNotMembers().clone(parameter.defaultValue!);

  Expression constant(ExportConstant value, PositionalParameter env) => _encode(
    env,
    value.type,
    CloneVisitorNotMembers().clone(value.target.initializer!),
  );

  Expression failure(String message) => Throw(
    ConstructorInvocation(
      core.index
          .getClass('dart:core', 'ArgumentError')
          .constructors
          .singleWhere((c) => c.name.text.isEmpty),
      Arguments([StringLiteral(message)]),
    ),
  );

  bool _isComposite(ExportType type) => switch (type.kind) {
    ValueKind.object ||
    ValueKind.list ||
    ValueKind.map ||
    ValueKind.set ||
    ValueKind.typedData ||
    ValueKind.simd ||
    ValueKind.simdList ||
    ValueKind.dateTime ||
    ValueKind.byteBuffer ||
    ValueKind.byteData ||
    ValueKind.function ||
    ValueKind.future ||
    ValueKind.stream ||
    ValueKind.record ||
    ValueKind.enumeration ||
    ValueKind.jsReference => true,
    _ => false,
  };

  ExportType? _classBound(ExportType type) {
    var bound = type.parameter!.bound;
    while (bound.kind == ValueKind.typeParameter) {
      if (bound.parameter!.reified &&
          !_genericValues.containsKey(bound.parameter)) {
        usesClassBounds = true;
        return bound;
      }
      bound = bound.parameter!.bound;
    }
    if (bound.kind != ValueKind.object || bound.classExport!.isObject) {
      return null;
    }
    usesClassBounds = true;
    return bound;
  }

  Expression _decode(
    PositionalParameter env,
    ExportType type,
    Expression Function(DartType) read, {
    bool futureValue = false,
  }) {
    if (type.kind == ValueKind.typeParameter) {
      if (_classCodecs[type.parameter] case final codec?) {
        return call(
          VariableGet(env),
          method(envClass, '_readClassArgument'),
          [VariableGet(codec), read(core.objectNullableRawType)],
          types: [_dartType(type)],
          named: [
            if (type.nullable) NamedExpression('nullable', BoolLiteral(true)),
            if (futureValue) NamedExpression('futureValue', BoolLiteral(true)),
          ],
        );
      }
      if (_genericValues.containsKey(type.parameter)) {
        final bound = _classBound(type);
        return call(
          VariableGet(env),
          method(
            envClass,
            bound == null ? '_readGenericValue' : '_readBoundGenericValue',
          ),
          [
            read(core.objectNullableRawType),
            if (_genericValues[type.parameter] case final values?)
              VariableGet(values),
          ],
          types: [_dartType(type), if (bound != null) _dartType(bound)],
        );
      }
      final codec = _readCodecs[type.parameter];
      if (codec != null) {
        final raw = SyntheticVariable(
          cosmeticName: 'value${_next++}',
          type: core.objectNullableRawType,
          initializer: read(core.objectNullableRawType),
          isFinal: true,
        );
        final convert = FunctionInvocation(
          FunctionAccessKind.FunctionType,
          VariableGet(codec),
          Arguments([VariableGet(raw)]),
          functionType: codec.type as FunctionType,
        );
        return Let(
          raw,
          type.nullable
              ? ConditionalExpression(
                  EqualsNull(VariableGet(raw)),
                  NullLiteral(),
                  convert,
                  _dartType(type),
                )
              : convert,
        );
      }
      if (type.parameter!.reified) {
        throw StateError('Missing reader for ${type.parameter!.name}');
      }
      return _decode(env, type.representation!, read);
    }
    if (type.kind == ValueKind.opaque || type.kind == ValueKind.dynamicValue) {
      return call(
        VariableGet(env),
        method(envClass, '_readValue'),
        [read(core.objectNullableRawType)],
        types: [_dartType(type)],
      );
    }
    if (!_isComposite(type)) return read(_dartType(type));
    final baseType = switch (type.kind) {
      ValueKind.function => functionType,
      ValueKind.enumeration => core.intNonNullableRawType,
      ValueKind.jsReference =>
        (_dartType(type) as InterfaceType).typeArguments.single
            as InterfaceType,
      _ => objectType,
    };
    final rawType = type.nullable
        ? baseType.withDeclaredNullability(Nullability.nullable)
        : baseType;
    final raw = SyntheticVariable(
      cosmeticName: 'object${_next++}',
      type: rawType,
      initializer: read(rawType),
      isFinal: true,
    );
    Expression source() =>
        type.nullable ? NullCheck(VariableGet(raw)) : VariableGet(raw);
    Expression convert() => switch (type.kind) {
      ValueKind.object =>
        type.classExport!.isObject
            ? _objectInvocation(env, type, source(), read: true)
            : call(
                VariableGet(env),
                method(envClass, 'unwrap'),
                [source()],
                types: [
                  _dartType(
                    type,
                  ).withDeclaredNullability(Nullability.nonNullable),
                ],
              ),
      ValueKind.list || ValueKind.map => call(
        VariableGet(env),
        method(
          envClass,
          type.kind == ValueKind.list ? '_readList' : '_readMap',
        ),
        [source(), _elementReader(env, type)],
        types: [_dartType(type.element!)],
      ),
      ValueKind.set => call(
        VariableGet(env),
        method(envClass, '_readSet'),
        [source(), _valueReader(env, type.element!)],
        types: [_dartType(type.element!)],
      ),
      ValueKind.typedData => call(
        VariableGet(env),
        method(envClass, _typedDataMethod(type, read: true)),
        [source(), IntLiteral(_typedArrayKind(type.typedDataKind!))],
        types: [
          _dartType(type).withDeclaredNullability(Nullability.nonNullable),
        ],
      ),
      ValueKind.simd || ValueKind.simdList => call(
        VariableGet(env),
        method(
          envClass,
          type.kind == ValueKind.simd ? '_readSimd' : '_readSimdList',
        ),
        [source(), IntLiteral(_simdArrayKind(type.simdKind!))],
        types: [
          _dartType(type).withDeclaredNullability(Nullability.nonNullable),
        ],
      ),
      ValueKind.dateTime => call(
        VariableGet(env),
        method(envClass, '_readDate'),
        [source()],
      ),
      ValueKind.byteBuffer || ValueKind.byteData => call(
        VariableGet(env),
        method(
          envClass,
          type.kind == ValueKind.byteBuffer
              ? '_readByteBuffer'
              : '_readByteData',
        ),
        [source()],
      ),
      ValueKind.function => _readFunction(env, type.signature!, source()),
      ValueKind.record => _readRecord(env, type, source),
      ValueKind.enumeration => _readEnum(type.enumExport!, source),
      ValueKind.jsReference => call(
        VariableGet(env),
        method(envClass, '_retain'),
        [source()],
        types: [(_dartType(type) as InterfaceType).typeArguments.single],
      ),
      ValueKind.future || ValueKind.stream => call(
        VariableGet(env),
        method(
          envClass,
          type.kind == ValueKind.future ? '_readFuture' : '_readStream',
        ),
        [
          source(),
          _valueReader(
            env,
            type.element!,
            future: type.kind == ValueKind.future,
          ),
        ],
        types: [_dartType(type.element!)],
      ),
      _ => throw StateError('Not a composite type: ${type.kind}'),
    };
    return Let(
      raw,
      type.nullable
          ? ConditionalExpression(
              EqualsNull(VariableGet(raw)),
              NullLiteral(),
              convert(),
              _dartType(type),
            )
          : convert(),
    );
  }

  Expression _elementReader(PositionalParameter env, ExportType type) {
    final source = PositionalParameter(
      cosmeticName: 'source',
      type: objectType,
    );
    final key = PositionalParameter(
      cosmeticName: 'key',
      type: type.kind == ValueKind.list
          ? core.intNonNullableRawType
          : core.stringNonNullableRawType,
    );
    final element = type.element!;
    return FunctionExpression(
      FunctionNode(
        ReturnStatement(
          _decode(
            env,
            element,
            (dartType) => call(
              VariableGet(source),
              method(
                objectClass,
                type.kind == ValueKind.list ? '_element' : 'get',
              ),
              [VariableGet(key)],
              types: [dartType],
            ),
          ),
        ),
        positionalParameters: [source, key],
        returnType: _dartType(element),
      ),
    );
  }

  Expression _encode(
    PositionalParameter env,
    ExportType type,
    Expression value,
  ) {
    if (type.kind == ValueKind.typeParameter) {
      if (_classCodecs[type.parameter] case final codec?) {
        return call(
          VariableGet(env),
          method(envClass, '_writeClassArgument'),
          [VariableGet(codec), value],
          types: [_dartType(type)],
          named: [
            if (type.nullable) NamedExpression('nullable', BoolLiteral(true)),
          ],
        );
      }
      if (_genericValues.containsKey(type.parameter)) {
        final bound = _classBound(type);
        return call(
          VariableGet(env),
          method(
            envClass,
            bound == null ? '_writeGenericValue' : '_writeBoundGenericValue',
          ),
          [
            value,
            if (_genericValues[type.parameter] case final values?)
              VariableGet(values),
          ],
          types: [_dartType(type), if (bound != null) _dartType(bound)],
        );
      }
      final codec = _writeCodecs[type.parameter];
      if (codec != null) {
        final result = SyntheticVariable(
          cosmeticName: 'value${_next++}',
          type: _dartType(type),
          initializer: value,
          isFinal: true,
        );
        final convert = FunctionInvocation(
          FunctionAccessKind.FunctionType,
          VariableGet(codec),
          Arguments([
            type.nullable
                ? NullCheck(VariableGet(result))
                : VariableGet(result),
          ]),
          functionType: codec.type as FunctionType,
        );
        return Let(
          result,
          type.nullable
              ? ConditionalExpression(
                  EqualsNull(VariableGet(result)),
                  NullLiteral(),
                  convert,
                  core.objectNullableRawType,
                )
              : convert,
        );
      }
      if (type.parameter!.reified) {
        throw StateError('Missing writer for ${type.parameter!.name}');
      }
      return _encode(env, type.representation!, value);
    }
    if (type.kind == ValueKind.voidValue) {
      return BlockExpression(
        Block([ExpressionStatement(value)]),
        _constant('undefined'),
      );
    }
    if (!_isComposite(type) || type.kind == ValueKind.jsReference) return value;
    final result = SyntheticVariable(
      cosmeticName: 'result${_next++}',
      type: _dartType(type),
      initializer: value,
      isFinal: true,
    );
    Expression source() =>
        type.nullable ? NullCheck(VariableGet(result)) : VariableGet(result);
    Expression convert() => switch (type.kind) {
      ValueKind.object =>
        type.classExport!.isObject
            ? _objectInvocation(env, type, source(), read: false)
            : call(
                VariableGet(env),
                method(envClass, 'wrap'),
                [source()],
                types: [type.classExport!.dartType],
              ),
      ValueKind.list || ValueKind.map => call(
        VariableGet(env),
        method(
          envClass,
          type.kind == ValueKind.list ? '_writeList' : '_writeMap',
        ),
        [source(), _elementWriter(env, type.element!)],
        types: [_dartType(type.element!)],
      ),
      ValueKind.set => call(
        VariableGet(env),
        method(envClass, '_writeSet'),
        [source(), _elementWriter(env, type.element!)],
        types: [_dartType(type.element!)],
      ),
      ValueKind.typedData => call(
        VariableGet(env),
        method(envClass, _typedDataMethod(type, read: false)),
        [source(), IntLiteral(_typedArrayKind(type.typedDataKind!))],
      ),
      ValueKind.simd || ValueKind.simdList => call(
        VariableGet(env),
        method(
          envClass,
          type.kind == ValueKind.simd ? '_writeSimd' : '_writeTypedData',
        ),
        [source(), IntLiteral(_simdArrayKind(type.simdKind!))],
      ),
      ValueKind.dateTime => call(
        VariableGet(env),
        method(envClass, '_writeDate'),
        [source()],
      ),
      ValueKind.byteBuffer || ValueKind.byteData => call(
        VariableGet(env),
        method(
          envClass,
          type.kind == ValueKind.byteBuffer
              ? '_writeByteBuffer'
              : '_writeByteData',
        ),
        [source()],
      ),
      ValueKind.function => _writeFunction(env, type.signature!, source),
      ValueKind.record => _writeRecord(env, type, source),
      ValueKind.enumeration => InstanceGet(
        InstanceAccessKind.Instance,
        source(),
        Name('index'),
        interfaceTarget: method(
          core.index.getClass('dart:core', 'Enum'),
          'index',
        ),
        resultType: core.intNonNullableRawType,
      ),
      ValueKind.future || ValueKind.stream => call(
        VariableGet(env),
        method(
          envClass,
          type.kind == ValueKind.future ? '_writeFuture' : '_writeStream',
        ),
        [source(), _elementWriter(env, type.element!)],
        types: [_dartType(type.element!)],
      ),
      _ => throw StateError('Not a composite type: ${type.kind}'),
    };
    return Let(
      result,
      type.nullable
          ? ConditionalExpression(
              EqualsNull(VariableGet(result)),
              NullLiteral(),
              convert(),
              (type.kind == ValueKind.enumeration
                      ? core.intNonNullableRawType
                      : objectType)
                  .withDeclaredNullability(Nullability.nullable),
            )
          : convert(),
    );
  }

  Expression _objectInvocation(
    PositionalParameter env,
    ExportType type,
    Expression value, {
    required bool read,
  }) {
    final cls = type.classExport!;
    if (read && cls.constructor == null && _classArgumentConversion) {
      return failure('${cls.name} has no annotated input constructor.');
    }
    final helper = _objectCodec(cls, read: read);
    final needs = _codecNeeds(cls, read);
    return StaticInvocation(
      helper,
      Arguments([
        VariableGet(env),
        value,
        for (var i = 0; i < cls.typeParameters.length; ++i) ...[
          if (((needs[cls.typeParameters[i]] ?? 0) & 1) != 0)
            _rawValueReader(env, type.typeArguments[i]),
          if (((needs[cls.typeParameters[i]] ?? 0) & 2) != 0)
            _elementWriter(env, type.typeArguments[i]),
          if (((needs[cls.typeParameters[i]] ?? 0) & 4) != 0)
            _directionalValue(type.typeArguments[i]),
        ],
      ], types: type.typeArguments.map(_dartType).toList()),
    );
  }

  Expression _rawValueReader(PositionalParameter env, ExportType type) {
    final value = PositionalParameter(
      cosmeticName: 'value',
      type: core.objectNullableRawType,
    );
    return FunctionExpression(
      FunctionNode(
        ReturnStatement(
          _decode(
            env,
            type,
            (dartType) => call(
              VariableGet(env),
              method(envClass, '_typedValue'),
              [VariableGet(value)],
              types: [dartType],
            ),
          ),
        ),
        positionalParameters: [value],
        returnType: _dartType(type),
      ),
    );
  }

  Procedure _objectCodec(ExportClass cls, {required bool read}) {
    final cache = read ? _objectReaders : _objectWriters;
    final key = (cls, _classArgumentConversion);
    final existing = cache[key];
    if (existing != null) return existing;
    if (read && cls.constructor == null) {
      throw FormatException(
        '@NAPI.object ${cls.name}: has no annotated input constructor.',
      );
    }
    final fresh = getFreshTypeParameters(cls.target.typeParameters);
    final classType = fresh.substitute(cls.dartType);
    final env = PositionalParameter(cosmeticName: 'env', type: envType);
    final value = PositionalParameter(
      cosmeticName: 'value',
      type: read ? objectType : classType,
    );
    final needs = _codecNeeds(cls, read);
    final readers = <ExportTypeParameter, PositionalParameter>{};
    final writers = <ExportTypeParameter, PositionalParameter>{};
    final directions = <ExportTypeParameter, PositionalParameter>{};
    final codecs = <PositionalParameter>[];
    for (var i = 0; i < cls.typeParameters.length; ++i) {
      final parameter = cls.typeParameters[i];
      final bits = needs[parameter] ?? 0;
      if ((bits & 1) != 0) {
        final codec = PositionalParameter(
          cosmeticName: 'read$i',
          type: FunctionType(
            [core.objectNullableRawType],
            fresh.freshTypeArguments[i],
            Nullability.nonNullable,
          ),
        );
        readers[parameter] = codec;
        codecs.add(codec);
      }
      if ((bits & 2) != 0) {
        final codec = PositionalParameter(
          cosmeticName: 'write$i',
          type: FunctionType(
            [fresh.freshTypeArguments[i]],
            core.objectNullableRawType,
            Nullability.nonNullable,
          ),
        );
        writers[parameter] = codec;
        codecs.add(codec);
      }
      if ((bits & 4) != 0) {
        final flag = PositionalParameter(
          cosmeticName: 'directional$i',
          type: core.boolNonNullableRawType,
        );
        directions[parameter] = flag;
        codecs.add(flag);
      }
    }
    final helper = Procedure(
      Name('_napi${read ? 'Read' : 'Write'}Object${_next++}', library),
      ProcedureKind.Method,
      FunctionNode(
        null,
        typeParameters: fresh.freshTypeParameters,
        positionalParameters: [env, value, ...codecs],
        returnType: read ? classType : objectType,
      ),
      isStatic: true,
      fileUri: library.fileUri,
    );
    // Cache the template before visiting fields, including expanding recursion.
    cache[key] = helper;
    library.addProcedure(helper);
    final savedTypes = _codecTypes;
    final savedReaders = _readCodecs;
    final savedWriters = _writeCodecs;
    final savedDirections = _codecDirections;
    _codecTypes = fresh.substitution;
    _readCodecs = readers;
    _writeCodecs = writers;
    _codecDirections = directions;
    try {
      final statements = <Statement>[];
      if (read) {
        final constructor = cls.constructor!;
        Expression parameter(ExportParameter parameter) => VariableGet(
          local(
            statements,
            parameter.name,
            _dartType(parameter.type),
            ConditionalExpression(
              call(VariableGet(value), method(objectClass, 'hasOwn'), [
                StringLiteral(parameter.name),
              ]),
              _decode(
                env,
                parameter.type,
                (type) => call(
                  VariableGet(value),
                  method(objectClass, 'get'),
                  [StringLiteral(parameter.name)],
                  types: [type],
                ),
              ),
              parameter.required
                  ? failure('Missing object property: ${parameter.name}')
                  : _default(parameter),
              _dartType(parameter.type),
            ),
          ),
        );
        final positional = [
          for (final item in constructor.signature.positional) parameter(item),
        ];
        final named = [
          for (final item in constructor.signature.named)
            NamedExpression(item.name, parameter(item)),
        ];
        statements.add(
          ReturnStatement(_invoke(constructor, env, null, positional, named)),
        );
      } else {
        final result = local(
          statements,
          'object',
          objectType,
          call(VariableGet(env), method(envClass, 'object'), []),
        );
        for (final property in cls.properties) {
          final getter = property.getter!;
          statements.add(
            ExpressionStatement(
              call(VariableGet(result), method(objectClass, 'defineValue'), [
                StringLiteral(property.name),
                _encode(
                  env,
                  property.readType!,
                  InstanceGet(
                    InstanceAccessKind.Instance,
                    VariableGet(value),
                    getter.name,
                    interfaceTarget: getter,
                    resultType: _dartType(property.readType!),
                  ),
                ),
              ]),
            ),
          );
        }
        statements.add(ReturnStatement(VariableGet(result)));
      }
      helper.function.body = ReturnStatement(
        call(
          VariableGet(env),
          method(envClass, '_convertObject'),
          [
            FunctionExpression(
              FunctionNode(
                Block(statements),
                returnType: read ? classType : objectType,
              ),
            ),
          ],
          types: [read ? classType : objectType],
        ),
      )..parent = helper.function;
      _lower(helper);
      return helper;
    } finally {
      _codecTypes = savedTypes;
      _readCodecs = savedReaders;
      _writeCodecs = savedWriters;
      _codecDirections = savedDirections;
    }
  }

  Expression _readEnum(ExportEnum enumeration, Expression Function() source) =>
      ConditionalExpression(
        LogicalExpression(
          call(source(), method(core.numClass, '>='), [IntLiteral(0)]),
          LogicalExpressionOperator.AND,
          call(source(), method(core.numClass, '<'), [
            IntLiteral(enumeration.cases.length),
          ]),
        ),
        InstanceInvocation(
          InstanceAccessKind.Instance,
          CloneVisitorNotMembers().clone(enumeration.values.initializer!),
          Name('[]'),
          Arguments([source()]),
          interfaceTarget: method(core.listClass, '[]'),
          functionType: FunctionType(
            [core.intNonNullableRawType],
            enumeration.dartType,
            Nullability.nonNullable,
          ),
        ),
        failure('Invalid enum index for ${enumeration.name}'),
        enumeration.dartType,
      );

  Expression _readRecord(
    PositionalParameter env,
    ExportType type,
    Expression Function() source,
  ) {
    final fields = type.recordFields!;
    final tuple = fields.named.isEmpty;
    final statements = <Statement>[];
    if (tuple) {
      statements.add(
        IfStatement(
          Not(
            call(
              InstanceGet(
                InstanceAccessKind.Instance,
                source(),
                method(objectClass, '_arrayLength').name,
                interfaceTarget: method(objectClass, '_arrayLength'),
                resultType: core.intNonNullableRawType,
              ),
              method(core.numClass, '=='),
              [IntLiteral(fields.positional.length)],
            ),
          ),
          ExpressionStatement(
            failure('Expected a tuple of length ${fields.positional.length}'),
          ),
          null,
        ),
      );
    }
    Expression field(String key, ExportType field) => VariableGet(
      local(
        statements,
        'field${_next++}',
        _dartType(field),
        ConditionalExpression(
          call(source(), method(objectClass, 'hasOwn'), [StringLiteral(key)]),
          _decode(
            env,
            field,
            (type) => call(
              source(),
              method(objectClass, 'get'),
              [StringLiteral(key)],
              types: [type],
            ),
          ),
          failure('Missing record field: $key'),
          _dartType(field),
        ),
      ),
    );
    final positional = [
      for (var i = 0; i < fields.positional.length; ++i)
        field(tuple ? '$i' : '\$${i + 1}', fields.positional[i]),
    ];
    final named = [
      for (final entry in fields.named.entries)
        NamedExpression(entry.key, field(entry.key, entry.value)),
    ];
    return BlockExpression(
      Block(statements),
      RecordLiteral(
        positional,
        named,
        (_dartType(type) as RecordType).withDeclaredNullability(
          Nullability.nonNullable,
        ),
      ),
    );
  }

  Expression _writeRecord(
    PositionalParameter env,
    ExportType type,
    Expression Function() source,
  ) {
    final fields = type.recordFields!;
    final tuple = fields.named.isEmpty;
    final recordType = (_dartType(type) as RecordType).withDeclaredNullability(
      Nullability.nonNullable,
    );
    final statements = <Statement>[];
    final result = local(
      statements,
      'record${_next++}',
      objectType,
      call(VariableGet(env), method(envClass, tuple ? '_array' : 'object'), [
        if (tuple) IntLiteral(fields.positional.length),
      ]),
    );
    void field(String key, ExportType type, Expression value) {
      statements.add(
        ExpressionStatement(
          call(VariableGet(result), method(objectClass, 'defineValue'), [
            StringLiteral(key),
            _encode(env, type, value),
          ]),
        ),
      );
    }

    for (var i = 0; i < fields.positional.length; ++i) {
      field(
        tuple ? '$i' : '\$${i + 1}',
        fields.positional[i],
        RecordIndexGet(source(), recordType, i),
      );
    }
    for (final entry in fields.named.entries) {
      field(
        entry.key,
        entry.value,
        RecordNameGet(source(), recordType, entry.key),
      );
    }
    return BlockExpression(Block(statements), VariableGet(result));
  }

  Expression _constant(String name) => CloneVisitorNotMembers().clone(
    envLibrary.fields
        .singleWhere((field) => field.name.text == name)
        .initializer!,
  );

  Expression _supplied(FunctionParameter parameter) => Not(
    StaticInvocation(
      core.index.getTopLevelProcedure('dart:core', 'identical'),
      Arguments([VariableGet(parameter), _constant('_omittedArgument')]),
    ),
  );

  Statement _append(LocalVariable list, Expression value) =>
      ExpressionStatement(
        InstanceInvocation(
          InstanceAccessKind.Instance,
          VariableGet(list),
          Name('add'),
          Arguments([value]),
          interfaceTarget: method(core.listClass, 'add'),
          functionType: FunctionType(
            [core.objectNullableRawType],
            const VoidType(),
            Nullability.nonNullable,
          ),
        ),
      );

  Expression _withFunctionGenerics(
    ExportSignature signature, {
    required bool erased,
    required Expression Function(List<TypeParameter>, List<DartType>) build,
  }) {
    final parameters = signature.typeParameters;
    if (parameters.isEmpty) return build(const [], const []);
    final savedTypes = _codecTypes;
    final savedValues = _genericValues;
    final fresh = getFreshTypeParameters([
      for (final parameter in parameters) parameter.target,
    ]);
    final freshTypes = Substitution.combine(fresh.substitution, savedTypes);
    for (var i = 0; i < parameters.length; ++i) {
      fresh.freshTypeParameters[i]
        ..bound = freshTypes.substituteType(parameters[i].bound.dartType)
        ..defaultType = freshTypes.substituteType(
          parameters[i].defaultType.dartType,
        );
    }
    final arguments = erased
        ? [
            for (final parameter in parameters)
              savedTypes.substituteType(parameter.actualType),
          ]
        : fresh.freshTypeArguments;
    _codecTypes = Substitution.combine(
      Substitution.fromPairs([
        for (final parameter in parameters) parameter.target,
      ], arguments),
      savedTypes,
    );
    _genericValues = {
      ...savedValues,
      for (final parameter in parameters) parameter: null,
    };
    try {
      return build(erased ? const [] : fresh.freshTypeParameters, arguments);
    } finally {
      _codecTypes = savedTypes;
      _genericValues = savedValues;
    }
  }

  Expression _readFunction(
    PositionalParameter env,
    ExportSignature signature,
    Expression source,
  ) => _withFunctionGenerics(
    signature,
    erased: false,
    build: (parameters, _) =>
        _readFunctionBody(env, signature, source, parameters),
  );

  Expression _readFunctionBody(
    PositionalParameter env,
    ExportSignature signature,
    Expression source,
    List<TypeParameter> typeParameters,
  ) {
    final reference = PositionalParameter(
      cosmeticName: 'reference',
      type: InterfaceType(referenceClass, Nullability.nonNullable, [
        functionType,
      ]),
    );
    final positional = [
      for (final parameter in signature.positional)
        PositionalParameter(
          cosmeticName: parameter.name,
          type: parameter.required
              ? _dartType(parameter.type)
              : core.objectNullableRawType,
          defaultValue: parameter.required
              ? null
              : _constant('_omittedArgument'),
        ),
    ];
    final named = [
      for (final parameter in signature.named)
        NamedParameter(
          parameterName: parameter.name,
          type: parameter.required
              ? _dartType(parameter.type)
              : core.objectNullableRawType,
          isRequired: parameter.required,
          defaultValue: parameter.required
              ? null
              : _constant('_omittedArgument'),
        ),
    ];
    final js = PositionalParameter(
      cosmeticName: 'function',
      type: functionType,
    );
    final statements = <Statement>[];
    if (signature.typeParameters.isNotEmpty) {
      final valuesClass = envLibrary.classes.singleWhere(
        (cls) => cls.name == '_GenericValues',
      );
      for (final parameter in signature.typeParameters) {
        final values = local(
          statements,
          '${parameter.name}Values',
          InterfaceType(valuesClass, Nullability.nonNullable),
          ConstructorInvocation(valuesClass.constructors.single, Arguments([])),
        );
        _genericValues = {..._genericValues, parameter: values};
      }
    }
    final arguments = local(
      statements,
      'arguments',
      InterfaceType(core.listClass, Nullability.nonNullable, [
        core.objectNullableRawType,
      ]),
      ListLiteral([], typeArgument: core.objectNullableRawType),
    );
    Expression encode(ExportParameter model, FunctionParameter parameter) =>
        _encode(
          env,
          model.type,
          model.required
              ? VariableGet(parameter)
              : (AsExpression(VariableGet(parameter), _dartType(model.type))
                  ..isTypeError = true),
        );
    for (var i = 0; i < positional.length; ++i) {
      final model = signature.positional[i];
      final append = _append(arguments, encode(model, positional[i]));
      statements.add(
        model.required
            ? append
            : IfStatement(_supplied(positional[i]), append, null),
      );
    }
    if (named.isNotEmpty) {
      final optionsStatements = <Statement>[];
      final options = local(
        optionsStatements,
        'options',
        objectType,
        call(VariableGet(env), method(envClass, 'object'), []),
      );
      for (var i = 0; i < named.length; ++i) {
        final model = signature.named[i];
        final write = ExpressionStatement(
          call(VariableGet(options), method(objectClass, 'defineValue'), [
            StringLiteral(model.name),
            encode(model, named[i]),
          ]),
        );
        optionsStatements.add(
          model.required
              ? write
              : IfStatement(_supplied(named[i]), write, null),
        );
      }
      optionsStatements.add(_append(arguments, VariableGet(options)));
      if (signature.named.any((parameter) => parameter.required)) {
        statements.addAll(optionsStatements);
      } else {
        Expression present = _supplied(named.first);
        for (final parameter in named.skip(1)) {
          present = LogicalExpression(
            present,
            LogicalExpressionOperator.OR,
            _supplied(parameter),
          );
        }
        statements.add(IfStatement(present, Block(optionsStatements), null));
      }
    }
    Expression invoke(DartType result) => call(
      VariableGet(js),
      method(functionClass, '_call'),
      [VariableGet(arguments)],
      types: [result],
    );
    if (signature.result.kind == ValueKind.voidValue) {
      statements.add(ExpressionStatement(invoke(core.objectNullableRawType)));
      statements.add(ReturnStatement());
    } else {
      statements.add(ReturnStatement(_decode(env, signature.result, invoke)));
    }
    final invocation = call(
      VariableGet(env),
      method(envClass, '_invokeFunction'),
      [
        VariableGet(reference),
        FunctionExpression(
          FunctionNode(
            Block(statements),
            positionalParameters: [js],
            returnType: _dartType(signature.result),
          ),
        ),
      ],
      types: [_dartType(signature.result)],
    );
    final wrapper = FunctionExpression(
      FunctionNode(
        ReturnStatement(invocation),
        typeParameters: typeParameters,
        positionalParameters: positional,
        namedParameters: named,
        requiredParameterCount: signature.type.requiredParameterCount,
        returnType: _dartType(signature.result),
      ),
    );
    return call(
      VariableGet(env),
      method(envClass, '_readFunction'),
      [
        source,
        FunctionExpression(
          FunctionNode(
            ReturnStatement(wrapper),
            positionalParameters: [reference],
            returnType: _signatureType(signature),
          ),
        ),
      ],
      types: [_signatureType(signature)],
    );
  }

  Expression _anyDirection(Iterable<Expression> values) {
    Expression? result;
    for (final value in values) {
      if (value is BoolLiteral) {
        if (value.value) return value;
        continue;
      }
      result = result == null
          ? value
          : LogicalExpression(result, LogicalExpressionOperator.OR, value);
    }
    return result ?? BoolLiteral(false);
  }

  Expression _adapterValue(ExportSignature signature) {
    if (needsFunctionAdapter(signature)) return BoolLiteral(true);
    final savedValues = _genericValues;
    _genericValues = {
      ...savedValues,
      for (final parameter in signature.typeParameters) parameter: null,
    };
    try {
      return _anyDirection([
        for (final parameter in [...signature.positional, ...signature.named])
          _directionalValue(parameter.type),
        _directionalValue(signature.result),
      ]);
    } finally {
      _genericValues = savedValues;
    }
  }

  Expression _directionalValue(ExportType type) {
    if (usesDirectionalConversion(type)) return BoolLiteral(true);
    if (type.kind == ValueKind.typeParameter && type.parameter!.reified) {
      if (_classCodecs[type.parameter] case final codec?) {
        final cls = envLibrary.classes.singleWhere(
          (c) => c.name == '_ClassArgument',
        );
        return InstanceGet(
          InstanceAccessKind.Instance,
          VariableGet(codec),
          Name('directional'),
          interfaceTarget: cls.fields.singleWhere(
            (field) => field.name.text == 'directional',
          ),
          resultType: core.boolNonNullableRawType,
        );
      }
      if (_genericValues.containsKey(type.parameter)) {
        return BoolLiteral(false);
      }
      final flag = _codecDirections[type.parameter];
      if (flag == null) {
        throw StateError('Missing direction for ${type.parameter!.name}');
      }
      return VariableGet(flag);
    }
    return switch (type.kind) {
      ValueKind.list || ValueKind.map => _directionalValue(type.element!),
      ValueKind.record => _anyDirection([
        for (final field in [
          ...type.recordFields!.positional,
          ...type.recordFields!.named.values,
        ])
          _directionalValue(field),
      ]),
      ValueKind.function => _adapterValue(type.signature!),
      _ => BoolLiteral(false),
    };
  }

  Expression _writeFunction(
    PositionalParameter env,
    ExportSignature signature,
    Expression Function() source,
  ) => _withFunctionGenerics(
    signature,
    erased: true,
    build: (_, arguments) =>
        _writeFunctionBody(env, signature, source, arguments),
  );

  Expression _writeFunctionBody(
    PositionalParameter env,
    ExportSignature signature,
    Expression Function() source,
    List<DartType> typeArguments,
  ) {
    final adapter = _adapterValue(signature);
    final invocationType = typeArguments.isEmpty
        ? _signatureType(signature)
        : FunctionTypeInstantiator.instantiate(
            _signatureType(signature),
            typeArguments,
          );
    final args = PositionalParameter(
      cosmeticName: 'arguments',
      type: argumentsType,
    );
    return call(
      VariableGet(env),
      method(envClass, '_writeFunction'),
      [
        source(),
        FunctionExpression(
          FunctionNode(
            _callBody(
              env,
              args,
              signature,
              preserveDefaults: true,
              tearOff: source,
              invoke: (positional, named) => FunctionInvocation(
                FunctionAccessKind.FunctionType,
                source(),
                Arguments(positional, named: named, types: typeArguments),
                functionType: invocationType,
              ),
            ),
            positionalParameters: [args],
            returnType: core.objectNullableRawType,
          ),
        ),
      ],
      types: [_signatureType(signature)],
      named: [
        if (adapter is! BoolLiteral || adapter.value)
          NamedExpression('preserveIdentity', Not(adapter)),
      ],
    );
  }

  Expression classArgument(PositionalParameter env, ExportType type) {
    final saved = _classArgumentConversion;
    _classArgumentConversion = true;
    try {
      return _classArgument(env, type);
    } finally {
      _classArgumentConversion = saved;
    }
  }

  Expression _classArgument(PositionalParameter env, ExportType type) {
    final cls = envLibrary.classes.singleWhere(
      (c) => c.name == '_ClassArgument',
    );
    Expression reader({bool future = false}) {
      final input = PositionalParameter(
        cosmeticName: 'input',
        type: core.objectNullableRawType,
      );
      Expression read(DartType target) => call(
        VariableGet(env),
        method(envClass, '_typedValue'),
        [VariableGet(input)],
        types: [target],
      );
      return FunctionExpression(
        FunctionNode(
          ReturnStatement(
            future ? _futureValue(env, type, read) : _decode(env, type, read),
          ),
          positionalParameters: [input],
          returnType: core.objectNullableRawType,
        ),
      );
    }

    final output = PositionalParameter(
      cosmeticName: 'output',
      type: core.objectNullableRawType,
    );
    return ConstructorInvocation(
      cls.constructors.single,
      Arguments(
        [
          reader(),
          FunctionExpression(
            FunctionNode(
              ReturnStatement(
                _encode(
                  env,
                  type,
                  AsExpression(VariableGet(output), _dartType(type))
                    ..isTypeError = true,
                ),
              ),
              positionalParameters: [output],
              returnType: core.objectNullableRawType,
            ),
          ),
          _directionalValue(type),
        ],
        named: [
          if (type.kind == ValueKind.future)
            NamedExpression('readFuture', reader(future: true)),
        ],
      ),
    );
  }

  Expression classArguments(
    PositionalParameter env,
    List<ExportType> arguments,
  ) {
    final cls = envLibrary.classes.singleWhere(
      (c) => c.name == '_ClassArgument',
    );
    return ListLiteral([
      for (final type in arguments) classArgument(env, type),
    ], typeArgument: InterfaceType(cls, Nullability.nonNullable));
  }

  Expression _valueReader(
    PositionalParameter env,
    ExportType element, {
    bool future = false,
  }) {
    final args = PositionalParameter(
      cosmeticName: 'arguments',
      type: argumentsType,
    );
    return FunctionExpression(
      FunctionNode(
        ReturnStatement(
          element.kind == ValueKind.voidValue
              ? null
              : future
              ? _futureValue(
                  env,
                  element,
                  (target) => call(
                    VariableGet(args),
                    method(argumentsClass, 'get'),
                    [IntLiteral(0)],
                    types: [target],
                  ),
                )
              : _argument(env, args, 0, element),
        ),
        positionalParameters: [args],
        returnType: _dartType(element),
      ),
    );
  }

  Expression _futureValue(
    PositionalParameter env,
    ExportType type,
    Expression Function(DartType) read,
  ) {
    if (type.kind == ValueKind.voidValue) return NullLiteral();
    if (type.kind != ValueKind.future) {
      return _decode(env, type, read, futureValue: true);
    }
    // A Promise has already flattened its result. Rebuild the declared Dart
    // layers with syncValue, which stores an inner Future without adopting it.
    final value = StaticInvocation(
      method(core.futureClass, 'syncValue'),
      Arguments(
        [_futureValue(env, type.element!, read)],
        types: [_dartType(type.element!)],
      ),
    );
    if (!type.nullable) return value;
    return ConditionalExpression(
      EqualsNull(read(core.objectNullableRawType)),
      NullLiteral(),
      value,
      _dartType(type),
    );
  }

  Expression _elementWriter(PositionalParameter env, ExportType element) {
    final value = PositionalParameter(
      cosmeticName: 'value',
      type: _dartType(element),
    );
    return FunctionExpression(
      FunctionNode(
        ReturnStatement(
          element.kind == ValueKind.voidValue
              ? _constant('undefined')
              : _encode(env, element, VariableGet(value)),
        ),
        positionalParameters: [value],
        returnType: core.objectNullableRawType,
      ),
    );
  }

  String _typedDataMethod(ExportType type, {required bool read}) {
    final bigint =
        type.typedDataKind == TypedDataKind.int64 ||
        type.typedDataKind == TypedDataKind.uint64;
    if (read) return bigint ? '_readBigIntTypedData' : '_readTypedData';
    return bigint ? '_writeBigIntTypedData' : '_writeTypedData';
  }

  int _simdArrayKind(SimdKind kind) => switch (kind) {
    SimdKind.float32x4 => 7,
    SimdKind.int32x4 => 5,
    SimdKind.float64x2 => 8,
  };

  int _typedArrayKind(TypedDataKind kind) => switch (kind) {
    TypedDataKind.int8 => 0,
    TypedDataKind.uint8 => 1,
    TypedDataKind.uint8Clamped => 2,
    TypedDataKind.int16 => 3,
    TypedDataKind.uint16 => 4,
    TypedDataKind.int32 => 5,
    TypedDataKind.uint32 => 6,
    TypedDataKind.float32 => 7,
    TypedDataKind.float64 => 8,
    TypedDataKind.int64 => 9,
    TypedDataKind.uint64 => 10,
  };

  Expression _argument(
    PositionalParameter env,
    PositionalParameter args,
    int index,
    ExportType type,
  ) => _decode(
    env,
    type,
    (dartType) => call(
      VariableGet(args),
      method(argumentsClass, 'get'),
      [IntLiteral(index)],
      types: [dartType],
    ),
  );

  void _return(
    List<Statement> statements,
    PositionalParameter env,
    Expression value,
    ExportType type, {
    bool raw = false,
  }) {
    if (raw) {
      statements.add(ReturnStatement(value));
    } else if (type.kind == ValueKind.voidValue) {
      statements.add(ExpressionStatement(value));
      statements.add(
        ReturnStatement(
          CloneVisitorNotMembers().clone(
            envLibrary.fields
                .singleWhere((f) => f.name.text == 'undefined')
                .initializer!,
          ),
        ),
      );
    } else {
      statements.add(ReturnStatement(_encode(env, type, value)));
    }
  }

  ({List<Expression> positional, List<NamedExpression> named}) _injectEnv(
    ExportFunction? function,
    PositionalParameter env,
    List<Expression> positional,
    List<NamedExpression> named,
  ) {
    final arguments = [...positional];
    for (final index in function?.envPositional ?? const <int>[]) {
      arguments.insert(index, VariableGet(env));
    }
    final namedArguments = [
      ...named,
      for (final name in function?.envNamed ?? const <String>[])
        NamedExpression(name, VariableGet(env)),
    ]..sort((a, b) => a.name.compareTo(b.name));
    return (positional: arguments, named: namedArguments);
  }

  Expression _invoke(
    ExportFunction function,
    PositionalParameter env,
    PositionalParameter? receiver,
    List<Expression> positional,
    List<NamedExpression> named,
  ) {
    final injected = _injectEnv(function, env, positional, named);
    final args = Arguments(
      injected.positional,
      named: injected.named,
      types: function.typeArguments.map(_codecTypes.substituteType).toList(),
    );
    final target = function.target;
    if (target is Constructor) return ConstructorInvocation(target, args);
    if (function.classParameters.isNotEmpty) {
      final callable = function.instance
          ? InstanceTearOff(
              InstanceAccessKind.Instance,
              VariableGet(receiver!),
              target.name,
              interfaceTarget: target as Procedure,
              resultType: function.tearOffType!,
            )
          : ConstantExpression(
              StaticTearOffConstant(target as Procedure),
              target.function.computeFunctionType(Nullability.nonNullable),
            );
      final result = DynamicInvocation(
        DynamicAccessKind.Dynamic,
        callable,
        Name('call'),
        args,
      );
      return function.signature.result.kind == ValueKind.voidValue
          ? result
          : (AsExpression(result, _dartType(function.signature.result))
              ..isTypeError = true);
    }
    if (!function.instance) return StaticInvocation(target as Procedure, args);
    return InstanceInvocation(
      InstanceAccessKind.Instance,
      VariableGet(receiver!),
      target.name,
      args,
      interfaceTarget: target as Procedure,
      functionType: _signatureType(function.signature),
    );
  }

  Procedure function(ExportFunction function, {bool rawResult = false}) {
    final env = PositionalParameter(cosmeticName: 'env', type: envType);
    final receiver = function.instance
        ? PositionalParameter(
            cosmeticName: 'receiver',
            type: function.owner!.dartType,
          )
        : null;
    final args = PositionalParameter(
      cosmeticName: 'arguments',
      type: argumentsType,
    );
    Block body(
      Map<ExportParameter, ({Variable value, Variable present})> supplied,
    ) => _callBody(
      env,
      args,
      function.signature,
      function: function,
      preserveDefaults: function.instance,
      rawResult: rawResult,
      supplied: supplied,
      invoke: (positional, named) =>
          _invoke(function, env, receiver, positional, named),
      tearOff: function.instance
          ? () {
              final result = InstanceTearOff(
                InstanceAccessKind.Instance,
                VariableGet(receiver!),
                function.target.name,
                interfaceTarget: function.target as Procedure,
                resultType: function.tearOffType!,
              );
              return function.typeArguments.isEmpty
                  ? result
                  : Instantiation(
                      result,
                      function.typeArguments
                          .map(_codecTypes.substituteType)
                          .toList(),
                    );
            }
          : null,
    );
    return procedure(
      '_napiCall${_next++}',
      [env, if (receiver != null) receiver, args],
      rawResult
          ? _dartType(function.signature.result)
          : core.objectNullableRawType,
      function.classParameters.isEmpty
          ? body(const {})
          : _classCallBody(function, env, args, body),
    );
  }

  Block _classCallBody(
    ExportFunction function,
    PositionalParameter env,
    PositionalParameter args,
    Block Function(Map<ExportParameter, ({Variable value, Variable present})>)
    body,
  ) {
    final parameters = <ExportTypeParameter>[];
    void add(ExportTypeParameter parameter) {
      if (!parameter.fromClass || parameters.contains(parameter)) return;
      if (parameter.bound.parameter case final parent?) add(parent);
      parameters.add(parameter);
    }

    function.signature.typeParameters.forEach(add);
    final genericClass = envLibrary.classes.singleWhere(
      (c) => c.name == '_GenericArgument',
    );
    final codecClass = envLibrary.classes.singleWhere(
      (c) => c.name == '_ClassArgument',
    );
    final codecType = InterfaceType(codecClass, Nullability.nonNullable);
    final boundClass = envLibrary.classes.singleWhere(
      (c) => c.name == '_BoundObject',
    );
    final boundType = InterfaceType(boundClass, Nullability.nonNullable);
    final slotType = InterfaceType(genericClass, Nullability.nullable, [
      const DynamicType(),
    ]);
    final statements = <Statement>[];
    final slots = local(
      statements,
      'types',
      InterfaceType(core.listClass, Nullability.nonNullable, [slotType]),
      ListLiteral([
        for (final _ in parameters) NullLiteral(),
      ], typeArgument: slotType),
    );
    final supplied = <ExportParameter, ({Variable value, Variable present})>{};
    final extract = component.libraries
        .singleWhere((lib) => lib.importUri.toString() == 'dart:_internal')
        .procedures
        .singleWhere((p) => p.name.text == 'extractTypeArguments');
    for (final parameter in function.classParameters) {
      final position = function.signature.positional.indexOf(parameter);
      final cls = parameter.type.classExport!;
      final Expression present;
      final Expression source;
      if (position >= 0) {
        present = _present(args, position);
        source = call(
          VariableGet(args),
          method(argumentsClass, 'get'),
          [IntLiteral(position)],
          types: [core.objectNullableRawType],
        );
      } else {
        final index = function.signature.positional.length;
        final options = local(
          statements,
          'options',
          objectType.withDeclaredNullability(Nullability.nullable),
          ConditionalExpression(
            _present(args, index),
            call(
              VariableGet(args),
              method(argumentsClass, 'get'),
              [IntLiteral(index)],
              types: [objectType],
            ),
            NullLiteral(),
            objectType.withDeclaredNullability(Nullability.nullable),
          ),
        );
        present = LogicalExpression(
          Not(EqualsNull(VariableGet(options))),
          LogicalExpressionOperator.AND,
          call(NullCheck(VariableGet(options)), method(objectClass, 'hasOwn'), [
            StringLiteral(parameter.name),
          ]),
        );
        source = call(
          NullCheck(VariableGet(options)),
          method(objectClass, 'get'),
          [StringLiteral(parameter.name)],
          types: [core.objectNullableRawType],
        );
      }
      final hasValue = local(
        statements,
        'present',
        core.boolNonNullableRawType,
        present,
      );
      final raw = local(
        statements,
        'value',
        core.objectNullableRawType,
        ConditionalExpression(
          VariableGet(hasValue),
          source,
          parameter.required
              ? failure('Missing argument: ${parameter.name}')
              : NullLiteral(),
          core.objectNullableRawType,
        ),
      );
      supplied[parameter] = (value: raw, present: hasValue);
      final active = parameter.type.nullable
          ? LogicalExpression(
              VariableGet(hasValue),
              LogicalExpressionOperator.AND,
              Not(EqualsNull(VariableGet(raw))),
            )
          : VariableGet(hasValue);
      final branch = <Statement>[];
      final bound = local(
        branch,
        'bound',
        boundType,
        call(
          VariableGet(env),
          method(envClass, '_classCall'),
          [AsExpression(VariableGet(raw), objectType)..isTypeError = true],
          types: [cls.dartType],
        ),
      );
      final fresh = getFreshTypeParameters(cls.target.typeParameters);
      final record = <Statement>[];
      for (var i = 0; i < parameter.type.typeArguments.length; ++i) {
        final argument = parameter.type.typeArguments[i];
        final index = argument.parameter == null
            ? -1
            : parameters.indexOf(argument.parameter!);
        if (index < 0 || argument.nullable) continue;
        record.add(
          ExpressionStatement(
            call(
              VariableGet(env),
              method(envClass, '_recordGenericArgument'),
              [
                VariableGet(slots),
                IntLiteral(index),
                call(
                  VariableGet(env),
                  method(envClass, '_classArgument'),
                  [VariableGet(bound), IntLiteral(i)],
                  types: [cls.dartType],
                ),
                StringLiteral(parameters[index].name),
              ],
              types: [fresh.freshTypeArguments[i]],
            ),
          ),
        );
      }
      record.add(ReturnStatement(NullLiteral()));
      branch.add(
        ExpressionStatement(
          StaticInvocation(
            extract,
            Arguments(
              [
                AsExpression(
                  InstanceGet(
                    InstanceAccessKind.Instance,
                    VariableGet(bound),
                    Name('value'),
                    interfaceTarget: boundClass.fields.singleWhere(
                      (f) => f.name.text == 'value',
                    ),
                    resultType: core.objectNonNullableRawType,
                  ),
                  cls.dartType,
                )..isTypeError = true,
                FunctionExpression(
                  FunctionNode(
                    Block(record),
                    typeParameters: fresh.freshTypeParameters,
                    returnType: core.objectNullableRawType,
                  ),
                ),
              ],
              types: [cls.dartType],
            ),
          ),
        ),
      );
      statements.add(IfStatement(active, Block(branch), null));
    }
    Block invoke(int index) {
      if (index == parameters.length) return body(supplied);
      final parameter = parameters[index];
      final type = TypeParameter(
        parameter.name,
        core.objectNullableRawType,
        const DynamicType(),
      );
      final codec = PositionalParameter(
        cosmeticName: 'conversion',
        type: codecType,
      );
      final fallbackType = parameter.bound.parameter?.fromClass == true
          ? parameter.bound
          : parameter.defaultType;
      final fallback = FunctionExpression(
        FunctionNode(
          ReturnStatement(classArgument(env, fallbackType)),
          returnType: codecType,
        ),
      );
      final savedTypes = _codecTypes;
      final savedCodecs = _classCodecs;
      _codecTypes = Substitution.combine(
        Substitution.fromPairs(
          [parameter.target],
          [TypeParameterType(type, Nullability.nonNullable)],
        ),
        savedTypes,
      );
      _classCodecs = {..._classCodecs, parameter: codec};
      late final Block next;
      try {
        next = invoke(index + 1);
      } finally {
        _codecTypes = savedTypes;
        _classCodecs = savedCodecs;
      }
      return Block([
        ReturnStatement(
          call(
            VariableGet(env),
            method(envClass, '_invokeGenericArgument'),
            [
              VariableGet(slots),
              IntLiteral(index),
              fallback,
              FunctionExpression(
                FunctionNode(
                  next,
                  typeParameters: [type],
                  positionalParameters: [codec],
                  returnType: core.objectNullableRawType,
                ),
              ),
            ],
            types: [savedTypes.substituteType(fallbackType.dartType)],
          ),
        ),
      ]);
    }

    statements.addAll(invoke(0).statements);
    return Block(statements);
  }

  Block _callBody(
    PositionalParameter env,
    PositionalParameter args,
    ExportSignature signature, {
    required bool preserveDefaults,
    required Expression Function(List<Expression>, List<NamedExpression>)
    invoke,
    ExportFunction? function,
    Expression Function()? tearOff,
    bool rawResult = false,
    Map<ExportParameter, ({Variable value, Variable present})> supplied =
        const {},
  }) {
    final statements = <Statement>[];
    final required = signature.positional.where((p) => p.required).length;

    // Omitted virtual arguments must reach the actual method, whose defaults
    // may differ from the exported interface's defaults.
    if (preserveDefaults && required < signature.positional.length) {
      final positional = <LocalVariable>[];
      void decode(int index) {
        final parameter = signature.positional[index];
        positional.add(
          local(
            statements,
            'argument$index',
            _dartType(parameter.type),
            supplied.containsKey(parameter)
                ? _decode(
                    env,
                    parameter.type,
                    (type) => call(
                      VariableGet(env),
                      method(envClass, '_typedValue'),
                      [VariableGet(supplied[parameter]!.value)],
                      types: [type],
                    ),
                  )
                : _argument(env, args, index, parameter.type),
          ),
        );
      }

      for (var index = 0; index < required; ++index) {
        decode(index);
      }
      for (
        var count = required;
        count <= signature.positional.length;
        ++count
      ) {
        final branch = <Statement>[];
        _return(
          branch,
          env,
          invoke([
            for (final parameter in positional) VariableGet(parameter),
          ], []),
          signature.result,
        );
        if (count == signature.positional.length) {
          statements.addAll(branch);
        } else {
          statements.add(
            IfStatement(Not(_present(args, count)), Block(branch), null),
          );
          decode(count);
        }
      }
    } else {
      final positional = <Expression>[];
      for (var i = 0; i < signature.positional.length; ++i) {
        final parameter = signature.positional[i];
        // Keep conversion inside the presence branch, including class unwrap.
        final decoded = supplied.containsKey(parameter)
            ? _decode(
                env,
                parameter.type,
                (type) => call(
                  VariableGet(env),
                  method(envClass, '_typedValue'),
                  [VariableGet(supplied[parameter]!.value)],
                  types: [type],
                ),
              )
            : _argument(env, args, i, parameter.type);
        Expression value = decoded;
        if (!parameter.required)
          value = ConditionalExpression(
            _present(args, i),
            value,
            _default(parameter),
            _dartType(parameter.type),
          );
        positional.add(
          VariableGet(
            local(statements, 'argument$i', _dartType(parameter.type), value),
          ),
        );
      }
      final named = <NamedExpression>[];
      final sparse =
          preserveDefaults && signature.named.any((p) => !p.required);
      LocalVariable? sparseArguments;
      List<Expression>? sparsePositional;
      if (sparse) {
        final injected = _injectEnv(function, env, positional, []);
        sparsePositional = injected.positional;
        sparseArguments = local(
          statements,
          'namedArguments',
          InterfaceType(core.mapClass, Nullability.nonNullable, [
            core.symbolNonNullableRawType,
            core.objectNullableRawType,
          ]),
          MapLiteral(
            [
              for (final argument in injected.named)
                MapLiteralEntry(
                  ConstantExpression(
                    SymbolConstant(argument.name, null),
                    core.symbolNonNullableRawType,
                  ),
                  argument.value,
                ),
            ],
            keyType: core.symbolNonNullableRawType,
            valueType: core.objectNullableRawType,
          ),
        );
      }
      if (signature.named.isNotEmpty) {
        final requiredOptions = signature.named.any((p) => p.required);
        final position = signature.positional.length;
        Expression getOptions() => call(
          VariableGet(args),
          method(argumentsClass, 'get'),
          [IntLiteral(position)],
          types: [objectType],
        );
        final options = local(
          statements,
          'options',
          requiredOptions
              ? objectType
              : objectType.withDeclaredNullability(Nullability.nullable),
          requiredOptions
              ? getOptions()
              : ConditionalExpression(
                  _present(args, position),
                  getOptions(),
                  NullLiteral(),
                  objectType.withDeclaredNullability(Nullability.nullable),
                ),
        );
        Expression optionsValue() => requiredOptions
            ? VariableGet(options)
            : NullCheck(VariableGet(options));
        for (final parameter in signature.named) {
          Expression present = call(
            optionsValue(),
            method(objectClass, 'hasOwn'),
            [StringLiteral(parameter.name)],
          );
          if (!requiredOptions)
            present = LogicalExpression(
              Not(EqualsNull(VariableGet(options))),
              LogicalExpressionOperator.AND,
              present,
            );
          if (supplied[parameter] case final value?)
            present = VariableGet(value.present);
          final decoded = _decode(
            env,
            parameter.type,
            (type) => supplied.containsKey(parameter)
                ? call(
                    VariableGet(env),
                    method(envClass, '_typedValue'),
                    [VariableGet(supplied[parameter]!.value)],
                    types: [type],
                  )
                : call(
                    optionsValue(),
                    method(objectClass, 'get'),
                    [StringLiteral(parameter.name)],
                    types: [type],
                  ),
          );
          final value = decoded;
          if (sparse) {
            final write = ExpressionStatement(
              InstanceInvocation(
                InstanceAccessKind.Instance,
                VariableGet(sparseArguments!),
                Name('[]='),
                Arguments([
                  ConstantExpression(
                    SymbolConstant(parameter.name, null),
                    core.symbolNonNullableRawType,
                  ),
                  value,
                ]),
                interfaceTarget: method(core.mapClass, '[]='),
                functionType: FunctionType(
                  [core.symbolNonNullableRawType, core.objectNullableRawType],
                  const VoidType(),
                  Nullability.nonNullable,
                ),
              ),
            );
            statements.add(
              IfStatement(
                present,
                write,
                parameter.required
                    ? ExpressionStatement(
                        failure('Missing named argument: ${parameter.name}'),
                      )
                    : null,
              ),
            );
          } else {
            final variable = local(
              statements,
              parameter.name,
              _dartType(parameter.type),
              ConditionalExpression(
                present,
                value,
                parameter.required
                    ? failure('Missing named argument: ${parameter.name}')
                    : _default(parameter),
                _dartType(parameter.type),
              ),
            );
            named.add(NamedExpression(parameter.name, VariableGet(variable)));
          }
        }
      }
      Expression invocation;
      if (sparse) {
        invocation = StaticInvocation(
          method(core.functionClass, 'apply'),
          Arguments([
            tearOff!(),
            ListLiteral(
              sparsePositional!,
              typeArgument: core.objectNullableRawType,
            ),
            VariableGet(sparseArguments!),
          ]),
        );
        if (signature.result.kind != ValueKind.voidValue) {
          invocation = AsExpression(invocation, _dartType(signature.result))
            ..isTypeError = true;
        }
      } else {
        invocation = invoke(positional, named);
      }
      _return(statements, env, invocation, signature.result, raw: rawResult);
    }
    return Block(statements);
  }

  Procedure property(ExportProperty property, {required bool setter}) {
    final env = PositionalParameter(cosmeticName: 'env', type: envType);
    final receiver = property.instance
        ? PositionalParameter(
            cosmeticName: 'receiver',
            type: property.owner!.dartType,
          )
        : null;
    final args = setter
        ? PositionalParameter(cosmeticName: 'arguments', type: argumentsType)
        : null;
    final statements = <Statement>[];
    final target = (setter ? property.setter : property.getter)!;
    if (setter) {
      final value = _argument(env, args!, 0, property.writeType!);
      statements.add(
        ExpressionStatement(
          property.instance
              ? InstanceSet(
                  InstanceAccessKind.Instance,
                  VariableGet(receiver!),
                  target.name,
                  value,
                  interfaceTarget: target,
                )
              : StaticSet(target, value),
        ),
      );
      statements.add(ReturnStatement());
    } else {
      final Expression value;
      if (property.instance) {
        value = InstanceGet(
          InstanceAccessKind.Instance,
          VariableGet(receiver!),
          target.name,
          interfaceTarget: target,
          resultType: _dartType(property.readType!),
        );
      } else if (target is Field && target.isConst) {
        value = CloneVisitorNotMembers().clone(target.initializer!);
      } else {
        value = StaticGet(target);
      }
      _return(statements, env, value, property.readType!);
    }
    return procedure(
      '_napiProperty${_next++}',
      [env, if (receiver != null) receiver, if (args != null) args],
      setter ? const VoidType() : core.objectNullableRawType,
      Block(statements),
    );
  }

  Expression bind(Procedure bridge, PositionalParameter env) {
    final parameters = [
      for (final parameter in bridge.function.positionalParameters.skip(1))
        PositionalParameter(
          cosmeticName: parameter.cosmeticName,
          type: parameter.type,
        ),
    ];
    return FunctionExpression(
      FunctionNode(
        ReturnStatement(
          StaticInvocation(
            bridge,
            Arguments([
              VariableGet(env),
              for (final parameter in parameters) VariableGet(parameter),
            ]),
          ),
        ),
        positionalParameters: parameters,
        returnType: bridge.function.returnType,
      ),
    );
  }
}
