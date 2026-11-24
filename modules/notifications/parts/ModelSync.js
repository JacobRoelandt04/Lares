.pragma library

// Mirror an ordered list of KEYS into a ListModel without regenerating what
// is already there. A Repeater whose model is a derived JS array is cleared
// and rebuilt on every reassignment (CLAUDE.md) -- every card re-created,
// every fade-in replayed -- so the manager's lists are ListModels kept in step
// with the service by key: a new key is inserted where it belongs, a gone one
// removed (or marked `leaving`, for a delegate that animates out and removes
// itself), a moved one moved. Rows carry `key` plus whatever `fill(key)`
// returns (plain facts, never a colour: a Repeater model may not hold one).
//
// Returns true when anything changed. A move emits nothing a binding can
// watch (CLAUDE.md), so a caller that reads the order bumps its own serial.

function sync(model, keys, fill, markLeaving) {
    let changed = false;
    const want = {};
    for (let i = 0; i < keys.length; i++)
        want[keys[i]] = i;

    // Gone keys: removed, or flagged for their own exit.
    for (let i = model.count - 1; i >= 0; i--) {
        const r = model.get(i);
        if (want[r.key] !== undefined)
            continue;
        if (markLeaving) {
            if (!r.leaving) {
                model.setProperty(i, "leaving", true);
                changed = true;
            }
        } else {
            model.remove(i);
            changed = true;
        }
    }

    // Wanted keys in order, skipping rows that are on their way out (they keep
    // their place until they have gone).
    let pos = 0;
    for (let k = 0; k < keys.length; k++) {
        const key = keys[k];
        while (pos < model.count && model.get(pos).leaving && want[model.get(pos).key] === undefined)
            pos++;
        if (pos < model.count && model.get(pos).key === key) {
            const r = model.get(pos);
            if (r.leaving) {
                model.setProperty(pos, "leaving", false);
                changed = true;
            }
            refresh(model, pos, fill ? fill(key) : null);
            pos++;
            continue;
        }
        let found = -1;
        for (let j = pos + 1; j < model.count; j++) {
            if (model.get(j).key === key) {
                found = j;
                break;
            }
        }
        if (found >= 0) {
            model.move(found, pos, 1);
            if (model.get(pos).leaving)
                model.setProperty(pos, "leaving", false);
            refresh(model, pos, fill ? fill(key) : null);
        } else {
            const row = fill ? fill(key) : {};
            row.key = key;
            row.leaving = false;
            model.insert(pos, row);
        }
        changed = true;
        pos++;
    }
    return changed;
}

// Write only the roles whose value differs (setProperty on an equal value
// still notifies).
function refresh(model, i, row) {
    if (!row)
        return;
    const cur = model.get(i);
    for (const k in row) {
        if (k === "key")
            continue;
        const a = cur[k], b = row[k];
        if (a !== b && JSON.stringify(a) !== JSON.stringify(b))
            model.setProperty(i, k, b);
    }
}

function removeKey(model, key) {
    for (let i = 0; i < model.count; i++) {
        if (model.get(i).key === key) {
            model.remove(i);
            return true;
        }
    }
    return false;
}
