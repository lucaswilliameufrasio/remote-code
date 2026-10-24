import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { StringDecoder } from 'node:string_decoder';

export function createPolicy(roots, directory) {
  let active = 0;
  return async function execute(method, input, signal) {
    if (active >= 4) {
      throw new Error('FILES_BUSY');
    }
    signal?.throwIfAborted();
    active++;
    try {
      const request = JSON.stringify({ roots, directory, method, input });
      if (Buffer.byteLength(request) > 65536) {
        throw new Error('FILES_LIMIT');
      }
      return await new Promise((resolve, reject) => {
        const child = spawn('python3', [fileURLToPath(new URL('./filesystem.py', import.meta.url))],
          { stdio: ['pipe', 'pipe', 'ignore'] });
        let output = '';
        let outputBytes = 0;
        let failure;
        const decoder = new StringDecoder('utf8');
        const abort = () => {
          failure = new Error('FILES_CANCELLED');
          child.kill('SIGKILL');
        };
        const timeout = setTimeout(abort, 5000);
        signal?.addEventListener('abort', abort, { once: true });
        if (signal?.aborted) {
          abort();
        }
        const cleanup = () => {
          clearTimeout(timeout);
          signal?.removeEventListener('abort', abort);
        };
        child.on('error', () => {
          cleanup();
          reject(new Error('FILES_UNAVAILABLE'));
        });
        child.stdout.on('data', (chunk) => {
          outputBytes += chunk.length;
          if (outputBytes > 2 * 1024 * 1024) {
            abort();
            return;
          }
          output += decoder.write(chunk);
        });
        child.on('close', () => {
          cleanup();
          if (failure) {
            reject(failure);
            return;
          }
          try {
            resolve(JSON.parse(output + decoder.end()));
          } catch {
            reject(new Error('FILES_UNAVAILABLE'));
          }
        });
        child.stdin.on('error', () => {
          abort();
        });
        child.stdin.end(request);
      });
    } finally {
      active--;
    }
  };
}
