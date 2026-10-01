-- Verified timings belong to an exact local file, not just an episode number.
local M = {}
local function finite(n) return type(n) == "number" and n == n and math.abs(n) < 1e12 end
function M.validate(value, entry)
    if type(value) ~= "table" or not entry or value.verified ~= true or
        value.file ~= entry.relative or value.size ~= entry.size or value.mtime ~= entry.mtime or
        not finite(value.duration) or value.duration <= 0 or
        (entry.duration > 0 and math.abs(value.duration - entry.duration) > 2) then return nil end
    local intro, credits = value.intro, value.credits
    local excluded = {}
    if intro ~= nil then
        if type(intro) ~= "table" or not (finite(intro.start) and finite(intro.skipTo) and finite(intro.finish)) or
            not (0 <= intro.start and intro.start < intro.skipTo and intro.skipTo < intro.finish and
                 intro.finish < value.duration and intro.finish - intro.skipTo <= 5) then return nil end
        excluded[#excluded+1] = {intro.start, intro.finish}
    end
    if credits ~= nil then
        if type(credits) ~= "table" or not (finite(credits.start) and finite(credits.nextAt)) or
            not (0 <= credits.start and credits.start <= credits.nextAt and credits.nextAt < value.duration and
                 credits.nextAt - credits.start <= 5) then return nil end
        if intro and intro.finish >= credits.start then return nil end
        excluded[#excluded+1] = {credits.start, value.duration}
    end
    return {intro=intro, credits=credits, excluded=excluded}
end
function M.load(settings, catalog, library, json)
    local out, docs = {}, {}
    for _, series in ipairs(catalog.series or {}) do
        local doc = library.read(series.root .. "/markers.json", json)
        if doc and doc.version == 1 and type(doc.episodes) == "table" then docs[series.id] = doc.episodes end
    end
    for _, entry in ipairs(catalog.episodes) do
        local doc = docs[entry.seriesId]
        if doc then out[entry.id] = M.validate(doc[entry.key], entry) end
    end
    return out
end

function M.preferences(root, library, json)
    local saved = library.read(root .. "/playback.json", json) or {}
    return {skipIntro=saved.skipIntro ~= false, nextEpisode=saved.nextEpisode ~= false}
end
function M.new_player()
    local player = {}
    function player:plan(sample, marker, prefs, nextId)
        if not sample then self.id, self.generation = nil, nil; return nil end
        if self.id ~= sample.id or self.generation ~= sample.generation then
            self.id, self.generation, self.introDone, self.nextDone = sample.id, sample.generation, false, false
        end
        if sample.state ~= "playing" or not marker then return nil end
        local intro = marker.intro
        if intro and prefs.skipIntro and not self.introDone and sample.position >= intro.start and sample.position < intro.skipTo then
            return {kind="intro", position=intro.skipTo}
        end
        if marker.credits and prefs.nextEpisode and nextId and not self.nextDone and sample.position >= marker.credits.nextAt then
            return {kind="next", id=nextId}
        end
    end
    function player:applied(action)
        if action.kind == "intro" then self.introDone = true else self.nextDone = true end
    end
    return player
end
return M
