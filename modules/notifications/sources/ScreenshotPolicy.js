.pragma library
.import "SourceFormat.js" as F

// =============================================================================
// ScreenshotPolicy.js -- a screenshot taken, as pure decisions (SOURCES.md, "Later sources").
//
// The shell's capture script (tools/osd/shot.sh: grim, wl-copy, then `quickshell ipc call osd capture shot <path>
// copied|plain`) tells the OSD, and the OSD's capture card shows the shot -- its thumbnail, "copied". The card is
// transient and has no buttons; the notification's job is what it cannot do: the picture on a card that WAITS in
// the manager, with Open, Edit in swappy and Copy path. The two must not say it twice on screen.
//
//   shot(req)             -> { path, name, copied } for a capture request that is a screenshot, else null
//   route(osdConfig)      -> the OSD's route for its capture kind: "osd" | "notification" | "off"
//   mode(setting, route)  -> "toast" | "file" | "none": what this source does with the shot
//   key(path) / text(shot)
//
// THE DECISION (`sources.screenshot.toast`, "auto" by default):
//   auto     the OSD route says: "osd" -- its card is on screen, so this one is FILED silently (in the manager, seen,
//            with its buttons; no second popup over the same picture); "notification" -- the OSD already posts its own
//            plain notification, so this one stays out; "off" -- nothing else shows it, so this one toasts.
//   always   it toasts, whatever the OSD does (a second surface: the user's call).
//   never    it is filed silently, whatever the OSD does.
// No Qt, no clock.
// =============================================================================

function shot(req) {
    if (!req || req.kind !== "capture" || !req.capture || req.capture.what !== "shot")
        return null;
    var path = String(req.capture.path || "");
    if (path === "")
        return null;
    var name = path.substring(path.lastIndexOf("/") + 1);
    return { path: path, name: name, copied: req.capture.copied === true };
}

function route(osdConfig) {
    var k = osdConfig && osdConfig.kinds && osdConfig.kinds.capture ? osdConfig.kinds.capture.route : "osd";
    return k === "notification" || k === "off" ? k : "osd";
}

function mode(setting, osdRoute) {
    if (setting === "always")
        return "toast";
    if (setting === "never")
        return "file";
    if (osdRoute === "osd")
        return "file";
    return osdRoute === "notification" ? "none" : "toast";
}

function key(path) {
    return "shot:" + F.keyPart(path);
}

function text(s) {
    return { title: "Screenshot saved", body: s.name + (s.copied ? "\nCopied to the clipboard" : "") };
}
