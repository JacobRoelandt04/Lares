.pragma library
.import "SourceFormat.js" as F

// =============================================================================
// UsbDrives.js -- the removable drives, as pure decisions (SOURCES.md, "Later sources").
//
// A USB drive plugged: udisks -> Open / Eject, then 'safe to remove'. UDisks says WHEN (its monitor
// names an object that came or went); `lsblk -J -b` says WHAT, in one stable shape, and this reads it:
//
//   parse(text)               -> [drive] | null (unreadable: the last picture stands)
//   byId(drives)              -> { id: drive }
//   diff(prev, next)          -> { plugged: [drive], unplugged: [drive], changed: [drive] }
//   signature(drive)          what shows on a card: the partitions' paths, labels, filesystems and MOUNT POINTS (a mount made
//                             by anything -- the card, yazi's `M`, udiskie -- moves the card)
//   name(drive) / text(drive) / mounted(drive) / ejected(drive) / lost(drive)   the words
//   failed(drive, what, err) / unmounted(drive, err) / reason(err)   what a refusal of udisks says
//   mountedAt(drive)          the first mount point of the drive, "" none; mountsOf(drive) all of them
//   unmountedParts(drive) / mountedParts(drive)   the filesystems to mount / to unmount
//   openArgv(template, path)  the opener's argv, `{path}` filled in
//   mountPathOf(stdout)       "Mounted /dev/sdb1 at /run/media/user/TEST." -> "/run/media/user/TEST"
//
// A DRIVE is a whole disk that is removable, hot-pluggable or on USB (the internal NVMe is none of them), with the
// filesystems found on it or under it (a LUKS container's opened volume counts, the container does not). Its id is the
// disk's path: the card, the Eject and the mount all follow it. No Qt, no clock.
// =============================================================================

var _SKIP_FS = { swap: true, crypto_LUKS: true, LVM2_member: true, linux_raid_member: true, "": true };

function _flag(v) {
    return v === true || v === 1 || v === "1" || v === "true";
}

function _trim(s) {
    return s === undefined || s === null ? "" : String(s).trim();
}

function _mounts(n) {
    var list = Array.isArray(n.mountpoints) ? n.mountpoints : (n.mountpoint !== undefined ? [n.mountpoint] : []);
    return list.filter(function (m) { return m !== null && m !== undefined && m !== "" && String(m).charAt(0) === "/"; }).map(String);
}

function _collect(node, out) {
    if (node.fstype && !_SKIP_FS[node.fstype])
        out.push({ path: String(node.path), label: _trim(node.label), fstype: String(node.fstype), size: Number(node.size) || 0, mountpoints: _mounts(node) });
    var kids = Array.isArray(node.children) ? node.children : [];
    for (var i = 0; i < kids.length; i++)
        _collect(kids[i], out);
}

function parse(text) {
    var o = null;
    try {
        o = JSON.parse(String(text));
    } catch (e) {
        return null;
    }
    if (!o || !Array.isArray(o.blockdevices))
        return null;
    var out = [];
    for (var i = 0; i < o.blockdevices.length; i++) {
        var d = o.blockdevices[i];
        if (!d || d.type !== "disk" || !(_flag(d.rm) || _flag(d.hotplug) || d.tran === "usb"))
            continue;
        var parts = [];
        _collect(d, parts);
        out.push({ id: String(d.path), size: Number(d.size) || 0, model: _trim(d.model), vendor: _trim(d.vendor), tran: _trim(d.tran), parts: parts });
    }
    return out;
}

function byId(drives) {
    var m = {};
    for (var i = 0; i < drives.length; i++)
        m[drives[i].id] = drives[i];
    return m;
}

function signature(d) {
    return JSON.stringify(d.parts.map(function (p) { return [p.path, p.label, p.fstype, p.mountpoints]; }));
}

function diff(prev, next) {
    var out = { plugged: [], unplugged: [], changed: [] };
    var a = prev || {};
    var b = byId(next);
    for (var id in b)
        if (Object.prototype.hasOwnProperty.call(b, id)) {
            if (!a[id])
                out.plugged.push(b[id]);
            else if (signature(a[id]) !== signature(b[id]))
                out.changed.push(b[id]);
        }
    for (var k in a)
        if (Object.prototype.hasOwnProperty.call(a, k) && !b[k])
            out.unplugged.push(a[k]);
    return out;
}

// ---------------------------------------------------------------- the words

// A drive's marketed size: decimal, as the box says it (a 32 GB stick reads 29.7 GiB).
function driveSize(n) {
    if (!(n > 0))
        return "";
    if (n >= 1e12) {
        var t = Math.round(n / 1e11) / 10;
        return t + " TB";
    }
    return Math.round(n / 1e9) + " GB";
}

// What to call it: the maker and the model, else the first label, else "USB drive".
function name(d) {
    var n = (d.vendor + " " + d.model).trim();
    if (n !== "")
        return n;
    for (var i = 0; i < d.parts.length; i++)
        if (d.parts[i].label !== "")
            return d.parts[i].label;
    return "USB drive";
}

// "SanDisk Ultra connected" / "TESTDRIVE . 32 GB . exFAT".
function text(d) {
    var nm = name(d);
    var bits = [];
    for (var i = 0; i < d.parts.length; i++)
        if (d.parts[i].label !== "" && d.parts[i].label !== nm && bits.indexOf(d.parts[i].label) < 0)
            bits.push(d.parts[i].label);
    var size = driveSize(d.size);
    if (size !== "")
        bits.push(size);
    var fs = [];
    for (var j = 0; j < d.parts.length; j++)
        if (fs.indexOf(d.parts[j].fstype) < 0)
            fs.push(d.parts[j].fstype);
    bits.push(fs.length > 0 ? fs.join(", ") : "no filesystem");
    return { title: nm + " connected", body: bits.join(" · ") };
}

// "SanDisk Ultra mounted" / "at /run/media/user/TESTDRIVE" (the first mount point, and the others after it).
function mounted(d) {
    return { title: name(d) + " mounted", body: "at " + mountsOf(d).join(", ") };
}

function ejected(d) {
    return { title: name(d) + " can be removed", body: "Every filesystem on it is unmounted" };   // a fact, not the title again
}

function lost(d) {
    return { title: name(d) + " was removed", body: "It was still mounted: its files may be damaged." };
}

// udisksctl wraps its reason three times ("Error unmounting /dev/sdb1: GDBus.Error:org.freedesktop.UDisks2.Error.DeviceBusy:
// target is busy"): the last piece of the first line is the part a person reads.
function reason(err) {
    var line = String(err === undefined || err === null ? "" : err).trim().split("\n")[0].trim();
    if (line === "")
        return "udisksctl failed";
    var cut = line.lastIndexOf(": ");
    var tail = cut >= 0 ? line.substring(cut + 2).trim() : line;
    return tail.length >= 4 ? tail : line;
}

// "Could not eject SanDisk Ultra" / "target is busy".
function failed(d, what, err) {
    return { title: "Could not " + what + " " + name(d), body: reason(err) };
}

// Every filesystem is unmounted but the drive would not power off: not the word "safe".
function unmounted(d, err) {
    return { title: name(d) + " is unmounted", body: "It could not be powered off: " + reason(err) };
}

function mountsOf(d) {
    var out = [];
    for (var i = 0; i < d.parts.length; i++)
        for (var j = 0; j < d.parts[i].mountpoints.length; j++)
            if (out.indexOf(d.parts[i].mountpoints[j]) < 0)
                out.push(d.parts[i].mountpoints[j]);
    return out;
}

function unmountedParts(d) {
    return d.parts.filter(function (p) { return p.mountpoints.length === 0; });
}

function mountedParts(d) {
    return d.parts.filter(function (p) { return p.mountpoints.length > 0; });
}

// The opener's argv from the user's template: every `{path}` (a whole argument or inside one) is the mount point.
function openArgv(template, path) {
    var out = [];
    for (var i = 0; i < template.length; i++)
        out.push(String(template[i]).split("{path}").join(path));
    return out;
}

function mountedAt(d) {
    for (var i = 0; i < d.parts.length; i++)
        if (d.parts[i].mountpoints.length > 0)
            return d.parts[i].mountpoints[0];
    return "";
}

// `udisksctl mount` answers "Mounted /dev/sdb1 at /run/media/user/TEST." (the dot is the sentence's).
function mountPathOf(out) {
    var m = /\bat (\/[^\n]*?)\.?\s*$/.exec(String(out).trim());
    return m ? m[1] : "";
}
