import * as api from '@napi/resources-fixture';
import * as direct from '@napi/resources-fixture/BACKEND';
import * as external from '@napi/resources-external';

const resource = new api.ResourceCounter(1, 5);
const view: api.ResourceView = api.resourceView(resource);
const synchronous: number = resource.use();
const named: number = resource.read({amount: 2});
const directOrder: number = api.resourceDirectOrder([1], resource);
const directOrderFuture: Promise<number> = api.resourceDirectOrderFuture([1], resource, 11);
const held: Promise<number> = view.hold(1);
const orphan: Promise<number> = resource.orphan(8);
const close: Promise<void> = resource.release(undefined, resource, [5]);
const closed: Promise<void> = resource.release(8);
const asyncClose: Promise<void> = new api.ResourceAsync(2).close({code: 9, milliseconds: 5, dependency: resource});
const required: Promise<void> = new api.ResourceRequired(3).close({code: null});
const dynamicCleanup: Promise<void> = api.resourceAsyncView(9).close();
const orphanCleanup: Promise<void> = new api.ResourceOrphan(10).close();
const result: Promise<api.ResourceResult> = resource.result();
const nested: Promise<number> = api.resourceHoldEnvelope({owner: view, peers: [view, null]}, 2);
const list: Promise<number> = api.resourceHoldList([view, null], 3);
const map: Promise<number> = api.resourceHoldMap(new Map([['owner', view]]), 4);
const dictionary: Promise<number> = api.resourceHoldDictionary({owner: view, empty: null}, 5);
const record: Promise<number> = api.resourceHoldRecord({$1: view, other: null}, 6);
const subpath: Promise<void> = new direct.ResourceCounter(4).release();
const valueDefaults: api.ResourceDefaultValue = api.resourceDefaultEcho({});
const valueDefaultsUndefined: api.ResourceDefaultValue = api.resourceDefaultEcho({
  owner: undefined, peers: undefined, mapping: undefined, labels: undefined, pair: undefined,
});
const valueDefaultHold: Promise<number> = api.resourceDefaultHold({owner: null}, () => {}, 9);
const defaultOwner: api.ValueDefaultResource | null = valueDefaults.owner;
const defaultPeer: api.ValueDefaultResource | null = valueDefaults.peers[0];
const defaultCleanup: Promise<void> = valueDefaults.pair.$1.close();
const externalDefaults: external.ResourceDefaultValue = external.resourceDefaultEcho({});
external.resourceDefaultHold({owner: null}, () => {}, 10);
direct.resourceDefaultEcho({owner: null});
// @ts-expect-error Non-null resource containers cannot default from null.
api.resourceDefaultEcho({peers: null});
// @ts-expect-error Explicit defaults retain their declared resource brand.
api.resourceDefaultEcho({owner: resource});
// @ts-expect-error Resource defaults inside containers retain their leaf brand.
api.resourceDefaultEcho({mapping: new Map([['one', resource]])});
// @ts-expect-error Required value properties are present in the output shape.
const missingDefaultOwner: undefined = valueDefaults.owner;
// @ts-expect-error synchronous Dart cleanup is still a public Promise<void>.
const eager: void = resource.release();
// @ts-expect-error cleanup outputs have no result payload.
const wrong: Promise<number> = resource.release();
// @ts-expect-error the original Dart cleanup name is renamed.
resource.close();
// @ts-expect-error ordinary classes do not gain a cleanup method.
new api.OrdinaryCounter(1).dispose();
// @ts-expect-error required named presence survives Promise lifting.
new api.ResourceRequired(5).close({});
// @ts-expect-error required nullable values do not accept undefined.
new api.ResourceRequired(6).close({code: undefined});
// @ts-expect-error scalar cleanup parameters remain strict.
resource.release('bad');
// @ts-expect-error resource inputs retain their declared reference brands.
api.resourceHold({}, 7);
void [synchronous, named, directOrder, directOrderFuture, held, orphan, close, closed, asyncClose, required, dynamicCleanup, orphanCleanup, result, nested,
  list, map, dictionary, record, subpath, eager, wrong, valueDefaultsUndefined, valueDefaultHold,
  defaultOwner, defaultPeer, defaultCleanup, externalDefaults, missingDefaultOwner];
