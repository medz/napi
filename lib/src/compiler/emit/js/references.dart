/// Private module with no reverse dependency on the generated class callables.
/// Calls install their lexical brand/adoption closures during module evaluation.
String emitReferences() => r'''// Generated private class reference adapters.
const references = new Map();
export function registerReference(classId, unwrap, wrap) {
  if (references.has(classId)) throw new Error('Duplicate class reference adapter');
  references.set(classId, {unwrap, wrap});
}
function registered(classId, path) {
  const adapter = references.get(classId);
  if (adapter === undefined) throw new Error(path + ': class reference adapter is not registered');
  return adapter;
}
export function readReference(value, classId, nullable, path) {
  return registered(classId, path).unwrap(value, path, nullable);
}
export function writeReference(value, classId, path, pending) {
  if (value === null || typeof value !== 'object') throw new TypeError(path + ': expected a Dart class reference');
  return registered(classId, path).wrap(value, path, pending);
}
''';
