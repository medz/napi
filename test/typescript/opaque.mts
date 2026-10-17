import * as api from '@napi/opaque-fixture';
import * as direct from '@napi/opaque-fixture/BACKEND';
import {plainEcho, PlainStore} from '@napi/opaque-external';

const item = {name: 'payload'};
const same: typeof item = api.identity(item);
const un: undefined = api.identity(undefined);
const nullable: null = api.identity(null);
const directValue: symbol = direct.identity(Symbol('direct'));
const router = new api.Router<string>();
router.set('key', 'value');
router.put({key: 'named', value: 'value'});
const read: string | null = router.get('key');
const sameRouter: api.Router<string> = router.self();
const forwarded: api.Router<string> = api.forwardRouter(router);
const readopted: api.Router<string> = api.readoptRouter<string>();
router.value = 'field';
router.value = null;
const optional: string | null = router.optional();
router.optional('value');
router.optional(null);
const unknown = new api.Router();
unknown.set('anything', undefined);
unknown.set('anything', item);
const nullish = new api.Router<string | null | undefined>();
nullish.put({key: 'undefined', value: undefined});
nullish.put({key: 'null', value: null});
const named: api.Router<string> = api.Router.withValue('initial');
const pair = new api.Pair('first', 42);
const first: string = pair.first;
const second: number = pair.second;
const boundedNull = new api.Bounded<null>(null);
const boundedUndefined = new api.Bounded<undefined>(undefined);
const output: string | null = api.optional<string>();
api.optional<string>('value');
api.optional<string>(null);
api.optional<undefined>(undefined);
api.prefix<string>();
api.prefix<string>('first', undefined);
api.prefix<string>('first', 0, 'last');
api.prefix<string | undefined>(undefined, 0, undefined);
const pending: Promise<number> = api.waitOpaque(item);
const external: typeof item = plainEcho(item);
const store = new PlainStore('value');
const stored: string = store.value;
const array: number[] = api.opaqueArray('payload');
const emptyRecord: Record<PropertyKey, never> = api.opaqueRecord(undefined);
const emptyKey: Record<PropertyKey, never> = api.opaqueKey(null);
const globalResult: Promise<Map<string, number>> = api.opaqueGlobal(Symbol());

const numbers: number[] = new api.Array('payload').numbers();
const empty: Record<PropertyKey, never> = new api.Record().empty();
const futureRouter: Promise<api.Router<string>> = api.futureRouter(router);
void [numbers, empty, futureRouter];

// @ts-expect-error A required opaque argument may be undefined, but cannot be omitted.
api.identity();
// @ts-expect-error Fixed T preserves the declared payload relationship.
api.identity<string>(undefined);
// @ts-expect-error Optional opaque omission does not accept a supplied undefined for string T.
api.optional<string>(undefined);
// @ts-expect-error Class optional opaque inputs use the same presence rule.
router.optional(undefined);
// @ts-expect-error Prefix overloads preserve each supplied opaque argument.
api.prefix<string>(undefined);
// @ts-expect-error The last supplied opaque slot also preserves T.
api.prefix<string>('first', 0, undefined);
// @ts-expect-error A required named payload property cannot be omitted.
router.put({key: 'missing'});
// @ts-expect-error This property contains string T, not undefined, with either exact-optional setting.
router.put({key: 'wrong', value: undefined});
// @ts-expect-error Mutable generic storage cannot be widened unsafely.
const widened: api.Router<string | number> = router;
// @ts-expect-error Narrowing mutable storage is unsafe too.
const narrowed: api.Router<string> = new api.Router<string | number>();
// @ts-expect-error The mutable field also retains logical T.
router.value = 42;
// @ts-expect-error There is no synthesized undefined in the optional field's value type.
router.value = undefined;
// @ts-expect-error The private invariant marker rejects structural impostors.
const fake: api.Router<string> = {};
// @ts-expect-error The original first declaration parameter remains string.
pair.first = 42;
// @ts-expect-error The original second type parameter remains number.
pair.second = 'wrong';
// @ts-expect-error External generic declarations retain the same relationship.
store.value = 42;
// @ts-expect-error An external generic constructor requires its payload.
new PlainStore<string>();
void [same, un, nullable, directValue, read, sameRouter, forwarded, readopted,
  optional, named, first, second, boundedNull, boundedUndefined, output, pending,
  external, stored, array, emptyRecord, emptyKey, globalResult, widened, narrowed, fake];
