pragma ComponentBehavior: Bound

import QtQuick

import "../parts"

// =============================================================================
// UpdateAskBody.qml -- Yes and No for a plain question of yay's or pacman's, on the card.
//
//   def        "Y" | "N" | "": the tool's own default answer; its button stands accented, as in the
//              update popup's prompt banner
//   answer     function (yes: bool): where the click goes (the notifier writes "y" or "n" to the run)
//   hostCard   handed in by the card (its style and font)
//
// The question itself is the card's title ("Proceed with installation?"): the prompt's own words, said
// once. A question with more to it than yes or no (a package list, a diff, an editor) has no body of this
// kind: its card opens the popup at the prompt. The buttons are the card's own CardButton, so they take its
// style, size and shadow; the record carries no action list, because an action would consume the card
// (and Yes would not be the only way out).
// =============================================================================
Item {
    id: root

    property string def: ""
    property var answer: null
    property var hostCard: null
    // One answer per question: the card stays up for a moment while the run takes it.
    property bool _sent: false

    implicitHeight: Math.ceil(row.implicitHeight) + 4

    function _send(yes) {
        if (root._sent)
            return;
        root._sent = true;
        if (typeof root.answer === "function")
            root.answer(yes);
    }

    Row {
        id: row
        y: 2
        spacing: root.hostCard && root.hostCard._actionGap ? root.hostCard._actionGap : 6

        CardButton {
            text: "Yes"
            accent: root.def === "Y"
            enabled: !root._sent
            style: root.hostCard ? root.hostCard.style : null
            fontFamily: root.hostCard && root.hostCard.fontFamily ? root.hostCard.fontFamily : "Inter"
            onClicked: root._send(true)
        }
        CardButton {
            text: "No"
            accent: root.def === "N"
            enabled: !root._sent
            style: root.hostCard ? root.hostCard.style : null
            fontFamily: root.hostCard && root.hostCard.fontFamily ? root.hostCard.fontFamily : "Inter"
            onClicked: root._send(false)
        }
    }
}
