--!strict
-- Guitar Score: alphaTab renders each score to PNG systems; every note head is an
-- absolutely positioned hit box driven by static CSS classes (.gx116 .gy532 ...).
-- Several scores sit side by side; one is active and owns the transport.

local ui = tern.ui

local NODE = "C:/Program Files/nodejs/node.exe"
local PYTHON = "D:/programs/Python/python.exe"
local REQUEST = tern.plugin.data .. "/open-request.json"

-- native OS file dialog, filtered to score formats
local function nativePick(callback: (string?) -> ())
	tern.process.run(
		{ PYTHON, tern.plugin.dir .. "/pickfile.py" },
		{ timeout_ms = 120000 }
	):next(function(res)
			if res and res.status == 0 and res.stdout ~= "" then
				callback(res.stdout)
			else
				callback(nil)
			end
		end)
end

local TICK_MS = 40
local STEP_MS = 5000
local MAX_COLUMNS = 4

type Occ = { t: number, nb: { number } }
type Note = { id: number, b: number, x: number, y: number, w: number, h: number }
type BeatBox = { i: number, x: number, y: number, w: number, h: number }
type MeasureBox = { mb: number, x: number, y: number, w: number, h: number }
type MeasureTime = { mb: number, t0: number, t1: number }
type System = { png: string, w: number, h: number, blob: any, notes: { Note }, beats: { BeatBox }, measures: { MeasureBox } }

type Score = {
	path: string,
	out: string,
	title: string,
	status: string,
	err: string?,
	duration: number,
	pos: number,
	from: number,
	to: number,
	playing: boolean,
	armed: boolean,
	startedAt: number,
	session: string,
	loop: boolean,
	markA: number?,
	markB: number?,
	selA: number?,
	selB: number?,
	selT0: number?,
	selT1: number?,
	segPath: string?,
	tuning: { number },
	timeSignature: { number },
	cur: { [number]: boolean },
	timeline: { Occ },
	measureTimes: { MeasureTime },
	systems: { System },
}

type State = { scores: { Score }, active: number, width: number }

-- small helpers ------------------------------------------------------------

local function permille(v: number): number
	local p = math.floor(v * 1000 + 0.5)
	if p < 0 then
		return 0
	elseif p > 1000 then
		return 1000
	end
	return p
end

local function box(n: { x: number, y: number, w: number, h: number }): string
	return table.concat({
		"gx" .. permille(n.x), "gy" .. permille(n.y),
		"gw" .. permille(n.w), "gh" .. permille(n.h),
	}, " ")
end

local function clock(ms: number): string
	local s = math.max(0, math.floor(ms / 1000))
	return string.format("%d:%02d", math.floor(s / 60), s % 60)
end

-- one render per (score, width): the picture's pixels decide where the hit
-- boxes land, so a pane that grows must not reuse a narrower render
local function cacheDir(path: string, width: number): string
	return string.format("%s/cache/%s@%d", tern.plugin.data, path:gsub("[^%w]", "_"), width)
end

local function newSession(): string
	local n = 1
	pcall(function()
		n = tonumber(tern.kv.get("session") or 0) + 1
		tern.kv.set("session", n)
	end)
	return string.format("%d-%d-%d", n, math.floor(tern.now()), math.random(1000000))
end

local function hbFile(sc: Score): string
	return sc.out .. "/heartbeat.txt"
end

local function stampFile(sc: Score): string
	return sc.out .. "/started-" .. sc.session .. ".stamp"
end

local function beatsAt(sc: Score, ms: number): { [number]: boolean }
	local cur: { [number]: boolean } = {}
	local last: Occ? = nil
	for _, o in ipairs(sc.timeline) do
		if o.t > ms then
			break
		end
		last = o
	end
	if last then
		for _, id in ipairs(last.nb) do
			cur[id] = true
		end
	end
	return cur
end

local OPEN = { [1] = 40, [2] = 45, [3] = 50, [4] = 55, [5] = 59, [6] = 64 }

-- the agent reads this: the selected bars as notes, timing and tuning
local function exportSelection(sc: Score)
	if sc.selA == nil then
		return
	end
	local lo = sc.selA
	local hi = sc.selB or sc.selA
	local notes = {}
	for _, sys in ipairs(sc.systems) do
		for _, n in ipairs(sys.notes) do
			if n.m >= lo and n.m <= hi then
				local baseMidi = (sc.tuning and #sc.tuning >= n.string) and sc.tuning[n.string] or (OPEN[n.string] or 0)
				table.insert(notes, {
					bar = n.m,
					string = n.string,
					fret = n.fret,
					midi = baseMidi + (n.fret or 0),
				})
			end
		end
	end
	local beats = {}
	local spans = {}
	for _, o in ipairs(sc.timeline) do
		if o.t >= (sc.selT0 or 0) and o.t <= (sc.selT1 or 0) then
			table.insert(beats, o.t)
		end
	end
	for i = 1, #beats - 1 do
		table.insert(spans, beats[i + 1] - beats[i])
	end
	table.sort(spans)
	local payload = {
		path = sc.path,
		title = sc.title,
		bars = { lo, hi },
		t0 = sc.selT0,
		t1 = sc.selT1,
		beat_ms = if #spans > 0 then spans[math.floor(#spans / 2) + 1] else nil,
		time_signature = sc.timeSignature,
		tuning = sc.tuning,
		notes = notes,
	}
	pcall(tern.fs.write, tern.plugin.data .. "/selection.json", tern.json.encode(payload, true))
end

local function loopRange(sc: Score): (number, number)
	if sc.selT0 and sc.selT1 then
		return sc.selT0, sc.selT1
	end
	if sc.markA then
		return sc.markA, sc.markB or sc.duration
	end
	return 0, sc.duration
end

local function startPos(sc: Score): number
	if sc.loop then
		local lo, hi = loopRange(sc)
		if sc.pos < lo or sc.pos >= hi then
			return lo
		end
	end
	return sc.pos
end

local function endPos(sc: Score): number
	if sc.loop then
		local _, hi = loopRange(sc)
		return hi
	end
	return sc.duration
end

-- playback -----------------------------------------------------------------

local function playerStop(sc: Score)
	pcall(tern.fs.write, hbFile(sc), "0")
	sc.playing = false
	sc.armed = false
end

local function playFrom(state: State, cx: any, sc: Score, from: number, to: number)
	for i, other in ipairs(state.scores) do
		if i ~= state.active and other.playing then
			playerStop(other)
		end
	end
	playerStop(sc)
	sc.session = newSession()
	local session = sc.session
	sc.pos, sc.from, sc.to = from, from, to
	sc.playing = true
	sc.armed = false
	sc.startedAt = 0
	local stamp = stampFile(sc)
	pcall(tern.fs.remove, stamp)

	local needSlice = from > 0 or to < sc.duration
	local seg = string.format("%s/seg-%d-%d.wav", sc.out, math.floor(from), math.floor(to))
	local full = sc.out .. "/full.wav"
	local seconds = tostring(math.max(0.2, (to - from) / 1000 + 0.4))
	local spawnAt = tern.now()
	local lastSig = ""

	local function start(file: string)
		pcall(tern.fs.write, hbFile(sc), session)
		local okp, perr = pcall(function()
			tern.process.run(
				{ PYTHON, tern.plugin.dir .. "/player.py", file, hbFile(sc), session, seconds, stamp },
				{ timeout_ms = 900000 }
			):next(function() end)
		end)
		if not okp then
			pcall(tern.fs.write, sc.out .. "/spawn-error.txt", tostring(perr))
		end

		local function tick()
			if session ~= sc.session or not sc.playing then
				return
			end
			if not sc.armed then
				if tern.fs.exists(stamp) then
					sc.startedAt = tern.now() - TICK_MS / 2
					sc.armed = true
				elseif tern.now() - spawnAt > 8000 then
					playerStop(sc)
					sc.cur = {}
					cx:render()
					return
				else
					tern.timer(TICK_MS, tick)
					return
				end
			end
			local elapsed = tern.now() - sc.startedAt
			local pos = math.min(to, from + elapsed)
			sc.pos = pos
			if pos >= to then
				if sc.loop then
					local a, b = loopRange(sc)
					playFrom(state, cx, sc, a, b)
					return
				end
				playerStop(sc)
				sc.cur = {}
				sc.pos = to
				cx:render()
				return
			end
			pcall(tern.fs.write, hbFile(sc), session)
			sc.cur = beatsAt(sc, pos)
			local ids = {}
			for id in pairs(sc.cur) do
				table.insert(ids, id)
			end
			table.sort(ids)
			local sig = table.concat(ids, ",")
			if sig ~= lastSig then
				lastSig = sig
				cx:render()
			end
			tern.timer(TICK_MS, tick)
		end
		tern.timer(TICK_MS, tick)
		cx:render()
	end

	if not needSlice then
		start(full)
		return
	end
	if sc.segPath == seg and tern.fs.exists(seg) then
		start(seg)
		return
	end
	tern.process.run({
		PYTHON, tern.plugin.dir .. "/slice.py", full, seg,
		tostring(math.floor(from)), tostring(math.floor(to)),
	}, { timeout_ms = 23000 }):next(function(res)
		if res and res.status == 0 then
			sc.segPath = seg
			start(seg)
		else
			start(full)
		end
	end)
end

-- loading ------------------------------------------------------------------

local function applyJson(cx: any, sc: Score, data: any)
	sc.title = data.title or "Score"
	sc.tuning = data.tuning or {}
	sc.timeSignature = data.timeSignature or { 4, 4 }
	sc.duration = data.duration or 0
	sc.to = sc.duration
	sc.systems = {}
	sc.timeline = data.timeline or {}
	sc.measureTimes = data.measureTimes or {}
	local id = 0
	for _, s in ipairs(data.systems) do
		local blob: any = nil
		local okb, bytes = pcall(tern.fs.read, sc.out .. "/" .. s.png)
		if okb then
			local okBlob, handle = pcall(function()
				return cx:blob(bytes, "image/png")
			end)
			if okBlob then
				blob = handle
			end
		end
		local notes: { Note } = {}
		for _, n in ipairs(s.notes or {}) do
			n.id = id
			id = id + 1
			table.insert(notes, n)
		end
		table.insert(sc.systems, {
			png = s.png, w = s.w, h = s.h, blob = blob, notes = notes,
			beats = s.beats or {}, measures = s.measures or {},
		})
	end
	sc.status = "ready"
end

local renderOne: (any, State, number) -> ()

function renderOne(cx: any, state: State, index: number)
	local sc = state.scores[index]
	if not sc then
		return
	end
	sc.status = "loading"
	local argv = {
		NODE, "index.mjs",
		"--input", sc.path,
		"--out", sc.out,
		"--width", tostring(state.width),
	}
	local started, startErr = pcall(function()
		tern.process.run(argv, { cwd = tern.plugin.dir .. "/renderer", timeout_ms = 300000 }):next(function(res, runErr)
			if runErr then
				sc.status, sc.err = "error", tostring(runErr)
			elseif not res or res.status ~= 0 then
				sc.status = "error"
				sc.err = (res and (res.stderr ~= "" and res.stderr or res.stdout)) or "renderer failed"
			else
				local ok, data = pcall(tern.json.decode, res.stdout)
				if not ok or type(data) ~= "table" or not data.systems then
					sc.status, sc.err = "error", "bad renderer output"
				else
					applyJson(cx, sc, data)
				end
			end
			cx:render()
			renderOne(cx, state, index + 1)
		end)
	end)
	if not started then
		sc.status, sc.err = "error", tostring(startErr)
	end
end

local function scoreFiles(path: string): { string }
	local isDir = false
	pcall(function()
		tern.fs.list(path)
		isDir = true
	end)
	if not isDir then
		return { path }
	end
	local out = {}
	for _, name in ipairs(tern.fs.list(path)) do
		if name:match("%.musicxml$") or name:match("%.gp%d?$") or name:match("%.gpx$") then
			table.insert(out, path .. "/" .. name)
		end
	end
	table.sort(out)
	while #out > MAX_COLUMNS do
		table.remove(out)
	end
	return out
end

-- view ---------------------------------------------------------------------

local function button(icon: string, act: string, tip: string, tone: string?): Node
	local node = ui.node("icon", { name = icon, tone = tone, title = tip })
	local p: { [string]: any } = node.p or {}
	p.actions = { click = act }
	node.p = p
	return node
end

local function column(state: State, index: number, sc: Score): Node
	if sc.status == "error" then
		return ui.col({
			ui.text({ ui.span(sc.title, "muted") }),
			ui.text({ ui.span("failed", "error") }),
			ui.text({ ui.span(sc.err or "", "dim") }),
		})
	end
	if sc.status == "loading" then
		return ui.col({ ui.text({ ui.span("Rendering " .. (sc.path:match("[^/\\]+$") or "") .. " …", "muted") }) })
	end

	local rows: { Node } = {}
	for _, sys in ipairs(sc.systems) do
		local hits: { Node } = {}
		for _, m in ipairs(sys.measures) do
			local cls = "gmeas " .. box(m)
			if sc.selA ~= nil and m.mb >= sc.selA and m.mb <= (sc.selB or sc.selA) then
				cls = cls .. " gsel"
			end
			local mn = ui.el("div", { class = cls })
			local mp: { [string]: any } = mn.p or {}
			mp.actions = { click = "meas=" .. index .. ":" .. m.mb }
			mp.title = "Loop this bar"
			mn.p = mp
			table.insert(hits, mn)
		end
		for _, n in ipairs(sys.notes) do
			local node = ui.el("div", { class = "ghit " .. box(n) })
			local p: { [string]: any } = node.p or {}
			p.actions = { click = "note=" .. index .. ":" .. n.id }
			node.p = p
			table.insert(hits, node)
		end
		local bar: BeatBox? = nil
		for id in pairs(sc.cur) do
			for _, b in ipairs(sys.beats) do
				if b.i == id then
					bar = b
				end
			end
		end
		if bar ~= nil then
			table.insert(hits, ui.el("div", { class = "gbar " .. box(bar) }))
		end
		table.insert(rows, ui.node("image", {
			blob = sys.blob, w = sys.w, h = sys.h, alt = sys.png,
			role = "score",
		}, hits))
	end

	return ui.el("div", { class = "gcol" }, rows)
end

local def: BlockDef<State> = {
	init = function(cx: any, args: { string }, saved: any): State
		local root = args[1] or (saved and saved.root) or ""
		local files = if root == "" then {} else scoreFiles(root)
		-- render at roughly the pane's pixel width so a narrow split pane keeps its text legible
		local cols = tonumber(cx.cols) or 100
		local width = math.max(380, math.min(1040, math.floor(cols * 8)))
		if #files > 1 then
			width = math.max(420, math.floor(1000 / #files))
		end
		local state: State = { scores = {}, active = 1, width = width }
		for _, path in ipairs(files) do
			local sc: Score = {
				path = path,
				out = cacheDir(path, width),
				title = path:match("[^/\\]+$") or path,
				status = "loading",
				err = nil,
				duration = 0,
				pos = 0,
				from = 0,
				to = 0,
				playing = false,
				armed = false,
				startedAt = 0,
				session = "0",
				loop = false,
				markA = nil,
				markB = nil,
				selA = nil,
				selB = nil,
				selT0 = nil,
				selT1 = nil,
				segPath = nil,
				tuning = {},
				timeSignature = { 4, 4 },
				cur = {},
				timeline = {},
				measureTimes = {},
				systems = {},
			}
			pcall(function()
				tern.fs.mkdir(sc.out)
				tern.fs.write(hbFile(sc), "0")
			end)
			table.insert(state.scores, sc)
		end
		if #state.scores == 0 then
			return state
		end
		renderOne(cx, state, 1)
		return state
	end,

	title = function(state: State): string?
		local sc = state.scores[state.active]
		if not sc then
			return "Guitar Score"
		end
		if #state.scores > 1 then
			return string.format("%s (%d/%d)", sc.title, state.active, #state.scores)
		end
		return sc.title
	end,

	view = function(state: State, cx: any): BlockView
		if #state.scores == 0 then
			return { main = ui.col({ ui.text({ ui.span("No score files in that folder", "error") }) }) }
		end
		local cols: { Node } = {}
		for i, sc in ipairs(state.scores) do
			table.insert(cols, column(state, i, sc))
		end

		local sc = state.scores[state.active]
		local bar: { Node } = {}
		if #state.scores > 1 then
			for i, one in ipairs(state.scores) do
				local node = ui.node("badge", {
					text = tostring(i),
					tone = if i == state.active then "accent" else "muted",
					title = one.title,
				})
				local p: { [string]: any } = node.p or {}
				p.actions = { click = "pick=" .. i }
				node.p = p
				table.insert(bar, node)
			end
			table.insert(bar, ui.node("sep", {}))
		end
		if sc ~= nil and sc.status == "ready" then
			table.insert(bar, button(if sc.playing then "pause" else "play", "playpause",
				if sc.playing then "Pause (space)" else "Play (space)", "accent"))
			table.insert(bar, button("stop", "stop", "Stop"))
			table.insert(bar, button("rewind", "home", "Back to start"))
			table.insert(bar, button("frame-prev", "back", "-5s"))
			table.insert(bar, button("frame-next", "fwd", "+5s"))
			table.insert(bar, button("folder-open", "library", "Open a score file…"))
			table.insert(bar, button("repeat", "loop", "Loop the selected bar",
				if sc.loop then "accent" else "muted"))
			local marks = clock(sc.pos) .. " / " .. clock(sc.duration)
			if sc.loop then
				local lo, hi = loopRange(sc)
				marks = marks .. "  loop " .. clock(lo) .. "-" .. clock(hi)
			end
			table.insert(bar, ui.text({ ui.span(marks, "muted") }))
		end

		return {
			main = ui.col({
				ui.el("div", { class = "gscore-bar" }, { ui.row(bar) }),
				ui.el("div", { class = "gcols" }, { ui.row(cols) }),
			}),
		}
	end,

	key = function(state: State, key: any, cx: any): boolean?
		if key.ctrl or key.alt or key.meta then
			return false
		end
		local sc = state.scores[state.active]
		if not sc or sc.status ~= "ready" then
			return false
		end
		if key.name == "space" then
			if sc.playing then
				playerStop(sc)
			else
				playFrom(state, cx, sc, startPos(sc), endPos(sc))
			end
			cx:render()
			return true
		elseif key.name == "a" then
			sc.markA, sc.loop = sc.pos, true
			cx:render()
			return true
		elseif key.name == "b" then
			sc.markB, sc.loop = sc.pos, true
			cx:render()
			return true
		elseif key.name == "escape" then
			sc.markA, sc.markB, sc.loop = nil, nil, false
			sc.selA, sc.selB, sc.selT0, sc.selT1 = nil, nil, nil, nil
			cx:render()
			return true
		elseif key.name == "tab" then
			state.active = state.active % #state.scores + 1
			cx:render()
			return true
		end
		return false
	end,

	event = function(state: State, ev: any, cx: any)
		if ev.ev ~= "action" then
			return
		end
		if ev.act == "pick" then
			local i = tonumber(ev.value)
			if i and state.scores[i] then
				state.active = i
				cx:render()
			end
			return
		end
		local act = tostring(ev.act or "")
		if act == "library" then
			nativePick(function(path)
				if path then
					pcall(tern.fs.write, REQUEST, tern.json.encode({ file = path }))
				end
			end)
			return
		end
		if act == "playpause" or act == "stop" or act == "home" or act == "back"
			or act == "fwd" or act == "loop" then
			local sc0 = state.scores[state.active]
			if sc0 == nil or sc0.status ~= "ready" then
				return
			end
			if act == "playpause" then
				if sc0.playing then
					playerStop(sc0)
				else
					playFrom(state, cx, sc0, startPos(sc0), endPos(sc0))
				end
			elseif act == "loop" then
				sc0.loop = not sc0.loop
				if not sc0.loop then
					sc0.selA, sc0.selB, sc0.selT0, sc0.selT1 = nil, nil, nil, nil
				end
			else
				local wasPlaying = sc0.playing
				playerStop(sc0)
				if act == "stop" then
					sc0.pos = 0
				elseif act == "home" then
					sc0.pos = 0
				elseif act == "back" then
					sc0.pos = math.max(0, sc0.pos - STEP_MS)
				elseif act == "fwd" then
					sc0.pos = math.min(sc0.duration, sc0.pos + STEP_MS)
				end
				sc0.cur = beatsAt(sc0, sc0.pos)
				if wasPlaying then
					playFrom(state, cx, sc0, sc0.pos, sc0.duration)
				end
			end
			cx:render()
			return
		end

		local which, what = string.match(tostring(ev.value or ""), "^(%d+):(%d+)$")
		local index = tonumber(which or "")
		local sc = index and state.scores[index]
		if not sc then
			return
		end
		state.active = index
		if ev.act == "note" then
			local id = tonumber(what or "")
			if not id then
				return
			end
			local want: number? = nil
			for _, sys in ipairs(sc.systems) do
				for _, n in ipairs(sys.notes) do
					if n.id == id then
						want = n.b
					end
				end
			end
			if want == nil then
				return
			end
			local at = 0
			for _, o in ipairs(sc.timeline) do
				for _, b in ipairs(o.nb) do
					if b == want then
						at = o.t
					end
				end
			end
			playFrom(state, cx, sc, at, sc.duration)
		elseif ev.act == "meas" then
			local mb = tonumber(what or "")
			if not mb then
				return
			end
			local shift = false
			if type(ev.mods) == "table" then
				for _, mod in ipairs(ev.mods) do
					if mod == "shift" then
						shift = true
					end
				end
			end
			if shift and sc.selA ~= nil then
				sc.selA = math.min(sc.selA, mb)
				sc.selB = math.max(sc.selB or sc.selA, mb)
			else
				sc.selA, sc.selB = mb, mb
			end
			local lo: number? = nil
			local hi: number? = nil
			for _, mt in ipairs(sc.measureTimes) do
				if mt.mb >= (sc.selA or mb) and mt.mb <= (sc.selB or mb) then
					if lo == nil or mt.t0 < lo then
						lo = mt.t0
					end
					if hi == nil or mt.t1 > hi then
						hi = mt.t1
					end
				end
			end
			if lo == nil or hi == nil then
				return
			end
			sc.selT0, sc.selT1 = lo, hi
			sc.loop = true
			exportSelection(sc)
			playFrom(state, cx, sc, lo, hi)
		end
	end,

	save = function(state: State): any
		local sc = state.scores[1]
		return { root = if sc then sc.path else "" }
	end,
}

tern.block.define("score", def)

-- library ---------------------------------------------------------------

-- formats alphaTab's ScoreLoader imports; keep the manifest's file globs in step
local EXTS = { "musicxml", "xml", "mxl", "gp", "gp3", "gp4", "gp5", "gpx" }
local START_DIR = "D:/L/Guitar/吉他谱"

type Entry = { path: string, name: string, isDir: boolean, title: string? }

local function isScore(name: string): boolean
	for _, ext in ipairs(EXTS) do
		if name:lower():sub(-#ext - 1) == "." .. ext then
			return true
		end
	end
	return false
end

local function titleOf(path: string): string?
	local ok, text = pcall(tern.fs.read, path, 65536)
	if not ok then
		return nil
	end
	return string.match(text, "<movement%-title[^>]*>([^<]+)<")
		or string.match(text, "<work%-title[^>]*>([^<]+)<")
end

local function isDir(path: string): boolean
	local ok = pcall(tern.fs.list, path)
	return ok
end

local function byName(a: Entry, b: Entry): boolean
	return a.name:lower() < b.name:lower()
end

local function scan(dir: string): ({ Entry }, string?)
	local ok, names = pcall(tern.fs.list, dir)
	if not ok then
		return {}, "cannot read " .. dir
	end
	local dirs: { Entry } = {}
	local files: { Entry } = {}
	for _, name in ipairs(names) do
		if name:sub(1, 1) ~= "." then
			local path = dir .. "/" .. name
			if isDir(path) then
				table.insert(dirs, { path = path, name = name, isDir = true })
			elseif isScore(name) then
				table.insert(files, { path = path, name = name, isDir = false, title = titleOf(path) })
			end
		end
	end
	table.sort(dirs, byName)
	table.sort(files, byName)
	local out = dirs
	for _, f in ipairs(files) do
		table.insert(out, f)
	end
	return out, nil
end

local function parentOf(path: string): string
	local up = string.match(path, "^(.*)[/\\][^/\\]+$")
	if up == nil or up == "" then
		return path
	end
	if up:match("^%a:$") then
		return up .. "/"
	end
	return up
end

local function sheet(state: LibState): Node
	local items = {}
	local order = {}
	for _, e in ipairs(state.entries) do
		local id = e.path
		table.insert(items, {
			id = id,
			label = if e.isDir then { ui.span("▸ " .. e.name) } else { ui.span(e.title or e.name) },
			detail = if e.isDir then { ui.span(e.path, "dim") } else { ui.span(e.name, "dim") },
			icon = if e.isDir then "folder" else "music",
		})
		table.insert(order, id)
	end
	local sel = order[math.max(1, math.min(state.sel, #order))]
	return ui.node("picker", {
		title = { ui.span("Open a score") },
		subtitle = { ui.span(state.cwd, "dim") },
		noun = "scores",
		icon = "music",
		size = "md",
		layout = "rows",
		preview = "none",
		query = state.query,
		placeholder = "Search scores…",
		state = "ready",
		message = state.err,
		items = items,
		order = order,
		selected = sel,
		actions = {
			{ id = "open", label = "Open", keys = { "return" }, primary = true },
			{ id = "up", label = "Up" },
			{ id = "close", label = "Cancel", keys = { "escape" } },
		},
	})
end



type LibState = {
	open: boolean,
	cwd: string,
	query: string,
	entries: { Entry },
	err: string?,
	stale: { string },
}

local function hitsOf(text: string, query: string): boolean
	local low = text:lower()
	local q = query:lower()
	if q == "" then return true end
	local at = 1
	for i = 1, #q do
		local ch = q:sub(i, i)
		local found = string.find(low, ch, at, true)
		if not found then return false end
		at = found + 1
	end
	return true
end

local function shown(state: LibState): { Entry }
	if state.query == "" then
		return state.entries
	end
	local out = {}
	for _, e in ipairs(state.entries) do
		if hitsOf(e.name, state.query) or hitsOf(e.title or "", state.query) then
			table.insert(out, e)
		end
	end
	return out
end

local lib: BlockDef<LibState> = {
	init = function(_cx: any, args: { string }, saved: any): LibState
		local cwd = args[1] or (saved and saved.cwd) or START_DIR
		local entries, err = scan(cwd)
		return {
			cwd = cwd, entries = entries, err = err,
			open = #args > 0, query = "", sel = 1, stale = {},
		}
	end,

	title = function(state: LibState): string?
		if not state.open then
			return nil
		end
		return "Open a score"
	end,

	view = function(state: LibState, _cx: any): BlockView
		if not state.open then
			return { main = ui.text({ ui.span("Open a score…") }) }
		end
		return { layer = sheet(state) }
	end,

	key = function(state: LibState, key: any, cx: any): boolean?
		if not state.open then
			return false
		end
		if key.name == "escape" then
			state.open = false
			cx:render()
			return true
		elseif key.name == "up" then
			state.sel = math.max(1, state.sel - 1)
			cx:render()
			return true
		elseif key.name == "down" then
			state.sel = state.sel + 1
			cx:render()
			return true
		elseif key.name == "return" then
			local entry = state.entries[state.sel]
			if entry == nil then
				return true
			end
			if entry.isDir then
				local entries, err = scan(entry.path)
				state.cwd, state.entries, state.err, state.sel = entry.path, entries, err, 1
			else
				pcall(tern.fs.write, REQUEST, tern.json.encode({ file = entry.path }))
				state.open = false
			end
			cx:render()
			return true
		elseif key.name == "backspace" then
			state.query = state.query:sub(1, -2)
			state.sel = 1
			cx:render()
			return true
		elseif key.text ~= nil and key.text ~= "" and not key.ctrl and not key.meta then
			state.query = state.query .. key.text
			state.sel = 1
			cx:render()
			return true
		end
		return false
	end,

	event = function(state: LibState, ev: any, cx: any)
		if ev.ev == "select" then
			for i, e in ipairs(state.entries) do
				if e.path == ev.item then
					state.sel = i
				end
			end
			cx:render()
			return
		elseif ev.ev == "activate" then
			for _, e in ipairs(state.entries) do
				if e.path == ev.item then
					if e.isDir then
						local entries, err = scan(e.path)
						state.cwd, state.entries, state.err = e.path, entries, err
						state.sel = 1
					else
						pcall(tern.fs.write, REQUEST, tern.json.encode({ file = e.path }))
						state.open = false
					end
					cx:render()
					return
				end
			end
			return
		end
		if ev.ev ~= "action" then
			return
		end
		if ev.act == "show" then
			state.open = true
			local entries, err = scan(state.cwd)
			state.entries, state.err = entries, err
		elseif ev.act == "close" then
			state.open = false
		elseif ev.act == "native" then
			state.open = false
			nativePick(function(path)
				if path then
					pcall(tern.fs.write, REQUEST, tern.json.encode({ file = path }))
				end
			end)
		elseif ev.act == "up" then
			local up = parentOf(state.cwd)
			if up ~= state.cwd then
				local entries, err = scan(up)
				state.cwd, state.entries, state.err, state.sel = up, entries, err, 1
			end
		elseif ev.act == "open" then
			local entry = state.entries[state.sel]
			if entry == nil then
				return
			end
			if entry.isDir then
				local entries, err = scan(entry.path)
				state.cwd, state.entries, state.err, state.sel = entry.path, entries, err, 1
			else
				pcall(tern.fs.write, REQUEST, tern.json.encode({ file = entry.path }))
				state.open = false
			end
		end
		cx:render()
	end,

	save = function(state: LibState): any
		return { cwd = state.cwd }
	end,
}

tern.block.define("library", lib)

