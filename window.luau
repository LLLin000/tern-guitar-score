--!strict
-- Alt+Shift+G: one score.
-- Palette "Open Exercises Beside This Pane": a column of exercise panes.
-- Agent channel: write <plugin data>/open-request.json {"root": "..."} and the
-- window half lays it out within a tick (the CLI has no way to run a command).

local SAMPLE = "D:/L/Guitar/吉他谱/Tears in Heaven.musicxml"
local EXERCISES = "D:/L/AI/exercises"
local REQUEST = tern.plugin.data .. "/open-request.json"
local POLL_MS = 400

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

local function openList(cx: any, files: { string })
	if #files == 0 then
		cx:toast("error", "No score files")
		return
	end
	local previous = tern.kv.get("panes") or {}
	local ours: { [number]: boolean } = {}
	for _, id in ipairs(previous) do
		ours[id] = true
	end
	-- anchor: the focused pane unless it is one we opened, else any pane we did not
	local anchor = cx.session:focused()
	if anchor == nil or ours[anchor] then
		anchor = nil
		for _, info in cx.session:panes() do
			if not ours[info.pane] then
				anchor = info.pane
				break
			end
		end
	end
	if not anchor then
		cx:toast("error", "No pane to split from")
		return
	end
	-- refuse to pile up: a tab that already holds many panes is not a clean base
	local count = 0
	for _ in cx.session:panes() do
		count = count + 1
	end
	if count > 12 then
		cx:toast("warning", "Too many panes open", "close some, then retry")
		return
	end
	for _, id in ipairs(previous) do
		if id ~= anchor then
			pcall(function()
				cx.layout:close(id)
			end)
		end
	end
	tern.kv.set("panes", {})
	mine = {}
	local column = cx.layout:split(anchor, "right", {
		block = "gscore.score", args = { files[1] },
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
		pcall(tern.fs.write, tern.plugin.data .. "/win-debug.txt",
			"library branch hit lib=" .. tostring(spec.library))
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
		pcall(tern.fs.write, tern.plugin.data .. "/win-debug.txt",
			"old=" .. tostring(old) .. " anchor=" .. tostring(anchor0))
		if not anchor0 then
			return
		end
		local pane = cx.layout:split(anchor0, "right", {
			block = "gscore.library",
			args = if dir then { dir } else {},
		})
		pcall(tern.fs.write, tern.plugin.data .. "/win-debug.txt",
			"old=" .. tostring(old) .. " anchor=" .. tostring(anchor0) .. " pane=" .. tostring(pane))
		if pane then
			tern.kv.set("libraryPane", pane)
		end
		pcall(tern.fs.write, tern.plugin.data .. "/library-flag.txt", dir or "")
		return
	end
	if type(spec.file) == "string" and spec.file ~= "" then
		openList(cx, { spec.file })
		return
	end
	openList(cx, scoreFiles(tostring(spec.root or EXERCISES)))
end

local function poll(cx: any)
	if cx ~= nil then
		pcall(consume, cx)
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
