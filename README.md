# gdev.nvim

Godot 4 development for Neovim: the editor's language server and debug adapter, running the
project, browsing a scene, reading the class reference, and a `:checkhealth` that tells you which
of those is actually working.

Built like [mini.nvim](https://github.com/nvim-mini/mini.nvim) — one self-contained module per
feature under a shared `gdev.*` namespace, each independently `setup()`-able, configurable and
disable-able. Take the two you want and ignore the rest.

Only Neovim's own APIs are required. `nvim-treesitter` and `nvim-lspconfig` are not dependencies;
`nvim-dap` is one only if you debug.

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quickstart](#quickstart)
- [Configuration](#configuration)
- [Commands](#commands)
- [Modules](#modules)
- [Godot editor settings worth changing](#godot-editor-settings-worth-changing)
- [Using several Godot versions](#using-several-godot-versions)
- [Hiding Godot's generated files](#hiding-godots-generated-files)
- [What this plugin deliberately does not do](#what-this-plugin-deliberately-does-not-do)
- [Development](#development)

## Features

| Module | What it does |
|---|---|
| `gdev.lsp` | Attaches GDScript and shader buffers to the language server inside a running Godot editor, over TCP. Works around two Godot quirks. Opt-in inlay hints. |
| `gdev.treesitter` | Starts `vim.treesitter` in Godot buffers whose parser you installed, resolves the two names the `gdresource` grammar ships under, and adds the filetypes Neovim misses. |
| `gdev.dap` | Registers the editor's debug adapter with `nvim-dap` plus a "Launch scene" configuration, and opens/closes `nvim-dap-ui` with the session. |
| `gdev.format` | Runs `gdscript-formatter` or `gdformat` over a script after you write it, and reloads the buffer. Optional indent override. |
| `gdev.server` | Makes this Neovim reachable at a fixed address so clicking a script in Godot opens it here, with stale-socket recovery. |
| `gdev.run` | Runs the project, the current scene, a named scene, or one picked from the project — with optional capture of the engine's output into a scratch window. |
| `gdev.scenetree` | Renders a `.tscn` node hierarchy in a side pane, with jump-to-node, yank-node-path and open-attached-script. Parses the file, so Godot need not be running. |
| `gdev.docs` | Shows a Godot class page in a float, a split, or your browser, converting the documentation's reStructuredText source to Markdown. |
| `gdev.health` | `:checkhealth gdev` — eight sections, each finding saying what to do about it. |

Pickers go through `vim.ui.select`, so Telescope, fzf-lua and snacks users get their own picker for
free and everybody else gets a working one.

## Requirements

- **Neovim 0.11+**
- **Godot 4.x.** 4.3 or later is what this targets; `:checkhealth gdev` warns below it.
- **macOS or Linux.** Windows and WSL are out of scope — see
  [what this plugin deliberately does not do](#what-this-plugin-deliberately-does-not-do).

Everything below is optional, needed only by the module that uses it. `:checkhealth gdev` reports
each one and how to get it.

| Optional | Needed by | For |
|---|---|---|
| Treesitter parsers and queries for `gdscript`, `gdshader`, `gdresource` | `gdev.treesitter` | Syntax highlighting. **Yours to install** — see [gdev.treesitter](#gdevtreesitter). |
| [`nvim-dap`](https://github.com/mfussenegger/nvim-dap) | `gdev.dap` | Debugging. Without it, `setup()` warns and does nothing else. |
| [`nvim-dap-ui`](https://github.com/rcarriga/nvim-dap-ui) | `gdev.dap` | The panel opened and closed with a debug session. |
| `gdscript-formatter` or `gdformat` | `gdev.format` | Formatting on save. |
| `curl` | `gdev.docs` | The `float` and `buffer` renderers. The `browser` renderer needs nothing. |
| `nc` | `gdev.health` | The two port probes. Without it they say so instead of guessing. |

## Installation

No module sets itself up. Nothing happens until you call `setup()`, which is what makes it safe to
install this and adopt it one module at a time.

### lazy.nvim

```lua
{
  'gataky/gdev.nvim',
  ft = { 'gdscript', 'gdshader', 'gdresource' },
  -- Debugging only. `nvim-dap` has to be loadable by the time
  -- `require('gdev.dap').setup()` runs, which is why it belongs here rather than
  -- in a lazy load of its own. Leave both out and pass `dap = false` instead.
  dependencies = { 'mfussenegger/nvim-dap', 'rcarriga/nvim-dap-ui' },
  config = function() require('gdev').setup() end,
}
```

`ft` is a reasonable lazy trigger, with one thing to know: `gdev.server` has to be listening
*before* Godot tries to open a file in this Neovim, and a plugin that has not loaded is not
listening. If you use the external-editor workflow, either drop `ft` or set the server up eagerly.

### vim.pack (Neovim 0.12+)

```lua
vim.pack.add({
  'https://github.com/mfussenegger/nvim-dap', -- optional
  'https://github.com/rcarriga/nvim-dap-ui',  -- optional
  'https://github.com/gataky/gdev.nvim',
})

require('gdev').setup()
```

## Quickstart

1. **Open the project in the Godot editor.** Everything that talks to Godot talks to the *editor*:
   the language server and the debug adapter are part of it, not separate binaries, and they answer
   for the project it has open. Point Neovim at one project and Godot at another and the server
   will tell you so — you will see `The GDScript Language Server might not work correctly with
   other projects than the one opened in Godot`.
2. **Open the project in Neovim**, from the directory holding `project.godot` (or any file under
   it — the project root is found by walking up).
3. **Set the plugin up.** Per module is the documented API:

   ```lua
   require('gdev.lsp').setup()
   require('gdev.run').setup()
   ```

   Or all of it at once, which is the same thing with less typing:

   ```lua
   require('gdev').setup({ dap = false })
   ```

4. **Open a `.gd` file.** A client attaches to the editor and Neovim's built-in LSP mappings start
   working: `K`, `grr`, `gri`, `grn`, `<C-]>`, `gO`. This plugin defines no mappings of its own, so
   nothing of yours is taken.
5. **Run `:checkhealth gdev`.** It describes the session you are in — the Godot version it found,
   whether both editor ports answer, which treesitter parsers are missing, and the exact
   `Exec Flags` string to paste into Godot.

## Configuration

Every field below is at its default. Nothing here has to be set; this is the whole surface in one
place, and every module's own help page (`:h gdev.run`, `:h GdevRun.config`) says the same thing
with more detail.

The umbrella `require('gdev').setup()` forwards each key to that module's own `setup()` and does
nothing else. A key set to `false` skips the module entirely; an omitted key gets that module's
defaults. Nothing is shared between the tables — the host and port appear twice because the
language server and the debug adapter are two servers, and hard-coding them to agree here would
only have to be undone the first time one of them moved.

```lua
require('gdev').setup({
  lsp = {
    host = '127.0.0.1',            -- Editor Settings > Network > Language Server > Remote Host
    port = 6005,                   -- ... > Remote Port
    inlay_hints = false,           -- Godot has to advertise `textDocument/inlayHint`; 4.7 does not
  },

  treesitter = {
    highlight = true,              -- start `vim.treesitter` in Godot buffers with a parser
    fold = false,                  -- treesitter folding *replaces* the ftplugin's indent folding
  },

  dap = {
    host = '127.0.0.1',            -- Editor Settings > Network > Debug Adapter > Remote Host
    port = 6006,                   -- ... > Remote Port. Not `network/debug/remote_port` (6007)
    dapui = true,                  -- open/close nvim-dap-ui with the session, if installed
    configurations = nil,          -- replaces the built-in "Launch scene" entry
  },

  format = {
    formatter = 'gdscript-formatter', -- 'gdscript-formatter' | 'gdformat' | false
    command = nil,                 -- string or argv array; wins over `formatter`
    autoformat = true,             -- format after writing a Godot script buffer
    indent = false,                -- `false` leaves indent options alone; see gdev.format below
  },

  server = {
    address = nil,                 -- nil = the address Neovim generated at startup (changes daily)
    autostart = false,             -- start during `setup()` and when a Godot buffer opens
    remove_stale_socket = true,    -- clean up after a crashed Neovim
    filetypes = { 'gdscript', 'gdshader', 'gdresource' },
  },

  run = {
    godot = 'godot',               -- name on $PATH, or a path, or a version-manager wrapper
    script_extensions = { 'gd' },  -- what counts as a script when resolving a scene
    console = {
      enabled = false,             -- capture the engine's output instead of detaching the run
      renderer = 'buffer',         -- 'buffer' | 'float'
      buffer = { position = 'bottom', size = 0.3 },   -- 'bottom' | 'right' | 'current'
      float = { width = 0.8, height = 0.25, border = 'rounded' },
    },
  },

  scenetree = {
    buffer = { position = 'left', size = 0.35 },      -- 'left' | 'right'
    icons = 'nerdfont',            -- 'nerdfont' | 'ascii' | false | { generic, script_suffix, types }
    icon_colors = {
      generic = 'Normal',
      groups = {
        White = 'Normal',
        Grey = 'Comment',
        Blue = 'DiagnosticInfo',
        Red = 'DiagnosticError',
        Green = 'DiagnosticOk',
        Purple = 'Constant',
        Yellow = 'DiagnosticWarn',
      },
    },
    mappings = {                   -- inside the pane; `''` turns one off
      jump = '<CR>',
      yank = 'y',
      script = 'g',
      refresh = 'r',
      close = 'q',
    },
    script_extensions = { 'gd' },
  },

  docs = {
    renderer = 'float',            -- 'float' | 'buffer' | 'browser'
    fallback_renderer = 'browser', -- the only fallback that can recover a failed fetch
    missing_symbol_feedback = 'message', -- 'message' | 'notify'
    version = 'stable',            -- as it appears in a docs.godotengine.org URL
    language = 'en',
    source_ref = 'master',         -- godot-docs git ref the .rst source is read from
    source_base_url = nil,         -- e.g. 'file:///path/to/godot-docs' to read it offline
    timeout_ms = 10000,
    cache = { enabled = true, max_entries = 64 },
    float = { width = 0.8, height = 0.8, border = 'rounded' },
    buffer = { position = 'right', size = 0.4 },      -- 'right' | 'bottom' | 'current'
  },
})
```

### Per-buffer overrides and off switches

Every module reads its config at call time from three layers: the table you passed to `setup()`,
then `vim.b.gdev<name>_config`, then per-call options. So a project that needs a different engine
is one buffer-local variable:

```lua
vim.b.gdevrun_config = { godot = '/opt/godot/4.2/godot' }
```

And every module can be turned off without being un-set-up, globally or for one buffer:

```lua
vim.g.gdevformat_disable = true   -- no formatting anywhere
vim.b.gdevlsp_disable = true      -- ... in this buffer
```

`gdev.dap` is the exception: its whole config is consumed during `setup()`, so it has no
buffer-local config to read. Its `_disable` variables still suppress opening the UI panel.

## Commands

| Command | Module | |
|---|---|---|
| `:GdevLspReconnect` | `lsp` | Re-attempt attachment in every open Godot buffer. |
| `:GdevLspToggleHints` | `lsp` | Toggle inlay hints in this buffer. |
| `:GdevFormat` | `format` | Format this buffer's file now, even with `autoformat = false`. |
| `:GdevServerStart [address]` | `server` | Listen for Godot, on `address` or the configured one. |
| `:GdevRunProject` | `run` | Run the project's main scene. |
| `:GdevRunCurrentScene` | `run` | Run this `.tscn`, or the scene using this script. |
| `:GdevRunScene {path}` | `run` | Run a named scene: `res://`, project-relative, or absolute. |
| `:GdevRunPicker` | `run` | Pick a scene to run from all of them. |
| `:GdevRunConsole` | `run` | Reopen and focus the last captured output. |
| `:GdevScenetree [scene]` | `scenetree` | Show a scene in the pane, resolving it from this buffer. |
| `:GdevScenetreeRefresh` | `scenetree` | Reparse the scene the pane is showing. |
| `:GdevDocs [Class]` | `docs` | Class reference, in `config.renderer`. No argument uses `<cword>`. |
| `:GdevDocsFloat [Class]` | `docs` | ... in a floating window. |
| `:GdevDocsBuffer [Class]` | `docs` | ... in a reusable split. |
| `:GdevDocsBrowser [Class]` | `docs` | ... on the website, in your browser. |
| `:GdevDocsCursor` | `docs` | ... for the word under the cursor. |
| `:checkhealth gdev` | `health` | Diagnose all of the above. |

No mappings are created. `:GdevDocs` on `gK` pairs well with `K` for LSP hover:

```lua
vim.keymap.set('n', 'gK', '<Cmd>GdevDocs<CR>', { desc = 'Godot class reference' })
```

## Modules

### gdev.lsp

Godot's language server is part of the running editor. There is no separate binary to install and,
in Godot 4, no switch to turn it on — the editor listens on
`Editor Settings > Network > Language Server > Remote Port` (6005) whenever it is open. If nothing
attaches, the editor is not running, or its port does not match `config.port`.

The server is registered under the `gdscript` `vim.lsp.config` name, for `gd`, `gdscript`,
`gdscript3` and `gdshader` filetypes, rooted at `project.godot` or `.git`. Sharing the `gdscript`
name with `nvim-lspconfig`'s config is deliberate: it is what stops a second client attaching to
the same buffer. Note that Neovim derives the client name from the config name, so clients report
as `gdscript` rather than anything prettier.

Two Godot quirks are worked around:

- It advertises `textDocument/typeDefinition` and then answers the request with an error. The
  server flag is cleared on attach, so Neovim never routes the request there and asking for a type
  definition reports "no client supports it" instead of surfacing a server error.
- It reports methods it has not implemented as `window/showMessage` notifications rather than
  error responses, so a session otherwise fills with `Method not found: godot/reloadScript`
  warnings triggered by nothing you did. That one message is dropped; every other server message
  still reaches you.

`:GdevLspReconnect` is for the common case of having opened the files before the editor. It does
**not** reload any buffer — re-enabling the server is Neovim's own path for activating it in
buffers that are already open — so unsaved changes, undo history and cursor position all survive.

**Inlay hints are off by default because Godot does not offer them.** A stock Godot 4.7.1 editor
advertises no `inlayHintProvider`, so `inlay_hints = true` would enable a feature nothing produces.
`:GdevLspToggleHints` refuses rather than pretending, and says why. Leave the option alone until a
Godot build you use advertises the method.

### gdev.treesitter

**Parsers and queries are yours to install, and this is the part most likely to look broken.**
`nvim-treesitter` is not a dependency, Neovim ships no parser installer and no Godot grammars, so
`parser/gdscript.so` and friends have to be on `'runtimepath'` — put there by `nvim-treesitter`,
by your package manager, or by the `tree-sitter` CLI into `stdpath('data')/site/parser/`.

Two failure modes look identical from the outside and are not:

- **No parser.** `:checkhealth gdev` names it, and the buffer falls back to Neovim's regular
  syntax highlighting rather than erroring.
- **No queries.** A parser with no `highlights.scm` on `'runtimepath'` loads without complaint and
  highlights *nothing*. Health cannot see this, because the parser is there. `:InspectTree` is how
  you tell them apart: a tree with no colour means the queries are missing.

Whatever installs a parser should install its queries alongside.

The `gdresource` grammar is published under two names — `godot_resource` by `nvim-treesitter`,
`gdresource` when built straight from the grammar repository. Both are tried, and the winner is
handed to `vim.treesitter.language.register()` so `get_parser()`, `foldexpr()` and `:InspectTree`
all agree on it. A registration of your own wins over both.

Filetypes added: `.gdshaderinc` as `gdshader`, and `project.godot` as `gdresource`. Neovim already
detects `.gd`, `.gdshader`, `.tscn` and `.tres`. Godot's generated files (`.import`, `.escn`) are
left alone deliberately — `.import` is far too broad an extension to claim for every project on the
machine.

`fold = false` by default because Neovim's bundled `gdscript` ftplugin already sets an
indent-based `foldexpr`. Turning this on *replaces* working folding with folding that needs a
`folds.scm` query you may not have.

### gdev.dap

Registers `dap.adapters.godot` against the editor's debug adapter and one
`dap.configurations.gdscript` entry, "Launch scene", which starts the project in
`${workspaceFolder}` and debugs the scene open in the editor. Drive it with `nvim-dap`'s own
commands — `:DapContinue`, `:DapToggleBreakpoint` — which already know about the adapter. There are
no commands here, because a worse spelling of `:DapContinue` is not worth having.

Registration replaces `dap.configurations.gdscript` wholesale, so a `launch.json` loaded through
`dap-launch.json` has to be loaded *after* this `setup()`, not before.

`nvim-dap-ui` is opened on `event_initialized` and closed on `event_terminated` / `event_exited`,
under a namespaced listener key so calling `setup()` again does not stack a second copy.
`require('dapui').setup()` is deliberately **not** called from here — doing so would quietly
replace whatever configuration you gave it.

Mind the port. Godot has two "remote port" settings and they are not the same thing:
`network/debug_adapter/remote_port` (6006) is the debug adapter this connects to, while
`network/debug/remote_port` (6007) is how a running game talks back to the editor. The adapter
setting is registered by the editor at runtime, so you will not find it written in
`editor_settings-4.*.tres` until you change it; a stock 4.7.1 editor answers on 6006.

### gdev.format

Godot script buffers are formatted after they are written, by running an external formatter over
the saved file and reloading the buffer with `:checktime`. Both formatters in circulation rewrite
files in place and do not read stdin, which is why this formats what is on disk — and why a
modified buffer is refused rather than formatted from its stale saved state.

- [`gdscript-formatter`](https://github.com/GDQuest/GDScript-formatter) (default), run with
  `--reorder-code`, which sorts a script into Godot's documented member order.
- [`gdformat`](https://github.com/Scony/godot-gdscript-toolkit), from gdtoolkit:
  `pipx install "gdtoolkit==4.*"`.
- Anything else through `command`, as a string or an argv array. The file path is appended.

A missing executable is reported once, not once per save. `:GdevFormat` works even with
`autoformat = false`.

**Indentation is off by default, and that is not an oversight.** Neovim bundles
`ftplugin/gdscript.vim`, which already sets `noexpandtab tabstop=4 softtabstop=0 shiftwidth=0` —
tabs, four columns wide. That matches what Godot's own editor writes (`text_editor/behavior/indent`
defaults to tabs at size 4) and what the GDScript style guide recommends. This module does not fight
it. If you would rather have spaces, `indent = 4` opts in through a `FileType` hook that runs after
the ftplugin, in this plugin's buffers only. Setting `vim.g.gdscript_recommended_style = 0` is the
other way to take the options over, and `indent` does not need it.

If you have read elsewhere that "Godot expects spaces, 4 per indent" — it does not, and you do not
need a plugin to set that up.

### gdev.server

Godot's external-editor integration launches a command per clicked script. Point that command at a
Neovim that is already listening and the file opens in your session instead of in a new instance.

In Godot: **Editor Settings → Text Editor → External**

| Setting | Value |
|---|---|
| Use External Editor | on |
| Exec Path | `nvim`, or a wrapper script (see below) |
| Exec Flags | `--server /tmp/godot.nvim --remote {file}` |

and in Neovim:

```lua
require('gdev.server').setup({ address = '/tmp/godot.nvim', autostart = true })
```

The address in `Exec Flags` and the one this listens on have to be the same string.
`:lua = GdevServer.status()` prints the one in effect, and `:checkhealth gdev` prints the whole
`Exec Flags` line with it filled in, ready to paste.

Set `address` to something stable. Neovim always opens an address of its own at startup
(`v:servername`), which is what `address = nil` resolves to — but it is different every session,
which is no use in a settings file. Starting a server here *adds* a second address rather than
replacing the first.

An address containing a colon is a `host:port` pair; anything else is a Unix socket path. Only
socket paths can go stale, and only they get cleaned up: if the file exists but nothing answers on
it, it is a leftover from a Neovim that crashed and is removed. An address a *live* process answers
on is never taken over — that would silently point Godot at somebody else's session.

**Godot's `{line}` and `{col}` do not work with `--remote`.** `--remote` treats everything after
it as file names, so `--server ADDR --remote +{line} {file}` opens a buffer literally named `+3`
alongside the real one and leaves the cursor on line 1. Verified, not theoretical. Placing the
cursor needs `--remote-send`, which is what a wrapper script is for — and raising your terminal is
that wrapper's job too, since Neovim cannot do it:

```sh
#!/bin/sh
# Exec Path:  /path/to/this/script
# Exec Flags: {file} {line}
ADDR=/tmp/godot.nvim
FILE=$(cd "$(dirname "$1")" && printf '%s/%s' "$(pwd)" "$(basename "$1")")
LINE=${2:-1}

nvim --server "$ADDR" --remote "$FILE"
nvim --server "$ADDR" --remote-send "<C-\\><C-N>:$LINE<CR>zz"

# Raise the terminal. Replace with whatever your setup needs.
osascript -e 'tell application "kitty" to activate' 2>/dev/null || true
```

The absolutising is not superstition: `--remote` resolves a relative path against the *server's*
working directory, which is not necessarily the directory Godot was launched from.

### gdev.run

```vim
:GdevRunProject
:GdevRunCurrentScene
:GdevRunScene res://scenes/Main.tscn
:GdevRunPicker
```

Every command starts by walking up from the current buffer for a `project.godot`, falling back to
the working directory when the buffer has no file. That directory is what Godot is given with
`--path`. Scenes are named to the engine as `res://` paths; a `res://` path, a project-relative
path and an absolute path inside the project are all accepted, and anything resolving outside the
project is refused — including a `res://` path that climbs out with `..`. Running a scene from
another project means opening a buffer in that project first.

`:GdevRunCurrentScene` in a `.tscn` runs that scene. In a script buffer it runs the scene that
references the script, prompting through `vim.ui.select` when several do. A script attached to
nothing is an error saying so, which is usually the actual problem.

#### Console capture

Off by default, and the trade is worth knowing. With the console off, a run is **detached**: the
game outlives this Neovim and its output goes wherever a detached process' output goes. With
`console.enabled = true` the run is attached instead — `print()` and engine errors stream into a
scratch window in front of you, and quitting Neovim takes the game with it.

```lua
require('gdev.run').setup({ console = { enabled = true, renderer = 'float' } })
```

A run opens the console **without taking the cursor**, so you can keep editing and so the next
command still resolves its project from the file you are in rather than from the console. `q`
closes the window; the output survives it, and `:GdevRunConsole` brings it back and focuses it.
Only one captured run happens at a time — a second is refused rather than interleaved into the same
window. Detached runs are neither counted nor limited.

### gdev.scenetree

```vim
:GdevScenetree
:GdevScenetree res://scenes/Main.tscn
:GdevScenetreeRefresh
```

A side pane showing the node hierarchy, resolved from the buffer you are in the same way `gdev.run`
resolves a scene to run. It parses the `.tscn` file, so it answers for a scene you have never opened
in the editor and works with Godot closed.

```
Scene: res://scenes/main.tscn
> Main [Node2D]
  > Player [Sprite2D] *
    > Camera [Camera2D]
  > Hud [CanvasLayer]
    > Label [Label]
```

Inside the pane: `<CR>` jumps to the node's `[node ...]` line in the scene file, `y` yanks the node
path (what `get_node()` takes), `g` opens the attached script or the scene the node instances, `r`
reparses, `q` closes. All five are `config.mappings` and `''` turns one off — worth knowing that
`g` shadows `gg` inside the pane.

Icons are `'nerdfont'` by default and need a patched font; `'ascii'` and `false` are the fallbacks,
and a table is merged over the nerdfont set so overriding a few types keeps the rest:

```lua
require('gdev.scenetree').setup({ icons = { types = { Camera2D = '@' } } })
```

Only the icon is coloured, by the category Godot's own editor colours that node with, through
`GdevScenetreeIcon*` highlight groups.

Two things it gets right that are easy to get wrong:

- **An instanced scene shows the scene it instances**, resolved through the `[ext_resource]` table,
  rather than a useless `PackedScene` or a mangled attribute value.
- **A node whose type the file does not state has no type invented for it.** Godot records an
  override of a node inside an instance without a `type=`, and printing `[Node]` there would be a
  lie; the bracket is omitted and the icon greyed. Inherited scenes make this common.

Godot 4 quoting is required. Godot 3 `.tscn` files are not supported, and half-supporting them was
tried and removed.

### gdev.docs

```vim
:GdevDocs Node2D
:GdevDocs             " the word under the cursor
:GdevDocsBrowser AnimatedSprite2D
```

Two different sources, and it is worth knowing which is which. The `float` and `buffer` renderers
fetch the *source* of the class page — `classes/class_<name>.rst` from the `godot-docs`
repository — with `curl`, and convert its reStructuredText to Markdown: headings, code fences,
tables, and the `:ref:`/role markup cleaned out. The `browser` renderer opens the *published* page
on `docs.godotengine.org` through `vim.ui.open` and needs nothing fetched, which is why it is the
only `fallback_renderer` that can recover a failed fetch — being offline, being behind a proxy, or
naming a class that does not exist.

Both URLs are built from the symbol alone, lowercased with spaces removed, so there is no index to
download and nothing to keep in sync. `:lua = GdevDocs.get_url('Node')` shows both without
fetching.

The rendered buffer has filetype `markdown`, so a Markdown renderer such as
[render-markdown.nvim](https://github.com/MeanderingProgrammer/render-markdown.nvim) improves it
for free. Pages are cached in memory, keyed by source URL and evicted least-recently-used at
`cache.max_entries`; because the key is the whole URL, pointing `source_ref` at a `4.3` branch
re-fetches everything, which is what you want.

To read the reference offline, clone `godot-docs` and point at it — `curl` handles `file://`:

```lua
require('gdev.docs').setup({ source_base_url = 'file:///path/to/godot-docs' })
```

### gdev.health

`:checkhealth gdev` has eight sections: Godot binary and version, plugin dependencies, editor
connection (both port probes), editor server, treesitter parsers, formatter, class reference, scene
tree.

It describes **the session it runs in**, not the plugin in the abstract. A module you never set up
is reported as such rather than guessed at, so run it after your plugin manager has loaded and
configured the modules you actually use. It needs no `setup()` of its own.

## Godot editor settings worth changing

With **Advanced Settings** switched on in the Editor Settings dialog:

| Setting | Why |
|---|---|
| Text Editor → External → **Use External Editor**, **Exec Path**, **Exec Flags** | The whole external-editor workflow. See [gdev.server](#gdevserver). |
| Text Editor → Behavior → Files → **Auto Reload Scripts On External Change** | Without it, every save in Neovim greets you with a conflict dialog when the editor regains focus. |
| Interface → Editor → Behavior → **Save On Focus Loss** | Alt-tabbing to Neovim saves the editor's pending work first, so the file you open is the current one. |
| Interface → Editor → Behavior → **Import Resources When Unfocused** | Assets you add outside the editor get imported without you having to click into it. |
| Network → Language Server → **Remote Port** | Has to match `lsp.port`. Default 6005. |
| Network → Debug Adapter → **Remote Port** | Has to match `dap.port`. Default 6006 — and not the 6007 next to it under Network → Debug. |

## Using several Godot versions

`run.godot` is looked up with `executable()`, so a bare name is resolved on `$PATH` and a path is
used as given. Three ways to pin an engine per project, in increasing order of effort:

```lua
-- 1. A version manager owns the `godot` name
require('gdev.run').setup({ godot = 'godot' })

-- 2. An absolute path
require('gdev.run').setup({ godot = '/Applications/Godot4.2.app/Contents/MacOS/Godot' })

-- 3. A wrapper that picks the engine for the current project
require('gdev.run').setup({ godot = '~/bin/godot-for-project' })
```

Per project, without touching your config, set it on the buffer:

```lua
vim.b.gdevrun_config = { godot = '/opt/godot/4.2/godot' }
```

A `.nvim.lua` in the project root (with `'exrc'` on) is a good place for that.

## Hiding Godot's generated files

Godot writes `.godot/`, `.import` and `.uid` files next to yours, and they clutter a file
explorer. Both of these filter on the entry name.

**oil.nvim**

```lua
require('oil').setup({
  view_options = {
    is_hidden_file = function(name, _)
      local godot = { '^%.godot$', '^%.mono$', '%.import$', '%.uid$', '^godot.*%.tmp$' }
      for _, pattern in ipairs(godot) do
        if name:match(pattern) then return true end
      end
      return vim.startswith(name, '.')
    end,
  },
})
```

**mini.files**

```lua
require('mini.files').setup({
  content = {
    filter = function(entry)
      local godot = { '^%.godot$', '^%.mono$', '%.import$', '%.uid$', '^godot.*%.tmp$' }
      for _, pattern in ipairs(godot) do
        if entry.name:match(pattern) then return false end
      end
      return true
    end,
  },
})
```

`content.filter` is the documented hook and it works; you do not need to patch
`nvim_buf_set_lines` to make it do this.

For `:find`, `:vimgrep` and everything else that reads `'wildignore'`:

```vim
set wildignore+=.godot/**,*.import,*.uid
```

Note that `gdev.run` and `gdev.scenetree` skip dot-directories when they list scenes, so Godot's
`.godot/` cache never shows up in `:GdevRunPicker` regardless of any of this.

## What this plugin deliberately does not do

- **Windows and WSL.** No `has('win32')` branches, no `ncat` transport, no named pipes, no WSL
  bridge. A Unix-like filesystem and Unix domain sockets are assumed throughout. This is the one
  platform nobody here can test, and shipping untested code paths for it is worse than not shipping
  them.
- **C#.** Out of scope for now. The seams are in place — `script_extensions` on the three modules
  that resolve scripts, a language-registration helper in `gdev.dap`, a section registry in
  `gdev.health` — and `require('gdev').setup()` accepts a `csharp` key, reports that it is reserved,
  and does nothing with it.
- **Install anything.** No parsers, no formatters, no engines. `:checkhealth gdev` tells you what
  is missing and where to get it.
- **Require Telescope.** Pickers use `vim.ui.select`.
- **Create mappings.** Not one.
- **Set up your other plugins.** `require('dapui').setup()` is yours to call.

## Development

```sh
make test            # the whole suite, in headless child Neovim processes
make test_run        # one module
make lint            # stylua --check
make format          # stylua
make gendoc          # regenerate doc/gdev.txt from the annotations
```

Tests run in child processes against fixtures and fake executables, with no network and no Godot
binary, so they pass on a machine with neither.

While working on the plugin itself, `vim.g.gdev_dev_reload = true` — set before the plugin is
sourced — makes writing a file under `lua/gdev/` drop the whole namespace from `package.loaded` and
set every module that was set up back up with the config it is running. Off, and doing nothing, for
everyone else.

## License

MIT.
