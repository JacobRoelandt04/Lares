pragma ComponentBehavior: Bound

import QtQuick
import "../theme"
import "Lighting.js" as Lighting

// =============================================================================
// VinylDisc.qml
//
// One 12" record, drawn by shaders/vinyl_disc.frag. This file owns nothing but
// the record's POSE and its MATERIAL: where it is, how it is turned, what it
// is made of. Every animation -- the swivel, the spin, the flip, the drop --
// lives outside it (VinylStage) and writes these properties, so there is one
// place that knows what a record looks like and another that knows what it is
// doing.
//
// Pose, all in the item's own pixels:
//
//   spinDeg     rotation about the record's own axis. Under playback this is
//               the playback position times the platter speed, so the record's
//               angle IS the position and scrubbing spins it for free.
//   tiltX/Y     the swivel: degrees about the view's x and y axes.
//   flipDeg     a rotation about an axis lying IN the view plane at
//               flipAxisDeg -- the half-album flip, up to several turns.
//   heightPx    how far the record floats toward the camera above the surface
//               plane. Drives the perspective magnification and the shadow.
//   offsetX/Y   where the record's centre sits, from the item's centre.
//   cameraX/Y   where the CAMERA's axis pierces the item, from the item's
//               centre. Same units and same signs as offsetX/Y.
//
// The shader is given the record's own three axes rather than these angles,
// because it does not need to know which rotation produced them.
//
// The environment the record reflects is the SHELL: its sky is the surface the
// popup is drawn on and its ground is the deep shadow, so a record in dark
// mode reflects a dark room without anything here switching on the mode.
// =============================================================================
Item {
    id: root

    // ======================================================================
    // POSE
    // ======================================================================
    property real spinDeg: 0
    property real tiltX: 0
    property real tiltY: 0
    property real flipDeg: 0
    property real flipAxisDeg: 0
    property real heightPx: 0
    property real offsetX: 0
    property real offsetY: 0

    // WHERE THE CAMERA IS, laterally: the point of the item its axis goes
    // through, in the item's own pixels from the item's centre, with the same
    // signs as offsetX/offsetY.
    //
    // 0, 0 is the item's middle, which is right whenever the record is drawn in
    // the middle of its own item.
    //
    // A host that puts the record somewhere else in a big item must move the
    // camera with it, to the point the record TURNS ON -- the pin -- and not to
    // wherever the record has been flung to. Two things go wrong when it does
    // not. The record rises straight toward a camera that is not above it, so
    // on a 2D screen it slides sideways as it lifts: in mini, 157 px off an
    // axis 193 px away, the flip's apex leaves the platter behind. And every
    // point of the record is then seen from a rotated direction, so the room it
    // reflects arrives rotated with it and the sheen sits at a different angle
    // than it does on the same pose drawn in the middle -- which is why mini
    // and player would disagree about the light.
    //
    // Anything in the item's own plane is drawn at its own place whatever this
    // is, so 0 is the camera straight above the item's middle.
    property real cameraX: 0
    property real cameraY: 0

    // ======================================================================
    // PROPORTIONS
    //
    // A real LP: 302 mm across, a 100 mm label, a 7.2 mm spindle hole, about
    // 1.9 mm thick. Everything is a fraction of the outer radius so the record
    // stays a record at any size.
    // ======================================================================
    // Fraction of half the item's smaller side. Under 1 to leave room for the
    // record to grow as it lifts toward the camera, and for its shadow.
    property real radiusFrac: 0.78
    property real holeFrac: 0.024
    property real labelFrac: 0.331
    property real grooveInnerFrac: 0.365
    property real grooveOuterFrac: 0.965
    property real thicknessFrac: 0.013

    readonly property real discRadius: Math.min(root.width, root.height) * 0.5 * root.radiusFrac

    // ======================================================================
    // MATERIAL
    // ======================================================================
    // The body's albedo, literally: the lighting is normalised so a colour set
    // here is the colour that comes back, and the near-black default is
    // rendered directly.
    property color vinylColor: "#0A0A0D"
    property color labelTint: "#FFFFFF"
    // Grooves are given as a COUNT across the modulated band rather than a
    // pitch in pixels, so the record keeps its look when it is resized.
    property int grooveCount: 150
    // The smooth lands between tracks: what the eye actually reads as "grooves"
    // at popup size, because a real groove pitch is far under a pixel here.
    property int trackCount: 9
    property real trackWidth: 0.62
    property real grooveDepth: 0.55
    property real grooveRough: 0.10
    property real roughAlong: 0.045      // along the groove: sharp
    property real roughAcross: 0.22      // across it: smeared radially
    property real labelRough: 0.65
    property real reflectivity: 1.0
    property real specStrength: 0.7
    // The label is paper, so it gets the room the same way the lacquer does but
    // through its own roughness: a broad, dim sheen instead of a hard one.
    // That sheen is `labelReflect`: the environment through a roughness-capped
    // fresnel, which is nothing face-on and climbs as the label turns away --
    // the angle it is seen at while the record flips, and measured there
    // (80 degrees) it is the whole of the effect, +15 levels of 255.
    //
    // `labelSpec` is only the direct lights' own lobe on paper, and it has to
    // stay small. A GGX lobe at labelRough is so broad that gain on it is a
    // flat veil rather than a highlight: at 6.0 it lifts the label's blacks
    // from 36 to 100 and bleaches the artwork, while adding 0.2 of a level at
    // grazing -- brightest exactly where a sheen should be weakest.
    property real labelReflect: 0.60
    property real labelSpec: 1.2
    // The diffuse response. Together these put a white albedo facing the key
    // light just under 1: measured on the default rig, key ndl 0.52 and fill
    // 0.70 x 0.45 sum to 0.784, so 0.28 + 0.855 x 0.784 = 0.951. Just under, not
    // at, so the sheen has somewhere to go on a pale body. A ceiling of 0.55
    // would bring #ffffff in the album art back as #96979a.
    property real diffuseGain: 0.855
    property real ambientDiffuse: 0.28
    // Where the output bends toward 1 instead of arriving at it. The near-black
    // default never reaches it; a white record's whole face would otherwise sit
    // at the ceiling with the arcs clipped flat out of it.
    property real highlightKnee: 0.88
    // How much a PALE body damps its own sheen. The ramp inside the shader
    // starts at 0.30 luma, and the default's is 0.04, so this knob does not
    // reach the dark record at all -- its reflection is left alone. A white
    // one loses enough of the arcs not to read as brushed metal.
    property real paleSheen: 0.62
    // 1/specKnee is the brightest the sheen can get. There is an angle in the
    // flip where every point of the record reflects the strip at once; without
    // a ceiling the whole disc goes white and loses its shape.
    property real specKnee: 1.0

    // Wear
    property real dust: 0.3
    property real scuff: 0.3
    property real labelWear: 0.35

    // The rim and the spindle hole's wall. `edgeBevelFrac` is a fraction of the
    // record's HALF thickness: the corner is rolled over that much so the light
    // wraps it instead of leaving the black seam that reads as a void when the
    // record flips. `edgeAmbient` is the light that reaches a surface facing
    // nothing, and `edgeLift` how far the cut edge sits from the body's own
    // colour -- a cut edge is matte and catches every bounce inside the hole,
    // so it is never quite #000000.
    property real edgeBevelFrac: 0.75
    property real edgeAmbient: 0.16
    property real edgeLift: 0.10
    // Sub-samples spent on a pixel the silhouette, the rim band or the spindle
    // hole passes through -- and only on those pixels. 0 turns it off.
    property int edgeSamples: 8

    // The turntable's pin, as a shadow on the label. Off unless a stage sets
    // it: `pinShadowStrength` 0 draws nothing at all. `pinHeightPx` is the
    // length of pin standing PROUD of the label, so a stage sends the pin minus
    // however far the record has risen up it (VinylStage does exactly that):
    // longest with the record down on the platter, gone once it has cleared the
    // pin.
    //
    // The shadow is not one softness. Its penumbra grows ALONG it -- nearly
    // sharp where the pin meets the record, `pinPenumbra` px per px of
    // protrusion by the time it reaches the tip -- because what sets a
    // penumbra is the distance between the point casting the shadow and the
    // surface catching it, and along this shadow that distance runs from zero
    // to the whole protrusion. Which is also why a record still on its way down
    // has a SHORT HARD shadow and a record settled on the platter a long, soft,
    // draining one, with nothing switching between the two.
    property real pinShadowStrength: 0
    property real pinRadius: 0
    property real pinHeightPx: 0
    property real pinPenumbra: 0.22
    property real pinPenumbraBase: 0.6
    property real pinShadowFade: 0.45

    // Lights, in view space: x right, y up, z toward the viewer.
    //
    // Given as an ANGLE and an ELEVATION rather than as a vector, because that
    // is what a light is tuned by: the angle sweeps it round the record (0 is
    // from the right, 90 from above) and the elevation lifts it out of the
    // record's plane toward the camera. A vector3d cannot be put on a slider,
    // and a light that cannot be swept is one nobody will tune.
    property real keyAngleDeg: 122
    property real keyElevation: 0.52
    property real fillAngleDeg: -29
    property real fillElevation: 0.70
    property real lightIntensity0: 1.0
    property real lightIntensity1: 0.45
    property color lightColor0: "#FFFFFF"
    property color lightColor1: "#C9D6FF"

    readonly property vector3d lightDir0: Lighting.dirOf(root.keyAngleDeg, root.keyElevation)
    readonly property vector3d lightDir1: Lighting.dirOf(root.fillAngleDeg, root.fillElevation)

    // The room. Defaults follow the theme so the record reflects the shell.
    //
    // FadeColor, not the token: through a theme switch the record is a ThemeIsland (VinylStage) and its reflection goes
    // from the old room to the new on the crossfade's clock. At rest, and in a host with no island, it IS the token.
    property color skyColor: skyFade.value
    property color groundColor: groundFade.value
    // The record is an island through a switch (VinylStage says so): off, the lock's record and every other host keep the token itself.
    property bool islandArmed: false
    // the record's own rect, so its colours go as the live curtain's line crosses it (FadeColor.place)
    property Item islandPlace: null
    FadeColor { id: skyFade; token: "surface"; active: root.islandArmed; place: root.islandPlace }
    FadeColor { id: groundFade; token: "shadowDeep"; active: root.islandArmed; place: root.islandPlace }
    property real envHorizon: 0.45

    // The strip light: a long source, above and in front, lying across the
    // record. A point lamp on circular grooves gives a straight radial bar;
    // the curved sheens a record really shows need a source with length, so
    // this one is shaded from whichever point along it the pixel reflects.
    property real stripAngleDeg: 105
    property real stripElevation: 0.82
    property real stripTiltDeg: 20          // how the strip lies across the view
    property real stripHalfLength: 0.70
    readonly property vector3d stripCenter: Lighting.dirOf(root.stripAngleDeg, root.stripElevation)
    readonly property vector3d stripAxis: Qt.vector3d(Math.cos(root.stripTiltDeg * Math.PI / 180), Math.sin(root.stripTiltDeg * Math.PI / 180), 0)
    property real stripIntensity: 0.9
    property color stripColor: "#FFFFFF"

    // Camera. Distance in units of the record's radius: large is nearly
    // orthographic, small exaggerates the tilt.
    property real camDistFrac: 4.2

    // Contact shadow on the surface the record is lowered onto. The surface
    // sits `shadowGapFrac` of a radius BEHIND the record's rest position, so a
    // record at heightPx 0 still has a tight contact shadow rather than one
    // drawn in its own plane.
    property real shadowStrength: 0.42
    property real shadowSoftness: 0.004
    property real shadowGapFrac: 0.025
    property color shadowColor: Theme.shadowDeep

    // Album art for the label. Empty means a flat label in labelTint.
    property string albumArt: ""

    // ======================================================================
    // THE BASIS
    //
    // The record's own axes in view space. Spin first (inside the record),
    // then the flip about an in-plane axis, then the swivel about the view's
    // own axes -- so a swivel does not drag the flip's axis around with it.
    //
    // The pose -- the flip and then the swivel -- is applied to ONE vector at
    // a time. Each vector's chain of rotations is independent of the others',
    // so taking them one by one is the same arithmetic in the same order and
    // comes out bit for bit as a three-at-once loop would. What it buys is
    // the NORMAL on its own: the spin cannot move it, so it does not have to
    // be recomputed with the axes the spin does move.
    // ======================================================================
    function _rotAxis(v, axis, deg) {
        const a = deg * Math.PI / 180;
        const c = Math.cos(a), s = Math.sin(a);
        const dot = v.x * axis.x + v.y * axis.y + v.z * axis.z;
        // Rodrigues
        return Qt.vector3d(v.x * c + (axis.y * v.z - axis.z * v.y) * s + axis.x * dot * (1 - c), v.y * c + (axis.z * v.x - axis.x * v.z) * s + axis.y * dot * (1 - c), v.z * c + (axis.x * v.y - axis.y * v.x) * s + axis.z * dot * (1 - c));
    }

    function _posed(v) {
        const rad = Math.PI / 180;
        if (root.flipDeg !== 0) {
            const fa = root.flipAxisDeg * rad;
            v = root._rotAxis(v, Qt.vector3d(Math.cos(fa), Math.sin(fa), 0), root.flipDeg);
        }
        if (root.tiltX !== 0)
            v = root._rotAxis(v, Qt.vector3d(1, 0, 0), root.tiltX);
        if (root.tiltY !== 0)
            v = root._rotAxis(v, Qt.vector3d(0, 1, 0), root.tiltY);
        return v;
    }

    // THE NORMAL ON ITS OWN, because the spin provably cannot move it: it
    // starts at +z, which is the spin's own axis, and only the flip and the
    // swivel ever reach it.
    //
    // `_quad` below wants the normal and nothing else of the basis. Taken out
    // of a `var` array it would notify every frame: a `var` holding a NEW
    // ARRAY every evaluation is compared by identity, so a fresh one always
    // notifies, and while the record spun the whole drawn-rect derivation, its
    // Qt.rect, the four geometry bindings on `fx` and the `quad` uniform would
    // all re-run once a frame for a value that is numerically the same every
    // time (measured at 0.32 ms of the frame). A `vector3d` is a value type and
    // compares by value, so this notifies when the pose actually moves and not
    // otherwise.
    readonly property vector3d _normal: root._posed(Qt.vector3d(0, 0, 1))

    // ======================================================================
    // THE PART OF THE ITEM THAT IS ACTUALLY DRAWN
    //
    // The item is the whole card -- it has to be, because nothing may cut the
    // record's shadow but the container's own edge.
    // The record and its shadow are not the whole card, though: at the two
    // geometries this ships in they cover about 64 % of it in `player` and 15 %
    // in `mini`, where a 92 px record sits in a 456 x 142 box. The rest would
    // be a full ray-trace per pixel, per frame, for a result that is
    // transparent by construction.
    //
    // So the ShaderEffect is sized to the bound of what can be painted, and
    // tells the shader where it put itself. This is a bound and not a guess:
    //
    //   the record   lives inside a sphere of `discRadius + half-thickness`
    //                about its centre (+ the 4 px the shader's own reject
    //                allows for sub-samples), and a pinhole camera maps that
    //                sphere into the box below -- every point of it is seen
    //                with a magnification between the near and far faces'.
    //   the shadow   is the disc mapped onto the plane along the key light:
    //                a point `d` from the centre lands `d - L * d.z / L.z`
    //                from the shadow's centre, so the whole shadow lies within
    //                (radius + its own blur) * (1 + |n_xy| / L.z) of it. For a
    //                flat record that is exactly the record's own radius; it
    //                grows as the record turns edge-on, which is when the flip
    //                simply takes the whole card back.
    //
    // Rounded OUTWARD to whole pixels with two more of margin, and abandoned
    // entirely -- the whole item -- whenever the bound reaches 92 % of it.
    // Nothing is cut: outside this rect the shader would produce transparent
    // black, so nothing is asked there.
    // ======================================================================
    readonly property real _halfT: root.discRadius * root.thicknessFrac
    readonly property real _camZ: root.discRadius * root.camDistFrac

    readonly property rect _quad: {
        const W = Math.max(1, root.width), H = Math.max(1, root.height);
        const full = Qt.rect(0, 0, W, H);
        if (root.discRadius <= 0)
            return full;
        // View space: +y UP, measured from the item's centre. Same convention
        // as `discPos` and `camCenter` below.
        const camX = root.cameraX, camY = -root.cameraY;
        const cx = root.offsetX, cy = -root.offsetY, cz = root.heightPx;
        const cz0 = root._camZ;
        // THE RECORD'S EXTENT PER AXIS, and not a bounding sphere -- a sphere
        // around a 12" record is a quarter of a metre thick, and using one would
        // give the flat record a z-extent of a whole radius, a near-face
        // magnification of 1.33, and a box bigger than the card. The disc is
        // C + R(cos t . u + sin t . v) + s.n with |s| <= half the thickness,
        // and u, v, n are orthonormal, so along any view axis a its reach is
        // R.sqrt(1 - n.a^2) + halfT.|n.a| -- the whole radius across a flat
        // record, and only its thickness through it. Plus the 4 px of slack the
        // shader's own reject allows.
        const n = root._normal;
        const rr = root.discRadius, ht = root._halfT;
        function reach(na) { return rr * Math.sqrt(Math.max(0, 1 - na * na)) + ht * Math.abs(na) + 4.0; }
        const ex = reach(n.x), ey = reach(n.y), ez = reach(n.z);
        const mNear = cz0 / Math.max(cz0 - (cz + ez), 1);
        const mFar = cz0 / Math.max(cz0 - (cz - ez), 1);
        function span(c, cam, e) {
            const lo = c - e - cam, hi = c + e - cam;
            return [cam + Math.min(lo * mFar, lo * mNear), cam + Math.max(hi * mFar, hi * mNear)];
        }
        let sx = span(cx, camX, ex);
        let sy = span(cy, camY, ey);

        if (root.shadowStrength > 0.001) {
            const l = root.lightDir0;
            // The shader stops drawing a shadow below 0.06 of grazing; past
            // that the projection runs away and the bound with it.
            const lz = Math.max(l.z, 0.06);
            const shZ = -root.discRadius * root.shadowGapFrac;
            const nxy = Math.sqrt(n.x * n.x + n.y * n.y);
            const above = Math.max(cz - shZ, 0);
            const blur = root.discRadius * (0.04 + above * root.shadowSoftness);
            const rsh = (root.discRadius + blur) * (1 + nxy / lz);
            const t = (cz - shZ) / lz;
            const shX = cx - l.x * t, shY = cy - l.y * t;
            const ms = cz0 / Math.max(cz0 - shZ, 1);
            sx = [Math.min(sx[0], camX + (shX - rsh - camX) * ms),
                  Math.max(sx[1], camX + (shX + rsh - camX) * ms)];
            sy = [Math.min(sy[0], camY + (shY - rsh - camY) * ms),
                  Math.max(sy[1], camY + (shY + rsh - camY) * ms)];
        }

        // Back into the item's own coordinates, where +y is down.
        const x0 = Math.max(0, Math.floor(W / 2 + sx[0]) - 2);
        const x1 = Math.min(W, Math.ceil(W / 2 + sx[1]) + 2);
        const y0 = Math.max(0, Math.floor(H / 2 - sy[1]) - 2);
        const y1 = Math.min(H, Math.ceil(H / 2 - sy[0]) + 2);
        if (x1 <= x0 || y1 <= y0)
            return Qt.rect(0, 0, 0, 0);
        if ((x1 - x0) * (y1 - y0) > W * H * 0.92)
            return full;
        return Qt.rect(x0, y0, x1 - x0, y1 - y0);
    }

    // ======================================================================
    // HOW BIG THE LABEL IS ACTUALLY DECODED
    //
    // The cover on the label is drawn into a circle `labelFrac` of the record
    // across. Measured through the popup that is 129.9 px in `player` and
    // 30.5 px in `mini`; decoding, mipmapping and uploading both at 512 square
    // would be, in mini, 280 times the texels the screen can show. The
    // ShaderEffect's own quad follows the drawn size (419 x 421 in `player`
    // against 108 x 108 in `mini`), and so does the TEXTURE.
    //
    // It follows the label as drawn, with headroom, rounded UP to a power
    // of two:
    //
    //   the headroom is the PERSPECTIVE. The record rises toward the camera
    //     and is magnified by camZ / (camZ - h), and camZ is 1.638 stage
    //     widths (radiusFrac 0.78 / 2 x camDistFrac 4.2). At the flip's apex
    //     that is 1.22 at VinylStage's own liftFrac of 0.30 and 1.51 at a
    //     liftFrac of 0.55, so 2 covers every pose the choreography reaches at
    //     either, with room over.
    //   the power of two is so a RESIZE does not re-decode the cover on every
    //     pixel of the 260 ms the card takes to change view -- the size only
    //     moves when the label crosses an octave -- and so the mip chain the
    //     minification actually samples is exact.
    //   the cap (`labelTexMax`) means nothing ever decodes MORE than that and
    //     no view that is sharp becomes less so.
    //
    // At the two geometries this ships in: `player` 512, because 129.9 x 2
    // rounds up to it; `mini` 64, which is 64 times fewer texels for a picture
    // nobody can see any more of.
    // ======================================================================
    property real labelTexOversample: 2
    property int labelTexMax: 512
    readonly property int labelTexPx: {
        const drawn = root.discRadius * root.labelFrac * 2 * root.labelTexOversample;
        return Math.min(root.labelTexMax,
                        Math.pow(2, Math.ceil(Math.log2(Math.max(32, drawn)))));
    }

    // The album art. Not visible itself: it is here only as a texture for the
    // shader. Mipmapped, because the label is minified hard -- without it the
    // art crawls as the record turns.
    //
    // TWO LOADERS, SO A RESIZE NEVER SHOWS A BARE LABEL. `labelTexPx` is 512 in
    // the player and 64 in mini, so switching view changes `sourceSize` and the
    // Image reloads -- and for the frame or two that takes, `labelHasTex` would
    // be 0 and the shader would draw the label with no art on it at all (a
    // white flash).
    //
    // So the shader is handed whichever loader is READY, and the incoming one
    // takes the new size while the outgoing one keeps the picture up until it
    // lands. Nothing false is shown: it is the same picture at a different
    // resolution.
    //
    // WHICH IS EXACTLY WHY IT ONLY HOLDS ACROSS A RESIZE. When the ALBUM
    // changes there is no honest previous frame -- holding one would put the
    // last record's art on the new record's label, which is the bug the popup's
    // whole `_coverReady` latch exists to prevent. So an album change clears the
    // outgoing loader too and the shader waits with no art.
    Image {
        id: labelA
        visible: false
        asynchronous: true
        mipmap: true
        smooth: true
        cache: true
        onStatusChanged: root._noteLabelReady(labelA)
    }
    Image {
        id: labelB
        visible: false
        asynchronous: true
        mipmap: true
        smooth: true
        cache: true
        onStatusChanged: root._noteLabelReady(labelB)
    }

    property bool _showB: false
    readonly property var _labelShown: root._showB ? labelB : labelA
    readonly property var _labelIncoming: root._showB ? labelA : labelB

    // `source` and `sourceSize` are written from here and nowhere else, so
    // there is no binding to destroy: which loader gets which picture is a
    // decision, not a derivation.
    // THE ORDER HERE IS THE WHOLE FUNCTION: getting it wrong leaves the label
    // white until the view is switched.
    //
    // A CACHED Image reaches `Ready` SYNCHRONOUSLY, inside the `source`
    // assignment -- so `_noteLabelReady` runs before the next statement does,
    // and the swap it makes means `_labelShown` is no longer the loader it was
    // one line earlier. Clearing the outgoing one AFTER the load would
    // therefore clear the picture that has just arrived. Every album change
    // hits it, because by then the art is in Qt's cache; a cold first load is
    // genuinely asynchronous and the clear lands on the right image, so a test
    // that only ever sees the cold path cannot see this.
    //
    // So the outgoing one is cleared FIRST, while it is still known which it
    // is, and nothing is written after the load.
    function _retargetLabel(albumChanged) {
        const inc = root._labelIncoming;
        // No honest previous frame for a new album -- see the loaders above.
        if (albumChanged)
            root._labelShown.source = "";
        inc.sourceSize.width = root.labelTexPx;
        inc.sourceSize.height = root.labelTexPx;
        inc.source = root.albumArt;      // may reach `Ready` before it returns
    }

    // SET, NEVER TOGGLED. A toggle has to be called exactly once to be right,
    // and this can be reached twice for one picture (the synchronous path
    // above, and again on a later status change); choosing the loader by
    // identity is idempotent, so a second call is a no-op instead of a flip
    // back to the empty one.
    function _noteLabelReady(who) {
        if (who.status !== Image.Ready || String(who.source) === "")
            return;
        root._showB = (who === labelB);
    }

    // Whether the shader actually has art to put on the label -- not the same
    // fact as `albumArt` being set: a check that watches `albumArt` cannot see
    // a white label.
    readonly property bool labelReady:
        root.albumArt !== "" && root._labelShown
        && root._labelShown.status === Image.Ready

    onAlbumArtChanged: root._retargetLabel(true)
    onLabelTexPxChanged: root._retargetLabel(false)
    Component.onCompleted: root._retargetLabel(true)

    ShaderEffect {
        id: fx
        x: root._quad.x
        y: root._quad.y
        width: root._quad.width
        height: root._quad.height
        visible: root._quad.width > 0 && root._quad.height > 0
        fragmentShader: "shaders/vinyl_disc.frag.qsb"
        blending: true

        // `res` stays the ITEM's size, not the quad's: every position in the
        // shader is measured from the item's centre, and moving that origin
        // would move the record. `quad` is the only thing that says where the
        // drawn rect sits inside it.
        property vector2d res: Qt.vector2d(Math.max(1, root.width), Math.max(1, root.height))
        property vector4d quad: Qt.vector4d(root._quad.x, root._quad.y,
                                            Math.max(1, root._quad.width),
                                            Math.max(1, root._quad.height))
        property real camZ: root.discRadius * root.camDistFrac
        // View space has +y UP, the item's own coordinates +y down, which is
        // the same flip `discPos` does one line further on.
        property vector2d camCenter: Qt.vector2d(root.cameraX, -root.cameraY)
        property real edgeSamples: root.edgeSamples

        // The only part of the basis the spin moves, and therefore the only
        // part re-evaluated per frame -- the normal comes off `root._normal`,
        // which the spin does not notify.
        //
        // Deliberately NOT normalised here. The shader normalises these three
        // itself and nothing else, so that the traced hit point is bit-exact
        // -- the dust and scuff hashes and the label's
        // mip selection all turn a last-bit difference in it into a visible
        // one. Every OTHER direction the shader is handed (the two lights, the
        // strip's centre and axis) is unit by construction -- Lighting.dirOf
        // returns (cos a * r, sin a * r, e) with r = sqrt(1 - e * e), and the
        // strip's axis is (cos t, sin t, 0) -- and the shader normalises none
        // of them.
        property matrix4x4 basis: {
            const rad = Math.PI / 180;
            const cs = Math.cos(root.spinDeg * rad), sn = Math.sin(root.spinDeg * rad);
            const u = root._posed(Qt.vector3d(cs, sn, 0));
            const v = root._posed(Qt.vector3d(-sn, cs, 0));
            const n = root._normal;
            // Columns are the record's axes: GLSL basis[0] must be u.
            return Qt.matrix4x4(u.x, v.x, n.x, 0, u.y, v.y, n.y, 0, u.z, v.z, n.z, 0, 0, 0, 0, 1);
        }
        property vector4d discPos: Qt.vector4d(root.offsetX, -root.offsetY, root.heightPx, 0)

        property real radius: root.discRadius
        property real thickness: root.discRadius * root.thicknessFrac * 2.0
        property real holeR: root.discRadius * root.holeFrac
        property real labelR: root.discRadius * root.labelFrac
        property real grooveInnerR: root.discRadius * root.grooveInnerFrac
        property real grooveOuterR: root.discRadius * root.grooveOuterFrac

        property real groovePitch: (root.discRadius * (root.grooveOuterFrac - root.grooveInnerFrac)) / Math.max(1, root.grooveCount)
        property real grooveDepth: root.grooveDepth
        property real grooveRough: root.grooveRough
        property real trackCount: root.trackCount
        property real trackWidth: root.trackWidth

        property color vinylColor: root.vinylColor
        property color labelTint: root.labelTint
        property real roughAlong: root.roughAlong
        property real roughAcross: root.roughAcross
        property real labelRough: root.labelRough
        property real labelReflect: root.labelReflect
        property real labelSpec: root.labelSpec
        property real reflectivity: root.reflectivity
        property real specStrength: root.specStrength
        property real specKnee: root.specKnee
        property real diffuseGain: root.diffuseGain
        property real ambientDiffuse: root.ambientDiffuse
        property real paleSheen: root.paleSheen
        property real highlightKnee: root.highlightKnee
        property real edgeBevel: root.discRadius * root.thicknessFrac * root.edgeBevelFrac
        property real edgeAmbient: root.edgeAmbient
        property real edgeLift: root.edgeLift

        property vector4d light0: Qt.vector4d(root.lightDir0.x, root.lightDir0.y, root.lightDir0.z, root.lightIntensity0)
        property vector4d light1: Qt.vector4d(root.lightDir1.x, root.lightDir1.y, root.lightDir1.z, root.lightIntensity1)
        property color lightColor0: root.lightColor0
        property color lightColor1: root.lightColor1
        property color skyColor: root.skyColor
        property color groundColor: root.groundColor
        property real envHorizon: root.envHorizon

        property real dust: root.dust
        property real scuff: root.scuff
        property real labelWear: root.labelWear

        property vector4d stripCenter: Qt.vector4d(root.stripCenter.x, root.stripCenter.y, root.stripCenter.z, root.stripHalfLength)
        property vector4d stripAxis: Qt.vector4d(root.stripAxis.x, root.stripAxis.y, root.stripAxis.z, root.stripIntensity)
        property color stripColor: root.stripColor

        property real shadowZ: -root.discRadius * root.shadowGapFrac
        property real shadowStrength: root.shadowStrength
        property real shadowSoftness: root.shadowSoftness
        property color shadowColor: root.shadowColor

        property real pinShadow: root.pinShadowStrength
        property real pinRadius: root.pinRadius
        property real pinHeight: root.pinHeightPx
        property real pinPenumbra: root.pinPenumbra
        property real pinPenumbraBase: root.pinPenumbraBase
        property real pinShadowFade: root.pinShadowFade

        property real labelHasTex: root.labelReady ? 1 : 0
        property variant labelTex: root._labelShown
    }
}
