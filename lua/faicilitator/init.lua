-- FAIcilitator.nvim: monitors what you do (configurable recorders), sends a
-- compact transcript to an openai-compatible AI, and shows brief suggestions
-- for quicker vim motions/macros. Teaching, not nagging.

local config = require("faicilitator.config")
local tracker = require("faicilitator.tracker")
local ai = require("faicilitator.ai")
local awareness = require("faicilitator.awareness")

local M = {}

M.state = {
	enabled = true,
	pending = false, -- an analysis request is in flight
	last_run = 0, -- os.time() of last analysis attempt
	timer = nil,
	history = {}, -- { time, reason, suggestions } newest last, capped at 50
}

-- bottom-anchored message float: covers the message area BELOW the
-- statusline, never triggers the blocking hit-enter prompt. One at a time;
-- the next message replaces it.
local echo_win, echo_buf

local function close_echo_float()
	if echo_win and vim.api.nvim_win_is_valid(echo_win) then
		vim.api.nvim_win_close(echo_win, true)
	end
	echo_win = nil
end

local function echo_float(msg, warn)
	local width = vim.o.columns - 2
	local lines = {}
	for _, l in ipairs(vim.split(msg:gsub("^", "FAIcilitator: "), "\n", { plain = true })) do
		for i = 1, math.max(1, #l), width do
			lines[#lines + 1] = l:sub(i, i + width - 1)
		end
	end
	local maxh = math.max(3, math.floor(vim.o.lines * 0.4))
	if #lines > maxh then
		local kept = { "… full message in :FAIcilitatorLog" }
		vim.list_extend(kept, vim.list_slice(lines, #lines - maxh + 2, #lines))
		lines = kept
	end
	if not (echo_buf and vim.api.nvim_buf_is_valid(echo_buf)) then
		echo_buf = vim.api.nvim_create_buf(false, true)
	end
	vim.api.nvim_buf_set_lines(echo_buf, 0, -1, false, lines)
	if not (echo_win and vim.api.nvim_win_is_valid(echo_win)) then
		echo_win = vim.api.nvim_open_win(echo_buf, false, {
			relative = "editor",
			anchor = "SW",
			row = vim.o.lines - vim.o.cmdheight, -- bottom edge on the message row, under the statusline
			col = 0,
			width = width,
			height = #lines,
			style = "minimal",
			focusable = false,
			zindex = 60,
		})
		vim.wo[echo_win].wrap = false
	else
		vim.api.nvim_win_set_height(echo_win, #lines)
	end
	if warn then
		for i = 0, #lines - 1 do
			vim.api.nvim_buf_add_highlight(echo_buf, -1, "WarningMsg", i, 0, -1)
		end
	end
end

local function notify(msg, level)
	local opts = config.get()
	level = level or opts.notify.level
	if opts.display == "echo" then
		-- one render area only: short messages native-echo into the message
		-- row, long ones take the float covering exactly that row
		if not msg:find("\n") and #msg + 15 <= vim.o.columns then
			close_echo_float()
			vim.api.nvim_echo({ { "FAIcilitator: ", "Title" }, { msg, "Normal" } }, true, {})
		else
			echo_float(msg, level >= vim.log.levels.WARN)
		end
	else
		vim.notify(msg, level, { title = "FAIcilitator" })
	end
end

--- Append an entry to the persisted JSONL history (no-op if persist=false).
--- Rotates to the newest half of the file when max_file_kb is exceeded.
local function persist_entry(entry)
	local hcfg = config.get().history
	if not hcfg.persist then
		return
	end
	local line = vim.json.encode(entry)
	local st = vim.uv.fs_stat(hcfg.file)
	if st and st.size > hcfg.max_file_kb * 1024 then
		local old = {}
		local fd = vim.uv.fs_open(hcfg.file, "r", 420)
		if fd then
			local data = vim.uv.fs_read(fd, st.size, 0)
			vim.uv.fs_close(fd)
			for l in tostring(data or ""):gmatch("[^\n]+") do
				old[#old + 1] = l
			end
			local half = {}
			for i = math.max(1, math.floor(#old / 2)), #old do
				half[#half + 1] = old[i]
			end
			local wf = vim.uv.fs_open(hcfg.file, "w", 420)
			if wf then
				vim.uv.fs_write(wf, table.concat(half, "\n") .. "\n", 0)
				vim.uv.fs_close(wf)
			end
		end
	end
	local fd = vim.uv.fs_open(hcfg.file, "a", 420)
	if fd then
		vim.uv.fs_write(fd, line .. "\n", -1)
		vim.uv.fs_close(fd)
	end
end

--- Read every persisted entry (parse-time failure tolerance per line).
--- @return table[] entries with { time, reason, suggestions, question? }
local function read_persisted()
	local entries = {}
	local hcfg = config.get().history
	local fd = vim.uv.fs_open(hcfg.file, "r", 420)
	if not fd then
		return entries
	end
	local data = vim.uv.fs_read(fd, assert(vim.uv.fs_stat(hcfg.file)).size, 0)
	vim.uv.fs_close(fd)
	for l in tostring(data or ""):gmatch("[^\n]+") do
		local ok, e = pcall(vim.json.decode, l)
		if ok and type(e) == "table" and e.suggestions then
			entries[#entries + 1] = e
		end
	end
	return entries
end

--- Register a result entry: in-memory, on disk, and notify.
--- @param entry table { reason, suggestions, question? }
--- @param notify_text string
local function record_entry(entry, notify_text)
	persist_entry(entry)
	local h = M.state.history
	h[#h + 1] = entry
	if #h > 50 then
		table.remove(h, 1)
	end
	notify(notify_text)
end

local function record_result(reason, suggestions)
	local opts = config.get()
	local items = {}
	for i, s in ipairs(suggestions) do
		if i > opts.notify.max_suggestions then
			break
		end
		items[#items + 1] = "- " .. s
	end
	record_entry({ time = os.date("%Y-%m-%d %H:%M"), reason = reason, suggestions = items }, table.concat(items, "\n"))
end

local function can_analyze()
	local cfg = config.get()
	return cfg.enabled and M.state.enabled and not M.state.pending and (os.time() - M.state.last_run) >= cfg.cooldown
end

--- Collect the optional editing context (buffer lines around cursor,
--- unnamed register) per the context.* options. Content is truncated.
--- @return table ctx for faicilitator.ai.analyze
local function collect_context()
	local c = config.get().context
	local ctx = { filetype = vim.bo.filetype }
	if c.buffer_lines > 0 and vim.bo.buftype == "" then
		local row = vim.api.nvim_win_get_cursor(0)[1]
		local first = math.max(1, row - c.buffer_lines)
		local lines = vim.api.nvim_buf_get_lines(0, first - 1, row + c.buffer_lines, false)
		for i, l in ipairs(lines) do
			if #l > 300 then
				lines[i] = l:sub(1, 300) .. "…"
			end
		end
		ctx.cursor = { row = row, first = first, lines = lines }
	end
	if c.register then
		local reg = vim.fn.getreg('"')
		if reg ~= "" then
			ctx.register = #reg > 1000 and (reg:sub(1, 1000) .. "…") or reg
		end
	end
	return ctx
end

--- Attach the config-inventory block for the given scope
--- ("analysis"|"ask") per the awareness options.
local function attach_awareness(ctx, scope, question)
	local a = config.get().awareness[scope]
	if a then
		ctx.awareness = awareness.render(a, scope == "ask", question)
	end
end

--- Run one analysis. force=true bypasses cooldown/min_events (:FAIcilitator).
--- @param reason "timer"|"events"|"manual"
--- @param force boolean?
function M.analyze(reason, force)
	if not M.state.enabled then
		if force then
			notify("paused (:FAIcilitatorToggle to resume)", vim.log.levels.WARN)
		end
		return
	end
	if M.state.pending or (not force and not can_analyze()) then
		return
	end
	local opts = config.get()
	local transcript = tracker.render(opts.transcript_events)
	if transcript == "" then
		if force then
			notify("no activity recorded yet")
		end
		return
	end
	M.state.pending = true
	M.state.last_run = os.time()
	-- pcall: a throw inside context building (awareness/plugins/file reads)
	-- must not wedge pending forever — that silently disables all later analyses
	local ok, launch_err = pcall(function()
		local ctx = collect_context()
		attach_awareness(ctx, "analysis")
		ai.analyze(
			transcript,
			ctx,
			vim.schedule_wrap(function(suggestions, err)
				M.state.pending = false
				if err then
					notify("analysis failed: " .. err, vim.log.levels.WARN)
					return
				end
				tracker.clear() -- next run gets fresh material
				if suggestions and #suggestions > 0 then
					record_result(reason, suggestions)
				end
			end)
		)
	end)
	if not ok then
		M.state.pending = false
		notify("analysis failed: " .. tostring(launch_err), vim.log.levels.WARN)
	end
end

function M.toggle()
	M.state.enabled = not M.state.enabled
	notify(M.state.enabled and "resumed" or "paused")
end

--- Ask the model how to perform a specific action, with editing context.
--- @param question string
function M.ask(question)
	if not M.state.enabled then
		notify("paused (:FAIcilitatorToggle to resume)", vim.log.levels.WARN)
		return
	end
	if M.state.pending then
		notify("busy — try again in a moment", vim.log.levels.WARN)
		return
	end
	question = vim.trim(question or "")
	if question == "" then
		return
	end
	M.state.pending = true
	-- pcall: a throw before the request starts must not wedge pending (→ every
	-- later ask would say "busy"); see analyze() for the same pattern
	local ok, launch_err = pcall(function()
		local ctx = collect_context()
		attach_awareness(ctx, "ask", question)
		ai.ask(
			question,
			ctx,
			vim.schedule_wrap(function(answer, err)
				M.state.pending = false
				if err then
					notify("ask failed: " .. err, vim.log.levels.WARN)
					return
				end
				record_entry({
					time = os.date("%Y-%m-%d %H:%M"),
					reason = "ask",
					question = question,
					suggestions = vim.split(answer, "\n", { trimempty = true }),
				}, "Q: " .. question .. "\n" .. answer)
			end)
		)
	end)
	if not ok then
		M.state.pending = false
		notify("ask failed: " .. tostring(launch_err), vim.log.levels.WARN)
	end
end

-- markdown lines for one history entry (shared by split fallback + preview)
local function entry_lines(e)
	local lines = { string.format("## %s (%s)", e.time, e.reason) }
	if e.question then
		lines[#lines + 1] = "**Q:** " .. e.question
	end
	vim.list_extend(lines, e.suggestions)
	lines[#lines + 1] = ""
	return lines
end

-- telescope picker: one row per request, fuzzy over display AND content,
-- full entry in the preview pane
local function show_log_telescope(h)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local previewers = require("telescope.previewers")
	local results = {}
	for i = #h, 1, -1 do
		results[#results + 1] = h[i]
	end
	pickers
		.new({}, {
			prompt_title = "FAIcilitator history",
			sorting_strategy = "ascending",
			layout_config = { prompt_position = "top" },
			finder = finders.new_table({
				results = results,
				entry_maker = function(e)
					local first = e.question or (e.suggestions[1] or "")
					return {
						value = e,
						display = string.format("%s (%s)  %s", e.time, e.reason, first:gsub("\n", " ")),
						ordinal = table.concat(
							vim.list_extend({ e.time, e.reason, e.question or "" }, e.suggestions),
							" "
						),
					}
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				title = "Suggestion",
				define_preview = function(self, entry)
					local lines = entry_lines(entry.value)
					lines[#lines] = nil -- trailing blank
					vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
					vim.bo[self.state.bufnr].filetype = "markdown"
				end,
			}),
		})
		:find()
end

function M.show_log()
	-- full history: persisted entries first (survive restarts), plus any
	-- in-memory entries written with persist=false
	local h = read_persisted()
	if not config.get().history.persist then
		h = M.state.history
	end
	if #h == 0 then
		notify("no suggestions yet")
		return
	end
	if pcall(require, "telescope.pickers") then
		show_log_telescope(h)
		return
	end
	-- fallback: markdown split
	local lines = {}
	for i = #h, 1, -1 do
		vim.list_extend(lines, entry_lines(h[i]))
	end
	vim.cmd("botright new")
	local buf = vim.api.nvim_get_current_buf()
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "markdown"
	vim.bo[buf].modifiable = false
end

local function timer_tick()
	if not can_analyze() then
		return
	end
	if tracker.pending < config.get().timer.min_events then
		return
	end
	M.analyze("timer", false)
end

local function on_event()
	local cfg = config.get()
	if tracker.pending >= cfg.events.threshold and can_analyze() then
		M.analyze("events", false)
	end
end

function M.setup(opts)
	local cfg = config.setup(opts)
	M.state.enabled = cfg.enabled
	tracker.start()
	tracker.on_event = on_event
	-- the echo float lives on the cmdline row: hide it while the user types
	vim.api.nvim_create_autocmd("CmdlineEnter", {
		group = vim.api.nvim_create_augroup("FAIcilitatorEcho", { clear = true }),
		callback = close_echo_float,
	})
	if M.state.timer then
		M.state.timer:stop()
		M.state.timer:close()
		M.state.timer = nil
	end
	if cfg.timer.interval > 0 then
		local timer = vim.uv.new_timer()
		timer:start(cfg.timer.interval * 1000, cfg.timer.interval * 1000, vim.schedule_wrap(timer_tick))
		M.state.timer = timer
	end
	vim.api.nvim_create_user_command("FAIcilitator", function()
		M.analyze("manual", true)
	end, { desc = "Analyze recent activity and suggest better vim motions" })
	vim.api.nvim_create_user_command("FAIcilitatorLog", function()
		M.show_log()
	end, { desc = "Show FAIcilitator suggestion history" })
	vim.api.nvim_create_user_command("FAIcilitatorToggle", function()
		M.toggle()
	end, { desc = "Pause/resume FAIcilitator" })
	vim.api.nvim_create_user_command("FAIcilitatorAsk", function(cmd)
		if cmd.args ~= "" then
			M.ask(cmd.args)
		else
			vim.ui.input({ prompt = "How do I… " }, function(q)
				if q then
					M.ask(q)
				end
			end)
		end
	end, { nargs = "?", desc = "Ask the AI how to do something, the best vim way" })
end

return M
