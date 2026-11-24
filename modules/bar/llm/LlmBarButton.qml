pragma ComponentBehavior: Bound

import QtQuick

import "../../common/theme"
import "../../common/glyphs"
import "../../common/components"
import "../../common/components/Mix.js" as Mix
import "parts/SparklePose.js" as Pose

// =============================================================================
// LlmBarButton.qml -- the chat's icon: a four-pointed star, md-star_four_points U+F0AE2, ONE shape.
//
// The colour is the state, each over the one before (no glyph swap: the bar's on/off glyphs keep one shape):
//
//   no model in memory   the muted ink
//   a model is loaded    the star's ON hue (BarHues `llmOn`): the residency fact, /api/ps as of its last refresh (LlmService
//                        reads it the same way for `canUnload`)
//   generating           the accent       (a turn is streaming, or a tool runs, or a confirmation is parked, or a SPOKEN ask
//                                         waits in the queue: it opens no popup, so this is how the user sees it was heard)
//   needs you            the warn colour  (a confirmation waits for an answer, or an answer finished while no chat was open;
//                                         the second is latched here and goes when a chat opens; a spoken ask's answer is not
//                                         latched: its toast is its notice)
//
// "Generating" and "needs you" stay readable because neither is the on hue (the table keeps `llmOn` off the accent and the
// warn colour), and the hover (`llmHover`) is none of the three. All eased fractions (160 ms) mixed with Mix.js. The click is
// the host's (ShellFrame -> LlmBarOwner.toggle()).
//
// THE FLOURISH (feedback/llm.md "Bar glyph flourish"): THE SPARK KINDLES -- the star winds back, flares through a quarter turn
// and throws two small stars of its own shape, which wink out (SparklePose.js). It plays when the pointer comes onto the star
// (GlyphFlourish: once per entry) and in the OLED care's random turns (group `llm`, decorative: it says nothing about the
// chat -- the colour does that, and the flourish keeps whatever colour the star has).
// `llm` is LlmServices; null = nothing to say (a bare icon, filled, at rest).
// =============================================================================
BarGlyphButton {
    id: btn

    property var llm: null

    readonly property var _svc: btn.llm ? btn.llm.service : null
    readonly property bool loaded: {
        const s = btn._svc;
        const b = s ? s.backend : null;
        if (!b || !b.loaded || !s.model)
            return false;
        const l = b.loaded[s.model];
        return !!l && (l.size || 0) > 0;
    }
    // Working: a turn runs, or a spoken ask has been heard and waits for its turn (the queue's wait for the model list shows too).
    readonly property bool generating: !!btn._svc && (btn._svc.generating === true || btn._svc.voiceQueued === true)
    // An answer that finished while nobody had a chat open: latched until one opens.
    property bool _unseenAnswer: false
    // The conversation a spoken turn just ended in (`voiceAnswered` comes right before `answerCompleted`): its toast is the notice.
    property string _voiceConv: ""
    readonly property bool needsYou: (!!btn._svc && btn._svc.pendingConfirm !== null && btn._svc.pendingConfirm !== undefined) || btn._unseenAnswer

    Connections {
        target: btn._svc
        ignoreUnknownSignals: true
        function onVoiceAnswered(convId: string): void {
            btn._voiceConv = convId;
        }
        function onAnswerCompleted(convId: string): void {
            const spoken = btn._voiceConv === convId;
            btn._voiceConv = "";
            if (!spoken && (!btn.llm || !btn.llm.attended))
                btn._unseenAnswer = true;
        }
        function onAnswerFailed(convId: string): void {
            btn._voiceConv = "";
        }
    }
    Connections {
        target: btn.llm
        ignoreUnknownSignals: true
        function onAttendedChanged(): void {
            if (btn.llm && btn.llm.attended)
                btn._unseenAnswer = false;
        }
    }

    property real _genF: btn.generating ? 1 : 0
    Behavior on _genF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }
    property real _loadedF: btn.loaded ? 1 : 0
    Behavior on _loadedF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }
    property real _needF: btn.needsYou ? 1 : 0
    Behavior on _needF {
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }

    glyph: String.fromCodePoint(0xF0AE2)
    ink: Mix.c3(Mix.c(Theme.textMuted, BarHues.llmOn, btn._loadedF), Theme.accent, btn._genF, Theme.warn, btn._needF)
    hoverInk: BarHues.llmHover

    // ---- the flourish ----
    property bool flourishEnabled: true
    readonly property alias flourish: kindle
    GlyphFlourish {
        id: kindle
        group: "llm"
        decorative: true
        armed: btn.flourishEnabled
        ms: Pose.LIFE
        // a second ask while it plays is ignored: a restart would snap the star back out of its turn
        overlap: "ignore"
        hoverArea: btn.area
    }
    readonly property var _pose: kindle.playing ? Pose.frame(kindle.t, kindle.ms, null, btn.glyphSize, btn.glyphOrigin.x, btn.glyphOrigin.y) : null
    posing: kindle.playing
    parts: btn._pose ? btn._pose.parts : []
}
