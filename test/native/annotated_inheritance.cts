import addon = require('./addon');

const base: addon.Base = new addon.Base();
const derived: addon.Derived = new addon.Derived();
const leaf: addon.Leaf = new addon.Leaf();
const upcast: addon.Base = leaf;
const middle: addon.Derived = leaf;
const echoed: addon.Base = addon.echoBase(derived);
const same: addon.Base = leaf.same();
const summed: number = leaf.sum();
const extra: number = leaf.extra();
const described: string = leaf.describe({ label: 'custom' });
const aliased: number = derived.readAlias();
const derivedAlias: number = derived.readDerived();
const factory: addon.Base = addon.Base.shared();
const derivedFactory: addon.Derived = addon.Derived.shared();
if (factory instanceof addon.Derived) {
  const result: string = factory.onlyDerived();
}
derived.level = 8;
derived.stored = 6;
const stored: number = derived.stored;
class JavaScriptChild extends addon.Leaf {}
const javascript: addon.Base = new JavaScriptChild(4);
const numeric = new addon.NumDerived();
const numericBase: addon.GenericBase<number> = numeric;
const values: number[] = numeric.copy([1, 2.5]);
const generic: number[] = new addon.GenericBase<number>().copy([1]);
const wide = new addon.WideChild();
wide.accept('child contract');
const numericParent: addon.NumericParent<number> = wide;
numericParent.accept(1.5);

// @ts-expect-error A base instance lacks derived behavior and identity.
addon.echoDerived(base);
// @ts-expect-error Wrapped classes retain nominal identity through inheritance.
addon.echoBase({ value: 1, sum: () => 2 });
// @ts-expect-error Inherited optional parameters retain exact presence.
leaf.sum(undefined);
// @ts-expect-error Inherited named parameters retain their types.
leaf.describe({ times: '4' });
// @ts-expect-error Renamed inherited methods expose only their JavaScript alias.
derived.aliased();
// @ts-expect-error The concrete generic superclass argument is rebound to number.
numeric.copy(['wrong']);
// @ts-expect-error Concrete numeric generic arguments exclude null.
numeric.copy([null]);
// @ts-expect-error The parent view preserves its numeric parameter contract.
numericParent.accept('wrong');
