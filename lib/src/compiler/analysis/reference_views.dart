import '../ir/model.dart';
import 'validate.dart';

/// A total selected hierarchy has exactly one class at every membership depth.
bool hasCompositeReferenceViews(List<ReferenceClassShape> classes) =>
    classes.map((shape) => shape.memberships.length).toSet().length <
    classes.length;

/// Equivalent operation contracts share an ID. Coverage only records distinct
/// contracts of the same JS property, Dart member and callable kind.
final class ReferenceViewContracts {
  final Map<ReferenceMemberRef, int> ids;
  final List<Set<int>> accepts;
  ReferenceViewContracts._(this.ids, this.accepts);
}

ReferenceViewContracts referenceViewContracts(
  List<ReferenceClassShape> classes,
) {
  final declarations = {
    for (final shape in classes) shape.binding.declaration: shape.classId,
  };
  final memberships = {
    for (final shape in classes) shape.classId: shape.memberships,
  };
  ReferenceMemberShape member(ReferenceMemberRef ref) =>
      classes[ref.classId].members[ref.memberIndex];
  bool accepts(ReferenceMemberRef actual, ReferenceMemberRef expected) =>
      referenceMemberAccepts(
        member(actual),
        member(expected),
        declarations,
        memberships,
      ) &&
      _defaultsAccept(member(actual), member(expected));
  final groups = <(String, String, String, ReferenceMemberKind), List<int>>{};
  final representatives = <ReferenceMemberRef>[];
  final ids = <ReferenceMemberRef, int>{};
  // Only descriptor references are needed. Inherited surfaces remain deltas;
  // neither whole effective surfaces nor possible view combinations are copied.
  for (final shape in classes) {
    for (final property in shape.prototypeProperties) {
      for (final ref in [property.method, property.getter, property.setter]) {
        if (ref == null || ids.containsKey(ref)) continue;
        final operation = member(ref);
        final group = groups.putIfAbsent((
          property.name,
          operation.binding.declaration.name,
          operation.binding.callPath ?? operation.binding.declaration.name,
          operation.kind,
        ), () => []);
        int? equivalent;
        for (final id in group) {
          if (accepts(ref, representatives[id]) &&
              accepts(representatives[id], ref)) {
            equivalent = id;
            break;
          }
        }
        if (equivalent == null) {
          equivalent = representatives.length;
          representatives.add(ref);
          group.add(equivalent);
        }
        ids[ref] = equivalent;
      }
    }
  }
  final coverage = [for (final _ in representatives) <int>{}];
  for (final group in groups.values) {
    for (final actual in group) {
      for (final expected in group) {
        if (actual != expected &&
            accepts(representatives[actual], representatives[expected])) {
          coverage[actual].add(expected);
        }
      }
    }
  }
  return ReferenceViewContracts._(
    Map.unmodifiable(ids),
    List.unmodifiable(coverage.map(Set<int>.unmodifiable)),
  );
}

bool _positional(ParameterBinding parameter) =>
    parameter.kind == ParameterKind.requiredPositional ||
    parameter.kind == ParameterKind.optionalPositional;

bool _defaultsAccept(
  ReferenceMemberShape actual,
  ReferenceMemberShape expected,
) {
  final positional = actual.parameters.where(_positional).toList();
  final named = {
    for (final p in actual.parameters.where((p) => !_positional(p))) p.name: p,
  };
  var position = 0;
  for (final previous in expected.parameters) {
    final parameter = _positional(previous)
        ? positional[position++]
        : named[previous.name]!;
    // Required contracts prescribe no result for omission. If both accept it,
    // the chosen callback must supply the same Dart value, also for undefined.
    if (previous.presence == ParameterPresence.optional &&
        !_sameDefault(parameter, previous)) {
      return false;
    }
  }
  return true;
}

Object? _default(ParameterBinding parameter) {
  final value = parameter.defaultValue?.value;
  if (value is int) {
    if (parameter.type case DeclaredType(:final declaration)
        when declaration.library == Uri.parse('dart:core') &&
            declaration.name == 'double') {
      return value.toDouble();
    }
  }
  return value;
}

bool _sameDefault(ParameterBinding left, ParameterBinding right) {
  final a = _default(left);
  final b = _default(right);
  if (a is double && b is double) {
    if (a.isNaN && b.isNaN) return true;
    if (a == 0 && b == 0) return a.isNegative == b.isNegative;
  }
  return a.runtimeType == b.runtimeType && a == b;
}
