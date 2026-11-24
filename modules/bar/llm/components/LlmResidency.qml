pragma ComponentBehavior: Bound

import QtQuick

// =============================================================================
// LlmResidency.qml -- the chat put away, and how long its model stays loaded after that (llm.jsonc "unloadAfterMin"). ONE per shell
// (LlmServices), never one per screen.
//
// NOBODY LOOKS AT THE CHAT (`attended` falls: the last popup of it on any screen is closing), or an answer ends with it shut: the empty
// conversation is put away (`pruneEmptyActive`) and the card let go (`releaseModel`, which itself refuses while an answer is streaming or the
// session is pinned, and waits for a title). Decided one turn after the event, when the host's aggregate has settled (a handler reads a stale
// binding on the property it is handling).
//
// `afterMin` minutes is what the model stays first (0: none; under 0: for good), counted from the close, or from the end of an answer that
// was still running then. ONLY A TYPED CHAT KEEPS ITS MODEL: a spoken ask lets go as it ends -- unless the chat's own time is still running,
// which it does not add to.
// =============================================================================
Item {
    id: root

    property var service: null          // LlmService
    property bool attended: false
    property real afterMin: 0
    // The model is loaded for nothing but that time.
    readonly property bool waiting: clock.running

    // A typed turn has run since the model was last let go, and the latest turn was a spoken one.
    property bool _typed: false
    property bool _spoken: false

    onAttendedChanged: Qt.callLater(root._settle)
    // Said anew while nobody looks: the time that runs is the new one.
    onAfterMinChanged: {
        clock.stop();
        if (root._typed)
            Qt.callLater(root._settle);
    }
    Connections {
        target: root.service
        function onTurnStarted(convId) {
            root._spoken = root.service.spoken;
            if (!root._spoken)
                root._typed = true;
        }
        function onGeneratingChanged() {
            Qt.callLater(root._settle);
        }
    }

    Timer {
        id: clock
        interval: Math.max(1, root.afterMin * 60000)
        onTriggered: root._letGo()
    }

    function _settle() {
        const svc = root.service;
        if (!svc)
            return;
        if (root.attended) {
            clock.stop();
            return;
        }
        svc.pruneEmptyActive();
        if (root.afterMin === 0 || !root._typed)
            root._letGo();
        else if (root.afterMin > 0 && !(clock.running && root._spoken))
            clock.restart();
    }

    function _letGo() {
        clock.stop();
        root._typed = false;
        root.service.releaseModel();
    }
}
