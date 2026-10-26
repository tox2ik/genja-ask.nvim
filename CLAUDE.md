# genja-ask.nvim

Ask popup (idea 16): one quick question, a short plain-text answer in the same
float. Loaded from disk by the config's `../../lua/lazyp/new/genja-ask.lua`
(`dir =` spec, no trigger: it loads on the first `require('genja-ask')` from
`<M-?>` in `plugin/ask.lua` and `<leader>pc` in `plugin/claude-fterm.lua`).

How this file is kept: one heading per feature, one bullet per decision.
Unmarked bullets were stated by jaro. `(inferred)` marks Claude's reading of the
code or history: confirm or delete. `Hint:` is a working note for Claude.

## Layout

- `lua/genja-ask/init.lua`: `open()`, popup, sessions, history, log (`~/.claude/p-logs/nvim.log`).
- The float comes from `genja-util.float` (`plug-wip/genja-util.nvim`, a spec dependency).
- `lua/genja-ask/backends/`: `claude_p.lua` (`claude --print`), `claudefterm.lua` (the project's claude terminal), `cli.lua` (gemini, copilot, aichat).
- Moved out of the config's `lua/genja/ask.lua` and `lua/genja/ask/backends/`.

## Decisions

- The floaterm backend is named `claudefterm`, like `:ClaudeFterm`.
- `<M-p>` in the popup sends to the claudefterm, whatever the target.
- `<C-CR>`, `<M-CR>` and `<C-s>` send: `<C-CR>` doesn't reach nvim through Windows Terminal. The footer shows `<C-s>`.
- Mappings stay in the config.
- The plugin requires no `genja.*` module: the claudefterm backend calls `opts.send(prompt, run)` from `setup()`, set in the config's spec.
- `send` gets the whole `genja-ask.RunOpts` (model, effort, cwd, ...), so the caller maps the popup's choices itself; the spec turns model and effort into `--model` / `--effort` for `genja-claudefterm.send(text, flags)`.
- Flags only apply when claude starts; a running claude keeps its own, and `send()` warns when the flags differ from the ones it started with. (inferred)
