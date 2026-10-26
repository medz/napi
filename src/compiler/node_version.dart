import 'package:pub_semver/pub_semver.dart';

// Function wrappers use finalizers, which require Node-API 5.
const minimumNodeApi = 5;

// https://nodejs.org/api/n-api.html#node-api-version-matrix
const _nodeVersions = {
  4: '>=10.16.0 <11.0.0 || >=11.8.0',
  5: '>=10.17.0 <11.0.0 || >=12.11.0',
  6: '>=10.20.0 <11.0.0 || >=12.17.0 <13.0.0 || >=14.0.0',
  7: '>=10.23.0 <11.0.0 || >=12.19.0 <13.0.0 || >=14.12.0',
  8: '>=12.22.0 <13.0.0 || >=14.17.0 <15.0.0 || >=15.12.0',
  9: '>=18.17.0 <19.0.0 || >=20.3.0',
  10: '>=22.14.0 <23.0.0 || >=23.6.0',
};

VersionConstraint _constraint(String value) {
  if (value.trim().isEmpty) {
    throw const FormatException(
      'The Node.js version constraint must not be empty.',
    );
  }
  return VersionConstraint.unionOf(
    value.split('||').map((part) {
      final text = part.trim();
      final parsed = VersionConstraint.parse(text);
      if (!text.contains('+')) return parsed;
      return VersionConstraint.parse(
        text.replaceAll(RegExp(r'\+[0-9A-Za-z.-]+'), ''),
      );
    }),
  );
}

Iterable<VersionRange> nodeRanges(VersionConstraint constraint) =>
    constraint is VersionUnion
    ? constraint.ranges
    : [constraint as VersionRange];

String nodeConstraintText(VersionConstraint constraint) =>
    nodeRanges(constraint).join(' || ');

({int napi, VersionConstraint nodes}) nodeRequirements(
  Iterable<Map<String, Object?>> uses,
  String? target,
) {
  var napi = minimumNodeApi;
  var nodes = _constraint(_nodeVersions[napi]!);
  for (final use in uses) {
    final apiVersion = use['napi'] as int?;
    if (apiVersion != null && apiVersion > napi) {
      final supported = _nodeVersions[apiVersion];
      if (supported == null) {
        throw FormatException('Unsupported Node-API version: $apiVersion');
      }
      napi = apiVersion;
      nodes = nodes.intersect(_constraint(supported));
    }
    if (use['node'] case final String constraint) {
      nodes = nodes.intersect(_constraint(constraint));
    }
    if (nodes.isEmpty) {
      throw FormatException(
        'The Node.js requirements are incompatible at ${use['api']}.',
      );
    }
  }
  if (target != null) {
    final requested = _constraint(target);
    if (requested.isEmpty || !nodes.allowsAll(requested)) {
      throw FormatException(
        'Node.js "$target" includes versions unsupported by this addon. '
        'Its APIs require ${nodeConstraintText(nodes)}.',
      );
    }
  }
  return (napi: napi, nodes: nodes);
}
