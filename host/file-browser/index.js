import { createPolicy } from './policy.js';

const input = { type: 'object', properties: {
  path: { type: 'string', maxLength: 4096 },
  query: { type: 'string', maxLength: 256 },
  directories_only: { type: 'boolean' },
}, additionalProperties: false };
const method = { input, output: { type: 'object' }, errors: {
  rejected: { type: 'object', properties: {
    code: { type: 'string' },
  }, required: ['code'], additionalProperties: false },
} };

// OpenCode V2 Plugin.define and Rpc.define return these descriptors unchanged.
// Keep this runtime-only adapter dependency-free; schemas are validated by OpenCode.
const FileBrowser = {
  id: 'remote-code-files-v1',
  methods: { list: method, find: method, read: method, capabilities: method, roots: method },
  events: {},
};

export default {
  id: 'remote-code-file-browser',
  async setup(context) {
    const roots = Array.isArray(context.options.roots) ? context.options.roots : [];
    const execute = createPolicy(roots, context.location.directory);
    const handlers = {};
    for (const name of ['list', 'find', 'read', 'capabilities', 'roots']) {
      handlers[name] = async (value, request) => {
        try {
          const result = await execute(name, value, request.signal);
          if (result.error) {
            return request.error('rejected', result.error.message, { code: result.error.code });
          }
          return result.output;
        } catch {
          return request.error('rejected', 'Explorador indisponível ou ocupado. Tente novamente.', { code: 'FILES_UNAVAILABLE' });
        }
      };
    }
    await context.rpc.register(FileBrowser, handlers);
  },
};
