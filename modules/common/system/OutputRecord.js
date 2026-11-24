.pragma library

// =============================================================================
// OutputRecord.js -- one entry of `hyprctl -j monitors all` as the panorama contract's Output record
// (docs/contracts/panorama.md section 1). Pure; FocusedScreen holds the list. No Qt.
//
//   build(m, all)      the Output of one monitor object; `all` is the whole list (mirrorOf names its source by id: FACT F10)
//   isMirror(m)        the monitor mirrors another (only `monitors all` lists it)
//   isIgnored(name)    the lock's hop and Hyprland's own fallback output: never an output of ours
//   parseModes(list)   ["2880x1620@120.00Hz", ...] -> [{ w, h, r, preferred }] (the first is the preferred one)
//   fill(partial)      a fake's record with the defaults of a plain output
//
// `driver` is "" here: DrmWatch knows the driver of a connector, and whoever joins the two fills it.
// =============================================================================

var IGNORED = ["LARESLOCK-HOP", "FALLBACK"];

function isIgnored(name) {
    return IGNORED.indexOf(String(name)) >= 0;
}

function isMirror(m) {
    var v = m.mirrorOf;
    return v !== undefined && v !== null && v !== "none" && v !== "" && v !== -1;
}

function parseModes(list) {
    var out = [];
    if (!Array.isArray(list) && !(list && list.length !== undefined))
        return out;
    for (var i = 0; i < list.length; i++) {
        var k = /^(\d+)x(\d+)@([0-9.]+)Hz$/.exec(String(list[i]));
        if (k)
            out.push({ w: Number(k[1]), h: Number(k[2]), r: Number(k[3]), preferred: out.length === 0 });
    }
    return out;
}

function _sourceName(v, all) {
    if (!isMirror({ mirrorOf: v }))
        return "";
    for (var i = 0; i < all.length; i++)
        if (String(all[i].id) === String(v))
            return String(all[i].name);
    // already a name (a Hyprland that says so): keep it when it names a listed monitor
    for (var j = 0; j < all.length; j++)
        if (all[j].name === v)
            return String(v);
    return "";
}

function build(m, all) {
    var hw = m.hardwareDetails || {};
    var fmt = String(m.currentFormat || "");
    return {
        name: String(m.name),
        description: String(m.description || ""),
        make: String(m.make || ""),
        model: String(m.model || ""),
        serial: String(m.serial || ""),
        id: Number(m.id),
        enabled: m.disabled !== true,
        width: Number(m.width),
        height: Number(m.height),
        refresh: Number(m.refreshRate),
        x: Number(m.x),
        y: Number(m.y),
        scale: Number(m.scale),
        transform: Number(m.transform || 0),
        mirrorOf: _sourceName(m.mirrorOf, all),
        physW: Number(m.physicalWidth || 0),
        physH: Number(m.physicalHeight || 0),
        modes: parseModes(m.availableModes),
        backend: String(hw.backend || ""),
        hdr: hw.hdr === true,
        bt2020: hw.bt2020 === true,
        vrrCapable: hw.vrrCapable === true,
        vrr: m.vrr === true ? 1 : (typeof m.vrr === "number" ? m.vrr : 0),
        bitdepth: fmt.indexOf("2101010") >= 0 ? 10 : 8,
        cm: String(m.colorManagementPreset || ""),
        sdrbrightness: m.sdrBrightness !== undefined ? Number(m.sdrBrightness) : 1,
        sdrsaturation: m.sdrSaturation !== undefined ? Number(m.sdrSaturation) : 1,
        driver: ""
    };
}

function fill(p) {
    var o = {
        name: String(p.name), description: "", make: "", model: "", serial: "", id: 0, enabled: true, width: 1920, height: 1080,
        refresh: 60, x: 0, y: 0, scale: 1, transform: 0, mirrorOf: "", physW: 0, physH: 0, modes: [], backend: "drm", hdr: false,
        bt2020: false, vrrCapable: false, vrr: 0, bitdepth: 8, cm: "srgb", sdrbrightness: 1, sdrsaturation: 1, driver: ""
    };
    for (var k in p)
        if (k in o)
            o[k] = p[k];
    return o;
}
