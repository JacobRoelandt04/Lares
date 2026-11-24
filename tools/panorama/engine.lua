-- tools/panorama/engine.lua -- Lares Panorama's engine, Lua 5.5 INSIDE Hyprland (docs/contracts/panorama.md section 3).
--
-- It is never run from here: tools/panorama/generate.py (and the shell's EngineLink) put it after a `local PANORAMA_DATA_JSON = [=[..]=]`
-- line in ~/.config/hypr/config/panorama.lua, which Hyprland requires at its start and on every reload, and the shell `dofile`s by
-- eval when the data changes. The rules (identity, set key, scale snap, resolve, liveDiff, verify...) are the Lua twin of
-- modules/panorama/data/PanoramaModel.js, and both pass tools/dev/panorama_cases.json. The Hyprland facts it rests on: FACTS.md.
--
-- ONE global table `panorama`. Its state fields are set only when nil; its handlers are trampolines registered once.
-- Test hooks (tests only): LARES_PANORAMA_INTERNAL, or `panorama.internal_override` set before the file runs (a nested Hyprland's
-- environment cannot be given a variable), names a connector that counts as the internal panel (the nested env has no eDP).

local ENGINE_VERSION = 6
local DATA_JSON = PANORAMA_DATA_JSON or "{}"

panorama = panorama or {}
local P = panorama

-- ---- State (set only when nil: a second dofile keeps it) -------------------------------------------------------------------
P.serial = P.serial or 0
P.logs = P.logs or {}
P.timers = P.timers or {}
P.wsrules = P.wsrules or {}        -- workspace id (string) -> { rule = handle, monitor = name }
P.rules_sent = P.rules_sent or {}   -- output name -> how many rules were sent for it (tests read it; never written to the state file)
P.sent = P.sent or {}              -- output name -> { vrr, bitdepth } of the last rule sent (Hyprland's Lua cannot read them back)
P.deferred = P.deferred or {}      -- workspace id (string) -> monitor name (FACT F7)
P.trial = P.trial or { token = "", phase = "none", verdict = "" }
P.bound = P.bound or setmetatable({}, { __jsonarray = true })
P.snapshot = P.snapshot or nil     -- the data (as JSON text) in force before a trial
P.cast = P.cast or { map = {}, keep = {}, loaded = false }
-- P.seen: the output names listed at the last apply (nil until the first one of this session): a name that is new was PLUGGED, one that
-- is gone was unplugged, whatever events came (FACT G4: an output that comes up under a standing `disabled` rule fires no monitor.added).
-- P.on: externals a plug switched on against their stored setup, { set, id }, until the data says so itself (the shell stores it).
P.on = P.on or setmetatable({}, { __jsonarray = true })
-- P.conn: the kernel's word on the connector of each real external output listed (the cable watch below); P.dead: the listed outputs
-- that have no display
P.conn = P.conn or {}
P.dead = P.dead or {}   -- cast displays: output name -> identity `cast:<device id>`, and the names a live cast keeps
P.engine = ENGINE_VERSION

-- ---- JSON (no library) -----------------------------------------------------------------------------------------------------
local ARR = { __jsonarray = true }  -- the metatable of a JSON array (an empty one is still an array)
local json = {}

local function arr(t) return setmetatable(t or {}, ARR) end
local function isArray(t)
  local mt = getmetatable(t)
  return (mt ~= nil and mt.__jsonarray == true) or (next(t) ~= nil and #t > 0)
end

local function utf8char(cp) return utf8.char(cp) end

function json.decode(s, nullv)
  local pos = 1
  local function fail(msg) error("json: " .. msg .. " at " .. pos, 0) end
  local function ws() pos = s:find("[^ \t\r\n]", pos) or (#s + 1) end
  local value
  local function str()
    local out, i = {}, pos + 1
    while true do
      local j = s:find('["\\]', i)
      if not j then fail("unterminated string") end
      out[#out + 1] = s:sub(i, j - 1)
      if s:sub(j, j) == '"' then pos = j + 1; return table.concat(out) end
      local e = s:sub(j + 1, j + 1)
      local map = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }
      if map[e] then out[#out + 1] = map[e]; i = j + 2
      elseif e == "u" then
        local cp = tonumber(s:sub(j + 2, j + 5), 16)
        if not cp then fail("bad \\u escape") end
        i = j + 6
        if cp >= 0xD800 and cp < 0xDC00 and s:sub(i, i + 1) == "\\u" then
          local lo = tonumber(s:sub(i + 2, i + 5), 16)
          if lo and lo >= 0xDC00 and lo < 0xE000 then cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00); i = i + 6 end
        end
        out[#out + 1] = utf8char(cp)
      else fail("bad escape") end
    end
  end
  function value()
    ws()
    local c = s:sub(pos, pos)
    if c == "{" then
      local t = {}
      pos = pos + 1; ws()
      if s:sub(pos, pos) == "}" then pos = pos + 1; return t end
      while true do
        ws()
        if s:sub(pos, pos) ~= '"' then fail("object key expected") end
        local k = str(); ws()
        if s:sub(pos, pos) ~= ":" then fail("':' expected") end
        pos = pos + 1
        t[k] = value(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "}" then return t end
        if d ~= "," then fail("',' or '}' expected") end
      end
    elseif c == "[" then
      local t, n = arr(), 0
      pos = pos + 1; ws()
      if s:sub(pos, pos) == "]" then pos = pos + 1; return t end
      while true do
        n = n + 1
        t[n] = value(); ws()
        local d = s:sub(pos, pos); pos = pos + 1
        if d == "]" then return t end
        if d ~= "," then fail("',' or ']' expected") end
      end
    elseif c == '"' then return str()
    elseif s:sub(pos, pos + 3) == "true" then pos = pos + 4; return true
    elseif s:sub(pos, pos + 4) == "false" then pos = pos + 5; return false
    elseif s:sub(pos, pos + 3) == "null" then pos = pos + 4; return nullv
    else
      local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", pos)
      if not num or num == "" then fail("unexpected character") end
      pos = pos + #num
      local v = tonumber(num)
      if v == nil then fail("bad number") end
      return v
    end
  end
  local v = value(); ws()
  if pos <= #s then fail("trailing text") end
  return v
end

local ESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
local function encStr(s)
  return '"' .. s:gsub('[%c"\\]', function(c) return ESC[c] or string.format("\\u%04x", c:byte()) end) .. '"'
end

local byteLess   -- below
function json.encode(v)
  local tv = type(v)
  if tv == "nil" then return "null"
  elseif tv == "boolean" then return v and "true" or "false"
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if math.type(v) == "integer" then return string.format("%d", v) end
    if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
    return string.format("%.14g", v)
  elseif tv == "string" then return encStr(v)
  elseif tv == "table" then
    if isArray(v) then
      local out = {}
      for i = 1, #v do out[i] = json.encode(v[i]) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys, byteLess)
    local out = {}
    for i, k in ipairs(keys) do out[i] = encStr(k) .. ":" .. json.encode(v[k]) end
    return "{" .. table.concat(out, ",") .. "}"
  end
  return "null"
end

local function copy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = copy(v) end
  return setmetatable(c, getmetatable(t))
end

-- ---- The model: the Lua twin of modules/panorama/data/PanoramaModel.js (same names, same rules) -----------------------------
local M = {}

M.VERSION = 1
M.IGNORED = { "LARESLOCK-HOP", "FALLBACK" }
M.WORKSPACES = { "1", "2", "3", "4" }
M.CAST_MODE = "1920x1080@60"
local SCALE_MIN, SCALE_MAX = 1.0, 3.0
local PPMM_MIN, PPMM_MAX = 2.5, 14
local DIAG_MIN, DIAG_MAX = 250, 1100
local REFRESH_TOL, SCALE_TOL = 0.5, 0.001

-- Code-unit order. NEVER `<` on strings: that is strcoll, and Hyprland's locale is the user's (en_US puts "a" before "B").
function byteLess(a, b)
  local la, lb = #a, #b
  local n = la < lb and la or lb
  for i = 1, n do
    local x, y = a:byte(i), b:byte(i)
    if x ~= y then return x < y end
  end
  return la < lb
end
M.byteLess = byteLess

local function r(v) return math.floor(v + 0.5) end

local function trim(s)
  s = tostring(s == nil and "" or s)
  return (s:gsub("[ \t\r\n]+", " "):gsub("^ ", ""):gsub(" $", ""))
end

local function keysOf(t)
  local ks = {}
  for k in pairs(t or {}) do ks[#ks + 1] = k end
  table.sort(ks, byteLess)
  return ks
end

function M.isIgnored(name)
  name = tostring(name or "")
  for _, n in ipairs(M.IGNORED) do if n == name then return true end end
  return false
end

-- A cast display: a headless output the engine made for one TV (LARES-CAST-<n>); its identity is `cast:<device id>`.
function M.isCast(name)
  return tostring(name or ""):match("^LARES%-CAST%-%d+$") ~= nil
end

-- A CAST OUTPUT IS NEVER SWITCHED OFF AND NEVER A MIRROR while it exists (the JS twin has the reasons): `mirror` in its spec is the
-- shell's to read (a cast that mirrors has no output at all).
function M.specOn(name, spec)
  return (spec.enabled and true or false) or M.isCast(name)
end
function M.specMirror(name, spec)
  if M.isCast(name) then return "" end
  local mir = spec.mirror
  if mir == nil or mir == false then return "" end
  return mir
end

function M.isInternal(name)
  name = tostring(name or "")
  local ov = P.internal_override or os.getenv("LARES_PANORAMA_INTERNAL")
  if ov and ov ~= "" and name == ov then return true end
  return name:match("^eDP%-") ~= nil or name:match("^LVDS%-") ~= nil or name:match("^DSI%-") ~= nil
end

function M.identityOf(out, all)
  local d = trim(out.description)
  if out.castId and out.castId ~= "" then return out.castId end
  if out.backend == "headless" then return "headless:" .. out.name end
  if d == "" then return "port:" .. out.name end
  local twins = 0
  for _, o in ipairs(all or {}) do
    if not M.isIgnored(o.name) and o.backend ~= "headless" and trim(o.description) == d then twins = twins + 1 end
  end
  return twins > 1 and (d .. " @" .. out.name) or d
end

function M.identities(outs)
  local m = {}
  for _, o in ipairs(outs) do
    if not M.isIgnored(o.name) then m[o.name] = M.identityOf(o, outs) end
  end
  return m
end

function M.setKeyOf(ids)
  local c = {}
  for i, v in ipairs(ids) do c[i] = v end
  table.sort(c, byteLess)
  return table.concat(c, " + ")
end

function M.setOf(outs)
  local ids, list = M.identities(outs), {}
  for _, id in pairs(ids) do list[#list + 1] = id end
  return M.setKeyOf(list)
end

local function validK(k, w, h) return k > 0 and (120 * w) % k == 0 and (120 * h) % k == 0 end

-- FACT F5: k/120 with k dividing 120*W and 120*H, the nearest, ties UPWARD.
function M.snapScale(s, w, h)
  if not (w > 0 and h > 0) or not (s > 0) then return s end
  local k0 = r(s * 120)
  for i = 0, 2000 do
    if validK(k0 + i, w, h) then return (k0 + i) / 120 end
    if k0 - i > 0 and validK(k0 - i, w, h) then return (k0 - i) / 120 end
  end
  return s
end

function M.scaleChoices(w, h)
  local res = arr()
  for k = r(SCALE_MIN * 120), r(SCALE_MAX * 120) do
    if validK(k, w, h) then res[#res + 1] = k / 120 end
  end
  return res
end

local function plausible(out)
  if not ((out.physW or 0) > 0 and (out.physH or 0) > 0 and (out.width or 0) > 0) then return false end
  local ppmm = out.width / out.physW
  local diag = math.sqrt(out.physW * out.physW + out.physH * out.physH)
  return ppmm >= PPMM_MIN and ppmm <= PPMM_MAX and diag >= DIAG_MIN and diag <= DIAG_MAX
end

function M.physicalScale(ext, w, h, laptop)
  if not laptop or not plausible(laptop) or not plausible(ext) then return "auto" end
  local lapLogical = laptop.width / laptop.physW / ((laptop.scale or 0) > 0 and laptop.scale or 1)
  local s = (w / ext.physW) / lapLogical
  s = math.max(SCALE_MIN, math.min(SCALE_MAX, s))
  local snapped = M.snapScale(s, w, h)
  if snapped < SCALE_MIN then return M.snapScale(SCALE_MIN, w, h) end
  return snapped
end

function M.parseMode(mode)
  local w, h, rest = tostring(mode or ""):match("^(%d+)x(%d+)(.*)$")
  if not w then return nil end
  local rr = rest:match("^@([0-9.]+)")
  return { w = tonumber(w), h = tonumber(h), r = rr and tonumber(rr) or 0 }
end

local function modeString(w, h, rate)
  local v = math.floor(rate * 100 + 0.5) / 100
  local s = (v == math.floor(v)) and string.format("%d", v) or string.format("%.14g", v)
  return string.format("%d", w) .. "x" .. string.format("%d", h) .. "@" .. s
end

function M.preferredMode(out)
  local ms = out.modes or {}
  for _, m in ipairs(ms) do if m.preferred then return m end end
  if #ms > 0 then return ms[1] end
  if (out.width or 0) > 0 then return { w = out.width, h = out.height, r = out.refresh } end
  return nil
end

-- The preferred size at its fastest refresh: what a never-seen display gets on a machine with NO internal panel.
function M.fastestMode(out)
  local best = M.preferredMode(out)
  if not best then return nil end
  for _, m in ipairs(out.modes or {}) do
    if m.w == best.w and m.h == best.h and m.r > best.r then best = m end
  end
  return best
end

function M.specMode(spec, out)
  if spec.mode == "preferred" or not spec.mode or spec.mode == "" then return M.preferredMode(out) end
  return M.parseMode(spec.mode)
end

function M.specScale(spec, out, m)
  if spec.scale == "auto" or type(spec.scale) ~= "number" or not (spec.scale > 0) then
    return (out.scale or 0) > 0 and out.scale or 1
  end
  if m then return M.snapScale(spec.scale, m.w, m.h) end
  return spec.scale
end

function M.logicalSize(w, h, scale, transform)
  local lw, lh = r(w / scale), r(h / scale)
  if (transform % 2) == 1 then return { w = lh, h = lw } end
  return { w = lw, h = lh }
end

function M.rectOf(spec, out)
  local m = M.specMode(spec, out) or { w = out.width, h = out.height }
  local sz = M.logicalSize(m.w, m.h, M.specScale(spec, out, m), spec.transform or 0)
  return { x = spec.position[1], y = spec.position[2], w = sz.w, h = sz.h }
end

function M.defaultPosition(size, anchor, placed)
  local cx = anchor.x + anchor.w / 2
  local x = r(cx - size.w / 2)
  local top = anchor.y
  for _, p in ipairs(placed) do
    local overlapX = p.x < x + size.w and x < p.x + p.w
    if overlapX and p.y < top then top = p.y end
  end
  return arr({ x, top - size.h })
end

function M.defaultSpec()
  return { enabled = true, mode = "preferred", position = arr({ 0, 0 }), scale = "auto", transform = 0, mirror = false, vrr = 0,
           bitdepth = 8, cm = "srgb", sdrbrightness = 1, sdrsaturation = 1 }
end

local SPEC_KEYS = { "enabled", "mode", "position", "scale", "transform", "mirror", "vrr", "bitdepth", "cm", "sdrbrightness", "sdrsaturation" }

local function copySpec(s)
  local d = M.defaultSpec()
  for _, k in ipairs(SPEC_KEYS) do
    if s and s[k] ~= nil then
      if k == "position" then d.position = arr({ s.position[1], s.position[2] }) else d[k] = s[k] end
    end
  end
  if s and s.cast then d.cast = copy(s.cast) end     -- a cast display's stream quality rides on its spec
  return d
end

function M.knownSettings(data, id)
  local best, bestUsed = nil, -1
  local setups = (data or {}).setups or {}
  for _, key in ipairs(keysOf(setups)) do
    local st = setups[key]
    local o = st.outputs and st.outputs[id]
    if o then
      local used = st.used or 0
      if used > bestUsed then best = o; bestUsed = used end
    end
  end
  return best and copySpec(best) or nil
end

local function splitPlus(s)
  local parts, from = {}, 1
  while true do
    local a, b = s:find(" + ", from, true)
    if not a then parts[#parts + 1] = s:sub(from); break end
    parts[#parts + 1] = s:sub(from, a - 1)
    from = b + 1
  end
  return parts
end

function M.baseSetup(data, ids)
  local have = {}
  for _, id in ipairs(ids) do have[id] = true end
  local best, bestN, bestUsed = nil, -1, -1
  local setups = (data or {}).setups or {}
  for _, key in ipairs(keysOf(setups)) do
    local parts, inside = splitPlus(key), true
    for _, p in ipairs(parts) do
      if not have[p] then inside = false; break end
    end
    if inside then
      local used = setups[key].used or 0
      if #parts > bestN or (#parts == bestN and used > bestUsed) then best = key; bestN = #parts; bestUsed = used end
    end
  end
  return best
end

function M.bindPlaceholders(dataIn, outs)
  local d = copy(dataIn or {})
  d.displays = d.displays or {}; d.setups = d.setups or {}; d.split = d.split or {}
  local ids, bound = M.identities(outs), arr()
  for _, o in ipairs(outs) do
    local name = o.name
    local id = ids[name]
    local ph = "port:" .. name
    if id and id ~= ph and d.displays[ph] and d.displays[ph].placeholder and not d.displays[id] then
      local rec = d.displays[ph]
      d.displays[ph] = nil
      rec.placeholder = false
      d.displays[id] = rec
      local newSetups = {}
      for _, k in ipairs(keysOf(d.setups)) do
        local st = d.setups[k]
        if st.outputs and st.outputs[ph] then st.outputs[id] = st.outputs[ph]; st.outputs[ph] = nil end
        local parts = splitPlus(k)
        for i, p in ipairs(parts) do if p == ph then parts[i] = id end end
        newSetups[M.setKeyOf(parts)] = st
      end
      d.setups = newSetups
      for _, w in ipairs(keysOf(d.split)) do
        if d.split[w] == ph then d.split[w] = id end
      end
      bound[#bound + 1] = { from = ph, to = id }
    end
  end
  return { data = d, bound = bound }
end

function M.splitOf(data, present, ids, specs, internal)
  local shown, byId = {}, {}
  for _, o in ipairs(present) do
    local s = specs[o.name]
    if M.specOn(o.name, s) and M.specMirror(o.name, s) == "" then shown[#shown + 1] = o; byId[ids[o.name]] = o.name end
  end
  local res = {}
  if #shown == 0 then return res end
  -- a cast display is an external like any other (alone it takes 3 and 4), the real ones pick first
  local externals = {}
  for _, o in ipairs(shown) do
    if o ~= internal then externals[#externals + 1] = o end
  end
  table.sort(externals, function(a, b)
    if M.isCast(a.name) ~= M.isCast(b.name) then return M.isCast(b.name) end
    local pa, pb = specs[a.name].position, specs[b.name].position
    if pa[1] ~= pb[1] then return pa[1] < pb[1] end
    if pa[2] ~= pb[2] then return pa[2] < pb[2] end
    return byteLess(a.name, b.name)
  end)
  local home
  if internal and specs[internal.name].enabled and (specs[internal.name].mirror == "" or not specs[internal.name].mirror) then
    home = internal.name
  else
    home = shown[1].name
  end
  -- with no internal panel at all the home display is one of the externals, and not "the external" that takes 3-4
  if not internal then
    local rest = {}
    for _, o in ipairs(externals) do if o.name ~= home then rest[#rest + 1] = o end end
    externals = rest
  end
  local held = {}
  local split = (data and data.split) or {}
  for _, w in ipairs(M.WORKSPACES) do
    local nm = split[w] ~= nil and byId[split[w]] or nil
    if nm then res[w] = nm; held[nm] = true end
  end
  for _, w in ipairs(M.WORKSPACES) do
    if not res[w] then
      if tonumber(w) <= 2 then
        res[w] = home
      elseif #externals == 0 then
        res[w] = home
      else
        local pick = nil
        for _, e in ipairs(externals) do
          if not held[e.name] then pick = e.name; break end
        end
        res[w] = pick or externals[1].name
        held[res[w]] = true
      end
    end
  end
  return res
end

local function bitdepthOf(out)
  if (out.bitdepth or 0) > 0 then return out.bitdepth end
  if out.currentFormat == nil or out.currentFormat == "" then return 0 end
  local f = tostring(out.currentFormat)
  return (f:find("2101010") or f:find("16161616")) and 10 or 8
end
M.bitdepthOf = bitdepthOf

function M.specFromLive(out, internalName)
  local s = M.defaultSpec()
  s.enabled = out.enabled ~= false
  s.mode = (out.width or 0) > 0 and modeString(out.width, out.height, out.refresh or 0) or "preferred"
  s.position = arr({ out.x or 0, out.y or 0 })
  s.scale = (out.scale or 0) > 0 and out.scale or 1
  s.transform = (out.transform or 0) % 4
  s.mirror = (out.mirrorOf and out.mirrorOf ~= "" and out.mirrorOf == internalName) and true or false
  s.vrr = tonumber(out.vrr) or 0
  local bd = bitdepthOf(out)
  s.bitdepth = bd ~= 0 and bd or 8
  s.cm = out.cm or "srgb"
  s.sdrbrightness = (out.sdrbrightness or 0) > 0 and out.sdrbrightness or 1
  s.sdrsaturation = (out.sdrsaturation or 0) > 0 and out.sdrsaturation or 1
  return s
end

function M.resolve(outs, dataIn)
  local data = dataIn or { displays = {}, setups = {}, split = {} }
  local present = {}
  for _, o in ipairs(outs) do if not M.isIgnored(o.name) then present[#present + 1] = o end end
  table.sort(present, function(a, b) return byteLess(a.name, b.name) end)
  local ids, idList = M.identities(present), {}
  for i, o in ipairs(present) do idList[i] = ids[o.name] end
  local key = M.setKeyOf(idList)
  local setup = (data.setups or {})[key]
  local res = { setKey = key, kind = setup and "setup" or "default", base = setup and key or nil, name = setup and (setup.name or "") or "",
                specs = {}, unknown = arr(), split = {}, ids = ids }
  local internal = nil
  for _, o in ipairs(present) do if M.isInternal(o.name) then internal = o; break end end

  local specById = {}
  if setup then
    for _, id in ipairs(idList) do specById[id] = copySpec(setup.outputs[id]) end
  else
    local baseKey = M.baseSetup(data, idList)
    if baseKey then
      res.kind = "grown"; res.base = baseKey
      local byId = {}
      for _, o in ipairs(present) do byId[ids[o.name]] = o end
      for id, o in pairs(data.setups[baseKey].outputs) do
        specById[id] = copySpec(o)
        -- a set that grows starts with its externals on (the JS twin has the reason)
        if byId[id] and not M.isInternal(byId[id].name) then specById[id].enabled = true end
      end
    end
  end
  for _, id in ipairs(idList) do
    if not (data.displays or {})[id] then res.unknown[#res.unknown + 1] = id end
  end

  local placed = {}
  for _, o in ipairs(present) do
    local s = specById[ids[o.name]]
    if s and s.enabled and not s.mirror then placed[#placed + 1] = M.rectOf(s, o) end
  end
  local anchorOut = (internal and specById[ids[internal.name]] and specById[ids[internal.name]].enabled) and internal or nil
  local anchor = nil
  if anchorOut then anchor = M.rectOf(specById[ids[anchorOut.name]], anchorOut) elseif #placed > 0 then anchor = placed[1] end
  if internal and not specById[ids[internal.name]] then
    local si = M.knownSettings(data, ids[internal.name]) or M.specFromLive(internal, internal.name)
    si.enabled = true; si.mirror = false; si.position = arr({ 0, 0 })
    specById[ids[internal.name]] = si
    anchor = M.rectOf(si, internal)
    placed[#placed + 1] = anchor
  end
  for _, o in ipairs(present) do
    local id = ids[o.name]
    if not specById[id] then
      local spec = M.knownSettings(data, id)
      if not spec then
        spec = M.defaultSpec()
        if M.isCast(o.name) then
          spec.mode = M.CAST_MODE
          spec.scale = 1
        else
          local pm, fm = M.preferredMode(o), M.fastestMode(o)
          spec.scale = pm and M.physicalScale(o, pm.w, pm.h, internal) or "auto"
          if not internal and fm and fm.r > pm.r then spec.mode = modeString(fm.w, fm.h, fm.r) end
        end
      end
      spec.enabled = true; spec.mirror = false
      local rc = M.rectOf({ mode = spec.mode, scale = spec.scale, transform = spec.transform, position = { 0, 0 } }, o)
      if not anchor then
        spec.position = arr({ 0, 0 })
        anchor = { x = 0, y = 0, w = rc.w, h = rc.h }
      else
        spec.position = M.defaultPosition(rc, anchor, placed)
      end
      placed[#placed + 1] = { x = spec.position[1], y = spec.position[2], w = rc.w, h = rc.h }
      specById[id] = spec
    end
  end

  -- The safety rule: never a layout with nothing enabled.
  local anyOn = false
  for _, s in pairs(specById) do if s.enabled then anyOn = true; break end end
  if not anyOn and #present > 0 then
    local first = internal or present[1]
    specById[ids[first.name]].enabled = true
  end
  local internalOn = internal and specById[ids[internal.name]].enabled
  for _, o in ipairs(present) do
    local s2 = copySpec(specById[ids[o.name]])
    s2.mirror = (s2.mirror and internalOn and o ~= internal) and internal.name or ""
    res.specs[o.name] = s2
  end
  res.split = M.splitOf(data, present, ids, res.specs, internal)
  return res
end

function M.liveDiff(out, spec)
  local enabled = out.enabled ~= false
  if not M.specOn(out.name, spec) then return enabled and "enabled" or "" end
  if not enabled then return "enabled" end
  local mir = M.specMirror(out.name, spec)
  local live = out.mirrorOf
  if live == nil then live = "" end
  if live ~= mir then return "mirror" end
  if mir ~= "" then return "" end
  local m = M.specMode(spec, out)
  if m and (out.width ~= m.w or out.height ~= m.h) then return "mode" end
  if m and m.r > 0 and math.abs((out.refresh or 0) - m.r) > REFRESH_TOL then return "refresh" end
  if spec.scale ~= "auto" and math.abs((out.scale or 0) - M.specScale(spec, out, m)) > SCALE_TOL then return "scale" end
  if out.x ~= spec.position[1] or out.y ~= spec.position[2] then return "position" end
  if (out.transform or 0) ~= (spec.transform or 0) then return "transform" end
  if out.vrr ~= nil and (tonumber(out.vrr) or 0) ~= (tonumber(spec.vrr) or 0) and out.vrrCapable then return "vrr" end
  local bd = bitdepthOf(out)
  if bd ~= 0 and bd ~= (spec.bitdepth or 8) then return "bitdepth" end
  if out.cm ~= nil and tostring(out.cm) ~= tostring(spec.cm or "srgb") then return "cm" end
  return ""
end

function M.verify(outs, plan)
  local by = {}
  for _, o in ipairs(outs) do by[o.name] = o end
  for _, name in ipairs(keysOf(plan.specs)) do
    local o = by[name]
    if not o then return { ok = false, what = name .. ":gone" } end
    local d = M.liveDiff(o, plan.specs[name])
    if d ~= "" and d ~= "vrr" and d ~= "cm" and d ~= "bitdepth" then return { ok = false, what = name .. ":" .. d } end
  end
  return { ok = true, what = "" }
end

P.model = M
P.json = json

-- ---- Log, state file, nudge ---------------------------------------------------------------------------------------------------
local function log(fmt, ...)
  local ok, line = pcall(string.format, fmt, ...)
  if not ok then line = tostring(fmt) end
  P.logs[#P.logs + 1] = os.date("%H:%M:%S") .. " " .. line
  while #P.logs > 20 do table.remove(P.logs, 1) end
end
P.log = log

local function stateDir()
  if P.stateDir then return P.stateDir end
  local rt = os.getenv("XDG_RUNTIME_DIR")
  return (rt and rt ~= "") and (rt .. "/lares") or nil
end

function P.state()
  local plan = P.plan or {}
  local specs = {}
  for name, s in pairs(plan.specs or {}) do specs[name] = s end
  local split = {}
  for w, name in pairs(plan.split or {}) do split[w] = name end
  local deferred = arr()
  for _, w in ipairs(keysOf(P.deferred)) do deferred[#deferred + 1] = w end
  local lg = arr()
  for i, l in ipairs(P.logs) do lg[i] = l end
  return {
    v = 1, session = os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or "", serial = P.serial, engine = ENGINE_VERSION,
    set = plan.setKey or "", kind = plan.kind or "default", name = plan.name or "", specs = specs, split = split,
    unknown = plan.unknown or arr(), bound = P.bound, deferred = deferred,
    trial = { token = P.trial.token or "", phase = P.trial.phase or "none", verdict = P.trial.verdict or "" },
    cast = { outputs = P.cast.map, keep = P.castKeepList() },
    on = P.on, gone = P.goneList(),
    log = lg,
  }
end

function P.goneList()
  local l = arr()
  for _, n in ipairs(keysOf(P.dead)) do l[#l + 1] = n end
  return l
end

-- Atomic (a temp file, then rename); the directory is made only when it is missing.
function P.write_state()
  P.serial = P.serial + 1
  local dir = stateDir()
  if not dir then return false end
  local path, tmp = dir .. "/panorama.json", dir .. "/panorama.json.tmp"
  local text = json.encode(P.state())
  local f = io.open(tmp, "w")
  if not f then
    os.execute('mkdir -p "' .. dir .. '"')
    f = io.open(tmp, "w")
  end
  if not f then log("state: cannot write %s", tmp); return false end
  f:write(text); f:close()
  local ok, err = os.rename(tmp, path)
  if not ok then log("state: rename failed: %s", tostring(err)); return false end
  return true
end

function P.nudge()
  hl.dispatch(hl.dsp.event("lares-panorama," .. P.serial))
end

local function publish()
  P.write_state()
  P.nudge()
end

-- ---- Reading the live outputs (contract section 1, the Lua column) ---------------------------------------------------------------
function P.read_outputs()
  local list = hl.get_monitors({ all = true }) or {}
  local mirrorOf = {}
  for _, m in ipairs(list) do
    local mi = m.mirrors   -- the SOURCE lists the outputs that mirror it; the mirror says is_mirror (measured, FACTS)
    if type(mi) == "table" then
      for _, t in ipairs(mi) do mirrorOf[t.name] = m.name end
    elseif type(mi) == "userdata" and mi.name then
      mirrorOf[mi.name] = m.name
    end
  end
  local outs = {}
  for _, m in ipairs(list) do
    local hd = type(m.hardware_details) == "table" and m.hardware_details or {}
    -- a nested Hyprland's own window output (WAYLAND-1) is not a display, and neither is a cast output no cast has (a leftover: the
    -- sweep takes it; counted, it would be an "external" and take workspaces 3 and 4)
    -- ... nor an output whose cable is out though the compositor lists it (the cable watch)
    if not M.isIgnored(m.name) and hd.backend ~= "wayland" and not (M.isCast(m.name) and not P.cast.map[m.name]) and not P.dead[m.name] then
      local modes = arr()
      if type(m.available_modes) == "table" then
        for _, am in ipairs(m.available_modes) do
          modes[#modes + 1] = { w = am.width, h = am.height, r = am.refresh_rate, preferred = am.preferred and true or false }
        end
      end
      outs[#outs + 1] = {
        name = m.name, description = m.description or "", make = "", model = "", serial = m.serial or "", id = m.id,
        enabled = m.enabled ~= false, width = m.width or 0, height = m.height or 0, refresh = m.refresh_rate or 0,
        x = m.x or 0, y = m.y or 0, scale = m.scale or 1, transform = m.transform or 0,
        mirrorOf = mirrorOf[m.name] or "", physW = m.physical_width or 0, physH = m.physical_height or 0, modes = modes,
        backend = hd.backend or "", hdr = hd.hdr, bt2020 = hd.bt2020, vrrCapable = hd.vrr_capable and true or false,
        -- no `vrr` (vrr_active is the moment's state, not the setting) and no bitdepth in Lua: liveDiff skips both, and the
        -- engine compares them against the last rule it sent (needs_send)
        bitdepth = 0, cm = m.cm, driver = "", castId = P.cast.map[m.name] or "",
      }
    end
  end
  return outs
end

-- ---- Rules ----------------------------------------------------------------------------------------------------------------------
local function ruleOf(name, spec)
  if not M.specOn(name, spec) then return { output = name, disabled = true } end
  local pos = spec.position
  return {
    output = name, disabled = false, mode = spec.mode or "preferred",
    position = string.format("%dx%d", r(pos[1]), r(pos[2])),
    scale = spec.scale == "auto" and "auto" or spec.scale,
    transform = spec.transform or 0, mirror = M.specMirror(name, spec), vrr = spec.vrr or 0, bitdepth = spec.bitdepth or 8,
    cm = spec.cm or "srgb", sdrbrightness = spec.sdrbrightness or 1, sdrsaturation = spec.sdrsaturation or 1,
  }
end
P.rule_of = ruleOf

local function needsSend(out, spec)
  local d = M.liveDiff(out, spec)
  if d ~= "" then return d end
  local s = P.sent[out.name]
  if s and spec.enabled and (s.vrr ~= (spec.vrr or 0) or s.bitdepth ~= (spec.bitdepth or 8)) then return "settings" end
  return ""
end

local function listed(name)
  for _, m in ipairs(hl.get_monitors({ all = true }) or {}) do
    if m.name == name then return m end
  end
  return nil
end

local function wsOn(id)
  for _, w in ipairs(hl.get_workspaces() or {}) do
    if w.id == id then return w end
  end
  return nil
end

local function moveWorkspace(id, target)
  hl.dispatch(hl.dsp.workspace.move({ workspace = id, monitor = target }))
end

-- The split: persistent workspace rules by connector name (FACT F6), kept in the table, replaced when the target changes.
-- A NEW RULE PULLS AN EXISTING WORKSPACE TO ITS MONITOR (measured), so the rule of a deferred workspace waits with its move (FACT F7).
local function setRule(w, target)
  local cur = P.wsrules[w]
  if cur and cur.monitor == target then return end
  if cur and cur.rule then cur.rule:set_enabled(false) end
  P.wsrules[w] = nil
  if target then
    P.wsrules[w] = { rule = hl.workspace_rule({ workspace = w, monitor = target, persistent = true }), monitor = target }
  end
end

-- AN OUTPUT THAT IS STILL A MIRROR IS NO TARGET (FACT: a rule that ends a mirror lands after the call that sent it, and `workspace.move`
-- onto the mirror answers "Monitor not found", which `hyprctl eval` prints as a warning): the workspaces that belong on it wait, and
-- one short timer looks again once the un-mirror rule has landed (at most MIRROR_TRIES times, 150 ms apart).
local MIRROR_TRIES = 12

-- THE HAND-OVER (FACTS G1, G2). A new output is born on a workspace of Hyprland's own (the first free id: 5) and stays on it: moving 3
-- and 4 over does not put one of them on show. So the workspace count is five from the plug on, and the display shows a workspace
-- nobody asked for. Moving that birth workspace to another monitor makes the new one show its own (3), and Hyprland destroys the
-- empty workspace that was left, with no focus or pointer move -- but only for a monitor that is NOT focused (F7), and only once its
-- own workspace is really there. A workspace with a window in it is somebody's: never touched. Returns true when another look is due.
local function handOver(plan, outs)
  local again = false
  local other = {}
  for _, o in ipairs(outs) do
    if o.enabled and (o.mirrorOf or "") == "" then other[#other + 1] = o.name end
  end
  if #other < 2 then return false end
  local isSplit = {}
  for _, w in ipairs(M.WORKSPACES) do isSplit[tonumber(w)] = true end
  for _, name in ipairs(other) do
    local m = hl.get_monitor(name)
    local aw = m and m.active_workspace or nil
    if aw and aw.id and aw.id > 0 and not isSplit[aw.id] and (aw.windows or 0) == 0 and not m.focused then
      local own, there = nil, false
      for _, w in ipairs(M.WORKSPACES) do
        if plan.split[w] == name and not P.deferred[w] then
          own = own or w
          local ws = wsOn(tonumber(w))
          if ws and ws.monitor and ws.monitor.name == name then there = true end
        end
      end
      if own and there then
        local to = nil
        for _, n in ipairs(other) do if n ~= name then to = n; break end end
        local birth = aw.id
        moveWorkspace(birth, to)
        log("hand-over: %s shows its own workspace (%s left)", name, tostring(birth))
      elseif own then
        again = true
      end
    end
  end
  return again
end

local function applySplit(plan, outs)
  local enabledNow, mirroring = {}, {}
  for _, o in ipairs(outs) do
    if o.enabled then enabledNow[o.name] = true end
    if o.mirrorOf and o.mirrorOf ~= "" then mirroring[o.name] = true end
  end
  local act = hl.get_active_workspace()
  local waiting = false
  for _, w in ipairs(M.WORKSPACES) do
    local target = plan.split[w]
    local id = tonumber(w)
    local ws = target and wsOn(id) or nil
    local wrong = ws and enabledNow[target] and ws.monitor and ws.monitor.name ~= target
    if target and mirroring[target] then
      waiting = true
    elseif wrong and act and act.id == id then
      if P.deferred[w] ~= target then log("deferred: workspace %s -> %s", w, target) end
      P.deferred[w] = target
    else
      P.deferred[w] = nil
      setRule(w, target)
      if wrong then moveWorkspace(id, target) end
    end
  end
  if handOver(plan, outs) then waiting = true end
  if waiting then
    P.mirror_tries = (P.mirror_tries or 0) + 1
    if P.mirror_tries <= MIRROR_TRIES then
      P.arm_settle()
    else
      log("split: not settled after %d looks, giving up", MIRROR_TRIES)
    end
  else
    P.mirror_tries = 0
  end
end

function P.apply(why)
  if P.busy then P.again = why; return end
  P.busy = true
  local ok, err = pcall(function()
    local outs = P.read_outputs()
    if #outs == 0 then log("apply %s: no outputs", why); return end
    local bp = M.bindPlaceholders(P.data, outs)
    if #bp.bound > 0 then
      P.data = bp.data
      for _, b in ipairs(bp.bound) do P.bound[#P.bound + 1] = b end
      log("bound %d placeholder(s)", #bp.bound)
    end
    local plan = M.resolve(outs, P.data)
    -- what was plugged and what was unplugged since the last look, by the list itself
    local names, fresh = {}, {}
    for _, o in ipairs(outs) do names[o.name] = true end
    for n in pairs(names) do if not P.seen or not P.seen[n] then fresh[n] = true end end
    for n in pairs(P.seen or {}) do
      if not names[n] and not listed(n) then
        -- an unplug: the name's rule goes back to the catch-all values (FACT F17: the next display on that port would inherit it; G4: a
        -- standing `disabled` would keep it dark with no event), and what we sent for it is forgotten
        hl.monitor({ output = n, disabled = false, mirror = "", mode = "preferred", position = "auto", scale = "auto" })
        P.sent[n] = nil
        log("unplugged %s: rule reset", n)
      end
    end
    P.seen = names
    -- A PLUGGED DISPLAY TURNS ON (the user's rule, 2026-11-23): an "off" in the stored setup lasts until the cable is pulled. The setup in
    -- force is corrected here and the shell stores it (state `on`); the laptop's own panel keeps its off ("only external").
    local turned = false
    for _, o in ipairs(outs) do
      if fresh[o.name] and not M.isInternal(o.name) and not M.isCast(o.name) and not plan.specs[o.name].enabled then
        local st = (P.data.setups or {})[plan.setKey]
        local id = plan.ids[o.name]
        if st and st.outputs and st.outputs[id] then
          st.outputs[id].enabled = true
          P.on[#P.on + 1] = { set = plan.setKey, id = id }
          turned = true
          log("plugged %s: on (its setup had it off)", o.name)
        end
      end
    end
    if turned then plan = M.resolve(outs, P.data) end
    P.plan = plan
    local sends, mirrors = {}, {}
    for _, o in ipairs(outs) do
      local spec = plan.specs[o.name]
      local d = needsSend(o, spec)
      if d ~= "" then
        local rule = ruleOf(o.name, spec)
        if rule.mirror and rule.mirror ~= "" then mirrors[#mirrors + 1] = { rule = rule, spec = spec, why = d }
        else sends[#sends + 1] = { rule = rule, spec = spec, why = d } end
      end
    end
    for _, list in ipairs({ sends, mirrors }) do      -- mirrors last
      for _, s in ipairs(list) do
        hl.monitor(s.rule)
        P.rules_sent[s.rule.output] = (P.rules_sent[s.rule.output] or 0) + 1
        P.sent[s.rule.output] = { vrr = s.spec.vrr or 0, bitdepth = s.spec.bitdepth or 8 }
        log("rule %s (%s): %s", s.rule.output, s.why, why)
      end
    end
    -- an output with no display is switched off (its CRTC freed, its workspaces home)
    for n in pairs(P.dead) do
      local m = listed(n)
      if m and m.enabled ~= false then
        hl.monitor({ output = n, disabled = true })
        P.sent[n] = nil
        log("rule %s (no display): %s", n, why)
      end
    end
    applySplit(plan, outs)
  end)
  P.busy = false
  if not ok then log("apply %s failed: %s", why, tostring(err)) end
  -- (the first look of the cable watch can find a display gone: one more apply then)
  local ok2, seen = true, nil
  if not P.timers.cable then ok2, seen = pcall(P.watch) end      -- (armed already: the timer looks, at its own pace)
  local again = P.again or (ok2 and seen) or nil
  P.again = nil
  if again and not P.busyAgain then
    P.busyAgain = true
    pcall(P.apply, again)
    P.busyAgain = nil
  end
  publish()
end

-- ---- Events ---------------------------------------------------------------------------------------------------------------------
local function guard(name, fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if not ok then log("%s failed: %s", name, tostring(err)); pcall(publish) end
  end
end

local function cancel(which)
  local t = P.timers[which]
  if t then pcall(function() t:set_enabled(false) end) end
  P.timers[which] = nil
end

local function arm(which, ms, fn)
  cancel(which)
  P.timers[which] = hl.timer(guard("timer " .. which, fn), { timeout = math.max(1, math.floor(ms)), type = "oneshot" })
end

-- THE CABLE WATCH (the real machine, 2026-11-23). Hyprland's list cannot be trusted with a cable, two ways:
--   * an output that is SWITCHED OFF stays listed while its cable is out, and neither monitor.removed nor monitor.added is fired for it;
--   * the NVIDIA driver keeps a connector "connected" after its display was pulled (the journal: "Unable to read EDID for display device",
--     the mode list falls back to 1024x768 and below), so Hyprland keeps the output ON, with workspaces on a screen that is not there --
--     through `hyprctl reload` too. A forced probe and a CRTC switched off change nothing.
-- So while a real external output is listed, one slow timer reads the kernel's own words on its connector (/sys/class/drm/card<N>-<name>/
-- status and modes: cached, a few bytes, no probe). A connector that is not "connected", or is "connected" and has lost the display's
-- own mode for two looks in a row, has NO DISPLAY: the output is left out of every read (P.dead), switched off, and named in the state
-- (`gone`); when the connector answers again that is the plug. No real external listed, no timer.
local WATCH_MS = 1000

local function connFile(name, leaf)
  local dir = P.drmDir or "/sys/class/drm"
  for i = 0, 7 do
    local f = io.open(string.format("%s/card%d-%s/%s", dir, i, name, leaf), "r")
    if f then
      local s = f:read("a"); f:close()
      return s or ""
    end
  end
  return nil
end

-- "connected" | "disconnected" | "silent" (connected, the display's own mode gone) | nil (no connector of that name: a headless output)
local function connState(m)
  local st = connFile(m.name, "status")
  if not st then return nil end
  st = st:match("^%s*(%S*)") or ""
  if st ~= "connected" then return "disconnected" end
  local want = nil
  if type(m.available_modes) == "table" then
    for _, am in ipairs(m.available_modes) do
      if am.preferred then want = string.format("%dx%d", am.width, am.height); break end
    end
  end
  local modes = connFile(m.name, "modes")
  if not want or not modes or modes == "" then return "connected" end
  for line in modes:gmatch("[^\n]+") do
    if line == want then return "connected" end
  end
  return "silent"
end

function P.watch()
  local watched = {}
  for _, m in ipairs(hl.get_monitors({ all = true }) or {}) do
    local hd = type(m.hardware_details) == "table" and m.hardware_details or {}
    if not M.isIgnored(m.name) and not M.isCast(m.name) and not M.isInternal(m.name) and hd.backend ~= "wayland" then
      local st = connState(m)
      if st then watched[m.name] = st end
    end
  end
  local changed = nil
  for n, st in pairs(watched) do
    local c = P.conn[n]
    if type(c) ~= "table" then c = { state = "connected", silent = 0 } end     -- (an older engine of this session kept a word here)
    P.conn[n] = c
    -- a silent connector is believed at its second look (an EDID read that failed once is no unplug)
    if st == "silent" then
      c.silent = c.silent + 1
      if c.silent < 2 then st = c.state end
    else
      c.silent = 0
    end
    if st ~= c.state then
      local was = c.state
      c.state = st
      if st == "connected" then
        P.dead[n] = nil      -- (back in the list of outputs: the next apply sees a name it had not seen, a plug)
        log("cable: %s was plugged in", n)
        changed = "plug:" .. n
      elseif was == "connected" then
        P.dead[n] = true
        log("cable: %s is gone (%s), the compositor still lists it", n, st == "silent" and "the driver says connected, the display does not answer" or "disconnected")
        changed = changed or ("gone:" .. n)
      end
    end
  end
  for n in pairs(P.conn) do
    if not watched[n] then P.conn[n] = nil; P.dead[n] = nil end
  end
  cancel("cable")
  if next(watched) ~= nil then
    arm("cable", WATCH_MS, function()
      local why = P.watch()
      if why then P.apply(why) end
    end)
  end
  return changed
end

-- looks at the split again once the compositor has taken the rule that ended a mirror
function P.arm_settle()
  arm("settle", 150, function() P.apply("settle") end)
end

local function nameOf(m)
  if type(m) == "table" or type(m) == "userdata" then return m.name end
  return m
end

local function trialLive() return P.trial.phase == "trying" or P.trial.phase == "shown" end

P.on_added = guard("monitor.added", function(m)
  local name = nameOf(m)
  if not name or M.isIgnored(name) then return end
  P.apply("added:" .. name)
end)

-- IN THE HANDLER A REMOVED OUTPUT IS STILL LISTED, with `enabled` false (measured), exactly as an output switched off is: the two
-- are told apart a moment later, when an unplugged one is gone from the list. So the handler does only what cannot wait (the safety
-- rule, FACT F11) and the rest settles in one short timer.
P.pending_removed = P.pending_removed or {}

function P.settle_removed()
  local gone = false
  for name in pairs(P.pending_removed) do
    if not listed(name) then gone = true end     -- an unplug (apply resets its rule: it sees the name gone)
  end
  P.pending_removed = {}
  if gone and trialLive() then
    log("trial: an output was unplugged")
    P.revert(P.trial.token, "reverted")
    return
  end
  P.apply("removed")
end
P.settle_removed = guard("settle_removed", P.settle_removed)

P.on_removed = guard("monitor.removed", function(m)
  local name = nameOf(m)
  if not name or M.isIgnored(name) then return end
  -- the safety rule: with nothing enabled, the internal panel comes back, inside this handler (FACT F11)
  local anyOn, internal = false, nil
  for _, mm in ipairs(hl.get_monitors({ all = true }) or {}) do
    local hd = type(mm.hardware_details) == "table" and mm.hardware_details or {}
    if not M.isIgnored(mm.name) and hd.backend ~= "wayland" then
      -- (a cast output is no screen anybody sits at: with only one left, the panel comes back)
      if mm.name ~= name and mm.enabled ~= false and not M.isCast(mm.name) then anyOn = true end
      if M.isInternal(mm.name) and mm.name ~= name then internal = mm.name end
    end
  end
  if not anyOn and internal then
    hl.monitor({ output = internal, disabled = false })
    P.sent[internal] = nil
    log("safety: %s re-enabled", internal)
  end
  P.pending_removed[name] = true
  arm("removed", 100, function() P.settle_removed() end)
end)

local function runDeferred()
  local act = hl.get_active_workspace()
  local actId = act and act.id or nil
  local any = false
  for _, w in ipairs(keysOf(P.deferred)) do
    local id = tonumber(w)
    local target = P.deferred[w]
    local ws = wsOn(id)
    if not ws or (ws.monitor and ws.monitor.name == target) then
      -- Hyprland (or the user) already put it there: the persistent rule still has to say so, or it names the old monitor
      P.deferred[w] = nil; any = true
      setRule(w, target)
    elseif id ~= actId then
      P.deferred[w] = nil; any = true
      moveWorkspace(id, target)
      setRule(w, target)
      log("deferred move: workspace %s -> %s", w, target)
    end
  end
  return any
end

P.on_workspace = guard("workspace.active", function()
  if next(P.deferred) == nil then return end
  if runDeferred() then publish() end
end)

-- A reload runs the user's own monitor rules (hl.monitor lines of his config) AFTER this file's run read the outputs, so what that run
-- decided was true of the old state (measured: LOCK-2 put back at 2880x0 after our run saw -200 and sent nothing). The reload's end
-- looks again; liveDiff keeps it silent when nothing was undone.
P.on_reloaded = guard("config.reloaded", function() P.apply("reloaded") end)

-- ---- Cast displays (docs/contracts/panorama.md section 10) ----------------------------------------------------------------------------
-- The engine makes and removes the headless output of a cast (`hyprctl output create headless LARES-CAST-<n>`, run as the compositor's
-- child by hl.exec_cmd: the output shows up a moment later, monitor.added applies the resolved setup). The name -> identity table and
-- the names a live cast keeps are kept in a small file beside the state file, so a reload (a fresh Lua state) does not forget them.
-- THE CRASH-SAFE RULE: a LARES-CAST-* output nobody keeps is removed after a grace (the engine cannot see the stream; the shell tells it
-- the names with cast_keep at its start and after every change).
local CAST_GRACE_MS = 5000

function P.castKeepList()
  local l = arr()
  for _, n in ipairs(keysOf(P.cast.keep)) do l[#l + 1] = n end
  return l
end

local function castFile()
  local dir = stateDir()
  return dir and (dir .. "/panorama-cast.json") or nil
end

local function castSave()
  local path = castFile()
  if not path then return end
  local tmp = path .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then os.execute('mkdir -p "' .. path:match("^(.*)/[^/]*$") .. '"'); f = io.open(tmp, "w") end
  if not f then log("cast: cannot write %s", tmp); return end
  f:write(json.encode({ v = 1, map = P.cast.map, keep = P.castKeepList() })); f:close()
  os.rename(tmp, path)
end

local function castLoad()
  local path = castFile()
  local f = path and io.open(path, "r")
  if not f then return end
  local text = f:read("a"); f:close()
  local ok, d = pcall(json.decode, text)
  if not ok or type(d) ~= "table" then return end
  for n, id in pairs(d.map or {}) do if M.isCast(n) then P.cast.map[n] = id end end
  for _, n in ipairs(d.keep or {}) do if M.isCast(n) then P.cast.keep[n] = true end end
end

-- A name that is a bare identity or a JSON string of it.
local function plainText(text)
  local t = tostring(text or "")
  if t:sub(1, 1) == '"' then
    local ok, v = pcall(json.decode, t)
    if ok and type(v) == "string" then return v end
  end
  return t
end

-- `hyprctl output remove` ANSWERS "output not found" FOR AN OUTPUT THAT IS DISABLED OR MIRRORS (FACT G5), and exec_cmd drops the answer:
-- the removal is checked by the list. A cast output is never sent `disabled` or `mirror` (M.specOn), so the un-do here is for one an
-- older engine or a hand left that way: switched on first, removed a moment later (a rule lands after the call that sent it).
local CAST_REMOVE_TRIES = 5
local function castRemoveOutput(name, try)
  try = try or 1
  local m = listed(name)
  -- (not listed yet: its create may still be on the way -- the remove is sent anyway and the look below catches a late arrival)
  local stuck = m ~= nil and (m.enabled == false or m.is_mirror == true)
  if stuck then
    hl.monitor({ output = name, disabled = false, mirror = "", mode = M.CAST_MODE, position = "auto", scale = 1 })
    log("cast: %s was off or a mirror, switched on to remove it", name)
  else
    hl.exec_cmd("hyprctl output remove " .. name)
    log("cast: remove %s", name)
  end
  arm("castgone:" .. name, stuck and 300 or 500, function()
    if not listed(name) then return end
    if try >= CAST_REMOVE_TRIES then log("cast: %s is still there after %d tries", name, try); publish(); return end
    castRemoveOutput(name, try + 1)
  end)
end

-- the grace has run: every cast output nobody keeps goes
function P.cast_sweep()
  local removed = false
  for _, m in ipairs(hl.get_monitors({ all = true }) or {}) do
    if M.isCast(m.name) and not P.cast.keep[m.name] then
      castRemoveOutput(m.name)
      P.cast.map[m.name] = nil
      removed = true
    end
  end
  for n in pairs(P.cast.map) do
    if not P.cast.keep[n] and not listed(n) then P.cast.map[n] = nil; removed = true end
  end
  if removed then castSave(); publish() end
end

-- cast_open(identity): the output of this cast identity (made, or the one it already has: idempotent). Its name is in the state file's
-- cast.outputs at once; the output is listed a moment later.
function P.cast_open(idText)
  local id = plainText(idText)
  if id == "" or id:sub(1, 5) ~= "cast:" then log("cast_open: not a cast identity: %s", id); publish(); return end
  local name
  for _, n in ipairs(keysOf(P.cast.map)) do if P.cast.map[n] == id then name = n; break end end
  if not name then
    local n = 1
    while P.cast.map[string.format("LARES-CAST-%d", n)] or listed(string.format("LARES-CAST-%d", n)) do n = n + 1 end
    name = string.format("LARES-CAST-%d", n)
    P.cast.map[name] = id
  end
  P.cast.keep[name] = true
  castSave()
  if not listed(name) then
    hl.exec_cmd("hyprctl output create headless " .. name)
    log("cast: create %s for %s", name, id)
  else
    log("cast: %s is there for %s", name, id)
  end
  publish()
end

-- cast_close(name): the output goes and its rule goes back to the catch-all values (the unplug path does that when the removal lands).
function P.cast_close(name)
  name = plainText(name)
  if not M.isCast(name) then log("cast_close: not a cast output: %s", name); return end
  local known = P.cast.map[name] ~= nil or listed(name) ~= nil
  P.cast.map[name] = nil
  P.cast.keep[name] = nil
  castSave()
  if known then castRemoveOutput(name) end
  publish()
end

-- cast_keep(names): the cast outputs a live cast holds (a JSON array of names); the rest are swept after the grace
function P.cast_keep(text)
  local ok, list = pcall(json.decode, tostring(text))
  if not ok or type(list) ~= "table" then log("cast_keep: bad list"); return end
  P.cast.keep = {}
  for _, n in ipairs(list) do if M.isCast(n) then P.cast.keep[n] = true end end
  castSave()
  arm("caststray", CAST_GRACE_MS, function() P.cast_sweep() end)
  publish()
end

-- What a plug switched on stays on in every copy of the data that still says off (the file's, a trial's snapshot), until the data says
-- on itself (the shell has stored it): then the entry is done, and a later "off" is the user's again.
function P.keepOn()
  local rest = arr()
  for _, e in ipairs(P.on) do
    local st = ((P.data or {}).setups or {})[e.set]
    local sp = st and st.outputs and st.outputs[e.id] or nil
    if sp and sp.enabled == false then sp.enabled = true; rest[#rest + 1] = e end
  end
  P.on = rest
end

-- A reload is a fresh Lua state: what was listed and what a plug switched on come back from the state file, when it is this session's
-- (another session's file is the past: every display is "plugged" at Hyprland's start).
local function seenLoad()
  local dir = stateDir()
  local f = dir and io.open(dir .. "/panorama.json", "r")
  if not f then return end
  local text = f:read("a"); f:close()
  local ok, d = pcall(json.decode, text)
  if not ok or type(d) ~= "table" or (d.session or "") ~= (os.getenv("HYPRLAND_INSTANCE_SIGNATURE") or "") or d.session == "" then return end
  local names = {}
  for n in pairs(d.specs or {}) do names[n] = true end
  P.seen = names
  if #P.on == 0 then for _, e in ipairs(d.on or {}) do if type(e) == "table" and e.set and e.id then P.on[#P.on + 1] = { set = e.set, id = e.id } end end end
end

-- ---- Trials ---------------------------------------------------------------------------------------------------------------------
function P.revert(token, phase)
  if P.trial.token ~= token or not P.snapshot then log("revert: no such trial (%s)", tostring(token)); return end
  cancel("guard"); cancel("verify")
  P.data = json.decode(P.snapshot)
  P.snapshot = nil
  P.keepOn()
  P.trial.phase = phase or "reverted"
  if phase ~= "failed" then P.trial.verdict = "" end
  P.apply("revert")
end
P.revert = guard("revert", P.revert)

-- try(json, token [, guardMs [, verifyMs]]): the optional times are for tests; the shell never passes them.
function P.try(text, token, guardMs, verifyMs)
  cancel("guard"); cancel("verify")
  if not trialLive() then P.snapshot = json.encode(P.data or {}) end
  local ok, cand = pcall(json.decode, text)
  if not ok or type(cand) ~= "table" then
    P.trial = { token = token, phase = "failed", verdict = "failed:data" }
    log("try: bad data: %s", tostring(cand))
    publish()
    return
  end
  P.trial = { token = token, phase = "trying", verdict = "" }
  P.data = cand
  log("try %s", tostring(token))
  P.apply("try")
  arm("guard", guardMs or 45000, function()
    log("guard: no answer, reverting %s", tostring(token))
    P.revert(token, "reverted")
  end)
  arm("verify", verifyMs or 1500, function()
    if not trialLive() or P.trial.token ~= token then return end
    local outs = P.read_outputs()
    local plan = M.resolve(outs, P.data)
    local v = M.verify(outs, plan)
    if not v.ok then
      log("verify failed: %s", v.what)
      P.trial.verdict = "failed:" .. v.what
      P.revert(token, "failed")
    else
      log("verify ok")
    end
  end)
end
P.try = guard("try", P.try)
P.cast_open = guard("cast_open", P.cast_open)
P.cast_close = guard("cast_close", P.cast_close)
P.cast_keep = guard("cast_keep", P.cast_keep)
P.cast_sweep = guard("cast_sweep", P.cast_sweep)

-- shown(token [, ms]): the toast is on the glass; the guard runs `ms` from now (the shell's countdown + 2 s; 17 s when not given)
function P.shown(token, ms)
  if P.trial.token ~= token or not trialLive() then return end
  P.trial.phase = "shown"
  arm("guard", tonumber(ms) or 17000, function()
    log("guard: toast unanswered, reverting %s", tostring(token))
    P.revert(token, "reverted")
  end)
  publish()
end
P.shown = guard("shown", P.shown)

function P.keep(token)
  if P.trial.token ~= token or not trialLive() then return end
  cancel("guard"); cancel("verify")
  P.snapshot = nil
  P.trial.phase = "kept"
  log("kept %s", tostring(token))
  publish()
end
P.keep = guard("keep", P.keep)

function P.reload_data(text)
  P.data = json.decode(text)
  P.keepOn()
  P.apply("data")
end
P.reload_data = guard("reload_data", P.reload_data)

-- ---- The file run ---------------------------------------------------------------------------------------------------------------
local okd, dat = pcall(json.decode, DATA_JSON)
if not okd or type(dat) ~= "table" then log("data: unreadable (%s)", tostring(dat)); dat = {} end
if not trialLive() then P.data = dat else P.data = P.data or dat end
if P.seen == nil then pcall(seenLoad) end
P.keepOn()

if not P.hooked then
  P.hooked = true
  hl.on("monitor.added", function(m) return panorama.on_added(m) end)
  hl.on("monitor.removed", function(m) return panorama.on_removed(m) end)
  hl.on("workspace.active", function(w) return panorama.on_workspace(w) end)
  hl.on("config.reloaded", function() return panorama.on_reloaded() end)
end

-- a reload is a fresh Lua state: the cast table comes back from its file, and what no live cast keeps goes after the grace
if not P.cast.loaded then
  P.cast.loaded = true
  castLoad()
  arm("caststray", CAST_GRACE_MS, function() P.cast_sweep() end)
end

-- the catch-all: an output no rule names comes up at its preferred mode (NORULE), placed by apply
hl.monitor({ output = "", mode = "preferred", position = "auto", scale = "auto" })
log("engine %d loaded", ENGINE_VERSION)
P.apply("load")
