# Restricted Remote Code file browser

Optional OpenCode **V2** plugin for the mobile app's read-only file browser.
Uses the existing authenticated OpenCode RPC endpoint; no new listener, password,
public tunnel, or model request. Tested with an isolated OpenCode v2.0.27 server.

## Configure on a trusted Linux or macOS host

Requires Python 3 with POSIX `dir_fd`, `O_DIRECTORY`, and `O_NOFOLLOW`. The plugin
uses OpenCode's JavaScript runtime and Node built-ins; **no npm install is needed**.
Keep this whole directory on the host, including `filesystem.py` and `policy.js`.

Merge into the existing OpenCode configuration **manually**, preserving unrelated
settings. Use the plugin **directory**, not `index.js`, for v2.0.27 compatibility:

```jsonc
{
  "plugins": [
    {
      "package": "/absolute/path/remote-code/host/file-browser",
      "options": {
        "roots": ["/absolute/authorized/project"]
      }
    }
  ]
}
```

Do not copy the placeholder paths unchanged. The operator chooses up to 16 roots.
An absent/empty root list denies all access. Use actual, non-symlink absolute
paths (on macOS, `/tmp` is a symlink; use its canonical path if authorizing it).
Coordinate any required configuration reload/restart with the host owner. This
repository does not install the plugin or restart an existing server automatically.

The app requires this extension for **Arquivos do projeto** and directory
exploration. A missing plugin fails closed: no fallback to unrestricted native
filesystem endpoints. Chat, direct directory entry, and manual authentication
continue to use the normal OpenCode API.

## Security boundary

The helper authorizes the requested location against configured roots and walks
every component using directory descriptors and no-follow opens. Symlink files,
symlink directories, traversal, absolute child paths, special files and binary
previews are refused. Reads are anchored to already-open descriptors, including
when a directory is renamed while reading. Paths containing percent escapes or
backslashes are intentionally unsupported.

This is a boundary for **these RPC operations**, **not an agent sandbox**. It does
not disable native OpenCode filesystem endpoints for other clients, constrain
shell tools, prevent hard links/mounts, or secure a host executing malicious code
as its own user. Trust the plugin/configuration and use OS isolation or managed
policies for stronger requirements. Do not load untrusted project plugins.

Limits: 256 KiB text preview; 500 listed children (larger listings fail instead of
silently truncating); search returns at most 100 matches and inspects at most 5000
entries in two seconds, with at most 256 pending directories. Search is explicitly
bounded, not an exhaustive index. Four active helper processes, no waiting queue,
five-second deadline, bounded stdin/stdout and cancellation. Roots/options are not
credentials; credentials remain in OpenCode's authentication boundary.

## Contract and tests

Owned RPC: `POST /api/rpc/remote-code-files-v1/{method}` with
`location[directory]` and `{"input": {...}}`. Methods: `list`, `find`, `read`,
`capabilities`, `roots`. The roots method exposes only the operator's configured
root names to authenticated callers; it does not list an arbitrary location.
OpenCode validates schemas, supplies auth/cancellation and wraps
responses in `output`. Errors use declared RPC type `rejected` and stable
`FILES_*` codes. This is an extension contract, not a native OpenCode endpoint.

```sh
make test-host
make test-host-runtime
```

The runtime test creates its own temporary HOME/config/data, synthetic credentials,
fixture files and listener, starts only that isolated server, and terminates it
afterward. No existing OpenCode service, user config, real prompt or deployment is
used. Node 22+ is required for the adapter test runner. Actual TLS, remote host
installation and physical-device acceptance remain separate deployment checks.
