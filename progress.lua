-- Playback accounting, independent of VLC and the phone/browser.
local M = {}
local function clamp(n, a, b) return math.max(a, math.min(b, n)) end
local function rounded(n) return math.floor(n * 10 + 0.5) / 10 end

function M.merge(ranges, first, last, duration)
    first, last = clamp(first, 0, duration), clamp(last, 0, duration)
    if last <= first then return ranges end
    local all, out = {}, {}
    for _, r in ipairs(ranges or {}) do all[#all + 1] = {r[1], r[2]} end
    all[#all + 1] = {rounded(first), rounded(last)}
    table.sort(all, function(a, b) return a[1] < b[1] end)
    for _, r in ipairs(all) do
        local tail = out[#out]
        if tail and r[1] <= tail[2] + 0.25 then tail[2] = math.max(tail[2], r[2])
        else out[#out + 1] = {r[1], r[2]} end
    end
    return out
end

function M.summary(record, duration, excluded)
    record = record or {}
    duration = duration and duration > 0 and duration or record.duration or 0
    local watched = 0
    for _, r in ipairs(record.ranges or {}) do
        watched = watched + math.max(0, math.min(duration, r[2]) - math.max(0, r[1]))
    end
    local contentDuration, contentWatched = duration, watched
    -- Keep the original watched ranges. Intro/credits are exempt from completion,
    -- never recorded as watched merely because automation jumped over them.
    for _, cut in ipairs(excluded or {}) do
        local first, last = clamp(cut[1], 0, duration), clamp(cut[2], 0, duration)
        contentDuration = contentDuration - math.max(0, last - first)
        for _, range in ipairs(record.ranges or {}) do
            contentWatched = contentWatched - math.max(0, math.min(last, range[2]) - math.max(first, range[1]))
        end
    end
    contentWatched = math.max(0, contentWatched)
    local fraction = contentDuration > 0 and clamp(contentWatched / contentDuration, 0, 1) or 0
    return {watched = rounded(watched), fraction = fraction, complete = fraction >= 0.95,
        contentWatched=rounded(contentWatched), contentDuration=rounded(contentDuration), excluded=excluded or {},
        resume = clamp(record.resume or 0, 0, math.max(0, duration - 0.2)),
        ranges = record.ranges or {}, duration = duration, updatedAt = record.updatedAt or 0}
end

function M.new(data, options)
    data = data or {version = 1, episodes = {}}
    data.version, data.episodes = 1, data.episodes or {}
    setmetatable(data.episodes, {__jsontype = "object"})
    return setmetatable({data = data, previous = nil, visit = nil, dirty = false,
        qualifySeconds = (options or {}).qualifySeconds or 30}, {__index = M})
end

function M:observe(sample)
    local prev = self.previous
    if not sample or not sample.id or sample.duration <= 0 then
        self.previous, self.visit = nil, nil
        return
    end
    if not prev or prev.id ~= sample.id or prev.generation ~= sample.generation then
        self.visit = {id = sample.id, seconds = 0}
    end
    local r = self.data.episodes[sample.id]
    if not r then
        r = {ranges = {}, duration = sample.duration, resume = 0}
        self.data.episodes[sample.id] = r
    end
    r.duration = sample.duration
    if prev and prev.id == sample.id and prev.generation == sample.generation then
        local wall, delta = sample.clock - prev.clock, sample.position - prev.position
        local expected = wall * (prev.rate or 1)
        -- Discontinuities are seeks: they must never fill an unwatched gap.
        if prev.state == "playing" and wall > 0 and wall <= 3 and delta > 0 and
            math.abs(delta - expected) <= math.max(0.8, expected * 0.55) then
            r.ranges = M.merge(r.ranges, prev.position, sample.position, sample.duration)
            -- VLC reports time in uneven ticks. Capping each tick at wall time
            -- loses playback seconds; validated deltas average out correctly.
            self.visit.seconds = self.visit.seconds + delta / math.max(0.1, prev.rate or 1)
            r.updatedAt = sample.timestamp
            self.dirty = true
            -- A three-second accidental visit keeps the old bookmark and Continue card.
            if self.visit.seconds >= self.qualifySeconds then
                r.resume = rounded(sample.position)
                r.meaningfulAt = sample.timestamp
                self.data.continueId = sample.id
            end
        end
    end
    self.previous = sample
end

function M:checkpoint(timestamp)
    self.data.updatedAt = timestamp
    self.data.revision = (self.data.revision or 0) + 1
    return self.data
end
return M
