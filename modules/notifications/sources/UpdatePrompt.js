.pragma library

// =============================================================================
// UpdatePrompt.js -- what yay or pacman is asking, from the card's point of view.
//
// The update popup decides this in its own QML (SystemUpdatePopup `_promptKind`, `_promptTitle`,
// `_yesNoDefault`): the parser's kind, a backstop from the PHASE (the parser closes a prompt as
// soon as any other line arrives, and the question is still there), and the terminal's own tail
// heuristic for a "[Y/n]" that has no newline yet. The popup is not there when a card has to ask, so
// the same decision lives here, pure and tested; the table of titles is the popup's, word for word
// ("the prompt's own words").
//
//   classify(input)   -> null | { kind, title, yesno, def }
//   answer(kind, yes) -> the text to submit
//
// A sudo password is NOT a question of this kind: the update's sudo asks through the authentication
// toast (AskpassSource), never on the terminal. `passwordPrompt` makes the whole thing null.
//
// input: { parserKind, parserText, parserDefault, phase, answeredPhase, running,
//          backendAwaiting, backendPassword, backendLastPrompt }
// =============================================================================

// A PROMPT_* phase back to its kind (the popup's `_phasePromptKinds`).
var PHASE_KINDS = {
    PROMPT_EXCLUDE: "yay_exclude",
    PROMPT_CLEANBUILD: "yay_cleanbuild",
    PROMPT_DIFFS: "yay_diffs",
    PROMPT_EDIT_PKGBUILD: "yay_edit_pkgbuild"
};

// The kinds a Yes and a No answer: nothing else is a card's to answer (a list of packages, a diff,
// an editor are the popup's).
var YESNO = { pacman_proceed: true, yay_skip_dep: true, yay_yesno: true };

var TITLES = {
    pacman_proceed: "Proceed with installation?",
    yay_exclude: "Packages to exclude",
    yay_cleanbuild: "Packages to cleanBuild?",
    yay_diffs: "Diffs to show?",
    yay_edit_pkgbuild: "PKGBUILDs to edit?",
    yay_skip_dep: "Do you want to skip the above package for this upgrade?"
};

function _tailKind(lastPrompt) {
    var lp = String(lastPrompt || "");
    if (!/\[[yY]\/[nN]\]/.test(lp))
        return "";
    if (/Proceed with install/i.test(lp))
        return "pacman_proceed";
    if (/skip the above package/i.test(lp))
        return "yay_skip_dep";
    return "yay_yesno";
}

// "Remove make dependencies after install? [y/N]" -> "Remove make dependencies after install": the
// words of the question without yay's marks (the popup's `_yesNoTail`).
function _tailQuestion(lastPrompt) {
    return String(lastPrompt || "")
        .replace(/\s+$/, "")
        .replace(/\s*[yYnN]$/, "")
        .replace(/\s*\[[yY]\/[nN]\]\s*$/, "")
        .replace(/^\s*(?:::|==>|->)\s*/, "")
        .replace(/\?\s*$/, "")
        .trim();
}

function _tailDefault(lastPrompt) {
    var m = String(lastPrompt || "").match(/\[([yY])\/([nN])\]/);
    if (!m)
        return "";
    return m[1] === "Y" ? "Y" : (m[2] === "N" ? "N" : "");
}

function classify(inp) {
    var i = inp || {};
    if (i.backendPassword === true)
        return null;
    var kind = String(i.parserKind || "");
    if (kind === "" && i.running === true && i.phase !== i.answeredPhase && PHASE_KINDS[i.phase])
        kind = PHASE_KINDS[i.phase];
    if (kind === "" && i.backendAwaiting === true)
        kind = _tailKind(i.backendLastPrompt);
    if (kind === "")
        return null;
    var text = String(i.parserText || "");
    var question = text !== "" ? text : _tailQuestion(i.backendLastPrompt);
    var title = TITLES[kind];
    if (title === undefined)
        title = question !== "" ? question + "?" : "";
    var def = String(i.parserDefault || "");
    if (def === "")
        def = _tailDefault(i.backendLastPrompt);
    return { kind: kind, title: title, yesno: YESNO[kind] === true, def: def };
}

function answer(kind, yes) {
    return yes ? "y" : "n";
}
