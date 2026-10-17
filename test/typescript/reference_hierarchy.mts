import {HierarchyBase as Base, HierarchyChild as Child, HierarchyView as View,
  HierarchyGetter, HierarchySetter, HierarchyReadonly, HierarchyWritable,
  HierarchyFactory, HierarchyFactoryChild, echoHierarchyBase, echoHierarchyView,
  hierarchyEnvelope} from '@napi/class-fixture';

const child = new Child(1);
const base: Base = child;
const view: View = child;
const identity: Base = echoHierarchyBase(child);
const projected: View = echoHierarchyView(child);
const number: number = child.defaults(undefined, 9);
const inherited: number = child.named({amount: undefined});
const self: Base = child.self();
const named: Base = Base.child(3);
const envelope: {base: Base; view: View} = hierarchyEnvelope({base: child, view: child});
const getter = new HierarchyGetter(2);
getter.value = 3;
const getterResult: number = getter.value;
const setter = new HierarchySetter(2);
setter.value = 3;
const setterResult: number = setter.value;
const writable = new HierarchyWritable();
writable.value = 3;
const readonly: HierarchyReadonly = writable;
const read: number = writable.value;
const factory: HierarchyFactory = new HierarchyFactoryChild();
void [base, view, identity, projected, number, inherited, self, named, envelope,
  getterResult, setterResult, readonly, read, factory];
// @ts-expect-error static methods do not inherit
Child.baseOnly();
// @ts-expect-error named constructors do not inherit
Child.child();
// @ts-expect-error readonly base remains readonly
new HierarchyReadonly().value = 3;
// @ts-expect-error abstract interface cannot be constructed
new View();
// @ts-expect-error base lacks the child-specific interface method
const invalidView: View = new Base();
// @ts-expect-error required interface reference rejects absent values
echoHierarchyView(undefined);
