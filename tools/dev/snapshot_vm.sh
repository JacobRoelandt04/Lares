#!/usr/bin/env bash
# (first: tools/dev/snapshot_vm/prepare.sh)  The rescue's VM tests: a QEMU guest laid out like the laptop (ESP at /boot, swap, ext4 root, GRUB), broken in several ways, then restored
# by the Lares rescue. Nothing is installed on the host; all files live under ~/.cache/claude-orch/snapshots/vm. See tools/dev/snapshot_vm/.
#   tools/dev/snapshot_vm.sh                  every test:  a b c hib cut resc
#   TESTS=a,hib tools/dev/snapshot_vm.sh      some of them
#   ARMS=noexclude,noprotect,bootdelete,nohib,recordonly tools/dev/snapshot_vm.sh   each arm: a patched copy of the rescue, its named check must fail
#   tools/dev/snapshot_vm.sh --build-base     only the cached base image
# One `SNAPSHOT_VM <name> RESULT PASS|FAIL` line per test and a final `SNAPSHOT_VM RESULT`.
set -u
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
vm=$here/snapshot_vm
[ "${1:-}" = --build-base ] && exec python3 "$vm/build_base.py"
args=()
[ -n "${TESTS:-}" ] && args+=(--tests "$TESTS")
if [ -n "${ARMS:-}" ]; then args+=(--arm "$ARMS"); fi
[ -n "${KEEP:-}" ] && args+=(--keep)
python3 "$vm/run_tests.py" "${args[@]}"
