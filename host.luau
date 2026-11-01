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
type Note = {
	id: number,
	b: number,
	m: number,
	string: number,
	fret: number,
	x: number,
	y: number,
	w: number,
	h: number,
	durationTicks: number?,
	tuplet: string?,
	isTie: boolean?,
	isHammerPull: boolean?,
	isSlide: boolean?,
	isGhost: boolean?,
	isDead: boolean?,
}
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
	speed: number,
	countIn: boolean,
	countInActive: boolean,
	countInDuration: number?,
	tempoBpm: number,
	backendRunning: boolean,
	cmdSeq: number,
	loopToken: number,
	backendSeq: number?,
	lastBackendActiveAt: number?,
	lastActiveSys: number?,
	isDraft: boolean,
	draftTemplate: string?,
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
local function exportSelection(sc: Score, destPath: string?): any
	if sc.selA == nil then
		return nil
	end
	local lo = sc.selA
	local hi = sc.selB or sc.selA
	local notes = {}
	for _, sys in ipairs(sc.systems) do
		for _, n in ipairs(sys.notes) do
			if n.m >= lo and n.m <= hi then
				local tuningLen = if sc.tuning then #sc.tuning else 0
				local baseMidi = OPEN[n.string] or 40
				-- sc.tuning from alphaTab is high-to-low [64, 59, 55, 50, 45, 40]
				-- n.string is low-to-high (1 = low E, 6 = high E)
				if tuningLen >= 6 and n.string >= 1 and n.string <= 6 then
					baseMidi = sc.tuning[7 - n.string] or baseMidi
				end
				table.insert(notes, {
					id = n.id,
					bar = n.m,
					string = n.string,
					fret = n.fret,
					midi = baseMidi + (n.fret or 0),
					duration_ticks = n.durationTicks,
					tuplet = n.tuplet,
					is_tie = n.isTie,
					is_hammer_pull = n.isHammerPull,
					is_slide = n.isSlide,
					is_ghost = n.isGhost,
					is_dead = n.isDead,
				})
			end
		end
	end
	local beats = {}
	local spans = {}
	for _, o in ipairs(sc.timeline) do
		if o.t >= (sc.selT0 or 0) and o.t <= (sc.selT1 or 0) then
			table.insert(beats, { t = o.t, beat_ids = o.nb })
		end
	end
	for i = 1, #beats - 1 do
		table.insert(spans, beats[i + 1].t - beats[i].t)
	end
	table.sort(spans)
	local payload = {
		version = "1.1.0",
		protocol = "music_context_v1",
		timestamp_ms = math.floor(tern.now()),
		path = sc.path,
		title = sc.title,
		bars = { lo, hi },
		playback_range_ms = { t0 = sc.selT0, t1 = sc.selT1 },
		tempo_bpm = if #spans > 0 then math.floor(60000 / spans[math.floor(#spans / 2) + 1] + 0.5) else 120,
		median_beat_ms = if #spans > 0 then spans[math.floor(#spans / 2) + 1] else nil,
		time_signature = sc.timeSignature,
		tuning_midi = sc.tuning,
		notes = notes,
		beats = beats,
	}
	local encoded = tern.json.encode(payload, true)
	pcall(tern.fs.write, destPath or (tern.plugin.data .. "/selection.json"), encoded)
	return payload
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

-- atomic per-command queue: each command is an isolated sequentially
-- numbered file inside `<cache>/cmds/`. This eliminates all read-modify-write
-- races between Luau writers and the python reader.
local function cmdsDir(sc: Score): string
	local dir = sc.out .. "/cmds"
	pcall(tern.fs.mkdir, dir)
	return dir
end

local function stateFile(sc: Score): string
	return sc.out .. "/audio_state.json"
end

-- Luau has no rename, so publish atomically with an end sentinel: the reader
-- only consumes a file whose body terminates with END_SENTINEL, which a
-- half-written file never does.
local END_SENTINEL = "\n__GSCORE_END__\n"

local function sendCmd(sc: Score, payload: any)
	sc.cmdSeq = (sc.cmdSeq or 0) + 1
	local path = string.format("%s/%08d.json", cmdsDir(sc), sc.cmdSeq)
	pcall(tern.fs.write, path, tern.json.encode(payload, false) .. END_SENTINEL)
end

-- self-healing backend watcher: relies on strictly monotonic sequence numbers
-- and mtime freshness measured exclusively within `tern.now()` domain.
-- NEVER compares `tern.now()` to python's unix-epoch `time.time()*1000`.
local function ensureBackend(sc: Score)
	if sc.backendRunning then
		local ok, text = pcall(tern.fs.read, stateFile(sc))
		if ok and text ~= "" then
			local okj, data = pcall(tern.json.decode, text)
			if okj and type(data) == "table" and data.seq ~= nil then
				local now = tern.now()
				if sc.backendSeq == nil or data.seq ~= sc.backendSeq then
					sc.backendSeq = data.seq
					sc.lastBackendActiveAt = now
					return
				elseif sc.lastBackendActiveAt ~= nil and (now - sc.lastBackendActiveAt) < 6000 then
					return
				end
			end
		end
	end
	pcall(tern.fs.write, hbFile(sc), tostring(math.floor(tern.now())))
	pcall(function()
		tern.process.run(
			{ PYTHON, tern.plugin.dir .. "/audio_backend.py", sc.out },
			{ timeout_ms = 9999999 }
		):next(function()
			sc.backendRunning = false
		end)
	end)
	sc.backendRunning = true
	sc.lastBackendActiveAt = tern.now()
end

local function playerStop(sc: Score)
	sendCmd(sc, { action = "stop" })
	sc.playing = false
	sc.armed = false
	sc.cur = {}
end

local function playerPause(sc: Score)
	sendCmd(sc, { action = "pause" })
	sc.playing = false
end

local function playerSeek(sc: Score, pos_ms: number)
	sendCmd(sc, { action = "seek", pos_ms = math.floor(pos_ms) })
	sc.pos = pos_ms
end

local function playerSpeed(sc: Score, speed: number)
	sc.speed = speed
	sendCmd(sc, { action = "speed", speed = speed })
end

local function playerLoop(sc: Score, a_ms: number?, b_ms: number?)
	sendCmd(sc, { action = "loop", loop_a_ms = a_ms, loop_b_ms = b_ms })
end

-- single polling loop per score: each invocation gets a unique `myToken`.
-- If state restarts or resumes, previous loops observe token mismatch and exit cleanly.
local function startAudioLoop(state: State, cx: any, sc: Score)
	sc.loopToken = (sc.loopToken or 0) + 1
	local myToken = sc.loopToken
	local session = sc.session
	local lastSig = ""
	local function tick()
		if myToken ~= sc.loopToken or session ~= sc.session then
			return
		end
		-- Keep backend alive even while paused
		pcall(tern.fs.write, hbFile(sc), tostring(math.floor(tern.now())))
		if not sc.playing and not sc.countInActive then
			if sc.backendRunning then
				tern.timer(300, tick)
			end
			return
		end
		
		-- Read true audio clock from backend state file
		local ok, text = pcall(tern.fs.read, stateFile(sc))
		if ok and text ~= "" then
			local okj, data = pcall(tern.json.decode, text)
			if okj and type(data) == "table" then
				if data.seq ~= nil and data.seq ~= sc.backendSeq then
					sc.backendSeq = data.seq
					sc.lastBackendActiveAt = tern.now()
				end
				if data.pos_ms ~= nil then
					sc.pos = data.pos_ms
				end
				if data.duration_ms ~= nil and data.duration_ms > 0 then
					sc.countInDuration = data.duration_ms
				end
				if sc.countInActive then
					if data.playing == false and data.pos_ms >= (sc.countInDuration or 1900) - 50 then
						sc.countInActive = false
						sc.playing = true
						sc.pos = sc.from
						local full = sc.out .. "/full.wav"
						sendCmd(sc, { action = "load", file = full, pos_ms = math.floor(sc.from), paused = false })
						if sc.speed ~= 1.0 then
							sendCmd(sc, { action = "speed", speed = sc.speed })
						end
						if sc.loop then
							local a, b = loopRange(sc)
							playerLoop(sc, a, b)
						end
					end
				elseif data.playing ~= nil then
					sc.playing = data.playing and not data.paused
				end
			end
		end

		sc.cur = beatsAt(sc, sc.pos)
		local ids = {}
		for id in pairs(sc.cur) do
			table.insert(ids, id)
		end
		table.sort(ids)
		local sig = table.concat(ids, ",")
				-- Viewport follow: when playback crosses to a new system row,
		-- reveal it into view via TSP raw frame op ["reveal", nodeId, "nearest"]
		local activeSys: number? = nil
		for sidx, sys in ipairs(sc.systems) do
			for id in pairs(sc.cur) do
				for _, b in ipairs(sys.beats) do
					if b.i == id then
						activeSys = sidx
						break
					end
				end
				if activeSys ~= nil then break end
			end
			if activeSys ~= nil then break end
		end
		if activeSys ~= nil and activeSys ~= sc.lastActiveSys then
			sc.lastActiveSys = activeSys
			local nodeKey = string.format("sys_%d_%d", state.active, activeSys)
			pcall(function()
				cx:frame({ { "reveal", nodeKey, "nearest" } })
			end)
		end
		if sig ~= lastSig then
			lastSig = sig
			cx:render()
		end

		if myToken == sc.loopToken and (sc.playing or sc.countInActive) then
			tern.timer(TICK_MS, tick)
		else
			cx:render()
		end
	end
	tern.timer(TICK_MS, tick)
end

local function playFrom(state: State, cx: any, sc: Score, from: number, to: number)
	for i, other in ipairs(state.scores) do
		if i ~= state.active and other.playing then
			playerStop(other)
		end
	end
	ensureBackend(sc)
	sc.session = newSession()
	sc.from, sc.to = from, to

	-- count-in: 1 bar of metronome ticks before the real playback
	local countInPath = sc.out .. "/count_in.wav"
	if sc.countIn and from <= 0 and tern.fs.exists(countInPath) then
		sc.countInActive = true
		sc.playing = false
		sc.pos = 0
		sendCmd(sc, { action = "load", file = countInPath, pos_ms = 0, paused = false })
		startAudioLoop(state, cx, sc)
		cx:render()
		return
	end

	sc.countInActive = false
	sc.pos = from
	sc.playing = true

	local full = sc.out .. "/full.wav"
	sendCmd(sc, { action = "load", file = full, pos_ms = math.floor(from), paused = false })
	if sc.speed ~= 1.0 then
		sendCmd(sc, { action = "speed", speed = sc.speed })
	end

	if sc.loop then
		local a, b = loopRange(sc)
		playerLoop(sc, a, b)
	else
		playerLoop(sc, nil, nil)
	end

	startAudioLoop(state, cx, sc)
	cx:render()
end

local function applyJson(cx: any, sc: Score, data: any)
	sc.title = data.title or "Score"
	sc.tuning = data.tuning or {}
	sc.tempoBpm = data.tempo_bpm or 120
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
			-- the renderer's stableId is the identity the agent protocol exports,
			-- so keep it; only a payload without one falls back to a running index
			if n.id == nil then
				n.id = id
			end
			id = math.max(id, n.id + 1)
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
	for sindex, sys in ipairs(sc.systems) do
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
		local isCurSys = (bar ~= nil)
		local nodeKey = string.format("sys_%d_%d", index, sindex)
		table.insert(rows, ui.node("image", {
			key = nodeKey,
			blob = sys.blob, w = sys.w, h = sys.h, alt = sys.png,
			role = if isCurSys then "score-active" else "score",
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
			local isDraft = (args[2] == "draft") or (path:find("draft_") ~= nil)
			local rawTitle = path:match("[^/\\]+$") or path
			local sc: Score = {
				path = path,
				out = cacheDir(path, width),
				title = if isDraft then ("[Draft] " .. rawTitle) else rawTitle,
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
				speed = 1.0,
				countIn = true,
				countInActive = false,
				countInDuration = nil,
				tempoBpm = 120,
				backendRunning = false,
				cmdSeq = 0,
				loopToken = 0,
				backendSeq = nil,
				lastBackendActiveAt = nil,
				lastActiveSys = nil,
				isDraft = isDraft,
				draftTemplate = nil,
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
			-- Count-in toggle button
			table.insert(bar, button("sparkle", "count_in_toggle", "Count-in: " .. (if sc.countIn then "ON" else "OFF"),
				if sc.countIn then "accent" else "muted"))
			-- Agent Draft button when bars are selected
			if sc.selA ~= nil then
				local barsLabel = tostring(sc.selA) .. "–" .. tostring(sc.selB or sc.selA)
				table.insert(bar, button("wand", "agent_draft", "Ask Agent to create practice variation for bars " .. barsLabel, "accent"))
			end
			if sc.isDraft then
				table.insert(bar, ui.node("badge", { text = "Agent Draft", tone = "accent", title = "AI-generated practice variation" }))
			end
			-- Speed button
			local speedLabel = string.format("%.2fx", sc.speed or 1.0)
			table.insert(bar, button("speed", "speed_cycle", "Speed: " .. speedLabel .. " (click to cycle 0.75x/1.0x/1.25x)"))
			
			local marks = ""
			if sc.countInActive then
				marks = "PREP... " .. clock(sc.pos)
			else
				marks = clock(sc.pos) .. " / " .. clock(sc.duration) .. " [" .. speedLabel .. "]"
			end
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
				playerPause(sc)
			else
				if sc.pos > 0 and sc.pos < sc.duration then
					ensureBackend(sc)
					sc.playing = true
					sendCmd(sc, { action = "play" })
					startAudioLoop(state, cx, sc)
				else
					playFrom(state, cx, sc, startPos(sc), endPos(sc))
				end
			end
			cx:render()
			return true
		elseif key.name == "a" then
			sc.markA, sc.loop = sc.pos, true
			playerLoop(sc, nil, nil)
			cx:render()
			return true
		elseif key.name == "b" then
			sc.markB, sc.loop = sc.pos, true
			playerLoop(sc, sc.markA, sc.markB)
			cx:render()
			return true
		elseif key.name == "escape" then
			sc.markA, sc.markB, sc.loop = nil, nil, false
			sc.selA, sc.selB, sc.selT0, sc.selT1 = nil, nil, nil, nil
			playerLoop(sc, nil, nil)
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
		if act == "agent_draft" then
			local sc0 = state.scores[state.active]
			if sc0 == nil or sc0.selA == nil then
				cx:toast("warning", "Select some bars first", "Click a bar, Shift-click to extend")
				return
			end
			local requestId = string.format("req_%d_%d", math.floor(tern.now()), math.random(100000))
			local draftsDir = tern.plugin.data .. "/drafts"
			pcall(tern.fs.mkdir, draftsDir)
			local selFile = draftsDir .. "/selection_" .. requestId .. ".json"
			-- keep a per-request snapshot so the generator never reads a newer selection
			exportSelection(sc0, selFile)
			local reqPayload = {
				action = "create_draft",
				request_id = requestId,
				selection_file = selFile,
				source_score = sc0.path,
				source_pane = cx.pane,
				title = sc0.title,
				bars = { sc0.selA, sc0.selB or sc0.selA },
				t0 = sc0.selT0,
				t1 = sc0.selT1,
				template = sc0.draftTemplate or "alternate_picking",
				bpm = 60,
				created_at = math.floor(tern.now()),
			}
			pcall(tern.fs.write, tern.plugin.data .. "/draft-request.json", tern.json.encode(reqPayload, true))
			cx:toast("info", "Draft requested",
				"Bars " .. tostring(sc0.selA) .. "–" .. tostring(sc0.selB or sc0.selA) .. " · " .. tostring(sc0.draftTemplate or "alternate_picking"))
			return
		end
		if act == "playpause" or act == "stop" or act == "home" or act == "back"
			or act == "fwd" or act == "loop" or act == "speed_cycle"
			or act == "count_in_toggle" then
			local sc0 = state.scores[state.active]
			if sc0 == nil or sc0.status ~= "ready" then
				return
			end
			if act == "playpause" then
				if sc0.playing then
					playerPause(sc0)
				else
					if sc0.pos > 0 and sc0.pos < sc0.duration then
						ensureBackend(sc0)
						sc0.playing = true
						sendCmd(sc0, { action = "play" })
						startAudioLoop(state, cx, sc0)
					else
						playFrom(state, cx, sc0, startPos(sc0), endPos(sc0))
					end
				end
			elseif act == "count_in_toggle" then
				sc0.countIn = not sc0.countIn
			elseif act == "speed_cycle" then
				local nextSpeed = 1.0
				if math.abs((sc0.speed or 1.0) - 1.0) < 0.05 then
					nextSpeed = 1.25
				elseif math.abs((sc0.speed or 1.0) - 1.25) < 0.05 then
					nextSpeed = 0.75
				else
					nextSpeed = 1.0
				end
				playerSpeed(sc0, nextSpeed)
			elseif act == "loop" then
				sc0.loop = not sc0.loop
				if not sc0.loop then
					sc0.selA, sc0.selB, sc0.selT0, sc0.selT1 = nil, nil, nil, nil
					playerLoop(sc0, nil, nil)
				else
					local a, b = loopRange(sc0)
					playerLoop(sc0, a, b)
				end
			elseif act == "stop" then
				playerStop(sc0)
				sc0.pos = 0
			elseif act == "home" then
				playerSeek(sc0, 0)
			elseif act == "back" then
				playerSeek(sc0, math.max(0, sc0.pos - STEP_MS))
			elseif act == "fwd" then
				playerSeek(sc0, math.min(sc0.duration, sc0.pos + STEP_MS))
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
			local targetNote: Note? = nil
			for _, sys in ipairs(sc.systems) do
				for _, n in ipairs(sys.notes) do
					if n.id == id then
						want = n.b
						targetNote = n
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
			-- Click note seeks to that beat directly via mpv seek
			ensureBackend(sc)
			playerSeek(sc, at)
			if not sc.playing then
				sc.cur = beatsAt(sc, at)
			end
			cx:render()
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

