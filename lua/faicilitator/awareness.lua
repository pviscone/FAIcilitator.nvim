-- FAIcilitator.nvim config awareness: renders the user's keymaps, commands
-- and installed plugins as compact prompt sections, so the model can suggest
-- what actually exists in this config (and never a key already remapped).

local M = {}

local MAX_BLOCK = 4000 -- chars kept per awareness block

-- compact = interesting keys only: leader maps, single chars, single modified
-- keys (<S-H>, <C-w>); full = every n/v mapping
local function keymap_hit(lhs, leader)
	if #lhs <= 1 then
		return true
	end
	if leader and (lhs:sub(1, #leader) == leader or lhs:sub(1, 1) == " ") then
		return true
	end
	local inner = lhs:match("^<%u%-(.+)>$") -- <S-H>, <C-/>…
	return inner ~= nil and #inner <= 2
end

--- @param mode "compact"|"full"
--- @return string[]
local function collect_keymaps(mode)
	local leader = vim.g.mapleader == " " and "<Space>" or vim.g.mapleader
	local out = {}
	for _, m in ipairs({ "n", "v" }) do
		for _, map in ipairs(vim.api.nvim_get_keymap(m)) do
			if mode == "full" or keymap_hit(map.lhs, leader) then
				local rhs = vim.trim((map.desc ~= "" and map.desc) or vim.fn.keytrans(map.rhs or ""))
				out[#out + 1] = string.format("%s: %s -> %s", m, map.lhs, rhs:sub(1, 60))
			end
		end
	end
	table.sort(out)
	return out
end

--- @param with_desc boolean ask scope gets descriptions, analysis names only
local function collect_commands(with_desc)
	local cmds = vim.api.nvim_get_commands({ builtin = false })
	local names = vim.tbl_keys(cmds)
	table.sort(names)
	if not with_desc then
		local out = {}
		for _, n in ipairs(names) do
			out[#out + 1] = ":" .. n
		end
		return { table.concat(out, ", ") }
	end
	local out = {}
	for _, n in ipairs(names) do
		local desc = cmds[n].desc
		out[#out + 1] = ":" .. n .. (desc and desc ~= "" and (" — " .. desc:sub(1, 50)) or "")
	end
	return out
end

local function collect_plugins()
	local zok, api = pcall(require, "zpack.api")
	if zok then
		local names = {}
		for _, p in ipairs(api.get_plugins()) do
			names[#names + 1] = p.name
		end
		if #names > 0 then
			table.sort(names)
			return names
		end
	end
	if vim.pack and vim.pack.get then -- vim.pack-only users
		local names = {}
		for _, p in ipairs(vim.pack.get()) do
			names[#names + 1] = p.spec and p.spec.name or p.name
		end
		table.sort(names)
		return names
	end
	return {}
end

-- ── plugin doc snippets: keyword retrieval at ask time, nothing cached ──────

local STOP = {
	["how"] = true,
	["do"] = true,
	["does"] = true,
	["the"] = true,
	["a"] = true,
	["an"] = true,
	["to"] = true,
	["of"] = true,
	["in"] = true,
	["on"] = true,
	["with"] = true,
	["all"] = true,
	["only"] = true,
	["current"] = true,
	["and"] = true,
	["or"] = true,
	["is"] = true,
	["are"] = true,
	["what"] = true,
	["i"] = true,
	["can"] = true,
	["use"] = true,
	["way"] = true,
	["best"] = true,
	["for"] = true,
	["my"] = true,
	["me"] = true,
	["this"] = true,
	["that"] = true,
	["from"] = true,
}

local function terms_of(question)
	local terms = {}
	for w in question:lower():gmatch("[%w_]+") do
		if #w >= 3 and not STOP[w] then
			terms[#terms + 1] = w
		end
	end
	return terms
end

-- window around the first hit of any term, ~200 chars of lead context
local function snippet_of(text, terms, len)
	local lower = text:lower()
	local pos
	for _, w in ipairs(terms) do
		local p = lower:find(vim.pesc(w))
		if p and (not pos or p < pos) then
			pos = p
		end
	end
	pos = pos or 1
	local first = math.max(1, pos - 200)
	return text:sub(first, math.min(#text, first + len)), pos > 1
end

--- Find relevant doc snippets across installed plugins for a question.
--- Score: normalized plugin-name mention ×10 plus term hits (capped ×3).
--- Empty/missing docs are skipped. Nothing is written to disk.
--- @param question string
--- @param cap integer total chars budget
--- @return string|nil
function M.doc_snippets(question, cap)
	-- vim.pack.get() errors without a git executable
	local ok, packs = pcall(vim.pack.get)
	if not (ok and packs) then
		return nil
	end
	local terms = terms_of(question)
	local qnorm = question:lower():gsub("[%._%-]", "")
	local scored = {}
	for _, p in ipairs(packs) do
		local name = (p.spec and p.spec.name) or "?"
		if p.path then
			local files = vim.fn.globpath(p.path .. "/doc", "*.txt", false, true)
			local text = ""
			for _, f in ipairs(files) do
				local ok, lines = pcall(vim.fn.readfile, f)
				if ok then
					text = text .. "\n" .. table.concat(lines, "\n")
				end
			end
			if text ~= "" then
				local score = 0
				local nnorm = name:lower():gsub("[%._%-]", "")
				if #nnorm >= 3 and qnorm:find(nnorm, 1, true) then
					score = score + 10
				end
				local lower = text:lower()
				for _, w in ipairs(terms) do
					local _, n = lower:gsub(vim.pesc(w), "")
					score = score + math.min(n, 3)
				end
				if score > 0 then
					scored[#scored + 1] = { name = name, score = score, text = text }
				end
			end
		end
	end
	table.sort(scored, function(a, b)
		return a.score > b.score
	end)
	local out, size = {}, 0
	for i = 1, math.min(2, #scored) do
		local s = scored[i]
		local piece = snippet_of(s.text, terms, math.min(600, cap - size - 80))
		local block = "### doc: " .. s.name .. "\n" .. vim.trim(piece)
		out[#out + 1] = block
		size = size + #block + 1
		if size >= cap then
			break
		end
	end
	return #out > 0 and table.concat(out, "\n\n") or nil
end

--- Render the awareness block for one scope.
--- @param opts table { keymaps = "compact"|"full"|false, commands = bool, plugins = bool, docs = bool }
--- @param with_desc boolean richer rendering for interactive scopes
--- @param question string? needed for docs snippet retrieval (ask scope)
--- @return string|nil
function M.render(opts, with_desc, question)
	-- section budgets so the block always fits the total; ask scope (docs)
	-- raises the cap since asks are rare
	local total = opts.docs and 6000 or MAX_BLOCK
	local PLUGIN_CAP, CMD_CAP, DOC_CAP = 800, 1600, 1400
	local parts = {}
	if opts.docs and question then
		local docs = M.doc_snippets(question, DOC_CAP)
		if docs then
			parts[#parts + 1] = "Relevant plugin docs:\n" .. docs
		end
	end
	if opts.plugins then
		local plugins = collect_plugins()
		if #plugins > 0 then
			local s = "Installed plugins: " .. table.concat(plugins, ", ")
			if #s > PLUGIN_CAP then
				s = s:sub(1, PLUGIN_CAP) .. "…"
			end
			parts[#parts + 1] = s
		end
	end
	if opts.commands then
		local cmds = collect_commands(with_desc)
		local kept, size = {}, 0
		for _, line in ipairs(cmds) do
			if size + #line > CMD_CAP then
				break
			end
			kept[#kept + 1] = line
			size = size + #line + 1
		end
		if #kept > 0 then
			parts[#parts + 1] = "Defined commands"
				.. (#kept < #cmds and " (" .. #cmds - #kept .. " omitted)" or "")
				.. ":\n"
				.. table.concat(kept, "\n")
		end
	end
	if opts.keymaps then
		local maps = collect_keymaps(opts.keymaps)
		local used = #table.concat(parts, "\n\n")
		local budget = total - used - 100 -- header + omissions note
		local kept, size = {}, 0
		for _, line in ipairs(maps) do
			if size + #line > budget then
				break
			end
			kept[#kept + 1] = line
			size = size + #line + 1
		end
		if #kept > 0 then
			local omitted = #maps - #kept
			local header = string.format(
				"Custom keymaps (%s%s, %d):",
				opts.keymaps,
				omitted > 0 and (", " .. omitted .. " more omitted") or "",
				#maps
			)
			table.insert(parts, 1, header .. "\n" .. table.concat(kept, "\n"))
		end
	end
	local s = table.concat(parts, "\n\n")
	return s ~= "" and s or nil
end

return M
