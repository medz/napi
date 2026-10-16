import * as api from './module.wasm';
import {verifyStructures} from './structural_contract.mjs';
verifyStructures(api);
console.log('Generated structural Wasm conformance passed');
