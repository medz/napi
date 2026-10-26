import binding, { Counter } from '@fixture/counter';
import cjs = require('@fixture/counter');

const fromRequire: Counter = new cjs.Counter();
const fromImport: cjs.Counter = new Counter(5);
const fromDefault: Counter = new binding.Counter();
const value: number = fromRequire.increment(2);
const same: Counter = fromImport.same();
