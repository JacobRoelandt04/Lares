.pragma library

// =============================================================================
// ical.js — Minimal RFC 5545 tokenizer
//
// parseIcs(text) -> {
//   calendar: { prodId, version, calName, calDesc, timezone, refreshInterval },
//   events:   [ {
//       uid, summary, description, location,
//       dtstart: { value: Date, tzid, isDate, raw },   // isDate = all-day
//       dtend:   { value: Date, tzid, isDate, raw },   // may be null
//       rrule:   { freq, interval, count, until, byday, bymonth, bymonthday }
//                | null,
//       exdates: [ Date, ... ],
//       sequence, status, rawBlock
//   }, ... ],
//   timezones: { [tzid]: { tzid, standardOffset, daylightOffset, ... } }
// }
//
// Known limitations (v1, intentional):
//   - TZID-to-local conversion: if TZID matches the system timezone name the
//     values land in local time naturally (we parse the components as local).
//     When TZID differs from system tz the time may be wrong. For Proton
//     calendars this is fine because DTSTART is always in the user's tz.
//   - VTIMEZONE block is captured but not used for cross-tz conversion.
//   - BYSETPOS / BYYEARDAY / BYWEEKNO recurrence rules are parsed into the
//     rrule object but rrule.js ignores them.
// =============================================================================

// ---------- Line unfolding + tokenising ----------

function _unfold(text) {
    // RFC 5545: lines wrapped at 75 octets may continue on next line with a
    // single leading space or tab. Join those back before parsing.
    let lines = text.replace(/\r\n/g, "\n").split("\n");
    let out = [];
    for (let i = 0; i < lines.length; i++) {
        let l = lines[i];
        if (l.length === 0) continue;
        if ((l[0] === " " || l[0] === "\t") && out.length > 0) {
            out[out.length - 1] += l.slice(1);
        } else {
            out.push(l);
        }
    }
    return out;
}

function _parseLine(line) {
    // Split at first unquoted ":" → "NAME;params" vs "value".
    let colonIdx = -1;
    let inQuotes = false;
    for (let i = 0; i < line.length; i++) {
        let c = line[i];
        if (c === '"') inQuotes = !inQuotes;
        else if (c === ':' && !inQuotes) { colonIdx = i; break; }
    }
    if (colonIdx < 0) return { name: line, params: {}, value: "" };

    let left = line.slice(0, colonIdx);
    let value = line.slice(colonIdx + 1);

    // Split left on unquoted ';' → "NAME" ; param1=x ; param2="y;z"
    let parts = [];
    let start = 0;
    inQuotes = false;
    for (let i = 0; i < left.length; i++) {
        let c = left[i];
        if (c === '"') inQuotes = !inQuotes;
        else if (c === ';' && !inQuotes) {
            parts.push(left.slice(start, i));
            start = i + 1;
        }
    }
    parts.push(left.slice(start));

    let name = parts[0].toUpperCase();
    let params = {};
    for (let i = 1; i < parts.length; i++) {
        let p = parts[i];
        let eq = p.indexOf('=');
        if (eq < 0) continue;
        let pname = p.slice(0, eq).toUpperCase();
        let pval = p.slice(eq + 1);
        // Strip surrounding quotes
        if (pval.length >= 2 && pval[0] === '"' && pval[pval.length-1] === '"')
            pval = pval.slice(1, -1);
        params[pname] = pval;
    }
    return { name: name, params: params, value: value };
}

// ---------- Date / datetime parsing ----------

function _parseIcsDate(value, params) {
    // Shapes:
    //   "YYYYMMDD"                 -> all-day (DATE value)
    //   "YYYYMMDDTHHMMSS"          -> floating / TZID-qualified local time
    //   "YYYYMMDDTHHMMSSZ"         -> UTC
    //   Params may include VALUE=DATE or TZID=<zone>.
    let isDate = params.VALUE === "DATE"
              || (value.length === 8 && !value.includes("T"));
    let tzid = params.TZID || null;

    let y = parseInt(value.slice(0, 4), 10);
    let mo = parseInt(value.slice(4, 6), 10) - 1;
    let d = parseInt(value.slice(6, 8), 10);

    if (isDate) {
        return { value: new Date(y, mo, d, 0, 0, 0, 0), tzid, isDate: true, raw: value };
    }

    let h = parseInt(value.slice(9, 11), 10);
    let mi = parseInt(value.slice(11, 13), 10);
    let s = parseInt(value.slice(13, 15), 10) || 0;
    let isUtc = value.endsWith("Z");

    let dt = isUtc
        ? new Date(Date.UTC(y, mo, d, h, mi, s))
        : new Date(y, mo, d, h, mi, s);  // local-time interpretation

    return { value: dt, tzid, isDate: false, raw: value };
}

function _parseRRule(str) {
    // FREQ=WEEKLY;INTERVAL=2;BYDAY=MO,WE,FR;COUNT=10;UNTIL=20260601T000000Z
    let out = {};
    let parts = str.split(";");
    for (let i = 0; i < parts.length; i++) {
        let kv = parts[i].split("=");
        if (kv.length !== 2) continue;
        let k = kv[0].toUpperCase();
        let v = kv[1];
        if (k === "INTERVAL" || k === "COUNT" || k === "BYSETPOS"
            || k === "BYMONTH" || k === "BYMONTHDAY" || k === "BYYEARDAY"
            || k === "BYWEEKNO") {
            out[k.toLowerCase()] = parseInt(v, 10);
        } else if (k === "BYDAY") {
            // Each token: optional signed prefix + 2-letter day (MO,TU,...)
            out.byday = v.split(",").map(function(t) {
                let m = /^(-?\d+)?([A-Z]{2})$/.exec(t);
                if (!m) return null;
                return { offset: m[1] ? parseInt(m[1], 10) : 0, day: m[2] };
            }).filter(function(x) { return !!x; });
        } else if (k === "UNTIL") {
            out.until = _parseIcsDate(v, {}).value;
        } else {
            out[k.toLowerCase()] = v;
        }
    }
    return out;
}

function _unescape(s) {
    if (!s) return s;
    return s.replace(/\\n/g, "\n")
            .replace(/\\,/g, ",")
            .replace(/\\;/g, ";")
            .replace(/\\\\/g, "\\");
}

// ---------- Top-level parse ----------

function parseIcs(text) {
    let lines = _unfold(text);
    let calendar = {};
    let events = [];
    let timezones = {};

    let stack = [];   // block-name stack: VCALENDAR, VEVENT, VTIMEZONE, ...
    let current = null;
    let rawBlockLines = [];

    for (let i = 0; i < lines.length; i++) {
        let line = lines[i];
        let parsed = _parseLine(line);

        if (parsed.name === "BEGIN") {
            stack.push(parsed.value.toUpperCase());
            let block = parsed.value.toUpperCase();
            if (block === "VEVENT") {
                current = { exdates: [], rawBlockLines: [] };
                rawBlockLines = [];
            } else if (block === "VTIMEZONE") {
                current = { tzid: null, children: [] };
            }
            continue;
        }

        if (parsed.name === "END") {
            let block = parsed.value.toUpperCase();
            if (block === "VEVENT" && current) {
                current.rawBlock = rawBlockLines.join("\n");
                events.push(current);
                current = null;
            } else if (block === "VTIMEZONE" && current && current.tzid) {
                timezones[current.tzid] = current;
                current = null;
            }
            stack.pop();
            continue;
        }

        let ctx = stack[stack.length - 1];

        if (ctx === "VCALENDAR" && !current) {
            switch (parsed.name) {
                case "PRODID":  calendar.prodId = parsed.value; break;
                case "VERSION": calendar.version = parsed.value; break;
                case "X-WR-CALNAME":  calendar.calName = parsed.value; break;
                case "X-WR-CALDESC":  calendar.calDesc = parsed.value; break;
                case "X-WR-TIMEZONE": calendar.timezone = parsed.value; break;
                case "REFRESH-INTERVAL":
                case "X-PUBLISHED-TTL":
                    calendar.refreshInterval = parsed.value; break;
            }
            continue;
        }

        if (ctx === "VTIMEZONE" && current) {
            if (parsed.name === "TZID") current.tzid = parsed.value;
            current.children.push(parsed);
            continue;
        }

        if (ctx === "VEVENT" && current) {
            rawBlockLines.push(line);
            switch (parsed.name) {
                case "UID":         current.uid         = parsed.value; break;
                case "SUMMARY":     current.summary     = _unescape(parsed.value); break;
                case "DESCRIPTION": current.description = _unescape(parsed.value); break;
                case "LOCATION":    current.location    = _unescape(parsed.value); break;
                case "DTSTART":     current.dtstart     = _parseIcsDate(parsed.value, parsed.params); break;
                case "DTEND":       current.dtend       = _parseIcsDate(parsed.value, parsed.params); break;
                case "RRULE":       current.rrule       = _parseRRule(parsed.value); break;
                case "EXDATE": {
                    // EXDATE may contain comma-separated list.
                    let tokens = parsed.value.split(",");
                    for (let j = 0; j < tokens.length; j++) {
                        let pd = _parseIcsDate(tokens[j], parsed.params);
                        if (pd && pd.value) current.exdates.push(pd.value);
                    }
                    break;
                }
                case "SEQUENCE":    current.sequence    = parseInt(parsed.value, 10); break;
                case "STATUS":      current.status      = parsed.value; break;
            }
            continue;
        }
    }

    return { calendar: calendar, events: events, timezones: timezones };
}
