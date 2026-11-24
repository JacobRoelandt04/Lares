.pragma library

// =============================================================================
// SenderMatch.js -- which window sent this notification, pure.
//
//   norm(s)                    -> lowercased, trimmed, ".desktop" stripped
//   matches(rec, win)          -> bool
//   focusTarget(rec, windows)  -> window | null
//
// A notification names its sender three ways and a Hyprland client names
// itself two: the record has `desktopEntry` (the hint), `appName` and, while
// the notification is live, `senderPid` (libnotify's `sender-pid` hint -- a
// runtime field the service passes along, never persisted: a pid read back
// after a restart belongs to somebody else); a window has `cls` and
// `initialClass` (plus `title` and `pid`).
//
// THE PID IS THE ONLY EXACT ANSWER, so it wins: a notification whose sender
// pid is a client's pid came from that client, whatever the names say. The
// names come next, compared after `norm` ("Firefox", "firefox.desktop" and
// "firefox" are one app). Last, reverse-DNS: a Flatpak's desktop entry is
// "com.discordapp.Discord" while its window class is "discord", and KDE apps
// do the opposite ("konsole" against "org.kde.konsole"), so the last dot
// segment of either side may stand in for the whole name -- the weakest
// match, only used when nothing better is there.
//
// A shell record (`origin: "shell"`) never matches: the shell's own sources
// have no window, and "clock" against a client that calls itself "clock"
// would focus a stranger.
//
// Several windows can match equally (kitty runs every window in one process,
// so they share its pid). `focusTarget` then takes the most recently focused
// one when the windows carry Hyprland's `focusHistoryId` (0 = focused now),
// else the first in the list.
//
// Pure: no Qt, loadable under node.
// =============================================================================

function norm(s) {
    if (s === undefined || s === null)
        return "";
    var t = String(s).trim().toLowerCase();
    if (t.length >= 8 && t.substring(t.length - 8) === ".desktop")
        t = t.substring(0, t.length - 8).trim();
    return t;
}

// The last segment of a reverse-DNS name ("com.discordapp.discord" ->
// "discord"), "" for a name without a dot.
function _tail(s) {
    var i = s.lastIndexOf(".");
    return i >= 0 ? s.substring(i + 1) : "";
}

function _pid(v) {
    var n = Number(v);
    return isFinite(n) && n > 0 ? n : 0;
}

// 3 = the sender's pid, 2 = a name equal to a class, 1 = reverse-DNS tail,
// 0 = no match.
function _score(rec, win) {
    if (!rec || !win || rec.origin === "shell")
        return 0;
    var pid = _pid(rec.senderPid);
    if (pid > 0 && _pid(win.pid) === pid)
        return 3;
    var names = [norm(rec.desktopEntry), norm(rec.appName)].filter(function (s) { return s !== ""; });
    var cls = [norm(win.cls), norm(win.initialClass)].filter(function (s) { return s !== ""; });
    var i, j;
    for (i = 0; i < names.length; i++)
        for (j = 0; j < cls.length; j++)
            if (names[i] === cls[j])
                return 2;
    for (i = 0; i < names.length; i++)
        for (j = 0; j < cls.length; j++) {
            var a = _tail(names[i]), b = _tail(cls[j]);
            if ((a !== "" && a === cls[j]) || (b !== "" && b === names[i]))
                return 1;
        }
    return 0;
}

function matches(rec, win) {
    return _score(rec, win) > 0;
}

function focusTarget(rec, windows) {
    var best = null, bestScore = 0, bestAge = Infinity;
    var list = Array.isArray(windows) ? windows : [];
    for (var i = 0; i < list.length; i++) {
        var w = list[i];
        var s = _score(rec, w);
        if (s === 0)
            continue;
        var age = (w && typeof w.focusHistoryId === "number" && w.focusHistoryId >= 0)
            ? w.focusHistoryId : Infinity;
        if (s > bestScore || (s === bestScore && age < bestAge)) {
            best = w;
            bestScore = s;
            bestAge = age;
        }
    }
    return best;
}
