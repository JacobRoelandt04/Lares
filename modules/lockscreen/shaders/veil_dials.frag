#version 440
// =============================================================================
// veil_dials.frag -- the DIAL RINGS veil: concentric rings of the shell's material round
// the popup, like a vault dial or a watch's chapter rings.
//
// ONE SHADER, NO ITEMS. The ring a pixel is in is a division (k = floor((r - hub) / pitch)),
// so there is no loop over rings. Between two rings runs a carved groove (floor tinted toward
// the sunk tone, the flank away from the light in shadow, the flank toward it lit -- the
// radial profile's slope along the light, r-hat . L); the rings are plateaus of the surface.
// Each ring carries engraved ticks, drawn as the distance to a tick's segment in the ring's
// own frame (arc coordinate u = r * (angle - ring angle) folded to the tick pitch, radial
// coordinate along the band), each a small carved groove lit by its own slope along the
// light (the arc direction's component along L is what makes the left of a dial and its right
// catch the light differently, as an engraving does).
//
// Every ring turns at its own slow rate and its own way; a key CLICKS every ring one tick
// round, the outer rings a moment after the inner (a wave of clicks, each an ease with a
// little overshoot, like a detent); the accepted password turns every ring to the alignment
// angle; a failed one makes them shudder.
//
// THE ENTRANCE: a cutter groove travels out from the popup (r_front grows with presence);
// behind it each ring is cut in -- its ticks engrave over the next ~one ring and the ring turns
// from a quarter turn away into place; ahead of it the desktop is untouched.
//
// THE RE-CUT (VeilDials.qml): when the hub has changed size (the shell's popup arrived), a ring keeps
// the tick count it had until a re-cut front passes its middle; its ticks are smoothed away as the
// front comes and engraved again as it goes on, so the count changes while the ring shows none.
//
// Pixel size comes from p.x (a linear coordinate); masks feather inward; no loop-indexed uniform
// array (the clicks are unrolled by name, nested by the count).
// =============================================================================
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4  qt_Matrix;
    float qt_Opacity;
    vec2  size;
    vec4  geom;         // centre x, y, unit, hub radius px
    vec4  ringG;        // ring pitch px, groove width px, groove depth px, tick target pitch px
    vec4  tickG;        // tick half width px, tick depth px, minor length (share of band), major length
    vec4  spin;         // base rate rad/s, rate spread, major every, marker length (share of band)
    vec4  click;        // notch (ticks), delay per ring s, duration s, settled clicks
    vec4  align;        // alignment angle, ok progress 0..1 (eased), ok time (s), total clicks
    vec4  shake;        // fail age s, amplitude rad, decay s, frequency Hz
    vec4  front;        // r_front, feather px, cut-in px, entrance spin rad
    vec4  lightK;       // highlight gain, shadow gain, cavity, dark highlight lift
    vec4  tone;         // alternate ring tint, the hub (px) the tick counts are worked out from, what is left of the dial (1; the clear's end takes it to 0), 0
    vec4  detail;       // brushed-metal strength, numerals on 0/1, 0, 0
    float presence;
    float opaqueMode;
    float tm;
    float sandAlpha;
    float clickCount;
    vec4  cSand;
    vec4  cHi;
    vec4  cLo;
    vec4  cFloor;
    vec4  cErr;
    vec4  clk0;         // recent clicks: age, weight (0 = not drawn)
    vec4  clk1;
    vec4  clk2;
    vec4  clk3;
    vec4  clk4;
    vec4  clk5;
    vec4  clk6;
    vec4  clk7;
    vec4  clk8;
    vec4  clk9;
    vec4  clk10;
    vec4  clk11;
    vec4  clk12;
    vec4  clk13;
    vec4  clk14;
    vec4  clk15;
    vec4  recut;        // THE RE-CUT: tick hub of the rings no re-cut has reached, of those only the earlier one has passed,
                        // how far (px from the hub) the earlier and the newest have come (-1e6 not left, 1e6 all passed)
};

const vec2 LIGHT = vec2(-0.5145, -0.8575);   // toward the light, y down
const float TAU = 6.2831853;

float easeBack(float a) {
    float b = a - 1.0;
    return 1.0 + 2.7 * b * b * b + 1.7 * b * b;
}
// how far one click has turned a ring that starts `dly` after the key: 0 .. weight
float clickOf(vec4 c, float dly) {
    float a = (c.x - dly) / max(click.z, 1e-3);
    if (a <= 0.0 || c.y <= 0.0)
        return 0.0;
    return a >= 1.0 ? c.y : easeBack(a) * c.y;
}

// No sine of a scaled argument (see lock_kawase_up.frag): only fract(), which stays random whatever the argument and on every driver.
float hash11(float n) {
    n = fract(n * 0.1031);
    n *= n + 33.33;
    n *= n + n;
    return fract(n);
}

// THE TICK COUNT of a ring whose middle lies `rk` past a hub of `h`: a whole number of numeral wheels (see below)
float ticksAt(float h, float rk, float wheel, float u) {
    return wheel * max(1.0, floor(TAU * (h + rk) / (ringG.w * u * wheel) + 0.5));
}

// distance from p to the segment a-b, and the vector from the nearest point to p (xy), packed (dist, vec)
vec3 segD(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a, ba = b - a;
    float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
    vec2 v = pa - ba * h;
    return vec3(length(v), v);
}
// seven segments of a digit: a top, b upper right, c lower right, d bottom, e lower left, f upper left, g middle
// (no bit operations or const arrays: the .qsb targets include GLSL 1.20)
float digitMask(float d) {
    return d < 0.5 ? 63.0 : d < 1.5 ? 6.0 : d < 2.5 ? 91.0 : d < 3.5 ? 79.0 : d < 4.5 ? 102.0 : d < 5.5 ? 109.0 : d < 6.5 ? 125.0 : d < 7.5 ? 7.0 : d < 8.5 ? 127.0 : 111.0;
}
bool seg(float m, float bit) { return mod(floor(m / bit + 0.01), 2.0) > 0.5; }
vec3 digitD(vec2 p, float dgt, float hw, float hh) {
    float m = digitMask(dgt);
    vec3 best = vec3(1e3, 0.0, 0.0);
    if (seg(m, 1.0))  { vec3 t = segD(p, vec2(-hw, hh), vec2(hw, hh));   if (t.x < best.x) best = t; }
    if (seg(m, 2.0))  { vec3 t = segD(p, vec2(hw, hh), vec2(hw, 0.0));   if (t.x < best.x) best = t; }
    if (seg(m, 4.0))  { vec3 t = segD(p, vec2(hw, 0.0), vec2(hw, -hh));  if (t.x < best.x) best = t; }
    if (seg(m, 8.0))  { vec3 t = segD(p, vec2(-hw, -hh), vec2(hw, -hh)); if (t.x < best.x) best = t; }
    if (seg(m, 16.0)) { vec3 t = segD(p, vec2(-hw, -hh), vec2(-hw, 0.0)); if (t.x < best.x) best = t; }
    if (seg(m, 32.0)) { vec3 t = segD(p, vec2(-hw, 0.0), vec2(-hw, hh)); if (t.x < best.x) best = t; }
    if (seg(m, 64.0)) { vec3 t = segD(p, vec2(-hw, 0.0), vec2(hw, 0.0)); if (t.x < best.x) best = t; }
    return best;
}

void main() {
    vec2 p = qt_TexCoord0 * size;
    float u = max(geom.z, 1e-3);
    float px = max(length(vec2(dFdx(p.x), dFdy(p.x))), 1e-4);
    vec2 dv = p - geom.xy;
    float r = max(length(dv), 1e-3);
    vec2 rh = dv / r;
    vec2 th = vec2(-rh.y, rh.x);                    // direction of increasing angle
    float ang = atan(dv.y, dv.x);

    float pitch = ringG.x * u;
    float gw = 0.5 * ringG.y * u;
    float hub = geom.w;

    // ---- the entrance: the cutter's place, the sand behind it ------------------------------
    // At rest (presence 1) the cutter is past every pixel: nothing below depends on it, and none of it is computed.
    bool entering = presence < 0.9999;
    float behind = entering ? front.x - r : 1e5;    // > 0 behind the cutter
    // (at boot the sand is there whole from the first frame: the cutter only engraves it)
    float groundCov = entering && opaqueMode < 0.5 ? smoothstep(0.0, front.y * u, behind) : 1.0;

    // ---- the ring ----------------------------------------------------------------------------
    float rr = r - hub;
    float kf = floor(rr / pitch);
    float rem = rr - kf * pitch;                    // 0 at the ring's inner groove, pitch at its outer
    float H = 0.0;                                  // height, px
    float S = 0.0;                                  // slope along the light
    float stripe = 0.0;                             // error tint
    float ringTone = 0.0;
    float kc = kf;                                  // ring whose engraving applies here

    // grooves: at every ring boundary (rem = 0 and pitch), a carved channel
    float db = min(rem, pitch - rem);
    float sgn = rem < pitch - rem ? 1.0 : -1.0;     // + : the channel is on the inner side
    float dep = ringG.z * u;
    float cutIn = entering ? clamp((behind) / max(front.z * u, 1.0), 0.0, 1.0) : 1.0;
    if (rr > -gw && db < gw) {
        float t = db / gw;
        float q = 1.0 - t * t;
        float dhdt = 4.0 * t * q;                   // d/dt of -(q^2)
        H = -q * q * dep;
        // d/dr of the height: the channel at rem=0 has its centre at rem 0: moving outward leaves it
        float drem = rem < pitch - rem ? 1.0 : -1.0;
        float dHdr = dhdt / gw * dep * drem;
        S = -dHdr * dot(rh, LIGHT);
    }
    // the hub's own channel (the ring boundary at rr = 0, which kf = -1 would otherwise own)
    float ring = max(kf, 0.0);
    ringTone = mod(ring, 2.0) * tone.x;

    // ---- the ticks ---------------------------------------------------------------------------
    float tickD = 1e3;                              // distance to the nearest tick, px
    float engr = 1.0;                               // how much of the ring's engraving stands (THE RE-CUT takes it away and back)
    vec2 tickG2 = vec2(0.0);                        // its gradient direction (screen)
    float markOn = 0.0;
    if (rr > 0.0 && rem > gw * 0.6 && rem < pitch - gw * 0.6) {
        float rmid = hub + (ring + 0.5) * pitch;
        // THE TICK COUNT of a ring is a whole number of numeral wheels: ten majors, `every` ticks apart,
        // so the digits 0..9 run round the ring and meet themselves at the zero. (A count that is any
        // other multiple drops digits at the seam: 4 3 2 0 9 -- the 1 missing.) It is worked out from
        // the dial's hub as it was at rest (`tone.y`), never from the live one: when the unlock pulls
        // the dial in, its rings keep their ticks and shrink with it instead of being re-ticked.
        // THE RE-CUT: the count is the one the hub the ring was last cut at gives, and where a front passes a ring whose
        // count it changes, the ring's engraving goes to nothing at the front (over the cut-in either side).
        float wheel = max(spin.z, 1.0) * 10.0;
        float rk = (ring + 0.5) * pitch;
        float N = ticksAt(tone.y, rk, wheel, u);
        if (recut.w < 1e5) {
            float N0 = ticksAt(recut.x, rk, wheel, u);
            float N1 = ticksAt(recut.y, rk, wheel, u);
            float fade = max(front.z * u, 1.0);
            if (N0 != N1)
                engr *= smoothstep(0.0, fade, abs(rk - recut.z));
            if (N1 != N)
                engr *= smoothstep(0.0, fade, abs(rk - recut.w));
            N = rk < recut.w ? N : (rk < recut.z ? N1 : N0);
        }
        float dir = mod(ring, 2.0) < 0.5 ? 1.0 : -1.0;
        float rate = dir * spin.x * (1.0 + spin.y * hash11(ring + 3.0));
        float dTick = TAU / N;
        // clicks: this ring starts each `ring * delay` after the key
        float dly = ring * click.y;
        float clicks = click.w;
        if (clickCount > 0.5) {
            clicks += clickOf(clk0, dly);
            if (clickCount > 1.5) {
                clicks += clickOf(clk1, dly);
                if (clickCount > 2.5) {
                    clicks += clickOf(clk2, dly);
                    if (clickCount > 3.5) {
                        clicks += clickOf(clk3, dly);
                        if (clickCount > 4.5) {
                            clicks += clickOf(clk4, dly);
                            if (clickCount > 5.5) {
                                clicks += clickOf(clk5, dly);
                                if (clickCount > 6.5) {
                                    clicks += clickOf(clk6, dly);
                                    if (clickCount > 7.5) {
                                        clicks += clickOf(clk7, dly);
                                        if (clickCount > 8.5) {
                                            clicks += clickOf(clk8, dly);
                                            if (clickCount > 9.5) {
                                                clicks += clickOf(clk9, dly);
                                                if (clickCount > 10.5) {
                                                    clicks += clickOf(clk10, dly);
                                                    if (clickCount > 11.5) {
                                                        clicks += clickOf(clk11, dly);
                                                        if (clickCount > 12.5) {
                                                            clicks += clickOf(clk12, dly);
                                                            if (clickCount > 13.5) {
                                                                clicks += clickOf(clk13, dly);
                                                                if (clickCount > 14.5) {
                                                                    clicks += clickOf(clk14, dly);
                                                                    if (clickCount > 15.5) {
                                                                        clicks += clickOf(clk15, dly);
                                                                    }
                                                                }
                                                            }
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        float th0 = rate * tm + dir * click.x * dTick * clicks;
        // accepted: every ring turns to the alignment angle, by the shortest way
        float thOk = rate * align.z + dir * click.x * dTick * align.w;
        float tgt = align.x + TAU * floor((thOk - align.x) / TAU + 0.5);
        float thv = mix(th0, tgt, align.y);
        // failed: a shudder, the rings out of step with each other
        if (shake.x >= 0.0 && shake.y > 0.0) {
            float ag = shake.x - ring * 0.025;
            if (ag > 0.0) {
                float env = exp(-ag / shake.z);
                thv += dir * shake.y * env * sin(TAU * shake.w * ag);
                stripe = env;
            }
        }
        // the entrance: the ring turns into place as it is cut
        // the ring turns into place as a WHOLE: its own radius, not the pixel's, says how far the cutter is past it (a pixel's
        // radius sheared the outermost ring's ticks, whose turn was still unfinished across its width)
        if (entering) {
            float ek = clamp((front.x - rmid) / max(front.z * u * 1.6, 1.0), 0.0, 1.0);
            thv += dir * front.w * (1.0 - ek) * (1.0 - ek) * (1.0 - ek);
        }
        float a = ang - thv;
        float ia = floor(a / dTick + 0.5);
        float ua = (a / dTick - ia) * dTick * r;     // arc distance to the nearest tick, px (signed)
        float idx = mod(ia, N);
        float every = max(spin.z, 1.0);
        bool major = mod(idx, every) < 0.5;
        bool mark = idx < 0.5;
        float band = pitch - 2.0 * gw * 0.9;
        float len = band * (mark ? spin.w : (major ? tickG.w : tickG.z));
        float typ = mod(ring, 3.0);
        float lo = gw * 0.9, hi = lo + len;                      // radial span of the tick, from the inner edge
        if (typ < 0.5) {
            hi = pitch - gw * 0.9; lo = hi - len;                // from the outer edge
            // the zero mark stops short of the numeral engraved under it: it would run through the 0
            if (mark && detail.y > 0.5) lo = max(lo, gw * 0.9 + 14.0 * u + band * 0.27);
        }
        else if (typ < 1.5) { lo = gw * 0.9; hi = lo + len; }        // from the inner edge
        else { lo = 0.5 * (pitch - len); hi = lo + len; }            // centred
        float dr = max(max(lo - rem, rem - hi), 0.0);
        float drs = rem < lo ? rem - lo : (rem > hi ? rem - hi : 0.0);
        float dist = length(vec2(ua, dr));
        tickD = dist;
        vec2 gdir = vec2(ua, drs);
        float gl = max(length(gdir), 1e-3);
        // the gradient in screen space: arc axis = th, radial axis = rh
        tickG2 = (gdir.x * th + gdir.y * rh) / gl;
        markOn = mark ? 1.0 : 0.0;
        // engraved numerals under the outer-edge rings' major ticks: upright over the lower half of the screen
        if (detail.y > 0.5 && typ < 0.5 && major) {
            float hN = band * 0.27, wN = hN * 0.58;
            float yc = gw * 0.9 + 6.0 * u + 0.5 * hN;
            vec2 qn = vec2(-ua, -(rem - yc));        // turned half a turn: upright over the visible lower half, up = toward the popup, reading left to right
            if (abs(qn.x) < 0.5 * wN + 4.0 * u && abs(qn.y) < 0.5 * hN + 4.0 * u) {
                vec3 dd = digitD(qn, mod(10.0 - mod(floor(idx / every + 0.5), 10.0), 10.0), 0.5 * wN, 0.5 * hN);
                if (dd.x < tickD) {
                    tickD = dd.x;
                    tickG2 = (dd.y * th + dd.z * rh) / max(dd.x, 1e-3);
                }
            }
        }
        // engraving strength: grows as the cutter passes (and a re-cut takes it away and back)
        engr *= cutIn;
        tickD = tickD + (1.0 - engr) * 6.0 * u;
    }
    float tw = tickG.x * u * (1.0 + 0.5 * markOn);
    float tfoot = tw * 1.7;
    if (tickD < tfoot) {
        float t = tickD / tfoot;
        float q = 1.0 - t * t;
        float td = tickG.y * u * (1.0 + 0.4 * markOn) * engr;
        H += -q * q * td;
        float dHd = 4.0 * t * q / tfoot * td;       // dH/d(dist)
        S += -dHd * dot(tickG2, LIGHT);
    }

    // ---- the cutter groove: a channel at r = front -----------------------------------------------
    float cut = 0.0;
    if (entering && abs(behind) < gw * 1.4) {
        float t = abs(behind) / (gw * 1.4);
        float q = 1.0 - t * t;
        H += -q * q * dep * 0.9;
        S += -(4.0 * t * q / (gw * 1.4) * dep * 0.9) * (behind < 0.0 ? 1.0 : -1.0) * dot(rh, LIGHT) * -1.0;
        cut = q;
    }

    // ---- accepted: a line engraved straight down the dial where the zero marks arrive -----------------
    if (align.y > 0.001 && rr > 0.0) {
        vec2 ad = vec2(cos(align.x), sin(align.x));
        float ua2 = dot(dv, vec2(-ad.y, ad.x));
        float lw = 3.0 * u;
        if (dot(dv, ad) > 0.0 && abs(ua2) < lw * 1.7) {
            float t = abs(ua2) / (lw * 1.7);
            float q = 1.0 - t * t;
            float dd = 4.4 * u * align.y;
            H += -q * q * dd;
            S += -(4.0 * t * q / (lw * 1.7) * dd * (ua2 < 0.0 ? -1.0 : 1.0)) * dot(vec2(-ad.y, ad.x), LIGHT);
        }
    }

    // ---- the material ---------------------------------------------------------------------------
    float sA = mix(sandAlpha, 1.0, opaqueMode) * groundCov;
    vec3 sc = mix(cSand.rgb, cFloor.rgb, ringTone);
    sc = mix(sc, cErr.rgb, stripe * 0.35);
    vec4 pm = vec4(sc * sA, sA);
    float depthN = clamp(-H / max(dep, 1e-3), 0.0, 1.0);
    float fl = depthN * lightK.z;
    pm = pm * (1.0 - fl) + vec4(cFloor.rgb, 1.0) * fl * sA;
    float hi = clamp(S * lightK.x * lightK.w, 0.0, 1.0);
    float lo2 = clamp(-S * lightK.y, 0.0, 1.0);
    pm = pm * (1.0 - hi) + vec4(cHi.rgb, 1.0) * hi * max(sA, 0.55);
    vec3 loC = mix(cLo.rgb, cErr.rgb, stripe * 0.4);
    pm = pm * (1.0 - lo2) + vec4(loC, 1.0) * lo2 * max(sA, 0.55);
    // brushed metal on the ring faces: fine lines round the dial and the anisotropic sheen of such a finish -- two lobes
    // along the light's axis, none across it
    if (detail.x > 0.001 && rr > 0.0) {
        float face = (1.0 - depthN) * (1.0 - hi) * (1.0 - lo2);
        float br = fract(floor(rr * 1.1) * 0.7548777) - 0.5;      // a cheap hash of the brush line's index (no sin)
        float cl = dot(rh, vec2(-0.5048, -0.8632));               // cos of the angle to the light's axis, without a trig call
        float c2 = cl * cl, c4 = c2 * c2;
        float lobe = c4 * c4 * c2 * c2;                           // (cos^2)^5 as multiplications
        float k = detail.x * face * (0.24 * lobe + 0.05);
        pm = pm * (1.0 + detail.x * 0.03 * br * face);
        pm = pm * (1.0 - k) + vec4(cHi.rgb, 1.0) * k * max(sA, 0.55);
    }
    // the clear's end: the scored grooves ahead of the cutter (the entrance leaves them showing too) go with the rest
    fragColor = pm * (tone.z * qt_Opacity);
}
