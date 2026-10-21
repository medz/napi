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

const functionFactories = new Map();
const functionWrappers = new WeakMap();
const functionOwners = new WeakMap();
const callbackSources = new WeakMap();
const functionApply = Reflect.apply;
const functionMap = Map;
const functionMapGet = Map.prototype.get, functionMapSet = Map.prototype.set;
const functionMapDelete = Map.prototype.delete;
const functionWeakGet = WeakMap.prototype.get, functionWeakSet = WeakMap.prototype.set;
const functionWeakRef = WeakRef, functionDeref = WeakRef.prototype.deref;
export function registerFunction(contractId, signature, wireSignature, factory) {
  if (functionFactories.has(contractId)) throw new Error('Duplicate function contract');
  functionFactories.set(contractId, {signature, wireSignature, factory});
}
export function registerCallbackSource(adapter, signature, wireSignature, callback) {
  functionApply(functionWeakSet, callbackSources, [adapter, {signature, wireSignature, callback}]);
}
export function unwrapFunction(value, signature) {
  const owner = functionApply(functionWeakGet, functionOwners, [value]);
  return owner !== undefined && owner.signature === signature ? owner.reference : null;
}
export function writeFunction(reference, contractId, path, pending) {
  const contract = functionApply(functionMapGet, functionFactories, [contractId]);
  if (contract === undefined) throw new Error(path + ': function contract is not registered');
  const source = functionApply(functionWeakGet, callbackSources, [reference]);
  if (source !== undefined && source.signature === contract.signature &&
      source.wireSignature === contract.wireSignature) return source.callback;
  let entries = functionApply(functionWeakGet, functionWrappers, [reference]);
  const previous = entries === undefined ? undefined : functionApply(functionMapGet, entries, [contract.signature]);
  const live = previous === undefined ? undefined : functionApply(functionDeref, previous, []);
  if (live !== undefined) return live;
  const facade = contract.factory(reference);
  if (entries === undefined) {
    entries = new functionMap();
    functionApply(functionWeakSet, functionWrappers, [reference, entries]);
  }
  const entry = new functionWeakRef(facade);
  functionApply(functionMapSet, entries, [contract.signature, entry]);
  functionApply(functionWeakSet, functionOwners, [facade, {reference, signature: contract.signature}]);
  if (pending !== undefined) pending.add(() => {
    if (functionApply(functionMapGet, entries, [contract.signature]) === entry) functionApply(functionMapDelete, entries, [contract.signature]);
  });
  return facade;
}
''';
