-- A fixture shaped like the user's monitors.lua (2026-11-21)
-- Internal laptop screen
hl.monitor({
    output = "eDP-1",
    mode = "2880x1620@120",
    position = "0x0",
    scale = 1.25,
    bitdepth = 10,
    -- cm = "hdr",
})

-- External monitor (DVI-I-1)
hl.monitor({
    output = "DVI-I-1",
    mode = "3440x1440@60",
    position = "-280x-1440",
    scale = 1
})

-- External monitor (HDMI-A-1)
hl.monitor({
    output = "HDMI-A-1",
    mode = "preferred",
    position = "auto",
    scale = 1,
    mirror = "eDP-1"
})

-- hl.monitor({
--     output = "HDMI-A-1",
--     position = "2304x0",
-- })

hl.workspace_rule({
    workspace = "3",
    monitor = "HDMI-A-1",
    default = true
})
