import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, realpath, mkdir, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import plugin from './index.js';
import { createPolicy } from './policy.js';

async function fixture(context) {
  const directory = await realpath(await mkdtemp(join(tmpdir(), 'remote-code-files-')));
  context.after(() => rm(directory, { recursive: true, force: true }));
  await writeFile(join(directory, 'file.txt'), 'safe content');
  return directory;
}

test('Should register RPC handlers and enforce configured roots in the real helper', async (context) => {
  const directory = await fixture(context);
  let handlers;
  await plugin.setup({ options: { roots: [directory] }, location: { directory },
    rpc: { register: async (definition, registered) => {
      assert.equal(definition.id, 'remote-code-files-v1');
      handlers = registered;
    } },
  });
  const request = { error: (type, message, data) => ({ type, data }) };
  assert.equal((await handlers.read({ path: 'file.txt' }, request)).text, 'safe content');
  assert.equal((await handlers.read({ path: '../outside' }, request)).data.code, 'FILES_DENIED');
});

test('Should deny every operation when no root is configured', async (context) => {
  const directory = await fixture(context);
  const policy = createPolicy([], directory);
  assert.equal((await policy('list', {})).error.code, 'FILES_DENIED');
});

test('Should bound active subprocesses reject overload and release capacity', async (context) => {
  const directory = await fixture(context);
  const policy = createPolicy([directory], directory);
  const requests = Array.from({ length: 4 }, () => policy('list', {}));
  await assert.rejects(policy('list', {}), /FILES_BUSY/);
  await Promise.all(requests);
  assert.ok((await policy('list', {})).output.data.length > 0);
});

test('Should cancel a child process and permit later requests', async (context) => {
  const directory = await fixture(context);
  const policy = createPolicy([directory], directory);
  const controller = new AbortController();
  const request = policy('list', {}, controller.signal);
  controller.abort();
  await assert.rejects(request, /FILES_CANCELLED/);
  assert.ok((await policy('list', {})).output.data.length > 0);
});

test('Should preserve multi-byte text across process output chunks', async (context) => {
  const directory = await fixture(context);
  await mkdir(join(directory, 'src'));
  await writeFile(join(directory, 'src', 'unicode.txt'), 'é'.repeat(200000));
  const policy = createPolicy([directory], directory);
  const result = await policy('read', { path: 'src/unicode.txt' });
  assert.equal(result.output.truncated, true);
  assert.equal(Buffer.byteLength(result.output.text), 256 * 1024);
  assert.equal(result.output.text.includes('\ufffd'), false);
});
