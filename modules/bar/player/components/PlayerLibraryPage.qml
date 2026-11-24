pragma ComponentBehavior: Bound

import QtQuick

import "../../../common/theme"
import "../../../common/scroll"
import "../../../common/components"
import "PlayerFormat.js" as Fmt

// =============================================================================
// PlayerLibraryPage.qml -- one album's page, or one artist's, inside the library's list box.
//
// Auxio's detail pages are the model (total album duration, album information from the metadata):
//
//   ALBUM   cover, title, the artist (a link to THEIR page), "2015 · Dream Pop", "10 songs · 43 min", what the
//           files are (FLAC 24-bit 44.1 kHz; a mixed album says so), the label when a tag has one, then
//           Play / Play next / Add to queue, then the songs in disc and track order (a "Disc 2" label
//           when there is more than one), each with its length. A click plays a song; a right click opens
//           its menu (Play next, Add to queue, Song details).
//   ARTIST  name, "3 albums · 31 songs · 2 h 5 min", the genre they have most of, Play / Play next / Add to
//           queue, then their albums (cover, title, "2015 · 10 songs · 43 min"): a click opens the album.
// A click on the cover shows it large, over the page, on one fraction; a click anywhere, or Escape, puts it back.
//
// The page fills the list's box and is its panel's to open and close (PlayerPageStack owns the stack and the
// morph, and says what a page grows out of through `tileOf`); this file is the content and the scroll. It reads
// `info`, which the host fills from the service (`albumInfo`, `albumsOfArtist`), and says what was asked in
// signals; it plays nothing. It draws no ground: it lies on the box. The back row is sticky; everything under
// it scrolls in ONE KineticScroll flickable, faded at both ends like the list and stopping `insetFoot` above the
// box's foot, so nothing scrolls over the carve.
//
// A list this size (a page is a screenful or three) is plain Items in a Column: no model, no pool.
// =============================================================================
Item {
    id: page

    DeviceScale { id: dev }

    // "album" | "artist"
    property string kind: "album"
    // album: { albumArtist, albumArtists, album, coverUrl, songs:[song], duration, discs, year, date, genre,
    //          label, formats:[string], mixed }
    // artist: { name, albums:[shelf record], songCount, duration, genre }
    property var info: null
    property bool loading: false
    property string backLabel: "Albums"
    // The song under the needle, so its row wears the mark the lists give it.
    property string currentFile: ""
    property bool playing: false

    property string fontFamily: "Inter"
    property real padding: 12
    property real containerRadius: 14
    property real rowHeight: 30
    property real insetFoot: 3
    property real coverSize: 112
    property real coverRadius: 8
    // The cover as a click shows it: decoded once at this size, the small one included (RoundedImage: a new sourceSize is a new decode).
    readonly property real largeCover: 420

    property color listBoxColor: Theme.listBox
    property color headerBoxColor: Theme.headerBox
    property color surfaceColor: Theme.surface
    property color bevelColor: Theme.bevel
    property color borderColor: Theme.border
    property color textColor: Theme.textPrimary
    property color mutedColor: Theme.textMuted
    property color faintColor: Theme.textFaint
    property color accentColor: Theme.accent
    property color accentHoverColor: Theme.accentHover
    property color accentBevelColor: Theme.accentBevel
    property color textOnAccentColor: Theme.textOnAccent
    property color buttonPlateauColor: Theme.buttonPlateau
    property color buttonPlateauHoverColor: Theme.buttonPlateauHover
    property color buttonBevelColor: Theme.buttonBevel
    property color buttonShadowColor: Theme.buttonShadow
    property real scrollSpeed: 1.0

    signal backRequested()
    // "play" | "next" | "queue"
    signal wholeRequested(string what)
    signal songClicked(string uri)
    signal songMenuRequested(string uri, real sceneX, real sceneY)
    signal albumClicked(string albumArtist, string album)
    signal albumMenuRequested(string albumArtist, string album, real sceneX, real sceneY)
    signal artistClicked(string name)

    readonly property bool _isAlbum: page.kind === "album"
    readonly property var _i: page.info || ({})
    readonly property int _backH: 34

    // Where the page is scrolled to: the host keeps it while the page waits under another.
    property alias scrollY: pageFlick.contentY
    // The cover, large (`closeCover`: true when it was out, for a host's Escape).
    property bool _coverOut: false
    property real _coverF: page._coverOut ? 1 : 0
    Behavior on _coverF {
        NumberAnimation { duration: 260; easing.type: Easing.OutCubic }
    }
    property var _coverFrom: ({ x: 0, y: 0, w: 0 })
    readonly property string _coverUrl: page._isAlbum ? (page._i.coverUrl || "") : ((page._i.albums || []).length > 0 ? (page._i.albums[0].coverUrl || "") : "")
    function _showCover() {
        const p = cover.mapToItem(page, 0, 0);
        page._coverFrom = { x: p.x, y: p.y, w: cover.width };
        page._coverOut = true;
    }
    function closeCover() {
        if (!page._coverOut)
            return false;
        page._coverOut = false;
        return true;
    }
    // What a page opened from this one grows out of: an album's or a song's row, or an artist's link (null: not on show).
    function tileOf(kind, a, b) {
        if (kind === "song") {
            for (let i = 0; i < rowRep.count; i++) {
                const r = rowRep.itemAt(i);
                if (!r || r.modelData.k !== "song" || r.modelData.file !== a)
                    continue;
                const top = r.mapToItem(pageFlick, 0, 0).y;
                return top + r.height > 0 && top < pageFlick.height ? r : null;
            }
            return null;
        }
        if (kind === "artist") {
            for (let i = 0; i < artistLinks.count; i++) {
                const t = artistLinks.itemAt(i);
                if (t && t.modelData === a)
                    return t;
            }
            return null;
        }
        for (let i = 0; i < rowRep.count; i++) {
            const r = rowRep.itemAt(i);
            if (!r || r.modelData.k !== "album" || r.modelData.album !== b || r.modelData.albumArtist !== a)
                continue;
            const top = r.mapToItem(pageFlick, 0, 0).y;
            return top + r.height > 0 && top < pageFlick.height ? r : null;
        }
        return null;
    }

    // ---- the sticky back row ----
    Item {
        id: backRow
        x: 0
        y: 0
        width: page.width
        height: page._backH
        z: 3

        Chevron {
            id: backChev
            size: 13
            rotation: 90
            thickness: 2
            color: backArea.containsMouse ? page.accentColor : page.faintColor
            x: Math.round(page.padding)
            y: Math.round((backRow.height - height) / 2)
        }
        Text {
            id: backText
            anchors.left: backChev.right
            anchors.leftMargin: 6
            anchors.verticalCenter: parent.verticalCenter
            text: page.backLabel
            color: backArea.containsMouse ? page.accentColor : page.mutedColor
            font.family: page.fontFamily
            font.pixelSize: 12
        }
        MouseArea {
            id: backArea
            x: 0
            y: 0
            width: backText.x + backText.implicitWidth + 12
            height: backRow.height
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: page.backRequested()
        }
    }

    Flickable {
        id: pageFlick
        objectName: "playerLibraryPageFlick"
        x: 0
        y: page._backH
        width: page.width
        height: page.height - page._backH - page.insetFoot
        contentWidth: width
        contentHeight: col.implicitHeight + page.padding
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: false

        Column {
            id: col
            x: page.padding
            width: pageFlick.width - page.padding * 2
            spacing: 0

            // ---------------------------------------------------------- header
            Item {
                id: head
                width: col.width
                height: Math.max(cover.height, textCol.implicitHeight)

                Rectangle {
                    id: coverBack
                    width: cover.width
                    height: cover.height
                    radius: page.coverRadius
                    color: page.headerBoxColor
                }
                // An artist has no picture of their own: their first album's, or a mark.
                RoundedImage {
                    id: cover
                    width: page.coverSize
                    height: page.coverSize
                    radius: page.coverRadius
                    visible: source.toString() !== ""
                    source: page._coverUrl
                    sourceSize: dev.size(page.largeCover, page.largeCover)
                    asynchronous: true
                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: page._showCover()
                    }
                }
                Text {
                    anchors.centerIn: coverBack
                    visible: !cover.visible
                    text: page._isAlbum ? "♪" : (String(page._i.name || "?").charAt(0).toUpperCase())
                    color: page.faintColor
                    font.family: page.fontFamily
                    font.pixelSize: 30
                    font.bold: true
                }

                Column {
                    id: textCol
                    x: cover.width + 12
                    width: head.width - x
                    spacing: 2

                    Text {
                        width: parent.width
                        text: page._isAlbum ? String(page._i.album || "") : String(page._i.name || "")
                        color: page.textColor
                        font.family: page.fontFamily
                        font.pixelSize: 15
                        font.bold: true
                        wrapMode: Text.Wrap
                        maximumLineCount: 3
                        elide: Text.ElideRight
                    }
                    // the artist(s): each a link to their page
                    Flow {
                        width: parent.width
                        visible: page._isAlbum
                        spacing: 0
                        Repeater {
                            id: artistLinks
                            model: page._isAlbum ? (page._i.albumArtists || [page._i.albumArtist || ""]) : []
                            delegate: Text {
                                required property string modelData
                                required property int index
                                text: (index > 0 ? ", " : "") + modelData
                                color: artistArea.containsMouse ? page.accentColor : page.mutedColor
                                font.family: page.fontFamily
                                font.pixelSize: 12
                                MouseArea {
                                    id: artistArea
                                    anchors.fill: parent
                                    hoverEnabled: true
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: page.artistClicked(parent.modelData)
                                }
                            }
                        }
                    }
                    Text {
                        width: parent.width
                        visible: text.length > 0
                        text: page._metaLine
                        color: page.mutedColor
                        font.family: page.fontFamily
                        font.pixelSize: 11
                        wrapMode: Text.Wrap
                    }
                    Text {
                        width: parent.width
                        visible: text.length > 0
                        text: page._countLine
                        color: page.mutedColor
                        font.family: page.fontFamily
                        font.pixelSize: 11
                    }
                    Text {
                        width: parent.width
                        visible: text.length > 0
                        text: page._fileLine
                        color: page.faintColor
                        font.family: page.fontFamily
                        font.pixelSize: 11
                        wrapMode: Text.Wrap
                    }
                }
            }

            Item { width: 1; height: 10 }

            // --------------------------------------------------------- actions
            Row {
                id: actions
                spacing: 8
                height: 30
                Repeater {
                    model: [{ id: "play", label: "Play", accent: true }, { id: "next", label: "Play next" },
                            { id: "queue", label: "Add to queue" }]
                    delegate: RaisedButton {
                        required property var modelData
                        text: modelData.label
                        accent: modelData.accent === true
                        height: 30
                        fontFamily: page.fontFamily
                        fontPixelSize: 11
                        horizontalPadding: 12
                        minWidth: 56
                        surfaceColor: page.listBoxColor
                        plateauColor: page.buttonPlateauColor
                        plateauHoverColor: page.buttonPlateauHoverColor
                        bevelColor: page.buttonBevelColor
                        shadowColor: page.buttonShadowColor
                        textColor: page.textColor
                        faintTextColor: page.faintColor
                        accentColor: page.accentColor
                        accentHoverColor: page.accentHoverColor
                        accentBevelColor: page.accentBevelColor
                        accentTextColor: page.textOnAccentColor
                        // Lit with the page: an album is played by its name, and its songs need not have landed.
                        enabled: page.loading || page._hasRows
                        onClicked: page.wholeRequested(modelData.id)
                    }
                }
            }

            Item { width: 1; height: 12 }

            // ----------------------------------------------------------- rows
            Column {
                id: rows
                width: col.width
                spacing: 0

                Repeater {
                    id: rowRep
                    model: page._rowModel
                    delegate: Item {
                        id: row
                        required property var modelData
                        required property int index
                        readonly property bool _isLabel: modelData.k === "label"
                        readonly property bool _isSong: modelData.k === "song"
                        readonly property bool _current: row._isSong && page.currentFile !== "" && modelData.file === page.currentFile
                        width: rows.width
                        height: row._isLabel ? 26 : (row._isSong ? page.rowHeight : 48)

                        property real _hov: rowArea.containsMouse && !row._isLabel ? 1 : 0
                        Behavior on _hov { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

                        // song: number | title ... length
                        Text {
                            visible: row._isSong
                            x: 0
                            width: 26
                            anchors.verticalCenter: parent.verticalCenter
                            horizontalAlignment: Text.AlignRight
                            text: row._isSong ? (row.modelData.track > 0 ? String(row.modelData.track) : "") : ""
                            color: row._current ? page.accentColor : page.faintColor
                            font.family: page.fontFamily
                            font.pixelSize: 11
                        }
                        Text {
                            visible: row._isSong
                            x: 38
                            width: durText.x - 8 - x
                            anchors.verticalCenter: parent.verticalCenter
                            text: row._isSong ? row.modelData.title : ""
                            color: row._current ? page.accentColor : Qt.tint(page.textColor, Qt.rgba(page.accentColor.r, page.accentColor.g, page.accentColor.b, 0.85 * row._hov))
                            font.family: page.fontFamily
                            font.pixelSize: 13
                            font.bold: row._current && page.playing
                            elide: Text.ElideRight
                        }
                        Text {
                            id: durText
                            visible: row._isSong
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            text: row._isSong ? Fmt.clock(row.modelData.duration) : ""
                            color: page.mutedColor
                            font.family: page.fontFamily
                            font.pixelSize: 11
                        }

                        // label (disc / section)
                        Text {
                            visible: row._isLabel
                            anchors.left: parent.left
                            anchors.leftMargin: 4
                            anchors.bottom: parent.bottom
                            anchors.bottomMargin: 4
                            text: row._isLabel ? row.modelData.text : ""
                            color: page.faintColor
                            font.family: page.fontFamily
                            font.pixelSize: 11
                            font.bold: true
                            font.capitalization: Font.AllUppercase
                            font.letterSpacing: 0.6
                        }

                        // album (artist page): cover | title, sub
                        RoundedImage {
                            id: rowCover
                            visible: !row._isSong && !row._isLabel
                            x: 0
                            anchors.verticalCenter: parent.verticalCenter
                            width: 40
                            height: 40
                            radius: 6
                            source: !row._isSong && !row._isLabel ? (row.modelData.coverUrl || "") : ""
                            sourceSize: dev.size(96, 96)
                            asynchronous: true
                        }
                        Column {
                            visible: !row._isSong && !row._isLabel
                            x: 52
                            width: row.width - x
                            anchors.verticalCenter: parent.verticalCenter
                            spacing: 1
                            Text {
                                width: parent.width
                                text: !row._isSong && !row._isLabel ? row.modelData.title : ""
                                color: Qt.tint(page.textColor, Qt.rgba(page.accentColor.r, page.accentColor.g, page.accentColor.b, 0.85 * row._hov))
                                font.family: page.fontFamily
                                font.pixelSize: 13
                                elide: Text.ElideRight
                            }
                            Text {
                                width: parent.width
                                text: !row._isSong && !row._isLabel ? row.modelData.sub : ""
                                color: page.mutedColor
                                font.family: page.fontFamily
                                font.pixelSize: 11
                                elide: Text.ElideRight
                            }
                        }

                        MouseArea {
                            id: rowArea
                            anchors.fill: parent
                            enabled: !row._isLabel
                            hoverEnabled: true
                            acceptedButtons: Qt.LeftButton | Qt.RightButton
                            cursorShape: Qt.PointingHandCursor
                            onClicked: mouse => {
                                if (row._isSong) {
                                    if (mouse.button === Qt.RightButton) {
                                        const p = row.mapToItem(null, mouse.x, mouse.y);
                                        page.songMenuRequested(row.modelData.file, p.x, p.y);
                                    } else {
                                        page.songClicked(row.modelData.file);
                                    }
                                } else if (mouse.button === Qt.RightButton) {
                                    const q = row.mapToItem(null, mouse.x, mouse.y);
                                    page.albumMenuRequested(row.modelData.albumArtist, row.modelData.album, q.x, q.y);
                                } else {
                                    page.albumClicked(row.modelData.albumArtist, row.modelData.album);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    KineticScroll {
        id: scrollEngine
        flick: pageFlick
        speed: page.scrollSpeed * ScrollFeel.speed
    }
    WheelArea {
        x: pageFlick.x
        y: pageFlick.y
        width: pageFlick.width
        height: pageFlick.height
        turned: wheel => {
            scrollEngine.feed(wheel.pixelDelta.y, wheel.angleDelta.y, wheel.phase);
            wheel.accepted = true;
        }
    }
    // The fades, over the flickable alone (the back row is above it). The wheel is read above, by one reader.
    ScrollDressing {
        anchors.fill: pageFlick
        flick: pageFlick
        ground: page.listBoxColor
        fadeHeight: 28
        wheelEnabled: false
    }

    // ---- the cover, large ----
    Item {
        id: coverLarge
        anchors.fill: parent
        z: 5
        visible: page._coverF > 0.001
        Rectangle {
            anchors.fill: parent
            anchors.margins: page.insetFoot
            radius: Math.max(0, page.containerRadius - page.insetFoot)
            color: page.listBoxColor
            opacity: page._coverF
        }
        Item {
            id: largeRest
            readonly property real side: Math.min(page.width, page.height) - page.padding * 2
            x: (page.width - largeRest.side) / 2
            y: (page.height - largeRest.side) / 2
            width: largeRest.side
            height: largeRest.side
        }
        Loader {
            // Built when it is first wanted: the same url at the same decode size, so the small cover's texture is there at once.
            active: coverLarge.visible
            readonly property real f: page._coverF
            x: page._coverFrom.x + (largeRest.x - page._coverFrom.x) * f
            y: page._coverFrom.y + (largeRest.y - page._coverFrom.y) * f
            width: page._coverFrom.w + (largeRest.side - page._coverFrom.w) * f
            height: width
            sourceComponent: RoundedImage {
                radius: page.coverRadius
                source: page._coverUrl
                sourceSize: dev.size(page.largeCover, page.largeCover)
                asynchronous: true
            }
        }
        MouseArea {
            anchors.fill: parent
            enabled: page._coverOut
            cursorShape: Qt.PointingHandCursor
            onClicked: page._coverOut = false
        }
    }

    // ---- what the header says ----
    readonly property string _metaLine: {
        const i = page._i;
        const parts = [];
        if (page._isAlbum) {
            if (i.date) parts.push(Fmt.dateText(i.date));
            else if (i.year > 0) parts.push(String(i.year));
        }
        if (i.genre) parts.push(i.genre);
        return parts.join(" · ");
    }
    readonly property string _countLine: {
        const i = page._i;
        if (page.loading) return "";
        const parts = [];
        if (page._isAlbum) {
            const n = (i.songs || []).length;
            if (n > 0) parts.push(Fmt.plural(n, "song"));
            if (i.discs > 1) parts.push(Fmt.plural(i.discs, "disc"));
        } else {
            parts.push(Fmt.plural((i.albums || []).length, "album"));
            if (i.songCount > 0) parts.push(Fmt.plural(i.songCount, "song"));
        }
        const d = Fmt.long(i.duration);
        if (d) parts.push(d);
        return parts.join(" · ");
    }
    readonly property string _fileLine: {
        const i = page._i;
        if (!page._isAlbum || page.loading) return "";
        const parts = [];
        if (i.formats && i.formats.length > 0)
            parts.push(i.mixed ? "Mixed: " + i.formats.join(", ") : i.formats[0]);
        if (i.label) parts.push(i.label);
        return parts.join(" · ");
    }
    readonly property bool _hasRows: page._rowModel.length > 0

    // ---- the rows, as facts (no colours) ----
    readonly property var _rowModel: {
        const i = page._i;
        const out = [];
        if (page._isAlbum) {
            const songs = i.songs || [];
            const multi = (i.discs || 1) > 1;
            let disc = -1;
            for (let k = 0; k < songs.length; k++) {
                const s = songs[k];
                const d = s.disc || 1;
                if (multi && d !== disc) {
                    disc = d;
                    out.push({ k: "label", text: "Disc " + d });
                }
                out.push({ k: "song", file: s.file, title: s.title || s.file, track: s.track || 0, duration: s.duration || 0 });
            }
        } else {
            const albums = i.albums || [];
            for (let k = 0; k < albums.length; k++) {
                const a = albums[k];
                const sub = [];
                if (a.year > 0) sub.push(String(a.year));
                if (a.songCount > 0) sub.push(Fmt.plural(a.songCount, "song"));
                const dl = Fmt.long(a.duration);
                if (dl) sub.push(dl);
                out.push({ k: "album", albumArtist: a.albumArtist, album: a.album, title: a.album, sub: sub.join(" · "), coverUrl: a.coverUrl || "" });
            }
        }
        return out;
    }
}
