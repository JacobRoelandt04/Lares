"""What happens at the start of a session: nothing, a restore by itself, or an ask.

Pure: `decide(prev, now, snap, cfg)` -> {"decision", "cause", "clean"}.

  prev   the previous session's record (state.py) or None
  now    {"bootId", "time", "safeMode", "crashReport": time | None}
  snap   the candidate snapshot's {"time", "windows": n} or None

| previous session                                             | decision                                   |
|--------------------------------------------------------------|--------------------------------------------|
| this one runs in Hyprland's safe mode                        | none (nothing is touched)                  |
| no snapshot, no windows in it, or older than maxAgeHours     | none                                       |
| a restore was running, or ended < 60 s before an unclean end | ask-critical ("the last restore ...")      |
| did not end (crash, kill, power loss)                        | ask-critical; every command only typed     |
| ended "logout", same boot                                    | afterLogout  (ask)                         |
| ended "reboot" / "poweroff" / "system", or another boot      | afterReboot  (ask)                         |

afterLogout / afterReboot: "ask" (a toast of normal urgency that stays until answered), "ask-critical" (the same toast,
critical), "auto" (restored by itself), "off". After a clean end either ask is `clean`: a restore may RUN commands by
itself (classify.py rule 1); only an unclean end makes every command typed.
Cases: tools/dev/session_policy_cases.json (python3 tools/dev/session_cases.py).
"""
import datetime
import time

SUSPECT_S = 60


def _hm(t):
    return time.strftime("%H:%M", time.localtime(t))


_DAYS = ("Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun")
_MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")


def _at(t, now_t):
    """'at 18:42' for today; 'yesterday at 18:42', 'Tue at 18:42' (within the
    last week) or '12 Nov at 18:42' otherwise. Days are calendar days of the
    local zone, counted from `now_t` (the case tables pin it)."""
    a, b = time.localtime(t), time.localtime(now_t)
    back = (datetime.date(b.tm_year, b.tm_mon, b.tm_mday) - datetime.date(a.tm_year, a.tm_mon, a.tm_mday)).days
    if back <= 0:
        day = ""
    elif back == 1:
        day = "yesterday "
    elif back < 7:
        day = _DAYS[a.tm_wday] + " "
    else:
        day = "%d %s " % (a.tm_mday, _MONTHS[a.tm_mon - 1])
    return "%sat %s" % (day, _hm(t))


def decide(prev, now, snap, cfg):
    none = {"decision": "none", "cause": "", "clean": True}
    if now.get("safeMode"):
        return dict(none, cause="safe mode")
    if not prev:
        return dict(none, cause="no previous session")
    if not snap or not snap.get("windows"):
        return dict(none, cause="nothing was saved")
    age_h = (now["time"] - snap.get("time", 0)) / 3600.0
    if cfg.get("maxAgeHours") and age_h > cfg["maxAgeHours"]:
        return dict(none, cause="the saved session is %d hours old" % age_h)

    ended = prev.get("ended")
    clean_end = ended in ("logout", "reboot", "poweroff", "system")
    restoring = prev.get("restoring")
    if restoring and not clean_end:
        done = restoring.get("done")
        last = prev.get("lastSeen") or snap.get("time", 0)
        if done is None or last - done < SUSPECT_S:
            if cfg.get("afterCrash") == "off":
                return dict(none, cause="the last restore ended in a crash")
            return {"decision": "ask-critical", "clean": False,
                    "cause": "The last restore of this session ended in a crash"}

    if not clean_end:
        if cfg.get("afterCrash") == "off":
            return dict(none, cause="the last session did not end cleanly")
        if now.get("crashReport"):
            cause = "Hyprland crashed %s" % _at(now["crashReport"], now["time"])
        else:
            cause = "The last session ended without a log-out"
        return {"decision": "ask-critical", "cause": cause, "clean": False}

    same_boot = bool(prev.get("bootId")) and prev.get("bootId") == now.get("bootId")
    if ended == "logout" and same_boot:
        mode = cfg.get("afterLogout", "ask")
        cause = "Logged out %s" % _at(prev.get("endedAt") or snap.get("time", 0), now["time"])
    else:
        mode = cfg.get("afterReboot", "ask")
        words = {"reboot": "Restarted", "poweroff": "Powered off", "system": "Shut down", "logout": "Logged out"}
        word = words[prev.get("endedHow")] if ended == "system" and prev.get("endedHow") in ("reboot", "poweroff") else words[ended]
        cause = "%s %s" % (word, _at(prev.get("endedAt") or snap.get("time", 0), now["time"]))
    if mode not in ("auto", "ask", "ask-critical"):
        return dict(none, cause=cause)
    return {"decision": mode, "cause": cause, "clean": True}
