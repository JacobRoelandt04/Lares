.pragma library
.import "../scene/IsoCamera.js" as Cam
.import "../../common/board/BoardLayout.js" as BL

// =============================================================================
// PopupLayout.js -- where the popup's flat overlays and its zones are, from the SAME camera and the SAME
// geometry the scene draws with (SceneGeometry.json() / IsoCamera.fit; the generic helpers are the board toolkit's, modules/common/board/BoardLayout.js): a caption follows its zone because
// it is placed at a projected board point, never at a number of its own. Pure, no Qt.
//
//   anchorPx(G, cam, name)               a SceneGeometry anchor in item px
//   zoneRegions(G, cam, rects)           { cpu: [polygon], gpu: [polygon] }: what is "over" each zone
//   zoneAt(regions, x, y)                "cpu" | "gpu" | ""
//   intentOf(G, part)                    what a click on a part of the board means
//   partAnchor(G, cam, intent)           where the secondary hangs from, in item px
//   partBox(G, cam, name)                a board part's projected bounding box { x, y, w, h } in item px, or null
//   dipTagPoint(G, cam)                  where the battery error's tag hangs: the DIP switch's near right corner
//   holoTop(G, cam, name)                the screen y of the top edge of a hologram's plane (a plate hugs it)
//   holoRegions(G, cam)                  { cpu: [polygon], gpu: [polygon], ghost: polygon }: where a hologram is DRAWN
//   holoIntentAt(G, cam, x, y, presence) what a click on a hologram means: the zone's settings, as a click on its die does
//
// A ZONE is the part of the popup its swipe and its arrows belong to: the footprint of what it holds on
// the board (the CPU's square, the card and its slot, padded), the hologram's plane above it and its
// name plate. The pack, the DIP switch and the jack belong to no zone: a swipe over them does nothing.
// =============================================================================

var PAD_MM = 6;

var _proj = BL.proj;
var _poly = BL.poly;
var _rect = BL.rectPoly;
var _footprint = BL.footprint;
function anchorPx(G, cam, name) {
    return BL.anchorPx(G, cam, name);
}
function inPoly(poly, x, y) {
    return BL.inPoly(poly, x, y);
}
function inRegion(polys, x, y) {
    return BL.inRegion(polys, x, y);
}

// rects: { cpu: {x, y, w, h}, gpu: {x, y, w, h} } -- the two name plates, which belong to their zones
function zoneRegions(G, cam, rects) {
    var Z = G.ZONE, e = Z.half + PAD_MM, C = G.CARD, p = PAD_MM;
    var cardTop = C.rest + C.pcb + 3;
    var cpu = [
        _footprint(cam, Z.cx - e, Z.cz - e, Z.cx + e, Z.cz + e, 0),
        _rect(Cam.holoRect(G.ANCHORS.cpuHolo, cam, Cam.HOLO.w, Cam.HOLO.base, Cam.HOLO.h, 10), 0),
        _rect(rects.cpu, 8)
    ];
    var gpu = [
        _footprint(cam, C.x0 - p, C.z0 - p, C.x1 + p, C.z1 + p, 0),
        _footprint(cam, C.x0 - p, C.z0 - p, C.x1 + p, C.z1 + p, cardTop),
        _rect(Cam.holoRect(G.ANCHORS.gpuHolo, cam, Cam.HOLO.w, Cam.HOLO.base, Cam.HOLO.h, 10), 0),
        _rect(rects.gpu, 8)
    ];
    return { cpu: cpu, gpu: gpu };
}

function zoneAt(regions, x, y) {
    return BL.zoneAt(regions, x, y, ["cpu", "gpu"]);
}

// What a click on the board's part `name` means: the package opens the CPU's tuning, the card (and the slot
// it sits in, which is all that is left of it in Integrated) the GPU's settings, the DIP switch flips the
// charge limit. Everything else on the board is only drawn.
function intentOf(G, name) {
    if (!name)
        return "";
    var group = BL.groupOf(G, name);
    if (group === "pkg")
        return "tuning";
    if (group === "card" || group === "hdmi" || name === "slot" || name === "latch")
        return "gpu";               // (the HDMI plug stands in the card's port: it is the card's)
    if (group === "lever" || name === "dipBody")
        return "limit";
    return "";
}

// where each intent's part sits (item px): the secondary opens at the part that was clicked
function partAnchor(G, cam, intent) {
    if (intent === "tuning")
        return anchorPx(G, cam, "cpuHolo");
    if (intent === "gpu") {
        var C = G.CARD;
        return _proj(cam, [(C.x0 + C.x1) / 2, C.rest + C.pcb, (C.z0 + C.z1) / 2]);
    }
    var D = G.DIP;
    return _proj(cam, [(D.x0 + D.x1) / 2, D.h, (D.z0 + D.z1) / 2]);
}

function partBox(G, cam, name) {
    return BL.partBox(G, cam, name);
}

// Where the battery error's tag hangs, item px: the DIP switch's near right ground corner (its +x, +z corner, the one
// nearest the viewer on the side the plug is on). The tag's own top-left corner goes a little right of and below it.
function dipTagPoint(G, cam) {
    var D = G.DIP;
    return _proj(cam, [D.x1, 0, D.z1]);
}

// The screen y of the top edge of a hologram's plane (HOLO), item px: the line a name plate's text foot stands above (the text bunch hugs the hologram's top edge). `name` is an anchor: "cpuHolo" | "gpuHolo". The two planes stand at different heights (the card's die is
// 5 mm above the package's top), so each plate has its own.
function holoTop(G, cam, name) {
    return Cam.holoRect(G.ANCHORS[name], cam, Cam.HOLO.w, Cam.HOLO.base, Cam.HOLO.h, 0).y;
}

// ---- where a hologram is clickable ------------------------------------------------------------------------------------------------------------
// The clickable region for the detailed settings on cpu and gpu includes the hologram, which is clicked more often than the die itself.
// The region is what is DRAWN of it: the plane (a rectangle facing the viewer, HOLO) and the projector's column under it down
// to the lens on the anchor (the width of the lens ring); in Integrated the GPU's hologram is the beam's ghost of the card, which hangs over the card's place
// (hover and tallest part included: IsoCamera.ghostBox), so its region is the hull of that box instead. All in item px, from the camera the shaders draw with.
var _convexHull = BL.convexHull;

function _planeRegion(G, cam, name, lensMm) {
    var a = G.ANCHORS[name], H = Cam.HOLO;
    var r = Cam.holoRect(a, cam, H.w, H.base, H.h, 0);
    var anchor = _proj(cam, a), base = _proj(cam, [a[0], a[1] + H.base, a[2]]);
    var plane = { x: r.x, y: r.y, w: r.w, h: base[1] - r.y };
    var col = lensMm * cam.s;
    return [_rect(plane, 0), _rect({ x: anchor[0] - col, y: base[1], w: 2 * col, h: anchor[1] - base[1] }, 0)];
}

function holoRegions(G, cam) {
    var b = Cam.ghostBox(G, 0), pts = [];
    [b.x0, b.x1].forEach(function (x) {
        [b.y0, b.y1].forEach(function (y) {
            [b.z0, b.z1].forEach(function (z) {
                pts.push(_proj(cam, [x, y, z]));
            });
        });
    });
    return { cpu: _planeRegion(G, cam, "cpuHolo", G.LENS.cpu), gpu: _planeRegion(G, cam, "gpuHolo", G.LENS.gpu), ghost: _convexHull(pts) };
}

// What a click at (x, y) on a hologram means, "" when it is on none: "tuning" for the CPU's, "gpu" for the GPU's and for the ghost of the card in Integrated.
// `presence` { cpu, gpu, beam } is how much of each hologram is drawn now (0..1: the zone's power, the card's way out, the beam): one that is not drawn is not a thing
// to click. Parts are asked first (intentOf): a hologram only answers where nothing of the board does.
function holoIntentAt(G, cam, x, y, presence) {
    var pr = presence || {}, R = holoRegions(G, cam);
    if ((pr.cpu === undefined ? 1 : pr.cpu) > 0.5 && inRegion(R.cpu, x, y))
        return "tuning";
    if ((pr.gpu === undefined ? 1 : pr.gpu) > 0.5 && inRegion(R.gpu, x, y))
        return "gpu";
    if ((pr.beam === undefined ? 0 : pr.beam) > 0.5 && inPoly(R.ghost, x, y))
        return "gpu";
    return "";
}
