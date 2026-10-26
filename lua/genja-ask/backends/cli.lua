-- ask backends for one-shot CLIs: gemini, copilot, aichat. Flags as in genja-commit's
-- generate.lua (plug-wip/genja-commit.nvim); the prompt goes on stdin. No sessions:
-- the popup sends earlier questions and answers along with a follow-up.

local M = {}

---Run `cmd` with `prompt` on stdin; `on_done(err)` or `on_done(nil, stdout)` on the main loop.
---@param cmd string[]
---@param prompt string
---@param cwd string
---@param on_done fun(err: string|nil, text?: string)
---@return vim.SystemObj
function M.exec(cmd, prompt, cwd, on_done)
	return vim.system(cmd, { stdin = prompt, text = true, cwd = cwd }, vim.schedule_wrap(function(res)
		if res.code ~= 0 then
			on_done(vim.trim((res.stderr or '') .. ' (exit ' .. res.code .. ')'))
			return
		end
		on_done(nil, res.stdout or '')
	end))
end

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
			return M.exec(vim.list_extend({ exe }, flags(opts.model)), prompt, opts.cwd, on_done)
		end,
	}
end

---`args`, plus `flag model` when a model is picked.
---@param args string[]
---@param flag string
---@param model string|nil
---@return string[]
local function with_model(args, flag, model)
	if model then
		vim.list_extend(args, { flag, model })
	end
	return args
end

M.gemini = cli('gemini', { 'gemini-2.5-flash', 'gemini-2.5-pro' }, function(model)
	-- -p text is appended to stdin; -o text: plain answer (untested)
	return with_model({ '-p', 'Answer the question above briefly, plain text.', '-o', 'text' }, '-m', model)
end)

M.copilot = cli('copilot', {}, function(model)
	-- -s: answer only; --no-ask-user: never wait (untested, needs a Copilot plan)
	return with_model({ '-p', 'Answer the question on stdin briefly, plain text.', '-s', '--no-ask-user' }, '--model', model)
end)

M.aichat = cli('aichat', {}, function(model)
	return with_model({ '-S' }, '-m', model) -- -S no streaming: one plain answer
end)

return M
