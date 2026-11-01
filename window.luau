--!strict
-- Alt+Shift+G: one score.
-- Palette "Open Exercises Beside This Pane": a column of exercise panes.
-- Agent channel: write <plugin data>/open-request.json {"root": "..."} and the
-- window half lays it out within a tick (the CLI has no way to run a command).

local SAMPLE = "D:/L/Guitar/吉他谱/Tears in Heaven.musicxml"
local EXERCISES = "D:/L/AI/exercises"
local PYTHON_EXE = "D:/programs/Python/python.exe"
local REQUEST = tern.plugin.data .. "/open-request.json"
local DRAFT_REQUESTS = tern.plugin.data .. "/draft_requests"
local REQUEST_END_SENTINEL = "\n__GSCORE_END__\n"
local POLL_MS = 400

-- Async process results wait here until poll provides a live SessionContext for UI work.
type DraftResult = {
	res: any,
	outPath: string,
	template: string,
	bars: any,
	sourcePane: any,
}
local draftResults: { DraftResult } = {}

local function scoreFiles(dir: string): { string }
	local out = {}
	pcall(function()
		for _, name in ipairs(tern.fs.list(dir)) do
			if name:match("%.musicxml$") or name:match("%.gp%d?$") or name:match("%.gpx$") then
				table.insert(out, dir .. "/" .. name)
			end
		end
	end)
	table.sort(out)
	return out
end

-- one column on the right of the focused pane, one row per score
local mine: { number } = {}


local function openList(cx: any, files: { string }, isDraft: boolean?, preferredAnchor: any?)
	if #files == 0 then
		cx:toast("error", "No score files")
		return
	end
	local previous = tern.kv.get("panes") or {}
	mine = previous
	-- Prefer the pane that launched a draft; fall back when it has since closed.
	local anchor = nil
	if preferredAnchor ~= nil then
		local wanted = tostring(preferredAnchor)
		for _, info in cx.session:panes() do
			if tostring(info.pane) == wanted then
				anchor = info.pane
				break
			end
		end
	end
	if anchor == nil then
		anchor = cx.session:focused()
		if anchor == nil then
			for _, info in cx.session:panes() do
				anchor = info.pane
				break
			end
		end
	end
	if not anchor then
		cx:toast("error", "No pane to split from")
		return
	end
	local count = 0
	for _ in cx.session:panes() do
		count = count + 1
	end
	if count > 16 then
		cx:toast("warning", "Too many panes open", "close some, then retry")
		return
	end
	tern.kv.set("panes", mine)
	local a1 = { files[1] }
	if isDraft then table.insert(a1, "draft") end
	local column = cx.layout:split(anchor, "right", {
		block = "gscore.score", args = a1,
	})
	if not column then
		cx:toast("error", "Could not split the pane")
		return
	end
	table.insert(mine, column)
	local low = column
	for i = 2, #files do
		local pane = cx.layout:split(low, "down", {
			block = "gscore.score", args = { files[i] },
		})
		if not pane then
			break
		end
		low = pane
		table.insert(mine, pane)
	end
	tern.kv.set("panes", mine)
	if #files > 1 then
		cx.layout:resize(column, "down", -6)
	end
end

tern.command({
	id = "open",
	title = "Open Guitar Score",
	icon = "music",
	run = function(cx)
		cx:new_block("gscore.score", { SAMPLE }, nil, { focus = true })
	end,
})

tern.command({
	id = "exercises",
	title = "Open Exercises Beside This Pane",
	icon = "layers",
	run = function(cx)
		openList(cx, scoreFiles(EXERCISES))
	end,
})

tern.bind("alt+shift+g", "plugin.gscore.open")

-- agent channel -----------------------------------------------------------

-- Consume every complete per-request draft file; an incomplete write stays queued.
local function processDraftRequest(cx: any, path: string, requestId: string)
	local ok, text = pcall(tern.fs.read, path)
	if not ok or type(text) ~= "string"
		or text:sub(-#REQUEST_END_SENTINEL) ~= REQUEST_END_SENTINEL then
		return
	end
	pcall(tern.fs.remove, path)
	local body = text:sub(1, #text - #REQUEST_END_SENTINEL)
	local okj, spec = pcall(tern.json.decode, body)
	if not okj or type(spec) ~= "table" then
		cx:toast("error", "Bad draft request", requestId)
		return
	end
	local selFile = spec.selection_file
	local template = spec.template or "alternate_picking"
	local bpm = tostring(spec.bpm or 60)
	if type(selFile) ~= "string" or selFile == "" then
		cx:toast("error", "Draft failed", "request has no selection_file")
		return
	end
	if template ~= "alternate_picking" and template ~= "arpeggio" and template ~= "slow_drill" then
		cx:toast("error", "Draft failed", "unknown template: " .. tostring(template))
		return
	end

	local outPath = string.format("%s/drafts/draft_%s_%s.musicxml",
		tern.plugin.data, requestId, template)
	pcall(tern.fs.mkdir, tern.plugin.data .. "/drafts")
	cx:toast("info", "Generating draft…", template .. " @ " .. bpm .. " BPM")

	tern.process.run({
		PYTHON_EXE, tern.plugin.dir .. "/tools/generate_draft.py",
		"--selection", selFile,
		"--template", template,
		"--bpm", bpm,
		"--out", outPath,
	}, { timeout_ms = 60000 }):next(function(res)
		table.insert(draftResults, {
			res = res,
			outPath = outPath,
			template = template,
			bars = spec.bars,
			sourcePane = spec.source_pane,
		})
	end)
end

local function runDraftRequest(cx: any)
	local ok, names = pcall(tern.fs.list, DRAFT_REQUESTS)
	if not ok or type(names) ~= "table" then
		return
	end
	table.sort(names)
	for _, name in ipairs(names) do
		if name:match("^req_%d+_%d+%.json$") then
			processDraftRequest(cx, DRAFT_REQUESTS .. "/" .. name, name:gsub("%.json$", ""))
		end
	end
end

local function flushDraftResults(cx: any)
	while #draftResults > 0 do
		local result = table.remove(draftResults, 1)
		local res = result.res
		if not res or res.status ~= 0 or not tern.fs.exists(result.outPath) then
			cx:toast("error", "Draft generation failed",
				res and (res.stderr ~= "" and res.stderr or res.stdout) or "no output")
		else
			cx:toast("success", "Draft ready", result.template .. " · bars " ..
				tostring((result.bars or {})[1] or "?") .. "–" .. tostring((result.bars or {})[2] or "?"))
			openList(cx, { result.outPath }, true, result.sourcePane)
		end
	end
end

local function consume(cx: any)
	local ok, text = pcall(tern.fs.read, REQUEST)
	if not ok then
		return
	end
	pcall(tern.fs.remove, REQUEST)
	local okj, spec = pcall(tern.json.decode, text)
	if not okj or type(spec) ~= "table" then
		cx:toast("error", "Bad open-request.json")
		return
	end
	if type(spec.close) == "table" then
		for _, id in ipairs(spec.close) do
			pcall(function()
				cx.layout:close(tonumber(id) or id)
			end)
		end
	end
	if spec.dump then
		local rows = {}
		for _, info in cx.session:panes() do
			table.insert(rows, string.format("%s|%s|%s|%s", tostring(info.pane),
				tostring(info.program), tostring(info.title), tostring(info.cwd)))
		end
		pcall(tern.fs.write, tern.plugin.data .. "/panes.txt", table.concat(rows, "\n"))
		return
	end
	if spec.library then
		local dir = if type(spec.library) == "string" then spec.library else nil
		-- reuse the library pane when it is still open
		local old = tonumber(tern.kv.get("libraryPane") or 0)
		if old and old ~= 0 then
			for _, info in cx.session:panes() do
				if info.pane == old then
					cx.layout:focus(old)
					return
				end
			end
			tern.kv.set("libraryPane", 0)
		end
		local anchor0 = cx.session:focused()
		if not anchor0 then
			return
		end
		local pane = cx.layout:split(anchor0, "right", {
			block = "gscore.library",
			args = if dir then { dir } else {},
		})
		if pane then
			tern.kv.set("libraryPane", pane)
		end
		pcall(tern.fs.write, tern.plugin.data .. "/library-flag.txt", dir or "")
		return
	end
	if type(spec.file) == "string" and spec.file ~= "" then
		openList(cx, { spec.file }, spec.draft == true)
		return
	end
	openList(cx, scoreFiles(tostring(spec.root or EXERCISES)))
end

local function poll(cx: any)
	if cx ~= nil then
		pcall(consume, cx)
		pcall(runDraftRequest, cx)
		pcall(flushDraftResults, cx)
	end
	tern.timer(POLL_MS, poll)
end

-- module load runs on every reload, unlike window_start
local started = pcall(function()
	tern.timer(POLL_MS, poll)
end)
if not started then
	tern.on("window_start", function(cx)
		poll(cx)
	end)
end
