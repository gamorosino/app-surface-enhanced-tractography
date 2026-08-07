#!/usr/bin/env bash
# Shared helpers for building the per-subject QC JSON incrementally.
#
# Sourced by run_tracking.sh, 04_run_set_direct.sh, and 05_postprocess.sh.
# run_tracking.sh is the only orchestrator: it calls qc_init once at the
# start, then invokes the other two scripts and waits for each to finish
# before starting the next, so appends to the shared file are always
# sequential across process boundaries — no concurrent-write risk there.
# (Within 04_run_set_direct.sh's parallel seed loop, per-seed results are
# accumulated in memory and written as a single qc_write call after the
# batch joins — see that script for why.)
#
# If a script in the chain fails, run_tracking.sh's `set -e` unwinds before
# qc_finalize ever runs, so the QC file is left with a trailing comma and no
# closing brace — technically invalid JSON, but still human-readable and
# shows exactly which stage was last recorded before the failure. A `trap
# ... EXIT` in run_tracking.sh calls qc_finalize on every exit path so this
# only happens if the trap itself doesn't get to run (e.g. SIGKILL).

qc_timestamp() { date +"%Y-%m-%d %H:%M:%S"; }

# qc_init <path> — start a fresh QC json (top-level orchestrator only).
qc_init() {
    echo "{" > "$1"
}

# qc_write <path> <fragment> — append one stage's JSON fragment.
# <fragment> must be a bare '"key": { ... }' object, without a trailing
# comma — qc_write adds it. The last one written gets its comma stripped
# by qc_finalize.
qc_write() {
    local path="$1" fragment="$2"
    printf "%s,\n" "$fragment" >> "$path"
}

# qc_finalize <path> — strip the last stage's trailing comma, close the
# object, and pretty-print via jq if available (top-level orchestrator only).
qc_finalize() {
    local path="$1"
    [[ -f "$path" ]] || return 0
    sed -i '$ s/,$//' "$path"
    echo "}" >> "$path"
    if command -v jq >/dev/null 2>&1; then
        jq '.' "$path" > "${path}.tmp" 2>/dev/null && mv "${path}.tmp" "$path"
    fi
}
