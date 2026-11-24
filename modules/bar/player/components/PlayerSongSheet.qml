pragma ComponentBehavior: Bound

import QtQuick
import Quickshell.Io

import "../../../common/theme"
import "../../../common/scroll"
import "../../../common/components"
import "../../../common/components/Mix.js" as Mix
import "../../../common/components/MpdFidelity.js" as Fidelity
import "PlayerFormat.js" as Fmt

// =============================================================================
// PlayerSongSheet.qml -- everything known about ONE song, as a page of a panel's stack (PlayerPageStack).
//
// A song details sheet, after Auxio's song properties. The library's row menu, the queue's row menu and
// the album page all open one. It grows out of the row it came from and goes back to it as an album's
// page does (the stack's morph), lies on the panel's box, and has the page's sticky back row and a scroll
// of key / value lines:
//
//   from the daemon    title, artist(s), album, album artist, track and disc, date, genre, composer, label
//   from the file      the format as the chip says it, the file's AVERAGE bitrate (AudioBitrate: the
//                      audio bytes over the duration, never the decoder's moving reading), its size, its
//                      path, when it was last changed
//   from the tags      whatever else the file's own tags hold (ffprobe, AudioTags: BPM, ISRC, key, release
//                      type, comment...), so the sheet shows the file and not only what mpd indexes
//
// NOTHING RUNS WHILE IT IS SHUT: the three readers (the daemon's `find`, ffprobe twice, `stat`) exist only
// while the page does. Rows are plain facts. `first` ({ title, artist, album }, what the row it grew out of
// knew) stands in the head until the daemon has answered, so the page is whole from its first frame.
// =============================================================================
Item {
    id: sheet

    // The player (MpdService or its mock): songInfo(uri, cb), musicDir.
    property var player: null
    property string uri: ""
    property var first: null
    property string backLabel: ""

    property string fontFamily: "Inter"
    property real padding: 12
    property real insetFoot: 3
    property color listBoxColor: Theme.listBox
    property color textColor: Theme.textPrimary
    property color mutedColor: Theme.textMuted
    property color faintColor: Theme.textFaint
    property color accentColor: Theme.accent
    property color buttonPlateauColor: Theme.buttonPlateau
    property color buttonPlateauHoverColor: Theme.buttonPlateauHover
    property color buttonBevelColor: Theme.buttonBevel
    property color buttonShadowColor: Theme.buttonShadow
    property real scrollSpeed: 1.0

    signal backRequested()
    // The sheet's own buttons: "next", "queue", "album" (open the album's page), and its artist's line: "artist".
    signal actionRequested(string action, var song)

    // The stack's questions of a page: where it is scrolled to, what a page opened from this one grows out of.
    property alias scrollY: sheetFlick.contentY
    function tileOf(kind, a, b) {
        if (kind === "album")
            return actionRep.itemAt(2);
        return kind === "artist" ? sheet._artistLine : null;
    }
    function closeCover() {
        return false;
    }

    // ---- the data ----
    property var _info: null
    property string _asked: ""
    Component.onCompleted: sheet._ask()
    onUriChanged: sheet._ask()
    function _ask() {
        if (sheet.uri === "" || !sheet.player || sheet.uri === sheet._asked) return;
        sheet._asked = sheet.uri;
        sheet._info = null;
        sheet._size = 0;
        const want = sheet.uri;
        sheet.player.songInfo(want, info => {
            if (sheet.uri === want) sheet._info = info;
        });
        _stat.command = ["stat", "-c", "%s", sheet._abs(want)];
        _stat.running = true;
    }
    function _abs(file) { return (sheet.player && sheet.player.musicDir ? sheet.player.musicDir : "") + "/" + file; }
    property real _size: 0
    Process {
        id: _stat
        running: false
        stdout: StdioCollector { id: _statOut }
        onExited: code => { sheet._size = code === 0 ? (parseInt(String(_statOut.text).trim(), 10) || 0) : 0; }
    }
    AudioTags {
        id: tagReader
        active: sheet._info !== null
        path: sheet._info ? sheet._abs(sheet._info.song.file) : ""
    }
    AudioBitrate {
        id: avgReader
        active: sheet._info !== null
        path: sheet._info ? sheet._abs(sheet._info.song.file) : ""
        duration: sheet._info ? sheet._info.song.duration : 0
    }

    readonly property var _rows: {
        const out = [];
        const info = sheet._info;
        if (!info) return out;
        const s = info.song;
        const t = info.tags;
        const add = (k, v, link) => { const x = String(v === undefined || v === null ? "" : v).trim(); if (x !== "") out.push({ k: k, v: x, link: link === true }); };
        add("Title", s.title);
        add("Artist", s.artist, true);
        add("Album", s.album);
        if (s.albumArtist && s.albumArtist !== s.artist) add("Album artist", s.albumArtist);
        add("Track", (s.track > 0 ? String(s.track) : "") + (s.disc > 0 && (t.Disc || "") !== "" ? "  ·  Disc " + s.disc : ""));
        add("Date", Fmt.dateText(s.date));
        add("Genre", s.genre);
        add("Composer", t.Composer);
        add("Performer", t.Performer);
        add("Label", t.Label);
        add("Length", Fmt.clock(s.duration));
        const avg = avgReader.kbps;
        const fx = Fidelity.classify(s.format, avg, s.file);
        add("Format", fx.label);
        add("Bitrate", avg > 0 ? avg + " kbps average" : "");
        add("File size", Fmt.bytes(sheet._size));
        add("File", s.file);
        add("Changed", info.lastModified ? info.lastModified.replace("T", " ").replace(/Z$/, "") : "");
        const shown = { title: 1, artist: 1, album: 1, albumartist: 1, album_artist: 1, track: 1, disc: 1, date: 1, genre: 1, composer: 1,
                        performer: 1, label: 1, tracktotal: 1, disctotal: 1, totaltracks: 1, totaldiscs: 1, _format: 1, _duration: 1, _bitrate: 1,
                        _filename: 1, lyrics: 1, unsyncedlyrics: 1, encoder: 1, year: 1, originaldate: 1,
                        // the container's own words, about no song
                        major_brand: 1, minor_version: 1, compatible_brands: 1, creation_time: 1, handler_name: 1, vendor_id: 1 };
        const keys = Object.keys(tagReader.tags || {}).sort();
        let n = 0;
        for (let i = 0; i < keys.length && n < 14; i++) {
            const k = keys[i];
            if (shown[k] || k.indexOf("lyric") >= 0 || k.indexOf("musicbrainz") === 0 || k.indexOf("replaygain") === 0) continue;
            let v = String(tagReader.tags[k]);
            if (v.length > 120) v = v.substring(0, 117) + "…";
            out.push({ k: k.charAt(0).toUpperCase() + k.substring(1).replace(/_/g, " "), v: v, extra: true });
            n++;
        }
        return out;
    }

    // ---- look: it lies on the box ----
    Item {
        id: backRow
        width: sheet.width
        height: 34
        z: 2
        Chevron {
            id: chev
            size: 13
            rotation: 90
            thickness: 2
            color: backArea.containsMouse ? sheet.accentColor : sheet.faintColor
            x: Math.round(sheet.padding)
            y: Math.round((backRow.height - height) / 2)
        }
        Text {
            id: backText
            anchors.left: chev.right
            anchors.leftMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            text: sheet.backLabel
            color: backArea.containsMouse ? sheet.accentColor : sheet.mutedColor
            font.family: sheet.fontFamily
            font.pixelSize: 12
        }
        MouseArea {
            id: backArea
            width: backText.x + backText.implicitWidth + 12
            height: backRow.height
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: sheet.backRequested()
        }
    }

    Flickable {
        id: sheetFlick
        objectName: "playerSongSheetFlick"
        y: backRow.height
        width: sheet.width
        height: sheet.height - backRow.height - sheet.insetFoot
        contentWidth: width
        contentHeight: body.implicitHeight + sheet.padding
        clip: true
        interactive: false
        boundsBehavior: Flickable.StopAtBounds

        Column {
            id: body
            x: sheet.padding
            width: sheetFlick.width - sheet.padding * 2
            spacing: 2

            Text {
                width: parent.width
                text: sheet._info ? sheet._info.song.title : (sheet.first ? sheet.first.title : "")
                color: sheet.textColor
                font.family: sheet.fontFamily
                font.pixelSize: 15
                font.bold: true
                wrapMode: Text.Wrap
                maximumLineCount: 3
                elide: Text.ElideRight
            }
            Text {
                width: parent.width
                readonly property var _from: sheet._info ? sheet._info.song : (sheet.first || {})
                text: [_from.artist, _from.album].filter(x => !!x).join("  ·  ")
                color: sheet.mutedColor
                font.family: sheet.fontFamily
                font.pixelSize: 12
                wrapMode: Text.Wrap
                maximumLineCount: 2
                elide: Text.ElideRight
            }
            Item { width: 1; height: 8 }
            Row {
                spacing: 8
                height: 30
                visible: !!sheet._info
                Repeater {
                    id: actionRep
                    model: [{ id: "next", label: "Play next" }, { id: "queue", label: "Add to queue" }, { id: "album", label: "Show album" }]
                    delegate: RaisedButton {
                        required property var modelData
                        text: modelData.label
                        height: 30
                        fontFamily: sheet.fontFamily
                        fontPixelSize: 11
                        horizontalPadding: 12
                        minWidth: 56
                        surfaceColor: sheet.listBoxColor
                        plateauColor: sheet.buttonPlateauColor
                        plateauHoverColor: sheet.buttonPlateauHoverColor
                        bevelColor: sheet.buttonBevelColor
                        shadowColor: sheet.buttonShadowColor
                        textColor: sheet.textColor
                        faintTextColor: sheet.faintColor
                        accentColor: sheet.accentColor
                        enabled: !!sheet._info && (modelData.id !== "album" || !!sheet._info.song.album)
                        onClicked: sheet.actionRequested(modelData.id, sheet._info.song)
                    }
                }
            }
            Item { width: 1; height: 8 }

            Repeater {
                model: sheet._rows
                delegate: Item {
                    id: line
                    required property var modelData
                    width: body.width
                    height: Math.max(22, val.implicitHeight + 6)
                    Text {
                        id: key
                        width: 88
                        y: 4
                        text: line.modelData.k
                        color: sheet.faintColor
                        font.family: sheet.fontFamily
                        font.pixelSize: 11
                        elide: Text.ElideRight
                    }
                    property real _hov: linkArea.containsMouse ? 1 : 0
                    Behavior on _hov {
                        NumberAnimation {
                            duration: 120
                            easing.type: Easing.OutCubic
                        }
                    }
                    Component.onCompleted: if (line.modelData.link) sheet._artistLine = line
                    Text {
                        id: val
                        x: 96
                        y: 3
                        width: line.width - x
                        text: line.modelData.v
                        color: line.modelData.extra ? sheet.mutedColor : Mix.c(sheet.textColor, sheet.accentColor, line._hov)
                        font.family: sheet.fontFamily
                        font.pixelSize: 12
                        wrapMode: Text.WrapAnywhere
                        maximumLineCount: 4
                        elide: Text.ElideRight
                    }
                    // A link is an element that is already there (the artist's line goes to their page): nothing announces it but the pointer.
                    MouseArea {
                        id: linkArea
                        x: val.x
                        y: val.y
                        width: Math.min(val.implicitWidth, val.width)
                        height: val.implicitHeight
                        enabled: line.modelData.link === true
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: sheet.actionRequested("artist", sheet._info.song)
                    }
                }
            }
        }
    }

    property Item _artistLine: null
    KineticScroll {
        flick: sheetFlick
        speed: sheet.scrollSpeed * ScrollFeel.speed
        id: sheetScroll
    }
    WheelArea {
        x: sheetFlick.x
        y: sheetFlick.y
        width: sheetFlick.width
        height: sheetFlick.height
        turned: wheel => {
            sheetScroll.feed(wheel.pixelDelta.y, wheel.angleDelta.y, wheel.phase);
            wheel.accepted = true;
        }
    }
    // The fades, over the flickable alone (the back row is above it). The wheel is read above, by one reader.
    ScrollDressing {
        anchors.fill: sheetFlick
        flick: sheetFlick
        ground: sheet.listBoxColor
        fadeHeight: 28
        wheelEnabled: false
    }
}
