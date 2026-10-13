-- FAIcilitator.nvim activity tracker: configurable recorders feeding a ring
-- buffer, plus aggregation into a compact transcript for the AI.

local config = require("faicilitator.config")

local M = {}

M.ns = nil -- namespace for vim.on_key
M.augroup = nil
M.events = {}
M.pending = 0 -- events recorded since the last analysis
M.on_event = nil -- optional hook, called (cheap) after every event
M.ignore_keys = false -- set while our own ask prompt is open (don't self-record)
M.prompt_buf = nil -- buffer that was current when the prompt opened

local function push(ev)
	local opts = config.get()
	local e = M.events
	e[#e + 1] = ev
	if #e > opts.max_events then
		-- drop oldest 10% in one go (amortized, not per event)
		local drop = math.max(1, math.floor(opts.max_events / 10))
		local ne = {}
		for i = drop + 1, #e do
			ne[#ne + 1] = e[i]
		end
		M.events = ne
	end
	M.pending = M.pending + 1
	if M.on_event then
		M.on_event()
	end
end

local function record_key(key, typed)
	-- never record our own ask prompt (typing the question is not editing),
	-- terminal input (passwords, shell commands) or cmdline keystrokes (the
	-- commands recorder already captures the full line)
	-- (ignore while the prompt owns the focus: current buffer isn't the one
	-- the prompt was opened from; works with any vim.ui.input implementation)
	if M.ignore_keys and vim.api.nvim_get_current_buf() ~= M.prompt_buf then
		return
	end
	local mode = vim.api.nvim_get_mode().mode
	if mode:sub(1, 1) == "t" or mode:sub(1, 1) == "c" then
		return
	end
	local k = typed and typed ~= "" and typed or key
	push({ kind = "key", t = os.time(), mode = mode, key = vim.fn.keytrans(k) })
end

local function record_cmdline()
	local line = vim.fn.getcmdline()
	if line == "" then
		return
	end
	push({ kind = "cmd", t = os.time(), cmdtype = vim.fn.getcmdtype(), line = line })
end

local function record_yank()
	local ev = vim.v.event
	push({ kind = "yank", t = os.time(), op = ev.operator, lines = #ev.regcontents })
end

local function record_buffer()
	push({ kind = "buf", t = os.time(), name = vim.fn.expand("%:t") })
end

function M.start()
	local opts = config.get()
	M.stop()
	M.augroup = vim.api.nvim_create_augroup("FAIcilitator", { clear = true })
	if opts.record.keys then
		M.ns = M.ns or vim.api.nvim_create_namespace("faicilitator")
		vim.on_key(function(key, typed)
			pcall(record_key, key, typed) -- on_key errors break input
		end, M.ns)
	end
	if opts.record.commands then
		vim.api.nvim_create_autocmd("CmdlineLeave", { group = M.augroup, callback = record_cmdline })
	end
	if opts.record.yanks then
		vim.api.nvim_create_autocmd("TextYankPost", { group = M.augroup, callback = record_yank })
	end
	if opts.record.buffers then
		vim.api.nvim_create_autocmd("BufEnter", { group = M.augroup, callback = record_buffer })
	end
end

function M.stop()
	if M.ns then
		vim.on_key(nil, M.ns)
	end
	if M.augroup then
		pcall(vim.api.nvim_del_augroup_by_id, M.augroup)
		M.augroup = nil
	end
end

function M.clear()
	M.events = {}
	M.pending = 0
end

function M.reset_pending()
	M.pending = 0
end

--- Aggregate consecutive identical keys and render the transcript.
--- @param limit integer max aggregated lines returned
--- @return string
function M.render(limit)
	local agg = {}
	for _, ev in ipairs(M.events) do
		local last = agg[#agg]
		if ev.kind == "key" and last and last.kind == "key" and last.mode == ev.mode and last.key == ev.key then
			last.n = last.n + 1
		elseif ev.kind == "key" then
			agg[#agg + 1] = { kind = "key", mode = ev.mode, key = ev.key, n = 1, t = ev.t }
		elseif ev.kind == "cmd" then
			agg[#agg + 1] = { kind = "cmd", cmdtype = ev.cmdtype, line = ev.line, t = ev.t }
		elseif ev.kind == "yank" then
			agg[#agg + 1] = { kind = "yank", op = ev.op, lines = ev.lines, t = ev.t }
		else
			agg[#agg + 1] = { kind = "buf", name = ev.name, t = ev.t }
		end
	end
	if #agg > limit then
		local ne = {}
		for i = #agg - limit + 1, #agg do
			ne[#ne + 1] = agg[i]
		end
		agg = ne
	end
	local lines = {}
	for _, e in ipairs(agg) do
		local ts = os.date("%H:%M:%S", e.t)
		if e.kind == "key" then
			local rep = e.n > 1 and (" (x" .. e.n .. ")") or ""
			lines[#lines + 1] = string.format("[%s] key(%s): %s%s", ts, e.mode, e.key, rep)
		elseif e.kind == "cmd" then
			lines[#lines + 1] = string.format("[%s] cmdline(%s): %s", ts, e.cmdtype, e.line)
		elseif e.kind == "yank" then
			lines[#lines + 1] = string.format("[%s] op %s: %d lines", ts, e.op, e.lines)
		else
			lines[#lines + 1] = string.format("[%s] buffer: %s", ts, e.name)
		end
	end
	return table.concat(lines, "\n")
end

return M
