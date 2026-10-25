const assert = require('node:assert/strict');
const {execFileSync} = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');
const {Worker} = require('node:worker_threads');
const {pathToFileURL} = require('node:url');

const addonPath = path.resolve(
  process.env.NATIVE_IMAGE_ADDON || path.join(__dirname, 'build/addon.node'),
);
const workerSource = `
  const {parentPort, workerData} = require('node:worker_threads');
  const addon = require(workerData.addonPath);
  (async () => {
    parentPort.postMessage({
      answer: addon.answer,
      sum: addon.add(20, 22),
      delay: await addon.delay(1),
      file: await addon.readFile(workerData.file),
      run: await addon.isolateRun(21),
      spawn: await addon.isolateSpawn(21),
    });
  })().catch(error => { throw error; });
`;

function runWorker(data) {
  return new Promise((resolve, reject) => {
    const worker = new Worker(workerSource, {eval: true, workerData: data});
    const messages = [];
    worker.on('message', message => messages.push(message));
    worker.on('error', reject);
    worker.on('exit', code => {
      if (code !== 0) reject(new Error(`Worker exited with code ${code}`));
      else resolve(messages);
    });
  });
}

test('Dart native runtime integrates with Node', {timeout: 60000}, async t => {
  const addon = require(addonPath);
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'native image '));
  t.after(() => fs.rmSync(directory, {recursive: true, force: true}));
  const file = path.join(directory, '中文配置.txt');
  const contents = '  中文 🌍\nvalue\0tail\n';
  fs.writeFileSync(file, contents, 'utf8');
  const data = {addonPath, file};
  const expectedWorker = [{
    answer: 42, sum: 42, delay: 1, file: contents, run: 42, spawn: 42,
  }];
  assert.equal(addon.answer, 42);

  await t.test('Dart sees the host process and supports secure randomness', () => {
    const environment = JSON.parse(addon.environment());
    assert.equal(fs.realpathSync(environment.executable), fs.realpathSync(process.execPath));
    assert.equal(environment.resolvedExecutable, fs.realpathSync(process.execPath));
    assert.equal(environment.operatingSystem, 'macos');
    assert.equal(environment.pid, process.pid);
    assert.equal(environment.current, process.cwd());
    assert.equal(environment.base, pathToFileURL(process.cwd() + path.sep).href);
    assert.ok(Number.isInteger(environment.secureByte));
    assert.ok(environment.secureByte >= 0 && environment.secureByte < 256);
  });

  await t.test('adds safe integers and rejects invalid arguments', () => {
    for (let i = 0; i < 100; i++) assert.equal(addon.add(i, 42 - i), 42);
    assert.equal(addon.add(Number.MAX_SAFE_INTEGER, 0), Number.MAX_SAFE_INTEGER);
    assert.equal(addon.add(Number.MIN_SAFE_INTEGER, 0), Number.MIN_SAFE_INTEGER);
    assert.equal(addon.add(Number.MAX_SAFE_INTEGER, Number.MIN_SAFE_INTEGER), 0);
    for (const value of [
      undefined, null, true, '1', 1n, {}, [], 0.5, NaN, Infinity, -Infinity,
      Number.MAX_SAFE_INTEGER + 1, Number.MIN_SAFE_INTEGER - 1,
    ]) {
      assert.throws(() => addon.add(value, 0), TypeError);
      assert.throws(() => addon.add(0, value), TypeError);
      assert.equal(addon.add(20, 22), 42);
    }
    assert.throws(() => addon.add(), TypeError);
    assert.throws(() => addon.add(1), TypeError);
    assert.throws(() => addon.add(Number.MAX_SAFE_INTEGER, 1), TypeError);
    assert.throws(() => addon.add(Number.MIN_SAFE_INTEGER, -1), TypeError);
  });

  await t.test('sync and async file reads use dart:io directly', async () => {
    const syncRead = fs.readFileSync;
    const asyncRead = fs.readFile;
    fs.readFileSync = fs.readFile = () => {
      throw new Error('Dart native IO must not call Node fs');
    };
    try {
      assert.equal(addon.readFileSync(file), contents);
      const promise = addon.readFile(file);
      assert.ok(promise instanceof Promise);
      assert.equal(await promise, contents);
    } finally {
      fs.readFileSync = syncRead;
      fs.readFile = asyncRead;
    }
    const missing = path.join(directory, 'missing.txt');
    const fileError = /FileSystemException|PathNotFoundException|Cannot open|No such file/;
    assert.throws(() => addon.readFileSync(missing), fileError);
    await assert.rejects(addon.readFile(missing), fileError);
    assert.equal(await addon.readFile(file), contents);
  });

  await t.test('Timer completes after the current Node microtasks', async () => {
    const order = [];
    const delayed = addon.delay(5).then(value => {
      order.push('dart timer');
      assert.equal(value, 5);
    });
    order.push('after call');
    await Promise.resolve();
    order.push('node microtask');
    await delayed;
    assert.deepEqual(order, ['after call', 'node microtask', 'dart timer']);
    assert.equal(await addon.delay(0), 0);
  });

  await t.test('Dart writes and reads a UTF-8 file without Node fs', async () => {
    const written = path.join(directory, '写入.txt');
    const syncWrite = fs.writeFileSync;
    const asyncWrite = fs.writeFile;
    fs.writeFileSync = fs.writeFile = () => {
      throw new Error('Dart native IO must not call Node fs');
    };
    try {
      assert.equal(await addon.fileRoundtrip(written, contents), contents);
    } finally {
      fs.writeFileSync = syncWrite;
      fs.writeFile = asyncWrite;
    }
    assert.equal(fs.readFileSync(written, 'utf8'), contents);
  });

  await t.test('Dart Process starts a child and captures UTF-8 output', async () => {
    const text = '中文 🌍\n%s stays literal';
    assert.equal(await addon.processRoundtrip(text), text);
  });

  await t.test('Dart HTTP client and server exchange UTF-8 over loopback', async () => {
    assert.equal(
      await addon.httpRoundtrip('中文 🌍\0HTTP'),
      'Dart HTTP: 中文 🌍\0HTTP',
    );
  });

  await t.test('Isolate.run and Isolate.spawn return results and errors', async () => {
    assert.equal(await addon.isolateRun(21), 42);
    assert.equal(await addon.isolateSpawn(21), 42);
    assert.equal(await addon.isolateReadFile(file), contents);
    await assert.rejects(addon.isolateFailure(), /Dart isolate failure/);
    assert.equal(await addon.isolateRun(-21), -42);
  });

  await t.test('concurrent native async operations keep their results', async () => {
    assert.deepEqual(await Promise.all([
      addon.readFile(file),
      addon.delay(2),
      addon.isolateRun(10),
      addon.isolateSpawn(11),
      addon.httpRoundtrip('concurrent'),
    ]), [contents, 2, 20, 22, 'Dart HTTP: concurrent']);
  });

  await t.test('Node stays alive for Dart work and exits when idle', () => {
    const output = execFileSync(process.execPath, ['-e', `
      const addon = require(process.argv[1]);
      addon.delay(20).then(value => console.log('completed:' + value));
    `, addonPath], {timeout: 20000, encoding: 'utf8'});
    assert.equal(output.trim(), 'completed:20');
    execFileSync(process.execPath, ['-e', 'require(process.argv[1])', addonPath], {
      timeout: 20000, stdio: 'pipe',
    });
    const background = path.join(directory, 'background.txt');
    execFileSync(process.execPath, ['-e', `
      const addon = require(process.argv[1]);
      addon.backgroundFile(process.argv[2]);
    `, addonPath, background], {timeout: 20000, stdio: 'pipe'});
    assert.equal(fs.readFileSync(background, 'utf8'), 'Dart background task');
  });

  await t.test('handled Dart microtask errors do not leave Node alive', () => {
    const output = execFileSync(process.execPath, ['-e', `
      process.on('uncaughtException', error => {
        console.log(error.message.includes('Dart microtask failure')
          ? 'caught' : 'unexpected:' + error.message);
      });
      require(process.argv[1]).unhandledError();
    `, addonPath], {timeout: 20000, encoding: 'utf8'});
    assert.equal(output.trim(), 'caught');
  });

  await t.test('workers finish native async work while the parent remains callable', async () => {
    assert.deepEqual(await Promise.all([runWorker(data), runWorker(data)]), [
      expectedWorker, expectedWorker,
    ]);
    assert.equal(addon.add(20, 22), 42);
    assert.equal(await addon.readFile(file), contents);
  });

  await t.test('fresh workers may be the only addon users', () => {
    execFileSync(process.execPath, ['-e', `
      const assert = require('node:assert/strict');
      const {Worker} = require('node:worker_threads');
      const runWorker = ${runWorker.toString()};
      const workerSource = ${JSON.stringify(workerSource)};
      const data = JSON.parse(process.argv[1]);
      const expected = JSON.parse(process.argv[2]);
      (async () => {
        const first = await Promise.all([runWorker(data), runWorker(data)]);
        assert.deepEqual(first, [expected, expected]);
        assert.deepEqual(await runWorker(data), expected);
      })().catch(error => {
        console.error(error);
        process.exitCode = 1;
      });
    `, JSON.stringify(data), JSON.stringify(expectedWorker)], {
      timeout: 20000, stdio: 'pipe',
    });
  });

  await t.test('terminating a worker with a pending Dart timer is safe', async () => {
    const worker = new Worker(`
      const {parentPort, workerData} = require('node:worker_threads');
      const addon = require(workerData);
      addon.delay(60000);
      parentPort.postMessage('started');
    `, {eval: true, workerData: addonPath});
    await new Promise((resolve, reject) => {
      worker.once('message', resolve);
      worker.once('error', reject);
    });
    assert.equal(await worker.terminate(), 1);
    assert.equal(await addon.delay(1), 1);
  });

  await t.test('terminating a worker stops its Dart child isolates', async t => {
    const background = path.join(directory, 'child-background.txt');
    const worker = new Worker(`
      const {parentPort, workerData} = require('node:worker_threads');
      parentPort.on('message', () => {});
      const addon = require(workerData.addonPath);
      addon.spawnBackgroundFile(workerData.file).then(started => {
        parentPort.postMessage(started);
      });
    `, {eval: true, workerData: {addonPath, file: background}});
    t.after(() => worker.terminate());
    const started = await new Promise((resolve, reject) => {
      worker.once('message', resolve);
      worker.once('error', reject);
    });
    assert.equal(started, 'started');
    assert.equal(await worker.terminate(), 1);
    await new Promise(resolve => setTimeout(resolve, 250));
    assert.equal(fs.existsSync(background), false);
    assert.equal(await addon.delay(1), 1);
  });
});
