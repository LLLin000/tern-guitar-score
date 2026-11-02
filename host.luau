--!strict
-- Guitar Score: alphaTab renders each score to PNG systems; every note head is an
-- absolutely positioned hit box driven by static CSS classes (.gx116 .gy532 ...).
-- Several scores sit side by side; one is active and owns the transport.

local ui = tern.ui

local NODE = "C:/Program Files/nodejs/node.exe"
local PYTHON = "D:/programs/Python/python.exe"
local REQUEST = tern.plugin.data .. "/open-request.json"

-- Expose the shared plugin data directory to OMP shell panes.
tern.on("spawn", function(spec: any)
	local env = spec.env or {}
	env.GSCORE_DATA_DIR = tern.plugin.data
	spec.env = env
	return spec
end)

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

type Occ = { t: number, tick: number?, bar: number?, durationTicks: number?, dots: number?, tuplet: string?, nb: { number } }
type Note = {
	id: number,
	b: number,
	m: number,
	string: number,
	fret: number,
	realValue: number?,
	dots: number?,
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

type TrackInfo = { index: number, name: string, channels: { number } }

type Score = {
	path: string,
	out: string,
	renderOut: string,
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
	audioReady: boolean,
	tracks: { TrackInfo },
	mutedTracks: { [number]: boolean },
	soloTrack: number?,
	metronome: boolean,
	mixPath: string?,
	linkedBar: number?,
	lastPlaybackBar: number?,
}

type State = {
	scores: { Score },
	active: number,
	width: number,
	paneId: string,
	sourcePane: string?,
	sourceStart: number,
	sourceEnd: number,
	renderGeneration: number,
}

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
local function renderDir(path: string, width: number, revision: number): string
	return cacheDir(path, width) .. "/r" .. tostring(revision)
end

local function renderWidth(cols: number, scoreCount: number): number
	local perScore = math.floor(math.max(1, cols) * 8 / math.max(1, scoreCount))
	return math.max(220, math.min(1040, perScore))
end

local function audioFile(sc: Score): string
	return sc.mixPath or (sc.out .. "/full.wav")
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
					beat = n.b,
					bar = n.m,
					string = n.string,
					fret = n.fret,
					real_value = n.realValue,
					midi = n.realValue or (baseMidi + (n.fret or 0)),
					duration_ticks = n.durationTicks,
					dots = n.dots,
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
			table.insert(beats, {
				t = o.t, bar = o.bar, tick = o.tick,
				duration_ticks = o.durationTicks, dots = o.dots,
				tuplet = o.tuplet, beat_ids = o.nb,
			})
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

-- sentinel-delimited per-command files in `<cache>/cmds/` avoid read-modify-write
-- races between Luau writers and the Python reader; the sentinel detects partial writes.
local function cmdsDir(sc: Score): string
	local dir = sc.out .. "/cmds"
	pcall(tern.fs.mkdir, dir)
	return dir
end

local function stateFile(sc: Score): string
	return sc.out .. "/audio_state.json"
end

-- Luau has no rename, so command completeness uses an end sentinel: the reader
-- only consumes a file whose body terminates with END_SENTINEL. This is not a
-- filesystem-atomic publish.
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
	sc.countInActive = false
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
	sc.lastPlaybackBar = nil
end

local function playerSpeed(sc: Score, speed: number)
	sc.speed = speed
	sendCmd(sc, { action = "speed", speed = speed })
end

local function playerLoop(sc: Score, a_ms: number?, b_ms: number?)
	sendCmd(sc, { action = "loop", loop_a_ms = a_ms, loop_b_ms = b_ms })
end

local function independentlyMixable(sc: Score): boolean
	if #sc.tracks < 2 then
		return false
	end
	local channels: { [number]: boolean } = {}
	for _, track in ipairs(sc.tracks) do
		if #track.channels == 0 then
			return false
		end
		for _, channel in ipairs(track.channels) do
			if channels[channel] then
				return false
			end
			channels[channel] = true
		end
	end
	return true
end

local function requestMix(cx: any, sc: Score)
	if not sc.audioReady then
		return
	end
	local files = {}
	if independentlyMixable(sc) then
		for _, track in ipairs(sc.tracks) do
			local enabled = not sc.mutedTracks[track.index]
				and (sc.soloTrack == nil or sc.soloTrack == track.index)
			if enabled then
				table.insert(files, sc.out .. "/track-" .. tostring(track.index) .. ".wav")
			end
		end
	else
		table.insert(files, sc.out .. "/full.wav")
	end
	if sc.metronome then
		table.insert(files, sc.out .. "/metronome.wav")
	end
	for _, file in ipairs(files) do
		if not tern.fs.exists(file) then
			cx:toast("error", "Audio mix unavailable", "Missing " .. file)
			return
		end
	end
	local stateKey = {}
	for _, track in ipairs(sc.tracks) do
		local enabled = not sc.mutedTracks[track.index]
			and (sc.soloTrack == nil or sc.soloTrack == track.index)
		table.insert(stateKey, tostring(track.index) .. (if enabled then "1" else "0"))
	end
	table.insert(stateKey, if sc.metronome then "m1" else "m0")
	local output = sc.out .. "/mix-" .. table.concat(stateKey, "-")
		.. "-" .. tostring(math.floor(tern.now())) .. "-" .. tostring(math.random(1000000)) .. ".wav"
	sc.mixPath = output
	ensureBackend(sc)
	sendCmd(sc, {
		action = "mix",
		files = files,
		reference = sc.out .. "/full.wav",
		output = output,
	})
end

local function linkKey(state: State): string?
	local owner = state.sourcePane or state.paneId
	if owner == "" then
		return nil
	end
	return "gscore.measure-link." .. owner
end

local function publishLinkedBar(state: State, sc: Score, bar: number)
	local key = linkKey(state)
	if key == nil then
		return
	end
	local sourceBar = if state.sourcePane ~= nil then state.sourceStart + bar else bar
	sc.linkedBar = bar
	local value = tern.json.encode({ bar = sourceBar }, false)
	local ok, err = pcall(tern.kv.set, key, value)
end

local function measureAt(sc: Score, ms: number): number?
	for _, mt in ipairs(sc.measureTimes) do
		if ms >= mt.t0 and ms < mt.t1 then
			return mt.mb
		end
	end
	return nil
end

local function revealSystem(cx: any, index: number, sindex: number)
	local key = string.format("main.scores.columns.score_%d.sys_%d_%d", index, index, sindex)
	pcall(function()
		cx:frame({ { "reveal", key, "nearest" } })
	end)
end

local function revealMeasure(cx: any, index: number, sc: Score, bar: number)
	for sindex, sys in ipairs(sc.systems) do
		for _, measure in ipairs(sys.measures) do
			if measure.mb == bar then
				revealSystem(cx, index, sindex)
				return
			end
		end
	end
end

local function syncLinkedBar(state: State, cx: any, index: number, sc: Score): boolean
	local key = linkKey(state)
	if key == nil then
		return false
	end
	local ok, raw = pcall(tern.kv.get, key)
	if not ok or type(raw) ~= "string" then
		return false
	end
	local okj, data = pcall(tern.json.decode, raw)
	if not okj or type(data) ~= "table" or type(data.bar) ~= "number" then
		return false
	end
	local bar: number? = data.bar
	if state.sourcePane ~= nil then
		if data.bar < state.sourceStart or data.bar > state.sourceEnd then
			bar = nil
		else
			bar = data.bar - state.sourceStart
		end
	end
	if bar ~= nil then
		local found = false
		for _, mt in ipairs(sc.measureTimes) do
			if mt.mb == bar then
				found = true
				break
			end
		end
		if not found then
			bar = nil
		end
	end
	if sc.linkedBar == bar then
		return false
	end
	sc.linkedBar = bar
	if bar ~= nil then
		revealMeasure(cx, index, sc, bar)
	end
	return true
end

local function startLinkPoll(state: State, cx: any)
	local function tick()
		local changed = false
		for index, sc in ipairs(state.scores) do
			if syncLinkedBar(state, cx, index, sc) then
				changed = true
			end
		end
		if changed then
			pcall(function() cx:render() end)
		end
		tern.timer(250, tick)
	end
	tern.timer(250, tick)
end

-- single polling loop per score: each invocation gets a unique `myToken`.
-- If state restarts or resumes, previous loops observe token mismatch and exit cleanly.
local function startAudioLoop(state: State, cx: any, sc: Score)
	sc.loopToken = (sc.loopToken or 0) + 1
	local myToken = sc.loopToken
	local session = sc.session
	local scoreIndex = state.active
	for i, one in ipairs(state.scores) do
		if one == sc then
			scoreIndex = i
			break
		end
	end
	local lastSig = ""
	local function tick()
		if myToken ~= sc.loopToken or session ~= sc.session then
			return
		end
		pcall(tern.fs.write, hbFile(sc), tostring(math.floor(tern.now())))
		if not sc.playing and not sc.countInActive then
			if syncLinkedBar(state, cx, scoreIndex, sc) then
				cx:render()
			end
			if sc.backendRunning then
				tern.timer(300, tick)
			end
			return
		end

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
						sendCmd(sc, { action = "load", file = audioFile(sc), pos_ms = math.floor(sc.from), paused = false })
						if sc.speed ~= 1.0 then
							sendCmd(sc, { action = "speed", speed = sc.speed })
						end
						if sc.loop then
							local a, b = loopRange(sc)
							playerLoop(sc, a, b)
						else
							playerLoop(sc, nil, nil)
						end
					end
				elseif data.playing ~= nil then
					sc.playing = data.playing and not data.paused
				end
			end
		end

		local linkChanged = false
		if not sc.countInActive then
			local bar = measureAt(sc, sc.pos)
			if bar ~= nil and bar ~= sc.lastPlaybackBar then
				sc.lastPlaybackBar = bar
				publishLinkedBar(state, sc, bar)
			end
			linkChanged = syncLinkedBar(state, cx, scoreIndex, sc)
		end

		sc.cur = beatsAt(sc, sc.pos)
		local ids = {}
		for id in pairs(sc.cur) do
			table.insert(ids, id)
		end
		table.sort(ids)
		local sig = table.concat(ids, ",")
		local currentBar = measureAt(sc, sc.pos)
		local activeSys: number? = nil
		if currentBar ~= nil then
			for sidx, sys in ipairs(sc.systems) do
				for _, measure in ipairs(sys.measures) do
					if measure.mb == currentBar then
						activeSys = sidx
						break
					end
				end
				if activeSys ~= nil then break end
			end
		end
		if activeSys ~= nil and activeSys ~= sc.lastActiveSys then
			sc.lastActiveSys = activeSys
			revealSystem(cx, scoreIndex, activeSys)
		end
		if sig ~= lastSig or linkChanged then
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
	sc.lastPlaybackBar = nil

	-- The prior A-B loop belongs to the score, not to the count-in file.
	local countInPath = sc.out .. "/count_in.wav"
	if sc.countIn and from <= 0 and tern.fs.exists(countInPath) then
		playerLoop(sc, nil, nil)
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

	local full = audioFile(sc)
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

local function applyJson(cx: any, sc: Score, data: any, renderOut: string)
	sc.title = data.title or "Score"
	sc.tuning = data.tuning or {}
	sc.tempoBpm = data.tempo_bpm or 120
	sc.timeSignature = data.timeSignature or { 4, 4 }
	sc.duration = data.duration or 0
	sc.to = sc.duration
	sc.tracks = data.tracks or {}
	sc.systems = {}
	sc.timeline = data.timeline or {}
	sc.measureTimes = data.measureTimes or {}
	local id = 0
	for _, s in ipairs(data.systems) do
		local blob: any = nil
		local okb, bytes = pcall(tern.fs.read, renderOut .. "/" .. s.png)
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
	sc.lastActiveSys = nil
	sc.status = "ready"
end

local renderOne: (any, State, number, number, boolean, number) -> ()

function renderOne(cx: any, state: State, index: number, revision: number, withAudio: boolean, width: number)
	local sc = state.scores[index]
	if not sc then
		return
	end
	local renderOut = renderDir(sc.path, width, revision)
	if revision == state.renderGeneration then
		sc.renderOut = renderOut
	end
	if #sc.systems == 0 then
		sc.status = "loading"
	end
	local argv = {
		NODE, "index.mjs",
		"--input", sc.path,
		"--out", renderOut,
		"--audio-out", sc.out,
		"--width", tostring(width),
	}
	if not withAudio then
		table.insert(argv, "--no-audio")
	end
	local function failed(message: string)
		if #sc.systems == 0 then
			sc.status, sc.err = "error", message
		else
			cx:toast("error", "Score resize failed", message)
		end
	end
	local started, startErr = pcall(function()
		tern.process.run(argv, { cwd = tern.plugin.dir .. "/renderer", timeout_ms = 300000 }):next(function(res, runErr)
			if runErr then
				failed(tostring(runErr))
			elseif not res or res.status ~= 0 then
				failed((res and (res.stderr ~= "" and res.stderr or res.stdout)) or "renderer failed")
			else
				local ok, data = pcall(tern.json.decode, res.stdout)
				if not ok or type(data) ~= "table" or type(data.systems) ~= "table" then
					failed("bad renderer output")
				else
					if withAudio then
						sc.audioReady = true
					end
					if revision == state.renderGeneration or #sc.systems == 0 then
						local duration = sc.duration
						applyJson(cx, sc, data, renderOut)
						if not withAudio then
							sc.duration, sc.to = duration, duration
						end
					end
				end
			end
			cx:render()
			if withAudio or revision == state.renderGeneration then
				renderOne(cx, state, index + 1, revision, withAudio, width)
			end
		end)
	end)
	if not started then
		failed(tostring(startErr))
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

local function badgeButton(text: string, act: string, tip: string, tone: string?): Node
	local node = ui.node("badge", { text = text, tone = tone, title = tip })
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
			if sc.linkedBar == m.mb then
				cls = cls .. " glink"
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

	return ui.el("div", { class = "gcol", key = "score_" .. tostring(index) }, rows)
end

local def: BlockDef<State> = {
	init = function(cx: any, args: { string }, saved: any): State
		local root = args[1] or (saved and saved.root) or ""
		local files = if root == "" then {} else scoreFiles(root)
		local cols = tonumber(cx.cols) or 100
		local width = renderWidth(cols, #files)
		local sourcePane = args[3]
		if sourcePane == "" then sourcePane = nil end
		local sourceStart = math.floor(tonumber(args[4]) or 0)
		local sourceEnd = math.floor(tonumber(args[5]) or sourceStart)
		local state: State = {
			scores = {}, active = 1, width = width,
			paneId = tostring(cx.pane or ""), sourcePane = sourcePane,
			sourceStart = sourceStart, sourceEnd = sourceEnd, renderGeneration = 0,
		}
		if sourcePane == nil then
			local key = linkKey(state)
			if key then pcall(tern.kv.set, key, "") end
		end
		local paneCache = state.paneId
		if paneCache == "" then paneCache = newSession() end
		paneCache = paneCache:gsub("[^%w]", "_")
		for _, path in ipairs(files) do
			local isDraft = (args[2] == "draft") or (path:find("draft_") ~= nil)
			local rawTitle = path:match("[^/\\]+$") or path
			local sc: Score = {
				path = path,
				out = cacheDir(path, 0) .. "/pane-" .. paneCache,
				renderOut = renderDir(path, width, state.renderGeneration),
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
				audioReady = false,
				tracks = {},
				mutedTracks = {},
				soloTrack = nil,
				metronome = false,
				mixPath = nil,
				linkedBar = nil,
				lastPlaybackBar = nil,
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
		renderOne(cx, state, 1, state.renderGeneration, true, state.width)
		startLinkPoll(state, cx)
		return state
	end,

	resize = function(state: State, cols: number, _rows: number, cx: any)
		if #state.scores == 0 then return end
		local width = renderWidth(tonumber(cols) or 44, #state.scores)
		if width == state.width then return end
		state.width = width
		state.renderGeneration = state.renderGeneration + 1
		local revision = state.renderGeneration
		for _, sc in ipairs(state.scores) do
			sc.renderOut = renderDir(sc.path, width, revision)
		end
		local function resizeWhenReady()
			if revision ~= state.renderGeneration then return end
			for _, sc in ipairs(state.scores) do
				if not sc.audioReady then
					if sc.status == "loading" then
						tern.timer(200, resizeWhenReady)
					end
					return
				end
			end
			renderOne(cx, state, 1, revision, false, width)
		end
		tern.timer(220, resizeWhenReady)
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
		local mixBar: { Node } = {}
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
			table.insert(bar, button("sparkle", "count_in_toggle", "Count-in: " .. (if sc.countIn then "ON" else "OFF"),
				if sc.countIn then "accent" else "muted"))
			if sc.selA ~= nil then
				table.insert(bar, button("wand", "agent_draft",
					"Ask Agent to create practice variation for bars " .. tostring(sc.selA) .. "–" .. tostring(sc.selB or sc.selA),
					"accent"))
			end
			if sc.isDraft then
				table.insert(bar, ui.node("badge", { text = "Agent Draft", tone = "accent", title = "AI-generated practice variation" }))
			end
			local speedLabel = string.format("%.2fx", sc.speed or 1.0)
			table.insert(bar, button("speed", "speed_cycle", "Speed: " .. speedLabel .. " (click to cycle 0.75x/1.0x/1.25x)"))

			if independentlyMixable(sc) then
				table.insert(mixBar, ui.text({ ui.span("Tracks", "muted") }))
				for _, track in ipairs(sc.tracks) do
					local number = tostring(track.index + 1)
					local muted = sc.mutedTracks[track.index] == true
					local solo = sc.soloTrack == track.index
					table.insert(mixBar, badgeButton("M" .. number, "track_mute=" .. tostring(track.index),
						(if muted then "Unmute " else "Mute ") .. track.name, if muted then "accent" else "muted"))
					table.insert(mixBar, badgeButton("S" .. number, "track_solo=" .. tostring(track.index),
						(if solo then "Unsolo " else "Solo ") .. track.name, if solo then "accent" else "muted"))
				end
			end
			if #sc.tracks > 0 then
				table.insert(mixBar, badgeButton(if sc.metronome then "Click on" else "Click off",
					"metronome_toggle", if sc.metronome then "Disable live metronome" else "Enable live metronome",
					if sc.metronome then "accent" else "muted"))
			end

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

		local toolbar: { Node } = {
			ui.el("div", { class = "gscore-toolbar" }, { ui.row(bar) }),
		}
		if #mixBar > 0 then
			table.insert(toolbar, ui.el("div", { class = "gscore-mixer" }, { ui.row(mixBar) }))
		end
		local scoreRow = ui.row(cols)
		local scoreRowProps: { [string]: any } = scoreRow.p or {}
		scoreRowProps.key = "columns"
		scoreRow.p = scoreRowProps
		return {
			main = ui.col({
				ui.el("div", { class = "gscore-bar" }, toolbar),
				ui.el("div", { class = "gcols", key = "scores" }, { scoreRow }),
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
			local requestDir = tern.plugin.data .. "/draft_requests"
			local draftsDir = tern.plugin.data .. "/drafts"
			pcall(tern.fs.mkdir, requestDir)
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
			pcall(tern.fs.write, requestDir .. "/" .. requestId .. ".json",
				tern.json.encode(reqPayload, true) .. END_SENTINEL)
			cx:toast("info", "Draft requested",
				"Bars " .. tostring(sc0.selA) .. "–" .. tostring(sc0.selB or sc0.selA) .. " · " .. tostring(sc0.draftTemplate or "alternate_picking"))
			cx:render()
			return
		end
		if act == "track_mute" or act == "track_solo" or act == "metronome_toggle" then
			local sc0 = state.scores[state.active]
			if sc0 == nil or sc0.status ~= "ready" then
				return
			end
			if sc0.countInActive then
				cx:toast("warning", "Wait for count-in to finish before changing the mix")
				return
			end
			if act == "metronome_toggle" then
				if #sc0.tracks == 0 then return end
				sc0.metronome = not sc0.metronome
			else
				if not independentlyMixable(sc0) then return end
				local trackIndex = tonumber(ev.value or "")
				local found = false
				for _, track in ipairs(sc0.tracks) do
					if track.index == trackIndex then
						found = true
						break
					end
				end
				if not found or trackIndex == nil then return end
				if act == "track_mute" then
					sc0.mutedTracks[trackIndex] = not sc0.mutedTracks[trackIndex]
				elseif sc0.soloTrack == trackIndex then
					sc0.soloTrack = nil
				else
					sc0.soloTrack = trackIndex
				end
			end
			requestMix(cx, sc0)
			cx:render()
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
			sc.lastPlaybackBar = nil
			publishLinkedBar(state, sc, mb)
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


-- lesson block ------------------------------------------------------------

type LessonState = {
	lesson_id: string,
	revision: number,
	lesson: any?,
	err: string?,
	answers: { [string]: any },
	selected_pitches: { [string]: any },
}

local LESSON_ATTEMPT_SENTINEL = "\n__GSCORE_ATTEMPT_END__\n"
local LESSON_MAX_BYTES = 512 * 1024

local function lessonSafeId(value: any): boolean
	return type(value) == "string" and #value <= 64 and value:match("^[%w][%w_%-]*$") ~= nil
end

local function lessonPayloadErrorV1(lesson: any, lessonId: string, revision: number): string?
	if type(lesson) ~= "table" or lesson.schema ~= "gscore.lesson.v1"
		or lesson.lesson_id ~= lessonId or lesson.revision ~= revision then
		return "Lesson metadata does not match the pane request."
	end
	if type(lesson.goal) ~= "string" or lesson.goal == ""
		or type(lesson.activities) ~= "table" or #lesson.activities < 1 or #lesson.activities > 12 then
		return "Lesson content is invalid."
	end
	local seen: { [string]: boolean } = {}
	for _, activity in ipairs(lesson.activities) do
		if type(activity) ~= "table" or not lessonSafeId(activity.id) or seen[activity.id] then
			return "Lesson activity IDs are invalid."
		end
		seen[activity.id] = true
		if activity.type == "explanation" then
			if type(activity.text) ~= "string" or activity.text == "" then
				return "Lesson explanation is empty."
			end
		elseif activity.type == "chord_diagram" then
			if type(activity.svg) ~= "string" or #activity.svg > 262144
				or activity.svg:sub(1, 4) ~= "<svg" or activity.mime ~= "image/svg+xml"
				or type(activity.width) ~= "number" or activity.width <= 0
				or type(activity.height) ~= "number" or activity.height <= 0 then
				return "Lesson chord diagram is invalid."
			end
		elseif activity.type == "quiz" then
			if activity.question_type ~= "slash_bass" or type(activity.prompt) ~= "string"
				or type(activity.choices) ~= "table" or #activity.choices < 2 or #activity.choices > 6
				or type(activity.correct_index) ~= "number" or activity.correct_index % 1 ~= 0
				or activity.correct_index < 1 or activity.correct_index > #activity.choices then
				return "Lesson quiz is invalid."
			end
		else
			return "Lesson contains an unsupported activity."
		end
	end
	return nil
end

local function lessonFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

local function lessonPayloadErrorV2(lesson: any): string?
	if type(lesson.goal) ~= "string" or lesson.goal == ""
		or type(lesson.activities) ~= "table" or #lesson.activities < 1 or #lesson.activities > 12 then
		return "Lesson v2 content is invalid."
	end
	local seen: { [string]: boolean } = {}
	local visualShapes: { [string]: string } = {}
	for _, activity in ipairs(lesson.activities) do
		if type(activity) ~= "table" or not lessonSafeId(activity.id) or seen[activity.id] then
			return "Lesson v2 activity IDs are invalid."
		end
		seen[activity.id] = true
		if activity.type == "explanation" then
			if type(activity.content) ~= "string" or activity.content == "" then
				return "Lesson v2 explanation is empty."
			end
		elseif activity.type == "visual" then
			if activity.renderer ~= "guitar.chord" or activity.intent ~= "compare"
				or type(activity.items) ~= "table" or #activity.items ~= 2
				or type(activity.emphasis) ~= "table" or activity.emphasis.property ~= "lowest_sounding_pitch"
				or type(activity.interaction) ~= "table" or activity.interaction.action ~= "select_pitch" then
				return "Lesson v2 visual contract is unsupported."
			end
			local lowestMidis: { number } = {}
			for _, item in ipairs(activity.items) do
				local ref = if type(item) == "table" then item.shape_ref else nil
				local shape = if type(item) == "table" then item.shape else nil
				local diagram = if type(item) == "table" then item.diagram else nil
				if type(ref) ~= "table" or type(ref.symbol) ~= "string" or #ref.symbol == 0 or #ref.symbol > 80
					or type(ref.id) ~= "string" or #ref.id ~= 71 or not ref.id:match("^gshape_[0-9a-f]+$")
					or type(shape) ~= "table" or shape.shape_id ~= ref.id or item.symbol ~= ref.symbol
					or type(shape.actualFrets) ~= "table" or #shape.actualFrets ~= 6 or type(shape.notes) ~= "table"
					or type(shape.midi) ~= "table" or #shape.notes ~= #shape.midi
					or not lessonFiniteNumber(shape.lowestMidi)
					or type(shape.lowestNote) ~= "string"
					or type(diagram) ~= "table" or type(diagram.svg) ~= "string"
					or #diagram.svg > 262144 or diagram.svg:sub(1, 4) ~= "<svg"
					or diagram.mime ~= "image/svg+xml"
					or not lessonFiniteNumber(diagram.width) or diagram.width <= 0
					or not lessonFiniteNumber(diagram.height) or diagram.height <= 0
					or type(diagram.hit_regions) ~= "table" then
					return "Lesson v2 guitar shape or diagram is invalid."
				end
				local notesByString: { [number]: any } = {}
				local noteIndex = 0
				local actualLowestMidi = math.huge
				local actualLowestNote: string? = nil
				for index, fret in ipairs(shape.actualFrets) do
					if not lessonFiniteNumber(fret) or fret % 1 ~= 0 then
						return "Lesson v2 guitar frets are invalid."
					end
					if fret >= 0 then
						noteIndex = noteIndex + 1
						local midi = shape.midi[noteIndex]
						local pitch = shape.notes[noteIndex]
						if not lessonFiniteNumber(midi) or type(pitch) ~= "string" then
							return "Lesson v2 guitar pitches are invalid."
						end
						notesByString[7 - index] = { fret = fret, midi = midi, pitch = pitch }
						if midi < actualLowestMidi then
							actualLowestMidi = midi
							actualLowestNote = pitch
						end
					end
				end
				if noteIndex == 0 or noteIndex ~= #shape.notes or actualLowestMidi ~= shape.lowestMidi
					or actualLowestNote ~= shape.lowestNote or #diagram.hit_regions ~= noteIndex then
					return "Lesson v2 guitar shape pitches or hit regions do not match."
				end
				local regionIds: { [string]: boolean } = {}
				for _, region in ipairs(diagram.hit_regions) do
					if type(region) ~= "table" or not lessonFiniteNumber(region.string)
						or region.string % 1 ~= 0 or region.string < 1 or region.string > 6
						or not lessonFiniteNumber(region.fret) or region.fret % 1 ~= 0
						or type(region.id) ~= "string" then
						return "Lesson v2 hit region is invalid."
					end
					local expected = notesByString[region.string]
					local regionId = "s" .. tostring(region.string) .. "f" .. tostring(region.fret)
					if expected == nil or regionIds[regionId] or region.id ~= regionId
						or region.fret ~= expected.fret or region.midi ~= expected.midi
						or region.pitch ~= expected.pitch or region.lowest ~= (expected.midi == shape.lowestMidi)
						or not lessonFiniteNumber(region.x) or not lessonFiniteNumber(region.y)
						or not lessonFiniteNumber(region.w) or not lessonFiniteNumber(region.h)
						or region.x < 0 or region.y < 0 or region.w <= 0 or region.h <= 0
						or region.x + region.w > 1 or region.y + region.h > 1 then
						return "Lesson v2 hit region does not match the guitar shape."
					end
					regionIds[regionId] = true
				end
				visualShapes[ref.id] = ref.symbol
				table.insert(lowestMidis, shape.lowestMidi)
			end
			if lowestMidis[1] == lowestMidis[2] then
				return "Lesson v2 comparison has no lowest-pitch contrast."
			end
		elseif activity.type == "quiz" then
			local source = if type(activity.answer_source) == "table" then activity.answer_source.derived_from else nil
			if type(activity.question) ~= "string" or activity.question == ""
				or type(activity.options) ~= "table" or #activity.options < 2 or #activity.options > 6
				or not lessonFiniteNumber(activity.correct_index) or activity.correct_index % 1 ~= 0
				or activity.correct_index < 1 or activity.correct_index > #activity.options
				or activity.correct_choice ~= activity.options[activity.correct_index]
				or type(source) ~= "table" or activity.answer_source.property ~= "lowest_sounding_pitch_class"
				or visualShapes[source.id] ~= source.symbol then
				return "Lesson v2 quiz is invalid."
			end
		else
			return "Lesson v2 contains an unsupported activity."
		end
	end
	return nil
end

local function lessonPayloadError(lesson: any, lessonId: string, revision: number): string?
	if type(lesson) ~= "table" or lesson.lesson_id ~= lessonId or lesson.revision ~= revision then
		return "Lesson metadata does not match the pane request."
	end
	if lesson.schema == "gscore.lesson.v1" then
		return lessonPayloadErrorV1(lesson, lessonId, revision)
	elseif lesson.schema == "gscore.lesson.v2" then
		return lessonPayloadErrorV2(lesson)
	end
	return "Lesson schema is unsupported."
end

local function lessonQuizChoices(schema: string, activity: any): any
	if schema == "gscore.lesson.v1" then
		return activity.choices
	elseif schema == "gscore.lesson.v2" then
		return activity.options
	end
	return nil
end

local function readLessonAttempts(lessonId: string, revision: number, lesson: any): { [string]: any }
	local quizzes: { [string]: any } = {}
	for _, activity in ipairs(lesson.activities) do
		if activity.type == "quiz" then
			quizzes[activity.id] = activity
		end
	end
	local answers: { [string]: any } = {}
	local dir = tern.plugin.data .. "/lesson_attempts/" .. lessonId
	local okList, names = pcall(tern.fs.list, dir)
	if not okList or type(names) ~= "table" then
		return answers
	end
	table.sort(names)
	for _, name in ipairs(names) do
		if name:match("^attempt_[%w_%-]+%.json$") then
			local okRead, raw = pcall(tern.fs.read, dir .. "/" .. name)
			if okRead and type(raw) == "string" and raw:sub(-#LESSON_ATTEMPT_SENTINEL) == LESSON_ATTEMPT_SENTINEL then
				local body = raw:sub(1, #raw - #LESSON_ATTEMPT_SENTINEL)
				local okDecode, attempt = pcall(tern.json.decode, body)
				local activity = if okDecode and type(attempt) == "table" then quizzes[attempt.activity_id] else nil
				local choices = if activity ~= nil then lessonQuizChoices(lesson.schema, activity) else nil
				if activity ~= nil and type(choices) == "table" and attempt.schema == "gscore.lesson.attempt.v1"
					and attempt.lesson_id == lessonId and attempt.revision == revision
					and type(attempt.selected_index) == "number" and attempt.selected_index % 1 == 0
					and attempt.selected_index >= 1 and attempt.selected_index <= #choices
					and attempt.selected_choice == choices[attempt.selected_index]
					and type(attempt.attempted_at_ms) == "number"
					and (attempt.sequence == nil or (type(attempt.sequence) == "number" and attempt.sequence % 1 == 0 and attempt.sequence >= 0)) then
					local previous = answers[activity.id]
					local sequence = if type(attempt.sequence) == "number" then attempt.sequence else 0
					if previous == nil or attempt.attempted_at_ms > previous.attempted_at_ms
						or (attempt.attempted_at_ms == previous.attempted_at_ms and sequence >= (tonumber(previous.sequence) or 0)) then
						answers[activity.id] = {
							selected_index = attempt.selected_index,
							selected_choice = attempt.selected_choice,
							correct = attempt.correct,
							attempted_at_ms = attempt.attempted_at_ms,
							sequence = sequence,
						}
					end
				end
			end
		end
	end
	return answers
end

local function mergeSavedLessonAnswers(answers: { [string]: any }, saved: any, lesson: any)
	if type(saved) ~= "table" or type(saved.answers) ~= "table" then
		return
	end
	local quizzes: { [string]: any } = {}
	for _, activity in ipairs(lesson.activities) do
		if activity.type == "quiz" then
			quizzes[activity.id] = activity
		end
	end
	for id, answer in pairs(saved.answers) do
		local activity = quizzes[id]
		local choices = if activity ~= nil then lessonQuizChoices(lesson.schema, activity) else nil
		if activity ~= nil and type(answer) == "table" and type(choices) == "table"
			and type(answer.selected_index) == "number" and answer.selected_index % 1 == 0
			and answer.selected_index >= 1 and answer.selected_index <= #choices
			and answer.selected_choice == choices[answer.selected_index]
			and answer.correct == (answer.selected_index == activity.correct_index)
			and type(answer.attempted_at_ms) == "number"
			and (answer.sequence == nil or (type(answer.sequence) == "number" and answer.sequence % 1 == 0 and answer.sequence >= 0)) then
			local previous = answers[id]
			local sequence = if type(answer.sequence) == "number" then answer.sequence else 0
			if previous == nil or answer.attempted_at_ms > previous.attempted_at_ms
				or (answer.attempted_at_ms == previous.attempted_at_ms and sequence >= (tonumber(previous.sequence) or 0)) then
				answers[id] = {
					selected_index = answer.selected_index,
					selected_choice = answer.selected_choice,
					correct = answer.correct,
					attempted_at_ms = answer.attempted_at_ms,
					sequence = sequence,
				}
			end
		end
	end
end

local lesson: BlockDef<LessonState> = {
	init = function(cx: any, args: { string }, saved: any): LessonState
		local lessonId = args[1] or (if type(saved) == "table" then saved.lesson_id else nil) or ""
		local revision = tonumber(args[2]) or (if type(saved) == "table" then tonumber(saved.revision) else nil) or 0
		local state: LessonState = {
			lesson_id = lessonId,
			revision = revision,
			lesson = nil,
			err = nil,
			answers = {},
			selected_pitches = {},
		}
		if not lessonSafeId(lessonId) or revision < 1 or revision % 1 ~= 0 then
			state.err = "Lesson ID or revision is invalid."
			return state
		end
		local file = string.format("%s/lessons/%s/r%d.json", tern.plugin.data, lessonId, revision)
		local okRead, raw = pcall(tern.fs.read, file)
		if not okRead or type(raw) ~= "string" or #raw > LESSON_MAX_BYTES then
			state.err = "Lesson file is missing, unreadable, or too large."
			return state
		end
		local okDecode, decoded = pcall(tern.json.decode, raw)
		if not okDecode then
			state.err = "Lesson JSON is invalid."
			return state
		end
		local payloadError = lessonPayloadError(decoded, lessonId, revision)
		if payloadError ~= nil then
			state.err = payloadError
			return state
		end
		state.lesson = decoded
		state.answers = readLessonAttempts(lessonId, revision, decoded)
		if type(saved) == "table" and saved.lesson_id == lessonId and tonumber(saved.revision) == revision then
			mergeSavedLessonAnswers(state.answers, saved, decoded)
		end
		return state
	end,

	view = function(state: LessonState, cx: any): BlockView
		if state.err ~= nil or state.lesson == nil then
			return { main = ui.col({
				ui.text({ ui.span("Lesson unavailable", "error") }),
				ui.text({ ui.span(state.err or "Lesson data is unavailable.", "muted") }),
			}) }
		end
		local rows: { Node } = {
			ui.text({ ui.span(state.lesson.goal, "accent") }),
		}
		for _, activity in ipairs(state.lesson.activities) do
			local card: { Node } = {}
			if state.lesson.schema == "gscore.lesson.v2" then
				if activity.type == "explanation" then
					table.insert(card, ui.text({ ui.span("Explanation", "accent") }))
					table.insert(card, ui.text({ ui.span(activity.content) }))
				elseif activity.type == "visual" then
					table.insert(card, ui.text({ ui.span("Compare the lowest sounding pitch", "accent") }))
					local diagrams: { Node } = {}
					for itemIndex, item in ipairs(activity.items) do
						local diagramCard: { Node } = {
							ui.text({ ui.span(item.symbol .. " · lowest " .. item.shape.lowestNote, "accent") }),
						}
						if item.diagram.blob == nil then
							local okBlob, blob = pcall(function()
								return cx:blob(item.diagram.svg, item.diagram.mime)
							end)
							if okBlob then
								item.diagram.blob = blob
							end
						end
						if item.diagram.blob ~= nil then
							local hits: { Node } = {}
							for _, region in ipairs(item.diagram.hit_regions) do
								local selection = state.selected_pitches[activity.id]
								local selected = selection ~= nil and selection.item_index == itemIndex
									and selection.hit_id == region.id
								local class = "glesson-hit " .. box(region)
								if region.lowest then
									class = class .. " glowest"
								end
								if selected then
									class = class .. " gselected"
								end
								local hit = ui.el("button", {
									class = class,
									title = region.pitch .. " · string " .. tostring(region.string)
										.. " · fret " .. tostring(region.fret),
								})
								local hitProps: { [string]: any } = hit.p or {}
								hitProps.actions = {
									click = "pitch=" .. activity.id .. ":" .. tostring(itemIndex) .. ":" .. region.id,
								}
								hit.p = hitProps
								table.insert(hits, hit)
							end
							table.insert(diagramCard, ui.node("image", {
								blob = item.diagram.blob, w = item.diagram.width, h = item.diagram.height,
								alt = item.diagram.alt,
							}, hits))
						else
							table.insert(diagramCard, ui.text({ ui.span("Guitar diagram could not be rendered.", "error") }))
						end
						table.insert(diagrams, ui.el("div", { class = "glesson-diagram" }, { ui.col(diagramCard) }))
					end
					table.insert(card, ui.el("div", { class = "glesson-diagrams" }, { ui.row(diagrams) }))
				elseif activity.type == "quiz" then
					table.insert(card, ui.text({ ui.span(activity.question, "accent") }))
					local answer = state.answers[activity.id]
					for index, choice in ipairs(activity.options) do
						local tone = if answer == nil then "muted"
							elseif index == answer.selected_index then (if answer.correct then "accent" else "error")
							else "muted"
						table.insert(card, badgeButton(tostring(choice),
							"answer=" .. activity.id .. ":" .. tostring(index),
							"Select " .. tostring(choice), tone))
					end
					if answer ~= nil then
						local correctChoice = tostring(activity.correct_choice)
						local feedback = if answer.correct
							then "Correct — " .. correctChoice .. " is the lowest sounding pitch."
							else "Not quite. The lowest sounding pitch is " .. correctChoice .. "."
						table.insert(card, ui.text({ ui.span(feedback, if answer.correct then "accent" else "error") }))
					end
				end
			elseif state.lesson.schema == "gscore.lesson.v1" then
				if activity.type == "explanation" then
					table.insert(card, ui.text({ ui.span(activity.title or "Explanation", "accent") }))
					table.insert(card, ui.text({ ui.span(activity.text) }))
				elseif activity.type == "chord_diagram" then
					table.insert(card, ui.text({ ui.span(activity.symbol .. " · bass " .. tostring(activity.bass), "accent") }))
					if activity.blob == nil then
						local okBlob, blob = pcall(function()
							return cx:blob(activity.svg, activity.mime)
						end)
						if okBlob then
							activity.blob = blob
						end
					end
					if activity.blob ~= nil then
						table.insert(card, ui.node("image", {
							blob = activity.blob, w = activity.width, h = activity.height, alt = activity.alt,
						}))
					else
						table.insert(card, ui.text({ ui.span("Chord diagram could not be rendered.", "error") }))
					end
				elseif activity.type == "quiz" then
					table.insert(card, ui.text({ ui.span(activity.prompt, "accent") }))
					local answer = state.answers[activity.id]
					for index, choice in ipairs(activity.choices) do
						local tone = if answer == nil then "muted"
							elseif index == answer.selected_index then (if answer.correct then "accent" else "error")
							else "muted"
						table.insert(card, badgeButton(tostring(choice),
							"answer=" .. activity.id .. ":" .. tostring(index),
							"Select " .. tostring(choice), tone))
					end
					if answer ~= nil then
						local correctChoice = tostring(activity.choices[activity.correct_index])
						local feedback = if answer.correct
							then "Correct — " .. correctChoice .. " is the slash bass."
							else "Not quite. The slash bass is " .. correctChoice .. "."
						table.insert(card, ui.text({ ui.span(feedback, if answer.correct then "accent" else "error") }))
					end
				end
			end
			table.insert(rows, ui.el("div", { class = "gscore-lesson-activity" }, { ui.col(card) }))
		end
		return { main = ui.col(rows) }
	end,

	event = function(state: LessonState, ev: any, cx: any)
		if ev.ev ~= "action" or state.lesson == nil then
			return
		end
		if ev.act == "pitch" and state.lesson.schema == "gscore.lesson.v2" then
			local activityId, itemText, hitId = tostring(ev.value or ""):match("^([%w_%-]+):(%d+):([%w_%-]+)$")
			local itemIndex = tonumber(itemText)
			if activityId == nil or itemIndex == nil or itemIndex % 1 ~= 0 then
				return
			end
			for _, activity in ipairs(state.lesson.activities) do
				local item = if activity.type == "visual" then activity.items[itemIndex] else nil
				if activity.id == activityId and type(item) == "table" then
					for _, region in ipairs(item.diagram.hit_regions) do
						if region.id == hitId then
							state.selected_pitches[activityId] = { item_index = itemIndex, hit_id = hitId }
							cx:render()
							return
						end
					end
				end
			end
			return
		elseif ev.act ~= "answer" then
			return
		end
		local activityId, choiceText = tostring(ev.value or ""):match("^([%w_%-]+):(%d+)$")
		local selectedIndex = tonumber(choiceText)
		if activityId == nil or selectedIndex == nil then
			return
		end
		for _, activity in ipairs(state.lesson.activities) do
			local choices = if activity.type == "quiz" then lessonQuizChoices(state.lesson.schema, activity) else nil
			if activity.id == activityId and activity.type == "quiz" and type(choices) == "table"
				and selectedIndex >= 1 and selectedIndex <= #choices then
				local attemptedAt = os.time() * 1000
				local sequence = 0
				local sequenceReadOk, storedSequence = pcall(tern.kv.get, "lessonAttemptSequence")
				if sequenceReadOk then
					local nextSequence = math.max(0, math.floor(tonumber(storedSequence) or 0)) + 1
					local sequenceWriteOk, sequenceWriteResult = pcall(tern.kv.set, "lessonAttemptSequence", nextSequence)
					if sequenceWriteOk and sequenceWriteResult ~= false then
						sequence = nextSequence
					end
				end
				local correct = selectedIndex == activity.correct_index
				local answer = {
					selected_index = selectedIndex,
					selected_choice = choices[selectedIndex],
					correct = correct,
					attempted_at_ms = attemptedAt,
					sequence = sequence,
				}
				state.answers[activityId] = answer
				local paneId = tostring(cx.pane):gsub("[^%w_]", "_")
				local attemptId = string.format("%s_%d_%d", paneId, attemptedAt, math.random(1000000))
				local directory = tern.plugin.data .. "/lesson_attempts/" .. state.lesson_id
				pcall(tern.fs.mkdir, directory)
				local attempt = {
					schema = "gscore.lesson.attempt.v1",
					attempt_id = attemptId,
					lesson_id = state.lesson_id,
					revision = state.revision,
					activity_id = activityId,
					selected_index = selectedIndex,
					selected_choice = answer.selected_choice,
					correct = correct,
					attempted_at_ms = attemptedAt,
					sequence = sequence,
				}
				local file = directory .. "/attempt_" .. attemptId .. ".json"
				local okWrite, writeResult = pcall(tern.fs.write, file,
					tern.json.encode(attempt) .. LESSON_ATTEMPT_SENTINEL)
				if not okWrite or writeResult == false then
					cx:toast("error", "Answer not saved", "The feedback is visible, but Agent history could not be written.")
				end
				cx:render()
				return
			end
		end
	end,

	save = function(state: LessonState): any
		return { lesson_id = state.lesson_id, revision = state.revision, answers = state.answers }
	end,
}

tern.block.define("lesson", lesson)
