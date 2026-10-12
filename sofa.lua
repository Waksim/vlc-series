-- Sofa Remote: a local, authenticated remote running inside VLC's Lua interface.
-- No arbitrary commands, directory browsing, or arbitrary media URLs.
local json = require "dkjson"
local root = assert(config.root, "Sofa Remote root is missing")
local library = dofile(root .. "/library.lua")
local Progress = dofile(root .. "/progress.lua")
local Markers = dofile(root .. "/markers.lua")
local navigation = dofile(root .. "/navigation.lua").new(library, Progress)
local settings = assert(library.read(root .. "/settings.json", json))
local catalog, scanned, timings, markerScan, registryKey = nil, 0, {}, 0, nil
local function refreshcatalog()
    local catalogSettings, key = library.registry(root, settings, json)
    if not catalog or registryKey ~= key or os.time() - scanned >= 30 then
        catalog = library.scan(catalogSettings, library.read(root .. "/library-cache.json", json))
        registryKey = key
        scanned = os.time()
        markerScan = 0
    end
    if os.time() - markerScan >= 2 then
        timings = Markers.load(settings, catalog, library, json); markerScan = os.time()
    end
    return catalog
end
local port = tonumber(config.port) or settings.port or 8080
local storepath = config.sessions or (root .. "/sessions.json")
local sessions = {}
local sessionfile = io.open(storepath, "r")
if sessionfile then
    sessions = json.decode(sessionfile:read("*a")) or {}
    sessionfile:close()
end
-- An empty JSON array must never keep array metadata after adding token keys.
setmetatable(sessions, {__jsontype = "object"})
local function readfile(path)
    local f = assert(io.open(path, "rb"))
    local data = f:read("*a"); f:close(); return data
end
local assets = {
    ["/"] = {"text/html; charset=utf-8", "index.html"},
    ["/app.js"] = {"text/javascript; charset=utf-8", "app.js"},
    ["/style.css"] = {"text/css; charset=utf-8", "style.css"},
    ["/icon.svg"] = {"image/svg+xml", "icon.svg"},
    ["/manifest.webmanifest"] = {"application/manifest+json", "manifest.webmanifest"},
}
local arraymeta = {__jsontype = "array"}
local function array() return setmetatable({}, arraymeta) end
local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end
local function number(x) return type(x) == "number" and x == x and math.abs(x) < 1e12 end
local function getvar(obj, key, fallback)
    if not obj then return fallback end
    local ok, v = pcall(vlc.var.get, obj, key)
    if ok and v ~= nil then return v end
    return fallback
end
local Audio = dofile(root .. "/audio.lua")
local systemAudio = Audio.new(root, json, function()
    return getvar(vlc.object.aout(), "device", nil)
end)
local function tracks(input, key)
    local result = array()
    if not input then return result end
    local ok, ids, labels = pcall(vlc.var.get_list, input, key)
    if ok and type(ids) == "table" then
        for i, id in ipairs(ids) do
            result[#result + 1] = {id = id, name = (labels or {})[i] or tostring(id)}
        end
    end
    return result
end
local function libraryview(seriesId)
    local lib, history = refreshcatalog(), library.history(root, json)
    local current = library.current(lib)
    local selected = lib.seriesById[seriesId] or (current and lib.seriesById[current.seriesId]) or lib.series[1]
    local episodes, seasons, series = array(), array(), array()
    for _, show in ipairs(lib.series) do series[#series+1] = {id=show.id, title=show.title, count=show.count} end
    for season in pairs(selected and selected.seasons or {}) do seasons[#seasons+1] = season end
    table.sort(seasons)
    local continueId, latest = nil, -1
    for _, e in ipairs(lib.episodes) do
        if selected and e.seriesId == selected.id then
            local marker, record = timings[e.id], history.episodes[e.id]
            local progress = Progress.summary(record, e.duration, marker and marker.excluded)
            setmetatable(progress.ranges, arraymeta); setmetatable(progress.excluded, arraymeta)
            episodes[#episodes+1] = {id=e.id, key=e.key, seriesId=e.seriesId, season=e.season, episode=e.episode, progress=progress}
            local at = record and (record.meaningfulAt or ((record.resume or 0) > 0 and record.updatedAt)) or nil
            if at and at > latest then continueId, latest = e.id, at end
        end
    end
    local saved = lib.byId[history.continueId]
    if saved and selected and saved.seriesId == selected.id then continueId = saved.id end
    return {title=selected and selected.title or "Медиатека", series=series,
        seriesId=selected and selected.id, episodes=episodes, seasons=seasons,
        currentId=current and current.id, continueId=continueId, revision=history.revision or 0}
end

local function status()
    local input, item = vlc.object.input(), vlc.input.item()
    local vol = vlc.volume.get()
    local length = item and math.max(0, item:duration()) or 0
    local aout = vlc.object.aout()
    local current = library.current(refreshcatalog())
    return {
        state = vlc.playlist.status(), title = item and item:name() or "",
        time = getvar(input, "time", 0) / 1000000, length = length,
        volume = math.floor(math.max(0, vol) / 2.56 + 0.5),
        volumeMax = 200,
        systemAudio = systemAudio.status(),
        muted = getvar(aout, "mute", false) or vol == 0,
        fullscreen = getvar(vlc.object.vout(), "fullscreen", false),
        audio = tracks(input, "audio-es"), subtitles = tracks(input, "spu-es"),
        audioId = getvar(input, "audio-es", -1), subtitleId = getvar(input, "spu-es", -1),
        hasMedia = input ~= nil,
        episodeId = current and current.id, seriesId = current and current.seriesId,
        libraryTitle = current and current.seriesTitle or catalog.title, version = "1.0.1", apiVersion = 2,
        playback = Markers.preferences(root, library, json),
        marked = current ~= nil and timings[current.id] ~= nil,
    }
end
local function savesessions()
    local now, count = os.time(), 0
    for token, untiltime in pairs(sessions) do
        if type(untiltime) ~= "number" or untiltime < now then sessions[token] = nil
        else count = count + 1 end
    end
    if count > 24 then
        local oldest, expiry
        for token, untiltime in pairs(sessions) do
            if not expiry or untiltime < expiry then oldest, expiry = token, untiltime end
        end
        sessions[oldest] = nil
    end
    local f = assert(io.open(storepath .. ".tmp", "w"))
    f:write(json.encode(sessions)); f:close()
    assert(os.rename(storepath .. ".tmp", storepath))
end
local function randomtoken()
    local f = assert(io.open("/dev/urandom", "rb"))
    local bytes = assert(f:read(32)); f:close()
    return (bytes:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end
local attempts, blockedUntil, rememberedVolume = 0, 0, 256
local function togglemute()
    -- Dispatch VLC's own mute action, which preserves its level and reports real state.
    local id = vlc.misc.action_id("key-vol-mute")
    if not id then return false end
    vlc.var.set(vlc.object.libvlc(), "key-action", id)
    return true
end
local recentCommands, recentCount = {}, 0
local function playepisode(id, fromStart, previous)
    local entry = refreshcatalog().byId[id]
    if not entry or not library.unchanged(entry) then return false, "episode_missing" end
    -- Per-item start time cannot leak into another episode, unlike a global VLC flag.
    vlc.playlist.add({navigation.item(entry, library.history(root, json), timings, fromStart, previous)})
    return true
end
local function command(p)
    local input = vlc.object.input()
    if p.action == "playback_preferences" then
        if (p.key ~= "skipIntro" and p.key ~= "nextEpisode") or type(p.value) ~= "boolean" then
            return false, "bad_value"
        end
        local prefs = Markers.preferences(root, library, json)
        prefs[p.key] = p.value
        local f = assert(io.open(root .. "/playback.json.tmp", "w"))
        assert(f:write(json.encode(prefs))); assert(f:flush()); f:close()
        assert(os.rename(root .. "/playback.json.tmp", root .. "/playback.json"))
    elseif p.action == "toggle" then
        if vlc.playlist.status() == "stopped" then vlc.playlist.play() else vlc.playlist.pause() end
    elseif p.action == "scrub" then
        -- Older phone tabs must not turn a scroll/tap into an absolute seek either.
        return false, "timeline_read_only"
    elseif p.action == "seek" then
        if not input then return false, "no_media" end
        local item = vlc.input.item()
        local length = math.max(0, item:duration())
        if p.delta ~= 5 and p.delta ~= -5 then return false, "bad_value" end
        local target = getvar(input, "time", 0) / 1000000 + p.delta
        vlc.var.set(input, "time", math.floor(clamp(target, 0, math.max(0, length - 0.2)) * 1000000))
    elseif p.action == "volume" or p.action == "volume_step" then
        local value = p.value
        if p.action == "volume_step" then
            if p.delta ~= 5 and p.delta ~= -5 then return false, "bad_value" end
            value = vlc.volume.get() / 2.56 + p.delta
        end
        if not number(value) then return false, "bad_value" end
        local aout = vlc.object.aout()
        if aout and getvar(aout, "mute", false) then togglemute() end
        local ok = vlc.volume.set(math.floor(clamp(value, 0, 200) * 2.56 + 0.5))
        if not ok then return false, "volume_failed" end
    elseif p.action == "system_volume" or p.action == "system_mute" then
        return systemAudio.set(p.action == "system_volume" and "volume" or "mute", p.deviceId, p.value)
    elseif p.action == "system_volume_step" then
        return systemAudio.step(p.deviceId, p.delta)
    elseif p.action == "mute" then
        local aout = vlc.object.aout()
        if aout and getvar(aout, "mute", false) then
            togglemute()
        elseif vlc.volume.get() == 0 then vlc.volume.set(rememberedVolume)
        else rememberedVolume = vlc.volume.get(); togglemute() end
    elseif p.action == "fullscreen" then
        local vout = vlc.object.vout()
        if vout then vlc.var.set(vout, "fullscreen", not getvar(vout, "fullscreen", false)) end
    elseif p.action == "play_episode" then
        if type(p.id) ~= "string" or (p.fromStart ~= nil and type(p.fromStart) ~= "boolean") then
            return false, "bad_value"
        end
        local current = library.current(refreshcatalog())
        if current and current.id == p.id and not p.fromStart then
            if vlc.playlist.status() == "paused" then vlc.playlist.pause() end
        else return playepisode(p.id, p.fromStart) end
    elseif p.action == "next" then
        local lib = refreshcatalog()
        local current = library.current(lib)
        if current then
            local nextEntry = library.next(lib, current.id)
            if nextEntry then return playepisode(nextEntry.id, false) end
            return false, "last_episode"
        else vlc.playlist.next() end
    elseif p.action == "previous" then
        local lib = refreshcatalog()
        local current = library.current(lib)
        if current then
            local previousEntry = library.previous(lib, current.id)
            if previousEntry then return playepisode(previousEntry.id, false, true) end
            return false, "first_episode"
        else vlc.playlist.prev() end
    elseif p.action == "audio" or p.action == "subtitle" then
        if not input or not number(p.value) then return false, "bad_value" end
        local key = p.action == "audio" and "audio-es" or "spu-es"
        local valid = false
        for _, entry in ipairs(tracks(input, key)) do if entry.id == p.value then valid = true end end
        if not valid then return false, "bad_value" end
        vlc.var.set(input, key, p.value)
    else return false, "unknown_action" end
    return true
end
local function api(p)
    if type(p) ~= "table" then return 400, {error = "bad_json"} end
    if p.action == "login" then
        if os.time() < blockedUntil then return 429, {error = "wait", seconds = blockedUntil - os.time()} end
        if type(p.pattern) ~= "string" or p.pattern ~= settings.pattern then
            attempts = attempts + 1
            if attempts >= 5 then blockedUntil = os.time() + 30; attempts = 0 end
            return 403, {error = "wrong_pattern"}
        end
        attempts = 0
        local token = randomtoken()
        sessions[token] = os.time() + 60 * 60 * 24 * 30
        savesessions()
        return 200, {token = token, status = status()}
    end
    if type(p.token) ~= "string" or not sessions[p.token] or sessions[p.token] < os.time() then
        return 401, {error = "locked"}
    end
    if p.action == "logout" then
        sessions[p.token] = nil; savesessions(); return 200, {ok = true}
    end
    if p.action == "library" then return 200, libraryview(type(p.seriesId) == "string" and p.seriesId or nil) end
    if p.action ~= "status" then
        -- A duplicated request must not perform a second skip or toggle.
        if type(p.requestId) ~= "string" or #p.requestId > 100 then return 400, {error = "missing_id"} end
        local id = p.token .. ":" .. p.requestId
        if not recentCommands[id] then
            local ok, err = command(p)
            if not ok then return 400, {error = err} end
            if recentCount >= 256 then recentCommands = {}; recentCount = 0 end
            recentCommands[id] = true; recentCount = recentCount + 1
        end
    end
    return 200, status()
end
local reasons = {[200]="OK", [400]="Bad Request", [401]="Unauthorized", [403]="Forbidden", [404]="Not Found", [405]="Method Not Allowed", [413]="Payload Too Large", [429]="Too Many Requests", [500]="Internal Server Error"}
local function response(code, mime, body)
    return "HTTP/1.1 " .. code .. " " .. reasons[code] .. "\r\nContent-Type: " .. mime ..
        "\r\nContent-Length: " .. #body .. "\r\nConnection: close\r\nCache-Control: no-store\r\n" ..
        "X-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\n" ..
        "Content-Security-Policy: default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'\r\n\r\n" .. body
end
local function jsonresponse(code, body) return response(code, "application/json; charset=utf-8", json.encode(body)) end
local function allowedhost(host)
    local h = host:lower():gsub(":%d+$", "")
    return h == "localhost" or h == "127.0.0.1" or h == "[::1]" or h == settings.hostname:lower() or
        h:match("^192%.168%.%d+%.%d+$") or h:match("^10%.%d+%.%d+%.%d+$") or
        h:match("^172%.1[6-9]%.%d+%.%d+$") or h:match("^172%.2%d%.%d+%.%d+$") or h:match("^172%.3[01]%.%d+%.%d+$")
end
local function route(method, path, headers, body)
    local host = headers.host or ""
    if not allowedhost(host) then return jsonresponse(403, {error = "host"}) end
    if headers.origin and headers.origin ~= "http://" .. host then return jsonresponse(403, {error = "origin"}) end
    if path == "/health" and method == "GET" then
        return jsonresponse(200, {service="sofa-remote", version="1.0.1", apiVersion=2})
    end
    if path == "/api" then
        if method ~= "POST" then return jsonresponse(405, {error = "post_required"}) end
        if not (headers["content-type"] or ""):match("^application/json") then return jsonresponse(400, {error = "json_required"}) end
        local p, _, err = json.decode(body)
        if err then return jsonresponse(400, {error = "bad_json"}) end
        local ok, code, data = pcall(api, p)
        if not ok then vlc.msg.err("Sofa Remote request failed: " .. tostring(code)); return jsonresponse(500, {error = "player_error"}) end
        return jsonresponse(code, data)
    end
    if method ~= "GET" then return jsonresponse(405, {error = "get_required"}) end
    local asset = assets[path]
    if asset then return response(200, asset[1], readfile(root .. "/web/" .. asset[2])) end
    return jsonresponse(404, {error = "not_found"})
end
local clients = {}
local listener = vlc.net.listen_tcp(config.host or "0.0.0.0", port)
local listens = {listener:fds()}
local function close(fd) pcall(vlc.net.close, fd); clients[fd] = nil end
local function consume(c)
    local finish = c.data:find("\r\n\r\n", 1, true)
    if not finish then
        if #c.data > 8192 then c.out = jsonresponse(413, {error = "headers_too_large"}) end
        return
    end
    local head = c.data:sub(1, finish - 1)
    local method, path = head:match("^(%u+) ([^ ]+) HTTP/1%.[01]\r?\n")
    if not method then c.out = jsonresponse(400, {error = "request"}); return end
    local headers = {}
    for key, value in head:gmatch("\r\n([^: \r\n]+):[ \t]*([^\r\n]*)") do
        key = key:lower()
        if headers[key] then c.out = jsonresponse(400, {error = "duplicate_header"}); return end
        headers[key] = value:gsub("%s+$", "")
    end
    local length = tonumber(headers["content-length"] or "0")
    if not length or length < 0 or length > 2048 or length % 1 ~= 0 or headers["transfer-encoding"] then
        c.out = jsonresponse(400, {error = "body_length"}); return
    end
    if #c.data < finish + 3 + length then return end
    c.out = route(method, path, headers, c.data:sub(finish + 4, finish + 3 + length))
    c.data = ""
end
vlc.msg.info("Sofa Remote listening on port " .. port)
local ok, err = pcall(function()
    while true do
        local fds = {}
        for _, fd in ipairs(listens) do fds[fd] = vlc.net.POLLIN end
        for fd, c in pairs(clients) do fds[fd] = c.out and vlc.net.POLLOUT or vlc.net.POLLIN end
        vlc.net.poll(fds)
        for _, fd in ipairs(listens) do
            if fds[fd] and fds[fd] ~= 0 then
                local peer = listener:accept()
                if peer >= 0 then
                    local count, oldest, oldestTime = 0, nil, math.huge
                    for existing, c in pairs(clients) do
                        if os.time() - c.created > 10 then close(existing)
                        else
                            count = count + 1
                            if c.created < oldestTime then oldest, oldestTime = existing, c.created end
                        end
                    end
                    if count >= 16 and oldest then close(oldest) end
                    clients[peer] = {data = "", created = os.time(), sent = 0}
                end
            end
        end
        for fd, c in pairs(clients) do
            local events = fds[fd] or 0
            if events ~= 0 then
                if c.out and events % (2 * vlc.net.POLLOUT) >= vlc.net.POLLOUT then
                    local sent = vlc.net.send(fd, c.out:sub(c.sent + 1, c.sent + 16384))
                    if not sent or sent <= 0 then close(fd)
                    else c.sent = c.sent + sent; if c.sent >= #c.out then close(fd) end end
                elseif not c.out and events % (2 * vlc.net.POLLIN) >= vlc.net.POLLIN then
                    local chunk = vlc.net.recv(fd, 4096)
                    if not chunk then close(fd)
                    else c.data = c.data .. chunk; consume(c) end
                else close(fd) end
            end
        end
    end
end)
for fd in pairs(clients) do close(fd) end
if not ok and not tostring(err):match("Interrupted") then vlc.msg.err("Sofa Remote stopped: " .. tostring(err)) end
