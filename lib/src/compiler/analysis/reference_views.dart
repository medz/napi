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
  final bindings = classes.map((shape) => shape.binding).toList();
  final memberships = {
    for (final shape in classes) shape.classId: shape.memberships,
  };

  ReferenceMemberShape member(ReferenceMemberRef ref) =>
      classes[ref.classId].members[ref.memberIndex];
  bool accepts(ReferenceMemberRef actual, ReferenceMemberRef expected) =>
      referenceMemberAccepts(
        member(actual),
        member(expected),
        bindings,
        memberships,
      ) &&
      referenceMemberDefaultsAccept(member(actual), member(expected));
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

/// Concrete aliases remain invariant handles even when Dart's type arguments
/// overlap. The runtime may compose unrelated interface views, but cannot
/// combine two instantiations of the same original class.
List<List<int>> concreteReferenceGroups(List<ReferenceClassShape> classes) {
  final groups = <DeclarationId, List<int>>{};
  for (final shape in classes) {
    if (shape.binding.instantiatedType != null) {
      groups
          .putIfAbsent(shape.binding.declaration, () => [])
          .add(shape.classId);
    }
  }
  return groups.values.where((group) => group.length > 1).toList();
}
