pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import "DayTimes.js" as DayTimes
import "NotifyPolicy.js" as Policy
import "NotifyMarkup.js" as Markup
import "../../common/icons"
import "../../common/notify"
import "../../common/system"

// =============================================================================
// NotificationService.qml -- the notification hub, ONE per shell (outside any
// Variants). CONTRACT.md §D is its API; this header is how it holds together.
//
// WHERE RECORDS COME FROM. D-Bus notifications arrive through the bridge (a
// LazyLoader, so `serverEnabled: false` never registers the name) as live
// Notification objects -- or FakeNotifications, through the same `receive()`
// -- and shell sources call `post(spec)` directly (DesktopNotifier and
// LlmAttention do, through NotificationBus). Either way a record (CONTRACT
// "Record") goes into the store and a DECISION is taken once, by
// NotifyPolicy.decide over the moment's facts: DND and what breaks through
// it, the hold (lock / share / fullscreen), the manager being open, the source
// being attended, the sender's own window being focused, an app rule's mute
// (or its `drop`, which files nothing), a synchronous OSD hint. "show" hands it to the scheduler (which may still
// file it as a flood), "hold" parks it until the hold ends, "file" leaves it
// in the manager only, "drop" never records it (and never tracks it, so the
// server reports it Dismissed to its sender at once).
//
// WHAT STAYS OUT OF THE MODEL. The live Notification, a shell post's
// callbacks (`onAction`, `onDefault`, each action's `run`), its rich body
// (`bodyComponent` + `bodyProps`, read through `richBodyOf`), its sound
// request and the sender's sound hints live in a side map keyed by uid
// (`_rt`). A record never holds a function or an object that is not data.
//
// A REPLACE IS THE SAME RECORD. A shell post with a (source, key) that is
// live replaces it in place; a D-Bus replace arrives as change signals on the
// SAME object (`notification` is not emitted again). Both run
// NotifyPolicy.retoast: summary or body changed = shown again, only the
// progress changed = silent in place.
//
// KEPT. A shell post with `kept: true` is filed into the manager like any card but only its source's withdraw ever
// takes it away: remove() answers false and does nothing, clearAll / clearGroup and the retention pass skip it (a
// mounted drive's card). The refusal is shown by the card (SwipeVerbCard.refuse()).
//
// WHAT ENDS A RECORD. remove() (the user: a D-Bus one is dismiss()ed),
// withdraw (the source) and CloseRequested (the app) -- the last two keep a
// PINNED record, marked `closed`, actions off. Invoking an action or replying
// closes a non-resident D-Bus notification (the server does it) and the record
// goes with it (a pinned one stays, `closed`). A shell action or a body click
// removes its record BEFORE its callback runs, so a callback that posts again
// on the same key starts a new record rather than being removed with the old
// one; a resident or PINNED record is never removed by a click or an action --
// only an explicit delete takes a pin. clearAll / clearGroup take the unpinned
// records -- or, under a search filter, only the ones it shows (`uids`) -- out
// of the model at once and keep them (live objects, images and all) for
// `undoMs`; only when that window closes are they dismissed and their
// images deleted. `undoState` is the LATEST window on offer (the manager's one
// Undo slot), so a manager built inside it -- reopened, recreated -- re-arms
// its button from it. Retention (NotifyPolicy.retain: count, days; pins,
// toasts, held ones exempt) runs after every new record, when the config
// changes and at the next age-out.
//
// AN IMAGE IS AN AVATAR, A PICTURE OR AN ICON (`_imageFor`). libnotify's
// `notify-send -i X` -- the user's own volume / brightness scripts, every app
// built on notify_notification_new(icon) -- sends X in the image-path hint
// with app_icon empty, so an ICON arrives as the image: a theme name, or a
// file NotifyPolicy.isIconPath calls an icon. Those are kind "icon" (`icon`:
// the name or the path) and the card draws them as its column's own icon,
// uncut; measured as an image, a theme icon would read as an avatar and be cut
// to a circle and resampled.
//
// A FIXED POST (`post({ fixed: true })`, rec.fixed) is live UI, not a
// notification: the auth prompt. The user cannot end it -- `file`, `remove`,
// `togglePin` and `activate` do nothing to it, a click or an action never
// consumes it, the clears skip it, and the toast has no swipe verbs. Only the
// source that posted it ends it, with withdraw / withdrawUid. It is never history: it is
// `transient` (not persisted), `seen`, and in the group "fixed" -- which is
// none of the manager's groups, so the manager neither lists nor counts it --
// and whatever takes it off the lane (withdrawn, a timeout, an overflowing
// stack, a hold's summary) DROPS the record instead of filing it. A decision to
// file it (the manager is open, DND, a rule) shows it instead: a prompt that
// waits for an answer is never filed away, and the manager opening takes it
// off the lane and puts it straight back.
//
// A LIVE POST (`post({ live: true })`, rec.live) is a toast that keeps changing (the wiki's batch progress) and that the user
// may put away (the user, 2026-11-12: swiped away it "will just reappear as soon as the subtitle changes"). While it is a toast
// it is in the group "live" -- none of the manager's, so the manager neither lists nor counts it -- and the manager opening
// leaves it on the lane, beside the manager, as it does a fixed one. Both swipes of its toast HIDE it (`hide`): it goes into
// the manager in its own group, its later updates change it there and never toast it again, and both swipes of its manager
// entry UNHIDE it (`unhide`): back out of the manager, a toast again. Whatever else takes it off the lane (a full stack, a
// timeout, DND or a rule filing it) hides it too, so it is never in neither place. It cannot be deleted or cleared by the
// user; it is `transient` and `seen`. A post of the same key WITHOUT `live` (the batch's result) is an ordinary notification
// again, shown as one.
//
// A DEADLINE THE TOAST ONLY SHOWS (`post({ deadlineMs, deadlineTotalMs })`, rec.deadlineMs / rec.deadlineTotalMs): a source whose time
// is somebody else's -- the MUX guard that puts Hybrid back at the helper's own instant -- says the wall instant and the span it runs
// over, and the card's drain follows THAT (ToastEntry): it does not freeze for a hover, the user being away or a folded lane (the
// instant would then be a lie), is not the scheduler's (the toast stays sticky there: it never expires, nothing is filed or dropped
// when the drain reaches nothing) and moves with `update(uid, { deadlineMs, deadlineTotalMs })` in place, silently. 0 = none.
//
// INTERACTION. A rich body that needs the keyboard or the whole track's
// pointer says so through `setInteraction(token, { keyboard, catchAll })`;
// `interaction` is the strongest over every token (a new object when it
// changes) and NotificationToast republishes it as its keyboardFocusRequest
// and maskCatchAll. The token is the caller's own string; the body clears its
// own on destruction (`clearInteraction`), and a token that carries `uid` (or
// equals one) is also cleared when that record ends, so a body that never got
// to run cannot leave the lane catching clicks.
//
// ONE ASK, ONE ENTRY, ACROSS RESTARTS. A shell post's key is its identity: the
// same (source, key) as a live record replaces it. The map of live keys lives in
// memory, so a restart would forget every key the history still held and a
// module that says its ask again at every start (the wiki's "No Discover
// entries yet -- process 30 now?") would add a copy per start. `_relinkKeys()` at
// completion builds the map from the stored history (every keyed shell record
// read back, not closed), and collapses the copies an earlier run left (the
// newest stays, a pin of any of them goes with it). A post whose key finds such
// a STALE record (a copy from another run: its callbacks are gone, its actions
// off) is the user's "delete that one and then resend": the stale entry goes,
// the pin it carried goes to the new one, and the new one is a fresh arrival
// that toasts -- the module says it again because nobody answered, and "again"
// is a toast, not a silent edit of a row. A live record of THIS run keeps its
// quiet in-place replace (the retoast rule): progress ticks must not toast.
//
// A POST BEFORE THE LANE CAN SHOW IT WAITS FOR THE LANE. The first posts of a
// run land in the first turns after the start, before the compositor has
// answered which screen has the focus (FocusedScreen reads hyprctl) and
// before every screen's bars have registered: the stack would be "shown" on no
// screen, its clocks would run unseen, and a sticky ask would sit in the
// scheduler for ever while only the manager had it. So `laneScreen` takes the focused screen as soon
// as it is known when it was not known at the post (it still never moves while
// it names a screen: the stack stays where it grew), and while a hosted
// service has toasts and no screen for them (`_waitingForScreen`) the
// scheduler's clocks stand still (`unplaced`), like a toast waiting for room
// beside a popup. The owner asks for its lane the moment a place for it
// exists (NotificationsBarOwner). Which display that is, is the holds' `lane` (the focused one, or the one notifications.jsonc
// names).
//
// A SUSPEND stops Qt's (monotonic) timers while the wall moves on: on the
// resume the undo window and the age-out are re-armed from the wall, and the
// toasts' scheduler freezes across the sleep (ToastScheduler).
// =============================================================================
Item {
    id: root

    property string configPath:
        (Quickshell.env("XDG_CONFIG_HOME") || (Quickshell.env("HOME") + "/.config"))
        + "/quickshell/config/notifications.jsonc"
    property string statePath:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
        + "/lares/notifications/state.json"
    property string historyPath:
        (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state"))
        + "/lares/notifications/history.json"
    property bool serverEnabled: true
    property bool registerOnBus: true
    property bool liveSignals: true
    // The portal's cast nodes from PipeWire (NotificationHolds, THE SCREEN SHARE): follows liveSignals.
    property bool livePipewire: root.liveSignals
    // The shell's one focus tracker (a FocusedScreen, modules/common/system), handed to the holds: the lane
    // follows ITS focused screen and the fullscreen hold reads ITS answer (null = the holds' own).
    property var focusSource: null
    property bool persist: true
    property bool ipcEnabled: true
    // Whose sleeps the timers follow: the shell's one watcher; a probe hands
    // its own (or null).
    property var sleepWatcher: Sleep.watcher

    readonly property var store: storeItem
    readonly property var config: cfg.config
    // An image at most this many px on both sides and roughly square is an AVATAR beside the text; anything else is a picture band under
    // it (NotifyPolicy.imageKind). 128: a contact photo, not a screenshot. A constant of the module, tuned in the notifications mockup.
    property int avatarMax: 128
    readonly property var holds: holdsItem
    readonly property var toasts: sched
    readonly property var sound: soundItem
    readonly property int serial: storeItem.serial
    readonly property string imagesDir: storeItem.imagesDir
    readonly property string configError: cfg.lastError
    // The bridge is up and owns the name (false with serverEnabled: false).
    readonly property bool serverRunning: bridge.item !== null && bridge.item !== undefined

    property alias dnd: st.dnd
    readonly property real lastOpenedMs: st.lastOpenedMs
    readonly property string holdReason: holdsItem.reason
    readonly property string dotGroup: root._dotGroup()
    readonly property int unseenCount: root._unseen()
    readonly property string laneScreen: root._laneScreen
    // Where a request for the manager that names no screen opens it: the lane's -- the focused one while the lane stands on a
    // display of its own (notifications.jsonc `screen`).
    readonly property string managerScreen: holdsItem.laneNamed ? holdsItem.focusedScreen : root._laneScreen
    // The latest undo on offer: { token, kind: "all" | "group", group,
    // startedMs, deadlineMs, totalMs } (wall ms), or null. Back to null when
    // that undo is taken, expires, or has nothing left to restore (its
    // records withdrawn by their apps). One slot: a newer clear replaces it.
    readonly property var undoState: root._undoState
    property bool managerOpen: false
    // The strongest interaction asked for over all tokens (see INTERACTION):
    // { keyboard: "none" | "onDemand" | "exclusive", catchAll: bool }.
    readonly property var interaction: root._interaction

    signal openManagerRequested(string screenName)
    signal closeManagerRequested()
    signal recordAdded(string uid)
    signal recordRemoved(string uid)

    // ---- Shell sources -------------------------------------------------------

    function post(spec) {
        const s = spec || {};
        const source = String(s.source || "").trim();
        if (source.length === 0)
            return "";
        const key = (s.key === undefined || s.key === null) ? "" : String(s.key);
        const now = Date.now();
        const liveUid = key.length > 0 ? root._liveKey[root._keyOf(source, key)] : undefined;
        if (liveUid && !storeItem.has(liveUid))
            root._unstash(liveUid);        // cleared, then posted again: the new one wins
        let prev = liveUid ? storeItem.get(liveUid) : null;
        // The same ask from an earlier run (ONE ASK, ONE ENTRY): delete that one, then send this one.
        // What the user did to the entry (a pin) is theirs and goes with it.
        let carry = null;
        if (prev && prev.stale) {
            carry = { pinned: prev.pinned, pinnedMs: prev.pinnedMs };
            root._finalRemove(prev.uid, false);
            prev = null;
        }
        const uid = prev ? prev.uid : root._newUid("s" + source + "-" + key + "-", now);

        const acts = [];
        const runs = {};
        let defaultId = "";
        const list = Array.isArray(s.actions) ? s.actions : [];
        for (let i = 0; i < list.length; i++) {
            const a = list[i];
            if (!a || a.id === undefined || a.id === null)
                continue;
            const id = String(a.id);
            if (typeof a.run === "function")
                runs[id] = a.run;
            // A body click runs `default`, else `open`, else `show` (the
            // adapter's actions) -- the first in that order the post has.
            if ((id === "default" || id === "open" || id === "show")
                    && (defaultId === "" || ["default", "open", "show"].indexOf(id) < ["default", "open", "show"].indexOf(defaultId)))
                defaultId = id;
            if (id === "default" || id === "inline-reply")
                continue;
            const act = { id: id, label: String(a.label === undefined ? id : a.label) };
            if (a.icon)
                act.icon = String(a.icon);     // an icon-only button (the card draws this glyph; `label` is its name)
            acts.push(act);
        }
        const hasDefault = typeof s.onDefault === "function" || defaultId !== "";
        const body = s.body === undefined || s.body === null ? "" : String(s.body);
        const fixed = s.fixed === true;
        const live = s.live === true && !fixed;
        const rec = {
            uid: uid, origin: "shell", serverId: 0, sourceId: source, key: key,
            appName: s.appName ? String(s.appName) : source.charAt(0).toUpperCase() + source.substring(1),
            appKey: source.toLowerCase(), desktopEntry: "",
            appIcon: s.icon ? String(s.icon) : "",
            summary: s.title === undefined || s.title === null ? "" : String(s.title),
            body: Markup.sanitize(body), bodyText: Markup.plain(body),
            urgency: root._urgencyName(s.urgency),
            group: "system",
            arrivedMs: prev ? prev.arrivedMs : now, updatedMs: now,
            actions: acts, hasDefault: hasDefault, reply: null,
            image: s.image ? root._imageFor(String(s.image)) : null,
            progress: root._progress(s.progress),
            resident: !!s.resident, transient: fixed || live || s.persist === false, fixed: fixed,
            live: live, kept: s.kept === true && !fixed && !live, hidden: live && !!prev && prev.live === true && prev.hidden === true,
            deadlineMs: root._wall(s.deadlineMs), deadlineTotalMs: root._wall(s.deadlineTotalMs),
            pinned: prev ? prev.pinned : (carry ? carry.pinned : false),
            pinnedMs: prev ? prev.pinnedMs : (carry ? carry.pinnedMs : 0),
            closed: false, stale: false, seen: fixed || live
        };
        const rt = {
            live: null, source: source, key: key,
            onAction: typeof s.onAction === "function" ? s.onAction : null,
            onDefault: typeof s.onDefault === "function" ? s.onDefault : null,
            runs: runs, defaultId: defaultId,
            bodyComponent: s.bodyComponent || null,
            bodyProps: s.bodyProps || null, propsRev: 0,
            sound: { spec: s.sound === undefined ? "none" : String(s.sound) },
            breakDnd: !!s.breakDnd,
            requestedMs: s.timeoutMs
        };
        if (key.length > 0)
            root._liveKey[root._keyOf(source, key)] = uid;
        root._rt[uid] = rt;
        root._admit(rec, prev);
        return uid;
    }

    function update(uid, patch) {
        const prev = storeItem.get(uid);
        const rt = root._rt[uid];
        if (!prev || !rt || prev.origin !== "shell" || prev.closed)
            return false;
        const p = patch || {};
        const next = Object.assign({}, prev, { updatedMs: Date.now() });
        if (p.title !== undefined)
            next.summary = String(p.title);
        if (p.body !== undefined) {
            next.body = Markup.sanitize(String(p.body));
            next.bodyText = Markup.plain(String(p.body));
        }
        if (p.urgency !== undefined)
            next.urgency = root._urgencyName(p.urgency);
        if (p.progress !== undefined)
            next.progress = root._progress(p.progress);
        if (p.icon !== undefined)
            next.appIcon = String(p.icon || "");
        if (p.image !== undefined)
            next.image = p.image ? root._imageFor(String(p.image)) : null;
        if (p.bodyProps !== undefined) {
            rt.bodyProps = p.bodyProps;
            rt.propsRev++;
        }
        if (p.timeoutMs !== undefined)
            rt.requestedMs = p.timeoutMs;
        if (p.deadlineMs !== undefined)
            next.deadlineMs = root._wall(p.deadlineMs);
        if (p.deadlineTotalMs !== undefined)
            next.deadlineTotalMs = root._wall(p.deadlineTotalMs);
        root._admit(next, prev);
        return true;
    }

    function withdraw(source, key) {
        const uid = root._liveKey[root._keyOf(String(source), String(key))];
        if (uid)
            root.withdrawUid(uid);
    }

    function withdrawUid(uid) {
        if (root._unstash(uid))
            return;
        const rec = storeItem.get(uid);
        if (!rec)
            return;
        sched.unshow(uid);
        if (rec.pinned && rec.kept !== true) {
            root._unlinkKey(uid);
            storeItem.patch(uid, { closed: true });
            const rt = root._rt[uid];
            const live = rt ? rt.live : null;
            delete root._rt[uid];
            if (live)
                live.dismiss();
            return;
        }
        root._finalRemove(uid, true);
    }

    function attend(source, on) {
        const a = Object.assign({}, root._attended);
        a[String(source)] = !!on;
        root._attended = a;
    }

    // ---- User verbs ------------------------------------------------------------

    function file(uid) {
        if (root._isFixed(uid))
            return;
        if (root._isLive(uid)) {
            root.hide(uid);
            return;
        }
        sched.unshow(uid);
    }

    function remove(uid) {
        const rec = storeItem.get(uid);
        // A KEPT record (`kept: true` on the post: a drive that is still mounted) is the source's alone to take away.
        if (!rec || rec.kept === true || root._isFixed(uid) || root._isLive(uid))
            return false;
        sched.unshow(uid);
        root._finalRemove(uid, true);
        return true;
    }

    // A live record's two verbs (see the header): into the manager, and back out of it as a toast.
    function hide(uid) {
        const rec = storeItem.get(uid);
        if (!rec || rec.live !== true || rec.hidden === true)
            return false;
        sched.unshow(uid);
        storeItem.put(Object.assign({}, rec, { hidden: true, seen: true, group: Policy.groupOf(rec, Policy.ruleFor(root.config, rec)) }));
        return true;
    }

    function unhide(uid) {
        const rec = storeItem.get(uid);
        const rt = root._rt[uid];
        if (!rec || rec.live !== true || rec.hidden !== true || !rt)
            return false;
        const next = Object.assign({}, rec, { hidden: false, group: "live" });
        storeItem.put(next);
        root._toast(next, Policy.ruleFor(root.config, next), rt, { toast: "show", sound: false });
        return true;
    }

    function togglePin(uid) {
        const rec = storeItem.get(uid);
        if (!rec || rec.fixed === true)
            return false;
        return storeItem.patch(uid, rec.pinned ? { pinned: false, pinnedMs: 0 }
                                               : { pinned: true, pinnedMs: Date.now() });
    }

    function invoke(uid, actionId) {
        const rec = storeItem.get(uid);
        const rt = root._rt[uid];
        if (!rec || !rt || rec.stale || rec.closed)
            return false;
        const id = String(actionId);
        if (rec.origin === "shell") {
            const run = rt.runs[id] || null;
            const cb = rt.onAction;
            root._consumed(rec);
            if (run)
                run();
            else if (cb)
                cb(id);
            return true;
        }
        const live = rt.live;
        if (!live)
            return false;
        const acts = live.actions || [];
        for (let i = 0; i < acts.length; i++) {
            if (acts[i].identifier === id) {
                // A non-resident notification is closed by the server
                // (Dismissed); the closed handler takes the record.
                acts[i].invoke();
                return true;
            }
        }
        return false;
    }

    function activate(uid) {
        const rec = storeItem.get(uid);
        if (!rec || rec.fixed === true)
            return false;
        const rt = root._rt[uid];
        if (rec.origin === "shell") {
            if (rt && !rec.stale && !rec.closed) {
                if (rt.onDefault) {
                    const cb = rt.onDefault;
                    root._consumed(rec);
                    cb();
                    return true;
                }
                if (rt.defaultId)
                    return root.invoke(uid, rt.defaultId);
            }
            root._consumed(rec);
            return true;
        }
        if (rec.hasDefault && rt && rt.live && !rec.stale && !rec.closed)
            return root.invoke(uid, "default");
        if (root.config.clickFocus)
            holdsItem.focusApp(root._withPid(rec, rt));
        root._consumed(rec);
        return true;
    }

    // After a click or an action: the record goes, unless it is resident or
    // the user pinned it (only an explicit delete removes a pin).
    function _consumed(rec) {
        if (!rec.resident && !rec.pinned)
            root.remove(rec.uid);
    }

    function reply(uid, text) {
        const rec = storeItem.get(uid);
        const rt = root._rt[uid];
        if (!rec || !rt || !rt.live || !rec.reply || rec.stale || rec.closed)
            return false;
        rt.live.sendInlineReply(String(text));
        return true;
    }

    // Every unpinned record -- or, given `uids`, only those of them: Clear all
    // under a search filter clears the rows the filter shows, in every group,
    // and its undo restores exactly those. `[]` (a filter that shows nothing)
    // clears nothing; only a missing `uids` means everything.
    function clearAll(uids) {
        const only = root._only(uids);
        return root._stash(storeItem.all().filter(r => !r.pinned && !r.fixed && !r.live && !r.kept && (!only || only.indexOf(r.uid) >= 0)), "all", "");
    }

    // A group's unpinned records -- or, given `uids`, only those of them: a
    // header swiped under a search filter clears the rows the filter shows,
    // and its undo restores exactly those.
    function clearGroup(group, uids) {
        const only = root._only(uids);
        return root._stash(storeItem.all().filter(r => !r.pinned && !r.fixed && !r.live && !r.kept && r.group === group
                                                      && (!only || only.indexOf(r.uid) >= 0)), "group", String(group));
    }

    function undo(token) {
        const u = root._undo[token];
        if (!u || Date.now() > u.until)
            return false;
        const all = Object.assign({}, root._undo);
        delete all[token];
        root._undo = all;
        root._offerEnded(token);
        for (let i = 0; i < u.records.length; i++) {
            const r = u.records[i];
            storeItem.put(r);
            if (r.origin === "shell" && r.key && !r.closed)
                root._liveKey[root._keyOf(r.sourceId, r.key)] = r.uid;
            root.recordAdded(r.uid);
        }
        root._armUndo();
        return true;
    }

    function markSeen() {
        const recs = storeItem.all();
        for (let i = 0; i < recs.length; i++)
            if (!recs[i].seen)
                storeItem.patch(recs[i].uid, { seen: true });
        st.lastOpenedMs = Date.now();
    }

    // The UI saved a live image into imagesDir; w/h (optional) are the
    // image's own size when the UI knows it better than the service did.
    function imageGrabbed(uid, file, w, h) {
        const rec = storeItem.get(uid);
        if (!rec || !rec.image)
            return false;
        const img = Object.assign({}, rec.image, { file: String(file) });
        if (!img.openPath)
            img.openPath = String(file);
        if (w > 0 && h > 0) {
            img.w = w;
            img.h = h;
            // An icon stays an icon, whatever size it was drawn at.
            if (img.kind !== "icon")
                img.kind = Policy.imageKind(w, h, root.avatarMax);
        }
        return storeItem.patch(uid, { image: img });
    }

    // A shell post's rich body: { component, props, rev } | null. `rev` counts the times `update` handed new `bodyProps`: a card
    // writes the props into its loaded body at load and again only when `rev` moved (a change of any other field of the record is
    // none of the body's business).
    function richBodyOf(uid) {
        const rt = root._rt[uid];
        return rt && rt.bodyComponent ? { component: rt.bodyComponent, props: rt.bodyProps || {}, rev: rt.propsRev || 0 } : null;
    }

    // ---- Interaction (see the header) --------------------------------------------

    // `spec`: { keyboard: "none" | "onDemand" | "exclusive", catchAll: bool,
    // uid: the record it belongs to (optional) }. An all-default spec is the
    // same as clearInteraction(token).
    function setInteraction(token, spec) {
        const t = String(token === undefined || token === null ? "" : token);
        if (t === "")
            return;
        const sp = spec || {};
        const kb = sp.keyboard === "onDemand" || sp.keyboard === "exclusive" ? sp.keyboard : "none";
        const all = sp.catchAll === true;
        if (kb === "none" && !all) {
            root.clearInteraction(t);
            return;
        }
        root._itoks[t] = { keyboard: kb, catchAll: all, uid: sp.uid ? String(sp.uid) : "" };
        root._recomputeInteraction();
    }

    function clearInteraction(token) {
        const t = String(token === undefined || token === null ? "" : token);
        if (!(t in root._itoks))
            return;
        delete root._itoks[t];
        root._recomputeInteraction();
    }

    // THE LANE IS WANTED AND NOT OUT, per screen (shell-hosted). The scheduler is one and a shell
    // has an owner per screen, so each owner REPORTS its own answer and the clocks are blocked
    // while any screen says yes (a standalone owner binds `toasts.blocked` itself: one owner,
    // one writer). Kept by screen name, in place -- nothing binds to the map.
    function reportLaneUnseen(screenName, unseen) {
        const m = root._unseenBy;
        const k = String(screenName);
        if (unseen)
            m[k] = true;
        else
            delete m[k];
        sched.blocked = Object.keys(m).length > 0;
    }
    property var _unseenBy: ({})

    // ---- The bridge's side (and FakeNotification's) ------------------------------

    // A new Notification (real or FakeNotification). The bridge calls this
    // once per id; a replace arrives as change signals, watched here.
    function receive(n) {
        if (!n)
            return "";
        if (n.lastGeneration) {
            const back = root._relink(n);
            if (back)
                return back;
        }
        const hints = n.hints || {};
        const sync = hints["x-canonical-private-synchronous"] !== undefined;
        const now = Date.now();
        const uid = root._newUid("d" + n.id + "-", now);
        const rec = root._fromNotification(n, null, uid, now);
        const rt = {
            live: n, source: "", key: "", onAction: null, onDefault: null, runs: {}, defaultId: "",
            bodyComponent: null, bodyProps: null, sound: root._soundHints(hints),
            breakDnd: false, requestedMs: n.expireTimeout, senderPid: Number(hints["sender-pid"] || 0)
        };
        const rule = Policy.ruleFor(root.config, rec);
        const decision = root._decide(rec, rule, rt, sync);
        if (decision.toast === "drop")
            return "";
        n.tracked = true;
        root._rt[uid] = rt;
        root._watch(n, uid);
        root._place(rec, rule, rt, decision);
        return uid;
    }

    // ---- Private -------------------------------------------------------------
    property var _rt: ({})              // uid -> runtime side (never in the model)
    property var _liveKey: ({})         // "source\u0001key" -> uid of the live shell record
    property var _attended: ({})
    property var _undo: ({})            // token -> { records, until }
    property var _undoState: null
    property var _dirty: ({})
    property int _uidSeq: 0
    property int _tokSeq: 0
    property string _laneScreen: ""
    // Toasts shown and no screen to show them on, with a focus source that will say which (a hosted
    // service: its name is "" only while it is unknown). Standalone hosts name their lane's screen
    // themselves and never wait.
    readonly property bool _waitingForScreen: !!root.focusSource && root._laneScreen === "" && sched.shown.length > 0
    property string _lastReason: ""
    property bool _ready: false
    property var _interaction: ({ keyboard: "none", catchAll: false })
    property var _itoks: ({})           // token -> { keyboard, catchAll, uid }

    function _recomputeInteraction() {
        const rank = { none: 0, onDemand: 1, exclusive: 2 };
        let kb = "none";
        let all = false;
        const keys = Object.keys(root._itoks);
        for (let i = 0; i < keys.length; i++) {
            const e = root._itoks[keys[i]];
            if (rank[e.keyboard] > rank[kb])
                kb = e.keyboard;
            if (e.catchAll)
                all = true;
        }
        if (kb !== root._interaction.keyboard || all !== root._interaction.catchAll)
            root._interaction = { keyboard: kb, catchAll: all };
    }

    // The tokens a record's end takes with it: the ones that carry its uid,
    // or are it.
    function _dropInteractionOf(uid) {
        const keys = Object.keys(root._itoks);
        let any = false;
        for (let i = 0; i < keys.length; i++) {
            if (keys[i] === uid || root._itoks[keys[i]].uid === uid) {
                delete root._itoks[keys[i]];
                any = true;
            }
        }
        if (any)
            root._recomputeInteraction();
    }

    function _isFixed(uid) {
        const r = storeItem.get(uid);
        return !!r && r.fixed === true;
    }

    // A fixed record whose toast ended by anything but its source's withdraw
    // (timeout, overflow): dropped, never filed. A live one is hidden: in the manager, where its unhide is.
    function _endFixed(uid) {
        if (root._isFixed(uid))
            root._finalRemove(uid, true);
        else if (root._isLive(uid))
            root.hide(uid);
    }

    function _isLive(uid) {
        const r = storeItem.get(uid);
        return !!r && r.live === true;
    }
    function _liveOnLane(uid) {
        const r = storeItem.get(uid);
        return !!r && r.live === true && r.hidden !== true;
    }

    function _keyOf(source, key) {
        return source + "\u0001" + key;
    }

    // A record read back from history has no runtime side (`_rt`): its own fields name its key.
    function _unlinkKey(uid) {
        const rt = root._rt[uid];
        const rec = storeItem.get(uid);
        const source = rt && rt.key ? rt.source : (rec && rec.origin === "shell" ? rec.sourceId : "");
        const key = rt && rt.key ? rt.key : (rec && rec.origin === "shell" ? rec.key : "");
        if (key && root._liveKey[root._keyOf(source, key)] === uid)
            delete root._liveKey[root._keyOf(source, key)];
    }

    // The live keys, rebuilt from the history the store has just read (see ONE ASK, ONE ENTRY): one
    // record per (source, key) -- the newest, carrying the pin of any of its copies -- and the key
    // map pointing at it. A closed record (its source withdrew it while it was pinned) is history
    // only: its key is free for the next post.
    function _relinkKeys() {
        const recs = storeItem.all().filter(r => r.origin === "shell" && !!r.key && r.closed !== true && r.fixed !== true);
        const best = {};
        const copies = {};
        for (let i = 0; i < recs.length; i++) {
            const id = root._keyOf(recs[i].sourceId, recs[i].key);
            (copies[id] = copies[id] || []).push(recs[i]);
            const cur = best[id];
            const t = recs[i].updatedMs || recs[i].arrivedMs || 0;
            if (!cur || t >= (cur.updatedMs || cur.arrivedMs || 0))
                best[id] = recs[i];
        }
        for (const id in best) {
            const keep = best[id];
            let pinned = keep.pinned === true;
            let pinnedMs = keep.pinnedMs || 0;
            for (let i = 0; i < copies[id].length; i++) {
                const c = copies[id][i];
                if (c.uid === keep.uid)
                    continue;
                if (c.pinned === true) {
                    pinned = true;
                    pinnedMs = Math.max(pinnedMs, c.pinnedMs || 0);
                }
                root._finalRemove(c.uid, false);
            }
            if (pinned !== (keep.pinned === true))
                storeItem.patch(keep.uid, { pinned: pinned, pinnedMs: pinnedMs });
            root._liveKey[id] = keep.uid;
        }
    }

    function _newUid(prefix, now) {
        let uid = prefix + now;
        while (storeItem.has(uid) || root._rt[uid] || root._inStash(uid))
            uid = prefix + now + "." + (++root._uidSeq);
        return uid;
    }

    function _urgencyName(u) {
        if (u === 0 || u === "low")
            return "low";
        if (u === 2 || u === "critical")
            return "critical";
        return "normal";
    }

    // A wall instant or a span in ms (0 = none): a real number past 0, never a NaN or a negative.
    function _wall(v) {
        const n = Number(v);
        return isFinite(n) && n > 0 ? n : 0;
    }

    function _progress(v) {
        const n = Number(v);
        if (v === undefined || v === null || !isFinite(n) || n < 0)
            return -1;
        return Math.max(0, Math.min(100, Math.round(n)));
    }

    // { url, file, w, h, kind, openPath, icon } for a URL, a path or an icon
    // name; null when the image does not load. kind "icon" (the header's AN
    // IMAGE IS ... AN ICON): a theme name -- not loaded here, the provider
    // answers any name at any size and a missing one would warn twice; the
    // card checks the theme -- or a file NotifyPolicy.isIconPath calls an
    // icon; `icon` is that name or path, for the card to take the way it takes
    // an appIcon. Any other image is measured now (an Image loads a local URL
    // synchronously) and is an avatar or a picture (imageKind).
    //
    // A FILE IS MEASURED AS ITSELF, never through the URL the server hands
    // over (image://icon//<path>): Quickshell's icon provider fits whatever it
    // loads into 100 x 100 and answers "Ready" -- with a warning -- for a file
    // that is not there (a 1920 x 1080 picture reads 100 x 56, a
    // 512 px icon and a 128 px one 100 x 100), so every squarish picture sent
    // by path would read as an avatar. The checked iconPath says, silently, whether
    // the file exists; `url` stays what the sender's server gave.
    function _imageFor(src) {
        let url = src;
        let path = "";
        if (src.charAt(0) === "/") {
            url = "file://" + src;
            path = src;
        } else if (src.indexOf("file://") === 0) {
            try {
                path = decodeURIComponent(src.substring(7));
            } catch (e) {
                path = src.substring(7);
            }
        } else if (src.indexOf("image://icon//") === 0) {
            path = src.substring(13);
        } else if (src.indexOf("image://icon/") === 0) {
            return { url: src, file: "", w: 0, h: 0, kind: "icon", openPath: "", icon: src.substring(13) };
        } else if (!/^[a-z]+:/.test(src)) {
            return { url: "image://icon/" + src, file: "", w: 0, h: 0, kind: "icon", openPath: "", icon: src };
        }
        if (path !== "" && AppIcons.checkedPath(path) === "")
            return null;
        const probe = path !== "" ? "file://" + path.split("/").map(c => encodeURIComponent(c)).join("/") : url;
        const im = measureComp.createObject(root, { source: probe }) as Image;
        const ok = im.status === Image.Ready;
        const w = ok ? im.sourceSize.width : 0;
        const h = ok ? im.sourceSize.height : 0;
        im.destroy();
        if (!ok)
            return null;
        const icon = path !== "" && Policy.isIconPath(path);
        return { url: url, file: "", w: w, h: h, kind: icon ? "icon" : Policy.imageKind(w, h, root.avatarMax),
                 openPath: path, icon: icon ? path : "" };
    }

    function _fromNotification(n, prev, uid, now) {
        const hints = n.hints || {};
        const acts = [];
        let hasDefault = false;
        const list = n.actions || [];
        for (let i = 0; i < list.length; i++) {
            const id = String(list[i].identifier);
            if (id === "default") {
                hasDefault = true;
                continue;
            }
            if (id === "inline-reply")
                continue;
            acts.push({ id: id, label: String(list[i].text) });
        }
        const de = String(n.desktopEntry || "");
        const an = String(n.appName || "");
        const img = String(n.image || "");
        const keepImg = prev && prev.image && prev.image.url === img;
        const placeholder = hints["x-kde-reply-placeholder-text"] !== undefined
            ? String(hints["x-kde-reply-placeholder-text"]) : String(n.inlineReplyPlaceholder || "Reply");
        return {
            uid: uid, origin: "dbus", serverId: Number(n.id), sourceId: "", key: "",
            appName: an, appKey: (de || an).toLowerCase().trim(), desktopEntry: de,
            appIcon: String(n.appIcon || ""),
            summary: String(n.summary || ""),
            body: Markup.sanitize(String(n.body || "")), bodyText: Markup.plain(String(n.body || "")),
            urgency: root._urgencyName(Number(n.urgency)),
            group: "normal",
            arrivedMs: prev ? prev.arrivedMs : now, updatedMs: now,
            actions: acts, hasDefault: hasDefault,
            reply: n.hasInlineReply ? { placeholder: placeholder } : null,
            image: img.length === 0 ? null : (keepImg ? prev.image : root._imageFor(img)),
            progress: root._progress(hints.value),
            resident: !!n.resident, transient: !!n.transient || hints.transient === true,
            pinned: prev ? prev.pinned : false, pinnedMs: prev ? prev.pinnedMs : 0,
            closed: false, stale: false, seen: prev ? prev.seen : false
        };
    }

    // An app/source rule's urgency, then the group (NotifyPolicy.groupOf).
    function _applyRule(rec, rule) {
        if (rule && (rule.urgency === "low" || rule.urgency === "normal" || rule.urgency === "critical"))
            rec.urgency = rule.urgency;
        rec.group = rec.fixed === true ? "fixed" : (rec.live === true && rec.hidden !== true ? "live" : Policy.groupOf(rec, rule));
    }

    // SenderMatch reads `senderPid`, which is runtime only (a pid read back
    // after a restart belongs to somebody else): a copy of the record with it.
    function _withPid(rec, rt) {
        return Object.assign({}, rec, { senderPid: rt && rt.senderPid > 0 ? rt.senderPid : 0 });
    }

    function _soundHints(hints) {
        return { suppress: !!hints["suppress-sound"], file: String(hints["sound-file"] || ""),
                 name: String(hints["sound-name"] || "") };
    }

    function _decide(rec, rule, rt, sync) {
        root._applyRule(rec, rule);
        const snd = rt.sound || {};
        const ctx = {
            dnd: st.dnd,
            breaks: Policy.breaks(rec, root.config, rt.breakDnd),
            ruleBreaks: !!rule && rule.breakDnd === true,
            hold: holdsItem.reason,
            managerOpen: root.managerOpen && !(rec.live === true && rec.hidden !== true),
            attended: rec.origin === "shell" && !!root._attended[rec.sourceId],
            focusedSender: rec.origin === "dbus" && holdsItem.senderFocused(root._withPid(rec, rt)),
            focusSuppress: !rule || rule.focusSuppress !== false,
            mute: !!(rule && rule.mute),
            drop: !!(rule && rule.drop === true),
            synchronous: sync,
            silent: !!snd.suppress || (rule && rule.sound ? rule.sound === "none" : snd.spec === "none")
        };
        const decision = Policy.decide(rec, ctx);
        // A fixed record is never filed (see the header): it is shown.
        if (rec.fixed === true && decision.toast === "file")
            return Object.assign({}, decision, { toast: "show", seen: false });
        return decision;
    }

    // A record built by post()/update(), new or a replace of `prev`.
    function _admit(rec, prev) {
        const rt = root._rt[rec.uid];
        const rule = Policy.ruleFor(root.config, rec);
        if (prev) {
            root._applyRule(rec, rule);
            root._replace(rec, prev, rule, rt);
            return;
        }
        const decision = root._decide(rec, rule, rt, false);
        if (decision.toast === "drop") {
            delete root._rt[rec.uid];
            root._unlinkKey(rec.uid);
            return;
        }
        root._place(rec, rule, rt, decision);
    }

    // First placement of a new record.
    function _place(rec, rule, rt, decision) {
        if (decision.seen)
            rec.seen = true;
        if (rec.live === true && decision.toast === "file") {      // filed (DND, a rule): hidden, in the manager
            rec.hidden = true;
            rec.group = Policy.groupOf(rec, rule);
        }
        storeItem.put(rec);
        root.recordAdded(rec.uid);
        root._toast(rec, rule, rt, decision);
        root._retain();
    }

    function _toast(rec, rule, rt, decision) {
        if (decision.toast === "show") {
            const ms = Policy.timeoutFor(rec, root.config, rule, rt.requestedMs);
            const got = sched.offer(rec.uid, rec, ms);
            if (got === "shown" && decision.sound)
                soundItem.play(rec, Object.assign({ rule: rule && rule.sound ? String(rule.sound) : "" }, rt.sound));
        } else if (decision.toast === "hold") {
            sched.hold(rec.uid);
            // A critical held at the lock still sounds (NotifyPolicy.decide):
            // the sound is the only thing that reaches the lock screen.
            if (decision.sound)
                soundItem.play(rec, Object.assign({ rule: rule && rule.sound ? String(rule.sound) : "" }, rt.sound));
        }
    }

    // The same record, new content: NotifyPolicy.retoast says what that means.
    function _replace(rec, prev, rule, rt) {
        // A hidden live record changes where it is, in the manager, and never toasts again (until unhidden).
        const mode = rec.live === true && rec.hidden === true ? "inplace" : Policy.retoast(prev, rec);
        if (mode === "retoast")
            rec.seen = rec.fixed === true || rec.live === true;
        storeItem.put(rec);
        if (mode !== "retoast")
            return;
        const shownNow = sched.shown.indexOf(rec.uid) >= 0;
        const decision = root._decide(rec, rule, rt, false);
        if (decision.seen)
            storeItem.patch(rec.uid, { seen: true });
        if (!shownNow && decision.toast !== "hold" && sched.held.indexOf(rec.uid) >= 0)
            sched.unshow(rec.uid);
        if (shownNow && decision.toast !== "show") {
            sched.unshow(rec.uid);
            if (decision.toast === "hold")
                sched.hold(rec.uid);
            else if (rec.live === true)
                root.hide(rec.uid);              // filed while on the lane: hidden, never in neither place
            return;
        }
        root._toast(rec, rule, rt, decision);
        if (rec.live === true && decision.toast === "file")
            root.hide(rec.uid);
    }

    // D-Bus: watch the change signals of one notification (a replace), and
    // its close.
    function _watch(n, uid) {
        const mark = () => root._markDirty(uid);
        n.summaryChanged.connect(mark);
        n.bodyChanged.connect(mark);
        n.hintsChanged.connect(mark);
        n.actionsChanged.connect(mark);
        n.imageChanged.connect(mark);
        n.urgencyChanged.connect(mark);
        n.appIconChanged.connect(mark);
        n.closed.connect(reason => root._serverClosed(uid, Number(reason)));
    }

    function _markDirty(uid) {
        root._dirty[uid] = true;
        Qt.callLater(root._flushDirty);
    }

    function _flushDirty() {
        const uids = Object.keys(root._dirty);
        root._dirty = ({});
        for (let i = 0; i < uids.length; i++) {
            const uid = uids[i];
            const prev = storeItem.get(uid);
            const rt = root._rt[uid];
            if (!prev || !rt || !rt.live)
                continue;
            const n = rt.live;
            rt.sound = root._soundHints(n.hints || {});
            rt.requestedMs = n.expireTimeout;
            rt.senderPid = Number((n.hints || {})["sender-pid"] || 0);
            const next = root._fromNotification(n, prev, uid, Date.now());
            const rule = Policy.ruleFor(root.config, next);
            root._applyRule(next, rule);
            root._replace(next, prev, rule, rt);
        }
    }

    // The server says the notification closed. CloseRequested is the app
    // withdrawing it; the others are our own dismiss / invoke / reply.
    function _serverClosed(uid, reason) {
        const rt = root._rt[uid];
        if (rt)
            rt.live = null;
        if (root._unstash(uid))
            return;
        const rec = storeItem.get(uid);
        if (!rec)
            return;
        sched.unshow(uid);
        if (rec.pinned) {
            storeItem.patch(uid, { closed: true });
            delete root._rt[uid];
            return;
        }
        root._finalRemove(uid, false);
    }

    // Gone for good: out of the store (image and all), off the bus.
    function _finalRemove(uid, dismissLive) {
        const rt = root._rt[uid];
        root._unlinkKey(uid);
        root._dropInteractionOf(uid);
        delete root._rt[uid];
        const d = storeItem.drop(uid);
        if (dismissLive && rt && rt.live)
            rt.live.dismiss();
        if (d)
            root.recordRemoved(uid);
    }

    // A clear's `uids` as strings; `[]` names no record, so the clear takes
    // nothing. null when `uids` is not an array (left out): the clear takes
    // every record it would take without a filter.
    function _only(uids) {
        return Array.isArray(uids) ? uids.map(u => String(u)) : null;
    }

    // Take records out for an undo window; `kind` "all" | "group" (and the
    // group) is what the offer says. Nothing to take: a token for nothing,
    // and the offer on show stays.
    function _stash(records, kind, group) {
        const now = Date.now();
        const token = "u" + (++root._tokSeq) + "-" + now;
        if (records.length === 0)
            return token;
        const until = now + (root.config.undoMs > 0 ? root.config.undoMs : 10000);
        for (let i = 0; i < records.length; i++) {
            sched.unshow(records[i].uid);
            storeItem.drop(records[i].uid, true);
            root.recordRemoved(records[i].uid);
        }
        const all = Object.assign({}, root._undo);
        all[token] = { records: records, until: until };
        root._undo = all;
        root._undoState = { token: token, kind: kind === "group" ? "group" : "all", group: kind === "group" ? group : "",
                            startedMs: now, deadlineMs: until, totalMs: until - now };
        root._armUndo();
        return token;
    }

    // The window `token` closed (taken, expired, emptied): if it is the one
    // on offer, nothing is.
    function _offerEnded(token) {
        if (root._undoState && root._undoState.token === token)
            root._undoState = null;
    }

    function _inStash(uid) {
        const toks = Object.keys(root._undo);
        for (let i = 0; i < toks.length; i++)
            if (root._undo[toks[i]].records.some(r => r.uid === uid))
                return true;
        return false;
    }

    // A stashed record the app or the source withdrew: it is not coming back.
    function _unstash(uid) {
        const toks = Object.keys(root._undo);
        for (let i = 0; i < toks.length; i++) {
            const u = root._undo[toks[i]];
            const at = u.records.findIndex(r => r.uid === uid);
            if (at < 0)
                continue;
            const r = u.records[at];
            u.records.splice(at, 1);
            // Nothing left to restore: the window closes with its last record.
            if (u.records.length === 0) {
                const all = Object.assign({}, root._undo);
                delete all[toks[i]];
                root._undo = all;
                root._offerEnded(toks[i]);
                root._armUndo();
            }
            const rt = root._rt[uid];
            root._unlinkKey(uid);
            delete root._rt[uid];
            if (rt && rt.live)
                rt.live.dismiss();
            storeItem.deleteImage(r);
            return true;
        }
        return false;
    }

    function _armUndo() {
        undoTimer.stop();
        let next = -1;
        const toks = Object.keys(root._undo);
        for (let i = 0; i < toks.length; i++)
            if (next < 0 || root._undo[toks[i]].until < next)
                next = root._undo[toks[i]].until;
        if (next < 0)
            return;
        undoTimer.interval = Math.max(1, next - Date.now());
        undoTimer.start();
    }

    function _expireUndo() {
        const now = Date.now();
        const all = Object.assign({}, root._undo);
        const gone = [];
        const toks = Object.keys(all);
        for (let i = 0; i < toks.length; i++) {
            if (all[toks[i]].until > now)
                continue;
            gone.push.apply(gone, all[toks[i]].records);
            delete all[toks[i]];
            root._offerEnded(toks[i]);
        }
        // The window is closed BEFORE anything is dismissed: a dismiss closes
        // synchronously, and the close handler must not find them stashed.
        root._undo = all;
        for (let j = 0; j < gone.length; j++) {
            const r = gone[j];
            const rt = root._rt[r.uid];
            root._unlinkKey(r.uid);
            delete root._rt[r.uid];
            if (rt && rt.live)
                rt.live.dismiss();
            storeItem.deleteImage(r);
        }
        root._armUndo();
    }

    // History limits: count and age; pins, toasts and held records exempt.
    function _retain() {
        const recs = storeItem.all();
        const prot = sched.shown.concat(sched.held, recs.filter(r => r.kept === true).map(r => r.uid));
        const r = Policy.retain(recs, Date.now(), root.config, prot);
        for (let i = 0; i < r.drop.length; i++) {
            sched.unshow(r.drop[i].uid);
            root._finalRemove(r.drop[i].uid, true);
        }
        root._armAgeOut();
    }

    function _armAgeOut() {
        ageTimer.stop();
        const days = root.config.retention && typeof root.config.retention.days === "number" ? root.config.retention.days : 7;
        if (days < 0)
            return;
        // Age counts from the last update (NotifyPolicy.retain).
        const recs = storeItem.all();
        let oldest = -1;
        for (let i = 0; i < recs.length; i++) {
            const t = recs[i].updatedMs || recs[i].arrivedMs;
            if (!recs[i].pinned && recs[i].kept !== true && (oldest < 0 || t < oldest))
                oldest = t;
        }
        if (oldest < 0)
            return;
        const at = oldest + days * 86400000 + 1000;
        ageTimer.interval = Math.max(1000, Math.min(86400000, at - Date.now()));
        ageTimer.start();
    }

    // A notification carried over a reload (keepOnReload): the record it was
    // is in history.json as stale; make it live again, quietly.
    function _relink(n) {
        const recs = storeItem.all();
        let best = null;
        for (let i = 0; i < recs.length; i++) {
            const r = recs[i];
            if (r.origin === "dbus" && r.serverId === Number(n.id) && r.stale && (!best || r.arrivedMs > best.arrivedMs))
                best = r;
        }
        if (!best)
            return "";
        const hints = n.hints || {};
        n.tracked = true;
        root._rt[best.uid] = {
            live: n, source: "", key: "", onAction: null, onDefault: null, runs: {}, defaultId: "",
            bodyComponent: null, bodyProps: null, sound: root._soundHints(hints),
            breakDnd: false, requestedMs: n.expireTimeout, senderPid: Number(hints["sender-pid"] || 0)
        };
        root._watch(n, best.uid);
        storeItem.patch(best.uid, { stale: false, closed: false });
        return best.uid;
    }

    // The hold changed: what it kept back comes out (NotifyPolicy.heldRelease)
    // when it ends; a lock that turns into a share lets its criticals out.
    function _holdChanged() {
        const was = root._lastReason;
        const now = holdsItem.reason;
        root._lastReason = now;
        if (was === now)
            return;
        if (was === "") {
            // A fullscreen window begins over toasts already out: the ones that are not critical go the way every other non-critical
            // one goes while it lasts -- held, and told in the summary when it ends (a non-critical toast
            // that is up when fullscreen begins would be "carried over" into the fullscreen pill, which shows criticals only).
            if (now === "fullscreen")
                root._holdShown();
            return;
        }
        if (now !== "") {
            if (was === "locked") {
                const keep = [];
                const held = sched.takeHeld();
                for (let i = 0; i < held.length; i++) {
                    const rec = storeItem.get(held[i]);
                    if (!rec)
                        continue;
                    if (rec.urgency === "critical" || rec.fixed === true)      // _decide holds it again if it must wait
                        root._reshow(rec);
                    else
                        keep.push(held[i]);
                }
                for (let i = 0; i < keep.length; i++)
                    sched.hold(keep[i]);
            }
            return;
        }
        const recs = sched.takeHeld().map(u => storeItem.get(u)).filter(r => !!r);
        const out = Policy.heldRelease(recs, was);
        for (let i = 0; i < out.individual.length; i++) {
            const rec = storeItem.get(out.individual[i]);
            if (rec)
                root._reshow(rec);
        }
        // A fixed record is not summarised into the digest: dropped.
        for (let i = 0; i < recs.length; i++)
            if (recs[i].fixed === true && out.individual.indexOf(recs[i].uid) < 0)
                root._finalRemove(recs[i].uid, true);
        if (out.summary && root.config.dnd.summary)
            root._postSummary(out.summary, recs.filter(r => out.individual.indexOf(r.uid) < 0 && r.fixed !== true));
    }

    // Take the stack's non-critical toasts out of it and hold them (a fixed one is live UI, not a notification: it stays).
    function _holdShown() {
        const out = sched.shown.slice();
        for (let i = 0; i < out.length; i++) {
            const rec = storeItem.get(out[i]);
            if (!rec || rec.urgency === "critical" || rec.fixed === true)
                continue;
            sched.unshow(out[i]);
            sched.hold(out[i]);
        }
    }

    function _reshow(rec) {
        const rt = root._rt[rec.uid] || { breakDnd: false, sound: {}, requestedMs: undefined, defaultId: "" };
        const rule = Policy.ruleFor(root.config, rec);
        const decision = root._decide(Object.assign({}, rec), rule, rt, false);
        root._toast(rec, rule, rt, decision);
    }

    function _postSummary(summary, recs) {
        const why = summary.reason === "locked" ? "while the screen was locked"
            : summary.reason === "screencast" ? "while the screen was shared"
            : summary.reason === "fullscreen" ? "while in fullscreen"
            : summary.reason === "app" ? "while you were busy" : "while you were away";
        const apps = [];
        for (let i = 0; i < recs.length; i++)
            if (apps.indexOf(recs[i].appName) < 0 && recs[i].appName)
                apps.push(recs[i].appName);
        const open = () => root.openManagerRequested(holdsItem.focusedScreen);
        root.post({
            source: "notifications", key: "held", appName: "Notifications",
            title: summary.count + (summary.count === 1 ? " notification " : " notifications ") + why,
            body: apps.join(", "),
            urgency: "normal", persist: false,
            actions: [{ id: "open", label: "Open" }],
            onAction: open, onDefault: open
        });
    }

    function _dotGroup() {
        void root.serial;
        return Policy.dotGroup(storeItem.all(), st.lastOpenedMs);
    }

    function _unseen() {
        void root.serial;
        const recs = storeItem.all();
        let n = 0;
        for (let i = 0; i < recs.length; i++)
            if (!recs[i].seen)
                n++;
        return n;
    }

    Component {
        id: measureComp
        Image {
            visible: false
            asynchronous: false
        }
    }

    NotificationConfig {
        id: cfg
        configPath: root.configPath
    }
    NotificationState {
        id: st
        persist: root.persist
        statePath: root.statePath
    }
    NotificationStore {
        id: storeItem
        persist: root.persist
        historyPath: root.historyPath
        persistFilter: r => {
            const rule = Policy.ruleFor(root.config, r);
            return !rule || rule.history !== false;
        }
    }
    NotificationHolds {
        id: holdsItem
        liveSignals: root.liveSignals
        livePipewire: root.livePipewire
        focusSource: root.focusSource
        config: root.config
        onReasonChanged: root._holdChanged()
    }
    // A theme switch's line is running: the toasts' clocks stand still (ToastScheduler.curtain).
    property bool curtainHold: false
    ToastScheduler {
        id: sched
        config: root.config
        idle: holdsItem.idle
        sleepWatcher: root.sleepWatcher
        unplaced: root._waitingForScreen
        curtain: root.curtainHold
        onGrew: root._seatLane()
    }
    // The screen the stack stands on was not known when it grew (the first turns after a start): it
    // is the one it comes on as soon as that is known. A known screen never moves here (ONE stack stays
    // where it grew; a new arrival moves it, `onGrew`) -- but for the display the config names: the stack
    // goes when that one goes, and back when it is back.
    Connections {
        target: holdsItem
        function onLaneChanged() {
            if (root._laneScreen === "" || root._laneNamed !== holdsItem.laneNamed)
                root._seatLane();
        }
    }
    property bool _laneNamed: false
    function _seatLane() {
        root._laneNamed = holdsItem.laneNamed;
        root._laneScreen = holdsItem.lane;
    }
    NotificationSound {
        id: soundItem
        config: root.config
        dnd: st.dnd
    }

    Connections {
        target: cfg
        function onSerialChanged() {
            root._retain();
            root._takeHours();
        }
    }

    // ---- QUIET HOURS (dnd.hours) --------------------------------------------
    // Do-not-disturb is SWITCHED at each start and end (DayTimes: wall instants), by one timer re-armed; between two it is the user's, and the
    // switch by hand stands until the next one -- over a restart too (`hoursAt` remembers which one was followed), and one that passed in a
    // sleep or while the shell was down is followed at once. Hours that are edited switch it only when they change the clock's answer for now.
    property var _hours: []
    function _followHours() {
        const now = Date.now();
        const last = DayTimes.last(root._hours, now);
        if (last && last.at > st.hoursAt) {
            st.hoursAt = last.at;
            st.dnd = last.on;
        }
        const next = DayTimes.next(root._hours, now);
        hoursTimer.stop();
        if (next < 0)
            return;
        hoursTimer.interval = Math.max(50, Math.min(3600000, next - now));
        hoursTimer.start();
    }
    function _takeHours() {
        const hours = root.config.dnd.hours;
        if (!root._ready || JSON.stringify(hours) === JSON.stringify(root._hours))
            return;
        const now = Date.now();
        const on = DayTimes.inside(hours, now);
        if (on !== DayTimes.inside(root._hours, now))
            st.dnd = on;
        root._hours = hours;
        const last = DayTimes.last(hours, now);
        st.hoursAt = last ? last.at : 0;
        root._followHours();
    }
    Timer {
        id: hoursTimer
        onTriggered: root._followHours()
    }
    // A fixed record whose toast ended on its own is dropped, not filed.
    Connections {
        target: sched
        function onExpired(uid: string) { root._endFixed(uid); }
        function onOverflowed(uid: string) { root._endFixed(uid); }
    }
    // The undo window and the age-out are wall deadlines on monotonic timers:
    // after a suspend, re-armed from the wall (an undo whose time ran out in
    // the sleep closes now, as its drain already shows).
    Connections {
        target: root.sleepWatcher
        ignoreUnknownSignals: true
        function onResumed() {
            root._armUndo();
            root._retain();
            root._followHours();
        }
    }

    onManagerOpenChanged: {
        if (!root.managerOpen)
            return;
        // Opening the manager files every toast -- except a fixed one, which is
        // taken off the lane and put straight back (see the header).
        const keepShown = sched.shown.filter(u => root._isFixed(u) || root._liveOnLane(u));
        const keepHeld = sched.held.filter(u => root._isFixed(u) || root._liveOnLane(u));
        sched.clear();
        for (let i = keepShown.length - 1; i >= 0; i--) {
            const rec = storeItem.get(keepShown[i]);
            const rt = root._rt[keepShown[i]];
            if (rec && rt)
                root._toast(rec, Policy.ruleFor(root.config, rec), rt, { toast: "show", sound: false });
        }
        for (let i = 0; i < keepHeld.length; i++)
            sched.hold(keepHeld[i]);
    }

    Timer {
        id: undoTimer
        repeat: false
        onTriggered: root._expireUndo()
    }
    Timer {
        id: ageTimer
        repeat: false
        onTriggered: root._retain()
    }

    LazyLoader {
        id: bridge
        active: root.serverEnabled && root._ready
        component: NotificationServerBridge {
            service: root
        }
    }
    LazyLoader {
        active: root.ipcEnabled && root._ready
        component: NotificationsIpc {
            service: root
        }
    }

    Component.onCompleted: {
        // onCompleted order is not defined: the config and the history must
        // be read before the first decision or retention pass, or a config
        // with a larger retention count would lose records to the default.
        cfg.ensureLoaded();
        storeItem.ensureLoaded();
        root._relinkKeys();
        root._lastReason = holdsItem.reason;
        root._seatLane();
        st.ensureLoaded();
        if (!root.config.dnd.remember) {
            st.dnd = false;
            st.hoursAt = 0;
        }
        root._hours = root.config.dnd.hours;
        root._followHours();
        if (root.registerOnBus)
            NotificationBus.service = root;
        root._ready = true;
        root._retain();
    }
    Component.onDestruction: {
        if (NotificationBus.service === root)
            NotificationBus.service = null;
    }
}
