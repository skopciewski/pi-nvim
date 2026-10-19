# pi-nvim

forked from [carderne/pi-nvim](https://github.com/carderne/pi-nvim)

## How it works

1. **Neovim plugin** (`lua/pi-nvim/`) — connects to that socket via libuv. Sends context from your editor to pi.

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
  socket_path = nil, -- auto-discover
  set_default_keymaps = true,
})
```

## Usage

Start pi in one terminal. Start Neovim in another. The pi extension automatically opens a socket on session start.

### Commands

| Command            | Description                                                  |
| ------------------ | ------------------------------------------------------------ |
| `:Pi`              | Open the Send to pi dialog (works in normal and visual mode) |
| `:PiSend`          | Type a prompt and send to pi                                 |
| `:PiSendFile`      | Send current file path + prompt                              |
| `:PiSendSelection` | Send visual selection + prompt                               |
| `:PiSendBuffer`    | Send entire buffer + prompt                                  |
| `:PiPing`          | Check if pi is reachable                                     |
| `:PiSessions`      | List/switch between running pi sessions                      |

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
echo '{"type":"prompt","message":"hello"}' | socat - UNIX-CONNECT:/tmp/pi-nvim-sockets/<hash>.sock
```

## License

MIT
