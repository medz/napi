import 'dart:convert';

import '../../analysis/reference_views.dart';
import '../../analysis/validate.dart';

/// Shared, lazy prototype composition. This cache contains declaration metadata
/// and callbacks only; business wrappers and their lifetime belong to a backend.
String emitCompositeReferencePrototypes(
  List<ReferenceClassShape> classes,
  String Function(ReferenceMemberRef) member,
) {
  final contracts = referenceViewContracts(classes);
  final concreteGroups = concreteReferenceGroups(classes);
  String operation(ReferenceMemberRef? ref) =>
      ref == null ? 'null' : '[${contracts.ids[ref]}, ${member(ref)}]';
  final code = StringBuffer();
  code.writeln(
    'const \$napiViewMemberships = ${jsonEncode(classes.map((shape) => shape.memberships.toList()).toList())};',
  );
  code.writeln(
    'const \$napiViewParents = ${jsonEncode(classes.map((shape) => shape.superclassId).toList())};',
  );
  code.writeln('const \$napiViewProperties = [');
  for (final shape in classes) {
    code.writeln('  [');
    for (final property in shape.prototypeProperties) {
      final ref = property.method ?? property.getter ?? property.setter!;
      final binding = classes[ref.classId].members[ref.memberIndex].binding;
      final dartName = binding.declaration.name;
      final target = '$dartName:${binding.callPath ?? dartName}';
      code.writeln(
        '    [${jsonEncode(property.name)}, ${jsonEncode(target)}, '
        '${operation(property.method)}, ${operation(property.getter)}, '
        '${operation(property.setter)}],',
      );
    }
    code.writeln('  ],');
  }
  code.writeln('];');
  code.writeln(
    'const \$napiViewAccepts = [${contracts.accepts.map((ids) => ids.isEmpty ? 'null' : 'new Set(${jsonEncode(ids.toList())})').join(', ')}];',
  );
  if (concreteGroups.isNotEmpty) {
    code.writeln('const \$napiConcreteGroups = ${jsonEncode(concreteGroups)};');
  }
  code.write(r'''const $napiCompositePrototypes = new Map();
function $napiCompositePrototype(viewIds, context) {
''');
  if (concreteGroups.isNotEmpty) {
    code.write(r'''  for (const group of $napiConcreteGroups) {
    let matched = false;
    for (const id of group) {
      if (viewIds.includes(id)) {
        if (matched) throw new TypeError(context + ': ambiguous concrete type arguments');
        matched = true;
      }
    }
  }
''');
  }
  code.write(r'''  const maximal = new Set(viewIds);
  for (const id of viewIds) {
    for (const ancestor of $napiViewMemberships[id]) {
      if (ancestor !== id) maximal.delete(ancestor);
    }
  }
  const views = Array.from(maximal).sort((a, b) => a - b);
  const key = views.join(',');
  const previous = $napiCompositePrototypes.get(key);
  if (previous !== undefined) return previous;
  const properties = new Map();
  const conflict = name => {
    throw new TypeError(context + ': conflicting reference views for ' + name);
  };
  for (const view of views) {
    const seen = new Set();
    for (let id = view; id !== null; id = $napiViewParents[id]) {
      for (const property of $napiViewProperties[id]) {
        const [name, dartName, method] = property;
        if (seen.has(name)) continue;
        seen.add(name);
        let combined = properties.get(name);
        if (combined === undefined) {
          combined = {dartName, method: method !== null,
            operations: [new Map(), new Map(), new Map()]};
          properties.set(name, combined);
        } else if (combined.dartName !== dartName || combined.method !== (method !== null)) {
          conflict(name);
        }
        for (let kind = 0; kind < 3; kind++) {
          const operation = property[kind + 2];
          if (operation !== null && !combined.operations[kind].has(operation[0])) {
            combined.operations[kind].set(operation[0], operation[1]);
          }
        }
      }
    }
  }
  const prototype = Object.create(Object.prototype);
  for (const [name, property] of properties) {
    const select = operations => {
      if (operations.size === 0) return undefined;
      for (const [candidate, callback] of operations) {
        const accepts = $napiViewAccepts[candidate];
        let compatible = true;
        for (const contract of operations.keys()) {
          if (candidate !== contract && (accepts === null || !accepts.has(contract))) {
            compatible = false;
            break;
          }
        }
        if (compatible) return callback;
      }
      conflict(name);
    };
    const descriptor = property.method
      ? {value: select(property.operations[0]), writable: true}
      : {get: select(property.operations[1]), set: select(property.operations[2])};
    Object.defineProperty(prototype, name, {...descriptor, enumerable: false, configurable: true});
  }
  $napiCompositePrototypes.set(key, prototype);
  return prototype;
}
''');
  return code.toString();
}
