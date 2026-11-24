.pragma library

// =============================================================================
// Astro.js -- where the sun and the moon are, for the detail screen's sun/moon
// altitude curves and the moon's illumination.
//
//     Astro.getPosition(ms, lat, lon)      -> { altitude, azimuth }   radians; altitude geometric (no refraction)
//     Astro.getMoonPosition(ms, lat, lon)  -> { altitude, azimuth, distance, parallacticAngle }   altitude with refraction
//     Astro.getMoonIllumination(ms)        -> { fraction, phase, angle }
//     Astro.sunAltitudeDeg(ms, lat, lon)   -> degrees
//     Astro.moonAltitudeDeg(ms, lat, lon)  -> degrees
//     Astro.crossings(fn, fromMs, toMs, level, stepMin) -> [ { ms, rising } ]
//         every instant in [fromMs, toMs] where fn(ms) crosses `level`, found by
//         a coarse scan and a bisection to the second. Sunrise and sunset are
//         the sun's geometric altitude crossing -0.833° (34' of refraction
//         plus the 16' semi-diameter), which is what Open-Meteo reports.
//
// Times are epoch MILLISECONDS, like everything in the model; latitude and
// longitude in degrees (east positive). Pure JS, no Qt.
//
// A compact port of SunCalc (https://github.com/mourner/suncalc), which is
//
//   Copyright (c) 2014, Vladimir Agafonkin
//   All rights reserved.
//
//   Redistribution and use in source and binary forms, with or without
//   modification, are permitted provided that the following conditions are met:
//
//   1. Redistributions of source code must retain the above copyright notice,
//      this list of conditions and the following disclaimer.
//   2. Redistributions in binary form must reproduce the above copyright
//      notice, this list of conditions and the following disclaimer in the
//      documentation and/or other materials provided with the distribution.
//
//   THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
//   AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
//   IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
//   ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
//   LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
//   CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
//   SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
//   INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
//   CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
//   ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
//   POSSIBILITY OF SUCH DAMAGE.
// =============================================================================

var PI = Math.PI;
var RAD = PI / 180;
var DAY_MS = 86400000;
var J1970 = 2440588;
var J2000 = 2451545;
// Obliquity of the ecliptic.
var E = RAD * 23.4397;

function toDays(ms) {
    return ms / DAY_MS - 0.5 + J1970 - J2000;
}

function rightAscension(l, b) {
    return Math.atan2(Math.sin(l) * Math.cos(E) - Math.tan(b) * Math.sin(E), Math.cos(l));
}
function declination(l, b) {
    return Math.asin(Math.sin(b) * Math.cos(E) + Math.cos(b) * Math.sin(E) * Math.sin(l));
}
function azimuth(H, phi, dec) {
    return Math.atan2(Math.sin(H), Math.cos(H) * Math.sin(phi) - Math.tan(dec) * Math.cos(phi));
}
function altitude(H, phi, dec) {
    return Math.asin(Math.sin(phi) * Math.sin(dec) + Math.cos(phi) * Math.cos(dec) * Math.cos(H));
}
function siderealTime(d, lw) {
    return RAD * (280.16 + 360.9856235 * d) - lw;
}
// Refraction near the horizon, in radians, for an apparent altitude h.
function astroRefraction(h) {
    if (h < 0)
        h = 0;
    return 0.0002967 / Math.tan(h + 0.00312536 / (h + 0.08901179));
}

// ---- the sun ---------------------------------------------------------------
function solarMeanAnomaly(d) {
    return RAD * (357.5291 + 0.98560028 * d);
}
function eclipticLongitude(M) {
    const C = RAD * (1.9148 * Math.sin(M) + 0.02 * Math.sin(2 * M) + 0.0003 * Math.sin(3 * M));
    const P = RAD * 102.9372;   // perihelion of the Earth
    return M + C + P + PI;
}
function sunCoords(d) {
    const M = solarMeanAnomaly(d);
    const L = eclipticLongitude(M);
    return { dec: declination(L, 0), ra: rightAscension(L, 0) };
}

function getPosition(ms, lat, lon) {
    const lw = RAD * -lon;
    const phi = RAD * lat;
    const d = toDays(ms);
    const c = sunCoords(d);
    const H = siderealTime(d, lw) - c.ra;
    return { azimuth: azimuth(H, phi, c.dec), altitude: altitude(H, phi, c.dec) };
}

// ---- the moon ---------------------------------------------------------------
function moonCoords(d) {
    const L = RAD * (218.316 + 13.176396 * d);   // ecliptic longitude
    const M = RAD * (134.963 + 13.064993 * d);   // mean anomaly
    const F = RAD * (93.272 + 13.229350 * d);    // mean distance
    const l = L + RAD * 6.289 * Math.sin(M);     // longitude
    const b = RAD * 5.128 * Math.sin(F);         // latitude
    const dt = 385001 - 20905 * Math.cos(M);     // distance, km
    return { ra: rightAscension(l, b), dec: declination(l, b), dist: dt };
}

function getMoonPosition(ms, lat, lon) {
    const lw = RAD * -lon;
    const phi = RAD * lat;
    const d = toDays(ms);
    const c = moonCoords(d);
    const H = siderealTime(d, lw) - c.ra;
    let h = altitude(H, phi, c.dec);
    const pa = Math.atan2(Math.sin(H), Math.tan(phi) * Math.cos(c.dec) - Math.sin(c.dec) * Math.cos(H));
    h = h + astroRefraction(h);
    return { azimuth: azimuth(H, phi, c.dec), altitude: h, distance: c.dist, parallacticAngle: pa };
}

// fraction: the lit share of the disc; phase: 0 new, 0.25 first quarter,
// 0.5 full, 0.75 last quarter; angle: the bright limb's position angle.
function getMoonIllumination(ms) {
    const d = toDays(ms);
    const s = sunCoords(d);
    const m = moonCoords(d);
    const sdist = 149598000;   // distance from Earth to Sun, km
    const phi = Math.acos(Math.sin(s.dec) * Math.sin(m.dec) + Math.cos(s.dec) * Math.cos(m.dec) * Math.cos(s.ra - m.ra));
    const inc = Math.atan2(sdist * Math.sin(phi), m.dist - sdist * Math.cos(phi));
    const angle = Math.atan2(Math.cos(s.dec) * Math.sin(s.ra - m.ra),
                             Math.sin(s.dec) * Math.cos(m.dec) - Math.cos(s.dec) * Math.sin(m.dec) * Math.cos(s.ra - m.ra));
    return { fraction: (1 + Math.cos(inc)) / 2, phase: 0.5 + 0.5 * inc * (angle < 0 ? -1 : 1) / PI, angle: angle };
}

// ---- degrees, for the chart -------------------------------------------------
function sunAltitudeDeg(ms, lat, lon) {
    return getPosition(ms, lat, lon).altitude / RAD;
}
function moonAltitudeDeg(ms, lat, lon) {
    return getMoonPosition(ms, lat, lon).altitude / RAD;
}

// Every crossing of `level` by fn(ms) in [fromMs, toMs]: a scan every
// `stepMin` minutes, then a bisection to within a second on each sign change.
// Returns [ { ms, rising } ] in time order.
function crossings(fn, fromMs, toMs, level, stepMin) {
    const step = Math.max(1, stepMin || 10) * 60000;
    const out = [];
    let t0 = fromMs;
    let v0 = fn(t0) - level;
    while (t0 < toMs) {
        const t1 = Math.min(toMs, t0 + step);
        const v1 = fn(t1) - level;
        if ((v0 < 0 && v1 >= 0) || (v0 >= 0 && v1 < 0)) {
            let a = t0, b = t1, va = v0;
            while (b - a > 1000) {
                const m = (a + b) / 2;
                const vm = fn(m) - level;
                if ((va < 0) === (vm < 0)) { a = m; va = vm; } else { b = m; }
            }
            out.push({ ms: Math.round((a + b) / 2), rising: v1 >= 0 });
        }
        t0 = t1;
        v0 = v1;
    }
    return out;
}

// The sunrise/sunset convention: the geometric centre at -0.833 degrees.
var SUN_HORIZON_DEG = -0.833;
