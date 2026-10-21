# pi-nvim

forked from [carderne/pi-nvim](https://github.com/carderne/pi-nvim)

## How it works

The pi side is the vendored pi-nvim extension, which opens a Unix socket for each pi session. The **Neovim plugin** (`lua/pi-nvim/`) finds the socket of the current project, connects to it via libuv, and sends context from the editor to pi. Windows is not supported.

### Session discovery

Each pi session listens on `<dir>/<hash>-<pid>-<random>.sock` and writes a manifest `<socket>.info` (`socket`, `cwd`, `projectRoot`, `pid`, `startedAt`) next to it. The project root is the nearest ancestor of the cwd that contains `.git` (a directory or a worktree/submodule file), or the cwd itself. `cwd` remains the actual session starting directory; `projectRoot` is the checkout root as seen by pi. `<dir>` is `<project root>/tmp` when that directory exists, otherwise `/tmp/pi-nvim-sockets`.

Keeping the socket in the project directory lets Neovim on the host reach pi running in a container that has the project volume-mounted, because the container's `/tmp` is not visible from the host. Create `tmp/` in the project (and ignore it in git) before starting pi.

The plugin picks the socket in this order:

1. `socket_path` from `setup()`, used as-is.
2. The session chosen in `:PiSessions`, until it stops accepting connections.
3. The newest session in `<project root>/tmp`.
4. The newest session in `/tmp/pi-nvim-sockets` whose `projectRoot` matches the local project root. Older manifests without `projectRoot` fall back to matching `cwd` inside the project.

Sessions of other projects are never chosen automatically. `:PiSessions` lists the sessions in this project's `tmp/` and all sessions in `/tmp/pi-nvim-sockets` (any project), so you can pin one explicitly; sessions living in another project's `tmp/` are not visible from here. Discovery uses Neovim's effective cwd, including `:lcd` and `:tcd`. The result is cached and rescanned only when the cwd or one of the two directories changes. If a connection is refused, the plugin deletes the leftover socket and its manifest (pi exited without cleanup) and retries once with the next session. It deletes only names written by the extension, and only if the path still holds the socket that refused.

### File paths across host and container

All file-bearing commands, including the `:Pi` dialog, send **absolute paths in
the selected pi session's filesystem**, not host paths or paths relative to cwd.
The dialog still displays the local file name; its layout and controls are unchanged.

The manifest in the shared `<checkout>/tmp` directory pairs the local checkout
root with pi's `projectRoot`. For example:

```text
Neovim root: /home/user/worktrees/project/feature-a
pi root:     /mnt/agent-share/project/worktrees/feature-a
Local file:  /home/user/worktrees/project/feature-a/src/example.lua
Sent path:   /mnt/agent-share/project/worktrees/feature-a/src/example.lua
```

The same mechanism works when both roots are identical. Neither process needs
to start at the root; cwd subdirectories do not affect the resulting reference.
Each worktree must share its own `tmp/` directory and socket with the host;
different checkouts must not point their `tmp/` directories at one common socket
store. Create that directory **before starting pi**, including in a fresh worktree;
the container's global socket directory is not visible on the host.

The local socket address comes from where the manifest was found, never from
the container's `socket` field. Older manifests without `projectRoot` can infer
the remote root from an advertised `<root>/tmp/<name>.sock` address. Global
sockets and custom socket locations without a shared-root pairing assume the
same filesystem path namespace, using the manifest's project root (or the
locally resolved cwd for older manifests).

File references are built after selecting a session and rebuilt if connection
retry selects a different session. Files outside the selected session's checkout,
including symlinks leading outside it, are rejected with an error. Symlinked
checkout paths and new, unsaved files inside a checkout are supported. Unnamed
buffers are labeled `(unnamed buffer)` rather than assigned a file path.
Terminal, scratch, and other virtual buffers can send contents, selections, and
diagnostics with a `(buffer: ...)` label, never an invented checkout file path.
`:PiSendFile` requires a real file buffer. In `:Pi`, a virtual buffer with neither
a selection nor the send-buffer option sends only the entered prompt.
A fixed socket without usable manifest metadata still accepts plain prompts and
pings, but cannot accept automatically generated file references.

All sends use the selected socket, even if a pi terminal buffer is open in
Neovim. The plugin no longer sends bracketed-paste input to the first terminal
named pi, so that terminal cannot override `:PiSessions` or the path mapping.
Paths typed manually in a prompt are not rewritten.

## Install

### Neovim side

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{ "carderne/pi-nvim" }
```

Then in your config:

```lua
require("pi-nvim").setup()
```

Options (defaults):

```lua
require("pi-nvim").setup({
  socket_path = nil, -- fixed socket path; nil = discover (see above)
  set_default_keymaps = true,
})
```

## Usage

Start pi in one terminal (or container) and Neovim in another, both in the same project. The pi extension opens a socket on session start.

### Commands

| Command              | Description                                                  |
| -------------------- | ------------------------------------------------------------ |
| `:Pi`                | Open the Send to pi dialog (works in normal and visual mode)  |
| `:PiSend`            | Type a prompt and send to pi                                  |
| `:PiSendFile`        | Send current file path + prompt                               |
| `:PiSendSelection`   | Send visual selection + prompt                                |
| `:PiSendBuffer`      | Send entire buffer + prompt                                   |
| `:PiSendDiagnostics` | Send diagnostics from the current buffer without a dialog     |
| `:PiPing`            | Check if pi is reachable                                      |
| `:PiSessions`        | List running pi sessions (see Session discovery) and pin one  |

`:PiSendDiagnostics` sends all diagnostic severities and sources known to Neovim
for the current buffer only. The message includes the mapped file path, one-based
line and byte column, severity, source and diagnostic code (when available), and diagnostic
text, sorted by position. It does not send buffer contents or run a new analysis.
If the buffer has unsaved changes, the message notes that; if it has no
diagnostics, the command notifies you without sending anything to pi. Diagnostic
positions come from Neovim's most recent diagnostic results, which can lag behind edits.

### Default keybindings

`<leader>p` is mapped to `:Pi` in both normal and visual mode by default.

To disable the default mappings:

```lua
require("pi-nvim").setup({
  set_default_keymaps = false,
})
```

### The `:Pi` dialog

Opens a floating window in the center of the screen:

- Shows the current **file name** (always sent)
- If you had a **visual selection**, it shows the line range and sends the selected text
- If no selection, you can press **Tab** to toggle sending the **entire buffer**
- Type a prompt and press **Enter** to send (or just Enter with no prompt)
- The dialog closes after pi acknowledges the message; a failed send keeps your prompt available to edit or retry
- Press **Esc** or **Ctrl-C** to cancel

### Additional keybindings

```lua
vim.keymap.set("n", "<leader>pp", ":PiSend<CR>")
vim.keymap.set("n", "<leader>pf", ":PiSendFile<CR>")
vim.keymap.set("v", "<leader>ps", ":PiSendSelection<CR>")
vim.keymap.set("n", "<leader>pb", ":PiSendBuffer<CR>")
vim.keymap.set("n", "<leader>pd", ":PiSendDiagnostics<CR>")
vim.keymap.set("n", "<leader>pi", ":PiPing<CR>")
```

## Protocol

The socket accepts newline-delimited JSON:

```json
{"type": "prompt", "message": "your prompt here"}
{"type": "ping"}
```

Responses:

```json
{"ok": true}
{"ok": true, "type": "pong"}
{"ok": false, "error": "..."}
```

This means you can also send prompts from any tool:

```bash
echo '{"type":"prompt","message":"hello"}' | socat - UNIX-CONNECT:tmp/<hash>-<pid>-<random>.sock
```

## Tests

```sh
nvim --clean --headless -l tests/discovery_spec.lua
nvim --clean --headless -l tests/diagnostics_spec.lua
nvim --clean --headless -l tests/context_spec.lua
```

## License

MIT
