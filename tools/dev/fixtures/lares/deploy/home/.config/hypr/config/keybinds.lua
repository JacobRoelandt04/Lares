local function toggle_special_window()
    local win = hl.get_active_window()
    if not win then return end
    
    if win.workspace.name == "special:default" then
        local active_ws = hl.get_active_workspace()
        hl.dispatch(hl.dsp.window.move({ workspace = active_ws.name }))
    else
        hl.dispatch(hl.dsp.window.move({ workspace = "special:default", follow = false }))
    end
end

local function smart_focus(dir)
    local win = hl.get_active_window()
    if not win then return end

    if win.group ~= nil then
        local dispatcher
        local fallback_arg
        if dir == "l" then
            dispatcher = hl.dsp.group.prev or hl.dsp.group.change_active
            fallback_arg = "b"
        else
            dispatcher = hl.dsp.group.next or hl.dsp.group.change_active
            fallback_arg = "f"
        end

        if type(dispatcher) == "function" then
            hl.dispatch(dispatcher())
        elseif type(dispatcher) == "table" then
            hl.dispatch(dispatcher)
        else
            hl.dispatch(hl.dsp.exec_cmd("hyprctl dispatch changegroupactive " .. fallback_arg))
        end
    else
        hl.dispatch(hl.dsp.focus({ direction = dir }))
    end
end

-- Window Managment
hl.bind("SUPER + down", hl.dsp.window.close())
hl.bind("SUPER + Z",    hl.dsp.window.float())
hl.bind("SUPER + F",    hl.dsp.window.fullscreen())
hl.bind("SUPER + T",    hl.dsp.window.set_prop({ window = "active", prop = "opaque", value = "toggle" }))
hl.bind("SUPER + mouse:272",            hl.dsp.window.drag(),   { mouse = true})
hl.bind("SUPER + SHIFT + mouse:272",    hl.dsp.window.resize(), { mouse = true})
hl.bind("SUPER + left",  function() smart_focus("l") end, { repeating = true })
hl.bind("SUPER + right", function() smart_focus("r") end, { repeating = true })

-- Group Managment
hl.bind("SUPER + G",        hl.dsp.group.toggle())
hl.bind("SUPER + CTRL + G", hl.dsp.group.lock())

-- Workspace Navigation
for i = 1, 4 do
    hl.bind("SUPER + " .. i, hl.dsp.focus({ workspace = i}))
end
for i = 1, 4 do
    hl.bind("SUPER + SHIFT + " .. i, hl.dsp.window.move({ workspace = i, follow = false}))
end
hl.bind("SUPER + ESCAPE",           hl.dsp.workspace.toggle_special("default"))
hl.bind("SUPER + SHIFT + ESCAPE",   toggle_special_window)

-- Apps
hl.bind("SUPER + up",               hl.dsp.exec_cmd("kitty --hold fastfetch"))
hl.bind("SUPER + SHIFT + up",       hl.dsp.exec_cmd("zen-browser"))
hl.bind("SUPER + E",                hl.dsp.exec_cmd("kitty -o background_opacity=0.75 --title yazi sh -c 'yazi'"))
hl.bind("CTRL + SHIFT + ESCAPE",    hl.dsp.exec_cmd("kitty --title btop sh -c 'btop'"))
hl.bind("CTRL + SHIFT + code:49",   hl.dsp.exec_cmd("kitty --title nvtop sh -c 'nvtop'"))

-- Shell
hl.bind("SUPER + F2",           hl.dsp.global("lares:bars"))
hl.bind("SUPER + SHIFT + F12",  hl.dsp.exec_cmd("'/home/user/.local/state/lares/shell/current/tools/shell/lares' fallback --reason 'panic bind'"))

-- Util
hl.bind("ALT + SPACE",          hl.dsp.global("lares:launcher"))
hl.bind("ALT + V",              hl.dsp.global("lares:clipboard"))
hl.bind("ALT + N",              hl.dsp.global("lares:notes"))
hl.bind("XF86Launch5",          hl.dsp.global("lares:dictate"))
hl.bind("SHIFT + XF86Launch5",  hl.dsp.global("lares:dictate-nl"))
hl.bind("CTRL + XF86Launch5",   hl.dsp.global("lares:dictate-source"))
hl.bind("ALT + XF86Launch5",    hl.dsp.global("lares:dictate-ask"))
hl.bind("SUPER + C",            hl.dsp.exec_cmd("hyprpicker -aq -u 700 -s 2"))
hl.bind("ALT + PERIOD",         hl.dsp.global("lares:picker"))
hl.bind("SUPER + SHIFT + S",    hl.dsp.exec_cmd("/home/user/.local/state/lares/shell/current/tools/osd/shot.sh region"))

-- Hardware
hl.bind("XF86AudioRaiseVolume", hl.dsp.global("lares:osd-volume-up"), { locked = true })
hl.bind("XF86AudioLowerVolume", hl.dsp.global("lares:osd-volume-down"), { locked = true })
hl.bind("XF86AudioMute",        hl.dsp.global("lares:osd-volume-mute"), { locked = true })
hl.bind("XF86AudioMicMute",     hl.dsp.global("lares:osd-mic-mute"), { locked = true })
hl.bind("XF86MonBrightnessUp",              hl.dsp.global("lares:osd-brightness-up"), { locked = true })
hl.bind("XF86MonBrightnessDown",            hl.dsp.global("lares:osd-brightness-down"), { locked = true })
hl.bind("SHIFT + XF86MonBrightnessUp",      hl.dsp.global("lares:osd-brightness-up-fine"), { locked = true })
hl.bind("SHIFT + XF86MonBrightnessDown",    hl.dsp.global("lares:osd-brightness-down-fine"), { locked = true })
hl.bind("XF86KbdBrightnessUp",      hl.dsp.global("lares:osd-kbd-up"), { locked = true })
hl.bind("XF86KbdBrightnessDown",    hl.dsp.global("lares:osd-kbd-down"), { locked = true })

-- Audio
hl.bind("XF86AudioNext",    hl.dsp.global("lares:osd-media-next"), { locked = true })
hl.bind("XF86AudioPrev",    hl.dsp.global("lares:osd-media-prev"), { locked = true })
hl.bind("XF86AudioPlay",    hl.dsp.global("lares:osd-media-toggle"), { locked = true })
hl.bind("XF86AudioPause",   hl.dsp.global("lares:osd-media-toggle"), { locked = true })
hl.bind("XF86AudioStop",    hl.dsp.global("lares:osd-media-stop"), { locked = true })

-- Misc
hl.bind("Caps_Lock",    hl.dsp.global("lares:osd-lockkeys"), { non_consuming = true })
hl.bind("Num_Lock",     hl.dsp.global("lares:osd-lockkeys"), { non_consuming = true })