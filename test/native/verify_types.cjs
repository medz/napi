'use strict';

const { copyFileSync, readFileSync, writeFileSync } = require('node:fs');
const { join, resolve } = require('node:path');
const { spawnSync } = require('node:child_process');

function verify(consumers, isolated = false) {
  const result = spawnSync(process.execPath, [
    require.resolve('typescript/bin/tsc'),
    '--strict', '--exactOptionalPropertyTypes', '--noEmit',
    '--module', 'NodeNext', '--target', 'ES2020',
    ...(isolated ? ['--isolatedModules'] : []), ...consumers,
  ], { stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) process.exit(result.status ?? 1);
}

for (const [target, fixture] of [
  ['annotated', 'annotated_functions.cts'],
  ['classes', 'annotated_classes.cts'],
  ['collections', 'annotated_collections.cts'],
  ['callbacks', 'annotated_callbacks.cts'],
  ['futures', 'annotated_futures.cts'],
  ['streams', 'annotated_streams.cts'],
  ['records', 'annotated_records.cts'],
  ['enums', 'annotated_enums.cts'],
  ['constants', 'annotated_constants.cts'],
  ['references', 'annotated_js_references.cts'],
  ['objects', 'annotated_objects.cts'],
  ['properties', 'annotated_properties.cts'],
  ['generics', 'annotated_generics.cts'],
  ['dates', 'annotated_dates.cts'],
  ['binary-views', 'annotated_binary_views.cts'],
  ['simd', 'annotated_simd.cts'],
  ['sets', 'annotated_sets.cts'],
  ['env', 'annotated_env.cts'],
  ['inheritance', 'annotated_inheritance.cts'],
  ['generic-objects', 'annotated_generic_objects.cts'],
  ['generic-callbacks', 'annotated_generic_callbacks.cts'],
]) {
  const consumer = resolve(process.argv[2], target, 'consumer.cts');
  copyFileSync(join(__dirname, fixture), consumer);
  verify([consumer], target === 'enums');
}

const propertiesCjs = resolve(process.argv[2], 'properties-cts', 'consumer.cts');
writeFileSync(propertiesCjs,
  readFileSync(join(__dirname, 'annotated_properties.cts'), 'utf8')
    .replace("require('./addon')", "require('./addon.cjs')"));
verify([propertiesCjs], true);
const genericPackage = resolve(process.argv[2], 'generics', 'package-consumer.mts');
writeFileSync(genericPackage, `import api, { Box, echoBox, identity, amountBox } from '../generics-package/index.mjs';
import type { Amount } from '../generics-package/index.mjs';
const value: Box<number> = new Box<number>(42);
const fromDefault: Box<number> = new api.Box<number>(7);
api.box = value;
const same: Box<number> = echoBox(fromDefault);
const text: string = identity<string>('hello');
const nativeAmount: Box<Amount> = amountBox();
nativeAmount.value = {value: '42'};
const jsAmount = new api.Box(nativeAmount.value);
jsAmount.value = nativeAmount.value;
// @ts-expect-error ESM aliases preserve the native/opaque input distinction.
const wrongAmount: Box<Amount> = jsAmount;
// @ts-expect-error Generic class aliases retain their type parameter.
value.value = '42';
`);
verify([genericPackage], true);
const inheritancePackage = resolve(process.argv[2], 'inheritance', 'package-consumer.mts');
writeFileSync(inheritancePackage, `import api, { Base, Derived, Leaf, GenericBase, NumDerived, echoBase } from '../inheritance-package/index.mjs';
const leaf: Base = new Leaf();
const derived: Derived = new api.Derived();
const sameBrand: Base = echoBase(new api.Leaf());
const factory: Derived = Derived.shared();
const numeric: GenericBase<number> = new NumDerived();
const values: number[] = numeric.copy([1, 2.5]);
// @ts-expect-error A base instance does not acquire derived members.
const invalid: Derived = new Base();
`);
verify([inheritancePackage], true);
for (const [directory, specifier] of [
  ['properties-mts', './addon.mjs'],
  ['properties-package', '../properties-package/index.mjs'],
  ['properties-assembled', '../properties-assembled/index.mjs'],
]) {
  const consumer = resolve(process.argv[2], directory === 'properties-mts' ? directory : 'properties', `${directory}.mts`);
  writeFileSync(consumer, `import api, { Token, echoToken, twice, fixed } from '${specifier}';
import type { Point } from '${specifier}';
const token: Token = api.token;
const same: Token = echoToken(token);
api.token = new Token(7);
api.count = 3;
const count: number = api.count;
const point: Point = api.point;
api.point = { value: '7' };
const value: number = twice(3);
const constant: string = fixed;
// @ts-expect-error Live properties are only available on the default export.
import { count as namedCount } from '${specifier}';
// @ts-expect-error Final default-export properties remain readonly.
api.lazyFinal = 7;
`);
  verify([consumer], true);
}

for (const directory of ['objects-package', 'objects-assembled']) {
  const common = resolve(process.argv[2], 'objects', `${directory}.cts`);
  const module = resolve(process.argv[2], 'objects', `${directory}.mts`);
  writeFileSync(common, `import binding = require('../${directory}/index.cjs');
const child = new binding.PointInput(5);
const point: binding.Point = binding.echoPoint({ value: '7', child });
const readout: binding.Readout = binding.readout();
// @ts-expect-error Structural types have no constructor value.
new binding.Point();
`);
  writeFileSync(module, `import type { Point, Readout } from '../${directory}/index.mjs';
import { echoPoint, PointInput, readout } from '../${directory}/index.mjs';
const point: Point = echoPoint({ value: '7', child: new PointInput(5) });
const result: Readout = readout();
// @ts-expect-error Asymmetric output fields do not widen constructor input types.
echoPoint({ value: 7 });
`);
  verify([common, module], true);
}

for (const directory of ['constants-package', 'constants-assembled']) {
  const common = resolve(process.argv[2], 'constants', `${directory}.cts`);
  const module = resolve(process.argv[2], 'constants', `${directory}.mts`);
  writeFileSync(common, `import binding = require('../${directory}/index.cjs');
const point: binding.Point = binding.point;
const absent: null = binding.absent;
const sum: number = binding.add(3);
// @ts-expect-error Module bindings are const in package declarations.
binding.point = new binding.Point(1);
`);
  writeFileSync(module, `import { Point, point, absent, add } from '../${directory}/index.mjs';
const value: Point = point;
const empty: null = absent;
const sum: number = add(3);
// @ts-expect-error ESM re-exports retain the function constant's signature.
add('3');
`);
  verify([common, module], true);
}

for (const directory of ['enums-package', 'enums-assembled']) {
  const common = resolve(process.argv[2], 'enums', `${directory}.cts`);
  const module = resolve(process.argv[2], 'enums', `${directory}.mts`);
  writeFileSync(common, `import binding = require('../${directory}/index.cjs');
const ready: binding.Status = binding.Status.ready;
const done: binding.Status = binding.toggle(ready);
// @ts-expect-error Enum values remain a numeric union in package declarations.
const invalid: binding.Status = 2;
`);
  writeFileSync(module, `import { Status, toggle } from '../${directory}/index.mjs';
const ready: Status = Status.ready;
const done: Status = toggle(ready);
// @ts-expect-error ESM re-exports retain the enum type and value.
const invalid: Status = 2;
`);
  verify([common, module], true);
}
