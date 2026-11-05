# genja-ask.nvim

One quick question to an LLM from Neovim: a float opens, you type, a short
plain-text answer appears in the same float. Follow-ups stay in the same session.

Targets (`<M-t>` cycles them, the first is the default):

- `claude-p`: `claude --print`, with sessions (save and resume them).
- `claudefterm`: types the question into the project's Claude Code terminal
  ([genja-claudefterm.nvim](https://github.com/tox2ik/genja-claudefterm.nvim)).
- `gemini`, `copilot`, `aichat`: their CLIs, prompt on stdin.
- `ollama`: an OpenAI-compatible HTTP end point, the local server by default.

Every question and answer is appended to `~/.claude/p-logs/nvim.log`.

## Requirements

- Neovim 0.11+
- [genja-util.nvim](https://github.com/tox2ik/genja-util.nvim) (float, text and LLM backend helpers)
- At least one backend: the `claude`, `gemini`, `copilot` or `aichat` CLI on PATH, or an ollama server.

## Install (lazy.nvim)

```lua
{
    'tox2ik/genja-ask.nvim',
    dependencies = { 'tox2ik/genja-util.nvim' },
    keys = {
        { '<M-?>', function() require('genja-ask').open() end, mode = { 'n', 'i', 'x' }, desc = 'Ask: popup' },
    },
    opts = {
        -- claudefterm target: how a question reaches your Claude terminal
        send = function(prompt, run)
            require('genja-claudefterm').send(prompt)
        end,
        ollama = {
            models = { 'qwen2.5-coder:7b' }, -- <M-m> list, the first is the default
            -- end_point = 'http://localhost:11434/v1/chat/completions',
            -- api_key = 'string' or function() return '...' end,
        },
    },
}
```

No keys are mapped by the plugin; map `require('genja-ask').open()` yourself.
In visual mode the selection is attached to the question.

## Keys in the popup

| Where | Key | Action |
|---|---|---|
| compose | `<C-s>`, `<M-CR>`, `<C-CR>` | send (`<C-CR>` doesn't reach Neovim through Windows Terminal) |
| compose | `<M-p>` | send to the claudefterm, whatever the target |
| compose | `<S-CR>`, `<C-j>` | newline |
| compose | `<C-p>`, `<C-n>` | history |
| compose | `<C-b>` | ask for a brief answer |
| compose | `<M-t>`, `<M-m>`, `<M-e>` | next target, model, effort |
| compose | `<M-s>`, `<M-r>` | save the session, resume a saved one |
| compose | `<Esc>`, `q` (normal) | close; the draft is kept |
| waiting | `<C-c>` | cancel |
| answer | `<CR>` | follow-up in the same session |
| answer | `y` | yank the answer |
| answer | `q`, `<Esc>` | close |

## License

MIT
