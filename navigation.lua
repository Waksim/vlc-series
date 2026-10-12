-- Keep VLC's own Next/Previous controls in the same episode order as the remote.
-- Only the tracker reconciles the queue; the playing input is never replaced.
local M = {}

function M.new(library, Progress)
    local function item(entry, history, timings, fromStart, previous)
        local marker = timings[entry.id]
        local progress = Progress.summary(history.episodes[entry.id], entry.duration, marker and marker.excluded)
        local start = not fromStart and (previous or not progress.complete) and progress.resume or 0
        return {path=vlc.strings.make_uri(entry.path), name=entry.filename, duration=entry.duration,
            options={"start-time=" .. tostring(start)},
            meta={["sofa-start-time"]=tostring(start), ["sofa-resume-mode"]=previous and "previous" or "default"}}
    end

    local function sync(catalog, current, history, timings)
        local generation = vlc.playlist.current()
        local queue, playing = vlc.playlist.get("playlist"), vlc.playlist.get(generation)
        local uri = vlc.strings.make_uri(current.path)
        if not queue or not playing or playing.path ~= uri then return false end
        local function unchanged()
            local input = vlc.input.item()
            return vlc.playlist.current() == generation and input and input:uri() == uri
        end
        if not unchanged() then return false end

        local desired, wanted, before = {}, {}, true
        for _, entry in ipairs(catalog.episodes) do
            if entry.seriesId == current.seriesId and library.unchanged(entry) then
                if entry.id == current.id then before = false end
                local value = item(entry, history, timings, false, before)
                desired[#desired+1], wanted[value.path] = value, value
            end
        end
        if not wanted[uri] then return false end

        -- Moving to the root also safely detaches an input opened from a folder node.
        -- Never clear the queue: VLC's clear() stops the current input.
        if vlc.playlist.move(generation, queue.id) ~= 0 then return false end
        queue = vlc.playlist.get("playlist")
        local keep = {[generation]=true}
        local ids = {[uri]=generation}
        for _, node in ipairs(queue.children or {}) do
            local value = wanted[node.path]
            if not node.children and value and not ids[node.path] and node.item then
                local meta = node.item:metas()
                if meta["sofa-start-time"] == value.meta["sofa-start-time"] and
                    meta["sofa-resume-mode"] == value.meta["sofa-resume-mode"] then
                    ids[node.path], keep[node.id] = node.id, true
                end
            end
        end
        for _, node in ipairs(queue.children or {}) do
            if not keep[node.id] then
                if not unchanged() then return false end
                vlc.playlist.delete(node.id)
            end
        end
        local missing = {}
        for _, value in ipairs(desired) do
            if not ids[value.path] then missing[#missing+1] = value end
        end
        if #missing > 0 then
            if not unchanged() then return false end
            vlc.playlist.enqueue(missing)
        end
        queue = vlc.playlist.get("playlist")
        for _, node in ipairs(queue.children or {}) do ids[node.path] = node.id end
        -- VLC 3's move-after-item uses ID arithmetic. Moving to the root in reverse
        -- order works with non-contiguous IDs and keeps native navigation reliable.
        for i=#desired,1,-1 do
            if not unchanged() or not ids[desired[i].path] then return false end
            if vlc.playlist.move(ids[desired[i].path], queue.id) ~= 0 then return false end
        end
        -- VLC 3 accepts "on"/"off" here, rather than Lua booleans.
        vlc.playlist.random("off")
        vlc.playlist.loop("off")
        vlc.playlist.repeat_("off")
        return unchanged()
    end

    return {item=item, sync=sync}
end

return M
