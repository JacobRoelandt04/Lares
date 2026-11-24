.pragma library

// =============================================================================
// UpdateGroups.js -- which packages of one update category fold under a group
// header, and in what order the category's rows are then listed. PURE: no Qt.
//
// THE PREFIX RULE. A package's group is the word before its first "-"
// (`python-numpy` -> `python`, `lib32-mesa` -> `lib32`, `qt6-base` -> `qt6`,
// `haskell-aeson` -> `haskell`). A name with no "-" has none of its own, but it
// JOINS the group named after it when the category has one: `pipewire` is the base
// of `pipewire-*`, and counts towards it. A bare name that no `<name>-*` package follows
// stays alone. A group exists only from MIN (3) packages of the category (the base
// included): two would save no row once the header is counted.
//
// ONE RULE FOR THE LIST AND THE BAR. `statusCount` is the number of updates the bar
// glyph's status level counts: each group once, every other package once (qemu's
// hundred packages are one update there; the popup and the lockscreen keep the real
// count). It reads `groupsOf`, so what the status calls a group is exactly what the
// popup folds under a row.
// The count is taken over EVERY package of the category, favourites included,
// so favouriting one never dissolves or re-forms a group (a group that comes
// and goes with the stars would flap the list).
//
// WHAT THE LIST LOOKS LIKE (rows arrive favourites-first, then by name, as the
// service sorts them):
//
//   1. a group whose packages are ALL favourites: its header ("favgroup:<key>"),
//      then its packages while it is open. It is "a favourite of its own" -- at
//      the top, the header wearing the favourite's full-strength mark.
//   2. the favourite packages left over, each pulled OUT of its group (depth 0).
//   3. everything else, in order; a group's header takes the place of its
//      first package, and its (non-favourite) packages follow it while it is
//      open, one level in (depth 1).
//
// An entry is {name, kind: "pkg" | "group", groupKey, depth, ...}. A package
// entry is the input row with `kind`, `groupKey` and `depth` added; a group
// entry carries `groupCount` (the packages under it), `groupFav` (all of them
// favourites) and `groupOpen`, and is a favourite (`isFavorite`) exactly when
// `groupFav`. Its name differs by that state, so the list's diff retires the
// header from one place and brings it in at the other instead of teleporting it.
// =============================================================================

var MIN = 3;

function prefixOf(name) {
    var s = String(name || "");
    var i = s.indexOf("-");
    return i > 0 ? s.substring(0, i) : "";
}

// { key: [row, ...] } for the groups of `rows` (>= min members), in the order
// their first member appears.
function groupsOf(rows, min) {
    var need = min === undefined ? MIN : min;
    var byKey = Object.create(null), order = [], prefixes = Object.create(null);
    var i;
    for (i = 0; i < rows.length; i++) {
        var p = prefixOf(rows[i].name);
        if (p !== "")
            prefixes[p] = true;
    }
    // keyOf: package name -> group key ("" when it is in none of them)
    for (i = 0; i < rows.length; i++) {
        var n = String(rows[i].name || "");
        var k = prefixOf(n);
        if (k === "" && prefixes[n])
            k = n;
        if (k === "")
            continue;
        if (!byKey[k]) {
            byKey[k] = [];
            order.push(k);
        }
        byKey[k].push(rows[i]);
    }
    var out = Object.create(null), keys = [], keyOf = Object.create(null);
    for (var j = 0; j < order.length; j++)
        if (byKey[order[j]].length >= need) {
            out[order[j]] = byKey[order[j]];
            keys.push(order[j]);
            for (var m = 0; m < byKey[order[j]].length; m++)
                keyOf[byKey[order[j]][m].name] = order[j];
        }
    return { members: out, keys: keys, keyOf: keyOf };
}

// How many updates the bar glyph's status level counts for these rows (ONE category's, or
// all of them when the caller has no categories: a group never spans two repos in the popup,
// so the caller sums per category): every group once, every package outside one once.
function statusCount(rows, min) {
    var g = groupsOf(rows, min), inGroups = 0;
    for (var i = 0; i < g.keys.length; i++)
        inGroups += g.members[g.keys[i]].length;
    return rows.length - inGroups + g.keys.length;
}

function _pkg(row, depth, key) {
    var e = {};
    for (var f in row)
        e[f] = row[f];
    e.kind = "pkg";
    e.depth = depth;
    e.groupKey = key;
    return e;
}

function _head(key, members, allFav, open) {
    var shown = 0;
    for (var i = 0; i < members.length; i++)
        if (allFav || !members[i].isFavorite)
            shown++;
    return {
        name: (allFav ? "favgroup:" : "group:") + key,
        oldVer: "", newVer: "",
        kind: "group", groupKey: key, depth: 0,
        groupCount: shown, groupFav: allFav, groupOpen: open,
        isFavorite: allFav
    };
}

// opts: { min, open: { key: true } }
function plan(rows, opts) {
    var o = opts || {};
    var open = o.open || {};
    var g = groupsOf(rows, o.min);
    if (g.keys.length === 0) {
        var flat = [];
        for (var i = 0; i < rows.length; i++)
            flat.push(_pkg(rows[i], 0, ""));
        return flat;
    }
    var allFav = Object.create(null);
    for (var a = 0; a < g.keys.length; a++) {
        var ms = g.members[g.keys[a]], every = true;
        for (var b = 0; b < ms.length; b++)
            if (!ms[b].isFavorite) {
                every = false;
                break;
            }
        allFav[g.keys[a]] = every;
    }

    var out = [];
    // 1. the groups that are favourites as a whole
    for (var c = 0; c < g.keys.length; c++) {
        var key = g.keys[c];
        if (!allFav[key])
            continue;
        var isOpen = open[key] === true;
        out.push(_head(key, g.members[key], true, isOpen));
        if (isOpen)
            for (var d = 0; d < g.members[key].length; d++)
                out.push(_pkg(g.members[key][d], 1, key));
    }
    // 2. favourites that are on their own (a mixed group's are pulled out)
    for (var e = 0; e < rows.length; e++) {
        var r = rows[e];
        if (!r.isFavorite)
            continue;
        var rk = g.keyOf[r.name] || "";
        if (rk !== "" && allFav[rk])
            continue;
        out.push(_pkg(r, 0, ""));
    }
    // 3. the rest, a group's header where its first package stood
    var seen = Object.create(null);
    for (var h = 0; h < rows.length; h++) {
        var row = rows[h];
        if (row.isFavorite)
            continue;
        var pk = g.keyOf[row.name] || "";
        if (pk === "") {
            out.push(_pkg(row, 0, ""));
            continue;
        }
        if (seen[pk])
            continue;
        seen[pk] = true;
        var openNow = open[pk] === true;
        out.push(_head(pk, g.members[pk], false, openNow));
        if (openNow)
            for (var m = 0; m < g.members[pk].length; m++)
                if (!g.members[pk][m].isFavorite)
                    out.push(_pkg(g.members[pk][m], 1, pk));
    }
    return out;
}

// The package names a right-click on a group's header changes: all of them
// are favourites -> every one is taken off; otherwise those not yet favourites
// are put on. {names, favorite} -- `favorite` is what they become.
function favoriteChange(rows, key, min) {
    var ms = groupsOf(rows, min).members[key] || [];
    var all = ms.length > 0, names = [], i;
    for (i = 0; i < ms.length; i++)
        if (!ms[i].isFavorite)
            all = false;
    if (all) {
        for (i = 0; i < ms.length; i++)
            names.push(ms[i].name);
        return { names: names, favorite: false };
    }
    for (i = 0; i < ms.length; i++)
        if (!ms[i].isFavorite)
            names.push(ms[i].name);
    return { names: names, favorite: true };
}
