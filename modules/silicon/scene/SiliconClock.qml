pragma ComponentBehavior: Bound

import QtQuick

import "../../common/board"

// =============================================================================
// SiliconClock.qml -- silicon's scene clock: a BoardClock (the pacing, the idle ladder, the theme hold; modules/common/board/BoardClock.qml) that
// integrates the phases silicon's shaders read each tick: the CPU pulse train (cycles), the dGPU's slot lines (cycles) and the battery's flow (mm).
// A phase is the sum of rate x dt, never tempo x time: a change of load changes the SPEED of what is already in flight and never jumps a phase.
// =============================================================================
BoardClock {
    id: root

    // ---- the tempo (cycles or mm per second), tunable on the mockup's Motion tab ----
    // CPU: the pulse train toward the package. Quiet .. Performance sets the base (the scene's pkgQuarter
    // 0 .. 2, so it glides through a change), the load scales it; 0.9 cycles/s is what the films run at.
    property real cpuTempoQuiet: 0.55
    property real cpuTempoPerformance: 1.10
    property real cpuLoadSlow: 0.6          // x the base at no load
    property real cpuLoadFast: 1.4          // x the base at full load
    // dGPU: the pulse train out of the slot, while it is awake
    property real gpuTempoIdle: 0.5
    property real gpuTempoBusy: 1.4
    // battery: the flow along the copper, mm/s: a floor that grows with the watts, up to a cap
    property real flowBase: 14
    property real flowPerWatt: 0.5
    property real flowMax: 60

    onAdvance: (dt, tempo) => {
        const sc = root.scene;
        // the tempo follows the profile the package is turning to or from: folded back onto Quiet .. Performance,
        // so a half turn round the end (Performance -> Quiet, 2 -> 4) glides the tempo down, not clamps it
        const qm = ((sc.pkgQuarter % 4) + 4) % 4;
        const q = Math.max(0, Math.min(2, qm > 2 ? 4 - qm : qm)) / 2;
        const load = Math.max(0, Math.min(1, sc.cpuLoad));
        const base = root.cpuTempoQuiet + (root.cpuTempoPerformance - root.cpuTempoQuiet) * q;
        sc.cpuPhase += base * (root.cpuLoadSlow + (root.cpuLoadFast - root.cpuLoadSlow) * load) * dt * tempo;
        const util = Math.max(0, Math.min(1, sc.gpuUtil));
        sc.gpuPhase += (root.gpuTempoIdle + (root.gpuTempoBusy - root.gpuTempoIdle) * util) * dt * tempo;
        sc.flowPhase += Math.min(root.flowMax, root.flowBase + root.flowPerWatt * Math.abs(sc.flowW)) * dt * tempo;
    }
}
