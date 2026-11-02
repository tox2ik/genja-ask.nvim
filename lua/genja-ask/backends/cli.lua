-- ask backends without sessions: gemini, copilot, aichat (CLIs) and ollama (http), built on
-- plug-wip/genja-util.nvim/lua/genja-util/llm.lua (shared with genja-commit's <M-g>).
-- The popup sends earlier questions and answers along with a follow-up.

local llm = require('genja-util.llm')

local M = {}

---An ask target for a genja-util.llm backend.
---@param backend genja-util.llm.Backend
---@param models string[] first one is the default; empty: the backend's default
---@return genja-ask.Backend
local function target(backend, models)
    return {
        name = backend.name,
        models = models,
        efforts = {},
        sessions = false,
        run = function(_, prompt, opts, on_done)
            return backend:run(prompt, { cwd = opts.cwd, model = opts.model }, on_done)
        end,
    }
end

M.gemini = target(llm.gemini({ instruction = 'Answer the question above briefly, plain text.' }),
    { 'gemini-2.5-flash', 'gemini-2.5-pro' })

M.copilot = target(llm.copilot({}), {}) -- untested, needs a Copilot plan

M.aichat = target(llm.aichat({}), {})

---ollama target; `settings` from setup({ ollama = ... }). Its models list feeds <M-m>.
---@param settings genja-ask.OllamaOpts
---@return genja-ask.Backend
function M.ollama(settings)
    local models = settings.models or { llm.OLLAMA_MODEL }
    return target(llm.ollama({ end_point = settings.end_point, model = models[1], api_key = settings.api_key }), models)
end

return M
