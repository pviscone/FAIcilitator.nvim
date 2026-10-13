-- FAIcilitator.nvim configuration: defaults + merge.

local M = {}

M.defaults = {
	enabled = true,
	record = {
		keys = false, -- typed text (insert/replace); off by default: only motions are tracked
		commands = true, -- :ex commands and /? searches via CmdlineLeave
		yanks = false, -- yank/delete operators via TextYankPost
		buffers = false, -- buffer switches via BufEnter (leaks file names to the AI)
	},
	max_events = 2000, -- raw events kept in the ring buffer
	transcript_events = 300, -- aggregated lines sent to the AI per analysis
	timer = { interval = 5, min_events = 1 }, -- seconds; needs >= min_events new activity
	events = { threshold = 10 }, -- also analyze after this many new events
	cooldown = 5, -- min seconds between two analyses (:FAIcilitator ignores this)
	idle_ms = 1500, -- auto-analysis waits until this long after the last recorded event
	history = {
		persist = true, -- append suggestions to a file so :FAIcilitatorLog survives restarts
		file = vim.fn.stdpath("data") .. "/faicilitator_history.jsonl",
		max_file_kb = 256, -- rotated to keep the newest half when exceeded
	},
	notify = { level = vim.log.levels.INFO, max_suggestions = 3 },
	display = "echo", -- "notify": vim.notify toast | "echo": message area below the statusline
	context = {
		buffer_lines = 3, -- buffer lines each side of the cursor sent as context (0 = off)
		register = true, -- also send the unnamed register (last yank/delete)
	},
	awareness = { -- how much of YOUR config (maps/commands/plugins) the model sees
		analysis = { keymaps = "compact", commands = true, plugins = false },
		ask = { keymaps = "full", commands = true, plugins = true, docs = true },
	},
	ai = {
		endpoint = nil, -- REQUIRED: openai-compatible base URL, e.g. "https://api.openai.com/v1"
		model = nil, -- REQUIRED: model name served by that endpoint
		api_key = nil, -- resolved: this field -> $api_key_env
		api_key_env = "FAICILITATOR_API_KEY",
		params = {}, -- extra request-body fields, e.g. { reasoning_effort = "none" }
		timeout = 30, -- seconds for the curl call
	},
	-- deep-merged over `ai` per call path; nil = use `ai` as-is. Use for a
	-- different model or mode per scope, e.g. ai_ask = { params = { ... } }
	ai_analysis = nil,
	ai_ask = nil,
}

M.options = nil

function M.setup(opts)
	M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
	return M.options
end

function M.get()
	return M.options or M.setup({})
end

return M
