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

  late final envClass = envLibrary.classes.singleWhere((c) => c.name == 'Env');
  late final objectClass = envLibrary.classes.singleWhere(
    (c) => c.name == 'JsObject',
  );
  late final argumentsClass = envLibrary.classes.singleWhere(
    (c) => c.name == 'JsArguments',
  );
  late final envType = InterfaceType(envClass, Nullability.nonNullable);
  late final objectType = InterfaceType(objectClass, Nullability.nonNullable);
  late final argumentsType = InterfaceType(
    argumentsClass,
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
    lowering.transformProcedure(
      procedure,
      core,
      hierarchy,
      productMode: true,
      isClosureContextLoweringEnabled: false,
    );
    return procedure;
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

  Expression failure(String message) => Throw(
    ConstructorInvocation(
      core.index
          .getClass('dart:core', 'ArgumentError')
          .constructors
          .singleWhere((c) => c.name.text.isEmpty),
      Arguments([StringLiteral(message)]),
    ),
  );

  Expression _decode(
    PositionalParameter env,
    ExportType type,
    Expression Function(DartType) read,
  ) {
    if (type.kind != ValueKind.object) return read(type.dartType);
    final rawType = type.nullable
        ? objectType.withDeclaredNullability(Nullability.nullable)
        : objectType;
    final raw = SyntheticVariable(
      cosmeticName: 'object${_next++}',
      type: rawType,
      initializer: read(rawType),
      isFinal: true,
    );
    Expression unwrap() => call(
      VariableGet(env),
      method(envClass, 'unwrap'),
      [type.nullable ? NullCheck(VariableGet(raw)) : VariableGet(raw)],
      types: [type.classExport!.dartType],
    );
    return Let(
      raw,
      type.nullable
          ? ConditionalExpression(
              EqualsNull(VariableGet(raw)),
              NullLiteral(),
              unwrap(),
              type.dartType,
            )
          : unwrap(),
    );
  }

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
    } else if (type.kind == ValueKind.object) {
      final result = local(statements, 'result', type.dartType, value);
      Expression wrap() => call(
        VariableGet(env),
        method(envClass, 'wrap'),
        [type.nullable ? NullCheck(VariableGet(result)) : VariableGet(result)],
        types: [type.classExport!.dartType],
      );
      statements.add(
        ReturnStatement(
          type.nullable
              ? ConditionalExpression(
                  EqualsNull(VariableGet(result)),
                  NullLiteral(),
                  wrap(),
                  objectType.withDeclaredNullability(Nullability.nullable),
                )
              : wrap(),
        ),
      );
    } else {
      statements.add(ReturnStatement(value));
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
      functionType: function.signature,
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
    final statements = <Statement>[];
    final required = function.positional.where((p) => p.required).length;

    // Omitted virtual arguments must reach the actual method, whose defaults
    // may differ from the exported interface's defaults.
    if (function.instance && required < function.positional.length) {
      final positional = <LocalVariable>[];
      void decode(int index) {
        final parameter = function.positional[index];
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
      for (var count = required; count <= function.positional.length; ++count) {
        final branch = <Statement>[];
        _return(
          branch,
          env,
          _invoke(function, receiver, [
            for (final parameter in positional) VariableGet(parameter),
          ], []),
          function.result,
        );
        if (count == function.positional.length) {
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
      for (var i = 0; i < function.positional.length; ++i) {
        final parameter = function.positional[i];
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
          function.instance && function.named.any((p) => !p.required);
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
      if (function.named.isNotEmpty) {
        final requiredOptions = function.named.any((p) => p.required);
        final position = function.positional.length;
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
        for (final parameter in function.named) {
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
            InstanceTearOff(
              InstanceAccessKind.Instance,
              VariableGet(receiver!),
              function.target.name,
              interfaceTarget: function.target as Procedure,
              resultType: function.signature,
            ),
            ListLiteral(positional, typeArgument: core.objectNullableRawType),
            VariableGet(sparseArguments!),
          ]),
        );
        if (function.result.kind != ValueKind.voidValue) {
          invocation = AsExpression(invocation, function.result.dartType)
            ..isTypeError = true;
        }
      } else {
        invocation = _invoke(function, receiver, positional, named);
      }
      _return(statements, env, invocation, function.result, raw: rawResult);
    }
    return procedure(
      '_napiCall${_next++}',
      [env, if (receiver != null) receiver, args],
      rawResult ? function.result.dartType : core.objectNullableRawType,
      Block(statements),
    );
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
