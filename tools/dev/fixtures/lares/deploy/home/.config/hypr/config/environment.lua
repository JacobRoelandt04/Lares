-- Cursors
hl.env("HYPRCURSOR_THEME", "Nordzy-cursors-white")
hl.env("HYPRCURSOR_SIZE", 36)
hl.env("XCURSOR_THEME", "Nordzy-cursors-white")
hl.env("XCURSOR_SIZE", 36)

-- Qt file dialogs go through the xdg portal, which on this desktop is
-- xdg-desktop-portal-termfilechooser -> yazi in kitty. Without this Qt has no
-- platform theme and falls back to its own built-in QML file dialog.
hl.env("QT_QPA_PLATFORMTHEME", "xdgdesktopportal")
-- (The portal registration warning that theme causes is silenced in
-- ~/.config/QtProject/qtlogging.ini, which every Qt app reads on its own --
-- an env line here with an "=" in its value never reached the session.)

-- Theme
hl.env("ADW_DISABLE_PORTAL", "1")

-- XDG
hl.env("XDG_CURRENT_DESKTOP", "Hyprland")
hl.env("XDG_SESSION_TYPE", "wayland")
hl.env("XDG_SESSION_DESKTOP", "Hyprland")

-- Force Wayland on Electron 28+ apps (Postman, VS Code, Signal, Vesktop, Obsidian, Slack, etc.)
hl.env("ELECTRON_OZONE_PLATFORM_HINT", "auto")

-- Force Wayland for Qt applications (falls back to X11 if unsupported)
hl.env("QT_QPA_PLATFORM", "wayland;xcb")
hl.env("QT_AUTO_SCREEN_SCALE_FACTOR", "1")

-- Force Wayland for GTK applications
hl.env("GDK_BACKEND", "wayland,x11")
-- GTK 4 defaults to Vulkan, whose start costs ~2.1 s here (the NVIDIA ICD), every launch
hl.env("GSK_RENDERER", "ngl")

-- Force Wayland for SDL games / engines
hl.env("SDL_VIDEODRIVER", "wayland,x11")
-- Clutter backend
hl.env("CLUTTER_BACKEND", "wayland")
-- qs-shell deploy BEGIN env: bare `quickshell ipc ...` (shot.sh, the hyprlock wrapper) reaches the deployed shell
hl.env("QS_CONFIG_PATH", "/home/user/.local/state/lares/shell/current/shell.qml")
-- qs-shell deploy END env
