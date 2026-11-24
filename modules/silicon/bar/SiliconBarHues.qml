import QtQuick

import "../../common/theme"

// =============================================================================
// SiliconBarHues.qml -- the ONE place the bar button's hues are named: silicon's Theme tokens
// (CONTRACT.md §1; light and dark in themes/eva.json), so the theme crossfade reaches every hue
// with no clock of its own.
// =============================================================================
QtObject {
    // 0 Quiet, 1 Balanced, 2 Performance
    function profile(p: int): color {
        return p === 0 ? Theme.profileQuiet : (p === 1 ? Theme.profileBalanced : Theme.profilePerformance);
    }

    // silicon's step order (CONTRACT.md §6): 0 Integrated, 1 Smart, 2 Hybrid, 3 dGPU-only
    function gpu(m: int): color {
        return m === 0 ? Theme.gpuIntegrated : (m === 1 ? Theme.gpuSmart : (m === 2 ? Theme.gpuHybrid : Theme.gpuDgpu));
    }

    readonly property color tweak: Theme.profileTweak
}
