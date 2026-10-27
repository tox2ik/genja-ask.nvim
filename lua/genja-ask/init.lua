-- Ask popup (idea 16): one quick question, a short plain-text answer in the same float.
--   <M-?> (normal, insert, visual: selection attached), <leader>pc: open (plugin/ask.lua, plugin/claude-fterm.lua in the config)
--   compose:  <C-CR>/<M-CR>/<C-s> send · <M-p> send to the claudefterm · <S-CR>/<C-j> newline · <C-p>/<C-n> history · <C-b> brief
--             <M-t> target · <M-m> model · <M-e> effort · <M-s> save session · <M-r> resume saved
--             <Esc>/q (normal) close, the draft is kept
--   waiting:  <C-c> cancel
--   answer:   <CR> follow-up (same session) · y yank the answer · q/<Esc> close
-- Targets (backends/): claude-p (claude --print, sessions), claudefterm (the
-- project's claude terminal), gemini, copilot, aichat. Every Q&A goes to ~/.claude/p-logs/nvim.log.
-- Saved claude-p sessions are named `nvim yyyy.ww.d-ddd.hhmm` (the pwsh claude-p uses `pwsh ...`).

local SRC = 'genja-ask/init.lua: '

local float = require('genja-util.float')
local txt = require('genja-util.text')

---@class genja-ask
local M = {}

local BRIEF = 'Answer briefly: at most 3 short sentences.\n\n'
local HISTORY_MAX = 50
local LOG = vim.fs.normalize('~/.claude/p-logs/nvim.log')
local FOOTER = {
	compose = ' <C-s> send · <M-p> to claudefterm · <M-t> target · <M-m> model · <M-e> effort · <M-s> save · <M-r> resume · <C-b> brief ',
	wait = ' <C-c> cancel ',
	answer = ' <CR> follow-up · y yank · q close ',
}

---@class genja-ask.RunOpts
---@field model string|nil
---@field effort string|nil
---@field session_id string
---@field resume boolean continue session_id instead of starting it
---@field save_name string|nil name the session (claude -n)
---@field cwd string

---@class genja-ask.Backend
---@field name string
---@field models string[] first one is the default; empty: the CLI's default
---@field efforts string[]
---@field sessions boolean keeps context itself; else earlier Q&A is sent along
---@field sync? boolean answers at once (no job)
---@field system? string
---@field run fun(self: genja-ask.Backend, prompt: string, opts: genja-ask.RunOpts, on_done: fun(err: string|nil, text?: string)): vim.SystemObj|nil

---@class genja-ask.Opts
---Sends to the claudefterm target. `run` carries the popup's choices (model, effort, cwd, ...);
---the caller maps them to whatever its terminal takes.
---@field send? fun(prompt: string, run: genja-ask.RunOpts)

---@type genja-ask.Opts
M.options = {}

---@param opts? genja-ask.Opts
function M.setup(opts)
	M.options = vim.tbl_extend('force', M.options, opts or {})
end

---Targets in <M-t> order, the first is the default. Listed explicitly.
---@return genja-ask.Backend[]
local function backends()
	local cli = require('genja-ask.backends.cli')
	return {
		require('genja-ask.backends.claude_p'),
		require('genja-ask.backends.claudefterm'),
		cli.gemini,
		cli.copilot,
		cli.aichat,
	}
end

local state = {
	target = 1,     -- index into backends()
	model = {},     -- backend name -> index into its models
	effort = {},    -- backend name -> index into its efforts
	draft = nil,    -- compose text kept between popups
	history = {},   -- sent prompts, oldest first (this nvim only)
	brief = false,  -- <C-b>: ask for at most 3 sentences
}

-- {{{ helpers

---Session name like the pwsh claude-p's: ISO year . week . weekday-name . HHMM.
---@return string
local function session_name()
	return 'nvim ' .. os.date('%G.%V.%u-') .. os.date('%a'):lower() .. os.date('.%H%M')
end

---Project root of the current buffer: git root of its dir, else :pwd.
---@return string
local function project_root()
	local name = vim.api.nvim_buf_get_name(0)
	local dir = vim.fn.getcwd()
	if name ~= '' and vim.bo.buftype == '' then
		dir = vim.fs.dirname(name)
	end
	return vim.fs.normalize(vim.fs.root(dir, '.git') or vim.fn.getcwd())
end

---The visual selection as `path:first-last` plus a fenced block, and its label.
---@param root string paths are relative to it
---@return string|nil text, string|nil label
local function selection(root)
	local first, last = txt.visual_lines()
	local file = vim.api.nvim_buf_get_name(0)
	if file == '' or vim.bo.buftype ~= '' then
		return nil, nil
	end
	local label = (vim.fs.relpath(root, file) or vim.fs.normalize(file)) .. ':' .. first .. '-' .. last
	local code = table.concat(vim.api.nvim_buf_get_lines(0, first - 1, last, false), '\n')
	return label .. '\n' .. txt.fenced(code, vim.bo.filetype) .. '\n\n', label
end

---Append one Q&A to the log.
---@param backend string
---@param prompt string
---@param answer string
local function log(backend, prompt, answer)
	vim.fn.mkdir(vim.fs.dirname(LOG), 'p')
	local text = table.concat({
		'## ' .. os.date('%Y-%m-%d %H:%M') .. ' (' .. backend .. ')', '',
		'**Q:** ' .. prompt, '',
		answer, '', '---', '',
	}, '\n')
	-- prompt and answer span lines; writefile wants one item per line
	vim.fn.writefile(vim.split(text, '\n', { plain = true }), LOG, 'a')
end

---Current value of a backend's model or effort list (nil: the CLI's default).
---@param list string[]
---@param idx integer|nil
---@return string|nil
local function pick(list, idx)
	return list[idx or 1]
end

---Saved claude-p sessions named `nvim ...`, sorted by name: { name, id }.
---@return { name: string, id: string }[]
local function saved_sessions()
	if vim.fn.executable('rg') == 0 then
		vim.notify(SRC .. 'resume needs rg on PATH', vim.log.levels.WARN)
		return {}
	end
	local dir = vim.fs.normalize('~/.claude/projects')
	local res = vim.system({ 'rg', '--no-filename', '-F', '"type":"custom-title"', '-g', '*.jsonl', dir }, { text = true }):wait()
	-- a renamed session has several title lines; the last one wins
	local by_id = {}
	for line in (res.stdout or ''):gmatch('[^\n]+') do
		local ok, entry = pcall(vim.json.decode, line)
		if ok and type(entry) == 'table' and type(entry.customTitle) == 'string'
			and entry.customTitle:match('^nvim ') and type(entry.sessionId) == 'string' then
			by_id[entry.sessionId] = entry.customTitle
		end
	end
	local list = {}
	for id, name in pairs(by_id) do
		table.insert(list, { name = name, id = id })
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	return list
end
-- }}}

---Open the popup; in visual mode the selection goes along.
function M.open()
	local root = project_root()
	local context, label
	if vim.fn.mode():match('^[vV\22]') then
		context, label = selection(root)
	end

	---@type 'compose'|'wait'|'answer'
	local mode = 'compose'
	local session = { id = txt.uuid(), resume = false, save_name = nil }
	local transcript = {} -- { q, a } pairs, sent along for backends without sessions
	local answer = ''
	local job = nil
	local closed = false

	local buf = float.scratch(state.draft)
	vim.bo[buf].filetype = 'markdown'
	local height = math.min(8, vim.o.lines - vim.o.cmdheight - 4)
	local win = float.open(buf, { width = math.min(90, vim.o.columns - 4), height = height, up = 3, left = 8 })
	vim.wo[win].wrap = true
	vim.b[buf].completion = false -- blink.cmp: a completion menu would take <CR>

	local function backend()
		return backends()[state.target]
	end

	---Title and footer for the current mode and choices.
	local function decorate()
		if closed or not vim.api.nvim_win_is_valid(win) then
			return
		end
		local b = backend()
		local parts = { b.name, pick(b.models, state.model[b.name]) or 'default' }
		local effort = pick(b.efforts, state.effort[b.name])
		if effort then
			table.insert(parts, effort)
		end
		local title = ' ' .. table.concat(parts, ' · ')
		if label then
			title = title .. ' + ' .. label
		end
		if state.brief then
			title = title .. ' [brief]'
		end
		if session.save_name then
			title = title .. ' [' .. session.save_name .. ']'
		end
		if session.resume or #transcript > 0 then
			title = title .. ' [follow-up]'
		end
		vim.api.nvim_win_set_config(win, { title = title .. ' ', title_pos = 'center', footer = FOOTER[mode], footer_pos = 'center' })
	end

	local function close()
		if closed then
			return
		end
		closed = true
		if mode == 'compose' and vim.api.nvim_buf_is_valid(buf) then
			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			state.draft = nil
			if vim.trim(table.concat(lines, '\n')) ~= '' then
				state.draft = lines
			end
		end
		float.close(win)
	end

	---Show `lines` read-only and grow the float to fit.
	---@param lines string[]
	local function show(lines)
		if closed or not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = (mode == 'compose')
		local h = math.min(math.max(#lines + 1, height), vim.o.lines - vim.o.cmdheight - 6)
		vim.api.nvim_win_set_config(win, { height = math.max(h, 1) })
		vim.api.nvim_win_set_cursor(win, { 1, 0 })
	end

	local function compose()
		mode = 'compose'
		show({ '' })
		decorate()
		vim.cmd.startinsert()
	end

	---@param target? genja-ask.Backend overrides the picked target for this send (<M-p>)
	local function send(target)
		local prompt = vim.trim(table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n'))
		if prompt == '' then
			return
		end
		state.draft = nil
		if state.history[#state.history] ~= prompt then
			table.insert(state.history, prompt)
		end
		if #state.history > HISTORY_MAX then
			table.remove(state.history, 1)
		end

		local b = target or backend()
		local full = prompt
		if context then
			full = context .. full
			context = nil -- only with the first question
		end
		if state.brief then
			full = BRIEF .. full
		end
		if not b.sessions and #transcript > 0 then
			local earlier = { 'Earlier in this conversation:' }
			for _, qa in ipairs(transcript) do
				table.insert(earlier, 'Q: ' .. qa[1])
				table.insert(earlier, 'A: ' .. qa[2])
			end
			full = table.concat(earlier, '\n') .. '\n\nNow: ' .. full
		end

		local q_lines = vim.split('Q: ' .. prompt, '\n', { plain = true })
		mode = 'wait' -- before close(): no draft is kept
		if b.sync then
			close() -- the answer shows in the claudefterm
		end
		vim.cmd.stopinsert()
		show(vim.list_extend(vim.deepcopy(q_lines), { '', '… waiting for ' .. b.name }))
		decorate()

		local opts = {
			model = pick(b.models, state.model[b.name]),
			effort = pick(b.efforts, state.effort[b.name]),
			session_id = session.id,
			resume = session.resume,
			save_name = session.save_name,
			cwd = root,
		}
		job = b:run(full, opts, function(err, text)
			job = nil
			local body = text or ''
			if err then
				body = 'error: ' .. err
			else
				answer = vim.trim(body)
				table.insert(transcript, { prompt, answer })
				if b.sessions then
					session.resume = true
				end
			end
			log(b.name, prompt, body)
			if closed then
				if not b.sync then
					vim.notify(SRC .. b.name .. ' answered after the popup closed; see ' .. LOG)
				end
				return
			end
			mode = 'answer'
			local lines = vim.deepcopy(q_lines)
			table.insert(lines, '')
			show(vim.list_extend(lines, vim.split(vim.trim(body), '\n', { plain = true })))
			decorate()
		end)
	end

	local function cancel()
		if not job then
			return
		end
		job:kill(15)
		job = nil
		mode = 'answer'
		show({ '(cancelled)' })
		decorate()
	end

	---Cycle a backend list choice (<M-m> model, <M-e> effort).
	---@param what 'model'|'effort'
	local function cycle(what)
		local b = backend()
		local list = (what == 'effort' and b.efforts or b.models)
		if #list == 0 then
			vim.notify(SRC .. b.name .. ' has no ' .. what .. ' choice', vim.log.levels.INFO)
			return
		end
		state[what][b.name] = (state[what][b.name] or 1) % #list + 1
		decorate()
	end

	local function next_target()
		state.target = state.target % #backends() + 1
		decorate()
	end

	local function save()
		if not backend().sessions then
			vim.notify(SRC .. backend().name .. ' has no sessions to save', vim.log.levels.INFO)
			return
		end
		session.save_name = session_name()
		decorate()
	end

	local function resume()
		local list = saved_sessions()
		if #list == 0 then
			vim.notify(SRC .. 'no saved nvim sessions')
			return
		end
		vim.ui.select(list, {
			prompt = 'Resume session',
			format_item = function(item) return item.name end,
		}, function(item)
			if not item then
				return
			end
			state.target = 1 -- claude-p
			session.id = item.id
			session.resume = true
			session.save_name = nil
			if vim.api.nvim_win_is_valid(win) then
				vim.api.nvim_set_current_win(win)
			end
			decorate()
		end)
	end

	-- prompt history: index nil is the text typed before <C-p>
	local history_index = nil
	local typed = nil
	local function show_history(index)
		history_index = index
		local text = typed or {}
		if index then
			text = vim.split(state.history[index], '\n', { plain = true })
		end
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, text)
	end
	local function history_prev()
		if mode ~= 'compose' or #state.history == 0 then
			return
		end
		if history_index == nil then
			typed = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			show_history(#state.history)
		elseif history_index > 1 then
			show_history(history_index - 1)
		end
	end
	local function history_next()
		if mode ~= 'compose' or history_index == nil then
			return
		end
		if history_index < #state.history then
			show_history(history_index + 1)
		else
			show_history(nil)
		end
	end

	local function map(modes, lhs, rhs, desc)
		vim.keymap.set(modes, lhs, rhs, { buffer = buf, desc = desc })
	end
	local function in_compose(fn)
		return function()
			if mode == 'compose' then
				fn()
			end
		end
	end
	local function in_answer(fn, lhs)
		return function()
			if mode ~= 'answer' then
				return lhs
			end
			fn()
			return ''
		end
	end
	local both = { 'i', 'n' }
	-- <C-CR> doesn't reach nvim through Windows Terminal; <M-CR> and <C-s> do
	for _, lhs in ipairs({ '<C-CR>', '<M-CR>', '<C-s>' }) do
		map(both, lhs, in_compose(function() send() end), 'Ask: send')
	end
	map(both, '<M-p>', in_compose(function()
		send(require('genja-ask.backends.claudefterm'))
	end), 'Ask: send to the claudefterm')
	map('i', '<S-CR>', '<CR>', 'Ask: newline')
	map('i', '<C-j>', '<CR>', 'Ask: newline')
	map(both, '<C-p>', history_prev, 'Ask: previous prompt')
	map(both, '<C-n>', history_next, 'Ask: next prompt')
	map(both, '<C-b>', function()
		state.brief = not state.brief
		decorate()
	end, 'Ask: toggle brief')
	map(both, '<M-t>', next_target, 'Ask: next target')
	map(both, '<M-m>', function() cycle('model') end, 'Ask: next model')
	map(both, '<M-e>', function() cycle('effort') end, 'Ask: next effort')
	map(both, '<M-s>', save, 'Ask: save the session')
	map(both, '<M-r>', resume, 'Ask: resume a saved session')
	map(both, '<C-c>', function()
		if mode == 'wait' then
			cancel()
		else
			vim.cmd.stopinsert()
		end
	end, 'Ask: cancel')
	-- normal mode: <CR> and y keep their usual meaning while composing
	vim.keymap.set('n', '<CR>', in_answer(function()
		vim.schedule(compose) -- no text changes inside an expr mapping (E565)
	end, '<CR>'), { buffer = buf, expr = true, desc = 'Ask: follow-up' })
	vim.keymap.set('n', 'y', in_answer(function()
		vim.fn.setreg('"', answer)
		vim.fn.setreg('+', answer)
		vim.notify(SRC .. 'answer yanked')
	end, 'y'), { buffer = buf, expr = true, desc = 'Ask: yank the answer' })
	map('n', '<Esc>', close, 'Ask: close')
	map('n', 'q', close, 'Ask: close')

	-- leaving the popup closes it; scheduled: no window closing inside WinLeave
	vim.api.nvim_create_autocmd('WinLeave', {
		buffer = buf,
		callback = function()
			vim.schedule(function()
				-- vim.ui.select (resume) takes the focus for a moment
				if vim.api.nvim_get_current_win() ~= win and vim.bo.filetype ~= 'TelescopePrompt' then
					close()
				end
			end)
		end,
	})
	decorate()
	vim.api.nvim_win_set_cursor(win, { 1, 0 })
	vim.cmd.startinsert({ bang = true })
end

return M
