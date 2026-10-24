-- ask backend: hand the prompt to `opts.send` from setup() (the config pastes it into
-- this project's claudefterm and submits). The answer shows in that terminal; the popup only confirms.

local SRC = 'genja-ask/claudefterm.lua: '

---@type genja-ask.Backend
return {
	name = 'claudefterm',
	models  = { 'opus',  'sonnet', 'haiku',  },
	efforts = { 'low',   'medium', 'high' },
	sessions = false,
	sync = true, -- answers right away; no process to wait for

	run = function(_, prompt, opts, on_done)
		local send = require('genja-ask').options.send
		if not send then
			on_done(SRC .. 'no send function; set opts.send in the genja-ask spec')
			return nil
		end
		send(prompt, opts)
		on_done(nil, '(sent to the claudefterm; the answer shows there)')
		return nil
	end,
}
