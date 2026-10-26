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

---@class genja-ask
local M = {}

local BRIEF = 'Answer briefly: at most 3 short sentences.\n\n'
local HISTORY_MAX = 50
local LOG = vim.fs.normalize('~/.claude/p-logs/nvim.log')

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

---Random version 4 UUID, for `claude --session-id`.
---@return string
local function new_uuid()
	local bytes = { assert(vim.uv.random(16)):byte(1, 16) }
	bytes[7] = bytes[7] % 16 + 0x40
	bytes[9] = bytes[9] % 64 + 0x80
	local hex = ''
	for _, b in ipairs(bytes) do
		hex = hex .. string.format('%02x', b)
	end
	return hex:sub(1, 8) .. '-' .. hex:sub(9, 12) .. '-' .. hex:sub(13, 16) .. '-'
		.. hex:sub(17, 20) .. '-' .. hex:sub(21, 32)
end

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
	local root = vim.fs.root(dir, '.git')
	if not root then
		root = vim.fn.getcwd()
	end
	return vim.fs.normalize(root)
end

---The visual selection as `path:first-last` plus a fenced block, and its label.
---@param root string paths are relative to it
---@return string|nil text, string|nil label
local function selection(root)
	local first = vim.fn.line('v')
	local last = vim.fn.line('.')
	if first > last then
		first, last = last, first
	end
	vim.api.nvim_feedkeys(vim.keycode('<Esc>'), 'n', false)
	local file = vim.api.nvim_buf_get_name(0)
	if file == '' or vim.bo.buftype ~= '' then
		return nil, nil
	end
	local rel = vim.fs.relpath(root, file)
	if not rel then
		rel = vim.fs.normalize(file)
	end
	local label = rel .. ':' .. first .. '-' .. last
	local code = table.concat(vim.api.nvim_buf_get_lines(0, first - 1, last, false), '\n')
	local ticks = '```'
	for run in code:gmatch('`+') do
		if #run >= #ticks then
			ticks = string.rep('`', #run + 1)
		end
	end
	return label .. '\n' .. ticks .. vim.bo.filetype .. '\n' .. code .. '\n' .. ticks .. '\n\n', label
end

---Append one Q&A to the log.
---@param backend string
---@param prompt string
---@param answer string
local function log(backend, prompt, answer)
	vim.fn.mkdir(vim.fs.dirname(LOG), 'p')
	local entry = {
		'## ' .. os.date('%Y-%m-%d %H:%M') .. ' (' .. backend .. ')', '',
		'**Q:** ' .. prompt, '',
		answer, '', '---', '',
	}
	local text = table.concat(entry, '\n')
	vim.fn.writefile(vim.split(text, '\n', { plain = true }), LOG, 'a')
end

---Current value of a backend's model or effort list (nil: the CLI's default).
---@param list string[]
---@param idx integer|nil
---@return string|nil
local function pick(list, idx)
	if #list == 0 then
		return nil
	end
	return list[idx or 1]
end

---Saved claude-p sessions named `nvim ...`, newest last: { name, id }.
---@return { name: string, id: string }[]
local function saved_sessions()
	local dir = vim.fs.normalize('~/.claude/projects')
	if vim.fn.executable('rg') == 0 then
		vim.notify(SRC .. 'resume needs rg on PATH', vim.log.levels.WARN)
		return {}
	end
	local res = vim.system({ 'rg', '--no-filename', '-F', '"type":"custom-title"', '-g', '*.jsonl', dir }, { text = true }):wait()
	local by_id = {}
	local order = {}
	for line in (res.stdout or ''):gmatch('[^\n]+') do
		local ok, entry = pcall(vim.json.decode, line)
		if ok and type(entry) == 'table' and type(entry.customTitle) == 'string'
			and entry.customTitle:match('^nvim ') and type(entry.sessionId) == 'string' then
			if not by_id[entry.sessionId] then
				table.insert(order, entry.sessionId)
			end
			by_id[entry.sessionId] = entry.customTitle
		end
	end
	local list = {}
	for _, id in ipairs(order) do
		table.insert(list, { name = by_id[id], id = id })
	end
	table.sort(list, function(a, b) return a.name < b.name end)
	return list
end
-- }}}

---Open the popup; in visual mode the selection goes along.
function M.open()
	local root = project_root()
	local context = nil
	local label = nil
	if vim.fn.mode():match('^[vV\22]') then
		context, label = selection(root)
	end

	---@type 'compose'|'wait'|'answer'
	local mode = 'compose'
	local session = { id = new_uuid(), resume = false, save_name = nil }
	local transcript = {} -- { q, a } pairs, sent along for backends without sessions
	local answer = ''
	local job = nil
	local closed = false

	local buf = vim.api.nvim_create_buf(false, true)
	vim.bo[buf].bufhidden = 'wipe'
	vim.bo[buf].filetype = 'markdown'
	if state.draft then
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, state.draft)
	end
	local width = math.min(90, vim.o.columns - 4)
	local height = math.min(8, vim.o.lines - vim.o.cmdheight - 4)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = 'editor',
		width = width,
		height = math.max(height, 1),
		row = math.max(math.floor((vim.o.lines - height) / 2) - 3, 0),
		col = math.max(math.floor((vim.o.columns - width) / 2) - 8, 0),
		style = 'minimal',
		border = 'rounded',
		title = '',
		title_pos = 'center',
	})
	vim.wo[win].wrap = true
	local ok_cmp, cmp = pcall(require, 'cmp')
	if ok_cmp then
		cmp.setup.buffer({ enabled = false }) -- a completion menu would take <CR>
	end

	local function backend()
		return backends()[state.target]
	end

	---Title and footer for the current mode and choices.
	local function decorate()
		if closed or not vim.api.nvim_win_is_valid(win) then
			return
		end
		local b = backend()
		local parts = { b.name }
		local model = pick(b.models, state.model[b.name])
		local effort = pick(b.efforts, state.effort[b.name])
		table.insert(parts, model or 'default')
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
		local footer = ' <C-s> send · <M-p> to claudefterm · <M-t> target · <M-m> model · <M-e> effort · <M-s> save · <M-r> resume · <C-b> brief '
		if mode == 'wait' then
			footer = ' <C-c> cancel '
		elseif mode == 'answer' then
			footer = ' <CR> follow-up · y yank · q close '
		end
		vim.api.nvim_win_set_config(win, { title = title .. ' ', title_pos = 'center', footer = footer, footer_pos = 'center' })
	end

	local function close()
		if closed then
			return
		end
		closed = true
		if mode == 'compose' and vim.api.nvim_buf_is_valid(buf) then
			local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
			state.draft = lines
			if vim.trim(table.concat(lines, '\n')) == '' then
				state.draft = nil
			end
		end
		if vim.api.nvim_get_current_win() == win then
			vim.cmd.stopinsert()
		end
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end

	---Show `lines` read-only and grow the float to fit.
	---@param lines string[]
	local function show(lines)
		if closed or not vim.api.nvim_buf_is_valid(buf) then
			return
		end
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
		vim.bo[buf].modifiable = mode == 'compose'
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

		local b = backend()
		if target then
			b = target
		end
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
		if b.sync then
			-- the answer shows in the claudefterm
			mode = 'wait'
			close()
		end
		mode = 'wait'
		vim.cmd.stopinsert()
		local waiting = vim.list_extend(vim.deepcopy(q_lines), { '', '… waiting for ' .. b.name })
		show(waiting)
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
			vim.list_extend(lines, vim.split(vim.trim(body), '\n', { plain = true }))
			show(lines)
			decorate()
		end)
	end

	local function cancel()
		if job then
			job:kill(15)
			job = nil
			mode = 'answer'
			show({ '(cancelled)' })
			decorate()
		end
	end

	---Cycle a backend list choice (<M-m> model, <M-e> effort).
	---@param what 'model'|'effort'
	local function cycle(what)
		local b = backend()
		local list = b.models
		if what == 'effort' then
			list = b.efforts
		end
		if #list == 0 then
			vim.notify(SRC .. b.name .. ' has no ' .. what .. ' choice', vim.log.levels.INFO)
			return
		end
		local idx = (state[what][b.name] or 1) % #list + 1
		state[what][b.name] = idx
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

	local history_index = nil
	local scratch = nil
	local function show_history(index)
		history_index = index
		local text = scratch or {}
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
			scratch = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
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

	local function o(desc) return { buffer = buf, desc = desc, noremap = true } end
	local function in_compose(fn)
		return function()
			if mode == 'compose' then
				fn()
			end
		end
	end
	-- <C-CR> doesn't reach nvim through Windows Terminal; <M-CR> and <C-s> do
	for _, lhs in ipairs({ '<C-CR>', '<M-CR>', '<C-s>' }) do
		vim.keymap.set({ 'i', 'n' }, lhs, in_compose(function() send() end), o 'Ask: send')
	end
	local function send_claudefterm()
		send(require('genja-ask.backends.claudefterm'))
	end
	vim.keymap.set({ 'i', 'n' }, '<M-p>', in_compose(send_claudefterm), o 'Ask: send to the claudefterm')
	vim.keymap.set('i', '<S-CR>', '<CR>', o 'Ask: newline')
	vim.keymap.set('i', '<C-j>', '<CR>', o 'Ask: newline')
	vim.keymap.set({ 'i', 'n' }, '<C-p>', history_prev, o 'Ask: previous prompt')
	vim.keymap.set({ 'i', 'n' }, '<C-n>', history_next, o 'Ask: next prompt')
	vim.keymap.set({ 'i', 'n' }, '<C-b>', function() state.brief = not state.brief; decorate() end, o 'Ask: toggle brief')
	vim.keymap.set({ 'i', 'n' }, '<M-t>', next_target, o 'Ask: next target')
	vim.keymap.set({ 'i', 'n' }, '<M-m>', function() cycle('model') end, o 'Ask: next model')
	vim.keymap.set({ 'i', 'n' }, '<M-e>', function() cycle('effort') end, o 'Ask: next effort')
	vim.keymap.set({ 'i', 'n' }, '<M-s>', save, o 'Ask: save the session')
	vim.keymap.set({ 'i', 'n' }, '<M-r>', resume, o 'Ask: resume a saved session')
	vim.keymap.set({ 'i', 'n' }, '<C-c>', function()
		if mode == 'wait' then
			cancel()
		else
			vim.cmd.stopinsert()
		end
	end, o 'Ask: cancel')
	-- normal mode: these keep their usual meaning while composing
	vim.keymap.set('n', '<CR>', function()
		if mode == 'answer' then
			vim.schedule(compose) -- no text changes inside an expr mapping (E565)
			return ''
		end
		return '<CR>'
	end, { buffer = buf, expr = true, desc = 'Ask: follow-up' })
	vim.keymap.set('n', 'y', function()
		if mode == 'answer' then
			vim.fn.setreg('"', answer)
			vim.fn.setreg('+', answer)
			vim.notify(SRC .. 'answer yanked')
			return ''
		end
		return 'y'
	end, { buffer = buf, expr = true, desc = 'Ask: yank the answer' })
	vim.keymap.set('n', '<Esc>', close, o 'Ask: close')
	vim.keymap.set('n', 'q', close, o 'Ask: close')

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
