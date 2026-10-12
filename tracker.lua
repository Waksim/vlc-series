-- Runs in a second VLC Lua interface, so tracking continues with no HTTP clients.
local json = require "dkjson"
local root = assert(config.root)
local library = dofile(root .. "/library.lua")
local Progress = dofile(root .. "/progress.lua")
local Markers = dofile(root .. "/markers.lua")
local navigation = dofile(root .. "/navigation.lua").new(library, Progress)
local settings = assert(library.read(root .. "/settings.json", json))
local catalogSettings, registryKey = library.registry(root, settings, json)
local catalog = library.scan(catalogSettings, library.read(root .. "/library-cache.json", json))
local engine = Progress.new(library.history(root, json))
local player = Markers.new_player()
local timings, preferences = {}, {}
local lastSave, lastScan, lastSettings = 0, 0, 0
local startGeneration, awaitingStart, startDeadline
local queueGeneration, queueCatalog
local function atomic(path, raw)
    local f = assert(io.open(path .. ".tmp", "w"))
    assert(f:write(raw)); assert(f:flush()); f:close()
    assert(os.rename(path .. ".tmp", path))
end
local function save()
    if not engine.dirty then return end
    local old = library.read(root .. "/progress.json", json)
    if old and old.version == 1 and old.episodes then atomic(root .. "/progress.json.bak", json.encode(old)) end
    local data = engine:checkpoint(os.time())
    atomic(root .. "/progress.json", json.encode(data))
    engine.dirty = false
    lastSave = vlc.misc.mdate() / 1000000
end
local function sample()
    local clock = vlc.misc.mdate() / 1000000
    if clock - lastSettings > 1 then
        local updated, key = library.registry(root, settings, json)
        if key ~= registryKey or clock - lastScan > 30 then
            catalog = library.scan(updated, library.read(root .. "/library-cache.json", json))
            registryKey, lastScan = key, clock
        end
        timings = Markers.load(settings, catalog, library, json)
        preferences = Markers.preferences(root, library, json)
        lastSettings = clock
    end
    local input, item = vlc.object.input(), vlc.input.item()
    local entry = library.current(catalog)
    if not input or not item or not entry then
        engine:observe(nil); player:plan(nil); startGeneration = nil; save(); return
    end
    local s = {id=entry.id, generation=vlc.playlist.current(), state=vlc.playlist.status(),
        position=vlc.var.get(input,"time")/1000000, duration=math.max(0,item:duration()),
        rate=vlc.var.get(input,"rate"), clock=clock, timestamp=os.time()}
    local previous = engine.previous
    engine:observe(s)
    if s.state ~= "playing" or not previous or previous.id ~= s.id or clock - lastSave >= 2 then save() end
    if queueGeneration ~= s.generation or queueCatalog ~= catalog then
        if navigation.sync(catalog, entry, engine.data, timings) then
            queueGeneration, queueCatalog = s.generation, catalog
        end
    end
    if vlc.playlist.current() ~= s.generation then return end
    -- VLC briefly reports time=0 before applying an item's saved start-time.
    -- An opening at zero must not overwrite that pending resume seek.
    if startGeneration ~= s.generation then
        startGeneration = s.generation
        local ok, requested = pcall(vlc.var.get, input, "start-time")
        awaitingStart = ok and type(requested) == "number" and requested > 0 and requested or nil
        startDeadline = clock + 5
        local marker = timings[entry.id]
        local meta = item:metas()
        if meta["sofa-resume-mode"] == "previous" and marker and marker.credits and
            awaitingStart and awaitingStart >= marker.credits.nextAt then
            -- Back to the saved credits must not immediately bounce forward again.
            player:plan({id=s.id, generation=s.generation, state="paused"}, nil, preferences)
            player:applied({kind="next"})
        end
    end
    if awaitingStart then
        if s.position >= awaitingStart - 0.5 or clock >= startDeadline then awaitingStart = nil
        else return end
    end
    local marker = timings[entry.id]
    -- A replaced file must not inherit timings while waiting for the next scan.
    if marker and (not library.unchanged(entry) or math.abs(s.duration - entry.duration) > 2) then marker = nil end
    local nextEntry = library.next(catalog, entry.id)
    local action = player:plan(s, marker, preferences, nextEntry and nextEntry.id)
    if not action then return end
    -- HTTP controls may have changed the input since this sample was taken.
    if vlc.playlist.current() ~= s.generation or vlc.playlist.status() ~= "playing" then return end
    if action.kind == "intro" then
        vlc.var.set(input, "time", math.floor(action.position * 1000000))
        -- Do not count a short automatic seek as genuine playback.
        player:applied(action)
        -- Preserve the qualification counter across this intentional discontinuity.
        engine.previous = {id=s.id, generation=s.generation, state="paused", position=action.position,
            duration=s.duration, rate=s.rate, clock=s.clock, timestamp=s.timestamp}
    elseif nextEntry and library.unchanged(nextEntry) then
        save()
        vlc.playlist.add({navigation.item(nextEntry, engine.data, timings, false, false)})
        player:applied(action)
    end
end
vlc.msg.info("Sofa Remote progress tracking and verified skips started")
local ok, err = pcall(function()
    while true do
        local good, why = pcall(sample)
        if not good then vlc.msg.warn("Sofa progress sample: " .. tostring(why)) end
        vlc.misc.mwait(vlc.misc.mdate() + 500000)
    end
end)
local saved, why = pcall(save)
if not saved then vlc.msg.err("Sofa progress could not be saved: " .. tostring(why)) end
if not ok and not tostring(err):match("Interrupted") then vlc.msg.dbg("Sofa tracker stopped: " .. tostring(err)) end
