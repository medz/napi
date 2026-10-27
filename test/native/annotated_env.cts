import addon = require('./addon');

const object: object = addon.makeObject(3);
const session: addon.Session = new addon.Session('normal');
const explicit: addon.Session = new addon.Session('explicit', 5);
const owner: boolean = session.sameOwner();
const computed: number = session.compute(1);
const sparse: number = addon.derivedSession().compute(1, { b: 9 });
const created: object = addon.Session.create(7);
const asynchronous: Promise<object> = addon.asyncObject();
const stamp: addon.Stamp = addon.echoStamp({ value: 3 });

// @ts-expect-error The environment is injected rather than passed by JavaScript.
addon.makeObject({}, 3);
// @ts-expect-error An injected positional parameter does not occupy a JavaScript slot.
new addon.Session('normal', {}, 5);
// @ts-expect-error An injected named parameter is absent from the options type.
session.compute(1, { env: {} });
// @ts-expect-error Optional Dart integer parameters do not accept explicit undefined.
session.compute(1, { a: undefined });
// @ts-expect-error Structural input does not require or expose its constructor environment.
addon.echoStamp({ value: 3, env: {} });
// @ts-expect-error Structural classes have no JavaScript constructor.
new addon.Stamp({ value: 3 });
