/// A facade owns its Dart state directly. Only outstanding reads enter the
/// existing Promise registry; idle iterators never enter a strong registry.
const streamFacadePolicy = r'''
class StreamIterator {
  #record;
  constructor(state) {
    this.#record = {state, roots: core['napi:stream:roots'](state)};
  }
  static #read(iterator, closing) {
    const capability = createPromise();
    try {
      const record = iterator.#record;
      retainPromise(capability, record);
      core['napi:stream:read'](capability, record.state, closing);
    } catch (error) { rejectPromise(capability, error); }
    return capability.promise;
  }
  next() { return StreamIterator.#read(this, 0); }
  return() { return StreamIterator.#read(this, 1); }
  [Symbol.asyncIterator]() { return this; }
}
function adoptStream(state, operation = null) {
  let published = false;
  try {
    const iterator = new StreamIterator(state);
    if (operation !== null) {
      // The state now owns the original group, never one lease per read.
      operation.release = null;
      operation.retain = null;
    }
    published = true;
    return iterator;
  } finally { core['napi:stream:finish'](state, published ? 1 : 0); }
}
''';

String streamBoundaryPolicy({required bool references}) =>
    '''
const streamCreate = Object.create;
const streamRangeError = RangeError;
const streamDefineProperty = Object.defineProperty;
export function captureStreamItem(convert, classId, path) {
  const envelope = {threw: false, value: undefined};
  try {
    convert(envelope);
${references ? '    if (classId >= 0 && envelope.value !== null) envelope.value = writeReference(envelope.value, classId, path);\n' : ''}  } catch (value) {
    envelope.threw = true;
    envelope.value = value;
  }
  return envelope;
}
export function writeStreamItem(envelope, value) { envelope.value = value; }
export function streamItemThrew(envelope) { return envelope.threw ? 1 : 0; }
export function releaseStreamItem(envelope) { envelope.value = null; }
export function throwStreamError(envelope) { throw envelope.value; }
export function throwStreamOverflow(message, stack) {
  const error = new streamRangeError(message);
  streamDefineProperty(error, 'dartStack', {value: stack, writable: true, enumerable: true, configurable: true});
  throw error;
}
export function attachStreamDelivery(capability, release, failed) {
  capability.release = release;
  capability.streamFailure = failed;
}
export function resolveStreamResult(capability, envelope, done) {
  // A poisoned Object.prototype.then must not assimilate this outer result.
  try {
    const result = streamCreate(null);
    result.value = done ? undefined : envelope.value;
    result.done = done !== 0;
    capability.resolve(result);
  } catch (value) {
    capability.streamFailure({threw: true, value});
    throw value;
  }
}
''';
