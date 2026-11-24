pragma ComponentBehavior: Bound

import QtQuick

import "../../common/board"

// =============================================================================
// SiliconIsland.qml -- silicon's theme island: a BoardIsland (modules/common/board/BoardIsland.qml: the cut-out, the old-palette ghost faded over the live
// scene on the picture's own clock) whose ghost is a second SiliconScene given every input of the first (one binding each: the scene is a pure function
// of its inputs and `time`, particles included: "a film that sets time per frame draws what the live scene draws") but the OLD palette and mode.
// =============================================================================
BoardIsland {
    id: root

    ghostContent: Component {
        SiliconScene {
            id: ghost
            width: root.scene.width
            height: root.scene.height
            oldMap: root.oldMap
            oldDark: root.oldDark

            family: root.scene.family
            renderScale: root.scene.renderScale
            lightAngle: root.scene.lightAngle
            lightElevation: root.scene.lightElevation
            shadowStrength: root.scene.shadowStrength
            pkgQuarter: root.scene.pkgQuarter
            pkgRise: root.scene.pkgRise
            cardLift: root.scene.cardLift
            cardDissolve: root.scene.cardDissolve
            plugIn: root.scene.plugIn
            hdmiIn: root.scene.hdmiIn
            lever: root.scene.lever
            patchMargin: root.scene.patchMargin
            cardSettleMs: root.scene.cardSettleMs
            time: root.scene.time
            power: root.scene.power
            live: root.scene.live
            cpuZone: root.scene.cpuZone
            gpuZone: root.scene.gpuZone
            muxBreath: root.scene.muxBreath
            muxBreathS: root.scene.muxBreathS
            muxBreathDepth: root.scene.muxBreathDepth
            lensStrength: root.scene.lensStrength
            fxPlinth: root.scene.fxPlinth
            fxTrace: root.scene.fxTrace
            fxOrbits: root.scene.fxOrbits
            fxStream: root.scene.fxStream
            profile: root.scene.profile
            cpuSymbol: root.scene.cpuSymbol
            cpuNextProfile: root.scene.cpuNextProfile
            cpuDerez: root.scene.cpuDerez
            cpuLoad: root.scene.cpuLoad
            cores: root.scene.cores
            cpuPhase: root.scene.cpuPhase
            tweak: root.scene.tweak
            gpuMode: root.scene.gpuMode
            gpuSymbol: root.scene.gpuSymbol
            gpuNextMode: root.scene.gpuNextMode
            gpuDerez: root.scene.gpuDerez
            dgpuAwake: root.scene.dgpuAwake
            gpuUtil: root.scene.gpuUtil
            gpuPhase: root.scene.gpuPhase
            beam: root.scene.beam
            igpuBusy: root.scene.igpuBusy
            fill: root.scene.fill
            flowW: root.scene.flowW
            flowPhase: root.scene.flowPhase
            eventAge: root.scene.eventAge
            eventKind: root.scene.eventKind
            limitOn: root.scene.limitOn
            lock: root.scene.lock
            figures: root.scene.figures
            memory: root.scene.memory
        }
    }
}
