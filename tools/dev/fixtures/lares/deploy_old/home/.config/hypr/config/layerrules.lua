hl.layer_rule({
    name = "wallpaper_selector",
    match = {
        namespace = "wallpaper_selector"
    },
    xray = true,
    blur = true,
    ignore_alpha = true
})

hl.layer_rule({ name = "screenshot_selection", match = { namespace = "^selection$" }, no_anim = true })
-- qs-shell deploy BEGIN layers: the shell's layer surfaces do not fade in and out (tools/shell/qs-shell LAYER_RULES_TABLE; the lock's above_lock rule stays its supervisor's, set at each lock)
hl.layer_rule({ name = "qs_bar_noanim", match = { namespace = "^qs-bar$" }, no_anim = true })
hl.layer_rule({ name = "qs_osd_pill_noanim", match = { namespace = "^osd-pill$" }, no_anim = true })
hl.layer_rule({ name = "qs_auth_pill_noanim", match = { namespace = "^auth-pill$" }, no_anim = true })
hl.layer_rule({ name = "qs_curtain_noanim", match = { namespace = "^qs-curtain$" }, no_anim = true })
hl.layer_rule({ name = "qs_toast_pill_noanim", match = { namespace = "^toast-pill$" }, no_anim = true })
-- qs-shell deploy END layers
