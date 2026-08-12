# gdev.nvim — execution plan

This is the handoff plan for building gdev.nvim. It is written to be executed by independent
agents, one phase at a time, without needing the conversation that produced it.

## Mission

Build a Godot 4 development plugin for Neovim that is **feature-complete with
`.ref/godotdev.nvim`** (Mathijs-Bakker/godotdev.nvim), restructured into this project's
mini.nvim-style architecture, **excluding C# support** — but with explicit seams so C# can be
added later without restructuring (see Appendix A).

`.ref/godotdev.nvim` is the *behavioral specification*: what commands exist, what config means,
how edge cases behave. It is **not** a source to copy from — repo rule 4 forbids committing
anything derived from wholesale copying of `.ref/`. Read it to understand behavior, then
implement fresh following `.templates/` and `.doc/patterns.md`.

## Standing decisions (do not relitigate)

1. **Reuse, don't reinvent.** LSP uses Neovim's built-in `vim.lsp.config`/`vim.lsp.enable`
   against Godot's editor LSP server (no nvim-lspconfig dependency). Syntax uses Neovim's
   built-in `vim.treesitter`, with **parsers and queries supplied by the user** — not by
   nvim-treesitter, which is not a dependency (see Phase 2). Debugging uses `nvim-dap`
   (+ optional `nvim-dap-ui`) against Godot's DAP server, the one remaining plugin
   dependency. All plugin dependencies are soft: degrade with a clear `vim.notify` warning,
   never error, when one is missing.
2. **mini.nvim module architecture.** One self-contained module per feature under
   `lua/gdev/<name>.lua`, each independently `setup()`-able, following `.templates/module.lua`
   exactly (two-table `Gdev<Name>`/`H` shape, `H.get_config()` precedence, disable protocol,
   etc. — see `.doc/patterns.md`). The reference's central `setup.lua` that wires all modules
   is replaced by per-module setups plus a thin optional umbrella (Phase 10).
3. **Pickers use `vim.ui.select`**, not a hard Telescope dependency. The reference requires
   Telescope for scene pickers; we deliberately improve on this — `vim.ui.select` works
   everywhere and users with Telescope/fzf-lua get their picker via ui-select adapters. This is
   the one sanctioned deviation from parity.
4. **Share helpers rather than repeating them.** Two internal modules, neither `setup()`-able,
   both using plain `--` comments so they stay out of the generated vimdoc:

   - **`lua/gdev/util.lua`** — per-module plumbing: `error`, `notify`, `check_type`,
     `validate_buf_id`, `is_disabled`, `get_config`, `map`, bound by
     `require('gdev.util').new('<name>', Gdev<Name>)`.
   - **`lua/gdev/project.lua`** — Godot-project domain knowledge: project-root discovery,
     `res://` path conversion, scene listing, and finding the scenes that reference a script.
     Introduced in Phase 6 and consumed unchanged by Phase 7; the reference duplicates roughly
     130 lines of this across `run.lua` and `scene_tree.lua`. Kept separate from `util.lua`
     because plumbing and domain knowledge have different audiences and lifetimes.

   This overrides mini.nvim's habit of restating boilerplate per module, which only pays off for
   a plugin whose modules get copied out one at a time. Things a module might reasonably want to
   do differently (config validation, augroups, user commands, and `vim.ui.select` prompt
   wording) stay in the module.
5. **Target Neovim 0.11+, Godot 4.x** (warn below 4.3 in health), **macOS and Linux only**.
   Windows and WSL are out of scope: no `ncat` transport, no named pipes, no WSL bridge, no
   `has('win32')` branches. The reference carries all of that; we deliberately do not. This
   removes the one platform none of us can test, so assume a Unix-like filesystem, `/tmp`, and
   Unix domain sockets throughout.

## Target module map

| Module | Replaces (in `.ref/godotdev.nvim/lua/godotdev/`) | User commands | Size |
|---|---|---|---|
| `gdev.lsp` | `lsp.lua`, `reconnect_lsp.lua`, `inline_hints.lua`, `utils.lua` | `:GdevLspReconnect`, `:GdevLspToggleHints` | S |
| `gdev.dap` | `dap.lua` | — (users drive nvim-dap directly) | S |
| `gdev.treesitter` | `tree-sitter.lua` (no query files — see Phase 2) | — | S |
| `gdev.format` | `formatting.lua` | `:GdevFormat` (manual trigger; bonus over reference) | S |
| `gdev.server` | `start_editor_server.lua` | `:GdevServerStart [address]` | M |
| `gdev.run` | `run.lua`, `run_console.lua` | `:GdevRunProject`, `:GdevRunCurrentScene`, `:GdevRunScene {path}`, `:GdevRunPicker`, `:GdevRunConsole` | L |
| `gdev.scenetree` | `scene_tree.lua` (1324 lines — largest module) | `:GdevScenetree [path]`, `:GdevScenetreeRefresh` | L |
| `gdev.docs` | `docs.lua`, `docs/{common,fetch,render,rst}.lua` | `:GdevDocs [Class]`, `:GdevDocsFloat`, `:GdevDocsBuffer`, `:GdevDocsBrowser`, `:GdevDocsCursor` | L |
| `gdev.health` | `health.lua` | `:checkhealth gdev` | M |
| `gdev` (init.lua) | `setup.lua`, `init.lua` | — | S |

Naming follows `.doc/patterns.md` conventions keyed to module name: module `run` → global
`GdevRun`, augroup `GdevRun`, commands `:GdevRun...`, `vim.b.gdevrun_config`,
`vim.g.gdevrun_disable`, error prefix `(gdev.run)`.

## Cross-cutting requirements (every phase)

- Start from `.templates/module.lua` / `.templates/test_module.lua` per `.templates/README.md`.
- Tests per `.doc/testing.md`: child-process mini.test suites, the required baseline coverage
  (setup side effects, config defaults, config validation per field, per-function
  works/respects-config/validates-args/respects-`b:`-config/respects-disable), fixtures under
  `tests/dir-<name>/`.
- **No network and no real Godot binary in tests.** Every module that shells out or fetches
  must route through a seam that tests can redirect: fake executables on `$PATH` inside
  `tests/dir-<name>/bin/`, `file://` URLs via config, or fixture files. Tests must pass on a
  machine with no Godot installed.
- Public API fully annotated for mini.doc; run `make gendoc` and commit regenerated `doc/`.
- `stylua .` clean before committing.
- One module per commit, conventional commit style (`feat(run): add scene picker`), no
  co-author trailers (CLAUDE.md rules).
- Never modify or commit `.ref/`.

### Working a phase (agent checklist)

1. Read `CLAUDE.md`, `.doc/patterns.md`, `.doc/testing.md`, `.templates/README.md`.
2. Read the referenced `.ref/godotdev.nvim` files for behavior; read the matching
   `.ref/godotdev.nvim/tests/spec_*.lua` for edge cases the author considered.
3. Copy templates, implement, mirror every config field and public function in tests.
4. `make test_<module>`, `make test`, `stylua .`, `make gendoc`.
5. Single commit. Update the phase's checkbox in this file.

---

## Phase 0 — Infrastructure

**Goal:** a repo where `make test` runs a trivially-passing suite and CI enforces it.

- [x] Clone mini.nvim into `.ref/mini.nvim` (read-only reference; `.ref/` is gitignored):
      `git clone --filter=blob:none https://github.com/nvim-mini/mini.nvim .ref/mini.nvim`.
      `.doc/patterns.md` and `.doc/testing.md` cite files inside it.
- [x] `scripts/minimal_init.lua` and `Makefile` exactly as specified in `.doc/testing.md`
      (`test`, `test_%`, `deps/mini.nvim`, `gendoc` targets).
- [x] `tests/helpers.lua` copied from `.templates/tests_helpers.lua`.
- [x] GitHub Actions workflow: matrix {ubuntu, macos} × Neovim {stable, nightly}; jobs for
      `make test` and a stylua check (`stylua --check .`).
- [x] Initial commit(s) of the existing scaffolding (`.gitignore`, `.stylua.toml`,
      `.templates/`, `CLAUDE.md`) if not already committed.

**Acceptance:** `make test` exits 0 locally (zero test files is fine if the runner tolerates
it; otherwise add a placeholder suite that Phase 1 replaces). CI green.

**Phase 0 outcome (done).** Notes for later phases:

- `MiniTest.run()` returns *without quitting* when it collects zero cases, so headless Neovim
  hangs instead of exiting 0. `tests/test_infrastructure.lua` therefore exists as a permanent
  smoke suite (child spawns, project root on `rtp`, `gdev.*` resolves, appearance pinned for
  screenshots, helpers work). Keep at least one collectable suite at all times; don't delete it
  in Phase 1.
- `make lint` / `make format` wrap stylua. stylua honors `.gitignore`, so vendored Lua under
  `.ref/` and `deps/` is skipped automatically — no `.styluaignore` needed.
- CI has a third job beyond the two the plan asked for: `lint-gendoc` regenerates docs and fails
  if `doc/` differs from what's committed. This mechanically enforces the cross-cutting
  "run `make gendoc` and commit" rule, so **every** phase must commit regenerated docs.
- `doc/gdev.txt` is committed as a modeline-only stub (mini.doc's honest output for an empty
  `lua/`). Phase 1 is the first phase to give it real content.
- Local `stylua` is 2.5.2 and CI pins the same version; bump both together.
- `deps/` is created by the Makefile and gitignored; `make clean-deps` removes it.

## Phase 1 — `gdev.lsp`

**Goal:** open a `.gd` file, get a working LSP session against a running Godot editor.
**Behavior spec:** `lsp.lua`, `reconnect_lsp.lua`, `inline_hints.lua`, `utils.lua`.

Config (defaults): `host = '127.0.0.1'`, `port = 6005`, `inlay_hints = false`.

- Register via `vim.lsp.config['gdscript']` + `vim.lsp.enable('gdscript')`: name
  `godot_editor`, filetypes `{ 'gd', 'gdscript', 'gdshader', 'gdscript3' }`, root markers
  `{ 'project.godot', '.git' }`.
- Transport: `vim.lsp.rpc.connect(host, port)`.
- Capabilities tweak: drop `textDocument.typeDefinition` (Godot advertises it but errors).
- `on_attach`: suppress the `window/showMessage` spam `Method not found: godot/reloadScript`
  by wrapping the client handler (reference: `utils.lua`); enable buffer inlay hints when
  `inlay_hints` is set and the client supports `textDocument/inlayHint`.
- `:GdevLspReconnect`: re-`:edit` every loaded buffer with filetype
  gdscript/gdresource/gdshader to retrigger attach.
- `:GdevLspToggleHints`: toggle `vim.lsp.inlay_hint` for current buffer; graceful message if
  the API or server support is missing.

**Tests:** config validation; commands exist; reconnect walks only Godot buffers (fixture
buffers with mixed filetypes); hint toggle no-ops gracefully. No live server needed — assert
registration state (`vim.lsp.config.gdscript`) rather than a live session.

**Phase 1 outcome (done).** Three points above did not survive contact with Neovim 0.11+, and the
module implements the *intent* instead. Later phases should assume the corrected facts:

- **`capabilities.textDocument.typeDefinition = nil` is a no-op.** Client capabilities are
  deep-merged over `vim.lsp.protocol.make_client_capabilities()` (`vim/lsp/client.lua`), so a key
  removed from the passed table is restored by the merge. What actually stops the request being
  routed to Godot is clearing the *server* flag in `on_attach`:
  `client.server_capabilities.typeDefinitionProvider = nil`, since `Client:supports_method()`
  consults `server_capabilities`. Implemented that way.
- **`name = 'godot_editor'` inside the config is ignored.** `vim.lsp.config`'s resolver forcibly
  assigns `resolved_config.name = <config key>`, so clients report as `gdscript`. Keeping the
  `gdscript` key was chosen over the nicer name because sharing the key with nvim-lspconfig's
  `gdscript` config is what prevents a second client attaching to the same buffer.
- **`reconnect()` does not `:edit`.** Re-running `vim.lsp.enable()` is Neovim's own path for
  activating a server in already-open buffers (it replays the `FileType` hook via `doautoall`), so
  no buffer is reloaded — unsaved changes, undo history and cursor survive, and there is no `E37`
  on modified buffers. A test asserts contents are untouched.
- Message suppression is declared as `handlers['window/showMessage']` in the config rather than
  patched onto `client.handlers` in `on_attach`, which makes re-`setup()` idempotent instead of
  stacking one filter per call.
- `H.get_config(config, buf_id)` takes an optional buffer: LSP callbacks run for buffers that are
  not current, so `vim.b.gdevlsp_config` has to be read off the target buffer. Modules with
  event-driven entry points should use the same two-argument shape.
- Fixtures live in `tests/dir-lsp/` (`project.godot`, `script.gd`). Fake clients and `vim.lsp`
  stubs are built inside the child (functions cannot cross the RPC boundary), and whole-config
  reads like `child.lua_get('vim.lsp.config.gdscript')` fail for the same reason — fetch fields
  individually.

**Also fixed in this phase (infrastructure, separate commit).** `scripts/minimal_init.lua` was not
hermetic: `--noplugin` leaves this machine's Neovim config on 'runtimepath', so a locally installed
mini.nvim shadowed `deps/mini.nvim` and local runs tested a different version than CI. It now
strips user directories, clears 'packpath', and prepends `deps/mini.nvim`. `make gendoc` also had
to start calling `require('mini.doc').setup()` before `generate()`, or every `---@eval` config block
errors on a nil `MiniDoc` global. Both are guarded in `tests/test_infrastructure.lua`.

## Phase 2 — `gdev.treesitter`

**Goal:** correct filetypes and syntax for `.gd`/`.gdshader`/`.gdresource`.
**Behavior spec:** `tree-sitter.lua`, `queries/gdshader/`.

Config: `auto_setup = true`, `ensure_installed = { 'gdscript', 'gdshader' }`.

- `vim.filetype.add` for `gdshader` extension (Neovim detects `.gd`/`.tscn`/`.gdresource`
  natively — verify, only add what's missing).
- When `auto_setup` and nvim-treesitter is present, ensure parsers installed + highlight
  enabled; silently skip when absent or `auto_setup = false`.
- Queries: rely on nvim-treesitter's upstream gdshader queries first. Only if highlighting has
  real gaps, author supplemental `queries/gdshader/*.scm` **from the tree-sitter-gdshader
  grammar** — do not copy the reference's query files (rule 4).

**Tests:** filetype detection for fixture files; `auto_setup = false` leaves treesitter
untouched; setup without nvim-treesitter installed does not error.

**Phase 2 outcome (done).** The approach above was replaced: **nvim-treesitter is not a
dependency at all.** The module drives Neovim's built-in `vim.treesitter`, and parsers plus
queries are the user's to provide (this project's author installs them with a `tree-sitter`
CLI script into `stdpath('data')/site/{parser,queries}`). Consequences:

- **Config is `highlight = true`, `fold = false`.** `auto_setup` and `ensure_installed` are
  gone: there is nothing to auto-configure and nothing this module can install. Neovim ships
  no parser installer.
- **Parser resolution is a real problem the plan missed.** The `gdresource` grammar is
  published under two names — `godot_resource` by nvim-treesitter, `gdresource` when built
  straight from the grammar repo. `H.lang_candidates` tries both, and the winner is passed to
  `vim.treesitter.language.register()` so `get_parser()`, `foldexpr()` and `:InspectTree`
  resolve it too. An existing registration by the user wins over both candidates.
- `vim.treesitter.language.add(lang)` is the documented parser probe: it returns `true`/`nil`
  rather than raising, and caches, so calling it per buffer is cheap. `vim.treesitter.start()`
  *does* raise when the parser is missing — pcall it.
- **Starting highlighting twice is not idempotent.** `highlighter.new()` overwrites the
  registry entry without destroying the previous highlighter, leaving it attached to the
  parser. Guarded by checking `vim.treesitter.highlighter.active[buf]`, which also detects
  highlighting somebody else started. There is no public predicate for this.
- `setup()` attaches already-loaded Godot buffers, because a lazy-loaded setup runs after the
  first Godot file is open and those buffers never see `FileType`.
- `GdevTreesitter.parser_status()` exists for Phase 9: it reports, per Godot filetype, the
  parser in use or the one to install. It deliberately keeps working while the module is
  disabled, since that is when it gets asked.
- Filetypes added: `.gdshaderinc` → `gdshader`, `project.godot` → `gdresource`. Generated files
  (`.import`, `.escn`) are left alone — `.import` is too broad an extension to claim globally.
- No query files are shipped. The user's pipeline fetches queries alongside parsers, and a
  parser with no `highlights.scm` loads fine while highlighting nothing — a failure mode worth
  knowing about when a Godot file looks unhighlighted.

**Two findings for later phases:**

- **Phase 4 must not blindly force spaces.** Neovim bundles `ftplugin/gdscript.vim`, which sets
  `noexpandtab tabstop=4 softtabstop=0 shiftwidth=0` unless `g:gdscript_recommended_style = 0`
  — tabs, matching Godot's own editor default. The reference plugin claims Godot wants 4
  spaces and forces `expandtab`, which fights the bundled ftplugin. Decide deliberately and
  document it; do not just copy the reference.
- That same ftplugin sets an indent-based `foldexpr`, so `fold = true` here *replaces* working
  folding rather than adding it. Hence the default of `false`.

**Test note.** A Godot parser cannot be faked: the loader looks for a `tree_sitter_<lang>`
symbol, so renaming a bundled parser to `gdshader.so` fails to load. Positive paths stub
`vim.treesitter`; negative paths run unstubbed against a runtime that genuinely has no Godot
parser. Also, Neovim's own ftplugins for `help`, `lua`, `markdown` and `query` call
`vim.treesitter.start()` with no arguments, so a stub that records calls must filter to the
ones this module makes (which always pass a buffer and language) or it will catch Neovim's.

## Phase 3 — `gdev.dap`

**Goal:** `:DapContinue` in a `.gd` buffer launches/debugs the current scene via Godot's DAP.
**Behavior spec:** `dap.lua`.

Config: `host = '127.0.0.1'`, `port = 6006`, `dapui = true`, `configurations = nil`
(user override for `dap.configurations.gdscript`).

- Register `dap.adapters.godot = { type = 'server', host, port }` and a default
  `dap.configurations.gdscript` "Launch scene" entry (`project = '${workspaceFolder}'`,
  `launch_scene = true`).
- If `nvim-dap` missing: warn once, return. If `nvim-dap-ui` present and `dapui`: wire
  open/close listeners (initialized → open; terminated/exited → close) under a namespaced
  listener key so re-`setup()` doesn't stack.
- **C# seam:** implement registration as `H.register_language(ft, adapter_name, adapter,
  configurations)` so a future C# module/phase adds `coreclr`/`cs` without touching this
  module's public surface.

**Tests:** adapter/config tables land in nvim-dap (add nvim-dap under `deps/` in the Makefile
as a test dependency); missing-dap path warns and doesn't error; `configurations` override
respected; re-setup idempotent.

**Phase 3 outcome (done).** Config is `host`, `port`, `dapui`, `configurations`. Notes:

- **No `vim.b.gdevdap_config`.** Every field is consumed during `setup()` and never read again, so
  a buffer-local override would do nothing — a debug session belongs to a project, not a buffer.
  The header says so rather than advertising a knob that does not exist. This is the one template
  element that does not instantiate here.
- **`dapui.setup()` is deliberately not called.** The reference calls it unconditionally, which
  silently replaces whatever configuration the user gave nvim-dap-ui. Only listeners are wired.
- The disable protocol is **asymmetric on purpose**: it suppresses opening the UI panel but never
  closing it, so an ending session cannot strand a panel this module opened.
- `dapui = false` *unwires* previously registered listeners rather than merely skipping them, per
  patterns.md's rule that `apply_config` undoes stale side effects.
- Configurations are deep-copied into nvim-dap so later edits to `GdevDap.config` cannot reach it
  behind the user's back.
- C# seam is `H.register_language(filetype, adapter_name, adapter, configurations)`; the caller
  words its own missing-nvim-dap warning.
- `deps/nvim-dap` is a Makefile test dependency but is deliberately **not** added to
  `scripts/minimal_init.lua`. Tests opt in per child with `set rtp+=deps/nvim-dap`, which leaves
  the "nvim-dap is not installed" path testable for free.

**Infrastructure fix from this phase.** `make gendoc` now passes an explicit `'doc/gdev.txt'`
output path. mini.doc otherwise derives the filename from the working directory's basename, so
generating inside a git worktree wrote `doc/<worktree-name>.txt` and then failed with
`E154: Duplicate tag`. Anyone running phases in worktrees needs this.

## Phase 4 — `gdev.format`

**Goal:** `.gd` files autoformat on save; correct indent defaults.
**Behavior spec:** `formatting.lua`.

Config: `formatter = 'gdscript-formatter'` (`'gdscript-formatter' | 'gdformat' | false`),
`command = nil` (string or argv list override; default gdscript-formatter argv appends
`--reorder-code`), `autoformat = true`.

- `BufWritePost *.gd` → run formatter argv + filename via `vim.system`; on success
  `checktime` the buffer; on failure notify stderr/stdout. Missing executable → single WARN
  pointing at `:checkhealth gdev`.
- `:GdevFormat` formats current buffer on demand (works even when `autoformat = false`).
- Set buffer-local indent options for gdscript filetype (4-wide indent, matching the
  reference's documented behavior); make it a config field (`indent = 4` or `false`) so users
  who prefer tabs can opt out.

**Tests:** fake formatter scripts in `tests/dir-format/bin/` (prepend to `$PATH` in child):
one that rewrites the file, one that fails with stderr; assert buffer reload, error notify,
argv construction (string vs list vs default `--reorder-code`), `formatter = false` disables,
disable protocol respected.

**Phase 4 outcome (done).** Config is `formatter`, `command`, `autoformat`, `indent`. Public API
is `GdevFormat.format(buf_id, opts)` and `GdevFormat.get_command(buf_id, opts)`. Notes:

- **`indent = false` by default; the module touches no indent option.** Two corrections to the
  spec above. First, Neovim bundles `ftplugin/gdscript.vim`, which already sets
  `noexpandtab tabstop=4 softtabstop=0 shiftwidth=0` under `g:gdscript_recommended_style`.
  Second, **the reference never implemented the 4-space indent it documents** — grepping all of
  `.ref/godotdev.nvim` for `expandtab|shiftwidth|tabstop|softtabstop` returns nothing outside
  `swapfile` lines, while its README and vimdoc both claim the plugin sets buffer options. There
  was no parity to keep. `indent = N` opts into `expandtab` at width N via a `FileType`
  autocommand registered during `setup()`, i.e. after the ftplugin, so it wins either way.
- The on-save hook filters by **filetype**, not a `*.gd` path pattern.
- Missing executable warns once per executable name, and that cache resets on `setup()`.
- `get_command()` returns the resolved argv minus the file path and keeps working while the
  module is disabled — the query contract Phase 9 consumes.

**Test-environment facts worth reusing:**

- `:enew` on an empty unnamed buffer **reuses the same buffer number and drops its buffer-local
  variables**. To put a `b:` var on a non-current buffer, use `nvim_create_buf`.
- `vim.system` passes argv[0] to a `#!` script as the PATH-resolved absolute path, not the name
  invoked, so fake executables should log `${0##*/}`.
- `vim.wait(timeout, cond)` in a child pumps the loop far enough to run `vim.system` callbacks
  and their `vim.schedule` bodies, so async modules need no sleeps. Scale with
  `helpers.get_time_const()`.

## Phase 5 — `gdev.server`

**Goal:** Godot's "external editor" integration can open files in this Neovim instance.
**Behavior spec:** `start_editor_server.lua`.

Config: `address = nil` (nil → `v:servername` if listening, else `/tmp/godot.nvim`),
`autostart = false`, `remove_stale_socket = true`.

- `:GdevServerStart [address]` starts `vim.fn.serverstart` on the resolved address; if a
  server is already listening on the target, INFO and reuse; if listening elsewhere, WARN and
  skip.
- Stale-socket recovery (socket-path addresses only, not `host:port`): if the socket file exists
  but `sockconnect` fails, unlink it before starting; notify what was removed.
- `autostart = true`: attempt start during `setup()` and on `BufReadPost *.gd` (extension
  list configurable — C# seam).

**Tests:** address resolution matrix (explicit > servername > default); stale-socket cleanup
using a dead socket file fixture; already-running short-circuit; autostart autocmd presence.

**Phase 5 outcome (done).** Config is `address`, `autostart`, `remove_stale_socket`, `filetypes`
(the C# seam — add `'cs'`). Public API is `GdevServer.start(address)` and `GdevServer.status()`.
The spec above was wrong in one load-bearing way:

- **`vim.v.servername` is never empty.** Neovim opens an address at startup regardless — verified
  under `--clean --headless` and even `--listen ''`. So "if listening elsewhere, WARN and skip"
  would have refused every configured address and made the module a permanent no-op. What is
  implemented instead: `config.address` outranks the startup address, and starting *adds* a
  second listen address (Neovim supports several at once — verified). Warn-and-skip is kept where
  it is real: when **another process** already answers on the target, which would otherwise
  silently point Godot at someone else's session.
- Resolution and the "am I listening?" check go through **`vim.fn.serverlist()`**, never
  `vim.v.servername`, which Neovim's own docs define as merely the first entry of that list.
  `serverlist()` is also correct when several addresses are open.
- **The reference's `start_editor_server.lua` is dead code on modern Neovim** for this same
  reason: it resolves `v:servername` before the configured address, so it always reports "already
  running" and never reaches its own stale-socket or `serverstart` paths.
- **Neovim 0.12 already recovers stale sockets itself** (probe, "Removing stale socket", retry).
  `remove_stale_socket` still earns its place on 0.11, the project minimum, and adds a
  notification and an off switch — but it cannot suppress Neovim 0.12's own recovery.
- The `/tmp/godot.nvim` fallback is effectively unreachable, since the startup-address rung always
  resolves first. Kept and documented rather than removed.
- `vim.tbl_deep_extend` **already replaces list-like tables wholesale** rather than merging them
  index-wise (0.11 and 0.12 alike), so config lists such as `filetypes` need no special handling.
  Mutation testing found the special case written for this was dead code, and it was deleted.

**For Phase 10 docs:** the working Godot setup is Editor Settings → Text Editor → External → Use
External Editor, `Exec Path` = `nvim` or a wrapper, `Exec Flags` = `--server <address> --remote
{file}`. Godot's `{line}` / `{col}` do **not** work with `--remote` — it opens a buffer literally
named `+3`. Cursor placement needs `--remote-send` or `nvr`, which is the wrapper's job (as is
raising the terminal).

## Phase 6 — `gdev.run`

**Goal:** run project/scenes from Neovim, with optional captured console output.
**Behavior spec:** `run.lua` + `run_console.lua` (fold both into one module — console is
run-output presentation, not a standalone feature).

Config: `godot = 'godot'` (executable path), and
`console = { enabled = false, renderer = 'buffer'|'float', buffer = { position =
'bottom'|'right'|'current', size = 0.3 }, float = { width = 0.8, height = 0.25, border =
'rounded' } }`.

- Project root: upward search for `project.godot` from current file (fall back to cwd).
- Scene path normalization: accept `res://…`, project-relative, or absolute-inside-project;
  reject paths outside the project. Launch as `godot --path <root> [res://scene]`.
- `:GdevRunCurrentScene`: from a `.tscn` run it directly; from a script buffer, scan project
  `.tscn` files for ones referencing the script — one match runs, multiple prompt via
  `vim.ui.select`. Script extensions configurable, default `{ 'gd' }` (**C# seam**: adding
  `'cs'` later is a one-line default change).
- `:GdevRunPicker`: `vim.ui.select` over all project scenes (sorted).
- Launch: detached `vim.system` when console off (notify stderr on nonzero exit); when
  `console.enabled`, run attached, stream stdout/stderr into a scratch window (split or
  float per renderer), `q` closes, one active captured run at a time (warn on second),
  `:GdevRunConsole` reopens the last console.
- Missing `godot` executable → actionable error (PATH / `godot` config / version-manager
  wrapper), same content as reference.

**Tests:** fixture Godot project under `tests/dir-run/project/` (a `project.godot`, a couple
of `.tscn` files, scripts attached); fake `godot` script capturing argv to a file; assert
root discovery, `res://` normalization (incl. rejection outside project), scene-for-script
matching (0/1/many), console buffer contents and single-run guard, disable protocol.

**Phase 6 outcome (done).** Shipped as two commits: `lua/gdev/project.lua` (shared, internal)
and `lua/gdev/run.lua`.

### `gdev.project` — the API Phase 7 consumes unchanged

Two rules shape it: **the root is always an argument**, so a command resolves it once and every
later answer is consistent; and **nothing prompts, notifies or raises** — pickers and wording
belong to the modules.

| Function | Contract |
|---|---|
| `find_root(path)` | Directory holding `project.godot` above `path`, else `nil`. File or directory; `nil`/`''` starts at cwd. **Absolute and normalized**, so `==` comparisons work. |
| `to_res(root, path)` | `path` as a `res://` name, else `nil` when outside `root`. Accepts absolute, root-relative or `res://` — the last is **re-resolved, not trusted**. `root` itself → `'res://'`. File need not exist. |
| `to_path(root, res)` | Inverse. `nil` unless `res` resolves inside `root`. Exists **for Phase 7** (reading `.tscn`, opening attached scripts); tested, but `run` has no consumer. |
| `list_scenes(root)` | Every `.tscn` as sorted `res://` names. Skips dot-directories, so Godot's `.godot/` cache is ignored. |
| `scenes_with_script(root, script)` | Sorted `res://` names of scenes referencing `script`. `{}` means both "unused" and "outside the project" — call `to_res` first if you must tell them apart. |
| `is_scene(path)` | Ends in `.tscn`. |
| `is_script(path, extensions)` | Bare dotless extensions; `nil` → `{ 'gd' }`. **The C# seam** — every script-driven entry point routes through here. |

Two traps it encodes: script matching needs the **quoted** `res://` name, or `res://player.gd`
also matches a scene referencing `res://player.gdshader`; and `find_root` must return absolute,
because `vim.fs.find()` answers in the shape it was asked and a relative root silently fails
every containment check against buffer names.

### `gdev.run`

Config `godot`, `script_extensions`, `console = { enabled, renderer, buffer = { position, size },
float = { width, height, border } }`; fractions validate within `(0, 1]`. Public: `run_project`,
`run_current_scene`, `run_scene`, `pick_scene`, `show_console`, and the query
`status(opts)` → `{ root, godot, executable }` for Phase 9.

**Where the spec was wrong:**

- **`:GdevRunCurrentScene` cannot reject a scene outside the project.** The root is found by
  walking up from that very buffer, so `to_res` can never fail there. Both guards written to the
  spec were dead code and were deleted; only `run_scene {path}` has a reachable rejection.
- **The reference's focus-stealing console is a bug.** With the console focused, the *next*
  command resolves its project from `gdev://run-console`. A run now opens the console **without
  taking the cursor**; `:GdevRunConsole` focuses deliberately.
- **`res://` pass-through is unsafe.** The reference returns any `res://` string verbatim, so
  `res://../elsewhere.tscn` escapes the project. Ours re-resolves and rejects.
- `vim.system` **raises synchronously on ENOENT**, so the `executable()` probe is load-bearing,
  not cosmetic.

**For Phase 7:** a scene-tree pane is a `nofile` buffer, so it hits the same trap the console did
— copy the `buftype ~= ''` guard before resolving a project from the current buffer. There is no
"outside the project" error path for the current-buffer route, for the reason above; don't write
one. Build your own `tests/dir-scenetree/`; `dir-run/` is shaped around run's cases.
`child.expect_screenshot()` is still unused, so Phase 7 is its first deliberate use.

**Also fixed in this phase (infrastructure).** Emptying `'packpath'` in
`scripts/minimal_init.lua` — added during Phase 1's hermeticity work — hid Neovim's own bundled
packages, so every child failed startup with `E919 ... pack/*/opt/netrw`. An erroring child does
not exit cleanly, so mini.test's one-second `jobwait` on teardown timed out **once per case**:
1047ms per restart against 26ms, and the whole suite went from 361s to 14s. Nothing caught it
because nothing was broken — the tests passed, only slowly. Filtering `'runtimepath'` is what
actually provides hermeticity. `tests/test_infrastructure.lua` now asserts the child starts with
an empty `v:errmsg`.

## Phase 7 — `gdev.scenetree`

**Goal:** static scene-tree pane for the current scene. Largest single module; budget
accordingly.
**Behavior spec:** `scene_tree.lua`. Read its test file `spec_scene_tree.lua` closely —
the `.tscn` parser has many edge cases (instanced scenes, ext_resource scripts, node
type/parent resolution).

Config: `buffer = { position = 'left'|'right', size = 0.35 }`,
`icons = 'nerdfont'|'ascii'|false|table` (table: `generic`, `script_suffix`, `types = {}`),
`icon_colors = { generic = …, groups = { White/Grey/Blue/Red/Green/Purple/Yellow } }`.

- Parse `[node …]` blocks from `.tscn`: name, type, parent path, attached script via
  `ext_resource`; build the tree; render with per-type icons (Godot's node-color categories)
  and icon-only highlighting via `GdevScenetreeIcon<Group>` groups (created `default = true`,
  reapplied on ColorScheme, per patterns.md).
- `:GdevScenetree [path]` resolves scene like `run` does (current `.tscn`, or scenes
  attached to current script with `vim.ui.select` on multiple); `:GdevScenetreeRefresh`
  reparses. **Use `lua/gdev/project.lua` for root discovery, `res://` conversion and
  scene-for-script lookup** — Phase 6 built it to be consumed here unchanged. Do not
  reimplement it, and do not copy the reference's duplicated copies.
- Pane keymaps: `<CR>` jump to node's `[node …]` line in the `.tscn`, `y` yank node path,
  `g` open attached script, `r` refresh, `q` close.

**Tests:** parser unit tests over fixture `.tscn` files (flat, nested, instanced,
scripted); rendering via `child.expect_screenshot()` for icons/highlights (commit reference
screenshots); keymap behaviors (jump target line, yanked register content, script open);
config matrix for position/size/icons via `parametrize`.

**Phase 7 outcome (done).** Config adds `mappings` (the plan pinned the keys, but `g` shadows
`gg` inside the pane, so an off switch is not optional) and `script_extensions` (the C# seam).
Public API: `open`, `refresh`, `close`, `jump_to_node`, `yank_node_path`, `open_script`, plus the
pure queries `get_nodes(scene)` and `status(opts)`.

**`gdev.project` held up as a shared dependency** — consumed unchanged, nothing missing, nothing
worked around, and `to_path()` finally has its consumer. That validates the Phase 6 split. One
case the contract does not cover was solved locally, correctly: a focused pane is a `nofile`
buffer but still needs a project, so the module remembers the pane's own root and falls back to
`Project.find_root()` otherwise. That is pane state, so it belongs in the module.

**Where the reference is wrong (verified independently):**

- **Its parser mis-reads every instanced scene.** `parse_attributes` matches bare values with
  `[^%s"%]]+`, which excludes `"`, so `instance=ExtResource("2_abc")` yields
  `instance = 'ExtResource('` and that string becomes the node's type. Reproduced directly
  against the reference's own pattern. Ours resolves the id against the `[ext_resource]` table
  and shows the instanced scene rather than a useless `PackedScene`.
- **`type` is not always knowable, and defaulting it to `Node` is a lie.** A node overriding a
  property inside an instance (`[node name="Camera" parent="Hero" index="0"]`) carries no type in
  that file; the reference prints `[Node]`. Ours omits the bracket and greys the icon. Inherited
  scenes make this common.
- **`script = ExtResource(...)` must be word-anchored**, or an exported property such as
  `death_script = ExtResource("1")` marks the node as scripted. Fixed with a `%f[%w_]` frontier.
- Godot 3 tolerance was attempted and then removed: Godot 3 also writes `id=1` unquoted in the
  `[ext_resource]` header, which the attribute parser never records, so half-tolerance could not
  work. Godot 4 quoting is required.

### Screenshot infrastructure — usable, with one rule

**Isolate the window under test** (`:only`, or a float over an empty buffer). A first attempt left
the scene file visible beside the pane, and the reference then captured Neovim's *bundled*
`gdresource` syntax highlighting — a runtime file that can differ across 0.11.7 / stable /
nightly, i.e. a CI failure unrelated to the code. Isolated, the captured surface is just the
pinned colorscheme, the pinned statusline and the module's own highlights.

The screenshot earned its place: one mutation ("window options not set") was caught **only** by
the screenshot, via a missing `cursorline` attribute. One reference is committed, `icons =
'ascii'`, 12×44.

**For Phase 8:** attribute symbols are assigned in order of appearance, so they are stable as long
as the *grouping* is — two highlight groups that collide under mini.hues silently merge, worth
checking when a screenshot is meant to prove colours differ (`PreProc` and `DiagnosticInfo` are
the same blue there, which is why purple links to `Constant`). For float geometry,
`nvim_win_get_config` remains the sharper tool: screenshot the border and content, assert
geometry through the API.

**Operational warning:** a mutation that stops the pane taking the cursor *hangs* the suite rather
than failing it — `type_keys('r')` then lands in a `.tscn` buffer where `r` waits for a character
and blocks the child. Nothing shipped triggers it, but a hung CI job is worse than a failed one;
keep it in mind if pane focus is ever changed.

**For Phase 9:** `GdevScenetree.status()` → `{ root, scene, open, icons }`, pure and disabled-safe.
`icons` is the *resolved* style, so health can warn that `'nerdfont'` needs a patched font.

## Phase 8 — `gdev.docs`

**Goal:** Godot class reference inside Neovim.
**Behavior spec:** `docs.lua`, `docs/{common,fetch,rst,render}.lua` (fold into one module).

Config: `renderer = 'float'` (`'float'|'buffer'|'browser'`), `fallback_renderer = 'browser'`
(only fallback that recovers fetch failures), `missing_symbol_feedback = 'message'|'notify'`,
`version = 'stable'`, `language = 'en'`, `source_ref = 'master'`, `source_base_url = nil`,
`timeout_ms = 10000`, `cache = { enabled = true, max_entries = 64 }`,
`float = { width = 0.8, height = 0.8, border = 'rounded' }`,
`buffer = { position = 'right'|'bottom'|'current', size = 0.4 }`.

- Symbol resolution: command arg, else `<cword>` (that's `:GdevDocsCursor` / bare
  `:GdevDocs`); map symbol → class slug → godot-docs `classes/class_<slug>.rst` raw URL on
  `source_base_url or raw.githubusercontent.com/godotengine/godot-docs/<source_ref>`.
- Fetch with `curl` via `vim.system` (async, timeout); convert the Sphinx `.rst` class page
  to markdown (headings, code blocks, tables, `:ref:`/role cleanup — port behavior from
  `docs/rst.lua`, verify against `spec_docs_render.lua` cases); render in float or reusable
  scratch buffer (`markdown` filetype, `q` to close) or open the website in the browser.
- In-memory LRU cache of fetched/rendered pages.
- Unknown symbol → message/notify per config; fetch failure → fallback renderer.

**Tests:** rst→markdown conversion is the test surface with the highest value — pure
function, many fixture cases under `tests/dir-docs/`. Fetch path tested with
`source_base_url = 'file://…/tests/dir-docs/site'` (curl supports `file://`) plus a
failing-URL case driving the browser fallback (browser opener stubbed). Cache eviction at
`max_entries`. Renderer geometry via screenshots.

**Phase 8 outcome (done).** Two commits: `lua/gdev/rst.lua` and `lua/gdev/docs.lua`.

**The rst converter lives in `lua/gdev/rst.lua`** — internal, own suite, following the
`gdev.project` precedent — rather than on the public table. `.doc/testing.md` forbids tests
reaching into `H`, and the conversion is a heuristic reading aid for Godot's rst dialect whose
exact whitespace output will keep changing; publishing it would freeze that as API. It has one
consumer today, which is the honest cost.

**Where the reference is wrong (verified independently):**

- **Its converter never detects a single heading.** The underline test is
  `next_line:match('^([=~%^"%-])%1+$')`, and a Lua back-reference cannot be quantified. Run
  directly against the reference's own pattern, `====`, `----`, `~~~~`, `^^^^` and even `=+` all
  return `nil` — it matches nothing at all, at both call sites. Every class title and every
  `Description` / `Properties` / `Method Descriptions` heading falls through into a paragraph.
  Ours uses `vim.pesc(marker)` plus a length check.
- **`spec_docs_render.lua` is not a spec of the conversion.** It holds eight renderer-dispatch
  cases; `grep -rl 'to_markdown' .ref/godotdev.nvim/tests/` returns nothing. The reference's
  converter has no tests at all, so the plan's "verify against `spec_docs_render.lua` cases" was
  not achievable — the suite was written from behavior plus real class-page structure.
- Its final `gsub('\n[ \t]+', '\n')` strips indentation from *every* line including fenced code,
  and `consume_indented_block(..., '   ')` hardcodes 3 spaces where Godot writes 4 — so its code
  fences come out empty and the code leaks into a paragraph.
- `--max-time` takes **seconds**; the reference passes `timeout_ms` verbatim, a ~3-hour timeout.
- `vim.ui.open` failure is `nil, err`; the reference tests `ok == false`, which never happens.
- **Not reproduced:** the reference's HTML-page verification and `classes/index.html` scrape.
  Slug-only URL construction is correct (`class_animatedsprite2d.rst` really is the file name)
  and removes two network round-trips per lookup.

**Screenshots worked here too**, and killed two mutations nothing else caught ("float positioned
at the top-left" and "window options not applied"). Two rules made it safe, extending Phase 7's:
capture only stable content (the `Docs: https://...` header, not a `file://` fixture path that
would make the reference machine-specific), and pass `ignore_attr = true` when the buffer has a
`filetype` — `markdown` pulls in Neovim's bundled highlighting, the exact runtime file Phase 7 got
burned by. Geometry, border and title are asserted through `nvim_win_get_config()`.

**Version note:** Neovim 0.12.4 no longer rejects a float `title` without a border, so the guard
against that is insurance for 0.11 — which CI covers and this machine does not.

## Phase 9 — `gdev.health`

**Goal:** `:checkhealth gdev` diagnoses the whole environment.
**Behavior spec:** `health.lua`.

- Structural note: checkhealth requires `lua/gdev/health.lua` exporting `check()`; it is
  read-only (no `setup()` needed) and reads other modules' state via their globals
  (`_G.GdevLsp` etc.) when present, falling back to defaults. Document this sanctioned
  deviation from the module template in the module header.
- **Query functions to consume** (each is pure, side-effect free, and deliberately keeps working
  while its module is disabled — that is when health gets asked):
  `GdevTreesitter.parser_status()` → per-filetype parser and whether it is installed;
  `GdevServer.status()` → `{ address, listening }`; `GdevFormat.get_command()` → resolved argv
  whose `[1]` is the executable to probe. `gdev.dap` has none by design — read
  `_G.GdevDap.config.port` and `pcall(require, 'dap')` directly.
- Sections (mirror reference): Godot binary + version (warn < 4.3); plugin deps
  (nvim-dap, nvim-dap-ui) as warnings not errors; treesitter parsers via
  `GdevTreesitter.parser_status()` (warn per missing parser, with the name to install, since
  nvim-treesitter is not a dependency — see Phase 2); editor LSP port probe and
  DAP port probe (`nc -z`, skip gracefully when absent); editor server target + listening state;
  docs renderer/source + `curl` presence; formatter executable presence with install pointers.
- **C# seam:** build sections as an internal registry list so a C# section can be appended
  later.

**Tests:** run `check()` in child with stubbed executables/ports and assert report lines
(mini.test can capture `vim.health` output; see how mini.nvim tests health or assert via
`health.report_*` interception).

**Phase 9 outcome (done).** Eight sections, built as an ordered `{ title, check }` registry so a C#
section is one appended entry: Godot binary and version, plugin dependencies, editor connection
(LSP and DAP port probes), editor server, treesitter parsers, formatter, class reference, scene
tree. Windows `ncat` and WSL2 are dropped per standing decision 5.

**All six query functions held up unchanged** — nothing missing, nothing worked around, no module
touched. That validates a contract first introduced in Phase 2 and extended through Phase 8. The
pre-chewed shapes are what made it work: `GdevScenetree.status().icons` returning the *resolved*
style lets health warn about Nerd Fonts without knowing the icon internals, and
`GdevFormat.get_command()` returning "argv minus the path" means health probes `argv[1]` without
re-deriving it.

- **One contract has an ambiguity worth knowing:** `get_command()` returns `nil` both for
  "formatting is off" and, from health's side, for "module never set up". Health's internal query
  returns `(result, asked)` to tell them apart. Any future query returning a meaningful `nil`
  needs the same treatment.
- Health reads `mod.config` directly for `lsp` and `dap`, which have no query by design. That cost
  nothing — neither has a buffer-local override that would mean anything for a session-wide
  connection.
- During `:checkhealth` the current buffer is `health://`, a `nofile` buffer, so the Phase 6
  `buftype ~= ''` guard sends root resolution to cwd. "Project root" therefore describes the
  working directory, which is the sane answer.

**Where the reference is wrong:** its `port_open()` returns `true` when `nc` is missing ("assume
port ok"), so on a machine without netcat it reports a green tick for a port nothing is listening
on — and its own `spec_health.lua` asserts that behavior. Ours returns a third state and says the
probe was skipped.

**Two findings worth reusing:**

- **`pcall` around `vim.system` is load-bearing, not padding.** `executable()` only checks the
  execute bit, so a wrapper script whose shebang interpreter is missing passes the guard and then
  raises `ENOENT` out of `vim.system` (a text file with no shebang raises `ENOEXEC` the same way).
  Unguarded, that aborts every later section. There is a fixture and a test for it.
- `vim.health.warn(msg, advice)` takes advice as a second argument but `vim.health.info` does not,
  and `vim.health` indents continuation lines by 2 on top of whatever you write.

Recording the five `vim.health.*` calls rather than scraping the buffer was decisive: eleven of the
32 mutations are level changes or duplications a buffer scrape would not see, and asserting
*exactly one* match per finding is what catches duplication. Note `$PATH` is *replaced* rather than
prepended in the child, so "tool not installed" stays testable on a machine that has the real one
— which matters here, since this machine runs a live Godot editor on 6005/6006 and a real probe
would have made the suite depend on whether it happened to be open.

**Verified for real:** `:checkhealth gdev` was run outside the test suite against this machine and
correctly reported Godot 4.7.1 as OK, both editor ports answering, the Neovim server address with
the exact Godot `Exec Flags` recipe, and the two genuinely missing treesitter parsers
(`gdshader`, `gdresource`). It also caught a real transient — a freshly installed Godot failing
`--version` while macOS verified it — which is exactly the job.

## Phase 10 — umbrella entry, docs, release polish

- [ ] `lua/gdev/init.lua`: optional convenience `require('gdev').setup({ lsp = {...},
      run = {...}, … })` forwarding each sub-table to the module's `setup()`; a module key set
      to `false` is skipped; omitted keys get defaults. Shared values (host/ports/godot path)
      stay per-module — the umbrella just forwards. Keep this thin; per-module setup remains
      the primary documented API (mini.nvim style).
- [ ] README.md: feature overview, requirements, install (lazy.nvim + `vim.pack`), quickstart,
      full annotated config example, per-feature sections (port the *content ideas* — external
      editor setup guide, Godot editor settings recommendations, multiple-Godot-versions
      guidance, hiding `.godot`/`.uid`/`.import` in file explorers — written fresh).
- [ ] `make gendoc` output committed; help tags resolve (`:h gdev`, `:h gdev.run`, …).
- [ ] Manual integration pass against a real Godot 4 project (LSP attach, debug launch, run
      with console, scene tree, docs float, format on save, `:checkhealth gdev`) — record
      results in the PR/commit message.
- [ ] Optional dev nicety: `plugin/dev-reload` equivalent gated behind
      `vim.g.gdev_dev_reload` (see reference `plugin/dev-reload.lua`).

---

## Appendix A — C# extensibility (future work, design constraints now)

C# is out of scope, but these seams must exist so adding it is additive:

| Seam | Where | Now | Later |
|---|---|---|---|
| Script extensions | `gdev.run`, `gdev.server`, `gdev.scenetree` config | `{ 'gd' }` | add `'cs'` |
| DAP language registration | `gdev.dap` `H.register_language(...)` | gdscript only | register `coreclr` adapter + `cs` configurations (netcoredbg) |
| Health sections | `gdev.health` section registry | no C# section | append dotnet/csharp-ls-or-omnisharp/netcoredbg checks |
| Umbrella config | `gdev.setup()` | — | reserved `csharp` key |
| Formatter | `gdev.format` | gdscript formatters | per-filetype formatter map if needed |

Reference behavior for the future implementation: `csharp = true` in godotdev.nvim enables
tooling *checks* only (LSP stays user-managed) plus netcoredbg DAP wiring — see
`.ref/godotdev.nvim/lua/godotdev/setup.lua` (`setup_csharp_dap`) and `health.lua`
(`report_csharp`).

## Appendix B — feature-parity checklist (verify at the end)

Every user-visible capability of godotdev.nvim minus C#:

- [x] GDScript LSP auto-attach over TCP; typeDefinition suppressed; reloadScript message spam
      suppressed
- [x] LSP reconnect command for all Godot buffers
- [x] Inlay hints (opt-in, capability-gated, per-buffer toggle command)
- [x] gdshader filetype + treesitter highlighting (built-in `vim.treesitter`; parsers are
      user-supplied rather than installed, and `parser_status()` reports what is missing)
- [x] DAP: launch-scene debugging; dap-ui auto open/close
- [x] Run: project / current scene / scene by path / picker; script→scene resolution with
      multi-match picker
- [x] Run console capture (buffer/float, reopen command, single-run guard)
- [x] Editor server: start command, autostart option, address pinning, stale socket cleanup
- [x] Scene tree pane: icons + color groups, jump/yank/open-script/refresh/close keymaps,
      position/size config (keymaps are configurable, and instanced scenes parse correctly —
      the reference mis-reads every one of them)
- [x] Docs: float/buffer/browser renderers, cursor symbol default, rst→markdown, cache,
      browser fallback, missing-symbol feedback modes (the conversion is a genuine improvement —
      the reference's heading detection never fires and its code fences come out empty)
- [x] Autoformat on save (gdscript-formatter default with `--reorder-code`, gdformat
      alternative, argv override, disable). Indent defaults are deliberately *not* set: Neovim's
      bundled gdscript ftplugin already does it, and the reference only documented its own.
- [x] `:checkhealth gdev` covering all of the above (eight sections; verified against this
      machine, not just fixtures)
- [ ] README + vimdoc parity with the reference's documented workflows
