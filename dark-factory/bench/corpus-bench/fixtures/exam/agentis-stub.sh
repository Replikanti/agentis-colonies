#!/bin/sh
# agentis-stub.sh — offline stand-in for `agentis` in the #2262 exam runner self-test (exam.sh self-test hands
# it to run-zone-hunt.sh through the --agentis seam, with --backend mock). No LLM, no network. Dash-safe.
#   hunter.ag   the share-pool zone's C1 cell answers one CANDIDATE at Pool.sol:withdraw; every other cell SAFE.
#   refuter.ag  refutes every candidate, so nothing is verified and the delivery stage has nothing to do.
# Test seams (all unset by default):
#   STUB_ENV_DUMP=<file>  every hunter call appends its full environment, then a `--` line, to <file> (the
#                         knob-hygiene assertions read it).
#   STUB_SLEEP=<s>        every hunter call sleeps <s> seconds first (the hard-stop case: HARD_STOP_S < <s>).
#   STUB_FAIL_CALLS=<n> + STUB_FAIL_STATE=<file>
#                         (#2262 M3) the share-pool C1 cell FAILS its first <n> hunter calls (a counter in <file>):
#                         it prints STUB_FAIL_TEXT's file content (default: a terminal agentis transport error)
#                         and no sentinel, so the pipeline marks the cell .novalid. Call <n>+1 answers normally —
#                         that is how the self-test drives the one-shot re-hunt (and, with a large <n>, a cell
#                         still failed after it).
#   STUB_FAIL_TEXT=<file> what a failing call prints (e.g. the usage-limit notice fixture, glyphs and all).
#   STUB_KILL_CALLS=<n> + STUB_KILL_STATE=<file>
#                         (#2262 M3 review) the share-pool C1 cell's first <n> hunter calls SIGKILL the top-level
#                         run-discovery.sh above them (an OOM kill / a `set -eu` abort mid-zone): the cell log stays
#                         empty with no failure marker and run-zone-hunt.sh records the zone `failed` and CONTINUES.
#   STUB_REPO_MUTATE=1    (#2372) the share-pool C1 cell's first hunter call writes into the repo it was handed
#                         ($HUNT_SANDBOX_REPO, the arm's private copy): a leftover PoC test, forge-style build output,
#                         an append to a tracked file, a moved file, a chmod +x, a new symlink and a commit in the
#                         copy's .git. The isolation case proves none of it reaches the frozen base.
#   STUB_BASE_WRITE=<dir> (#2372) the same call writes test/Leak.t.sol into <dir> (the base, behind the guard's back):
#                         the post-run guard must VOID the arm.
case "${1:-}" in
  init) mkdir -p .agentis; exit 0 ;;
  memo) exit 0 ;;
  go)
    case "${2:-}" in
      hunter.ag)
        if [ -n "${STUB_ENV_DUMP:-}" ]; then
          env >> "$STUB_ENV_DUMP"
          echo "--" >> "$STUB_ENV_DUMP"
        fi
        if [ "${SUBSYSTEM:-}" = "share pool" ] && [ "${HUNT_CLASS:-}" = "C1" ]; then
          r="${HUNT_SANDBOX_REPO:-}"
          if [ "${STUB_REPO_MUTATE:-}" = 1 ] && [ -n "$r" ] && [ ! -e "$r/test/Leftover.t.sol" ]; then
            mkdir -p "$r/test" "$r/out/build-info" "$r/docs"
            echo "contract LeftoverPoc {}" > "$r/test/Leftover.t.sol"
            echo "{}" > "$r/out/build-info/x.json"
            echo "// stub edit" >> "$r/src/pool/Pool.sol"
            mv "$r/README.md" "$r/docs/README.moved.md"
            chmod +x "$r/foundry.toml"
            ln -s src/pool/Pool.sol "$r/pool-link.sol"
            git -C "$r" add -A > /dev/null 2>&1
            git -C "$r" -c user.email=stub@example.invalid -c user.name=stub commit -qm leftover > /dev/null 2>&1
          fi
          if [ -n "${STUB_BASE_WRITE:-}" ]; then
            mkdir -p "$STUB_BASE_WRITE/test"
            echo "contract LeakPoc {}" > "$STUB_BASE_WRITE/test/Leak.t.sol"
          fi
        fi
        if [ -n "${STUB_SLEEP:-}" ]; then sleep "$STUB_SLEEP"; fi
        if [ -n "${STUB_KILL_CALLS:-}" ] && [ -n "${STUB_KILL_STATE:-}" ] \
           && [ "${SUBSYSTEM:-}" = "share pool" ] && [ "${HUNT_CLASS:-}" = "C1" ]; then
          kills="$(cat "$STUB_KILL_STATE" 2>/dev/null || echo 0)"
          kills=$((kills + 1))
          echo "$kills" > "$STUB_KILL_STATE"
          if [ "$kills" -le "$STUB_KILL_CALLS" ]; then
            # walk up to the OUTERMOST run-discovery.sh (its subshells carry the same command line)
            pid=$$; top=""
            while [ -n "$pid" ] && [ "$pid" -gt 1 ]; do
              case "$(tr '\000' ' ' < "/proc/$pid/cmdline" 2>/dev/null)" in *run-discovery.sh*) top="$pid" ;; esac
              pid="$(sed 's/.*) //' "/proc/$pid/stat" 2>/dev/null | cut -d' ' -f2)"
            done
            [ -z "$top" ] || kill -KILL "$top"
            exit 137
          fi
        fi
        if [ -n "${STUB_FAIL_CALLS:-}" ] && [ -n "${STUB_FAIL_STATE:-}" ] \
           && [ "${SUBSYSTEM:-}" = "share pool" ] && [ "${HUNT_CLASS:-}" = "C1" ]; then
          calls="$(cat "$STUB_FAIL_STATE" 2>/dev/null || echo 0)"
          calls=$((calls + 1))
          echo "$calls" > "$STUB_FAIL_STATE"
          if [ "$calls" -le "$STUB_FAIL_CALLS" ]; then
            if [ -n "${STUB_FAIL_TEXT:-}" ]; then cat "$STUB_FAIL_TEXT"
            else echo "Error: runtime error: LLM transport error: flat-cyborg exited with status 1"; fi
            exit 1
          fi
        fi
        if [ "${SUBSYSTEM:-}" = "share pool" ] && [ "${HUNT_CLASS:-}" = "C1" ]; then
          echo "CANDIDATE|src/pool/Pool.sol:withdraw:17|C1|High|withdraw prices the exit before the share burn|skew the ratio, then withdraw"
        else
          echo "SAFE"
        fi
        exit 0 ;;
      refuter.ag)
        echo "VERDICT|REFUTED|${CAND_FILE_FN:-}|${CAND_CLASS:-}|stub refuter: refutes every candidate"
        exit 0 ;;
    esac
    exit 0 ;;
esac
exit 0
