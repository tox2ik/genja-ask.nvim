-- ask backend: `claude --print`, the Lua take on the pwsh claude-p function (PowerShell profile).
-- Prompt on stdin (npm .cmd shims cap the command line). Sessions: the first question gets
-- `--session-id <id>`, follow-ups `--resume <id>`; `-n <name>` names a saved one.

---@type genja-ask.Backend
return {
	name = 'claude-p',
	models = { 'haiku', 'sonnet', 'opus' },
	efforts = { 'low', 'medium', 'high' },
	sessions = true,
	system = table.concat({
		'Output: plain text, no markdown, no preamble.',
		'Use ascii punctuation, not unicode dashes or quotes.',
		'Hard-wrap at 80 columns; short paragraphs of 1-3 lines.',
		'Style: terse, imperative, no hedging, no follow-up questions.',
	}, '\n'),

	run = function(self, prompt, opts, on_done)
		local exe = vim.fn.exepath('claude')
		if exe == '' then
			on_done('claude is not on PATH')
			return nil
		end
		local cmd = { exe, '--print', '--append-system-prompt', self.system }
		if opts.model then
			vim.list_extend(cmd, { '--model', opts.model })
		end
		if opts.effort then
			vim.list_extend(cmd, { '--effort', opts.effort })
		end
		if opts.resume then
			vim.list_extend(cmd, { '--resume', opts.session_id })
		else
			vim.list_extend(cmd, { '--session-id', opts.session_id })
		end
		if opts.save_name then
			vim.list_extend(cmd, { '-n', opts.save_name })
		end
		return require('genja-ask.backends.cli').exec(cmd, prompt, opts.cwd, on_done)
	end,
}
