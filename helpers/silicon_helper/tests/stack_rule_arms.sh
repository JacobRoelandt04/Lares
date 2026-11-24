#!/usr/bin/env bash
# The ARMs of the helper's MUX safety rules. A test that cannot fail proves nothing, so this runs the crate's whole
# suite on a PRIVATE COPY of the crate (never the tree it lives in), first as it is, then with one rule broken at a
# time, and requires the right tests to go red each time.
#
#   (none)       every test is green                                          -- the baseline
#
#   the stack rule (src/mux.rs `needs_stack_down`: only the switch TO dGPU-only waits for the NVIDIA stack)
#   extend       the waiver extended to the dGPU direction (nobody waits)      -- a dGPU switch would be written with
#                                                                                the stack up: its refusal tests fail
#   remove       the waiver removed (everybody waits: the old rule)            -- the way back would be refused with
#                                                                                the stack up: its tests fail
#   silent       the driver note dropped from the way back's record            -- the "written with the driver still
#                                                                                loaded" tests fail
#
#   the guard (src/mux.rs `withdraw_toward`: only ever hybrid is put back at boot)
#   withdraw     the symmetric withdrawal back: a way back that did not take    -- the guard would write the dGPU value
#                writes dGPU-only into the firmware                               at boot: its tests fail
#
#   the NVIDIA driver (src/machine.rs `discover_for_write`, src/cli.rs `finish`: nothing that writes reads
#   /proc/driver/nvidia/...; the fixture makes that entry a FIFO nobody writes, so a read of it blocks for good)
#   nvidiaread   the write paths read it again                                  -- the way back, the revert, the guard's
#                                                                                withdrawal and systemd's other commands
#                                                                                hang: their tests fail
#   nvidiaanswer systemd's own answers read it again                            -- the way back's answer hangs after the
#                                                                                write: its test fails
#
#   the unit (src/gpu.rs `mux_unit_check`: a request is refused while silicon-mux.service is not active)
#   unitcheck    the unit is always taken for active                            -- the refusal tests fail
#   unitblind    a systemd that exports no invocation link at all is taken for   -- the fail-open tests fail
#                "the unit is not active"
#
#   helpers/silicon_helper/tests/stack_rule_arms.sh                run all
#   ARM=withdraw helpers/silicon_helper/tests/stack_rule_arms.sh   one ARM (the baseline runs first anyway)
#   SANDBOX=/tmp/lares-sandbox-silicon-w5 ...                         where the copy lives (default below)
#   BREAK=1 ...                                                    a syntax error put into the copy: the run must
#                                                                  end on "RESULT FAIL (no result: <log>)", exit 1
#
# Nothing here touches the machine: cargo test runs the helper in TEST MODE against fixture trees under /tmp,
# as an ordinary user (the helper refuses test mode as root). Ends with ONE line: SILICON_HELPER_STACKRULE
# RESULT PASS|FAIL (no result = FAIL, tools/dev/result_lib.sh).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
CRATE="$(cd "$HERE/.." && pwd)"
ROOT="$(cd "$CRATE/../.." && pwd)"
# shellcheck source=/dev/null
. "$ROOT/tools/dev/result_lib.sh"
NAME=SILICON_HELPER_STACKRULE
SANDBOX="${SANDBOX:-${TMPDIR:-/tmp}/silicon-helper-arms}"
COPY="$SANDBOX/crate"
WANT="${ARM:-all}"
FAILED=0

[ "$(id -u)" != 0 ] || { echo "run as an ordinary user: the helper refuses its test mode as root"; echo "$NAME RESULT FAIL (root)"; exit 1; }
mkdir -p "$SANDBOX" || { echo "$NAME RESULT FAIL (no sandbox $SANDBOX)"; exit 1; }
# a fresh copy of the crate's sources and fixtures, never its target directory
fresh() {
    rsync -a --delete --exclude target --exclude .git "$CRATE/" "$COPY/" || { echo "$NAME RESULT FAIL (rsync)"; exit 1; }
    if [ "${BREAK:-}" = 1 ]; then echo 'fn this is not rust' >>"$COPY/src/mux.rs"; fi
}

# mutate <label> <file under the crate> <old> <new>: exact-string anchor in the copy, once, or the run fails
mutate() {
    python3 - "$COPY/$2" "$1" "$3" "$4" <<'PY'
import sys
path, label, old, new = sys.argv[1:5]
text = open(path).read()
n = text.count(old)
if n != 1:
    print(f"FAIL {label}: the anchor is in the file {n} times, not once"); sys.exit(1)
open(path, "w").write(text.replace(old, new))
print(f"ok   {label}")
PY
}

# run_suite <label>: the whole suite on the copy; the log's failing test names, one per line, in "$SANDBOX/<label>.failed"
run_suite() {
    local label="$1" log="$SANDBOX/$1.log"
    # one build directory per run: a restored source with an old mtime must never be taken for "already built"
    # (cargo's freshness is by mtime, and a build of the broken rule would be reused for the next run)
    (cd "$COPY" && rm -rf "$SANDBOX/target-$label" && CARGO_TARGET_DIR="$SANDBOX/target-$label" cargo test --offline --no-fail-fast >"$log" 2>&1)
    rl_clean "$log" | grep -a -E '^test .* \.\.\. FAILED$' | sed -E 's/^test (.*) \.\.\. FAILED$/\1/' | sort >"$SANDBOX/$label.failed"
    rm -rf "$SANDBOX/target-$label"
    # no "test result" line, or a compile error: the copy never ran, which proves nothing
    if ! rl_has "$log" '^test result: ' || rl_has "$log" '^error(\[E[0-9]+\]|: could not compile)'; then
        rl_clean "$log" | grep -a -E '^error' | head -5
        echo "$label: the suite did not run"
        rl_noresult "$NAME" "$log"
        exit 1
    fi
    return 0
}

# expect_red <label> <test name>...: every named test is among the failures
expect_red() {
    local label="$1"; shift
    local t miss=0
    for t in "$@"; do
        if grep -qx -- "$t" "$SANDBOX/$label.failed"; then echo "  red   $t"; else echo "  GREEN $t   <- must fail under ARM=$label"; miss=1; fi
    done
    local n; n=$(wc -l <"$SANDBOX/$label.failed")
    echo "ARM $label: $n test(s) failed, $([ $miss = 0 ] && echo 'every named one among them' || echo 'a named test stayed green')"
    return $miss
}

# arm <label> <what it breaks> <file> <old> <new> <test>...: a fresh copy, one mutation, the suite, the named tests red
arm() {
    local label="$1" what="$2" file="$3" old="$4" new="$5"; shift 5
    echo "== ARM $label: $what"
    fresh
    mutate "$label" "$file" "$old" "$new" || return 1
    run_suite "$label" || return 1
    expect_red "$label" "$@"
}

fresh
echo "== baseline (the rules as they are)"
run_suite base
if [ ! -s "$SANDBOX/base.failed" ]; then
    echo "baseline: green"
else
    echo "baseline: RED"; cat "$SANDBOX/base.failed"; FAILED=1
fi

RULE_OLD=$'fn needs_stack_down(want: Wiring) -> bool {\n    want == Wiring::Dgpu\n}'
arm_extend() {
    arm extend "the waiver extended to the dGPU direction (no direction waits for the stack)" src/mux.rs \
        "$RULE_OLD" $'fn needs_stack_down(want: Wiring) -> bool {\n    let _ = want;\n    false\n}' \
        "mux::tests::only_the_dgpu_direction_waits_for_the_stack" \
        "mux::tests::a_unit_that_will_not_stop_means_no_unload_and_no_write" \
        "mux::tests::a_module_that_will_not_unload_means_no_write_and_the_why_says_which" \
        "mux::tests::the_stack_comes_down_in_order_and_the_firmware_is_written_after_the_last_unload" \
        "apply_skips_the_write_when_something_still_holds_the_dgpu" \
        "apply_skips_the_write_when_the_nvidia_modules_cannot_be_unloaded" \
        "the_stack_rule_by_direction_and_by_state_of_the_stack"
}
arm_remove() {
    arm remove "the waiver removed (every direction waits for the stack: the old rule)" src/mux.rs \
        "$RULE_OLD" $'fn needs_stack_down(want: Wiring) -> bool {\n    let _ = want;\n    true\n}' \
        "mux::tests::only_the_dgpu_direction_waits_for_the_stack" \
        "mux::tests::the_way_back_is_written_without_asking_anything_of_the_stack" \
        "the_stack_rule_by_direction_and_by_state_of_the_stack" \
        "the_way_back_with_the_dgpu_in_use_is_written_and_names_the_driver" \
        "the_way_back_goes_to_the_armoury_attribute_too_with_the_stack_stuck" \
        "the_way_back_end_to_end_with_the_stack_stuck"
}
arm_silent() {
    arm silent "a way back written with the driver loaded says nothing about it" src/mux.rs \
        $'fn driver_note(loaded: &[String]) -> String {\n    if loaded.is_empty() {' \
        $'fn driver_note(loaded: &[String]) -> String {\n    if loaded.is_empty() || !loaded.is_empty() {' \
        "mux::tests::the_way_back_is_written_without_asking_anything_of_the_stack" \
        "the_stack_rule_by_direction_and_by_state_of_the_stack" \
        "the_way_back_with_the_dgpu_in_use_is_written_and_names_the_driver"
}
arm_withdraw() {
    arm withdraw "the symmetric withdrawal back: a way back that did not take writes dGPU-only at boot" src/mux.rs \
        $'    (found == Wiring::Hybrid).then_some(found)\n}' $'    Some(found)\n}' \
        "a_way_back_that_did_not_take_writes_nothing_and_the_record_says_why" \
        "mux::tests::the_guard_never_withdraws_toward_dgpu" \
        "mux::tests::applied_in_a_new_boot_follows_the_wiring"
}
arm_nvidiaread() {
    arm nvidiaread "the write paths read the NVIDIA driver's proc entry again" src/machine.rs \
        $'    pub fn discover_for_write(roots: &Roots) -> Machine {\n        Machine::build(roots, false)' \
        $'    pub fn discover_for_write(roots: &Roots) -> Machine {\n        Machine::build(roots, true)' \
        "the_way_back_is_written_when_the_nvidia_proc_entry_blocks" \
        "the_revert_is_written_when_the_nvidia_proc_entry_blocks" \
        "the_guards_withdrawal_is_written_when_the_nvidia_proc_entry_blocks" \
        "the_other_commands_systemd_runs_do_not_read_the_driver_either"
}
arm_nvidiaanswer() {
    arm nvidiaanswer "the answers of systemd's own commands read the NVIDIA driver's proc entry again" src/cli.rs \
        $'let machine = if full { Machine::discover(roots) } else { Machine::discover_for_write(roots) };' \
        $'let machine = if full || !full { Machine::discover(roots) } else { Machine::discover_for_write(roots) };' \
        "the_way_back_is_written_when_the_nvidia_proc_entry_blocks" \
        "the_revert_is_written_when_the_nvidia_proc_entry_blocks" \
        "the_guards_withdrawal_is_written_when_the_nvidia_proc_entry_blocks"
}
arm_unitcheck() {
    arm unitcheck "the unit that writes a queued change is always taken for active" src/gpu.rs \
        $'    if fs::symlink_metadata(dir.join(format!("invocation:{MUX_UNIT}"))).is_ok() {' $'    if true {' \
        "a_request_is_refused_while_the_unit_that_would_write_it_is_not_active" \
        "the_unit_and_the_nvidia_stack_are_both_named_when_both_are_wrong" \
        "gpu::tests::the_unit_is_not_active_when_others_have_links_and_it_has_none"
}
arm_unitblind() {
    arm unitblind "a systemd that exports no invocation link at all is taken for an inactive unit" src/gpu.rs \
        $'    if !list_dir(dir).iter().any(|name| name.starts_with("invocation:")) {' $'    if false {' \
        "a_systemd_that_exports_nothing_is_not_taken_for_an_inactive_unit" \
        "gpu::tests::the_check_cannot_tell_without_a_systemd_that_exports_anything"
}

for a in extend remove silent withdraw nvidiaread nvidiaanswer unitcheck unitblind; do
    if [ "$WANT" = all ] || [ "$WANT" = "$a" ]; then
        "arm_$a" || FAILED=1
    fi
done

if [ "$FAILED" = 0 ]; then
    echo "$NAME RESULT PASS"
else
    echo "$NAME RESULT FAIL"
    exit 1
fi
