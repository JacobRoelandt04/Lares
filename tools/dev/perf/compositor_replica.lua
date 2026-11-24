-- compositor_replica.lua -- what the user's own Hyprland draws under every shell frame, for tools/dev/perf/frame_split.sh
-- (HYPR_EXTRA=tools/dev/perf/compositor_replica.lua WINDOWS=3): the decoration block of his appearance.lua as it stood on
-- 2026-11-23 (translucent windows over a blurred ground, shadows). The values are a COPY for a nested measurement: his file is
-- never read by a runner and never written. `decor-off` is the same run without this file.
hl.config({
    decoration = {
        rounding = 14,
        active_opacity = 0.94,
        inactive_opacity = 0.86,
        blur = { size = 10, passes = 4, noise = 0.1, brightness = 1.25, vibrancy = 0.25, vibrancy_darkness = 0.2,
                 special = true, popups = true, input_methods = true, xray = true },
        shadow = { enabled = true, range = 30, render_power = 4 },
    },
})
