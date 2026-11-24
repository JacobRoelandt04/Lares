-- A fixture shaped like the user's hyprland.lua (2026-11-21): the require list, monitors third.
require("config/autostart")
require("config/environment")
require("config/monitors")
require("config/animations")
pcall(require, "config/theme")   -- themectl (guarded: a missing theme.lua is not an error)
require("config/keybinds")
