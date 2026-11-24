-- tools/dev/panorama_cases.lua -- Panorama's engine (tools/panorama/engine.lua) under /usr/bin/lua with a stub `hl`.
--
--   lua tools/dev/panorama_cases.lua          must end PANORAMA_CASES_LUA RESULT PASS
--   lua tools/dev/panorama_cases.lua --arms   the clean run passes AND every ARM turns a case red -> PANORAMA_CASES_LUA ARMS PASS
--
-- It runs (1) the ONE case table tools/dev/panorama_cases.json against panorama.model (cases with lang "js" are skipped), (2) the
-- event cases below against a stub `hl` (fake monitors, fake timers fired by hand), (3) the generation case: tools/panorama/generate.py
-- and the shell's EngineLink function (modules/panorama/data/EngineGenerate.js, run under node) write the same bytes.
-- ARMs patch ONE rule in a COPY of engine.lua in memory (an exact-string replace; the file is never touched):
--   luastrcoll  the set key sorts with `<` on strings (strcoll: the user's locale, not byte order)
--   snapdown    the scale snap tries downward first (FACT F5: ties go upward)
--   nohop       the lock's hop output counts
--   nodedup     liveDiff reports a difference for an equal output (every plug would re-modeset the eDP)
--   noguard     the handlers are registered at every file run (a dofile registers them again)
--   nodefer     the focused monitor's active workspace is moved at once (FACT F7: focus and pointer go with it)
--   nosafety    the internal panel is not re-enabled when the last enabled output goes
--   norulerun   a deferred workspace Hyprland already satisfied is cleared WITHOUT setting its persistent rule (the rule stays stale)
--   mirrormove  a workspace is moved onto an output that is still a mirror (Hyprland: "Monitor not found")
--   nostraysweep   the sweep after cast_keep removes nothing (a stray cast output stays for ever)
--   doubleclose    cast_close removes an output the second time too (the shell asks once per end; the engine must not run on)
--   castkeepdrop   a reload forgets the names a live cast keeps (the file is not read back): the live output is swept
--   castmirroron   a cast output whose spec says mirror is made a mirror (FACT G5: it could never be removed again)
--   grownoff       a set that grows carries its base's off
--   plugoff        a plugged display stays off when its setup says off
--   plugforgets    what a plug switched on is dark again at the next data load
--   nohandover     the new display keeps its birth workspace (five workspaces)
--   handoverwin    a birth workspace with a window in it is moved away too
--   noverifyremove a cast output that would not go is not looked at again
--   resetkeepsoff  an unplugged name's rule keeps its `disabled`
--   nooffwatch     a switched-off display that is plugged in again stays dark (no event comes for it)
--   nosilent       a connector the driver calls connected is believed though the display's own mode is gone
--   castnoext    a cast display is no external for the split
--   castfirst    a cast display picks its workspace before the real externals
--   castopendup    the same identity gets a second output
--   nofast         a never-seen display of a machine with no internal panel keeps the preferred refresh
--   homeextern     with no internal panel the home display counts as an external too (it is handed workspace 3)

local HERE = (arg and arg[0] or "tools/dev/panorama_cases.lua"):match("^(.*)/[^/]*$") or "."
local ROOT = HERE .. "/../.."
local ENGINE = ROOT .. "/tools/panorama/engine.lua"
local TABLE = HERE .. "/panorama_cases.json"
local GENERATE = ROOT .. "/tools/panorama/generate.py"
local GEN_NODE = HERE .. "/panorama_engine/gen_node.js"
local TMP = os.getenv("TMPDIR") or "/tmp"
-- a directory of this run's own: two rows of the gates start in one second (the cases and their arms), and a name built from the
-- second and one random digit was the same for both one time in ten -- they then shared the engine's state file (N3 red in both)
local WORK
do
  local h = io.popen('mktemp -d "' .. TMP .. '/panorama_cases_lua_XXXXXX"')
  WORK = h and h:read("l") or nil
  if h then h:close() end
  assert(WORK and WORK ~= "", "mktemp failed")
end

-- the locale of a real Hyprland (en_US): `<` on strings is strcoll there, so the luastrcoll ARM can bite
os.setlocale("en_US.utf8")

local function readFile(path)
  local f = assert(io.open(path, "rb"))
  local t = f:read("a"); f:close()
  return t
end

local function writeFile(path, text)
  local f = assert(io.open(path, "wb"))
  f:write(text); f:close()
end

os.execute('mkdir -p "' .. WORK .. '"')

local ARMS = {
  { "luastrcoll", "  table.sort(c, byteLess)\n  return table.concat(c, \" + \")", "  table.sort(c, function(a, b) return a < b end)\n  return table.concat(c, \" + \")" },
  { "snapdown", "    if validK(k0 + i, w, h) then return (k0 + i) / 120 end\n    if k0 - i > 0 and validK(k0 - i, w, h) then return (k0 - i) / 120 end",
    "    if k0 - i > 0 and validK(k0 - i, w, h) then return (k0 - i) / 120 end\n    if validK(k0 + i, w, h) then return (k0 + i) / 120 end" },
  { "nohop", 'M.IGNORED = { "LARESLOCK-HOP", "FALLBACK" }', 'M.IGNORED = { "FALLBACK" }' },
  { "nodedup", '  if out.x ~= spec.position[1] or out.y ~= spec.position[2] then return "position" end',
    '  if true then return "position" end' },
  { "noguard", "if not P.hooked then", "if true then" },
  { "nodefer", "if wrong and act and act.id == id then", "if false then" },
  { "nosafety", "if not anyOn and internal then", "if false then" },
  { "norulerun", "      P.deferred[w] = nil; any = true\n      setRule(w, target)\n    elseif id ~= actId then", "      P.deferred[w] = nil; any = true\n    elseif id ~= actId then" },
  { "mirrormove", "    if target and mirroring[target] then", "    if false then" },
  { "nostraysweep", "    if M.isCast(m.name) and not P.cast.keep[m.name] then", "    if false then" },
  { "doubleclose", "  if known then castRemoveOutput(name) end", "  castRemoveOutput(name)" },
  { "castkeepdrop", "  for _, n in ipairs(d.keep or {}) do if M.isCast(n) then P.cast.keep[n] = true end end", "" },
  { "castmirroron", "  if M.isCast(name) then return \"\" end\n  local mir = spec.mirror", "  local mir = spec.mirror" },
  { "grownoff", "        if byId[id] and not M.isInternal(byId[id].name) then specById[id].enabled = true end", "" },
  { "plugoff", "          st.outputs[id].enabled = true\n          P.on[#P.on + 1]", "          P.on[#P.on + 1]" },
  { "plugforgets", "    if sp and sp.enabled == false then sp.enabled = true; rest[#rest + 1] = e end", "" },
  { "nohandover", "  if handOver(plan, outs) then waiting = true end", "" },
  { "handoverwin", " and (aw.windows or 0) == 0 and not m.focused then", " and not m.focused then" },
  { "noverifyremove", "    castRemoveOutput(name, try + 1)", "" },
  { "nooffwatch", "        P.dead[n] = nil      -- (back in the list", "        -- (back in the list" },
  { "nosilent", "  return \"silent\"\nend", "  return \"connected\"\nend" },
  { "resetkeepsoff", "        hl.monitor({ output = n, disabled = false, mirror = \"\", mode = \"preferred\", position = \"auto\", scale = \"auto\" })", "        hl.monitor({ output = n, mode = \"preferred\", position = \"auto\", scale = \"auto\" })" },
  { "nofast", "if not internal and fm and fm.r > pm.r then", "if false then" },
  { "homeextern", "  if not internal then\n    local rest = {}", "  if false then\n    local rest = {}" },
  { "castnoext", "    if o ~= internal then externals[#externals + 1] = o end", "    if o ~= internal and not M.isCast(o.name) then externals[#externals + 1] = o end" },
  { "castfirst", "return M.isCast(b.name) end", "return M.isCast(a.name) end" },
  { "castopendup", "  for _, n in ipairs(keysOf(P.cast.map)) do if P.cast.map[n] == id then name = n; break end end", "" },
}

-- ---- A small loader: the engine text under a stub hl, with the generated file's data local before it ----------------------------
local NULL = setmetatable({}, { __tostring = function() return "null" end })

local function bracketed(text)
  local n = 0
  while (text .. "]"):find("]" .. string.rep("=", n) .. "]", 1, true) do n = n + 1 end
  local eq = string.rep("=", n)
  return "[" .. eq .. "[" .. text .. "]" .. eq .. "]"
end

local function chunkOf(engineText, dataJson)
  return "local PANORAMA_DATA_JSON = " .. bracketed(dataJson or "{}") .. "\n" .. engineText
end

-- ---- The stub world -------------------------------------------------------------------------------------------------------------
local function stubMonitor(o)
  local modes = {}
  for i, m in ipairs(o.modes or {}) do modes[i] = { width = m.w, height = m.h, refresh_rate = m.r, preferred = m.preferred } end
  return {
    name = o.name, description = o.description or "", serial = o.serial or "", id = o.id or 0, enabled = o.enabled ~= false,
    width = o.width, height = o.height, refresh_rate = o.refresh, x = o.x, y = o.y, scale = o.scale, transform = o.transform or 0,
    physical_width = o.physW or 0, physical_height = o.physH or 0, available_modes = modes, cm = o.cm or "srgb",
    hardware_details = { backend = o.backend or "drm", hdr = o.hdr, bt2020 = o.bt2020, vrr_capable = o.vrrCapable },
    is_mirror = false, mirrors = {}, _target = nil,
  }
end

local function newWorld(applyRules)
  local w = { monitors = {}, workspaces = {}, active = nil, calls = { monitor = {}, dispatch = {}, wsrule = {}, exec = {} }, handlers = {}, timers = {},
              applyRules = applyRules }
  local function recompute()
    for _, m in ipairs(w.monitors) do m.mirrors = {}; m.is_mirror = false end
    for _, m in ipairs(w.monitors) do
      if m._target then
        m.is_mirror = true
        for _, s in ipairs(w.monitors) do if s.name == m._target then s.mirrors[#s.mirrors + 1] = m end end
      end
    end
  end
  function w.find(name)
    for _, m in ipairs(w.monitors) do if m.name == name then return m end end
  end
  w.recompute = recompute
  w.pending = {}
  function w.land()      -- a mirror rule that was held lands now (the real compositor takes it AFTER the call that sent it)
    local list = w.pending
    w.pending = {}
    for _, spec in ipairs(list) do
      local m = w.find(spec.output)
      if m then m._target = spec.mirror ~= "" and spec.mirror or nil end
    end
    recompute()
  end
  function w.add(rec) local m = stubMonitor(rec); w.monitors[#w.monitors + 1] = m; return m end
  function w.remove(name)
    for i, m in ipairs(w.monitors) do if m.name == name then table.remove(w.monitors, i); return end end
  end
  w.hl = {
    monitor = function(spec)
      w.calls.monitor[#w.calls.monitor + 1] = spec
      if not w.applyRules then return end
      local m = w.find(spec.output)
      if not m then return end
      if spec.disabled == true then m.enabled = false end
      if spec.disabled == false then m.enabled = true end
      if spec.mode == "preferred" then
        for _, am in ipairs(m.available_modes) do
          if am.preferred then m.width, m.height, m.refresh_rate = am.width, am.height, am.refresh_rate end
        end
      elseif spec.mode then
        local mw, mh, mr = spec.mode:match("^(%d+)x(%d+)@?([%d.]*)")
        if mw then m.width, m.height = tonumber(mw), tonumber(mh); if mr ~= "" then m.refresh_rate = tonumber(mr) end end
      end
      if type(spec.position) == "string" then
        local px, py = spec.position:match("^(-?%d+)x(-?%d+)$")
        if px then m.x, m.y = tonumber(px), tonumber(py) end
      end
      if type(spec.scale) == "number" then m.scale = spec.scale end
      if spec.mirror ~= nil then
        if w.lagMirror then w.pending[#w.pending + 1] = spec
        else m._target = spec.mirror ~= "" and spec.mirror or nil; recompute() end
      end
    end,
    dispatch = function(d) w.calls.dispatch[#w.calls.dispatch + 1] = d end,
    exec_cmd = function(c) w.calls.exec[#w.calls.exec + 1] = c end,
    on = function(ev, fn) w.handlers[ev] = w.handlers[ev] or {}; table.insert(w.handlers[ev], fn) end,
    timer = function(fn, opts)
      local t = { fn = fn, timeout = opts.timeout, enabled = true }
      function t:set_enabled(v) self.enabled = v end
      w.timers[#w.timers + 1] = t
      return t
    end,
    workspace_rule = function(spec)
      local h = { spec = spec, enabled = true }
      function h:set_enabled(v) self.enabled = v end
      w.calls.wsrule[#w.calls.wsrule + 1] = h
      return h
    end,
    get_monitors = function() return w.monitors end,
    get_monitor = function(name) return w.find(name) end,
    get_workspaces = function() return w.workspaces end,
    get_active_workspace = function() return w.active end,
    get_config = function() return nil end,
    dsp = { event = function(s) return { event = s } end, workspace = { move = function(t) return { move = t } end } },
  }
  function w.fire(name, ...)
    for _, fn in ipairs(w.handlers[name] or {}) do fn(...) end
  end
  function w.fireTimer(t)
    assert(t and t.enabled, "timer not armed")
    t.enabled = false
    t.fn()
  end
  function w.clear() w.calls.monitor = {}; w.calls.dispatch = {}; w.calls.exec = {} end
  function w.setWorkspace(id, monName, active)
    local rec
    for _, x in ipairs(w.workspaces) do if x.id == id then rec = x end end
    if not rec then rec = { id = id }; w.workspaces[#w.workspaces + 1] = rec end
    rec.monitor = w.find(monName)
    if active then w.active = rec end
    return rec
  end
  return w
end

-- ---- Loading an engine text -------------------------------------------------------------------------------------------------------
local ENGINE_TEXT = readFile(ENGINE)
local TABLE_TEXT = readFile(TABLE)

local function loadEngine(world, text, dataJson, keep)
  _G.hl = world.hl
  -- (drmDir: no connector files, or the cable watch would read THIS machine's ports for the fixtures' names)
  if not keep then _G.panorama = { stateDir = WORK .. "/state", drmDir = WORK .. "/nodrm" } end
  local fn, err = load(chunkOf(text, dataJson), "=engine", "t")
  if not fn then error("engine does not compile: " .. err, 0) end
  fn()
  return _G.panorama
end

-- ---- The case table --------------------------------------------------------------------------------------------------------------------
local function run(arm, withGeneration)
  local text = ENGINE_TEXT
  if arm then
    local a
    for _, x in ipairs(ARMS) do if x[1] == arm then a = x end end
    local s, e = text:find(a[2], 1, true)
    if not s or text:find(a[2], e + 1, true) then error("ARM " .. arm .. ": its anchor is gone (or is not unique) in engine.lua", 0) end
    text = text:sub(1, s - 1) .. a[3] .. text:sub(e + 1)
  end
  local fails, n = 0, 0
  local quiet = arm ~= nil
  local function check(name, ok, detail)
    n = n + 1
    if not ok then
      fails = fails + 1
      if not quiet then print("CASE FAIL " .. name .. (detail and ("\n    " .. detail) or "")) end
    end
  end

  local base = newWorld(false)
  local P = loadEngine(base, text, "{}")
  local json, M = P.json, P.model

  local function eq(a, b)
    if a == NULL then a = nil end
    if b == NULL then b = nil end
    if type(a) == "number" and type(b) == "number" then return math.abs(a - b) < 1e-6 end
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do if not eq(v, b[k]) then return false end end
    for k, v in pairs(b) do if a[k] == nil and v ~= NULL then return false end end
    return true
  end
  local function subset(got, want)
    if want == NULL then return got == nil end
    if type(want) ~= "table" then return eq(got, want) end
    if type(got) ~= "table" then return false end
    if getmetatable(want) ~= nil then          -- an array
      if #got ~= #want then return false end
      for i = 1, #want do if not subset(got[i], want[i]) then return false end end
      return true
    end
    for k, v in pairs(want) do if not subset(got[k], v) then return false end end
    return true
  end
  local function show(v)
    local ok, s = pcall(json.encode, v)
    return ok and s:sub(1, 500) or tostring(v)
  end

  local tbl = json.decode(TABLE_TEXT, NULL)
  local function fixture(v)
    if type(v) == "string" and v:sub(1, 1) == "$" then
      local f = tbl.fixtures[v:sub(2)]
      assert(f, "no fixture " .. v)
      return json.decode(json.encode(f), NULL)
    end
    if type(v) == "table" and v ~= NULL then
      local c = setmetatable({}, getmetatable(v))
      for k, x in pairs(v) do c[k] = fixture(x) end
      return c
    end
    return v
  end

  local count = 0
  for _, c in ipairs(tbl.cases) do
    if c.lang ~= "js" then
      count = count + 1
      local args = {}
      for i = 1, #c.args do
        local a = fixture(c.args[i])
        if a == NULL then a = nil end
        args[i] = a
      end
      local ok, got = pcall(M[c.fn], table.unpack(args, 1, #c.args))
      local pass
      if not ok then pass = false
      elseif c.want ~= nil then pass = eq(got, c.want)
      else pass = subset(got, c.wantSubset) end
      check(c.fn .. "(" .. show(c.args):sub(1, 100) .. ")" .. (c.note and (" [" .. c.note .. "]") or ""), pass,
            "got  " .. (ok and show(got) or ("threw " .. tostring(got))) .. "\n    want " .. show(c.want ~= nil and c.want or c.wantSubset))
    end
  end

  -- ---- Event cases ---------------------------------------------------------------------------------------------------------------
  local fx = {}
  for k, v in pairs(tbl.fixtures) do fx[k] = v end
  local function out(name, over)
    local o = json.decode(json.encode(fx[name]), NULL)
    for k, v in pairs(over or {}) do o[k] = v end
    return o
  end
  local function dataText(name) return json.encode(fx[name]) end
  local function calls(w) return w.calls.monitor end
  local function rulesFor(w, name)
    local l = {}
    for _, c in ipairs(w.calls.monitor) do if c.output == name then l[#l + 1] = c end end
    return l
  end
  local function section(fn)
    local ok, err = pcall(fn)
    check("section threw", ok, tostring(err))
  end
  local function stateOf(P2) return json.decode(readFile(P2.stateDir .. "/panorama.json")) end

  -- E1: a never-seen plug sends exactly one rule, none for the eDP; a known set sends none at the file run
  section(function()
    local w = newWorld(false)
    w.add(out("edp"))
    local P2 = loadEngine(w, text, dataText("dataLaptop"))
    check("E1 file run: only the catch-all", #calls(w) == 1 and calls(w)[1].output == "", show(calls(w)))
    w.clear()
    w.add(out("proj", { name = "HDMI-A-1", description = "Acme Beamer 1000" }))
    w.fire("monitor.added", w.find("HDMI-A-1"))
    local sent = calls(w)
    check("E1 never-seen plug: exactly one rule", #sent == 1 and sent[1].output == "HDMI-A-1", show(sent))
    check("E1 never-seen plug: none for the eDP", #rulesFor(w, "eDP-1") == 0, show(sent))
    local st = stateOf(P2)
    check("E1 state lists it unknown", st.unknown[1] == "Acme Beamer 1000" and st.engine == 6 and st.serial >= 2, show(st))
    local nudged = false
    for _, d in ipairs(w.calls.dispatch) do if d.event and d.event:match("^lares%-panorama,%d+$") then nudged = true end end
    check("E1 nudge sent", nudged, show(w.calls.dispatch))
  end)

  -- E2: the hop output is ignored, added or removed
  section(function()
    local w = newWorld(false)
    w.add(out("edp"))
    local P2 = loadEngine(w, text, dataText("dataLaptop"))
    w.clear()
    local before = P2.serial
    w.add(out("hop"))
    w.fire("monitor.added", w.find("LARESLOCK-HOP"))
    w.remove("LARESLOCK-HOP")
    w.fire("monitor.removed", { name = "LARESLOCK-HOP" })
    check("E2 hop add/remove sends nothing", #calls(w) == 0 and #w.calls.dispatch == 0 and P2.serial == before,
          show(calls(w)) .. show(w.calls.dispatch))
    local ids = M.identities(P2.read_outputs())
    check("E2 hop is not read as an output", ids["LARESLOCK-HOP"] == nil)
  end)

  -- E3: the engine text twice registers the handlers once
  section(function()
    local w = newWorld(false)
    w.add(out("edp"))
    loadEngine(w, text, dataText("dataLaptop"))
    loadEngine(w, text, dataText("dataLaptop"), true)
    local counts = {}
    for ev, list in pairs(w.handlers) do counts[#counts + 1] = ev .. "=" .. #list end
    table.sort(counts)
    local ok = #(w.handlers["monitor.added"] or {}) == 1 and #(w.handlers["monitor.removed"] or {}) == 1
        and #(w.handlers["workspace.active"] or {}) == 1 and #(w.handlers["config.reloaded"] or {}) == 1
    check("E3 handlers registered once", ok, table.concat(counts, " "))
  end)

  -- E4: a trial whose verify fails reverts on the fake timer; the guard reverts an unanswered one; keep cancels it
  section(function()
    local w = newWorld(false)          -- the stub does NOT apply the rules, so the verify must fail
    w.add(out("edp"))
    local P2 = loadEngine(w, text, dataText("dataLaptop"))
    local cand = json.decode(dataText("dataLaptop"))
    for _, st in pairs(cand.setups) do for _, sp in pairs(st.outputs) do sp.scale = 1.5 end end
    w.clear()
    P2.try(json.encode(cand), "tok1")
    check("E4 try sends the candidate's rule", #rulesFor(w, "eDP-1") == 1 and rulesFor(w, "eDP-1")[1].scale == 1.5, show(calls(w)))
    check("E4 try arms guard 45 s and verify 1.5 s",
          P2.timers.guard and P2.timers.guard.timeout == 45000 and P2.timers.verify and P2.timers.verify.timeout == 1500)
    w.fireTimer(P2.timers.verify)
    local st = stateOf(P2)
    check("E4 failing verify reverts", st.trial.phase == "failed" and st.trial.verdict == "failed:eDP-1:scale", show(st.trial))
    local back
    for _, s in pairs(P2.data.setups) do for _, sp in pairs(s.outputs) do back = sp.scale end end
    check("E4 the data in force is the old one", back == 1.25, tostring(back))
    check("E4 revert cancelled the guard", P2.timers.guard == nil)
  end)
  section(function()
    local w = newWorld(true)           -- rules applied: the trial verifies
    w.add(out("edp"))
    local P2 = loadEngine(w, text, dataText("dataLaptop"))
    local cand = json.decode(dataText("dataLaptop"))
    for _, st in pairs(cand.setups) do for _, sp in pairs(st.outputs) do sp.scale = 1.5 end end
    P2.try(json.encode(cand), "tok2", 45000)
    w.fireTimer(P2.timers.verify)
    check("E4 verify ok keeps trying", stateOf(P2).trial.phase == "trying" and w.find("eDP-1").scale == 1.5)
    P2.shown("tok2")
    check("E4 shown re-arms the guard to 17 s", P2.timers.guard and P2.timers.guard.timeout == 17000 and stateOf(P2).trial.phase == "shown")
    P2.shown("tok2", 32000)
    check("E4 shown with the shell's time (panorama.jsonc keepSeconds 30 + 2 s) arms that", P2.timers.guard and P2.timers.guard.timeout == 32000,
          tostring(P2.timers.guard and P2.timers.guard.timeout))
    local oldGuard = P2.timers.guard
    w.fireTimer(oldGuard)
    check("E4 the guard reverts and re-applies the old data", stateOf(P2).trial.phase == "reverted" and w.find("eDP-1").scale == 1.25,
          show(stateOf(P2).trial) .. " scale " .. tostring(w.find("eDP-1").scale))
    P2.try(json.encode(cand), "tok3")
    local g = P2.timers.guard
    P2.keep("tok3")
    check("E4 keep cancels the guard", g.enabled == false and stateOf(P2).trial.phase == "kept" and w.find("eDP-1").scale == 1.5)
    P2.keep("wrong")
    check("E4 a token that is not the trial's does nothing", stateOf(P2).trial.phase == "kept")
  end)

  -- E5: the safety rule: the last enabled output goes, the internal panel is re-enabled inside the handler; an unplug resets the rule
  section(function()
    local w = newWorld(false)
    w.add(out("edp", { enabled = false }))
    w.add(out("lg"))
    local P2 = loadEngine(w, text, dataText("dataOnlyExternal"))
    w.clear()
    w.remove("DVI-I-1")
    w.fire("monitor.removed", { name = "DVI-I-1" })
    local re = rulesFor(w, "eDP-1")
    check("E5 internal re-enabled by the handler itself (the partial rule, before apply's complete one)",
          #re >= 1 and re[1].disabled == false and re[1].mode == nil, show(calls(w)))
    check("E5 the handler decides nothing else: no reset before the timer", #rulesFor(w, "DVI-I-1") == 0, show(calls(w)))
    w.fireTimer(P2.timers.removed)
    local reset = rulesFor(w, "DVI-I-1")
    check("E5 an unplugged name (gone from the list when the timer fires) is reset to the catch-all values",
          #reset == 1 and reset[1].mode == "preferred" and reset[1].scale == "auto", show(reset))
    -- an output switched off is still listed: no reset, no safety while another output is on
    local w2 = newWorld(false)
    w2.add(out("edp"))
    w2.add(out("lg", { enabled = false }))
    local loadedP2 = loadEngine(w2, text, dataText("dataLaptop"))
    w2.clear()
    w2.fire("monitor.removed", w2.find("DVI-I-1"))
    w2.fireTimer(loadedP2 and loadedP2.timers.removed)
    local resets = 0
    for _, c in ipairs(rulesFor(w2, "DVI-I-1")) do if c.scale == "auto" then resets = resets + 1 end end
    check("E5 switched off (still listed): no reset to the catch-all values", resets == 0, show(calls(w2)))
  end)

  -- E6: the focused monitor's active workspace is moved only when it is no longer on show (FACT F7)
  section(function()
    local w = newWorld(true)
    w.add(out("edp"))
    w.add(out("lg", { x = -280, y = -1440, scale = 1 }))
    w.setWorkspace(1, "eDP-1", false)
    w.setWorkspace(3, "eDP-1", true)    -- on show on the focused monitor, wanted on DVI-I-1 (split 3-4)
    w.setWorkspace(4, "eDP-1", false)
    local P2 = loadEngine(w, text, dataText("dataDesk"))
    local moves = {}
    for _, d in ipairs(w.calls.dispatch) do if d.move then moves[#moves + 1] = d.move end end
    local m3, m4 = false, false
    for _, m in ipairs(moves) do if m.workspace == 3 then m3 = true end; if m.workspace == 4 then m4 = true end end
    check("E6 the workspace not on show is moved at once", m4 and not m3, show(moves))
    local early = false
    for _, h in ipairs(w.calls.wsrule) do if h.spec.workspace == "3" then early = true end end
    check("E6 the one on show is deferred, and so is its rule (a new rule pulls the workspace)", stateOf(P2).deferred[1] == "3" and not early,
          show(stateOf(P2).deferred))
    w.setWorkspace(1, "eDP-1", true)    -- the user leaves it
    w.fire("workspace.active", w.active)
    local m3b = false
    for _, d in ipairs(w.calls.dispatch) do if d.move and d.move.workspace == 3 and d.move.monitor == "DVI-I-1" then m3b = true end end
    check("E6 the deferred move runs on workspace.active", m3b and #stateOf(P2).deferred == 0, show(w.calls.dispatch))
    local rules = {}
    for _, h in ipairs(w.calls.wsrule) do rules[h.spec.workspace] = h end
    check("E6 the split is persistent workspace rules by connector",
          rules["1"] and rules["3"] and rules["3"].spec.monitor == "DVI-I-1" and rules["3"].spec.persistent == true and rules["4"].spec.monitor == "DVI-I-1")
  end)

  -- E8: a deferred workspace Hyprland (or the user) already put on its target is cleared WITH its persistent rule
  section(function()
    local w = newWorld(true)
    w.add(out("edp"))
    w.add(out("lg", { x = -280, y = -1440, scale = 1 }))
    w.setWorkspace(1, "eDP-1", true)    -- on show on the focused monitor, wanted on DVI-I-1 (the split of dataDeskSplit1)
    w.setWorkspace(2, "eDP-1", false)
    local P2 = loadEngine(w, text, dataText("dataDeskSplit1"))
    local function ruleFor(id)
      local last
      for _, h in ipairs(w.calls.wsrule) do if h.spec.workspace == id and h.enabled then last = h end end
      return last
    end
    check("E8 workspace 1 is deferred, with no rule for the external yet", stateOf(P2).deferred[1] == "1" and not (ruleFor("1") and ruleFor("1").spec.monitor == "DVI-I-1"),
          show(stateOf(P2).deferred))
    w.setWorkspace(1, "DVI-I-1", false)    -- the user moved it there himself, and went to workspace 2
    w.setWorkspace(2, "eDP-1", true)
    w.fire("workspace.active", w.active)
    local r = ruleFor("1")
    check("E8 satisfied by Hyprland: cleared, and the persistent rule names the external", #stateOf(P2).deferred == 0 and r and r.spec.monitor == "DVI-I-1" and r.spec.persistent == true,
          show(stateOf(P2).deferred) .. " " .. show(r and r.spec))
  end)

  -- E9: an output that is still a mirror is no target; the split looks again once the un-mirror rule has landed
  section(function()
    local w = newWorld(true)
    w.lagMirror = true
    w.add(out("edp"))
    w.add(out("lg", { x = -280, y = -1440, scale = 1 }))
    w.find("DVI-I-1")._target = "eDP-1"; w.recompute()          -- a mirror trial is running; its revert is what loads now
    w.setWorkspace(1, "eDP-1", false)
    w.setWorkspace(3, "eDP-1", false)   -- the mirror's workspace went to the laptop; the data wants it back on DVI-I-1
    local P2 = loadEngine(w, text, dataText("dataDesk"))
    local function movedTo(ws, mon)
      for _, d in ipairs(w.calls.dispatch) do if d.move and d.move.workspace == ws and d.move.monitor == mon then return true end end
      return false
    end
    local function ruleOn(id, mon)
      for _, h in ipairs(w.calls.wsrule) do if h.spec.workspace == id and h.spec.monitor == mon then return true end end
      return false
    end
    check("E9 the un-mirror rule went out, last", rulesFor(w, "DVI-I-1")[1] and rulesFor(w, "DVI-I-1")[1].mirror == "", show(calls(w)))
    check("E9 while it is still a mirror: no move onto it and no rule that would pull a workspace onto it", not movedTo(3, "DVI-I-1") and not ruleOn("3", "DVI-I-1"), show(w.calls.dispatch))
    check("E9 ... and a short timer will look again", P2.timers.settle and P2.timers.settle.enabled, show(P2.timers))
    w.land()
    w.fireTimer(P2.timers.settle)
    check("E9 after the rule landed: workspace 3 is moved to DVI-I-1 and its rule is set", movedTo(3, "DVI-I-1") and ruleOn("3", "DVI-I-1"), show(w.calls.dispatch))
    check("E9 ... and the engine stops looking", not (P2.timers.settle and P2.timers.settle.enabled), show(P2.timers))
  end)

  -- C1-C8: cast displays (the engine makes the headless output of a cast, keeps a table name -> identity, sweeps the stray)
  local CID = "cast:wfd:02:AE:00:00:0A:01"
  local function execs(w, pat)
    local n = 0
    for _, c in ipairs(w.calls.exec) do if c:find(pat, 1, true) then n = n + 1 end end
    return n
  end
  section(function()
    local w = newWorld(false)
    w.add(out("edp"))
    local P2 = loadEngine(w, text, dataText("dataLaptop"))
    w.clear()
    P2.cast_open(CID)
    check("C1 cast_open creates LARES-CAST-1 as the compositor's child", execs(w, "hyprctl output create headless LARES-CAST-1") == 1, show(w.calls.exec))
    check("C1 the state file names it at once", stateOf(P2).cast.outputs["LARES-CAST-1"] == CID and stateOf(P2).cast.keep[1] == "LARES-CAST-1", show(stateOf(P2).cast))
    -- the output shows up; monitor.added applies the resolved setup: 1080p60, scale 1, centred above the laptop
    w.add(out("castOut", { x = 0, y = 0 }))
    w.clear()
    w.fire("monitor.added", w.find("LARES-CAST-1"))
    local r = rulesFor(w, "LARES-CAST-1")
    check("C2 monitor.added sends the cast its rule: mode, scale, place above the laptop",
          #r == 1 and r[1].mode == "1920x1080@60" and r[1].scale == 1 and r[1].position == "192x-1080" and r[1].disabled == false, show(r))
    check("C2 the cast's identity is the TV's (the state lists it as a display nobody knew)", stateOf(P2).unknown[1] == CID, show(stateOf(P2).unknown))
    check("C2 no trial, so no keep prompt", stateOf(P2).trial.phase == "none" and P2.timers.guard == nil, show(stateOf(P2).trial))
    local splitRule = {}
    for _, h in ipairs(w.calls.wsrule) do splitRule[h.spec.workspace] = h.spec.monitor end
    check("C2 workspaces 3 and 4 go to the cast, like any external", splitRule["3"] == "LARES-CAST-1" and splitRule["4"] == "LARES-CAST-1", show(splitRule))
    w.clear()
    P2.cast_open(CID)
    check("C3 the same identity reuses its output: no second create", execs(w, "output create") == 0 and stateOf(P2).cast.outputs["LARES-CAST-2"] == nil, show(w.calls.exec))
    P2.cast_open("cast:wfd:BB")
    check("C3 another TV is another output", execs(w, "output create headless LARES-CAST-2") == 1, show(w.calls.exec))
    w.clear()
    P2.cast_close("LARES-CAST-2")
    check("C4 cast_close removes the output", execs(w, "hyprctl output remove LARES-CAST-2") == 1 and stateOf(P2).cast.outputs["LARES-CAST-2"] == nil, show(w.calls.exec))
    w.clear()
    P2.cast_close("LARES-CAST-2")
    check("C4 a second close does nothing (the output is gone)", #w.calls.exec == 0, show(w.calls.exec))
    P2.cast_close("eDP-1")
    check("C4 a name that is no cast output is refused", #w.calls.exec == 0, show(w.calls.exec))
  end)
  section(function()
    local w = newWorld(false)
    w.add(out("edp"))
    local P2 = loadEngine(w, text, dataText("dataLaptop"))
    P2.cast_open(CID)
    w.add(out("castOut", { x = 0, y = 0 }))
    w.clear()
    P2.cast_keep("[]")
    check("C5 cast_keep arms the sweep with a 5 s grace", P2.timers.caststray and P2.timers.caststray.timeout == 5000, show(P2.timers))
    check("C5 nothing is removed before the grace is over", #w.calls.exec == 0, show(w.calls.exec))
    w.fireTimer(P2.timers.caststray)
    check("C5 the sweep removes the output no cast keeps", execs(w, "hyprctl output remove LARES-CAST-1") == 1 and stateOf(P2).cast.outputs["LARES-CAST-1"] == nil, show(w.calls.exec))
    w.remove("LARES-CAST-1")
    w.clear()
    P2.cast_open(CID)
    w.add(out("castOut", { x = 0, y = 0 }))
    P2.cast_keep('["LARES-CAST-1"]')
    w.clear()
    w.fireTimer(P2.timers.caststray)
    check("C5 an output a live cast keeps stays", #w.calls.exec == 0 and stateOf(P2).cast.outputs["LARES-CAST-1"] == CID, show(w.calls.exec))
    -- a reload is a fresh Lua state: the table and the kept names come back from their file; a live cast keeps its output
    local w2 = newWorld(false)
    w2.add(out("edp"))
    w2.add(out("castOut", { x = 0, y = 0 }))
    local P3 = loadEngine(w2, text, dataText("dataLaptop"))
    check("C6 a reload remembers the table", P3.cast.map["LARES-CAST-1"] == CID and P3.cast.keep["LARES-CAST-1"] == true, show(P3.cast))
    check("C6 ... and arms the sweep of the start", P3.timers.caststray and P3.timers.caststray.timeout == 5000)
    w2.clear()
    w2.fireTimer(P3.timers.caststray)
    check("C6 a live cast's output survives the start's sweep", #w2.calls.exec == 0, show(w2.calls.exec))
    P3.cast_keep("[]")
    local w3 = newWorld(false)
    w3.add(out("edp"))
    w3.add(out("castOut", { x = 0, y = 0 }))
    local P4 = loadEngine(w3, text, dataText("dataLaptop"))
    w3.clear()
    w3.fireTimer(P4.timers.caststray)
    check("C6 a start with no live cast sweeps the stray output", execs(w3, "hyprctl output remove LARES-CAST-1") == 1, show(w3.calls.exec))
  end)
  section(function()
    local w = newWorld(true)
    w.add(out("edp"))
    local P2 = loadEngine(w, text, dataText("dataCastMirror"))
    P2.cast_open(CID)
    w.add(out("castOut", { x = 0, y = 0 }))
    w.setWorkspace(1, "eDP-1", true)
    w.setWorkspace(2, "eDP-1", false)
    w.clear()
    w.fire("monitor.added", w.find("LARES-CAST-1"))
    local r = rulesFor(w, "LARES-CAST-1")
    check("C7 a cast output whose spec says mirror is neither switched off nor made a mirror", #r == 1 and r[1].disabled == false and r[1].mirror == "", show(r))
    check("C7 the laptop gets no rule (it is as asked) and no workspace moves", #rulesFor(w, "eDP-1") == 0 and #w.calls.dispatch == 1, show(w.calls.monitor) .. show(w.calls.dispatch))
    check("C7 the cast output stays on in the compositor (off, it could not be removed)", w.find("LARES-CAST-1").enabled ~= false)
  end)

  -- N: a plugged display turns on, the hand-over of the birth workspace, a removal that is looked at again (2026-11-23)
  local LGID = "Acme Displays ACME ULTRAWIDE 0x0000C0DE"
  local DESK = "Acme Displays ACME ULTRAWIDE 0x0000C0DE + Samsung Display Corp. 0x4180"
  local function freshState() os.remove(WORK .. "/state/panorama.json") end
  section(function()
    freshState()
    local w = newWorld(true)
    w.add(out("edp"))
    local P2 = loadEngine(w, text, dataText("dataDeskOff"))
    w.clear()
    w.add(out("lg", { x = 0, y = 0, scale = 1 }))
    w.fire("monitor.added", w.find("DVI-I-1"))
    local r = rulesFor(w, "DVI-I-1")
    check("N1 a plugged display whose setup says off is switched ON (ARM plugoff)", w.find("DVI-I-1").enabled ~= false and (#r == 0 or r[#r].disabled == false), show(r))
    check("N1 the setup in force says on, and the state names it for the shell to store",
          P2.data.setups[DESK].outputs[LGID].enabled == true and #stateOf(P2).on == 1 and stateOf(P2).on[1].id == LGID, show(stateOf(P2).on))
    w.clear()
    P2.reload_data(dataText("dataDeskOff"))
    check("N2 a data load that still says off does not darken it again (ARM plugforgets)", w.find("DVI-I-1").enabled ~= false and #stateOf(P2).on == 1, show(calls(w)))
    P2.reload_data(dataText("dataDesk"))
    check("N2 once the data says on itself the entry is done", #stateOf(P2).on == 0, show(stateOf(P2).on))
    w.clear()
    P2.reload_data(dataText("dataDeskOff"))
    check("N2 a later off is the user's: it holds", w.find("DVI-I-1").enabled == false, show(calls(w)))
    -- a reload (a fresh Lua state, the same session): the display was there before, so its off holds
    w.clear()
    local P3 = loadEngine(w, text, dataText("dataDeskOff"))
    check("N3 a reload is no plug: the off holds", w.find("DVI-I-1").enabled == false and #stateOf(P3).on == 0, show(calls(w)))
    -- Hyprland's start (no state of this session): every display counts as plugged
    freshState()
    w.clear()
    local P4 = loadEngine(w, text, dataText("dataDeskOff"))
    check("N3 at the session's start a connected display is on", w.find("DVI-I-1").enabled ~= false and #stateOf(P4).on == 1, show(calls(w)))
    -- the unplug: the name's rule is reset, `disabled` included (FACT G4)
    w.clear()
    w.remove("DVI-I-1")
    w.fire("monitor.removed", { name = "DVI-I-1" })
    w.fireTimer(P4.timers.removed)
    local rr = rulesFor(w, "DVI-I-1")
    check("N4 an unplug resets the name's rule, disabled = false said (ARM resetkeepsoff)",
          #rr == 1 and rr[1].disabled == false and rr[1].mode == "preferred" and rr[1].mirror == "", show(rr))
  end)
  -- N7: THE CABLE WATCH (the real machine, 2026-11-23). An output that is off stays listed through an unplug and no event comes; and the
  -- NVIDIA driver keeps a pulled HDMI "connected" with only fallback modes, so the compositor keeps the output ON.
  section(function()
    freshState()
    local drm = WORK .. "/drm"
    os.execute('mkdir -p "' .. drm .. '/card0-DVI-I-1"')
    local function put(leaf, v) local f = io.open(drm .. "/card0-DVI-I-1/" .. leaf, "w"); f:write(v); f:close() end
    local REAL, FALLBACK = "3440x1440\n1920x1080\n1024x768\n", "1024x768\n800x600\n640x480\n"
    put("status", "connected\n"); put("modes", REAL)
    local w = newWorld(true)
    w.add(out("edp"))
    w.add(out("lg", { x = -280, y = -1440, scale = 1 }))
    _G.panorama = { stateDir = WORK .. "/state", drmDir = drm }
    local P2 = loadEngine(w, text, dataText("dataDesk"), true)
    local function look() w.fireTimer(P2.timers.cable) end
    check("N7 a real external listed: the watch is armed", P2.timers.cable ~= nil and P2.timers.cable.enabled)
    look()
    check("N7 nothing changed: on, nothing gone", w.find("DVI-I-1").enabled ~= false and #stateOf(P2).gone == 0, show(stateOf(P2).gone))
    -- the driver's lie: connected, the display's own mode gone
    put("modes", FALLBACK)
    look()
    check("N7 one silent look is no unplug (an EDID read that failed once)", w.find("DVI-I-1").enabled ~= false and #stateOf(P2).gone == 0, show(P2.logs))
    w.clear()
    look()
    local st = stateOf(P2)
    check("N7 at the second it is gone: left out of the set, named in the state, switched off (ARM nosilent)",
          st.gone[1] == "DVI-I-1" and st.set == "Samsung Display Corp. 0x4180" and st.specs["DVI-I-1"] == nil and w.find("DVI-I-1").enabled == false, show(st.gone) .. st.set .. show(calls(w)))
    check("N7 ... and the workspaces are the laptop's", st.split["3"] == "eDP-1" and st.split["4"] == "eDP-1", show(st.split))
    put("modes", REAL)
    w.clear()
    look()
    st = stateOf(P2)
    check("N7 the display answers again: back in the set and on", #st.gone == 0 and st.specs["DVI-I-1"] ~= nil and w.find("DVI-I-1").enabled ~= false, show(st.gone) .. show(calls(w)))
    -- switched off by the user, then the cable pulled and put back
    P2.reload_data(dataText("dataDeskOff"))
    check("N7 the user's off holds while the display is there", w.find("DVI-I-1").enabled == false and #stateOf(P2).gone == 0)
    put("status", "disconnected\n")
    look()
    check("N7 the cable out: no display (still listed by the compositor)", stateOf(P2).gone[1] == "DVI-I-1" and w.find("DVI-I-1") ~= nil, show(stateOf(P2).gone))
    put("status", "connected\n")
    w.clear()
    look()
    check("N7 the cable back in: the display is switched ON (ARM nooffwatch)", w.find("DVI-I-1").enabled ~= false and #stateOf(P2).on == 1 and #stateOf(P2).gone == 0, show(calls(w)) .. show(P2.logs))
    w.remove("DVI-I-1")
    w.fire("monitor.removed", { name = "DVI-I-1" })
    w.fireTimer(P2.timers.removed)
    if P2.timers.cable and P2.timers.cable.enabled then look() end
    check("N7 no real external listed: no watch runs", P2.timers.cable == nil or not P2.timers.cable.enabled)
  end)
  section(function()
    freshState()
    local w = newWorld(true)
    w.add(out("edp"))
    local P2 = loadEngine(w, text, dataText("dataDesk"))
    for i = 1, 4 do w.setWorkspace(i, "eDP-1", i == 1) end
    w.find("eDP-1").focused = true
    w.find("eDP-1").active_workspace = w.setWorkspace(1, "eDP-1", true)
    local lg = w.add(out("lg", { x = -280, y = -1440, scale = 1 }))
    local birth = w.setWorkspace(5, "DVI-I-1", false)
    birth.windows = 0
    lg.active_workspace = birth
    w.clear()
    w.fire("monitor.added", lg)
    local function movesOf(id)
      local n, to = 0, nil
      for _, d in ipairs(w.calls.dispatch) do if d.move and d.move.workspace == id then n = n + 1; to = d.move.monitor end end
      return n, to
    end
    check("N5 the birth workspace waits until the display's own workspace is on it", movesOf(5) == 0 and P2.timers.settle ~= nil, show(w.calls.dispatch))
    w.setWorkspace(3, "DVI-I-1", false)
    w.setWorkspace(4, "DVI-I-1", false)
    w.clear()
    w.fireTimer(P2.timers.settle)
    local n5, to5 = movesOf(5)
    check("N5 then it is moved to the other display: the new one shows its own, four workspaces (ARM nohandover)", n5 == 1 and to5 == "eDP-1", show(w.calls.dispatch))
    -- a workspace somebody uses is never touched
    birth.windows = 1
    w.clear()
    P2.apply("again")
    check("N5 a birth workspace with a window in it stays (ARM handoverwin)", movesOf(5) == 0, show(w.calls.dispatch))
    -- nor the focused monitor's (F7: the move would carry the focus)
    birth.windows = 0
    lg.focused = true
    w.clear()
    P2.apply("again")
    check("N5 the focused monitor's workspace stays", movesOf(5) == 0, show(w.calls.dispatch))
  end)
  section(function()
    freshState()
    local w = newWorld(true)
    w.add(out("edp"))
    local P2 = loadEngine(w, text, dataText("dataLaptop"))
    P2.cast_open(CID)
    w.add(out("castOut", { x = 0, y = 0 }))
    w.fire("monitor.added", w.find("LARES-CAST-1"))
    w.clear()
    P2.cast_close("LARES-CAST-1")
    check("N6 cast_close asks for the removal", execs(w, "hyprctl output remove LARES-CAST-1") == 1, show(w.calls.exec))
    w.clear()
    w.fireTimer(P2.timers["castgone:LARES-CAST-1"])
    check("N6 an output that is still listed is removed again (ARM noverifyremove)", execs(w, "hyprctl output remove LARES-CAST-1") == 1, show(w.calls.exec))
    -- one that is off cannot be removed (FACT G5): switched on first, removed at the next look
    w.find("LARES-CAST-1").enabled = false
    w.clear()
    w.fireTimer(P2.timers["castgone:LARES-CAST-1"])
    local r = rulesFor(w, "LARES-CAST-1")
    check("N6 an output that is off is switched on before it is removed", #r == 1 and r[1].disabled == false and execs(w, "output remove") == 0, show(r) .. show(w.calls.exec))
    w.clear()
    w.fireTimer(P2.timers["castgone:LARES-CAST-1"])
    check("N6 and removed at the next look", execs(w, "hyprctl output remove LARES-CAST-1") == 1, show(w.calls.exec))
    w.remove("LARES-CAST-1")
    w.clear()
    w.fireTimer(P2.timers["castgone:LARES-CAST-1"])
    check("N6 once it is gone nothing more is asked", #w.calls.exec == 0 and #calls(w) <= 1, show(w.calls.exec))
  end)
  section(function()
    local w = newWorld(false)
    w.add(out("edp"))
    w.add(out("lg", { x = -280, y = -1440, scale = 1 }))
    local P2 = loadEngine(w, text, dataText("dataDesk"))
    P2.cast_open(CID)
    w.add(out("castOut", { x = 0, y = 0 }))
    w.clear()
    w.fire("monitor.added", w.find("LARES-CAST-1"))
    local st8 = stateOf(P2).split
    check("C8 the real external picks first: 3 is its, the cast takes 4", st8["3"] == "DVI-I-1" and st8["4"] == "LARES-CAST-1", show(st8))
    check("C8 another foreign headless output is no cast", not M.isCast("LOCK-3") and M.identityOf(out("lock3"), { out("lock3") }) == "headless:LOCK-3")
  end)

  -- E7: the generation case (clean run only)
  if withGeneration then
    local nasty = json.decode(dataText("dataDesk"))
    nasty.displays["Samsung Display Corp. 0x4180"].label = "Lap ]] ]=] ]==] \"q\" \\ \u{00e9}"
    nasty.setups["Samsung Display Corp. 0x4180"].name = "x\ny"
    for i, case in ipairs({ { "plain", fx.dataDesk }, { "nasty", nasty } }) do
      local src = WORK .. "/setups" .. i .. ".json"
      writeFile(src, json.encode(case[2]))
      local py, js = WORK .. "/gen_py" .. i .. ".lua", WORK .. "/gen_js" .. i .. ".lua"
      local ok1 = os.execute(string.format('python3 "%s" "%s" "%s" "%s"', GENERATE, src, ENGINE, py))
      local ok2 = os.execute(string.format('node "%s" "%s" "%s" "%s"', GEN_NODE, src, ENGINE, js))
      check("E7 " .. case[1] .. ": both generators ran", ok1 == true and ok2 == true)
      if ok1 == true and ok2 == true then
        local a, b = readFile(py), readFile(js)
        local function strip(t) return (t:gsub("%-%- generated: [^\n]*\n", "-- generated: <time>\n")) end
        check("E7 " .. case[1] .. ": same bytes from python and the shell's function", strip(a) == strip(b),
              "python " .. #a .. " bytes, node " .. #b)
        check("E7 " .. case[1] .. ": the engine text is verbatim at the end", a:sub(-#ENGINE_TEXT) == ENGINE_TEXT)
        check("E7 " .. case[1] .. ": header says generated and the version",
              a:find("Generated by Lares Panorama. Do not edit", 1, true) and a:find("engine version: 6", 1, true) and a:find("-- generated: ", 1, true))
        local w = newWorld(false)
        w.add(out("edp"))
        _G.hl = w.hl
        _G.panorama = { stateDir = WORK .. "/state", drmDir = WORK .. "/nodrm" }
        local fn, err = load(a, "=generated", "t")
        local okl = fn ~= nil and pcall(fn)
        local P3 = _G.panorama
        local same = okl and P3.data and json.encode(P3.data) == json.encode(case[2])
        check("E7 " .. case[1] .. ": the generated file loads and holds the data", same, tostring(err))
      end
    end
  end

  return fails, n
end

-- ---- Main --------------------------------------------------------------------------------------------------------------------------------
local function cleanup() os.execute('rm -rf "' .. WORK .. '"') end

local okRun, fails, n = pcall(run, nil, true)
if not okRun then
  print("CASE THREW " .. tostring(fails))
  cleanup()
  print("PANORAMA_CASES_LUA RESULT FAIL (the run threw)")
  os.exit(1)
end

local armsMode = false
for _, a in ipairs(arg or {}) do if a == "--arms" then armsMode = true end end

if armsMode then
  if fails > 0 then
    print("PANORAMA_CASES_LUA ARMS FAIL (the clean run has " .. fails .. " failures)")
    cleanup(); os.exit(1)
  end
  local bad = {}
  for _, a in ipairs(ARMS) do
    local ok, af = pcall(run, a[1], false)
    _G.panorama = nil
    if not ok then
      -- a Lua error out of the patched engine is a red case too, but a lost anchor is not
      if tostring(af):find("anchor is gone", 1, true) then print(af); bad[#bad + 1] = a[1]
      else print("ARM " .. a[1] .. ": fails as it must (the engine threw: " .. tostring(af):sub(1, 90) .. ")") end
    else
      print("ARM " .. a[1] .. ": " .. (af > 0 and ("fails as it must (" .. af .. " cases)") or "STILL PASSES"))
      if af == 0 then bad[#bad + 1] = a[1] end
    end
  end
  cleanup()
  print("PANORAMA_CASES_LUA ARMS " .. (#bad > 0 and ("FAIL (" .. table.concat(bad, ", ") .. ")") or "PASS"))
  os.exit(#bad > 0 and 1 or 0)
end

cleanup()
print("PANORAMA_CASES_LUA RESULT " .. (fails > 0 and ("FAIL (" .. fails .. " of " .. n .. ")") or ("PASS (" .. n .. " checks)")))
os.exit(fails > 0 and 1 or 0)
