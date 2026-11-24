pragma ComponentBehavior: Bound

import QtQuick
import Quickshell

import "../../common/theme"
import "../../common/components"
import "../../common/icons"
import "NotifyGlyphs.js" as G

// =============================================================================
// EntryIcon.qml -- the icon column of a notification card.
//
// Every icon is the icon theme's own, in its own colours, drawn as it is
// (unprocessed everywhere -- the column and the avatar's badge alike). In order of preference:
//
//   avatar   the sender's image when it is small and square (NotifyPolicy's
//            imageKind "avatar": a Signal contact, a web notification's
//            picture), cut to a circle, with the app's own icon as a badge on
//            its lower-right corner so the app is still named;
//   icon     an ICON THE SENDER PASSED AS ITS IMAGE (image.kind "icon",
//            image.icon a theme name or a path: libnotify's `notify-send -i`
//            and every app built on notify_notification_new(icon) put it in the
//            image-path hint with app_icon empty -- the user's volume,
//            brightness and mic scripts do), drawn as it is: the column's own
//            icon, uncut, at the size it is seen at, no badge (taken for an
//            avatar it would be cut to a circle and decoded at 128);
//            else the notification's appIcon (an icon name, a path or a file
//            URL), else its app's desktop entry's icon (DesktopEntries.byId on
//            the desktop-entry hint, else heuristicLookup on the app's name). A
//            name the icon theme does not have (Quickshell.hasThemeIcon) and a
//            path with no file behind it (the checked Quickshell.iconPath)
//            give way to the next candidate, before anything loads. Quickshell
//            scans the desktop entries LAZILY, on a thread, from the first
//            lookup: that lookup answers null and `applicationsChanged` fires
//            once the scan lands (+2 ms), so the entry is looked up
//            again then -- a method call in a binding captures nothing;
//   glyph    a shell source's Material glyph (or a D-Bus appIcon that is
//            itself a glyph), drawn plainly in the muted colour at icon size;
//   nothing  `shown` false: the card drops the column and its text starts at
//            the card's left padding.
//
// No well, no relief, no letter. Engraving the app's icon (the launcher's
// AppIconRelief over its baked cells) loses the identity: a themed icon's
// PLATE is its whole silhouette and its SYMBOL whatever sits inside in another
// colour, so kitty comes out as a grey cat-and-terminal silhouette with two eye
// holes and a prompt dug into it, KDE Connect as a grey phone with a ragged
// gear -- shades and shapes, the identity (the colour) gone.
//
// A live image that only exists while its notification does (image-data is
// served as image://qsimage/<id>/... by Quickshell) is grabbed to the
// record's image file the first time it is on screen, so it survives a
// restart; `service.imageGrabbed(uid, file)` records where.
// =============================================================================
Item {
    id: root

    property var d: null
    property var service: null
    property int size: 40
    property int badgeSize: 18
    // The glyph's pixel size as a share of `size`: a Material glyph's ink is
    // 20/24 of its em, so at 1.0 it fills the column the way a theme icon does.
    property real glyphScale: 1.0
    // Device pixels per item pixel (a mockup's zoom x the screen's scale): the
    // theme renders the icon at the size it is SEEN at, never scaled up.
    property real renderScale: 1

    // Whether there is anything to show; false = no column at all.
    readonly property bool shown: root.avatarShown || root._iconSource !== "" || root._glyph !== ""
    // The avatar is up (or on its way: the service measured it at arrival, so
    // a load that is still running is one that will land).
    readonly property bool avatarShown: root._avatar && avatarImg.status !== Image.Error
    // What the column draws: "avatar" | "icon" | "glyph" | "" (probes).
    readonly property string kind: root.avatarShown ? "avatar"
        : root._iconSource !== "" ? "icon" : root._glyph !== "" ? "glyph" : ""
    // The app icon being drawn (as the column or the badge), "" for none.
    readonly property string iconSource: root._iconSource

    implicitWidth: root.shown ? root.size : 0
    implicitHeight: root.shown ? root.size : 0

    readonly property var _img: root.d && root.d.image ? root.d.image : null
    readonly property bool _avatar: !!root._img && root._img.kind === "avatar"
    readonly property string _imgSource: !root._img ? ""
        : (root._img.file ? "file://" + root._img.file : (root.d.stale ? "" : (root._img.url || "")))
    readonly property string _appIcon: root.d ? String(root.d.appIcon || "") : ""
    // The sender's icon passed as its image (kind "icon": a name or a path).
    readonly property string _imgIcon: root._img && root._img.kind === "icon" ? String(root._img.icon || "") : ""
    readonly property string _glyph: {
        if (!root.d)
            return "";
        if (G.isGlyph(root._appIcon))
            return root._appIcon;
        if (root.d.origin === "shell")
            return G.sources[root.d.sourceId] || G.bell;
        return "";
    }

    // ---- the app icon's candidates, best first -----------------------------
    function _sourceOf(s) {
        if (s === "" || G.isGlyph(s))
            return "";
        // A path (or a file URL) goes through Quickshell's CHECKED iconPath:
        // QIcon loads an absolute path as a file and answers "" when there is
        // none -- silently, where an Image of a missing file logs "Cannot
        // open" once per card (a sender's stale path is common).
        const p = s.indexOf("file://") === 0 ? decodeURIComponent(s.substring(7)) : s;
        if (p.charAt(0) === "/")
            return AppIcons.checkedPath(p);
        if (/^[a-z]+:/.test(s))
            return s;
        // hasThemeIcon, not iconPath(s, true): with the icon theme set to
        // Papirus (QS_ICON_THEME, the launcher's theme) the checked iconPath
        // hands back a URL for a name the theme does not have, under gtk3 and
        // xdgdesktopportal alike, while hasThemeIcon answers false (with no
        // theme or hicolor both answer ""/false).
        return Quickshell.hasThemeIcon(s) ? Quickshell.iconPath(s) : "";
    }
    // The app's desktop entry's icon name (a D-Bus sender only).
    property int _scans: 0
    Connections {
        target: DesktopEntries
        function onApplicationsChanged() {
            root._scans++;
        }
    }
    readonly property string _entryIcon: {
        if (root._scans < 0 || !root.d || root.d.origin === "shell")
            return "";
        const byId = root.d.desktopEntry ? DesktopEntries.byId(String(root.d.desktopEntry)) : null;
        const e = byId ?? (root.d.appName ? DesktopEntries.heuristicLookup(String(root.d.appName)) : null);
        return e ? String(e.icon || "") : "";
    }
    readonly property var _candidates: {
        const out = [];
        const i = root._sourceOf(root._imgIcon);
        if (i !== "")
            out.push(i);
        const a = root._sourceOf(root._appIcon);
        if (a !== "" && out.indexOf(a) < 0)
            out.push(a);
        const b = root._sourceOf(root._entryIcon);
        if (b !== "" && out.indexOf(b) < 0)
            out.push(b);
        return out;
    }
    // The first candidate that loads. A name the theme has and a file that
    // exists are checked before they get here; a load that still fails (a
    // file that does not decode, another scheme) steps to the next one (a
    // synchronous load: in the same turn).
    property int _try: 0
    on_CandidatesChanged: root._try = 0
    readonly property string _iconSource: root._try < root._candidates.length ? root._candidates[root._try] : ""

    readonly property int _px: Math.max(1, Math.ceil(root.size * root.renderScale))
    readonly property int _badgePx: Math.max(1, Math.ceil(root.badgeSize * root.renderScale))

    // ---- the column ------------------------------------------------------------
    Image {
        id: iconImg
        objectName: "entryIconImage"
        width: root.size
        height: root.size
        visible: !root.avatarShown && root._iconSource !== ""
        source: root._iconSource
        sourceSize: Qt.size(root._px, root._px)
        fillMode: Image.PreserveAspectFit
        smooth: true
        asynchronous: false
        onStatusChanged: {
            if (iconImg.status === Image.Error && iconImg.source.toString() === root._iconSource)
                root._try++;
        }
    }

    Text {
        objectName: "entryIconGlyph"
        width: root.size
        height: root.size
        visible: !root.avatarShown && root._iconSource === "" && root._glyph !== ""
        text: root._glyph
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        font.family: G.family
        font.pixelSize: Math.round(root.size * root.glyphScale)
        color: Theme.textMuted
    }

    RoundedImage {
        id: avatarImg
        objectName: "entryAvatar"
        width: root.size
        height: root.size
        visible: root._avatar
        source: root._avatar ? root._imgSource : ""
        // 128 is the cap (a constant under layout); more when the glass shows the avatar larger than that
        sourceSize: Qt.size(Math.max(128, root._px), Math.max(128, root._px))
        radius: root.size / 2
        asynchronous: true
        onStatusChanged: root._maybeGrab()
    }

    // The badge: the same icon (or glyph), small, on the avatar's corner.
    Image {
        objectName: "entryBadgeImage"
        x: root.size - root.badgeSize + 3
        y: root.size - root.badgeSize + 3
        width: root.badgeSize
        height: root.badgeSize
        visible: root.avatarShown && root._iconSource !== ""
        source: root.avatarShown ? root._iconSource : ""
        sourceSize: Qt.size(root._badgePx, root._badgePx)
        fillMode: Image.PreserveAspectFit
        smooth: true
        asynchronous: false
    }
    Text {
        objectName: "entryBadgeGlyph"
        x: root.size - root.badgeSize + 3
        y: root.size - root.badgeSize + 3
        width: root.badgeSize
        height: root.badgeSize
        visible: root.avatarShown && root._iconSource === "" && root._glyph !== ""
        text: root._glyph
        horizontalAlignment: Text.AlignHCenter
        verticalAlignment: Text.AlignVCenter
        font.family: G.family
        font.pixelSize: Math.round(root.badgeSize * root.glyphScale)
        color: Theme.textMuted
    }

    // ---- keep a live image past its notification -------------------------------
    function _maybeGrab() {
        if (!root._avatar || avatarImg.status !== Image.Ready || !root.service || !root.d)
            return;
        if (root._img.file || String(root._img.url || "").indexOf("image://qsimage/") !== 0)
            return;
        const svc = root.service;
        const dir = svc.imagesDir || (String(svc.historyPath || "").replace(/[^/]*$/, "") + "images");
        const uid = root.d.uid;
        const file = dir + "/" + uid + ".png";
        // The Image itself, not the RoundedImage around it: a grab of the rounded item comes out FULLY TRANSPARENT
        // (a 128 x 128 PNG with every channel 0 in the history), the shader that cuts
        // the corners not being drawn into a grab of its own subtree. The corners are cut again when it is shown.
        avatarImg.image.grabToImage(r => {
            if (r.saveToFile(file))
                svc.imageGrabbed(uid, file);
        }, Qt.size(128, 128));
    }
}
