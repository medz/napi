import 'package:kernel/ast.dart';
import 'package:kernel/class_hierarchy.dart';
import 'package:kernel/clone.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/type_algebra.dart';
import 'package:vm/modular/transformations/lowering.dart' as lowering;

import 'exports.dart';

/// Builds typed callbacks after CFE has resolved declarations and defaults.
final class Calls {
  Calls(Component component, this.library, this.envLibrary)
    : core = CoreTypes(component),
      hierarchy = ClassHierarchy(component, CoreTypes(component));

  final Library library;
  final Library envLibrary;
  final CoreTypes core;
  final ClassHierarchy hierarchy;
  int _next = 0;
  final _objectReaders = <ExportClass, Procedure>{};
  final _objectWriters = <ExportClass, Procedure>{};

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
    ValueKind.typedData ||
    ValueKind.function ||
    ValueKind.future ||
    ValueKind.stream ||
    ValueKind.record ||
    ValueKind.enumeration ||
    ValueKind.jsReference => true,
    _ => false,
  };

  Expression _decode(
    PositionalParameter env,
    ExportType type,
    Expression Function(DartType) read,
  ) {
    if (type.kind == ValueKind.opaque || type.kind == ValueKind.dynamicValue) {
      return call(
        VariableGet(env),
        method(envClass, '_readValue'),
        [read(core.objectNullableRawType)],
        types: [type.dartType],
      );
    }
    if (type.kind == ValueKind.future &&
        type.element!.kind == ValueKind.future) {
      throw const FormatException(
        '@NAPI: nested Future inputs are not supported because JavaScript Promises flatten their value.',
      );
    }
    if (!_isComposite(type)) return read(type.dartType);
    final baseType = switch (type.kind) {
      ValueKind.function => functionType,
      ValueKind.enumeration => core.intNonNullableRawType,
      ValueKind.jsReference =>
        (type.dartType as InterfaceType).typeArguments.single as InterfaceType,
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
            ? StaticInvocation(
                _objectCodec(type.classExport!, read: true),
                Arguments([VariableGet(env), source()]),
              )
            : call(
                VariableGet(env),
                method(envClass, 'unwrap'),
                [source()],
                types: [type.classExport!.dartType],
              ),
      ValueKind.list || ValueKind.map => call(
        VariableGet(env),
        method(
          envClass,
          type.kind == ValueKind.list ? '_readList' : '_readMap',
        ),
        [source(), _elementReader(env, type)],
        types: [type.element!.dartType],
      ),
      ValueKind.typedData => call(
        VariableGet(env),
        method(envClass, _typedDataMethod(type, read: true)),
        [source(), IntLiteral(_typedArrayKind(type.typedDataKind!))],
        types: [type.dartType.withDeclaredNullability(Nullability.nonNullable)],
      ),
      ValueKind.function => _readFunction(env, type.signature!, source()),
      ValueKind.record => _readRecord(env, type, source),
      ValueKind.enumeration => _readEnum(type.enumExport!, source),
      ValueKind.jsReference => call(
        VariableGet(env),
        method(envClass, '_retain'),
        [source()],
        types: [(type.dartType as InterfaceType).typeArguments.single],
      ),
      ValueKind.future || ValueKind.stream => call(
        VariableGet(env),
        method(
          envClass,
          type.kind == ValueKind.future ? '_readFuture' : '_readStream',
        ),
        [source(), _valueReader(env, type.element!)],
        types: [type.element!.dartType],
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
              type.dartType,
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
        returnType: element.dartType,
      ),
    );
  }

  Expression _encode(
    PositionalParameter env,
    ExportType type,
    Expression value,
  ) {
    if (type.kind == ValueKind.voidValue) {
      return BlockExpression(
        Block([ExpressionStatement(value)]),
        _constant('undefined'),
      );
    }
    if (!_isComposite(type) || type.kind == ValueKind.jsReference) return value;
    final result = SyntheticVariable(
      cosmeticName: 'result${_next++}',
      type: type.dartType,
      initializer: value,
      isFinal: true,
    );
    Expression source() =>
        type.nullable ? NullCheck(VariableGet(result)) : VariableGet(result);
    Expression convert() => switch (type.kind) {
      ValueKind.object =>
        type.classExport!.isObject
            ? StaticInvocation(
                _objectCodec(type.classExport!, read: false),
                Arguments([VariableGet(env), source()]),
              )
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
        types: [type.element!.dartType],
      ),
      ValueKind.typedData => call(
        VariableGet(env),
        method(envClass, _typedDataMethod(type, read: false)),
        [source(), IntLiteral(_typedArrayKind(type.typedDataKind!))],
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
        types: [type.element!.dartType],
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

  Procedure _objectCodec(ExportClass cls, {required bool read}) {
    final cache = read ? _objectReaders : _objectWriters;
    final existing = cache[cls];
    if (existing != null) return existing;
    if (read && cls.constructor == null) {
      throw FormatException(
        '@NAPI.object ${cls.name}: has no annotated input constructor.',
      );
    }
    final env = PositionalParameter(cosmeticName: 'env', type: envType);
    final value = PositionalParameter(
      cosmeticName: 'value',
      type: read ? objectType : cls.dartType,
    );
    final helper = Procedure(
      Name('_napi${read ? 'Read' : 'Write'}Object${_next++}', library),
      ProcedureKind.Method,
      FunctionNode(
        null,
        positionalParameters: [env, value],
        returnType: read ? cls.dartType : objectType,
      ),
      isStatic: true,
      fileUri: library.fileUri,
    );
    // Register the reference before visiting properties so recursive types use
    // the same helper instead of recursively expanding generated code.
    cache[cls] = helper;
    library.addProcedure(helper);
    final statements = <Statement>[];
    if (read) {
      final constructor = cls.constructor!;
      Expression parameter(ExportParameter parameter) => VariableGet(
        local(
          statements,
          parameter.name,
          parameter.type.dartType,
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
            parameter.type.dartType,
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
        ReturnStatement(_invoke(constructor, null, positional, named)),
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
                  resultType: property.readType!.dartType,
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
              returnType: read ? cls.dartType : objectType,
            ),
          ),
        ],
        types: [read ? cls.dartType : objectType],
      ),
    )..parent = helper.function;
    _lower(helper);
    return helper;
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
        field.dartType,
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
          field.dartType,
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
        (type.dartType as RecordType).withDeclaredNullability(
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
    final recordType = (type.dartType as RecordType).withDeclaredNullability(
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

  Expression _readFunction(
    PositionalParameter env,
    ExportSignature signature,
    Expression source,
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
              ? parameter.type.dartType
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
              ? parameter.type.dartType
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
              : (AsExpression(VariableGet(parameter), model.type.dartType)
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
            returnType: signature.result.dartType,
          ),
        ),
      ],
      types: [signature.result.dartType],
    );
    final wrapper = FunctionExpression(
      FunctionNode(
        ReturnStatement(invocation),
        positionalParameters: positional,
        namedParameters: named,
        requiredParameterCount: signature.type.requiredParameterCount,
        returnType: signature.result.dartType,
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
            returnType: signature.type,
          ),
        ),
      ],
      types: [signature.type],
    );
  }

  bool _needsFunctionAdapter(ExportSignature signature) =>
      signature.positional.any((parameter) => _directional(parameter.type)) ||
      signature.named.any((parameter) => _directional(parameter.type)) ||
      _directional(signature.result);

  bool _directional(ExportType type) => switch (type.kind) {
    ValueKind.object => type.classExport!.isObject,
    ValueKind.future || ValueKind.stream => true,
    ValueKind.list || ValueKind.map => _directional(type.element!),
    ValueKind.record =>
      type.recordFields!.positional.any(_directional) ||
          type.recordFields!.named.values.any(_directional),
    ValueKind.function => _needsFunctionAdapter(type.signature!),
    _ => false,
  };

  Expression _writeFunction(
    PositionalParameter env,
    ExportSignature signature,
    Expression Function() source,
  ) {
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
                Arguments(positional, named: named),
                functionType: signature.type,
              ),
            ),
            positionalParameters: [args],
            returnType: core.objectNullableRawType,
          ),
        ),
      ],
      types: [signature.type],
      named: [
        if (_needsFunctionAdapter(signature))
          NamedExpression('preserveIdentity', BoolLiteral(false)),
      ],
    );
  }

  Expression _valueReader(PositionalParameter env, ExportType element) {
    final args = PositionalParameter(
      cosmeticName: 'arguments',
      type: argumentsType,
    );
    return FunctionExpression(
      FunctionNode(
        ReturnStatement(
          element.kind == ValueKind.voidValue
              ? null
              : _argument(env, args, 0, element),
        ),
        positionalParameters: [args],
        returnType: element.dartType,
      ),
    );
  }

  Expression _elementWriter(PositionalParameter env, ExportType element) {
    final value = PositionalParameter(
      cosmeticName: 'value',
      type: element.dartType,
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

  Expression _invoke(
    ExportFunction function,
    PositionalParameter? receiver,
    List<Expression> positional,
    List<NamedExpression> named,
  ) {
    final args = Arguments(positional, named: named);
    final target = function.target;
    if (target is Constructor) return ConstructorInvocation(target, args);
    if (!function.instance) return StaticInvocation(target as Procedure, args);
    return InstanceInvocation(
      InstanceAccessKind.Instance,
      VariableGet(receiver!),
      target.name,
      args,
      interfaceTarget: target as Procedure,
      functionType: function.signature.type,
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
    return procedure(
      '_napiCall${_next++}',
      [env, if (receiver != null) receiver, args],
      rawResult
          ? function.signature.result.dartType
          : core.objectNullableRawType,
      _callBody(
        env,
        args,
        function.signature,
        preserveDefaults: function.instance,
        rawResult: rawResult,
        invoke: (positional, named) =>
            _invoke(function, receiver, positional, named),
        tearOff: function.instance
            ? () => InstanceTearOff(
                InstanceAccessKind.Instance,
                VariableGet(receiver!),
                function.target.name,
                interfaceTarget: function.target as Procedure,
                resultType: function.signature.type,
              )
            : null,
      ),
    );
  }

  Block _callBody(
    PositionalParameter env,
    PositionalParameter args,
    ExportSignature signature, {
    required bool preserveDefaults,
    required Expression Function(List<Expression>, List<NamedExpression>)
    invoke,
    Expression Function()? tearOff,
    bool rawResult = false,
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
            parameter.type.dartType,
            _argument(env, args, index, parameter.type),
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
        final decoded = _argument(env, args, i, parameter.type);
        Expression value = decoded;
        if (!parameter.required)
          value = ConditionalExpression(
            _present(args, i),
            value,
            _default(parameter),
            parameter.type.dartType,
          );
        positional.add(
          VariableGet(
            local(statements, 'argument$i', parameter.type.dartType, value),
          ),
        );
      }
      final named = <NamedExpression>[];
      final sparse =
          preserveDefaults && signature.named.any((p) => !p.required);
      LocalVariable? sparseArguments;
      if (sparse)
        sparseArguments = local(
          statements,
          'namedArguments',
          InterfaceType(core.mapClass, Nullability.nonNullable, [
            core.symbolNonNullableRawType,
            core.objectNullableRawType,
          ]),
          MapLiteral(
            [],
            keyType: core.symbolNonNullableRawType,
            valueType: core.objectNullableRawType,
          ),
        );
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
          final decoded = _decode(
            env,
            parameter.type,
            (type) => call(
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
              parameter.type.dartType,
              ConditionalExpression(
                present,
                value,
                parameter.required
                    ? failure('Missing named argument: ${parameter.name}')
                    : _default(parameter),
                parameter.type.dartType,
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
            ListLiteral(positional, typeArgument: core.objectNullableRawType),
            VariableGet(sparseArguments!),
          ]),
        );
        if (signature.result.kind != ValueKind.voidValue) {
          invocation = AsExpression(invocation, signature.result.dartType)
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
            type: property.owner.dartType,
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
          resultType: property.readType!.dartType,
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
