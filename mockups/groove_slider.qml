pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts

import "modules/common/components"
import "modules/common/mockup"
import "modules/common/theme"

// =============================================================================
// mockups/groove_slider.qml -- GrooveSlider, the shell's value slider: a ball in a carved channel, with the
// perpendicular-drag mute.
//
// The stage holds a horizontal slider (the one the panel tunes) and a vertical one that follows every value of it,
// both dressed in the theme's tokens as the OSD dresses its level (the slider's own colour defaults are eva-light
// literals; every host sets them). The Run tab drives the state a host would: the value, the mute, boost and the
// mute mechanic. On the stage itself: drag the ball along the groove for the value, across it to snap into or out of
// mute; a click on the groove jumps the ball, a click on the ball puffs it, a right click toggles boost, the wheel
// moves the value.
//
// Save writes GrooveSlider's own defaults, which every host that leaves a value unset follows (the OSD level, the
// audio rows, the PDF menu, silicon's settled sliders; the size scale, the ball and the colours each host sets).
//
//   quickshell -p mockups/groove_slider.qml
// =============================================================================
MockupWindow {
    id: win

    moduleId: "groove_slider"
    title: "Groove slider mockup"
    stageLabel: "GrooveSlider: horizontal and vertical"
    content: strip
    target: hSlider
    zoom: 1.5

    lists: ({
            sliderParams: win.sliderParams
        })

    tabDefs: [
        {
            name: "Run",
            page: runPage
        },
        {
            name: "Slider",
            subs: [
                {
                    name: "Shape",
                    lists: ["sliderParams"],
                    groups: ["Geometry", "Carve", "Ball shadow"]
                },
                {
                    name: "Motion",
                    lists: ["sliderParams"],
                    groups: ["Springs", "Mute swap", "Drag"]
                },
                {
                    name: "Particles",
                    lists: ["sliderParams"],
                    groups: ["Sparks", "Mute burst", "Fidget"]
                }
            ]
        }
    ]

    // ---- the state a host drives ------------------------------------------------
    QtObject {
        id: host
        property real value: 0.55
        property bool muted: false
        property bool allowBoost: false
        property bool muteEnabled: true
    }


    // ---- the drop-in content -----------------------------------------------------
    Item {
        id: strip

        readonly property real pad: 12
        readonly property real gap: 24
        readonly property real length: 320
        implicitWidth: Math.ceil(strip.length + vSlider.implicitWidth) + strip.gap + 2 * strip.pad
        implicitHeight: Math.ceil(Math.max(hSlider.implicitHeight, strip.length)) + 2 * strip.pad

        GrooveSlider {
            id: hSlider
            // the theme's dress, as the OSD's level wears it
            surfaceColor: Theme.surface
            grooveColor: Theme.panelSunk
            grooveBevelColor: Theme.bevel
            grooveShadowColor: Theme.border
            ballColor: Theme.accent
            ballMutedColor: Theme.shadowDeep
            muteBarColor: Theme.border
            muteBarBevelColor: Theme.bevel
            muteBarShadowColor: Theme.shadowDeep
            ballMutedShadowColor: Theme.shadowDeep
            muteBurstColor: Theme.accentBevel
            unmuteBurstColorStart: Theme.accentBevel
            unmuteBurstColorEnd: Theme.accent
            value: host.value
            muted: host.muted
            allowBoost: host.allowBoost
            muteEnabled: host.muteEnabled
            onUserChangedValue: v => host.value = v
            onUserToggledMute: host.muted = !host.muted
            onUserToggledBoost: host.allowBoost = !host.allowBoost
            x: strip.pad
            y: Math.round((strip.height - height) / 2)
            width: strip.length
            height: Math.round(hSlider.implicitHeight)
            orientation: "horizontal"
        }
        GrooveSlider {
            id: vSlider
            surfaceColor: Theme.surface
            grooveColor: Theme.panelSunk
            grooveBevelColor: Theme.bevel
            grooveShadowColor: Theme.border
            ballColor: Theme.accent
            ballMutedColor: Theme.shadowDeep
            muteBarColor: Theme.border
            muteBarBevelColor: Theme.bevel
            muteBarShadowColor: Theme.shadowDeep
            ballMutedShadowColor: Theme.shadowDeep
            muteBurstColor: Theme.accentBevel
            unmuteBurstColorStart: Theme.accentBevel
            unmuteBurstColorEnd: Theme.accent
            value: host.value
            muted: host.muted
            allowBoost: host.allowBoost
            muteEnabled: host.muteEnabled
            onUserChangedValue: v => host.value = v
            onUserToggledMute: host.muted = !host.muted
            onUserToggledBoost: host.allowBoost = !host.allowBoost
            x: Math.round(strip.pad + strip.length + strip.gap)
            y: strip.pad
            width: Math.round(vSlider.implicitWidth)
            height: strip.length
            orientation: "vertical"
            sizeScale: hSlider.sizeScale
            ballSize: hSlider.ballSize
            barFatRatio: hSlider.barFatRatio
            barThinThickness: hSlider.barThinThickness
            edgePadding: hSlider.edgePadding
            grooveShadowWidth: hSlider.grooveShadowWidth
            grooveBevelWidth: hSlider.grooveBevelWidth
            ballShadowOpacity: hSlider.ballShadowOpacity
            ballShadowBlur: hSlider.ballShadowBlur
            boostSpringStiffness: hSlider.boostSpringStiffness
            boostSpringDamping: hSlider.boostSpringDamping
            recoverySpringStiffness: hSlider.recoverySpringStiffness
            recoverySpringDamping: hSlider.recoverySpringDamping
            barThicknessSwapDuration: hSlider.barThicknessSwapDuration
            barWavefrontSpan: hSlider.barWavefrontSpan
            axisDecisionDeadzone: hSlider.axisDecisionDeadzone
            crossOffsetDeadzone: hSlider.crossOffsetDeadzone
            edgeInfluence: hSlider.edgeInfluence
            ballSquishStrength: hSlider.ballSquishStrength
            bendSigmaScale: hSlider.bendSigmaScale
            bendSigmaMin: hSlider.bendSigmaMin
            unmuteBendSigmaMultiplier: hSlider.unmuteBendSigmaMultiplier
            sparksEnabled: hSlider.sparksEnabled
            sparksSpeedThreshold: hSlider.sparksSpeedThreshold
            sparksAmountMultiplier: hSlider.sparksAmountMultiplier
            sparksBaseVelocity: hSlider.sparksBaseVelocity
            sparksScatter: hSlider.sparksScatter
            sparksLifetimeBase: hSlider.sparksLifetimeBase
            sparksLifetimeVariance: hSlider.sparksLifetimeVariance
            sparksMaxHistory: hSlider.sparksMaxHistory
            sparksSizeStart: hSlider.sparksSizeStart
            sparksSizeEnd: hSlider.sparksSizeEnd
            sparksDrag: hSlider.sparksDrag
            sparksSwirlStr: hSlider.sparksSwirlStr
            sparksSwirlProb: hSlider.sparksSwirlProb
            sparksBloomBlur: hSlider.sparksBloomBlur
            sparksBloomStrength: hSlider.sparksBloomStrength
            sparksBloomBrightness: hSlider.sparksBloomBrightness
            muteBurstCount: hSlider.muteBurstCount
            muteBurstSpeed: hSlider.muteBurstSpeed
            muteBurstLifetime: hSlider.muteBurstLifetime
            fidgetCount: hSlider.fidgetCount
            fidgetSpeed: hSlider.fidgetSpeed
            fidgetLifetime: hSlider.fidgetLifetime
            fidgetBallShrink: hSlider.fidgetBallShrink
            fidgetShrinkDuration: hSlider.fidgetShrinkDuration
        }
    }

    // =====================================================================
    //  THE RUN PAGE
    // =====================================================================
    pages: [
        MockupPage {
            id: runPage

            TipGroup {
                title: "Scenarios"
                blurb: "What a host hands the slider. The slider reports what the hand did (a value, a mute, a boost) and the host writes it back, as here."
            }
            TipRow {
                tip: "The value, 0 to the top of the range (1, or the boost maximum while boost is allowed). The ball glides to it on its spring."
                Layout.fillWidth: true
                Label {
                    text: "value"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
                Slider {
                    Layout.fillWidth: true
                    from: 0
                    to: host.allowBoost ? hSlider.boostMaxValue : 1
                    stepSize: 0.01
                    value: host.value
                    onMoved: host.value = value
                }
                Label {
                    text: Math.round(host.value * 100) + " %"
                    color: "#8A8A8C"
                    font.family: "Audiowide"
                    font.pixelSize: 13
                }
            }
            TipRow {
                tip: "muted: the bars trade thicknesses and the ball goes grey on the mute track. boost: the range grows past 100 % on its spring. mute mechanic: off, as the audio rows and the PDF menu have it -- no mute track, no snap, the ball's cross travel soft-limited both ways."
                Layout.fillWidth: true
                CheckBox {
                    text: "muted"
                    checked: host.muted
                    onToggled: host.muted = checked
                }
                CheckBox {
                    text: "boost"
                    checked: host.allowBoost
                    onToggled: host.allowBoost = checked
                }
                CheckBox {
                    text: "mute mechanic"
                    checked: host.muteEnabled
                    onToggled: host.muteEnabled = checked
                }
            }

            TipGroup {
                title: "State"
                blurb: "What the horizontal slider holds now."
            }
            Label {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: "value " + hSlider.value.toFixed(3) + "   range " + hSlider.maxValue.toFixed(2) + "   muted " + hSlider.muted
                      + "   needs " + hSlider.neededCross.toFixed(1) + " px across"
                color: "#8A8A8C"
                font.family: "Audiowide"
                font.pixelSize: 12
            }
        }
    ]

    readonly property var sliderParams: [
        {
            label: "size scale",
            prop: "sizeScale",
            group: "Geometry",
            blurb: "The channel the ball runs in, and the ball. Every size here is multiplied by the size scale.",
            tip: "Multiplies every size of the slider (bars, ball, padding, shadows). 1.5 is the component's own; each host sets its own (the OSD's 0.8, the audio rows', the PDF menu's), so this reaches only a host that sets none.",
            val: 1.5,
            from: 0.5,
            to: 3,
            step: 0.05
        },
        {
            label: "ball px",
            prop: "ballSize",
            group: "Geometry",
            tip: "The ball's diameter before the size scale. The fat bar is made at least this thick, so the ball always nests inside the channel. 14 is the workspaces' ball too.",
            val: 14,
            from: 6,
            to: 30,
            step: 1
        },
        {
            label: "fat ratio",
            prop: "barFatRatio",
            group: "Geometry",
            tip: "The active (fat) bar's thickness as a multiple of the ball, used while no explicit thickness is set: 1.4 leaves a small clearance round the nested ball.",
            val: 1.4,
            from: 1,
            to: 3,
            step: 0.05
        },
        {
            label: "thin bar px",
            prop: "barThinThickness",
            group: "Geometry",
            tip: "The inactive bar's thickness before the size scale: the thin mute track while unmuted, the thin main track while muted.",
            val: 4,
            from: 1,
            to: 12,
            step: 0.5
        },
        {
            label: "end pad px",
            prop: "edgePadding",
            group: "Geometry",
            tip: "Empty room at each end of the groove before the size scale, so the ball at 0 or full stays inside the slider's width.",
            val: 18,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "shadow px",
            prop: "grooveShadowWidth",
            group: "Carve",
            blurb: "The channel is carved into the surface: an inset shadow inside its edge, a light bevel outside.",
            tip: "Width of the inset shadow inside the channel's edge, px: 3 is the shell's carve on containers (Design language, Material).",
            val: 3,
            from: 0,
            to: 8,
            step: 0.5
        },
        {
            label: "bevel px",
            prop: "grooveBevelWidth",
            group: "Carve",
            tip: "Width of the light bevel outside the channel's edge, px. 0.5 keeps the gap between the ball's flat and the bar's outer edge from showing.",
            val: 0.5,
            from: 0,
            to: 4,
            step: 0.25
        },
        {
            label: "shadow opacity",
            prop: "ballShadowOpacity",
            group: "Ball shadow",
            blurb: "The soft shadow under the ball, in the ball's own colour.",
            tip: "Opacity of the ball's soft glow (its colour, or the muted one), 0 to 1.",
            val: 0.55,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "shadow blur px",
            prop: "ballShadowBlur",
            group: "Ball shadow",
            tip: "How far the ball's glow spreads, px (the blur of the shadow under it).",
            val: 14,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "boost stiffness",
            prop: "boostSpringStiffness",
            group: "Springs",
            blurb: "The springs the range and the ball settle on.",
            tip: "Stiffness of the spring that grows or shrinks the range when boost is switched (to the host's boost maximum): low is a slow, bouncy rescale.",
            val: 2.4,
            from: 0.5,
            to: 8,
            step: 0.1
        },
        {
            label: "boost damping",
            prop: "boostSpringDamping",
            group: "Springs",
            tip: "Damping of that spring, 0 to 1: 0.18 lets the range overshoot a little and settle.",
            val: 0.18,
            from: 0.02,
            to: 1,
            step: 0.01
        },
        {
            label: "recovery stiffness",
            prop: "recoverySpringStiffness",
            group: "Springs",
            tip: "Stiffness of the springs that bring the bar's bend, the ball's offset and its squish back to rest after a drag or a snap.",
            val: 3.2,
            from: 0.5,
            to: 8,
            step: 0.1
        },
        {
            label: "recovery damping",
            prop: "recoverySpringDamping",
            group: "Springs",
            tip: "Damping of those springs, 0 to 1: 0.20 is a jiggle that dies in a few swings.",
            val: 0.2,
            from: 0.02,
            to: 1,
            step: 0.01
        },
        {
            label: "swap ms",
            prop: "barThicknessSwapDuration",
            group: "Mute swap",
            blurb: "When the mute flips, the fat bar and the thin one trade places as a swell along the groove.",
            tip: "How long the fat and the thin bar take to trade thicknesses when the mute flips, ms.",
            val: 600,
            from: 100,
            to: 1500,
            step: 10
        },
        {
            label: "wavefront span",
            prop: "barWavefrontSpan",
            group: "Mute swap",
            tip: "How much of the groove the slope of the swelling bar spreads over, as a share of its length: a swell with a long soft front, not a step that sweeps along.",
            val: 0.35,
            from: 0.05,
            to: 1,
            step: 0.05
        },
        {
            label: "axis deadzone px",
            prop: "axisDecisionDeadzone",
            group: "Drag",
            blurb: "A drag along the groove sets the value; across it, it bends the bar toward the mute track and snaps over at the threshold.",
            tip: "How far the pointer moves before the drag decides between volume (along) and mute (across), px.",
            val: 6,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "cross deadzone px",
            prop: "crossOffsetDeadzone",
            group: "Drag",
            tip: "How far across the groove the pointer goes before the bar starts to bend and the ball to squish, px.",
            val: 4,
            from: 0,
            to: 20,
            step: 1
        },
        {
            label: "far edge follow",
            prop: "edgeInfluence",
            group: "Drag",
            tip: "How much the edge away from the drag bulges with it, as a share of the near edge's bend: 0.15 keeps the channel's far wall nearly still.",
            val: 0.15,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "squish share",
            prop: "ballSquishStrength",
            group: "Drag",
            tip: "The share of a cross drag that squishes the ball rather than bending the bar, 0 to 1.",
            val: 0.65,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "bend width",
            prop: "bendSigmaScale",
            group: "Drag",
            tip: "Width of the bend's bell curve as a share of the groove's length.",
            val: 0.12,
            from: 0.02,
            to: 0.5,
            step: 0.01
        },
        {
            label: "bend width floor",
            prop: "bendSigmaMin",
            group: "Drag",
            tip: "The narrowest the bend gets, in ball sizes, so a short groove still bends round the ball.",
            val: 1.4,
            from: 0.5,
            to: 4,
            step: 0.1
        },
        {
            label: "unmute bend",
            prop: "unmuteBendSigmaMultiplier",
            group: "Drag",
            tip: "How much wider the bend is while the ball snaps back out of mute.",
            val: 1.6,
            from: 1,
            to: 4,
            step: 0.1
        },
        {
            label: "sparks",
            prop: "sparksEnabled",
            group: "Sparks",
            blurb: "The sparks a fast ball throws behind it.",
            tip: "On: a fast ball trails sparks. The audio rows and the PDF menu switch them off; the OSD has them while the hand drives the level.",
            val: true
        },
        {
            label: "speed threshold",
            prop: "sparksSpeedThreshold",
            group: "Sparks",
            tip: "How fast the ball must move before it throws sparks.",
            val: 0.7,
            from: 0,
            to: 3,
            step: 0.05
        },
        {
            label: "amount",
            prop: "sparksAmountMultiplier",
            group: "Sparks",
            tip: "How many sparks per unit of speed.",
            val: 0.8,
            from: 0,
            to: 5,
            step: 0.05
        },
        {
            label: "inherited velocity",
            prop: "sparksBaseVelocity",
            group: "Sparks",
            tip: "How much of the ball's velocity a spark carries backwards.",
            val: 0.06,
            from: 0,
            to: 0.5,
            step: 0.01
        },
        {
            label: "scatter",
            prop: "sparksScatter",
            group: "Sparks",
            tip: "The random velocity each spark gets on top.",
            val: 50,
            from: 0,
            to: 200,
            step: 5
        },
        {
            label: "life ms",
            prop: "sparksLifetimeBase",
            group: "Sparks",
            tip: "A spark's base life, ms.",
            val: 350,
            from: 50,
            to: 2000,
            step: 10
        },
        {
            label: "life spread ms",
            prop: "sparksLifetimeVariance",
            group: "Sparks",
            tip: "A random extra on each spark's life, ms.",
            val: 500,
            from: 0,
            to: 2000,
            step: 10
        },
        {
            label: "trail length",
            prop: "sparksMaxHistory",
            group: "Sparks",
            tip: "How many past positions a spark's trail keeps.",
            val: 5,
            from: 1,
            to: 12,
            step: 1
        },
        {
            label: "size start",
            prop: "sparksSizeStart",
            group: "Sparks",
            tip: "A spark's size when it is thrown (times the size scale).",
            val: 1.8,
            from: 0.2,
            to: 6,
            step: 0.1
        },
        {
            label: "size end",
            prop: "sparksSizeEnd",
            group: "Sparks",
            tip: "A spark's size when it dies (times the size scale).",
            val: 0.6,
            from: 0,
            to: 4,
            step: 0.1
        },
        {
            label: "drag",
            prop: "sparksDrag",
            group: "Sparks",
            tip: "Air resistance on a spark.",
            val: 2.6,
            from: 0,
            to: 8,
            step: 0.1
        },
        {
            label: "swirl strength",
            prop: "sparksSwirlStr",
            group: "Sparks",
            tip: "How hard a spark swirls at the end of its life.",
            val: 0.4,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "swirl chance",
            prop: "sparksSwirlProb",
            group: "Sparks",
            tip: "The share of sparks that swirl.",
            val: 0.4,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "bloom blur",
            prop: "sparksBloomBlur",
            group: "Sparks",
            tip: "Blur of the glow over the sparks.",
            val: 18,
            from: 0,
            to: 64,
            step: 1
        },
        {
            label: "bloom strength",
            prop: "sparksBloomStrength",
            group: "Sparks",
            tip: "Strength of that glow.",
            val: 0.25,
            from: 0,
            to: 1,
            step: 0.05
        },
        {
            label: "bloom brightness",
            prop: "sparksBloomBrightness",
            group: "Sparks",
            tip: "Brightness of the glow layer.",
            val: 0.85,
            from: 0,
            to: 2,
            step: 0.05
        },
        {
            label: "burst count",
            prop: "muteBurstCount",
            group: "Mute burst",
            blurb: "The puff the snap into or out of mute throws.",
            tip: "How many particles the snap into or out of mute throws.",
            val: 14,
            from: 0,
            to: 40,
            step: 1
        },
        {
            label: "burst speed",
            prop: "muteBurstSpeed",
            group: "Mute burst",
            tip: "How fast they fly out.",
            val: 230,
            from: 20,
            to: 600,
            step: 10
        },
        {
            label: "burst life ms",
            prop: "muteBurstLifetime",
            group: "Mute burst",
            tip: "How long they live, ms.",
            val: 600,
            from: 100,
            to: 2000,
            step: 10
        },
        {
            label: "fidget count",
            prop: "fidgetCount",
            group: "Fidget",
            blurb: "A click on the ball that does not drag: it shrinks and puffs.",
            tip: "How many particles a click on the ball (no drag) puffs.",
            val: 10,
            from: 0,
            to: 30,
            step: 1
        },
        {
            label: "fidget speed",
            prop: "fidgetSpeed",
            group: "Fidget",
            tip: "How fast the puff flies out.",
            val: 130,
            from: 20,
            to: 400,
            step: 5
        },
        {
            label: "fidget life ms",
            prop: "fidgetLifetime",
            group: "Fidget",
            tip: "How long the puff lives, ms.",
            val: 520,
            from: 100,
            to: 2000,
            step: 10
        },
        {
            label: "ball shrink",
            prop: "fidgetBallShrink",
            group: "Fidget",
            tip: "How small the ball goes on the click, as a share of its size.",
            val: 0.85,
            from: 0.5,
            to: 1,
            step: 0.01
        },
        {
            label: "shrink ms",
            prop: "fidgetShrinkDuration",
            group: "Fidget",
            tip: "How long the shrink and its return take, ms.",
            val: 220,
            from: 50,
            to: 800,
            step: 10
        }
    ]
}
