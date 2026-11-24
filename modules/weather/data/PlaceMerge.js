.pragma library

// =============================================================================
// PlaceMerge.js -- one place once in the list the location link cycles (feedback/weather.md, "Filter out duplicate
// locations"): the entry written in weather.jsonc and the current location are one place when the current location
// -- with no geoclue fix, or a fix inside it -- IS that municipality ("Mechelen" would be listed twice).
//
//   normName(name)               a municipality's name as two spellings of it compare: lower case, no diacritics, no
//                                "(mock)" / "(fixture)" tag, no ", BE" country tail, words joined by one space
//   mergeIndex(slotName, saved)  the index in `saved` ([{ name, lat, lon }]) of the first entry with the same municipality
//                                as the current-location slot, or -1. An entry without coordinates is not a place yet
//                                (a query still resolving) and never merges.
//
// The slot's name is what the user would read there: the fix's name (a saved place it is near, else KMI's municipality,
// else "lat, lon") with a fix, the hometown's name without. WeatherService keeps the CONFIGURED entry, in the slot's
// place at the head of the list, marked "here" when a fix says so -- never the live one: the config is the user's.
// Pure, no Qt.
// =============================================================================

function normName(name) {
    return String(name === undefined || name === null ? "" : name)
        .normalize("NFD").replace(/[\u0300-\u036f]/g, "")
        .toLowerCase()
        .replace(/\([^)]*\)/g, " ")
        .replace(/,\s*[a-z]{2}\s*$/, " ")
        .replace(/[^a-z0-9]+/g, " ")
        .trim();
}

function mergeIndex(slotName, saved) {
    const n = normName(slotName);
    if (n === "" || !Array.isArray(saved))
        return -1;
    for (let i = 0; i < saved.length; i++) {
        const l = saved[i];
        if (!l || typeof l.lat !== "number" || typeof l.lon !== "number")
            continue;
        if (normName(l.name) === n)
            return i;
    }
    return -1;
}
