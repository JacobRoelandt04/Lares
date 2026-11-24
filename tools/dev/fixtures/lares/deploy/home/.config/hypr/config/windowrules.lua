-- General
hl.window_rule({
    name = "fullscreen",
    match = {
        fullscreen = true
    },
    opaque = true,
    border_size = 0,
    rounding = 0
})

hl.window_rule({
    name = "content_types",
    match = {
        content = "game|photo|video",
    },
    opaque = true,
    border_size = 0,
    rounding = 0
})

hl.window_rule({
    name = "floating_shadow",
    match = {
        float = true
    },
    no_shadow = false
})

hl.window_rule({
    name = "tiled_shadow",
    match = {
        float = false
    },
    no_shadow = true
})

hl.window_rule({
    name = "modal_floating_focused",
    match = {
        modal = true
    },
    float = true,
    stay_focused = true
})

-- Content
hl.window_rule({
    name = "game_content",
    match = {
        class = "steam_app_.*"
    },
    content = "game"
})

hl.window_rule({
    name = "libreoffice-tiling-fix",
    match = {
        class = "^(libreoffice.*|soffice\\.bin)$",
    },
    tile = true,
    suppress_event = "maximize fullscreen x11configurerequest",
})

-- Workspace
hl.window_rule({
    name = "special_workspace_assignment",
    match = {
        class = "vesktop|Proton Mail|Proton Pass|protonvpn-app"
    },
    no_initial_focus = true,
    workspace = "special:default silent"
})
-- Apps
hl.window_rule({
    name = "bluetooth_manager",
    match = {
        class = "blueman-manager"
    },
    float = true,
    size = {"monitor_w * 0.25", "monitor_h * 0.2"}  
})

hl.window_rule({
    name = "btop/nvtop",
    match = {
        class = "kitty",
        title = "btop|nvtop"
    },
    float = true,
    min_size = { 880, 864 },
    size = {880, 864},
    move = { 12, "monitor_h - window_h - 12"},
})

hl.window_rule({
    name = "discord",
    match = {
        class = "vesktop"
    },
    no_initial_focus = true,
    workspace = "special:default silent"
})

hl.window_rule({
    name = "evince",
    match = {
        class = "org.gnome.Evince"
    },
    opaque = true
})

hl.window_rule({
    name = "libreoffice",
    match = {
        class = "libreoffice|libreoffice-base|libreoffice-calc|libreoffice-draw|libreoffice-impress|libreoffice-math|libreoffice-writer|"
    },
    opaque = true
})

hl.window_rule({
    name = "loupe",
    match = {
        class = "org.gnome.Loupe"
    },
    opaque = true
})

hl.window_rule({
    name = "networkmanager_connection_editor",
    match = {
        class = "nm-connection-editor"
    },
    float = true,
    size = {"monitor_w * 0.1", "monitor_h * 0.14"}
})

hl.window_rule({
    name = "nwg_look",
    match = {
        class = "nwg-look"
    },
    float = true,
    min_size = { 600, 900},
    size = { 600, 900}
})

-- qs-shell deploy: hl.window_rule({
    -- qs-shell deploy: name = "polkit-auth",
    -- qs-shell deploy: match = {
        -- qs-shell deploy: class = "polkit-gnome-authentication-agent-1",
        -- qs-shell deploy: title = "Authenticate"
    -- qs-shell deploy: },
    -- qs-shell deploy: stay_focused = true
-- qs-shell deploy: })

hl.window_rule({
    name = "pulseaudio_volume_control",
    match = {
        class = "org.pulseaudio.pavucontrol"
    },
    float = true,
    size = {"monitor_w * 0.2", "monitor_h * 0.6"},
    move = {"(monitor_w * 0.8) - 12", 46}
})

hl.window_rule({
    name = "quickshell_dev",
    match = {
        class = "org.quickshell"
    },
    opaque = true,
    workspace = "special:default silent"
})

hl.window_rule({
    name = "rlr",
    match = {
        class = "rlr"
    },
    float = true,
    border_size = 0,
    size  ={ 450, 75 }
})

hl.window_rule({
    name = "windows_vm",
    match = {
        class = "Microsoft Windows"
    },
    opaque = true
})

hl.window_rule({
    name = "yazi",
    match = {
        class = "kitty",
        title = "yazi"
    },
    animation = "gnomed",
    float = true,
    border_size = 0,
    size = {"monitor_w * 0.3", "monitor_h * 0.18"},
    move = { "(monitor_w * 0.7) - 9", "(monitor_h * 0.82) - 9" },
    tag = "+hyprglass_enabled"
})

hl.window_rule({
    name = "zen_browser_opaque",
    match = {
        class = "zen",
        title = ".*YouTube.*|.*Netflix.*|.*Twitch.*|.*Prime Video.*"
    },
    opaque = true
})
