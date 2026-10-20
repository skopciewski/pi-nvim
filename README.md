# pi-nvim

forked from [carderne/pi-nvim](https://github.com/carderne/pi-nvim)

## How it works

The pi side is the vendored pi-nvim extension, which opens a Unix socket for each pi session. The **Neovim plugin** (`lua/pi-nvim/`) finds the socket of the current project, connects to it via libuv, and sends context from the editor to pi. Windows is not supported.

### Session discovery

Each pi session listens on `<dir>/<hash>-<pid>-<random>.sock` and writes a manifest `<socket>.info` (`cwd`, `pid`, `startedAt`) next to it. The project root is the nearest ancestor of the cwd that contains `.git`, or the cwd itself. `<dir>` is `<project root>/tmp` when that directory exists, otherwise `/tmp/pi-nvim-sockets`.

Keeping the socket in the project directory lets Neovim on the host reach pi running in a container that has the project volume-mounted, because the container's `/tmp` is not visible from the host. Create `tmp/` in the project (and ignore it in git) before starting pi.

The plugin picks the socket in this order:

1. `socket_path` from `setup()`, used as-is.
2. The session chosen in `:PiSessions`, until it stops accepting connections.
3. The newest session in `<project root>/tmp`.
4. The newest session in `/tmp/pi-nvim-sockets` whose `cwd` lies inside the project.

Sessions of other projects are never chosen automatically. `:PiSessions` lists the sessions in this project's `tmp/` and all sessions in `/tmp/pi-nvim-sockets` (any project), so you can pin one explicitly; sessions living in another project's `tmp/` are not visible from here. The result is cached and rescanned only when the cwd or one of the two directories changes. If a connection is refused, the plugin deletes the leftover socket and its manifest (pi exited without cleanup) and retries once with the next session. It deletes only names written by the extension, and only if the path still holds the socket that refused.

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

| Command            | Description                                                  |
| ------------------ | ------------------------------------------------------------ |
| `:Pi`              | Open the Send to pi dialog (works in normal and visual mode) |
| `:PiSend`          | Type a prompt and send to pi                                 |
| `:PiSendFile`      | Send current file path + prompt                              |
| `:PiSendSelection` | Send visual selection + prompt                               |
| `:PiSendBuffer`    | Send entire buffer + prompt                                  |
| `:PiPing`          | Check if pi is reachable                                     |
| `:PiSessions`      | List running pi sessions (see Session discovery) and pin one |

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
- Press **Esc** or **Ctrl-C** to cancel

### Additional keybindings

```lua
vim.keymap.set("n", "<leader>pp", ":PiSend<CR>")
vim.keymap.set("n", "<leader>pf", ":PiSendFile<CR>")
vim.keymap.set("v", "<leader>ps", ":PiSendSelection<CR>")
vim.keymap.set("n", "<leader>pb", ":PiSendBuffer<CR>")
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
```

## License

MIT
