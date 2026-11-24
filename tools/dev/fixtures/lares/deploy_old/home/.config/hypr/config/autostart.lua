local wallpaper =   "hyprpaper"
local idle =        "hypridle"
local cursor =      "Nordzy-cursors-white"
local cursorSize =  "36"

hl.on("hyprland.start", function()
    -- qs-shell deploy BEGIN autostart: the Quickshell lock at boot (it does nothing when SDDM's --locked-cmd locked first), the shell under its supervisor, the geoclue agent, the theme (themectl), the lock's shader cache
    hl.exec_cmd("/home/user/.local/state/quickshell/lock/current/tools/lockscreen/qs-lock-session --boot")
    hl.exec_cmd("/home/user/.local/state/quickshell/shell/current/tools/shell/qs-shell start")
    hl.exec_cmd("/usr/lib/geoclue-2.0/demos/agent")
    hl.exec_cmd("/home/user/.local/state/quickshell/shell/current/tools/theme/themectl apply")
    hl.exec_cmd("/home/user/.local/state/quickshell/lock/current/tools/lockscreen/qs-lock-warm --if-stale")
    -- qs-shell deploy END autostart
    -- core
    hl.exec_cmd("systemctl --user reset-failed xdg-desktop-portal-hyprland.service xdg-desktop-portal.service")
    hl.exec_cmd("hyprctl plugin load " .. os.getenv("HOME") .. "/.local/lib/hyprland-plugins/hypr-group-tabs/hypr-group-tabs.so")
    hl.exec_cmd(wallpaper)
    hl.exec_cmd(idle)
    -- misc
    hl.exec_cmd("mpc clear")
    -- qs-shell deploy: hl.exec_cmd("~/.config/hypr/scripts/hyproled/hyproled-watcher.sh")
    hl.exec_cmd("kdeconnect-indicator")
    hl.exec_cmd("mpddiscordrpc")
    -- visual
    hl.exec_cmd("hyprctl setcursor " .. cursor .. " " .. cursorSize)
end)
