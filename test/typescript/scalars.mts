import { add, calls, echo, fail } from './module.wasm';
const result: number = add(1, 2);
const count: number = calls();
echo(result + count);
fail(1);
// @ts-expect-error required argument is missing
add(1);
// @ts-expect-error unsafe implicit coercion is not the API
add('1', 2);
// @ts-expect-error number representation is fixed
add(1n, 2n);
// @ts-expect-error nullable inputs are unsupported
add(null, 2);
// @ts-expect-error explicit undefined is invalid for required scalar
add(undefined, 2);
// @ts-expect-error native function export is not a constructor
new add(1, 2);
