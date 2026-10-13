-- FAIcilitator.nvim AI client: openai-compatible /chat/completions via curl.
-- No built-in provider: endpoint, model and key all come from setup().
--
-- PRIVACY: the transcript (keypresses, ex commands, search patterns) is sent
-- to the configured endpoint. Terminal-mode input is never recorded.

local config = require("faicilitator.config")

local M = {}

local SYSTEM = table.concat({
	"You are a Neovim coach embedded in the editor. You are given a transcript of",
	"the user's recent activity (keypresses grouped with counts, :ex commands,",
	"searches). Spot moments where the same result could have been achieved with",
	"quicker or smarter vim technique: motions (w, e, b, f, t, %, *, CTRL-O/CTRL-I),",
	"counts, text objects (iw, ap...), operators, the dot-repeat, and macros (q/@).",
	"Reply with ONLY a JSON array of 0-3 strings. Each string is one short, concrete",
	"suggestion (<= 120 chars) referencing the actual keys or commands seen.",
	"Return [] if nothing is clearly improvable. No text outside the JSON array.",
	"If buffer lines around the cursor or the unnamed register are included, use",
	"them to ground suggestions in what was actually being edited.",
	"If the user's keymaps, commands or plugins are listed, prefer solutions that",
	"use them, and never suggest a key that is already remapped to something else.",
}, "\n")

local ASK_SYSTEM = table.concat({
	"You are a Neovim expert answering how-to questions about editing.",
	"Reply with at most 3 numbered options, most efficient first. Each option:",
	"the exact keystrokes or ex command in backticks, a <= 12-word explanation.",
	"Use any provided buffer context to make the answer concrete.",
	"If the user's keymaps, commands or plugins are listed, use what exists",
	"(e.g. their <leader> mappings, plugin commands) over vanilla equivalents.",
	"No preamble, no closing remarks, no markdown headers.",
}, "\n")

local function resolve_key(ai)
	if ai.api_key and ai.api_key ~= "" then
		return ai.api_key
	end
	local env = ai.api_key_env and vim.env[ai.api_key_env]
	if env and env ~= "" then
		return env
	end
	return nil
end

-- validate endpoint/model/key; cb-received error string on failure
local function guard(ai, cb)
	if not ai.endpoint or ai.endpoint == "" or not ai.model or ai.model == "" then
		cb(nil, "ai.endpoint and ai.model must be set in setup()")
		return false
	end
	if not resolve_key(ai) then
		cb(nil, "no API key (pass ai.api_key in setup() or set $" .. (ai.api_key_env or "?") .. ")")
		return false
	end
	return true
end

-- one async completion; cb gets raw text content or an error
local function complete(ai, system, user, cb)
	local body_tbl = {
		model = ai.model,
		messages = {
			{ role = "system", content = system },
			{ role = "user", content = user },
		},
		temperature = 0.2,
		max_tokens = 512,
	}
	for k, v in pairs(ai.params or {}) do
		body_tbl[k] = v
	end
	local body = vim.json.encode(body_tbl)
	local url = ai.endpoint:gsub("/+$", "") .. "/chat/completions"
	vim.system({
		"curl",
		"-sS",
		"--max-time",
		tostring(ai.timeout),
		"-X",
		"POST",
		url,
		"-H",
		"Content-Type: application/json",
		"-H",
		"Authorization: Bearer " .. resolve_key(ai),
		"-d",
		"@-",
	}, { stdin = body, text = true }, function(res)
		-- NB: this callback is NOT on the main loop; cb must be schedule-wrapped
		if res.code ~= 0 then
			cb(nil, "curl failed: " .. vim.trim(res.stderr or ""))
			return
		end
		local ok, data = pcall(vim.json.decode, res.stdout)
		if not ok or type(data) ~= "table" then
			cb(nil, "non-JSON response: " .. res.stdout:sub(1, 200))
			return
		end
		if data.error then
			local msg = type(data.error) == "table" and data.error.message or vim.inspect(data.error)
			cb(nil, "API error: " .. tostring(msg))
			return
		end
		local choice = data.choices and data.choices[1]
		local content = choice and choice.message and choice.message.content
		if not content then
			cb(nil, "empty response: " .. res.stdout:sub(1, 200))
			return
		end
		cb(content)
	end)
end

--- Parse model output into a list of suggestion strings.
--- @param content string
--- @return string[]
function M.parse(content)
	local arr = content:match("%[.*%]") -- lua patterns: . matches newlines too
	if arr then
		local ok, decoded = pcall(vim.json.decode, arr)
		if ok and type(decoded) == "table" then
			local out = {}
			for _, v in ipairs(decoded) do
				if type(v) == "string" and v ~= "" then
					out[#out + 1] = v
				end
			end
			return out
		end
	end
	-- fallback: one suggestion per non-empty line, bullets/numbering stripped
	local out = {}
	for line in content:gmatch("[^\n]+") do
		line = line:gsub("^%s*[-*]%s*", ""):gsub("^%s*%d+[.)]%s*", "")
		if line ~= "" then
			out[#out + 1] = line
		end
	end
	return out
end

-- append filetype / cursor-region / register sections to a prompt parts list
local function append_context(parts, ctx)
	parts[#parts + 1] = "Context: filetype=" .. (ctx.filetype or "?")
	if ctx.cursor then
		parts[#parts + 1] = string.format("Buffer lines around the cursor (cursor on line %d):", ctx.cursor.row)
		for i, l in ipairs(ctx.cursor.lines) do
			local ln = ctx.cursor.first + i - 1
			parts[#parts + 1] = string.format("%s%4d| %s", ln == ctx.cursor.row and ">" or " ", ln, l)
		end
	end
	if ctx.register then
		parts[#parts + 1] = 'Unnamed register (last yank/delete):\n"""\n' .. ctx.register .. '\n"""'
	end
	if ctx.awareness then
		parts[#parts + 1] = "User's Neovim config inventory:\n" .. ctx.awareness
	end
end

-- base ai config deep-merged with the scope override (ai_analysis / ai_ask)
local function scoped_ai(scope)
	local cfg = config.get()
	return vim.tbl_deep_extend("force", cfg.ai, cfg["ai_" .. scope] or {})
end

--- Analyze a transcript asynchronously.
--- ctx: { filetype?, cursor? = { row, first, lines }, register? }
--- @param transcript string
--- @param ctx table
--- @param cb fun(suggestions: string[]|nil, err: string|nil)
function M.analyze(transcript, ctx, cb)
	local ai = scoped_ai("analysis")
	if not guard(ai, cb) then
		return
	end
	local parts = {}
	append_context(parts, ctx)
	parts[#parts + 1] = "Recent activity transcript (oldest to newest):\n" .. transcript
	complete(ai, SYSTEM, table.concat(parts, "\n"), function(content, err)
		if err then
			cb(nil, err)
			return
		end
		cb(M.parse(content))
	end)
end

--- Answer a free-form how-to question asynchronously.
--- @param question string
--- @param ctx table as for analyze()
--- @param cb fun(answer: string|nil, err: string|nil)
function M.ask(question, ctx, cb)
	local ai = scoped_ai("ask")
	if not guard(ai, cb) then
		return
	end
	local parts = { "Question: " .. question }
	append_context(parts, ctx)
	complete(ai, ASK_SYSTEM, table.concat(parts, "\n"), function(content, err)
		if err then
			cb(nil, err)
			return
		end
		cb(vim.trim(content))
	end)
end

return M
