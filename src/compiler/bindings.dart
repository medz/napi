import 'package:kernel/ast.dart';
import 'package:kernel/type_algebra.dart';

import 'calls.dart';
import 'exports.dart';

Procedure generateRegister(
  Component component,
  Library library,
  Library envLibrary,
  ExportModule exports,
) {
  final calls = Calls(component, library, envLibrary);
  final env = PositionalParameter(cosmeticName: 'env', type: calls.envType);
  final target = PositionalParameter(
    cosmeticName: 'exports',
    type: calls.objectType,
  );
  final statements = <Statement>[];
  void define(String name, Expression value) => statements.add(
    ExpressionStatement(
      calls.call(
        VariableGet(target),
        calls.method(calls.objectClass, 'defineValue'),
        [StringLiteral(name), value],
      ),
    ),
  );

  for (final enumeration in exports.enums) {
    final object = calls.local(
      statements,
      enumeration.name,
      calls.objectType,
      calls.call(VariableGet(env), calls.method(calls.envClass, 'object'), []),
    );
    for (final value in enumeration.cases) {
      statements.add(
        ExpressionStatement(
          calls.call(
            VariableGet(object),
            calls.method(calls.objectClass, '_defineValue'),
            [StringLiteral(value.name), IntLiteral(value.index)],
            named: [
              // Node-API napi_enumerable; cases are not writable/configurable.
              NamedExpression('attributes', IntLiteral(2)),
            ],
          ),
        ),
      );
    }
    define(enumeration.name, VariableGet(object));
  }
  for (final cls in exports.classes) {
    final signature = FunctionTypeInstantiator.instantiate(
      calls
          .method(calls.envClass, 'defineClass')
          .function
          .computeFunctionType(Nullability.nonNullable),
      [cls.dartType],
    );
    Expression callbacks(
      String parameter,
      List<MapEntry<String, Procedure>> entries,
    ) {
      final mapType =
          signature.namedParameters.singleWhere((p) => p.name == parameter).type
              as InterfaceType;
      return MapLiteral(
        [
          for (final entry in entries)
            MapLiteralEntry(
              StringLiteral(entry.key),
              calls.bind(entry.value, env),
            ),
        ],
        keyType: mapType.typeArguments[0],
        valueType: mapType.typeArguments[1],
      );
    }

    final Expression constructor;
    if (cls.constructor case final function?) {
      constructor = calls.bind(calls.function(function, rawResult: true), env);
    } else {
      constructor = FunctionExpression(
        FunctionNode(
          ExpressionStatement(
            calls.failure('${cls.name} has no public unnamed constructor.'),
          ),
          positionalParameters: [
            PositionalParameter(
              cosmeticName: 'arguments',
              type: calls.argumentsType,
            ),
          ],
          returnType: cls.dartType,
        ),
      );
    }
    define(
      cls.name,
      calls.call(
        VariableGet(env),
        calls.method(calls.envClass, 'defineClass'),
        [StringLiteral(cls.name)],
        types: [cls.dartType],
        named: [
          NamedExpression('constructor', constructor),
          NamedExpression(
            'methods',
            callbacks('methods', [
              for (final function in cls.methods)
                MapEntry(function.name, calls.function(function)),
            ]),
          ),
          NamedExpression(
            'getters',
            callbacks('getters', [
              for (final property in cls.properties)
                if (property.getter != null)
                  MapEntry(
                    property.name,
                    calls.property(property, setter: false),
                  ),
            ]),
          ),
          NamedExpression(
            'setters',
            callbacks('setters', [
              for (final property in cls.properties)
                if (property.setter != null)
                  MapEntry(
                    property.name,
                    calls.property(property, setter: true),
                  ),
            ]),
          ),
          NamedExpression(
            'staticMethods',
            callbacks('staticMethods', [
              for (final function in cls.staticMethods)
                MapEntry(function.name, calls.function(function)),
            ]),
          ),
          NamedExpression(
            'staticGetters',
            callbacks('staticGetters', [
              for (final property in cls.staticProperties)
                if (property.getter != null)
                  MapEntry(
                    property.name,
                    calls.property(property, setter: false),
                  ),
            ]),
          ),
          NamedExpression(
            'staticSetters',
            callbacks('staticSetters', [
              for (final property in cls.staticProperties)
                if (property.setter != null)
                  MapEntry(
                    property.name,
                    calls.property(property, setter: true),
                  ),
            ]),
          ),
        ],
      ),
    );
  }
  for (final function in exports.functions) {
    define(
      function.name,
      calls.call(VariableGet(env), calls.method(calls.envClass, 'function'), [
        StringLiteral(function.name),
        calls.bind(calls.function(function), env),
      ]),
    );
  }
  return calls.procedure(
    '_napiRegister',
    [env, target],
    const VoidType(),
    Block(statements),
  );
}
