import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

assert.ok(process.argv[2], 'Pass the TypeScript bin/tsc path.');
const apiPath = resolve(dirname(resolve(process.argv[2])), '../dist/api/sync/api.js');
const { API, SymbolFlags, SignatureKind } = await import(pathToFileURL(apiPath).href);
const expected = {
  summarize: 'Counts requests per exact operation name in UTF-16 code-unit order.\n' +
    "Durations and each operation's total must fit a nonnegative safe JS integer.",
  Observation: 'One request observation with duration measured in microseconds.\n' +
    'durationUs must be a nonnegative JavaScript safe integer.',
  Summary: 'Counts and total microsecond duration for one exact operation name.\n' +
    'totalDurationUs remains within the JavaScript safe integer range.',
};
const cases = [
  ['requests-consumer.ts', 'api.summarize(', 4, 'index.d.ts', 'summarize'],
  ['requests-consumer.ts', 'subpath(', 1, 'index.d.ts', 'summarize'],
  ['consumer.mts', 'summarize(', 1, 'module.d.wasm.ts', 'summarize'],
  ['requests-consumer.ts', 'Observation, Summary', 0, 'index.d.ts', 'Observation'],
  ['requests-consumer.ts', "Summary } from '@napi/requests'", 0, 'index.d.ts', 'Summary'],
  ['requests-consumer.ts', 'SubpathObservation, Summary', 0, 'index.d.ts', 'Observation'],
  ['requests-consumer.ts', 'SubpathSummary }', 0, 'index.d.ts', 'Summary'],
  ['consumer.mts', 'Observation, Summary', 0, 'module.d.wasm.ts', 'Observation'],
  ['consumer.mts', 'Summary } from', 0, 'module.d.wasm.ts', 'Summary'],
];
const temporary = mkdtempSync(join(tmpdir(), 'napi-documentation-'));
let api;
let checks = 0;
let functionChecks = 0;
let aliasChecks = 0;
try {
  const configs = ['NodeNext', 'Bundler'].map((mode) => {
    const config = join(temporary, `${mode}.json`);
    writeFileSync(config, JSON.stringify({
      compilerOptions: {
        strict: true,
        noEmit: true,
        target: 'ES2022',
        module: mode === 'NodeNext' ? 'NodeNext' : 'ESNext',
        moduleResolution: mode,
        allowArbitraryExtensions: true,
        types: [],
      },
      files: ['requests-consumer.ts', 'consumer.mts'].map((file) => resolve(file)),
    }));
    return config;
  });
  api = new API({ cwd: process.cwd() });
  const snapshot = api.updateSnapshot({ openProjects: configs });
  for (const config of configs) {
    const project = snapshot.getProject(config);
    assert.ok(project);
    for (const [file, text, offset, declaration, name] of cases) {
      const source = resolve(file);
      const position = readFileSync(source, 'utf8').indexOf(text);
      assert.ok(position >= 0, `Existing consumer reference ${text} is present.`);
      const imported = project.checker.getSymbolAtPosition(source, position + offset);
      assert.ok(imported);
      const symbol = imported.flags & SymbolFlags.Alias
        ? project.checker.getAliasedSymbol(imported)
        : imported;
      assert.equal(project.checker.isUnknownSymbol(symbol), false);
      assert.equal(symbol.name, name);
      assert.ok(symbol.declarations.some((node) => node.path.endsWith(`/${declaration}`)));
      if (name === 'summarize') {
        const type = project.checker.getTypeOfSymbol(symbol);
        assert.ok(type);
        assert.equal(project.checker.getSignaturesOfType(type, SignatureKind.Call).length, 1);
        functionChecks++;
      } else {
        assert.ok(symbol.flags & SymbolFlags.TypeAlias);
        aliasChecks++;
      }
      assert.equal(project.checker.getDocumentationCommentOfSymbol(symbol), expected[name]);
      checks++;
    }
  }
} finally {
  try {
    api?.close();
  } finally {
    rmSync(temporary, { recursive: true, force: true });
  }
}
console.log(JSON.stringify({
  documentationChecks: checks,
  functionDocumentationChecks: functionChecks,
  aliasDocumentationChecks: aliasChecks,
}));
