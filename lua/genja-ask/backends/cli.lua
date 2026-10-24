-- ask backends for one-shot CLIs: gemini, copilot, aichat. Flags as in genja-commit's
-- generate.lua (plug-wip/genja-commit.nvim); the prompt goes on stdin. No sessions:
-- the popup sends earlier questions and answers along with a follow-up.

---Backend for `name`; `flags(model)` builds the arguments after the executable.
---@param name string
---@param models string[]
---@param flags fun(model: string|nil): string[]
---@return genja-ask.Backend
local function cli(name, models, flags)
	return {
		name = name,
		models = models,
		efforts = {},
		sessions = false,
		run = function(_, prompt, opts, on_done)
			local exe = vim.fn.exepath(name) -- full path: finds .cmd shims on Windows
			if exe == '' then
				on_done(name .. ' is not on PATH')
				return nil
			end
			local cmd = { exe }
			vim.list_extend(cmd, flags(opts.model))
			return vim.system(cmd, { stdin = prompt, text = true, cwd = opts.cwd }, vim.schedule_wrap(function(res)
				if res.code ~= 0 then
					on_done(vim.trim((res.stderr or '') .. ' (exit ' .. res.code .. ')'))
					return
				end
				on_done(nil, res.stdout or '')
			end))
		end,
	}
end

local M = {}

M.gemini = cli('gemini', { 'gemini-2.5-flash', 'gemini-2.5-pro' }, function(model)
	-- -p text is appended to stdin; -o text: plain answer (untested)
	local args = { '-p', 'Answer the question above briefly, plain text.', '-o', 'text' }
	if model then
		vim.list_extend(args, { '-m', model })
	end
	return args
end)

M.copilot = cli('copilot', {}, function(model)
	-- -s: answer only; --no-ask-user: never wait (untested, needs a Copilot plan)
	local args = { '-p', 'Answer the question on stdin briefly, plain text.', '-s', '--no-ask-user' }
	if model then
		vim.list_extend(args, { '--model', model })
	end
	return args
end)

M.aichat = cli('aichat', {}, function(model)
	local args = { '-S' } -- no streaming: one plain answer
	if model then
		vim.list_extend(args, { '-m', model })
	end
	return args
end)

return M
