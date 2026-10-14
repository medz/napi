// Private bridge envelope. No envelope appears in the public generated API.
export function unwrap(result) {
  if (result.ok) return result.value;
  const detail = result.error;
  const ErrorType = detail.kind === 'range' ? RangeError
    : detail.kind === 'type' ? TypeError : Error;
  const error = new ErrorType(detail.message);
  Object.defineProperties(error, {
    dartType: { value: detail.dartType, enumerable: false },
    dartStack: { value: detail.dartStack, enumerable: false },
  });
  throw error;
}
