import 'package:kernel/ast.dart';
import 'package:kernel/clone.dart';
import 'package:kernel/core_types.dart';
import 'package:kernel/type_algebra.dart';

import 'exports.dart';

Procedure generateRegister(
  Component component,
  Library library,
  Library envLibrary,
  List<ExportFunction> exports,
) => _Bindings(component, library, envLibrary).generate(exports);

final class _Bindings {
  _Bindings(Component component, this.library, this.envLibrary)
    : core = CoreTypes(component);

  final Library library;
  final Library envLibrary;
  final CoreTypes core;

  late final envClass = _class('Env');
  late final objectClass = _class('JsObject');
  late final argumentsClass = _class('JsArguments');
  late final objectType = InterfaceType(objectClass, Nullability.nonNullable);
  late final argumentsType = InterfaceType(
    argumentsClass,
    Nullability.nonNullable,
  );
  late final argumentGet = _method(argumentsClass, 'get');
  late final argumentLength = _method(argumentsClass, 'length');
  late final propertyGet = _method(objectClass, 'get');
  late final hasOwn = _method(objectClass, 'hasOwn');
  late final greaterThan = _method(core.numClass, '>');

  Class _class(String name) =>
      envLibrary.classes.singleWhere((value) => value.name == name);

  Procedure _method(Class cls, String name) =>
      cls.procedures.singleWhere((value) => value.name.text == name);

  Procedure _procedure(
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
    return procedure;
  }

  Expression _call(
    Expression receiver,
    Procedure method,
    List<Expression> arguments, {
    List<DartType> types = const [],
  }) {
    final signature = FunctionTypeInstantiator.instantiate(
      method.function.computeFunctionType(Nullability.nonNullable),
      types,
    );
    return InstanceInvocation(
      InstanceAccessKind.Instance,
      receiver,
      method.name,
      Arguments(arguments, types: types),
      interfaceTarget: method,
      functionType: signature,
    );
  }

  Expression _present(PositionalParameter arguments, int index) => _call(
    InstanceGet(
      InstanceAccessKind.Instance,
      VariableGet(arguments),
      argumentLength.name,
      interfaceTarget: argumentLength,
      resultType: core.intNonNullableRawType,
    ),
    greaterThan,
    [IntLiteral(index)],
  );

  Expression _argument(
    PositionalParameter arguments,
    int index,
    DartType type,
  ) => _call(
    VariableGet(arguments),
    argumentGet,
    [IntLiteral(index)],
    types: [type],
  );

  Expression _default(ExportParameter parameter) =>
      parameter.defaultValue == null
      ? NullLiteral()
      : CloneVisitorNotMembers().clone(parameter.defaultValue!);

  LocalVariable _local(
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

  Expression _missing(String name) => Throw(
    ConstructorInvocation(
      core.index
          .getClass('dart:core', 'ArgumentError')
          .constructors
          .singleWhere((value) => value.name.text.isEmpty),
      Arguments([StringLiteral('Missing named argument: $name')]),
    ),
  );

  Procedure _bridge(ExportFunction function, int index) {
    final args = PositionalParameter(
      cosmeticName: 'arguments',
      type: argumentsType,
    );
    final statements = <Statement>[];
    final positional = <Expression>[];
    for (var i = 0; i < function.positional.length; ++i) {
      final parameter = function.positional[i];
      final value = _argument(args, i, parameter.type.dartType);
      final local = _local(
        statements,
        'argument$i',
        parameter.type.dartType,
        parameter.required
            ? value
            : ConditionalExpression(
                _present(args, i),
                value,
                _default(parameter),
                parameter.type.dartType,
              ),
      );
      positional.add(VariableGet(local));
    }
    final named = <NamedExpression>[];
    if (function.named.isNotEmpty) {
      final requiredOptions = function.named.any(
        (parameter) => parameter.required,
      );
      final position = function.positional.length;
      final options = LocalVariable(
        name: 'options',
        type: requiredOptions
            ? objectType
            : objectType.withDeclaredNullability(Nullability.nullable),
        isFinal: true,
        initializer: requiredOptions
            ? _argument(args, position, objectType)
            : ConditionalExpression(
                _present(args, position),
                _argument(args, position, objectType),
                NullLiteral(),
                objectType.withDeclaredNullability(Nullability.nullable),
              ),
      );
      statements.add(VariableStatement(VariableDeclaration(options)));
      Expression receiver() => requiredOptions
          ? VariableGet(options)
          : NullCheck(VariableGet(options));
      for (final parameter in function.named) {
        Expression present = _call(receiver(), hasOwn, [
          StringLiteral(parameter.name),
        ]);
        if (!requiredOptions) {
          present = LogicalExpression(
            Not(EqualsNull(VariableGet(options))),
            LogicalExpressionOperator.AND,
            present,
          );
        }
        final value = _call(
          receiver(),
          propertyGet,
          [StringLiteral(parameter.name)],
          types: [parameter.type.dartType],
        );
        final local = _local(
          statements,
          parameter.name,
          parameter.type.dartType,
          ConditionalExpression(
            present,
            value,
            parameter.required ? _missing(parameter.name) : _default(parameter),
            parameter.type.dartType,
          ),
        );
        named.add(NamedExpression(parameter.name, VariableGet(local)));
      }
    }
    final call = StaticInvocation(
      function.target,
      Arguments(positional, named: named),
    );
    if (function.result.kind == ScalarKind.voidValue) {
      statements.add(ExpressionStatement(call));
      final undefined = envLibrary.fields.singleWhere(
        (value) => value.name.text == 'undefined',
      );
      statements.add(
        ReturnStatement(CloneVisitorNotMembers().clone(undefined.initializer!)),
      );
    } else {
      statements.add(ReturnStatement(call));
    }
    return _procedure(
      '_napiFunction$index',
      [args],
      core.objectNullableRawType,
      Block(statements),
    );
  }

  Procedure generate(List<ExportFunction> exports) {
    final env = PositionalParameter(
      cosmeticName: 'env',
      type: InterfaceType(envClass, Nullability.nonNullable),
    );
    final target = PositionalParameter(
      cosmeticName: 'exports',
      type: objectType,
    );
    final createFunction = _method(envClass, 'function');
    final defineValue = _method(objectClass, 'defineValue');
    final statements = <Statement>[];
    for (var index = 0; index < exports.length; ++index) {
      final function = exports[index];
      final bridge = _bridge(function, index);
      statements.add(
        ExpressionStatement(
          _call(VariableGet(target), defineValue, [
            StringLiteral(function.name),
            _call(VariableGet(env), createFunction, [
              StringLiteral(function.name),
              ConstantExpression(
                StaticTearOffConstant(bridge),
                bridge.function.computeFunctionType(Nullability.nonNullable),
              ),
            ]),
          ]),
        ),
      );
    }
    return _procedure(
      '_napiRegister',
      [env, target],
      const VoidType(),
      Block(statements),
    );
  }
}
