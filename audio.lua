-- Only a fixed local helper and validated integer arguments may be executed.
local M = {}
local function integer(n, max)
    return type(n) == "number" and n == n and n >= 0 and n <= max and n % 1 == 0
end
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
function M.new(root, json, device)
    local helper = quote(root .. "/sofa-audio")
    local cached, updated, cachedRoute
    local function route()
        local raw = device()
        if raw == nil or raw == "" then return 0 end
        local id = tonumber(raw)
        if not integer(id, 4294967295) then return nil end
        -- auhal marks digital passthrough with bits 20..23. Do not expose a false mixer.
        if math.floor(id / 1048576) % 16 ~= 0 then return nil end
        return id
    end
    local function invoke(command, id, expected, value)
        local line = helper .. " " .. command .. " " .. string.format("%.0f", id)
        if expected then line = line .. " " .. string.format("%.0f %.0f", expected, value) end
        local ok, result = pcall(function()
            local pipe = io.popen(line .. " 2>/dev/null", "r")
            if not pipe then return nil end
            local text = pipe:read("*a"); pipe:close()
            return json.decode(text, 1, json.null)
        end)
        return ok and type(result) == "table" and result or
            {available=false, controllable=false, error="helper_unavailable"}
    end
    local self = {}
    function self.status(force)
        local id = route()
        if not id then return {available=false, controllable=false, error="unsupported_output"} end
        if force or not cached or cachedRoute ~= id or os.time() - updated >= 2 then
            cached, updated, cachedRoute = invoke("status", id), os.time(), id
        end
        return cached
    end
    function self.set(command, expected, value)
        if (command ~= "volume" and command ~= "mute") or not integer(expected, 4294967295) or
           not integer(value, command == "volume" and 100 or 1) then return false, "bad_value" end
        local id = route()
        if not id then return false, "system_volume_unavailable" end
        local before = self.status(true)
        if before.deviceId ~= expected then return false, "device_changed" end
        if before[command == "volume" and "controllable" or "muteControllable"] ~= true then
            return false, "system_volume_unavailable"
        end
        local result = invoke(command, id, expected, value)
        cached, updated, cachedRoute = nil, 0, nil
        if result.error then return false, result.error end
        return true
    end
    function self.step(expected, delta)
        if delta ~= -5 and delta ~= 5 then return false, "bad_value" end
        local before = self.status(true)
        if before.deviceId ~= expected then return false, "device_changed" end
        if before.controllable ~= true or type(before.volume) ~= "number" then
            return false, "system_volume_unavailable"
        end
        return self.set("volume", expected, math.max(0, math.min(100, before.volume + delta)))
    end
    return self
end
return M
