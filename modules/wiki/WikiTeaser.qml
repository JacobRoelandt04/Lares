pragma ComponentBehavior: Bound

import QtQuick

import "../common/components/Mix.js" as Mix
import "../common/theme"
import "data/WikiCardModel.js" as Card
import "WikiGlyphs.js" as Glyphs

// =============================================================================
// WikiTeaser.qml -- one line at the launcher's foot: the day's Discover
// article, "<glyph> Today: <title>". The whole line is the link.
//
//   service   the wiki service (WikiService / WikiMock); no service -> 0 x 0
//             and nothing created
//   groundColor   the fill of the popup it stands on (the hover wash is mixed
//             from it)
//   active    gates the one motion, the 160 ms presence fade of a card that
//             lands; false shows it at once
//
// IT IS 18 PX HIGH WHENEVER THERE IS A SERVICE, card or not: the launcher's
// teaser slot is static, so typing (or a card arriving) never resizes the
// popup. With nothing to show the slot is simply blank. Width is the host's;
// the title elides to it. Discover only.
//
// Hover: the text takes the primary ink and a wash appears (one eased
// fraction), and the pointer turns to a hand. Nothing else announces the link.
// Whole-pixel positions; the category glyph is the family's, in its hue token
// resolved here.
// =============================================================================
Item {
    id: root

    property var service: null
    property color groundColor: Theme.surface
    property string fontFamily: "Inter"
    property bool active: true
    // Where the glyph and the words start, and the hover wash's radius: a host
    // whose rows have an icon column passes its own numbers so the line reads as
    // one of its rows (the launcher: the glyph centred in the icon column, the
    // words on the names' edge, the rows' radius).
    property real glyphX: 6
    property real textX: 26
    property real washRadius: 6

    signal activated()

    readonly property var card: root.service ? root.service.card("discover") : null

    implicitWidth: root.service ? 380 : 0
    implicitHeight: root.service ? 18 : 0

    readonly property bool _shown: !!root.card
    property bool _live: false
    property real _presence: root._shown ? 1 : 0
    Behavior on _presence {
        enabled: root._live && root.active
        NumberAnimation {
            duration: 160
            easing.type: Easing.OutCubic
        }
    }
    Component.onCompleted: Qt.callLater(function () {
        root._live = true;
    })

    Loader {
        anchors.fill: parent
        active: !!root.service
        sourceComponent: faceComp
    }

    Component {
        id: faceComp

        Item {
            id: face
            anchors.fill: parent

            property real hover: hit.containsMouse ? 1 : 0
            Behavior on hover {
                NumberAnimation {
                    duration: 120
                    easing.type: Easing.OutCubic
                }
            }
            readonly property color hue: {
                const k = root.card ? root.card.hueToken : "";
                return k && Theme[k] !== undefined ? Theme[k] : Theme.textMuted;
            }
            readonly property real inset: 6
            readonly property real glyphBox: 14

            FontMetrics {
                id: fm
                font.family: root.fontFamily
                font.pixelSize: 11
            }

            Rectangle {
                anchors.fill: parent
                radius: root.washRadius
                visible: face.hover > 0
                color: Mix.c(root.groundColor, Theme.panelSunk, face.hover)
            }

            Item {
                anchors.fill: parent
                opacity: root._presence
                visible: root._presence > 0

                Text {
                    x: Math.round(root.glyphX)
                    y: Math.round((face.height - face.glyphBox) / 2)
                    width: face.glyphBox
                    height: face.glyphBox
                    text: root.card ? root.card.glyph : ""
                    color: face.hue
                    font.family: Glyphs.FONT_FAMILY
                    font.pixelSize: 14
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }
                Text {
                    x: Math.round(root.textX)
                    y: Math.round((face.height - Math.ceil(fm.height)) / 2)
                    width: Math.max(0, face.width - x - face.inset)
                    text: Card.teaserText(root.card)
                    color: Mix.c(Theme.textMuted, Theme.textPrimary, face.hover)
                    font.family: root.fontFamily
                    font.pixelSize: 11
                    wrapMode: Text.NoWrap
                    maximumLineCount: 1
                    elide: Text.ElideRight
                }
            }

            MouseArea {
                id: hit
                anchors.fill: parent
                enabled: root._shown
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.PointingHandCursor
                onClicked: root.activated()
            }
        }
    }
}
