# remote-ssh plugin tests

Tests run under the Pragtical runtime using the built-in `core.test`
framework.

## Running

Run from the plugin root directory with a **clean `PRAGTICAL_USERDIR`**
so that an installed copy of the plugin (in `~/.config/pragtical/plugins/`)
does not get auto-loaded and pollute the module under test:

```bash
mkdir -p /tmp/pragtical_test_user
PRAGTICAL_USERDIR=/tmp/pragtical_test_user pragtical test tests/
```

`pragtical test` opens a short-lived editor window, executes the tests in a
background coroutine, prints results, and quits with exit code `0` on success
(or `1` on any failure).

## Layout

| file             | purpose                                                      |
| ---------------- | ------------------------------------------------------------ |
| `helper.inc`     | shared harness: `package.preload` remaps, fake socket/proc   |
|                  | factories, framed-message helpers, error capture utilities.  |
| `messagepack.lua`| pure roundtrip + byte-layout tests for the MessagePack codec.|
| `bridge.lua`     | framing state machine, sync request/response, `update()`,     |
|                  | `disconnect()`, and `connect()` (mocked ssh/net) tests.      |
| `init.lua`       | API intercepts (`system.*`, `Doc:*`, `DirWatch`, `Project`), |
|                  | path scrubbing, view/title, on_disconnect, commands, and    |
|                  | treeview/terminal hook installation tests.                   |

## Notes

- The helper uses `package.preload` so `require("plugins.remote-ssh*")`
  resolves to `dofile` of the repo-root sources — the tests exercise the
  local code, not an installed copy.
- A `loopback` fake socket parses each framed request written by the
  bridge, invokes a handler, and feeds the framed response back through
  `:read()` so `bridge.perform_sync_request` completes synchronously
  without any real network/SSH.
- `bridge.connect()` orchestration is tested with mocked `process.start`
  and a fake `_G.net`; no real SSH connection is ever attempted.
