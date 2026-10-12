-- Catalogs are independent; a series ID keeps identical episode numbers apart.
local M = {}
local extensions = {mkv=true, mp4=true, avi=true, mov=true, m4v=true, webm=true, ts=true}
function M.read(path, json)
    local f = io.open(path, "r")
    if not f then return nil end
    local raw = f:read("*a"); f:close()
    local data = json.decode(raw)
    if type(data) == "table" then return data end
end
function M.history(root, json)
    local primary = M.read(root .. "/progress.json", json)
    if primary and primary.version == 1 and type(primary.episodes) == "table" then return primary end
    local backup = M.read(root .. "/progress.json.bak", json)
    if backup and backup.version == 1 and type(backup.episodes) == "table" then return backup end
    if vlc.net.stat(root .. "/progress.json") or vlc.net.stat(root .. "/progress.json.bak") then
        error("Saved progress is unreadable; refusing to replace it")
    end
    return {version=1, episodes={}}
end
function M.registry(root, settings, json)
    local f = io.open(root .. "/libraries.json", "r")
    if not f then return settings, "legacy" end
    local raw = f:read("*a"); f:close()
    local doc = json.decode(raw)
    assert(type(doc) == "table" and doc.version == 1 and type(doc.libraries) == "table", "Invalid libraries.json")
    local ids, paths = {}, {}
    for _, series in ipairs(doc.libraries) do
        assert(type(series.id) == "string" and series.id:match("^[a-z0-9][a-z0-9_-]*$") and
            #series.id <= 64 and not ids[series.id] and type(series.root) == "string" and
            series.root:sub(1,1) == "/" and not paths[series.root] and type(series.title) == "string",
            "Invalid or duplicate series")
        assert(not series.legacy or series.id == "legacy", "Only migrated legacy series may use old progress keys")
        ids[series.id], paths[series.root] = true, true
    end
    return {libraries=doc.libraries}, raw
end
function M.season(name)
    return tonumber(name:lower():match("season[ ._-]*(%d+)") or name:lower():match("^s(%d+)$") or
        name:match("Сезон[ ._-]*(%d+)") or name:match("сезон[ ._-]*(%d+)") or name:match("СЕЗОН[ ._-]*(%d+)"))
end
function M.parse(name, folderSeason)
    local lower = name:lower()
    local season, episode = lower:match("s(%d+)[ ._-]*e(%d+)")
    if not season then season, episode = lower:match("(%d+)x(%d+)") end
    if not season and folderSeason then
        episode = lower:match("episode[ ._-]*(%d+)") or lower:match("^e[ ._-]*(%d+)") or
            name:match("Серия[ ._-]*(%d+)") or name:match("серия[ ._-]*(%d+)") or
            name:match("СЕРИЯ[ ._-]*(%d+)") or name:match("^(%d+)[ ._-]") or name:match("^(%d+)%.")
        season = folderSeason
    end
    season, episode = tonumber(season), tonumber(episode)
    if season and episode and season >= 0 and season <= 999 and episode >= 1 and episode <= 999 then
        return season, episode
    end
end
function M.scan(settings, cache)
    local lib = {title="Медиатека", episodes={}, byId={}, byPath={}, seasons={}, series={}, seriesById={}, issues={}}
    local sources = settings.libraries or {}
    if not settings.libraries and settings.libraryRoot and settings.libraryRoot ~= "" then
        sources = {{id="legacy", title=settings.libraryTitle or "Мой сериал", root=settings.libraryRoot, legacy=true}}
    end
    for _, source in ipairs(sources) do
        local series = {id=source.id, title=source.title, root=source.root, legacy=source.legacy, seasons={}, count=0}
        lib.series[#lib.series+1], lib.seriesById[series.id] = series, series
        local lengths = ((cache or {}).libraries or {})[series.id] or (series.legacy and cache) or {}
        local fingerprints, durations = lengths.fingerprints or {}, lengths.durations or {}
        local candidates, duplicates = {}, {}
        local function walk(dir, depth, folderSeason)
            local ok, names = pcall(vlc.io.readdir, dir)
            if not ok or type(names) ~= "table" then return end
            table.sort(names)
            for _, name in ipairs(names) do
                if name:sub(1,1) ~= "." then
                    local path = dir .. "/" .. name
                    local info = vlc.net.stat(path)
                    if info and info.type == "dir" and depth < 3 then
                        walk(path, depth + 1, M.season(name) or folderSeason)
                    elseif info and info.type == "file" and extensions[(name:match("%.([^%.]+)$") or ""):lower()] then
                        local season, episode = M.parse(name, folderSeason)
                        if season then
                            local key = string.format("s%02de%02d", season, episode)
                            local id = series.legacy and key or series.id .. ":" .. key
                            local relative = path:sub(#series.root + 2)
                            local fp = fingerprints[relative]
                            local duration = (not fp or (fp.size == info.size and fp.mtime == info.modification_time)) and durations[relative] or 0
                            local entry = {id=id, key=key, seriesId=series.id, seriesTitle=series.title,
                                season=season, episode=episode, path=path, filename=name, relative=relative,
                                size=info.size, mtime=info.modification_time, duration=duration or 0}
                            if candidates[id] then duplicates[id] = true end
                            candidates[id] = entry
                        else lib.issues[#lib.issues+1] = {seriesId=series.id, file=name, error="unrecognized_episode"} end
                    end
                end
            end
        end
        walk(series.root, 0, M.season(series.root:match("([^/]+)$") or ""))
        for id, entry in pairs(candidates) do
            if duplicates[id] then lib.issues[#lib.issues+1] = {seriesId=series.id, episode=entry.key, error="duplicate_episode"}
            else
                lib.episodes[#lib.episodes+1] = entry
                lib.byId[id], lib.byPath[entry.path], lib.seasons[entry.season], series.seasons[entry.season] = entry, entry, true, true
                series.count = series.count + 1
            end
        end
    end
    table.sort(lib.episodes, function(a,b)
        if a.seriesId ~= b.seriesId then return a.seriesId < b.seriesId end
        return a.season == b.season and a.episode < b.episode or a.season < b.season
    end)
    return lib
end
function M.current(lib)
    local item = vlc.input.item()
    if not item then return nil end
    local ok, path = pcall(vlc.strings.make_path, item:uri())
    return ok and lib.byPath[path] or nil
end
local function adjacent(lib, id, offset)
    for i, entry in ipairs(lib.episodes) do
        if entry.id == id then
            local nextEntry = lib.episodes[i+offset]
            return nextEntry and nextEntry.seriesId == entry.seriesId and nextEntry or nil
        end
    end
end
function M.next(lib, id) return adjacent(lib, id, 1) end
function M.previous(lib, id) return adjacent(lib, id, -1) end
function M.unchanged(entry)
    local stat = entry and vlc.net.stat(entry.path)
    return stat and stat.type == "file" and stat.size == entry.size and stat.modification_time == entry.mtime
end
return M
