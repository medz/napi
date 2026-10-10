import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

assert.ok(process.argv[2], 'Pass the TypeScript bin/tsc path.');
const apiPath = resolve(dirname(resolve(process.argv[2])), '../dist/api/sync/api.js');
const { API, SymbolFlags, SignatureKind } = await import(pathToFileURL(apiPath).href);
const expected =
  'Counts requests per exact operation name in UTF-16 code-unit order.\n' +
  "Durations and each operation's total must fit a nonnegative safe JS integer.";
const cases = [
  ['requests-consumer.ts', 'api.summarize(', 4, 'index.d.ts'],
  ['requests-consumer.ts', 'subpath(', 1, 'index.d.ts'],
  ['consumer.mts', 'summarize(', 1, 'module.d.wasm.ts'],
];
const temporary = mkdtempSync(join(tmpdir(), 'napi-documentation-'));
let api;
let checks = 0;
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
    for (const [file, call, offset, declaration] of cases) {
      const source = resolve(file);
      const position = readFileSync(source, 'utf8').indexOf(call);
      assert.ok(position >= 0, `Existing consumer call ${call} is present.`);
      const imported = project.checker.getSymbolAtPosition(source, position + offset);
      assert.ok(imported);
      const symbol = imported.flags & SymbolFlags.Alias
        ? project.checker.getAliasedSymbol(imported)
        : imported;
      assert.equal(project.checker.isUnknownSymbol(symbol), false);
      assert.equal(symbol.name, 'summarize');
      assert.ok(symbol.declarations.some((node) => node.path.endsWith(`/${declaration}`)));
      const type = project.checker.getTypeOfSymbol(symbol);
      assert.ok(type);
      assert.equal(project.checker.getSignaturesOfType(type, SignatureKind.Call).length, 1);
      assert.equal(project.checker.getDocumentationCommentOfSymbol(symbol), expected);
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
console.log(JSON.stringify({ documentationChecks: checks }));
