.pragma library

// =============================================================================
// NetGlyphParts.js
//
// kind -> the parts of a piece of network hardware. Pure: numbers in, an array
// of numbers out, nothing themed (the shader resolves every colour from a
// colour INDEX, so a composition never carries a colour a theme switch would
// have to re-evaluate -- and a Repeater's model may never hold one at all).
//
// A part is eight numbers, the two vec4 uniforms the shader takes for it:
//
//     [type, cx, cy, s,   p1, p2, p3, colour]
//
// in the unit square (y DOWN) that NetGlyph's `size` scales. Types and colours
// are the shader's (shaders/net_glyph.frag). Slot 0 is the BACK, so a cavity
// comes after the shell it sits in and a lit pip after the body it sits on. At
// most `maxParts`.
//
// WHAT THESE ARE -- and what they are NOT.
//
// They are not the real components (an SMA connector with a whip, a keyswitch,
// an access point, a breaker, a bluetooth CARD): those read as too literal,
// and what is wanted is abstraction and visual play. The one real object is
// the RJ45 jack, because a port IS the universal sign for a wired network: it
// is not a photograph of a component, it is the thing everyone already
// pictures.
//
// So the family is: THE UNIVERSAL SYMBOL FOR EACH FUNCTION, BUILT AS A
// PHYSICAL OBJECT. The wifi fan is a stack of solid arcs standing on a base,
// not an antenna. A hotspot is a core pushing out whole rings -- omni, where
// the fan is directional, which is what keeps the two apart. A VPN is a
// padlock whose shackle is a CABLE, so one object says both network and
// secure, and open-versus-shut is a real movement rather than a colour. The
// master switch is a domed button that stands proud or sits pressed. And
// bluetooth is its own rune, machined into a badge -- the symbol as metal.
// A bay with no hardware shows the GHOST of the socket that is missing,
// because an empty hole reads as a fault while a faded jack reads as "this
// machine has no ethernet".
// =============================================================================

var T = { BOX: 0, KEYSTONE: 1, COMB: 2, DISC: 3, RING: 4, ARC: 5,
          HEXNUT: 6, MEANDER: 7, CAPSULE: 8, SCREW: 9, SHACKLE: 10 };

var C = { SHELL: 0, SHELL_DARK: 1, CONTACT: 2, LAMP_OFF: 3, PCB: 4, TRACE: 5,
          BRASS: 6, BEZEL: 7, LAMP_WARN: 8, PLATE: 9, LAMP_LINK: 10, LAMP_ACT: 11 };

var maxParts = 8;

// Below this many DEVICE pixels a comb halves its count. Eight RJ45 contacts
// on a 36 px jack sit 2.6 px apart, which is the last size they still read at.
var smallPx = 36;

// ---- helpers ---------------------------------------------------------------

function box(cx, cy, hw, hh, r, colour, rotTurns) {
    return [T.BOX, cx, cy, r, hw, hh, rotTurns || 0, colour];
}
function keystone(cx, cy, hw, hh, r, tabHw, colour) {
    return [T.KEYSTONE, cx, cy, r, hw, hh, tabHw, colour];
}
function comb(cx, cy, toothHw, halfLen, pitch, count, colour) {
    return [T.COMB, cx, cy, toothHw, halfLen, pitch, count, colour];
}
function disc(cx, cy, r, colour) {
    return [T.DISC, cx, cy, r, 0, 0, 0, colour];
}
function ring(cx, cy, r, hw, colour) {
    return [T.RING, cx, cy, r, hw, 0, 0, colour];
}
// `rotTurns` 0.5 points the arc's mouth up the screen: the unit square's y
// runs down.
function arc(cx, cy, r, hw, apTurns, rotTurns, colour) {
    return [T.ARC, cx, cy, r, hw, apTurns, rotTurns, colour];
}
function capsule(ax, ay, bx, by, r, colour) {
    return [T.CAPSULE, ax, ay, r, bx, by, 0, colour];
}
function shackle(cx, cy, r, hw, legL, openF, colour) {
    return [T.SHACKLE, cx, cy, r, hw, legL, openF, colour];
}

// ---- wired: the port, which is already the symbol --------------------------
// The notched shell, the dark cavity, the comb of contacts hanging from its
// roof, and the two lamp lenses in the band below.
function wired(small) {
    var parts = [];
    parts.push(keystone(0.50, 0.560, 0.360, 0.280, 0.045, 0.115, C.SHELL));
    parts.push(keystone(0.50, 0.495, 0.285, 0.185, 0.030, 0.075, C.SHELL_DARK));
    if (small)
        parts.push(comb(0.50, 0.405, 0.027, 0.070, 0.1430, 4, C.CONTACT));
    else
        parts.push(comb(0.50, 0.405, 0.016, 0.070, 0.0715, 8, C.CONTACT));
    parts.push(disc(0.280, 0.765, 0.050, C.LAMP_OFF));
    parts.push(disc(0.720, 0.765, 0.050, C.LAMP_OFF));
    return parts;
}
var wiredLamps = [{ cx: 0.280, cy: 0.765, r: 0.042 },
                  { cx: 0.720, cy: 0.765, r: 0.042 }];

// ---- wifi: the fan, as solid arcs on a base --------------------------------
// The dot is level 1 and each arc one more, which is the meter everybody
// already reads. `radio`: "on" | "off" (the fan unlit, a dark bar struck
// across it) | "blocked" (the bar in the warning colour).
function wifi(level, lit, radio) {
    var parts = [];
    var live = radio === "on";
    parts.push(box(0.500, 0.905, 0.160, 0.042, 0.021, C.SHELL, 0));
    parts.push(disc(0.500, 0.780, 0.058, live && level >= 1 ? lit : C.LAMP_OFF));
    // The fan is ALWAYS drawn. Taking it away for "off" would leave a base and
    // a dot with nothing above them, which reads as a socket that failed to
    // render rather than as a radio that is switched off; a struck-through fan
    // reads as off at any size.
    var radii = [0.170, 0.300, 0.430];
    for (var i = 0; i < radii.length; i++)
        parts.push(arc(0.500, 0.780, radii[i], 0.052, 0.155, 0.5,
                       live && level >= i + 2 ? lit : C.LAMP_OFF));
    if (!live)
        parts.push(capsule(0.190, 0.880, 0.810, 0.330, 0.054,
                           radio === "blocked" ? C.LAMP_WARN : C.SHELL_DARK));
    return parts;
}

// ---- hotspot: a core pushing out whole rings -------------------------------
// Rings, not a sector. The fan is directional and means "what I can hear";
// this is omnidirectional and means "what I am putting out".
function hotspot(lit, on) {
    var c = on ? lit : C.LAMP_OFF;
    return [ring(0.500, 0.500, 0.400, 0.050, c),
            ring(0.500, 0.500, 0.255, 0.050, c),
            disc(0.500, 0.500, 0.115, C.SHELL),
            disc(0.500, 0.500, 0.060, on ? lit : C.LAMP_OFF)];
}
var hotspotLamp = { cx: 0.500, cy: 0.500, r: 0.052 };

// ---- vpn: a padlock whose shackle is a cable -------------------------------
// One object saying both NETWORK and SECURE, and the state is a movement: the
// cable lifts out of the body and its near leg unhooks. `shut` is 1 closed,
// 0 open, so arming is one eased number.
function vpn(shut, present) {
    var parts = [];
    var openF = 1 - Math.max(0, Math.min(1, shut));
    // No profile to shut: the cable is there but DEAD and hanging open, which
    // says "nothing to lock". A body on its own is a rounded box and says
    // nothing at all.
    // The travel has to be worth seeing: at 0.075 of the square the lift would
    // be three pixels at 44 px and open would look the same as shut.
    var lift = present ? openF : 1;
    parts.push(shackle(0.500, 0.400 - 0.150 * lift, 0.175, 0.052,
                       0.220 + 0.150 * lift, lift,
                       present ? C.SHELL_DARK : C.LAMP_OFF));
    parts.push(box(0.500, 0.680, 0.265, 0.205, 0.062, C.SHELL, 0));
    parts.push(disc(0.500, 0.680, 0.062, C.LAMP_OFF));
    return parts;
}
var vpnLamp = { cx: 0.500, cy: 0.680, r: 0.054 };

// ---- master: a domed button that stands proud or sits pressed --------------
function master(down) {
    return [ring(0.500, 0.500, 0.330, 0.070, C.BEZEL),
            disc(0.500, 0.500, down ? 0.232 : 0.262, down ? C.SHELL_DARK : C.SHELL),
            disc(0.500, 0.500, 0.078, C.LAMP_OFF)];
}
var masterLamp = { cx: 0.500, cy: 0.500, r: 0.068 };

// ---- bluetooth: the rune, machined ----------------------------------------
// The bind rune itself, as five bars of metal: a stem, and two polylines
// crossing it. The symbol IS the object, not a picture of a bluetooth card.
function bt(lit, on) {
    var c = on ? lit : C.SHELL;
    var w = 0.056;
    return [capsule(0.500, 0.070, 0.500, 0.930, w, c),
            capsule(0.500, 0.070, 0.742, 0.293, w, c),
            capsule(0.742, 0.293, 0.258, 0.707, w, c),
            capsule(0.500, 0.930, 0.742, 0.707, w, c),
            capsule(0.742, 0.707, 0.258, 0.293, w, c)];
}

// ---- a bay with nothing in it ---------------------------------------------
// The ghost of the socket that is missing, in the plate's own material. An
// empty hole reads as a fault; a faded jack reads as "no ethernet here". The
// host draws it at reduced opacity.
function ghost(kind, small) {
    var parts = compose(kind, { level: 4, radio: "on", shut: 1, present: true, on: true }, small ? 1 : 999);
    var out = [];
    for (var i = 0; i < parts.length; i++) {
        var q = parts[i].slice();
        q[7] = C.PLATE;
        out.push(q);
    }
    return out;
}

function lamp(colour) {
    return [disc(0.5, 0.5, 0.42, colour)];
}

// ---- compose ---------------------------------------------------------------
// o: { level, radio, shut, present, on, down, ghost, colour }
function compose(kind, o, devSize) {
    var small = devSize < smallPx;
    var opts = o || {};
    var lit = typeof opts.colour === "number" ? opts.colour : C.LAMP_LINK;
    var parts;
    switch (kind) {
    case "wired":
        parts = wired(small);
        break;
    case "wifi":
        parts = wifi(Math.max(0, Math.min(4, opts.level || 0)), lit, opts.radio || "on");
        break;
    case "hotspot":
        parts = hotspot(lit, !!opts.on);
        break;
    case "vpn":
        parts = vpn(typeof opts.shut === "number" ? opts.shut : 0, opts.present !== false);
        break;
    case "master":
        parts = master(!!opts.down);
        break;
    case "bt":
        parts = bt(lit, !!opts.on);
        break;
    case "blank":
        parts = ghost(opts.ghost || "wired", small);
        break;
    case "lamp":
        parts = lamp(lit);
        break;
    default:
        parts = [];
        break;
    }
    return parts.slice(0, maxParts);
}

// Where a kind's lamps are, in its own unit square: the plate places a lamp
// quad by these rather than repeating the numbers. A kind whose own parts
// carry the colour (the fan, the rune) has none.
function lampsOf(kind) {
    switch (kind) {
    case "wired":   return wiredLamps;
    case "vpn":     return [vpnLamp];
    case "hotspot": return [hotspotLamp];
    case "master":  return [masterLamp];
    default:        return [];
    }
}
