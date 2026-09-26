#!/usr/bin/env bash
# exam.sh — the #2262 held-out EXAM RUNNER (M2: runner core; M3: run integrity). A reusable, contest-agnostic
# replacement for the host-only harness scripts every held-out measurement used to run on: freeze a contest's
# map + briefs from a pinned tool checkout, stage one zone (or the whole contest) into an arm dir, run the breadth
# pass with a KNOB PROFILE and optionally STAGE 4.5 over the same output, leave per-run metadata + done markers,
# drive a plan of rows sequentially, kill everything under a path, and hand the finished arms to triage.py.
# M3 makes every arm prove it is measurable: run-window model attribution (the PURE-<family> gate), VOID
# detection from known signatures (void-patterns.tsv), one in-arm re-hunt of failed cells, a plan HALT on a
# usage-limit VOID, and an explicit `drive --retry-void`.
#
# NOTHING contest-specific lives here. Every contest / arm / path fact is DATA: the frozen base's freeze.meta,
# a profile file (profiles/*.env), and a plan TSV the operator keeps outside the repo. All roots are arguments.
# The runner only INVOKES the pipeline (map-zones.sh, gen-briefs.sh, lib/zone-coverage.py, run-zone-hunt.sh)
# from the tool checkout it is given, and triage.py from its own tree; it edits none of them.
#
# Subcommands:
#   freeze   --base <dir> --contest <id> --checkout <tool-checkout> --profile <p>
#            (--code-subdir <rel> | --project-roots <csv|auto>) [--map-fixture <f> --brief-fixture <f>]
#            [--force] [--allow-fallback-briefs] [--deny-pattern <ERE>]... [--agentis <bin>]
#            Expects <base>/<id>/{code/,truth.tsv} (run-corpus-bench.sh --fetch --gt --id <id> --work <base>).
#            Refuses a dirty checkout and one whose prompt-visible files carry `corpus-bench` or a delimited
#            finding-id token (the colony-lint #2231 rules). Runs map-zones.sh + gen-briefs.sh FROM THE CHECKOUT
#            with the profile's BACKEND/MODEL, refuses mechanical-fallback briefs, greps map/ + briefs/ for
#            contamination, then writes <base>/<id>/freeze.sha256 + freeze.meta. --project-roots (#2255) maps a
#            MULTI-PROJECT clone from its root (`auto` = map-zones.sh's own detection); --code-subdir maps one
#            project dir. The frozen base is never written again by any other subcommand.
#   plan     --base <dir> --contest <id> --arm <label> --repeat <n> --profile <p> --checkout <dir>
#            [--zones <id,...> | --whole]
#            Prints a plan TSV (`contest zone arm repeat profile checkout base`): one row per zone of the frozen
#            zones.json (the every-zone exam), per listed zone, or ONE whole-contest row (zone `_all`). <n> is the
#            repeat INDEX; concatenate plans for more repeats. Review it before anything is spent.
#   stage    --root <root> --base <dir> --contest <id> --zone <id|_all> --arm <label> --repeat <n>
#            --profile <p> --checkout <dir>
#            Verifies freeze.sha256 (exit 3 on drift), refuses an arm whose run is still alive, COPIES map/ +
#            briefs/ into the arm dir, SYMLINKS code/, keeps truth.tsv + judging/ ONLY in the sibling _gt/<contest>/
#            scoring view, filters zones.json to that zone (`_all` keeps every zone), appends the
#            profile's INJECT_CLASSES to the zone's scope.tsv class field once each (no classes = byte-identical),
#            runs lib/zone-coverage.py init and checks `gaps` yields exactly the staged zone(s).
#   run      (the stage args) [--agentis <bin>]
#            Breadth: `timeout HARD_STOP_S run-zone-hunt.sh --rehunt-gaps` with the profile's env.* knobs.
#            One-shot RE-HUNT (M3, REHUNT_TRANSPORT=1, the default): when a final-attempt cell carries .timeout /
#            .novalid or a `transport` void pattern and no `weekly-limit` pattern matched, exactly ONE more
#            breadth call with --rehunt-gaps --rehunt-include-partial --rehunt-max-attempts 2 (the README's
#            symmetry rule; an .untraced cell is a METRIC and never triggers it). A usage-limit match also skips
#            STAGE 4.5 (deep_rc=skip-weekly-limit): it would void too.
#            STAGE 4.5 (DEEP_PASS=1, verify/verified_findings.json present, no breadth / re-hunt call
#            hard-stopped or killed): a second `timeout` call with --deep-hunt --deep-hunt-only over the SAME --out
#            and the deep.* knobs. Every call gets `env -u` for every pipeline + Claude Code knob (see clear_knobs); DF_NO_SANDBOX
#            is refused; the only live backend is flat-cyborg (sandboxed), and it needs bwrap. Refuses a repo root / --out that holds a truth.tsv or judging/. Writes
#            run.pid while alive. A hard stop (rc 124), a killed call (rc >= 128) or a TERM/INT to run itself kills
#            everything left under the arm dir. An EXIT trap ALWAYS writes run.meta (incl. the effective breadth
#            + deep knob env and the re-hunt), attrib.tsv (see attrib), void.txt (see void-check), one
#            MANIFEST.tsv row (with the verdict) and the arm's .done marker, even after a crash.
#   drive    --root <root> --plan <plan.tsv> [--resume | --retry-void] [--agentis <bin>]
#            stage + run per row, sequentially (one live arm at a time), under a PID lock; START/END lines in
#            logs/<plan>.progress (END carries rc=, deep= and void=), logs/<plan>.done at the end. Re-execs from a
#            snapshot of exam/ under logs/ (bash reads a script incrementally, so a pull mid-plan would otherwise
#            corrupt the run). Pins each checkout's HEAD at first use and refuses a row whose checkout has moved,
#            or whose run is still alive. A `weekly-limit` VOID HALTS the plan (logs/<plan>.halted names the row +
#            the evidence; later rows stay unstarted, exit 6): every row behind it would void too. Any other VOID
#            is recorded and the plan continues; nothing is re-run automatically. --resume skips a row only when
#            it is VALID + .done (a VOID row is reported and left alone); --retry-void (implies --resume) moves
#            every VOID arm dir aside as <arm>-r<N>.void-<k> (kept as evidence, never deleted) and re-stages it
#            fresh. Each run is its own process group (setsid); a TERM/INT to the driver stops that group and
#            waits for its cleanup. Ends with the triage hand-off below for every (contest, arm, repeat).
#   triage   --root <root> --contest <id> --arm <label> --repeat <n>
#            triage.py over every VALID zone tree of that arm, against the frozen base's FULL map (located via
#            run.meta); a VOID tree is passed as --unmeasured <zone>:<class>, a zone with no tree is unmeasured by
#            triage itself. Writes <root>/triage/<contest>-<arm>-r<n>.{tsv,md}.
#   attrib   --arm-dir <dir> [--transcripts-root <dir>]      (default: $HOME/.claude/projects)
#            Run-window model attribution of one arm: every RUN dir on disk (discovery/<zone>/run + cell-*,
#            verify/gates*/*/refute-out/run, deep-hunt/*/run, any other stage's run) mapped to Claude Code's per-cwd
#            transcript store by exact name, confirmed by the records' cwd, and model-attribution.py --since/--until
#            over that stage's window from run.meta (discovery + verify: start..breadth/re-hunt end; deep-hunt:
#            deep_start..deep_end). Gate: every stage that ran is PURE-<family of MODEL> (or ATTRIB_FAMILY); a
#            required stage with RUN dirs but no transcript is attribution-missing. Writes <arm>/attrib.tsv and, on
#            a finished arm, refreshes void.txt. `run` does this itself; `freeze` records its own map/brief-stage
#            verdict in freeze.meta (a warning only).
#   void-mark --arm-dir <dir> --reason <text>
#            Operator VOID: writes <arm>/void.operator and refreshes void.txt (exam-helper.py void-check; classes
#            and precedence in void-patterns.tsv + exam-helper.py).
#   kill     --path <dir> [--dry-run] [--grace <s>]
#            Kill-by-path: every process whose args name <dir> (or a path under it), whose cwd is under it, or
#            that is the live run controller of an arm under it (its run.pid) — never this process or its
#            ancestors. <dir> is resolved physically (pwd -P), as /proc/<pid>/cwd is. SIGTERM, grace (default
#            10 s), SIGKILL, then a check that nothing is left. Refuses a path with fewer than three components
#            (/, /tmp/x, a home dir). Reads `ps -ww -eo pid=,ppid=,args=` + /proc/<pid>/cwd; never a
#            pattern-matching process killer, which would match its own command line.
#   self-test
#            Offline end-to-end check over fixtures/exam/ (stub agentis, --backend mock; no LLM, no network).
#
# <p> (a profile) is a shipped name (`control`, `exam`, `exam-plus`, `mock` = profiles/<name>.env) or a path to
# a profile file. Grammar + knob hygiene: see exam-helper.py and profiles/control.env. The three Claude Code
# killswitches (refusal-fallback off, model-fallback off, session persistence on) are exported for every call.
#
# Exam root layout:
#   <root>/MANIFEST.tsv                                 one row per ATTEMPT (append-only, header line)
#   <root>/logs/<plan>.{lock,progress,done,log,heads}   driver lock, START/END lines, final marker, driver log,
#                                                       checkout HEAD pins; <plan>.halted after a usage-limit VOID
#   <root>/arms/<contest>/<zone>/<arm>-r<N>/            run.meta run.log rehunt.log deep.log stage.log stage.meta
#                                                       attrib.tsv void.txt [void.operator] .done
#                                                       run.pid (while alive) breadth.env deep.env env.cleared
#   <root>/arms/<contest>/<zone>/<arm>-r<N>.void-<k>/   a VOID attempt moved aside by drive --retry-void
#       <contest>/{code -> base, zone-hunt-out/}        what the hunt is pointed at
#       _gt/<contest>/{truth.tsv, judging -> base, zone-hunt-out -> ../../<contest>/zone-hunt-out}
#   <root>/triage/<contest>-<arm>-r<N>.{tsv,md}
# Score one arm with `generation-recall.sh --from-work <arm-dir>/_gt --id <contest>`.
#
# Needs bash, python3, git, GNU `timeout`, setsid and /proc (Linux); bwrap for a live backend. Exit: 0 ok; 1 a self-test / kill check failed;
# 2 usage or profile error; 3 missing prerequisite, dirty / contaminated checkout, drift, refused overwrite or a
# live lock; 4 contaminated freeze output; 5 fallback briefs (freeze); 6 the plan HALTED on a usage-limit VOID
# (drive). `run` exits with the breadth rc (else a non-zero re-hunt rc, else a non-zero deep rc).
set -uo pipefail

ME="exam.sh"
EXAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$EXAM_DIR/exam.sh"
HELPER="$EXAM_DIR/exam-helper.py"
PROFILES_DIR="$EXAM_DIR/profiles"
CB_DIR="$(cd "$EXAM_DIR/.." && pwd)"
TRIAGE="$CB_DIR/triage.py"
ATTRIB_PY="$CB_DIR/model-attribution.py"
PATTERNS="$EXAM_DIR/void-patterns.tsv"
SAFE_ID_RE='^[A-Za-z0-9][A-Za-z0-9._-]*$'

# Measurement integrity for every model call this runner starts: a refusal or a model fallback is an ERROR,
# never a silent substitution, and every session is persisted (the attribution gate reads the transcripts).
export CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1
export CLAUDE_CODE_NO_MODEL_FALLBACK=1
export CLAUDE_CODE_FORCE_SESSION_PERSISTENCE=1

die()  { local rc="$1"; shift; echo "$ME: $*" >&2; exit "$rc"; }
note() { echo "$ME: $*" >&2; }
utc()  { date -u +%Y-%m-%dT%H:%M:%SZ; }

need_platform() {
  command -v python3 >/dev/null 2>&1 || die 3 "python3 is required"
  command -v git >/dev/null 2>&1 || die 3 "git is required"
  if ! command -v timeout >/dev/null 2>&1 || ! timeout --version 2>/dev/null | grep -q 'GNU coreutils'; then
    die 3 "GNU timeout is required (coreutils)"
  fi
  [ -d /proc/self ] || die 3 "/proc is required (Linux)"
}

abs_dir()  { (cd "$1" 2>/dev/null && pwd -P); }   # PHYSICAL: /proc/<pid>/cwd is physical too
abs_file() { local d; d="$(abs_dir "$(dirname "$1")")" || return 1; printf '%s/%s\n' "$d" "$(basename "$1")"; }
safe_id()  { [[ "$1" =~ $SAFE_ID_RE ]]; }
pos_int()  { [[ "$1" =~ ^[1-9][0-9]*$ ]]; }
meta_get() { sed -n "s/^$2=//p" "$1" 2>/dev/null | head -1; }
need_val() { [ "$1" -ge 2 ] || die 2 "missing value for $2"; }

# A profile argument -> an absolute profile path. A bare name is a shipped profile.
resolve_profile() {
  case "$1" in
    */*|*.env)
      [ -f "$1" ] || die 2 "profile not found: $1"
      abs_file "$1" ;;
    *)
      safe_id "$1" && [ -f "$PROFILES_DIR/$1.env" ] || die 2 "no shipped profile '$1' (see $PROFILES_DIR)"
      printf '%s\n' "$PROFILES_DIR/$1.env" ;;
  esac
}

# Parse + validate a profile into P_* runner values and the ENV_KV / DEEP_KV / PASS_NAMES arrays.
P_BACKEND=""; P_MODEL=""; P_JOBS=""; P_DEEP_JOBS=""; P_HARD_STOP_S=""; P_DEEP_PASS=""; P_INJECT_CLASSES=""
P_SCOPE_DOCS=""; P_REHUNT_TRANSPORT=""; P_ATTRIB_FAMILY=""; ENV_KV=(); DEEP_KV=(); PASS_NAMES=()
load_profile() {
  local f="$1" tmp kind name val
  tmp="$(mktemp)"
  if ! python3 "$HELPER" profile "$f" > "$tmp"; then rm -f "$tmp"; die 2 "invalid profile: $f"; fi
  ENV_KV=(); DEEP_KV=(); PASS_NAMES=()
  while IFS= read -r -d '' kind && IFS= read -r -d '' name && IFS= read -r -d '' val; do
    case "$kind" in
      R) printf -v "P_$name" '%s' "$val" ;;
      E) ENV_KV+=("$name=$val") ;;
      D) DEEP_KV+=("$name=$val") ;;
      P) PASS_NAMES+=("$name") ;;
    esac
  done < "$tmp"
  rm -f "$tmp"
  [ -n "$P_DEEP_JOBS" ] || P_DEEP_JOBS="$P_JOBS"
}

# Knob hygiene (#2262 STOP-1 decision 2): the caller's environment is inherited, but every pipeline call the
# runner starts gets `env -u` for every knob candidate (exam-helper.py clear-list: every env name the checkout's
# pipeline reads, derived by grep at run time, + the shipped profiles' knob names + KNOBS names + every exported
# variable matching a KNOBS prefix, minus the !NAME host plumbing, the killswitches and the profile's own
# pass.<NAME>s, which must be present). The runner's own shell is never modified. DF_NO_SANDBOX is REFUSED, never
# cleared silently: a held-out run must never disable the hunt sandbox.
CLEAR_ARGS=()
clear_knobs() {
  local f="$1" df="$2" out="$3" n p
  [ -z "${DF_NO_SANDBOX:-}" ] \
    || die 3 "DF_NO_SANDBOX is set in the caller's environment — a held-out run never disables the hunt sandbox (unset it)"
  python3 "$HELPER" clear-list "$df" "$PROFILES_DIR" "$f" > "$out" || die 2 "cannot build the env clear list"
  CLEAR_ARGS=()
  while IFS= read -r n; do [ -n "$n" ] && CLEAR_ARGS+=(-u "$n"); done < "$out"
  for p in ${PASS_NAMES[@]+"${PASS_NAMES[@]}"}; do
    [ -n "${!p+x}" ] || die 3 "the profile inherits $p (pass.$p) but it is not set in the environment"
  done
}

# A live backend drives real Claude Code sessions: without bubblewrap lib/claude-sandboxed.sh falls through to an
# UNSANDBOXED session that can read the host (ground truth included). Refuse instead.
need_sandbox() {
  case "$P_BACKEND" in
    mock) return 0 ;;
    flat-cyborg) ;;
    *) die 3 "backend '$P_BACKEND' is refused — only flat-cyborg runs the hunt sessions sandboxed" ;;
  esac
  command -v bwrap >/dev/null 2>&1 \
    || die 3 "bwrap (bubblewrap) is required for a live backend — the hunt sessions must run sandboxed"
}

# The knob state a call actually ran with (NAME=VALUE, pass.<NAME> values masked), one line per knob.
effective_env() {
  local clearfile="$1"; shift
  env ${CLEAR_ARGS[@]+"${CLEAR_ARGS[@]}"} "$@" env -0 \
    | python3 "$HELPER" effective-env "$clearfile" ${PASS_NAMES[@]+"${PASS_NAMES[@]}"}
}

# 0 when <armdir>/run.pid names a live `exam.sh run` process (a second writer must never start).
arm_live() {
  local pf="$1/run.pid" pid
  [ -f "$pf" ] || return 1
  pid="$(head -1 "$pf" 2>/dev/null)"
  [[ "$pid" =~ ^[0-9]+$ ]] && [ -d "/proc/$pid" ] || return 1
  ps -ww -o stat=,args= -p "$pid" 2>/dev/null | awk '$1 !~ /^Z/ && /exam\.sh/ { f = 1 } END { exit f ? 0 : 1 }'
}

# sha256 of files. posix-portability: deferred (guarded pair — sha256sum on GNU, shasum -a 256 on BSD/macOS).
SHA256_CMD="sha256sum"; command -v sha256sum >/dev/null 2>&1 || SHA256_CMD="shasum -a 256"
# shellcheck disable=SC2086  # SHA256_CMD is a command + its flags, split on purpose
file_sha() { $SHA256_CMD "$1" | cut -d' ' -f1; }

# The frozen artifact manifest: sha256 of every file under map/ + briefs/, sorted relative paths.
freeze_manifest() {
  # shellcheck disable=SC2086  # SHA256_CMD is a command + its flags, split on purpose
  (cd "$1" && find map briefs -type f -print0 | LC_ALL=C sort -z | xargs -0 -r $SHA256_CMD)
}

# ----------------------------------------------------------------------------------------------------------
# kill-by-path
# ----------------------------------------------------------------------------------------------------------
# Every process (pid<TAB>why<TAB>args) that names PATH in its args, runs with its cwd under PATH, or is the live
# `exam.sh run` controller of an arm under PATH (its run.pid — the controller's own args name the root, not the
# arm, and its cwd is elsewhere), minus this process, its ancestors, its own descendants (the command
# substitutions of this very scan) and any other `exam.sh kill` (an operator's kill racing a run's cleanup).
kill_scan() {
  local path="$1" snap line pid why cwd pf pidfiles=""
  if [ -d "$path" ]; then
    while IFS= read -r pf; do
      pid="$(head -1 "$pf" 2>/dev/null)"
      [[ "$pid" =~ ^[0-9]+$ ]] && pidfiles="$pidfiles $pid"
    done < <(find "$path" -maxdepth 6 -name run.pid -type f 2>/dev/null)
  fi
  snap="$(ps -ww -eo pid=,ppid=,args=)"
  while IFS=$'\t' read -r pid why line; do
    [ -n "$pid" ] || continue
    [ -d "/proc/$pid" ] || continue
    if [ "$why" = "cwd?" ]; then
      cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null || true)"
      case "$cwd" in
        "$path"|"$path"/*) why="cwd" ;;
        *) continue ;;
      esac
    fi
    printf '%s\t%s\t%s\n' "$pid" "$why" "$line"
  done < <(printf '%s\n' "$snap" | awk -v self="$$" -v p="$path" -v pf="$pidfiles" '
    { pid = $1; ppid = $2; a = $0; sub(/^[[:space:]]*[0-9]+[[:space:]]+[0-9]+[[:space:]]?/, "", a)
      par[pid] = ppid; args[pid] = a; order[++n] = pid }
    function names(s,   i, rest, b, c) {
      rest = s; b = ""
      while ((i = index(rest, p)) > 0) {
        c = substr(rest, i + length(p), 1)
        if (i > 1) b = substr(rest, i - 1, 1)
        if ((b == "" || b == " " || b == "=" || b == ":" || b == "\047" || b == "\"") && (c == "" || c == "/" || c == " ")) return 1
        b = substr(rest, i, 1); rest = substr(rest, i + 1)
      }
      return 0
    }
    END {
      x = self; guard = 0
      while (x != "" && x != "0" && guard++ < 4096) { ex[x] = 1; x = par[x] }
      desc[self] = 1; changed = 1
      while (changed) { changed = 0
        for (k = 1; k <= n; k++) { q = order[k]; if (!(q in desc) && (par[q] in desc)) { desc[q] = 1; changed = 1 } } }
      np = split(pf, pfl, " "); for (k = 1; k <= np; k++) isrun[pfl[k]] = 1
      for (k = 1; k <= n; k++) { q = order[k]
        if (q in ex) continue
        # own descendants are skipped only when they are helpers of this scan (a command-substitution subshell
        # carries our argv, or the ps itself) — the real children of a run (timeout, the hunt) must still be matched.
        if ((q in desc) && (args[q] == args[self] || args[q] ~ /^ps( |$)/)) continue
        if (args[q] ~ /^\[.*\]$/) continue
        if (args[q] ~ /exam\.sh kill( |$)/) continue
        if ((q in isrun) && args[q] ~ /exam\.sh run( |$)/) { printf "%s\tpidfile\t%s\n", q, args[q]; continue }
        printf "%s\t%s\t%s\n", q, (names(args[q]) ? "args" : "cwd?"), args[q] }
    }')
}

kill_by_path() {
  local path="$1" dry="$2" grace="$3" hits pids pid i left
  hits="$(kill_scan "$path")"
  if [ "$dry" -eq 1 ]; then
    [ -z "$hits" ] || printf '%s\n' "$hits"
    return 0
  fi
  [ -n "$hits" ] || { note "kill: nothing under $path"; return 0; }
  pids="$(printf '%s\n' "$hits" | cut -f1)"
  note "kill: SIGTERM -> $(printf '%s\n' "$pids" | paste -sd' ' -)"
  for pid in $pids; do kill -TERM "$pid" 2>/dev/null || true; done
  i=0
  while [ "$i" -lt "$grace" ]; do
    left="$(kill_scan "$path")"
    [ -n "$left" ] || break
    sleep 1; i=$((i + 1))
  done
  left="$(kill_scan "$path")"
  if [ -n "$left" ]; then
    pids="$(printf '%s\n' "$left" | cut -f1)"
    note "kill: SIGKILL -> $(printf '%s\n' "$pids" | paste -sd' ' -)"
    for pid in $pids; do kill -KILL "$pid" 2>/dev/null || true; done
    sleep 1
  fi
  left="$(kill_scan "$path")"
  if [ -n "$left" ]; then
    note "kill: processes survive under $path:"; printf '%s\n' "$left" >&2
    return 1
  fi
  return 0
}

cmd_kill() {
  local path="" dry=0 grace=10
  while [ $# -gt 0 ]; do
    case "$1" in
      --path) need_val "$#" "$1"; path="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --grace) need_val "$#" "$1"; grace="$2"; shift 2 ;;
      *) die 2 "kill: unknown flag $1" ;;
    esac
  done
  [ -n "$path" ] || die 2 "kill: --path <dir> required"
  [[ "$grace" =~ ^[0-9]+$ ]] || die 2 "kill: --grace must be a whole number of seconds"
  [ -d /proc/self ] || die 3 "kill: /proc is required (Linux) — without it no cwd can be read"
  case "$path" in /*) ;; *) path="$(pwd)/$path" ;; esac
  if [ -d "$path" ]; then
    path="$(abs_dir "$path")"
  elif [ -d "$(dirname "$path")" ]; then
    path="$(abs_dir "$(dirname "$path")")/$(basename "$path")"
  fi
  path="${path%/}"
  # A path this short (/, /tmp/x, a home dir) would match half the machine; an exam root is always deeper.
  [ "$(printf '%s\n' "$path" | tr -cd '/' | wc -c)" -ge 3 ] || die 2 "kill: refusing a path this close to / ($path)"
  kill_by_path "$path" "$dry" "$grace"
}

# ----------------------------------------------------------------------------------------------------------
# freeze
# ----------------------------------------------------------------------------------------------------------
cmd_freeze() {
  local base="" contest="" checkout="" profile="" subdir="" roots="" mapfx="" brieffx="" force=0 allow_fb=0
  local agentis="agentis"
  local -a deny=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) need_val "$#" "$1"; base="$2"; shift 2 ;;
      --contest) need_val "$#" "$1"; contest="$2"; shift 2 ;;
      --checkout) need_val "$#" "$1"; checkout="$2"; shift 2 ;;
      --profile) need_val "$#" "$1"; profile="$2"; shift 2 ;;
      --code-subdir) need_val "$#" "$1"; subdir="$2"; shift 2 ;;
      --project-roots) need_val "$#" "$1"; roots="$2"; shift 2 ;;
      --map-fixture) need_val "$#" "$1"; mapfx="$2"; shift 2 ;;
      --brief-fixture) need_val "$#" "$1"; brieffx="$2"; shift 2 ;;
      --deny-pattern) need_val "$#" "$1"; deny+=("$2"); shift 2 ;;
      --agentis) need_val "$#" "$1"; agentis="$2"; shift 2 ;;
      --force) force=1; shift ;;
      --allow-fallback-briefs) allow_fb=1; shift ;;
      *) die 2 "freeze: unknown flag $1" ;;
    esac
  done
  [ -n "$base" ] && [ -n "$contest" ] && [ -n "$checkout" ] && [ -n "$profile" ] \
    || die 2 "freeze: --base --contest --checkout --profile are required"
  safe_id "$contest" || die 2 "freeze: bad contest id '$contest'"
  if [ -n "$subdir" ] && [ -n "$roots" ]; then die 2 "freeze: --code-subdir and --project-roots are exclusive"; fi
  if [ -z "$subdir" ] && [ -z "$roots" ]; then die 2 "freeze: one of --code-subdir / --project-roots is required"; fi
  if [ -n "$subdir" ]; then
    case "/$subdir/" in /[/]*|*/../*) die 2 "freeze: --code-subdir must be relative, without '..'" ;; esac
  fi
  if [ -n "$roots" ] && [ "$roots" != auto ] && ! [[ "$roots" =~ ^[A-Za-z0-9._/-]+(,[A-Za-z0-9._/-]+)+$ ]]; then
    die 2 "freeze: --project-roots takes 'auto' or a comma list of at least two root dirs"
  fi
  { [ -z "$mapfx" ] || [ -f "$mapfx" ]; } && { [ -z "$brieffx" ] || [ -f "$brieffx" ]; } \
    || die 2 "freeze: a --map-fixture / --brief-fixture file does not exist"
  [ -z "$mapfx" ] || mapfx="$(abs_file "$mapfx")"
  [ -z "$brieffx" ] || brieffx="$(abs_file "$brieffx")"
  need_platform
  base="$(abs_dir "$base")" || die 3 "freeze: --base not found"
  checkout="$(abs_dir "$checkout")" || die 3 "freeze: --checkout not found"
  profile="$(resolve_profile "$profile")" || exit 2
  local cdir="$base/$contest" df="$checkout/dark-factory"
  [ -d "$cdir/code" ] || die 3 "freeze: $cdir/code missing (run-corpus-bench.sh --fetch --gt --id $contest --work <base>)"
  [ -f "$cdir/truth.tsv" ] || die 3 "freeze: $cdir/truth.tsv missing"
  [ -f "$df/map-zones.sh" ] && [ -f "$df/gen-briefs.sh" ] || die 3 "freeze: $checkout is not a dark-factory checkout"
  local commit dirty
  commit="$(git -C "$checkout" rev-parse HEAD 2>/dev/null)" || die 3 "freeze: $checkout is not a git checkout"
  dirty="$(git -C "$checkout" status --porcelain 2>/dev/null)"
  [ -z "$dirty" ] || die 3 "freeze: the checkout is dirty — a freeze must come from a pinned, clean commit"

  # PRE-flight: the checkout's prompt-visible files must be clean (colony-lint #2231 rules).
  local hits scan_rc
  hits="$(python3 "$HELPER" contam-scan "$checkout")"; scan_rc=$?
  if [ "$scan_rc" -eq 1 ]; then
    note "freeze: the checkout's prompt-visible files carry corpus ground truth:"; printf '%s\n' "$hits" | head -20 >&2
    exit 3
  fi
  [ "$scan_rc" -eq 0 ] || die 3 "freeze: the prompt-visibility pre-flight failed (exit $scan_rc)"

  load_profile "$profile"
  need_sandbox
  local clearf; clearf="$(mktemp)"
  clear_knobs "$profile" "$df" "$clearf"

  local code code_rel roots_meta
  if [ -n "$subdir" ]; then
    code_rel="${subdir%/}"; code="$cdir/code/$code_rel"; roots_meta="-"
  else
    code_rel="."; code="$cdir/code"; roots_meta="$roots"
  fi
  [ -d "$code" ] || die 3 "freeze: code dir $code missing"

  if [ -e "$cdir/map" ] || [ -e "$cdir/briefs" ] || [ -e "$cdir/freeze.meta" ] || [ -e "$cdir/freeze.sha256" ]; then
    [ "$force" -eq 1 ] || die 3 "freeze: $cdir is already (partly) frozen — --force re-freezes it"
    rm -rf "$cdir/map" "$cdir/briefs" "$cdir/freeze.meta" "$cdir/freeze.sha256"
  fi

  local log="$cdir/freeze.log"
  local -a common=(--backend "$P_BACKEND" --agentis "$agentis")
  [ -z "$P_MODEL" ] || common+=(--model "$P_MODEL")
  local -a margs=(--repo "$code" --out "$cdir/map")
  if [ -n "$roots" ] && [ "$roots" != auto ]; then margs+=(--project-roots "$roots"); fi
  [ -z "$mapfx" ] || margs+=(--fixture "$mapfx")
  local fstart; fstart="$(utc)"
  echo "[freeze $fstart] contest=$contest checkout=$commit backend=$P_BACKEND model=${P_MODEL:--}" >> "$log"
  (cd "$df" && env ${CLEAR_ARGS[@]+"${CLEAR_ARGS[@]}"} bash map-zones.sh "${margs[@]}" "${common[@]}") >> "$log" 2>&1 \
    || die 3 "freeze: map-zones.sh failed (see $log)"
  [ -f "$cdir/map/zones.json" ] && grep -qv '^#' "$cdir/map/scope.tsv" 2>/dev/null \
    || die 3 "freeze: map-zones.sh produced no zones.json / scope.tsv lines (see $log)"
  local -a bargs=(--zones "$cdir/map/zones.json" --scope "$cdir/map/scope.tsv" --out "$cdir/briefs" --repo "$code")
  [ -z "$brieffx" ] || bargs+=(--fixture "$brieffx")
  local bout; bout="$(cd "$df" && env ${CLEAR_ARGS[@]+"${CLEAR_ARGS[@]}"} bash gen-briefs.sh "${bargs[@]}" "${common[@]}" 2>&1)"
  local brc=$?
  printf '%s\n' "$bout" >> "$log"
  [ "$brc" -eq 0 ] && [ -d "$cdir/briefs/briefs" ] || die 3 "freeze: gen-briefs.sh failed (see $log)"
  if printf '%s\n' "$bout" | grep -qE 'FAILED validation|mechanical briefs only'; then
    if [ "$allow_fb" -eq 1 ]; then
      note "freeze: WARNING mechanical-fallback briefs accepted (--allow-fallback-briefs)"
    else
      note "freeze: gen-briefs.sh fell back to MECHANICAL briefs — regenerate them (or --allow-fallback-briefs):"
      printf '%s\n' "$bout" | grep -E 'FAILED validation|mechanical briefs only' >&2
      exit 5
    fi
  fi

  # POST-freeze: the model's own output must not name the bench, a finding id, the judging repo or an audit
  # platform (the free-association leak the prompt-side guard cannot see).
  local leak="" pat
  leak="$(grep -rnF 'corpus-bench' "$cdir/map" "$cdir/briefs" 2>/dev/null
          grep -rnE '(^|[^[:alnum:]_])[HM]-[0-9]{1,2}([^[:alnum:]_]|$)' "$cdir/map" "$cdir/briefs" 2>/dev/null
          grep -rnF ' GT ' "$cdir/map" "$cdir/briefs" 2>/dev/null
          grep -rniE 'judging|sherlock|code4rena|code-423n4|cantina|codehawks' "$cdir/map" "$cdir/briefs" 2>/dev/null
          for pat in ${deny[@]+"${deny[@]}"}; do grep -rniE -- "$pat" "$cdir/map" "$cdir/briefs" 2>/dev/null; done
          true)"
  if [ -n "$leak" ]; then
    note "freeze: CONTAMINATED output (map/ + briefs/):"; printf '%s\n' "$leak" | sed "s|^$cdir/||" | head -20 >&2
    exit 4
  fi

  freeze_manifest "$cdir" > "$cdir/freeze.sha256"
  effective_env "$clearf" > "$cdir/freeze.env"
  rm -f "$clearf"
  # M3: the map + brief stages' own run-window attribution — recorded, a WARNING only (a freeze is re-done by hand).
  local fattrib="skipped-mock" fgate="ok"
  if [ "$P_BACKEND" != mock ]; then
    local -a ffam=(); [ -z "$P_ATTRIB_FAMILY" ] || ffam=(--family "$P_ATTRIB_FAMILY")
    if python3 "$HELPER" attrib --root "$cdir" --transcripts-root "$HOME/.claude/projects" --model "$P_MODEL"          ${ffam[@]+"${ffam[@]}"} --tsv "$cdir/freeze.attrib.tsv" --stage "map=$fstart,$(utc)" --stage "briefs=$fstart,$(utc)"; then
      fattrib="$(awk -F'\t' 'NR > 1 { printf "%s%s:%s(%s)", (n++ ? "," : ""), $1, $7, $9 }' "$cdir/freeze.attrib.tsv")"
      awk -F'\t' 'NR > 1 && $9 != "ok" && $9 != "not-run" { f = 1 } END { exit f ? 0 : 1 }' "$cdir/freeze.attrib.tsv" && fgate="WARN"
    else
      fattrib="error"; fgate="WARN"
    fi
    [ "$fgate" = ok ] || note "freeze: WARNING the map/brief stages are not PURE-${P_ATTRIB_FAMILY:-<family of $P_MODEL>} in the freeze window: $fattrib (see freeze.attrib.tsv)"
  fi
  local map_roots; map_roots="$(python3 "$HELPER" zone-roots "$cdir/map/zones.json")" || map_roots="-"
  {
    echo "checkout_commit=$commit"
    echo "model=${P_MODEL:--}"
    echo "backend=$P_BACKEND"
    echo "code_dir_rel=$code_rel"
    echo "project_roots=$roots_meta"
    echo "map_roots=$map_roots"
    echo "profile=$(basename "$profile")"
    echo "profile_sha256=$(file_sha "$profile")"
    echo "fallback_briefs_allowed=$allow_fb"
    echo "attrib=$fattrib"
    echo "attrib_gate=$fgate"
    echo "frozen_utc=$(utc)"
  } > "$cdir/freeze.meta"
  note "freeze: $contest frozen ($(wc -l < "$cdir/freeze.sha256") files, commit $commit, roots $map_roots)"
}

# ----------------------------------------------------------------------------------------------------------
# plan
# ----------------------------------------------------------------------------------------------------------
cmd_plan() {
  local base="" contest="" arm="" repeat="" profile="" checkout="" zones="" whole=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) need_val "$#" "$1"; base="$2"; shift 2 ;;
      --contest) need_val "$#" "$1"; contest="$2"; shift 2 ;;
      --arm) need_val "$#" "$1"; arm="$2"; shift 2 ;;
      --repeat) need_val "$#" "$1"; repeat="$2"; shift 2 ;;
      --profile) need_val "$#" "$1"; profile="$2"; shift 2 ;;
      --checkout) need_val "$#" "$1"; checkout="$2"; shift 2 ;;
      --zones) need_val "$#" "$1"; zones="$2"; shift 2 ;;
      --whole) whole=1; shift ;;
      *) die 2 "plan: unknown flag $1" ;;
    esac
  done
  [ -n "$base" ] && [ -n "$contest" ] && [ -n "$arm" ] && [ -n "$repeat" ] && [ -n "$profile" ] && [ -n "$checkout" ] \
    || die 2 "plan: --base --contest --arm --repeat --profile --checkout are required"
  safe_id "$contest" && safe_id "$arm" || die 2 "plan: bad contest / arm label"
  pos_int "$repeat" || die 2 "plan: --repeat must be a positive integer (the repeat index)"
  if [ -n "$zones" ] && [ "$whole" -eq 1 ]; then die 2 "plan: --zones and --whole are exclusive"; fi
  base="$(abs_dir "$base")" || die 3 "plan: --base not found"
  checkout="$(abs_dir "$checkout")" || die 3 "plan: --checkout not found"
  local pfile pcol
  pfile="$(resolve_profile "$profile")" || exit 2
  python3 "$HELPER" profile-summary "$pfile" > /dev/null || die 2 "plan: invalid profile $pfile"
  case "$profile" in */*|*.env) pcol="$pfile" ;; *) pcol="$profile" ;; esac
  local cdir="$base/$contest"
  [ -f "$cdir/freeze.meta" ] || die 3 "plan: $cdir is not frozen (exam.sh freeze first)"
  local all z; all="$(python3 "$HELPER" zone-ids "$cdir/map/zones.json")" || die 3 "plan: unreadable frozen map"
  local -a rows=()
  if [ "$whole" -eq 1 ]; then
    rows=(_all)
  elif [ -n "$zones" ]; then
    local -a listed=()
    IFS=, read -r -a listed <<< "$zones"
    for z in "${listed[@]}"; do
      printf '%s\n' "$all" | grep -qxF -- "$z" || die 2 "plan: zone '$z' is not in the frozen map"
      rows+=("$z")
    done
  else
    while IFS= read -r z; do [ -n "$z" ] && rows+=("$z"); done <<< "$all"
  fi
  printf '# contest\tzone\tarm\trepeat\tprofile\tcheckout\tbase\n'
  for z in "${rows[@]}"; do
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$contest" "$z" "$arm" "$repeat" "$pcol" "$checkout" "$base"
  done
}

# ----------------------------------------------------------------------------------------------------------
# stage / run (shared argument parsing)
# ----------------------------------------------------------------------------------------------------------
A_ROOT=""; A_BASE=""; A_CONTEST=""; A_ZONE=""; A_ARM=""; A_REPEAT=""; A_PROFILE=""; A_CHECKOUT=""; A_AGENTIS="agentis"
parse_arm_args() {
  local who="$1"; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) need_val "$#" "$1"; A_ROOT="$2"; shift 2 ;;
      --base) need_val "$#" "$1"; A_BASE="$2"; shift 2 ;;
      --contest) need_val "$#" "$1"; A_CONTEST="$2"; shift 2 ;;
      --zone) need_val "$#" "$1"; A_ZONE="$2"; shift 2 ;;
      --arm) need_val "$#" "$1"; A_ARM="$2"; shift 2 ;;
      --repeat) need_val "$#" "$1"; A_REPEAT="$2"; shift 2 ;;
      --profile) need_val "$#" "$1"; A_PROFILE="$2"; shift 2 ;;
      --checkout) need_val "$#" "$1"; A_CHECKOUT="$2"; shift 2 ;;
      --agentis) [ "$who" = run ] || die 2 "$who: unknown flag $1"; need_val "$#" "$1"; A_AGENTIS="$2"; shift 2 ;;
      *) die 2 "$who: unknown flag $1" ;;
    esac
  done
  [ -n "$A_ROOT" ] && [ -n "$A_BASE" ] && [ -n "$A_CONTEST" ] && [ -n "$A_ZONE" ] && [ -n "$A_ARM" ] \
    && [ -n "$A_REPEAT" ] && [ -n "$A_PROFILE" ] && [ -n "$A_CHECKOUT" ] \
    || die 2 "$who: --root --base --contest --zone --arm --repeat --profile --checkout are required"
  safe_id "$A_CONTEST" && safe_id "$A_ARM" || die 2 "$who: bad contest / arm label"
  [ "$A_ZONE" = _all ] || safe_id "$A_ZONE" || die 2 "$who: bad zone id '$A_ZONE'"
  pos_int "$A_REPEAT" || die 2 "$who: --repeat must be a positive integer"
  need_platform
  mkdir -p "$A_ROOT" || die 3 "$who: cannot create --root"
  A_ROOT="$(abs_dir "$A_ROOT")"
  A_BASE="$(abs_dir "$A_BASE")" || die 3 "$who: --base not found"
  A_CHECKOUT="$(abs_dir "$A_CHECKOUT")" || die 3 "$who: --checkout not found"
  A_PROFILE="$(resolve_profile "$A_PROFILE")" || exit 2
  [ -f "$A_CHECKOUT/dark-factory/run-zone-hunt.sh" ] && [ -f "$A_CHECKOUT/dark-factory/lib/zone-coverage.py" ] \
    || die 3 "$who: $A_CHECKOUT is not a dark-factory checkout"
}

arm_dir() { printf '%s/arms/%s/%s/%s-r%s\n' "$1" "$2" "$3" "$4" "$5"; }

cmd_stage() {
  parse_arm_args stage "$@"
  local cdir="$A_BASE/$A_CONTEST" df="$A_CHECKOUT/dark-factory"
  [ -f "$cdir/freeze.meta" ] && [ -f "$cdir/freeze.sha256" ] || die 3 "stage: $cdir is not frozen"
  [ -f "$cdir/truth.tsv" ] && [ -d "$cdir/code" ] || die 3 "stage: $cdir lacks truth.tsv / code/"
  if ! freeze_manifest "$cdir" | cmp -s - "$cdir/freeze.sha256"; then
    die 3 "stage: the frozen base $cdir DRIFTED from freeze.sha256 — refusing to stage (re-freeze or restore it)"
  fi
  load_profile "$A_PROFILE"
  local armdir; armdir="$(arm_dir "$A_ROOT" "$A_CONTEST" "$A_ZONE" "$A_ARM" "$A_REPEAT")"
  if arm_live "$armdir"; then
    die 3 "stage: $armdir has a LIVE run (pid $(head -1 "$armdir/run.pid")) — refusing to start a second writer"
  fi
  [ ! -e "$armdir/.done" ] || die 3 "stage: $armdir already ran (.done) — refusing to overwrite a finished arm"
  if [ -e "$armdir" ]; then
    local k=1; while [ -e "$armdir.partial-$k" ]; do k=$((k + 1)); done
    mv "$armdir" "$armdir.partial-$k" || die 3 "stage: cannot move the unfinished $armdir aside"
    note "stage: an unfinished arm dir was kept as $(basename "$armdir").partial-$k"
  fi
  local out="$armdir/$A_CONTEST/zone-hunt-out"
  mkdir -p "$out/coverage" || die 3 "stage: cannot create $out"
  local slog="$armdir/stage.log"
  slogf() { printf '[stage %s] %s\n' "$(utc)" "$*" >> "$slog"; }
  # Ground truth never sits next to anything the hunt is pointed at: truth.tsv + judging/ live in the sibling
  # _gt/<contest>/ scoring view (with a zone-hunt-out link, so `generation-recall.sh --from-work <arm>/_gt` works).
  local gt="$armdir/_gt/$A_CONTEST"
  mkdir -p "$gt" || die 3 "stage: cannot create $gt"
  cp -a "$cdir/map" "$out/map" && cp -a "$cdir/briefs" "$out/briefs" && cp "$cdir/truth.tsv" "$gt/truth.tsv" \
    || die 3 "stage: copying the frozen base failed"
  ln -s "$cdir/code" "$armdir/$A_CONTEST/code"
  [ ! -e "$cdir/judging" ] || ln -s "$cdir/judging" "$gt/judging"
  ln -s "../../$A_CONTEST/zone-hunt-out" "$gt/zone-hunt-out"
  slogf "copied map/ briefs/ from $cdir, truth.tsv into _gt/$A_CONTEST/; code/ (+ _gt judging/) symlinked read-only"
  clear_knobs "$A_PROFILE" "$df" "$armdir/stage.env-cleared"
  local zones_json="$out/map/zones.json" scope="$out/map/scope.tsv" name
  if [ "$A_ZONE" != _all ]; then
    name="$(python3 "$HELPER" zone-filter "$zones_json" "$A_ZONE")" || die 3 "stage: zone filter failed"
    slogf "zones.json filtered to 1 zone: id=$A_ZONE name=\"$name\""
  else
    slogf "whole-contest arm: zones.json kept whole"
  fi
  if [ -n "$P_INJECT_CLASSES" ]; then
    python3 "$HELPER" inject-classes "$scope" "$zones_json" "$P_INJECT_CLASSES" >> "$slog" \
      || die 3 "stage: class injection failed"
    slogf "injected $P_INJECT_CLASSES into the staged scope.tsv (lines above)"
  else
    slogf "scope.tsv left byte-identical to the frozen base (no INJECT_CLASSES)"
  fi
  local commit; commit="$(git -C "$A_CHECKOUT" rev-parse HEAD 2>/dev/null || echo unknown)"
  (cd "$df" && env ${CLEAR_ARGS[@]+"${CLEAR_ARGS[@]}"} python3 lib/zone-coverage.py init --zones "$zones_json" --out "$out/coverage/zone-coverage.json" \
      --zone-list "$out/.zone-list.tsv" --repo "$A_CONTEST" --commit "$commit" \
      --zone-cell-budget 0 --run-cell-budget 0) >> "$slog" 2>&1 || die 3 "stage: zone-coverage.py init failed"
  local gaps want got
  gaps="$(cd "$df" && env ${CLEAR_ARGS[@]+"${CLEAR_ARGS[@]}"} python3 lib/zone-coverage.py gaps --file "$out/coverage/zone-coverage.json" --max-attempts 2)" \
    || die 3 "stage: zone-coverage.py gaps failed"
  want="$(python3 "$HELPER" zone-ids "$zones_json" | LC_ALL=C sort)"
  got="$(printf '%s\n' "$gaps" | awk -F'\t' 'NF {print $1}' | LC_ALL=C sort)"
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    slogf "SELF-CHECK FAILED: gaps = [$(printf '%s' "$got" | paste -sd, -)], expected [$(printf '%s' "$want" | paste -sd, -)]"
    die 3 "stage: coverage self-check failed — the gap set is not exactly the staged zone(s) (see $slog)"
  fi
  slogf "SELF-CHECK PASS: the gap set is exactly [$(printf '%s' "$want" | paste -sd, -)]"
  {
    echo "contest=$A_CONTEST"; echo "zone=$A_ZONE"; echo "arm=$A_ARM"; echo "repeat=$A_REPEAT"
    echo "base=$A_BASE"; echo "checkout=$A_CHECKOUT"; echo "checkout_commit=$commit"
    echo "profile=$A_PROFILE"; echo "profile_sha256=$(file_sha "$A_PROFILE")"; echo "staged_utc=$(utc)"
  } > "$armdir/stage.meta"
  note "stage: [$A_CONTEST $A_ZONE $A_ARM r$A_REPEAT] staged -> $armdir"
}

# M2 wrote the first 16 columns; M3 appends rehunt_rc + verdict. A MANIFEST.tsv that still carries the M2 header
# keeps getting M2-shaped rows (never a column shift under an existing header); void.txt holds the verdict there.
MANIFEST_HEADER_M2=$'contest\tzone\tarm\trepeat\tprofile\tprofile_sha256\tcheckout_commit\tmodel\tbackend\tstart\tend\trc\tdeep_start\tdeep_end\tdeep_rc\tarm_dir'
MANIFEST_HEADER="$MANIFEST_HEADER_M2"$'\trehunt_rc\tverdict'

# run state, read by the EXIT trap
R_ARMDIR=""; R_START=""; R_RC=""; R_DEEP_START="-"; R_DEEP_END="-"; R_DEEP_RC="skip"; R_COMMIT=""; R_DIRTY=""
R_CODE=""; R_ROOTS=""; R_CHILD=""; R_BREADTH_END="-"
R_REHUNT_START="-"; R_REHUNT_END="-"; R_REHUNT_RC="none"; R_REHUNT_REASON="-"

# A signal to `run` (a drive's TERM, `exam.sh kill`, Ctrl-C): stop whatever runs under the arm, never start or
# continue STAGE 4.5, and let the EXIT trap record the interrupted attempt.
run_on_signal() {
  trap '' INT TERM
  local code="$1"
  if [ -z "$R_RC" ]; then
    R_RC="$code"; R_BREADTH_END="$(utc)"; [ "$P_DEEP_PASS" != 1 ] || R_DEEP_RC="skip-killed"
  elif [ "$R_REHUNT_START" != "-" ] && [ "$R_REHUNT_END" = "-" ]; then
    R_REHUNT_RC="$code"; R_REHUNT_END="$(utc)"; [ "$P_DEEP_PASS" != 1 ] || R_DEEP_RC="skip-killed"
  elif [ "$R_DEEP_START" != "-" ] && [ "$R_DEEP_END" = "-" ]; then
    R_DEEP_RC="$code"; R_DEEP_END="$(utc)"
  fi
  echo "[run $(utc)] signalled ($code) — killing everything left under the arm dir" >> "$R_ARMDIR/run.log"
  kill_by_path "$R_ARMDIR" 0 5 >> "$R_ARMDIR/run.log" 2>&1 || true
  exit "$code"
}

run_finish() {
  local rc=$? end meta
  [ -n "$R_RC" ] || R_RC="$rc"
  end="$(utc)"
  meta="$R_ARMDIR/run.meta"
  {
    echo "contest=$A_CONTEST"; echo "zone=$A_ZONE"; echo "arm=$A_ARM"; echo "repeat=$A_REPEAT"
    echo "start=$R_START"; echo "end=$end"; echo "rc=$R_RC"; echo "breadth_end=$R_BREADTH_END"
    echo "rehunt_start=$R_REHUNT_START"; echo "rehunt_end=$R_REHUNT_END"; echo "rehunt_rc=$R_REHUNT_RC"
    echo "rehunt_reason=$R_REHUNT_REASON"
    echo "deep_start=$R_DEEP_START"; echo "deep_end=$R_DEEP_END"; echo "deep_rc=$R_DEEP_RC"
    echo "base=$A_BASE"; echo "code=$R_CODE"; echo "project_roots=$R_ROOTS"
    echo "checkout=$A_CHECKOUT"; echo "checkout_commit=$R_COMMIT"; echo "checkout_dirty=$R_DIRTY"
    echo "backend=$P_BACKEND"; echo "model=${P_MODEL:--}"; echo "jobs=$P_JOBS"; echo "deep_jobs=$P_DEEP_JOBS"
    echo "hard_stop_s=$P_HARD_STOP_S"; echo "deep_pass=$P_DEEP_PASS"; echo "scope_docs=${P_SCOPE_DOCS:--}"
    echo "rehunt_transport=$P_REHUNT_TRANSPORT"; echo "attrib_family=${P_ATTRIB_FAMILY:--}"
    echo "env_knobs=$(printf '%s\n' ${ENV_KV[@]+"${ENV_KV[@]}"} | paste -sd' ' -)"
    echo "deep_knobs=$(printf '%s\n' ${DEEP_KV[@]+"${DEEP_KV[@]}"} | paste -sd' ' -)"
    echo "pass_knobs=$(printf '%s\n' ${PASS_NAMES[@]+"${PASS_NAMES[@]}"} | paste -sd' ' -)"
    echo "profile=$(basename "$A_PROFILE")"; echo "profile_sha256=$(file_sha "$A_PROFILE")"
    echo "breadth_env=$(paste -sd';' "$R_ARMDIR/breadth.env" 2>/dev/null)"
    echo "deep_env=$(paste -sd';' "$R_ARMDIR/deep.env" 2>/dev/null)"
    echo "env_cleared=$(grep -c . "$R_ARMDIR/env.cleared" 2>/dev/null || echo 0)"
    echo "env_cleared_set=$(paste -sd' ' "$R_ARMDIR/env.cleared-set" 2>/dev/null)"
  } > "$meta.tmp" && mv "$meta.tmp" "$meta"
  # M3: attribution over the run window, then the VOID verdict — both before the MANIFEST row and .done, so a
  # finished arm always carries them.
  arm_attrib "$R_ARMDIR" "$HOME/.claude/projects" >> "$R_ARMDIR/run.log" 2>&1 \
    || echo "[run $(utc)] attribution failed (void-check reads a missing attrib.tsv as VOID attribution)" >> "$R_ARMDIR/run.log"
  local verdict; verdict="$(arm_void_refresh "$R_ARMDIR")"
  local mf="$A_ROOT/MANIFEST.tsv" row
  [ -s "$mf" ] || printf '%s\n' "$MANIFEST_HEADER" > "$mf"
  row="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
    "$A_CONTEST" "$A_ZONE" "$A_ARM" "$A_REPEAT" "$(basename "$A_PROFILE")" "$(file_sha "$A_PROFILE")" "$R_COMMIT" \
    "${P_MODEL:--}" "$P_BACKEND" "$R_START" "$end" "$R_RC" "$R_DEEP_START" "$R_DEEP_END" "$R_DEEP_RC" \
    "arms/$A_CONTEST/$A_ZONE/$A_ARM-r$A_REPEAT")"
  if [ "$(head -1 "$mf")" = "$MANIFEST_HEADER_M2" ]; then
    printf '%s\n' "$row" >> "$mf"
  else
    printf '%s\t%s\t%s\n' "$row" "$R_REHUNT_RC" "$(verdict_word "$verdict")" >> "$mf"
  fi
  printf 'rc=%s\tdeep=%s\tend=%s\tvoid=%s\n' "$R_RC" "$R_DEEP_RC" "$end" "$(verdict_word "$verdict")" > "$R_ARMDIR/.done"
  if [ "$(head -1 "$R_ARMDIR/run.pid" 2>/dev/null)" = "$$" ]; then rm -f "$R_ARMDIR/run.pid"; fi
  note "run: [$A_CONTEST $A_ZONE $A_ARM r$A_REPEAT] END rc=$R_RC rehunt=$R_REHUNT_RC deep=$R_DEEP_RC $(verdict_word "$verdict") -> $R_ARMDIR"
}

cmd_run() {
  parse_arm_args run "$@"
  local cdir="$A_BASE/$A_CONTEST" df="$A_CHECKOUT/dark-factory"
  R_ARMDIR="$(arm_dir "$A_ROOT" "$A_CONTEST" "$A_ZONE" "$A_ARM" "$A_REPEAT")"
  local out="$R_ARMDIR/$A_CONTEST/zone-hunt-out"
  [ -f "$out/map/zones.json" ] && [ -f "$out/coverage/zone-coverage.json" ] && [ -d "$out/briefs/briefs" ] \
    || die 3 "run: $R_ARMDIR is not staged (exam.sh stage first)"
  if arm_live "$R_ARMDIR"; then
    die 3 "run: $R_ARMDIR has a LIVE run (pid $(head -1 "$R_ARMDIR/run.pid")) — refusing a second writer"
  fi
  [ ! -e "$R_ARMDIR/.done" ] || die 3 "run: $R_ARMDIR already ran (.done)"
  [ -f "$cdir/freeze.meta" ] || die 3 "run: $cdir is not frozen"
  local code_rel; code_rel="$(meta_get "$cdir/freeze.meta" code_dir_rel)"
  R_ROOTS="$(meta_get "$cdir/freeze.meta" project_roots)"; [ -n "$R_ROOTS" ] || R_ROOTS="-"
  R_CODE="$cdir/code"; [ -z "$code_rel" ] || [ "$code_rel" = . ] || R_CODE="$cdir/code/$code_rel"
  [ -d "$R_CODE" ] || die 3 "run: code dir $R_CODE missing"
  load_profile "$A_PROFILE"
  need_sandbox
  clear_knobs "$A_PROFILE" "$df" "$R_ARMDIR/env.cleared"
  # the names the caller's shell actually carried and this run dropped (names only, never values)
  local _n; while IFS= read -r _n; do [ -z "${!_n+x}" ] || printf '%s\n' "$_n"; done < "$R_ARMDIR/env.cleared" \
    > "$R_ARMDIR/env.cleared-set"
  # Ground truth must be invisible to the hunt: neither the repo root it is pointed at nor its --out may hold a
  # truth.tsv or a judging/ (stage keeps them in the sibling _gt/ view).
  local gt_leak; gt_leak="$(find "$R_CODE" "$out" \( -name truth.tsv -o -name judging \) -print 2>/dev/null | head -3)"
  [ -z "$gt_leak" ] || die 3 "run: ground truth is visible to the hunt: $(printf '%s' "$gt_leak" | paste -sd' ' -)"
  local scope_docs=""
  case "$P_SCOPE_DOCS" in
    "") ;;
    auto) scope_docs=auto ;;
    code:*) scope_docs="$cdir/code/${P_SCOPE_DOCS#code:}"
            [ -f "$scope_docs" ] || die 3 "run: SCOPE_DOCS file $scope_docs missing" ;;
  esac
  R_COMMIT="$(git -C "$A_CHECKOUT" rev-parse HEAD 2>/dev/null || echo unknown)"
  if [ -n "$(git -C "$A_CHECKOUT" status --porcelain 2>/dev/null)" ]; then
    R_DIRTY=yes; note "run: WARNING the checkout is dirty (recorded in run.meta)"
  else
    R_DIRTY=no
  fi
  local -a common=(--repo "$R_CODE" --out "$out" --backend "$P_BACKEND" --agentis "$A_AGENTIS")
  [ -z "$P_MODEL" ] || common+=(--model "$P_MODEL")
  case "$R_ROOTS" in -|auto) ;; *) common+=(--project-roots "$R_ROOTS") ;; esac
  local -a breadth=(--rehunt-gaps --jobs "$P_JOBS")
  [ -z "$scope_docs" ] || breadth+=(--scope-docs "$scope_docs")

  echo "$$" > "$R_ARMDIR/run.pid"
  trap run_finish EXIT
  trap 'run_on_signal 130' INT
  trap 'run_on_signal 143' TERM
  R_START="$(utc)"
  effective_env "$R_ARMDIR/env.cleared" ${ENV_KV[@]+"${ENV_KV[@]}"} > "$R_ARMDIR/breadth.env"
  echo "[run $R_START] breadth: env -u <$((${#CLEAR_ARGS[@]} / 2)) cleared> ${ENV_KV[*]+${ENV_KV[*]}} timeout $P_HARD_STOP_S run-zone-hunt.sh ${common[*]} ${breadth[*]}" >> "$R_ARMDIR/run.log"
  # Background + wait: a TERM / INT reaches run_on_signal at once instead of after the whole breadth pass.
  (cd "$df" && exec env ${CLEAR_ARGS[@]+"${CLEAR_ARGS[@]}"} ${ENV_KV[@]+"${ENV_KV[@]}"} timeout "$P_HARD_STOP_S" \
      bash run-zone-hunt.sh "${common[@]}" "${breadth[@]}") >> "$R_ARMDIR/run.log" 2>&1 &
  R_CHILD=$!
  wait "$R_CHILD"; R_RC=$?; R_CHILD=""; R_BREADTH_END="$(utc)"
  if [ "$R_RC" -eq 124 ] || [ "$R_RC" -ge 128 ]; then
    echo "[run $(utc)] breadth $( [ "$R_RC" -eq 124 ] && echo "HARD STOP after ${P_HARD_STOP_S}s" || echo "KILLED (rc $R_RC)") — killing what is left under the arm dir" >> "$R_ARMDIR/run.log"
    kill_by_path "$R_ARMDIR" 0 10 >> "$R_ARMDIR/run.log" 2>&1 || true
  fi
  # M3 one-shot RE-HUNT (the README's symmetry rule): a final-attempt cell still failed (.timeout / .novalid) or
  # carrying a terminal transport error gets exactly ONE more breadth pass IN THIS ARM — never when a usage-limit
  # notice matched (that pass would void too), never after a hard stop / kill, never twice.
  local rstop=""
  if [ "$R_RC" -eq 124 ]; then R_REHUNT_RC="skip-hard-stop"
  elif [ "$R_RC" -ge 128 ]; then R_REHUNT_RC="skip-killed"
  else
    local rchk rcrc
    rchk="$(python3 "$HELPER" rehunt-check "$out" "$PATTERNS" 2>&1)"; rcrc=$?
    R_REHUNT_REASON="$(printf '%s' "$rchk" | head -1 | tr '\t' ' ')"; [ -n "$R_REHUNT_REASON" ] || R_REHUNT_REASON="-"
    if [ "$rcrc" -eq 1 ]; then R_REHUNT_RC="none"
    elif [ "$rcrc" -eq 4 ]; then R_REHUNT_RC="skip-weekly-limit"; rstop="weekly-limit"
    elif [ "$rcrc" -ne 0 ]; then R_REHUNT_RC="skip-check-error"
    elif [ "$P_REHUNT_TRANSPORT" != 1 ]; then R_REHUNT_RC="skip-off"
    else
      R_REHUNT_START="$(utc)"
      echo "[rehunt $R_REHUNT_START] ($R_REHUNT_REASON) env -u <cleared> ${ENV_KV[*]+${ENV_KV[*]}} timeout $P_HARD_STOP_S run-zone-hunt.sh ${common[*]} ${breadth[*]} --rehunt-include-partial --rehunt-max-attempts 2" >> "$R_ARMDIR/rehunt.log"
      (cd "$df" && exec env ${CLEAR_ARGS[@]+"${CLEAR_ARGS[@]}"} ${ENV_KV[@]+"${ENV_KV[@]}"} timeout "$P_HARD_STOP_S" \
          bash run-zone-hunt.sh "${common[@]}" "${breadth[@]}" --rehunt-include-partial --rehunt-max-attempts 2) >> "$R_ARMDIR/rehunt.log" 2>&1 &
      R_CHILD=$!
      wait "$R_CHILD"; R_REHUNT_RC=$?; R_CHILD=""; R_REHUNT_END="$(utc)"
      if [ "$R_REHUNT_RC" -eq 124 ] || [ "$R_REHUNT_RC" -ge 128 ]; then
        echo "[rehunt $(utc)] re-hunt stopped (rc $R_REHUNT_RC) — killing what is left under the arm dir" >> "$R_ARMDIR/rehunt.log"
        kill_by_path "$R_ARMDIR" 0 10 >> "$R_ARMDIR/rehunt.log" 2>&1 || true
        rstop="$R_REHUNT_RC"
      fi
    fi
  fi
  if [ "$P_DEEP_PASS" = 1 ]; then
    if [ "$R_RC" -eq 124 ] || [ "$rstop" = 124 ]; then
      R_DEEP_RC="skip-hard-stop"
    elif [ "$rstop" = weekly-limit ]; then
      R_DEEP_RC="skip-weekly-limit"   # the usage limit would void STAGE 4.5 too
    elif [ "$R_RC" -ge 128 ] || [ -n "$rstop" ]; then
      R_DEEP_RC="skip-killed"
    elif [ ! -f "$out/verify/verified_findings.json" ]; then
      R_DEEP_RC="skip-no-verify"
    else
      R_DEEP_START="$(utc)"
      effective_env "$R_ARMDIR/env.cleared" ${DEEP_KV[@]+"${DEEP_KV[@]}"} > "$R_ARMDIR/deep.env"
      echo "[deep $R_DEEP_START] env -u <cleared> ${DEEP_KV[*]+${DEEP_KV[*]}} timeout $P_HARD_STOP_S run-zone-hunt.sh ${common[*]} --deep-hunt --deep-hunt-only --jobs $P_DEEP_JOBS" >> "$R_ARMDIR/deep.log"
      (cd "$df" && exec env ${CLEAR_ARGS[@]+"${CLEAR_ARGS[@]}"} ${DEEP_KV[@]+"${DEEP_KV[@]}"} timeout "$P_HARD_STOP_S" \
          bash run-zone-hunt.sh "${common[@]}" --deep-hunt --deep-hunt-only --jobs "$P_DEEP_JOBS") >> "$R_ARMDIR/deep.log" 2>&1 &
      R_CHILD=$!
      wait "$R_CHILD"; R_DEEP_RC=$?; R_CHILD=""
      R_DEEP_END="$(utc)"
      if [ "$R_DEEP_RC" -eq 124 ] || [ "$R_DEEP_RC" -ge 128 ]; then
        echo "[deep $(utc)] STAGE 4.5 stopped (rc $R_DEEP_RC) — killing what is left under the arm dir" >> "$R_ARMDIR/deep.log"
        kill_by_path "$R_ARMDIR" 0 10 >> "$R_ARMDIR/deep.log" 2>&1 || true
      fi
    fi
  fi
  [ "$R_RC" -eq 0 ] || exit "$R_RC"
  case "$R_REHUNT_RC" in ''|*[!0-9]*|0) ;; *) exit "$R_REHUNT_RC" ;; esac
  case "$R_DEEP_RC" in ''|*[!0-9]*|0) exit 0 ;; *) exit "$R_DEEP_RC" ;; esac
}

# ----------------------------------------------------------------------------------------------------------
# M3: run-window attribution + VOID verdict
# ----------------------------------------------------------------------------------------------------------
# arm_attrib <arm-dir> <transcripts-root> — attrib.tsv for one arm, every stage over its own window from run.meta.
arm_attrib() {
  local arm="$1" troot="$2" meta="$1/run.meta" backend model fam out s e be ds de
  [ -f "$meta" ] || { echo "attrib: $arm has no run.meta" >&2; return 3; }
  backend="$(meta_get "$meta" backend)"; model="$(meta_get "$meta" model)"; fam="$(meta_get "$meta" attrib_family)"
  out="$arm/$(meta_get "$meta" contest)/zone-hunt-out"
  [ "$backend" != mock ] || model="-"
  [ -n "$model" ] || model="-"
  s="$(meta_get "$meta" start)"; e="$(meta_get "$meta" end)"
  be="$(meta_get "$meta" rehunt_end)"
  case "$be" in ''|-) be="$(meta_get "$meta" breadth_end)" ;; esac
  case "$be" in ''|-) be="$e" ;; esac
  ds="$(meta_get "$meta" deep_start)"; de="$(meta_get "$meta" deep_end)"
  case "$ds" in ''|-) ds="$s"; de="$e" ;; esac
  case "$de" in ''|-) de="$e" ;; esac
  local -a famarg=(); case "$fam" in ''|-) ;; *) famarg=(--family "$fam") ;; esac
  python3 "$HELPER" attrib --root "$out" --transcripts-root "$troot" --model "$model" ${famarg[@]+"${famarg[@]}"} \
    --tsv "$arm/attrib.tsv" --stage "discovery=$s,$be" --stage "verify=$s,$be" --stage "deep-hunt=$ds,$de" \
    --other "$s,$e" --exclude map --exclude briefs --exclude coverage
}

# arm_void_refresh <arm-dir> — (re)compute void.txt; prints its line (`VALID` or `VOID<TAB>class<TAB>ref`).
arm_void_refresh() {
  python3 "$HELPER" void-check "$1" "$PATTERNS" 2>/dev/null || printf 'VOID\tincomplete\tvoid-check failed\n'
}

# arm_void <arm-dir> — void.txt's line, computed first when an arm (e.g. an M2-era one) has none.
arm_void() {
  if [ -s "$1/void.txt" ]; then head -1 "$1/void.txt"; else arm_void_refresh "$1"; fi
}

# verdict_word <void line> -> `VALID` / `VOID:<class>`; void_class <void line> -> `<class>` (empty when VALID).
verdict_word() { case "$1" in VALID*) echo VALID ;; *) printf 'VOID:%s\n' "$(printf '%s' "$1" | cut -f2)" ;; esac; }
void_class()   { case "$1" in VALID*) echo "" ;; *) printf '%s\n' "$1" | cut -f2 ;; esac; }

cmd_attrib() {
  local arm="" troot="$HOME/.claude/projects"
  while [ $# -gt 0 ]; do
    case "$1" in
      --arm-dir) need_val "$#" "$1"; arm="$2"; shift 2 ;;
      --transcripts-root) need_val "$#" "$1"; troot="$2"; shift 2 ;;
      *) die 2 "attrib: unknown flag $1" ;;
    esac
  done
  [ -n "$arm" ] || die 2 "attrib: --arm-dir <dir> required"
  command -v python3 >/dev/null 2>&1 || die 3 "python3 is required"
  arm="$(abs_dir "$arm")" || die 3 "attrib: --arm-dir not found"
  [ -f "$arm/run.meta" ] || die 3 "attrib: $arm has no run.meta (not a run arm)"
  arm_attrib "$arm" "$troot" || die 3 "attrib: attribution failed"
  cat "$arm/attrib.tsv"
  if [ -f "$arm/.done" ]; then note "attrib: void.txt -> $(arm_void_refresh "$arm" | tr '\t' ' ')"; fi
}

cmd_void_mark() {
  local arm="" reason=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --arm-dir) need_val "$#" "$1"; arm="$2"; shift 2 ;;
      --reason) need_val "$#" "$1"; reason="$2"; shift 2 ;;
      *) die 2 "void-mark: unknown flag $1" ;;
    esac
  done
  [ -n "$arm" ] && [ -n "$reason" ] || die 2 "void-mark: --arm-dir <dir> --reason <text> are required"
  case "$reason" in *$'\t'*|*$'\n'*) die 2 "void-mark: --reason must be one line without tabs" ;; esac
  command -v python3 >/dev/null 2>&1 || die 3 "python3 is required"
  arm="$(abs_dir "$arm")" || die 3 "void-mark: --arm-dir not found"
  [ -f "$arm/run.meta" ] || die 3 "void-mark: $arm has no run.meta (not a run arm)"
  if arm_live "$arm"; then die 3 "void-mark: $arm has a LIVE run — stop it first (exam.sh kill --path $arm)"; fi
  printf '%s (marked %s)\n' "$reason" "$(utc)" > "$arm/void.operator"
  arm_void_refresh "$arm"
}

# ----------------------------------------------------------------------------------------------------------
# triage hand-off
# ----------------------------------------------------------------------------------------------------------
cmd_triage() {
  local root="" contest="" arm="" repeat=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) need_val "$#" "$1"; root="$2"; shift 2 ;;
      --contest) need_val "$#" "$1"; contest="$2"; shift 2 ;;
      --arm) need_val "$#" "$1"; arm="$2"; shift 2 ;;
      --repeat) need_val "$#" "$1"; repeat="$2"; shift 2 ;;
      *) die 2 "triage: unknown flag $1" ;;
    esac
  done
  [ -n "$root" ] && [ -n "$contest" ] && [ -n "$arm" ] && [ -n "$repeat" ] || die 2 "triage: --root --contest --arm --repeat are required"
  safe_id "$contest" && safe_id "$arm" && pos_int "$repeat" || die 2 "triage: bad contest / arm / repeat"
  root="$(abs_dir "$root")" || die 3 "triage: --root not found"
  [ -f "$TRIAGE" ] || die 3 "triage: triage.py not found next to exam/"
  local d base="" zone v
  local -a runs=() unmeasured=()
  for d in "$root/arms/$contest"/*/"$arm-r$repeat"; do
    [ -f "$d/.done" ] && [ -f "$d/run.meta" ] || continue
    zone="$(basename "$(dirname "$d")")"
    [ -n "$base" ] || base="$(meta_get "$d/run.meta" base)"
    v="$(arm_void "$d")"
    if [ "$v" = VALID ]; then
      [ -d "$d/$contest/zone-hunt-out/discovery" ] && runs+=(--run "$zone=$d/$contest/zone-hunt-out")
    elif [ "$zone" != _all ]; then
      unmeasured+=(--unmeasured "$zone:$(void_class "$v")")
    fi
  done
  if [ "${#runs[@]}" -eq 0 ]; then note "triage: no finished, measurable arm for $contest $arm r$repeat"; return 0; fi
  local cdir="$base/$contest"
  [ -f "$cdir/map/zones.json" ] && [ -f "$cdir/truth.tsv" ] || die 3 "triage: the frozen base $cdir is gone"
  mkdir -p "$root/triage"
  local stem="$root/triage/$contest-$arm-r$repeat"
  python3 "$TRIAGE" --truth "$cdir/truth.tsv" "${runs[@]}" --zones-json "$cdir/map/zones.json" \
    --scope "$cdir/map/scope.tsv" ${unmeasured[@]+"${unmeasured[@]}"} --tsv "$stem.tsv" --md "$stem.md" \
    || die 3 "triage: triage.py failed"
  note "triage: $contest $arm r$repeat -> $stem.{tsv,md}"
}

# ----------------------------------------------------------------------------------------------------------
# drive
# ----------------------------------------------------------------------------------------------------------
# 0 when the lock names a live driver process (not a zombie, an exam.sh command line).
lock_live() {
  local lock="$1" pid
  [ -f "$lock" ] || return 1
  pid="$(head -1 "$lock" 2>/dev/null)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  ps -ww -eo pid=,stat=,args= | awk -v p="$pid" '$1 == p && $2 !~ /^Z/ && /exam\.sh/ { f = 1 } END { exit f ? 0 : 1 }'
}

# A TERM / INT to the driver stops the row it is running: the `run` child is its own process group (setsid),
# so the whole group gets TERM, and the driver waits for run's own cleanup (run_on_signal) before it exits.
D_CHILD=""; D_ROW=""; D_PROG=""
drive_on_signal() {
  trap '' INT TERM
  local code="$1"
  if [ -n "$D_CHILD" ]; then
    kill -TERM -- "-$D_CHILD" 2>/dev/null || true
    kill -TERM "$D_CHILD" 2>/dev/null || true
    wait "$D_CHILD" 2>/dev/null || true
    printf '%s\tEND\t%s\trc=drive-signalled-%s\tdeep=skip\n' "$(utc)" "$D_ROW" "$code" >> "$D_PROG"
  fi
  note "drive: signalled ($code) — stopped the running row, exiting"
  exit "$code"
}

cmd_drive() {
  local root="" plan="" resume=0 retry_void=0 agentis="agentis" orig=("$@")
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) need_val "$#" "$1"; root="$2"; shift 2 ;;
      --plan) need_val "$#" "$1"; plan="$2"; shift 2 ;;
      --resume) resume=1; shift ;;
      --retry-void) retry_void=1; resume=1; shift ;;
      --agentis) need_val "$#" "$1"; agentis="$2"; shift 2 ;;
      *) die 2 "drive: unknown flag $1" ;;
    esac
  done
  [ -n "$root" ] && [ -n "$plan" ] || die 2 "drive: --root and --plan are required"
  [ -f "$plan" ] || die 2 "drive: plan not found: $plan"
  need_platform
  command -v setsid >/dev/null 2>&1 || die 3 "drive: setsid (util-linux) is required"
  mkdir -p "$root/logs" || die 3 "drive: cannot create $root/logs"
  root="$(abs_dir "$root")"
  local pname; pname="$(basename "$plan")"; pname="${pname%.tsv}"
  safe_id "$pname" || die 2 "drive: the plan file name '$pname' is not a safe label"
  local logs="$root/logs" lock="$root/logs/$pname.lock"
  if [ "${EXAM_FROM_SNAPSHOT:-}" != 1 ]; then
    if lock_live "$lock"; then die 3 "drive: plan '$pname' is already driven by pid $(head -1 "$lock")"; fi
    local snap; snap="$logs/$pname.snapshot-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "$snap/exam" || die 3 "drive: cannot create the snapshot"
    cp "$SELF" "$HELPER" "$PATTERNS" "$snap/exam/" && cp -R "$PROFILES_DIR" "$snap/exam/profiles" \
      && cp "$TRIAGE" "$ATTRIB_PY" "$CB_DIR/score-match.py" "$CB_DIR/hypotheses-to-leads.py" "$snap/" \
      || die 3 "drive: snapshot copy failed"
    note "drive: re-exec from the snapshot $snap"
    EXAM_FROM_SNAPSHOT=1 exec bash "$snap/exam/exam.sh" drive "${orig[@]}"
  fi
  if ! (set -o noclobber; echo "$$" > "$lock") 2>/dev/null; then
    if lock_live "$lock"; then die 3 "drive: plan '$pname' is already driven by pid $(head -1 "$lock")"; fi
    note "drive: removing the stale lock (pid $(head -1 "$lock" 2>/dev/null) is gone)"
    rm -f "$lock"
    (set -o noclobber; echo "$$" > "$lock") 2>/dev/null || die 3 "drive: lost the lock race for '$pname'"
  fi
  # shellcheck disable=SC2064  # expand now: the lock path and this pid are fixed for the driver's lifetime
  trap "[ \"\$(head -1 '$lock' 2>/dev/null)\" = '$$' ] && rm -f '$lock'" EXIT

  # Validate the whole plan before anything is spent.
  local -a R_C=() R_Z=() R_A=() R_N=() R_P=() R_K=() R_B=()
  local c z a n p k b extra line_no=0
  while IFS=$'\t' read -r c z a n p k b extra; do
    line_no=$((line_no + 1))
    case "$c" in ''|'#'*) continue ;; esac
    [ -n "$b" ] && [ -z "$extra" ] || die 2 "drive: $plan:$line_no: expected 7 TAB columns (contest zone arm repeat profile checkout base)"
    safe_id "$c" && safe_id "$a" && pos_int "$n" && { [ "$z" = _all ] || safe_id "$z"; } \
      || die 2 "drive: $plan:$line_no: bad contest / zone / arm / repeat"
    [ -d "$k" ] && [ -f "$b/$c/freeze.meta" ] || die 2 "drive: $plan:$line_no: checkout or frozen base missing"
    k="$(abs_dir "$k")"; b="$(abs_dir "$b")"
    resolve_profile "$p" > /dev/null || exit 2
    if [ "$resume" -eq 0 ] && [ -e "$(arm_dir "$root" "$c" "$z" "$a" "$n")" ]; then
      die 2 "drive: $plan:$line_no: $(arm_dir "$root" "$c" "$z" "$a" "$n") exists — use --resume"
    fi
    R_C+=("$c"); R_Z+=("$z"); R_A+=("$a"); R_N+=("$n"); R_P+=("$p"); R_K+=("$k"); R_B+=("$b")
  done < "$plan"
  [ "${#R_C[@]}" -gt 0 ] || die 2 "drive: the plan has no rows"

  local prog="$logs/$pname.progress" dlog="$logs/$pname.log" heads="$logs/$pname.heads" halted="$logs/$pname.halted"
  touch "$heads"
  D_PROG="$prog"
  if [ -f "$halted" ]; then
    printf '%s\tUNHALT\tprevious halt: %s\n' "$(utc)" "$(head -1 "$halted" | tr '\t' ' ')" >> "$prog"
    rm -f "$halted"
  fi
  trap 'drive_on_signal 143' TERM
  trap 'drive_on_signal 130' INT
  local i armdir head pinned src rrc rc drc v vc vk ran=0 skipped=0 refused=0 voided=0 halt=""
  for i in "${!R_C[@]}"; do
    c="${R_C[$i]}"; z="${R_Z[$i]}"; a="${R_A[$i]}"; n="${R_N[$i]}"; p="${R_P[$i]}"; k="${R_K[$i]}"; b="${R_B[$i]}"
    armdir="$(arm_dir "$root" "$c" "$z" "$a" "$n")"
    if arm_live "$armdir"; then
      printf '%s\tEND\t%s\t%s\t%s\tr%s\trc=refused-live-run\tdeep=skip\n' "$(utc)" "$c" "$z" "$a" "$n" >> "$prog"
      note "drive: REFUSED $c $z $a r$n — its run (pid $(head -1 "$armdir/run.pid")) is still alive; stop it first (exam.sh kill --path $armdir)"
      refused=$((refused + 1)); continue
    fi
    if [ "$resume" -eq 1 ] && [ -f "$armdir/.done" ]; then
      # M3: a row is COMPLETE only when it is VALID + .done. A VOID row is re-run only through --retry-void,
      # which keeps the void attempt as <arm>-r<N>.void-<k> (evidence, never deleted).
      v="$(arm_void "$armdir")"; vc="$(void_class "$v")"
      if [ -z "$vc" ]; then
        printf '%s\tSKIP\t%s\t%s\t%s\tr%s\tdone\n' "$(utc)" "$c" "$z" "$a" "$n" >> "$prog"
        skipped=$((skipped + 1)); continue
      fi
      if [ "$retry_void" -ne 1 ]; then
        printf '%s\tSKIP\t%s\t%s\t%s\tr%s\tvoid=%s (drive --retry-void re-runs it)\n' "$(utc)" "$c" "$z" "$a" "$n" "$vc" >> "$prog"
        skipped=$((skipped + 1)); continue
      fi
      vk=1; while [ -e "$armdir.void-$vk" ]; do vk=$((vk + 1)); done
      mv "$armdir" "$armdir.void-$vk" || die 3 "drive: cannot move the VOID arm $armdir aside"
      printf '%s\tRETRY\t%s\t%s\t%s\tr%s\tvoid=%s kept as %s\n' "$(utc)" "$c" "$z" "$a" "$n" "$vc" "$(basename "$armdir").void-$vk" >> "$prog"
    fi
    head="$(git -C "$k" rev-parse HEAD 2>/dev/null || echo unknown)"
    pinned="$(awk -F'\t' -v k="$k" '$1 == k { print $2; exit }' "$heads")"
    if [ -n "$pinned" ] && [ "$pinned" != "$head" ]; then
      printf '%s\tEND\t%s\t%s\t%s\tr%s\trc=refused-head-moved\tdeep=skip\n' "$(utc)" "$c" "$z" "$a" "$n" >> "$prog"
      note "drive: REFUSED $c $z $a r$n — checkout $k moved from $pinned to $head since this plan pinned it"
      refused=$((refused + 1)); continue
    fi
    [ -n "$pinned" ] || printf '%s\t%s\n' "$k" "$head" >> "$heads"
    printf '%s\tSTART\t%s\t%s\t%s\tr%s\n' "$(utc)" "$c" "$z" "$a" "$n" >> "$prog"
    bash "$SELF" stage --root "$root" --base "$b" --contest "$c" --zone "$z" --arm "$a" --repeat "$n" \
      --profile "$p" --checkout "$k" >> "$dlog" 2>&1
    src=$?
    if [ "$src" -ne 0 ]; then
      printf '%s\tEND\t%s\t%s\t%s\tr%s\trc=stage-%s\tdeep=skip\n' "$(utc)" "$c" "$z" "$a" "$n" "$src" >> "$prog"
      continue
    fi
    D_ROW="$(printf '%s\t%s\t%s\tr%s' "$c" "$z" "$a" "$n")"
    setsid bash "$SELF" run --root "$root" --base "$b" --contest "$c" --zone "$z" --arm "$a" --repeat "$n" \
      --profile "$p" --checkout "$k" --agentis "$agentis" >> "$dlog" 2>&1 &
    D_CHILD=$!
    wait "$D_CHILD"; rrc=$?; D_CHILD=""
    rc="$(meta_get "$armdir/run.meta" rc)"; drc="$(meta_get "$armdir/run.meta" deep_rc)"
    # run's EXIT trap wrote void.txt; a run killed too hard for its trap gets one here.
    v="$(arm_void "$armdir")"; vc="$(void_class "$v")"
    printf '%s\tEND\t%s\t%s\t%s\tr%s\trc=%s\tdeep=%s\tvoid=%s\n' "$(utc)" "$c" "$z" "$a" "$n" "${rc:-$rrc}" "${drc:-skip}" "${vc:-VALID}" >> "$prog"
    ran=$((ran + 1))
    [ -z "$vc" ] || voided=$((voided + 1))
    if [ "$vc" = weekly-limit ]; then
      # Every row behind this one would void too: HALT the plan, leave the rest unstarted.
      halt="$(printf '%s\t%s\t%s\tr%s\t%s' "$c" "$z" "$a" "$n" "$(printf '%s' "$v" | cut -f3)")"
      printf '%s\t%s\n' "$(utc)" "$halt" > "$halted"
      rm -f "$logs/$pname.done"
      printf '%s\tHALT\t%s\n' "$(utc)" "$halt" >> "$prog"
      note "drive: HALTED on a usage-limit VOID ($c $z $a r$n) — the rows behind it are left unstarted; after the reset: drive --retry-void"
      break
    fi
  done

  # The triage hand-off: one table per (contest, arm, repeat) of the plan.
  local g seen=" "
  for i in "${!R_C[@]}"; do
    g="${R_C[$i]}|${R_A[$i]}|${R_N[$i]}"
    case "$seen" in *" $g "*) continue ;; esac
    seen="$seen$g "
    bash "$SELF" triage --root "$root" --contest "${R_C[$i]}" --arm "${R_A[$i]}" --repeat "${R_N[$i]}" >> "$dlog" 2>&1 \
      || note "drive: triage hand-off failed for ${R_C[$i]} ${R_A[$i]} r${R_N[$i]} (see $dlog)"
  done
  if [ -n "$halt" ]; then
    note "drive: plan '$pname' HALTED (ran=$ran voided=$voided skipped=$skipped refused=$refused) -> $halted"
    exit 6
  fi
  printf '%s\tDONE\tran=%s\tskipped=%s\trefused=%s\tvoid=%s\n' "$(utc)" "$ran" "$skipped" "$refused" "$voided" > "$logs/$pname.done"
  note "drive: plan '$pname' done (ran=$ran voided=$voided skipped=$skipped refused=$refused) -> $prog"
}

# ----------------------------------------------------------------------------------------------------------
# self-test (offline; fixtures/exam/ + the stub agentis + --backend mock)
# ----------------------------------------------------------------------------------------------------------
cmd_self_test() {
  need_platform
  local fix="$CB_DIR/fixtures/exam" df_real work
  df_real="$(cd "$CB_DIR/../.." && pwd)"
  for f in project/foundry.toml zones.fixture.txt briefs.fixture.txt truth.tsv agentis-stub.sh; do
    [ -e "$fix/$f" ] || die 3 "self-test: fixture missing: $fix/$f"
  done
  work="$(mktemp -d "${TMPDIR:-/tmp}/exam-self-test.XXXXXX")"
  work="$(cd "$work" && pwd -P)"
  ST_SLEEPER=""
  # shellcheck disable=SC2064  # expand now: the work dir is fixed
  trap "[ -z \"\${ST_SLEEPER:-}\" ] || kill -KILL \"\$ST_SLEEPER\" 2>/dev/null; rm -rf '$work'" EXIT
  export DARK_FACTORY_DIR="$work/dfdir"   # never register a hunt in the operator's ~/.dark-factory
  local fails=0
  ok()  { echo "  [OK]   $*"; }
  bad() { echo "  [FAIL] $*"; fails=$((fails + 1)); }
  expect_rc() { local want="$1" got="$2" what="$3"; if [ "$got" -eq "$want" ]; then ok "$what (exit $got)"; else bad "$what: exit $got, expected $want"; fi; }
  local stub="$fix/agentis-stub.sh" rc

  # --- a clean tool checkout: a git repo whose dark-factory/ is a symlink to this tree ---
  local co="$work/checkout"
  mkdir -p "$co" && ln -s "$df_real" "$co/dark-factory"
  git -C "$co" init -q && git -C "$co" config user.email t@example.invalid && git -C "$co" config user.name t \
    && git -C "$co" add -A && git -C "$co" commit -qm pinned || die 3 "self-test: cannot build the checkout"
  # --- a frozen-base candidate: <base>/fx/{code,truth.tsv,judging} ---
  local base="$work/base" cdir="$work/base/fx"
  mkdir -p "$cdir/judging" && cp -R "$fix/project" "$cdir/code" && cp "$fix/truth.tsv" "$cdir/truth.tsv"
  git -C "$cdir/code" init -q && git -C "$cdir/code" config user.email t@example.invalid \
    && git -C "$cdir/code" config user.name t && git -C "$cdir/code" add -A && git -C "$cdir/code" commit -qm code \
    || die 3 "self-test: cannot build the target"

  echo "exam.sh self-test: profile grammar"
  local pr
  for pr in control exam exam-plus mock; do
    python3 "$HELPER" profile-summary "$PROFILES_DIR/$pr.env" > /dev/null 2>&1; expect_rc 0 $? "shipped profile $pr parses"
  done
  printf 'BACKEND=mock\nNOPE=1\n' > "$work/p-unknown.env"
  printf 'BACKEND=mock\nenv.SEVERITY_RUBRIC=$(id)\n' > "$work/p-dollar.env"
  printf 'BACKEND=mock\nenv.severity=1\n' > "$work/p-name.env"
  printf 'BACKEND=flat-cyborg\n' > "$work/p-nomodel.env"
  printf 'BACKEND=claude\nMODEL=claude-opus-4-8\n' > "$work/p-claude.env"
  printf 'BACKEND=mock\nREHUNT_TRANSPORT=2\n' > "$work/p-rehunt.env"
  printf 'BACKEND=mock\nATTRIB_FAMILY=gpt\n' > "$work/p-family.env"
  for pr in unknown dollar name nomodel claude rehunt family; do
    python3 "$HELPER" profile "$work/p-$pr.env" > /dev/null 2>&1; expect_rc 2 $? "profile with a bad line ($pr) is refused"
  done
  printf 'BACKEND=mock\nenv.DF_NO_SANDBOX=1\n' > "$work/p-nosandbox.env"
  python3 "$HELPER" profile "$work/p-nosandbox.env" > /dev/null 2>&1; expect_rc 2 $? "a profile naming DF_NO_SANDBOX is refused"
  echo "exam.sh self-test: env clearing covers every knob the pipeline reads"
  local reads clr allow uncovered
  reads="$(python3 "$HELPER" env-reads "$df_real")"
  clr="$(python3 "$HELPER" clear-list "$df_real" "$PROFILES_DIR" "$PROFILES_DIR/mock.env")"
  allow="$(tr -s ' \t' '\n\n' < "$PROFILES_DIR/KNOBS" | sed -n 's/^!\([A-Z][A-Z0-9_]*\)$/\1/p')"
  uncovered="$(printf '%s\n' "$reads" | grep . | while IFS= read -r n; do
      printf '%s\n' "$clr" | grep -qxF "$n" && continue
      printf '%s\n' "$allow" | grep -qxF "$n" && continue
      case "$n" in CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK|CLAUDE_CODE_NO_MODEL_FALLBACK|CLAUDE_CODE_FORCE_SESSION_PERSISTENCE) continue ;; esac
      printf '%s\n' "$n"
    done)"
  if [ "$(printf '%s\n' "$reads" | grep -c .)" -ge 100 ] && [ -z "$uncovered" ]; then
    ok "every env name the pipeline reads ($(printf '%s\n' "$reads" | grep -c .)) is cleared or explicitly allowlisted (!NAME in KNOBS)"
  else
    bad "env names read by the pipeline but neither cleared nor allowlisted: $(printf '%s' "$uncovered" | paste -sd' ' - | cut -c1-300)"
  fi
  local missing="" n
  for n in DF_NO_SANDBOX FORK_URL FORK_BLOCK LLM_MAX_DISCOVERY_CELLS LLM_MAX_CONCURRENT DEEP_CELL_STALE_S FORGE_MAX_SLOTS \
           FLAT_CYBORG_IDLE_MS DF_EXTERNAL_RPC HUNT_SANDBOX_EXTERNAL SLICE_MAX_DEPTH VECTOR_HUNT_POC_RUNNER; do
    printf '%s\n' "$reads" | grep -qxF "$n" || missing="$missing $n"
  done
  if [ -z "$missing" ]; then
    ok "the derived read set holds the known leak names (DF_NO_SANDBOX, FORK_URL, LLM_MAX_DISCOVERY_CELLS, ...)"
  else
    bad "the derived env-read set misses:$missing"
  fi

  echo "exam.sh self-test: freeze"
  local bad_co="$work/bad-checkout"
  mkdir -p "$bad_co/dark-factory/auditor" && : > "$bad_co/dark-factory/map-zones.sh" && : > "$bad_co/dark-factory/gen-briefs.sh"
  printf 'a lens line naming finding %s-%s\n' M 12 > "$bad_co/dark-factory/auditor/lens.md"
  git -C "$bad_co" init -q && git -C "$bad_co" config user.email t@example.invalid && git -C "$bad_co" config user.name t \
    && git -C "$bad_co" add -A && git -C "$bad_co" commit -qm bad
  bash "$SELF" freeze --base "$base" --contest fx --checkout "$bad_co" --profile mock --code-subdir . \
    --agentis "$stub" > /dev/null 2>&1; expect_rc 3 $? "freeze refuses a checkout whose prompt-visible file carries a finding id"
  echo x > "$co/untracked.txt"
  bash "$SELF" freeze --base "$base" --contest fx --checkout "$co" --profile mock --code-subdir . \
    --agentis "$stub" > /dev/null 2>&1; expect_rc 3 $? "freeze refuses a dirty checkout"
  rm -f "$co/untracked.txt"
  bash "$SELF" freeze --base "$base" --contest fx --checkout "$co" --profile mock --code-subdir . \
    --map-fixture "$fix/zones.fixture.txt" --brief-fixture "$fix/briefs.fixture.txt" --agentis "$stub" > "$work/freeze.out" 2>&1
  rc=$?; expect_rc 0 "$rc" "freeze over the fixture"
  [ "$rc" -eq 0 ] || sed 's/^/         | /' "$work/freeze.out" | tail -15
  if [ -f "$cdir/map/zones.json" ] && [ -n "$(find "$cdir/briefs/briefs" -type f 2>/dev/null)" ] \
     && [ "$(meta_get "$cdir/freeze.meta" checkout_commit)" = "$(git -C "$co" rev-parse HEAD)" ] \
     && [ "$(meta_get "$cdir/freeze.meta" code_dir_rel)" = . ] && freeze_manifest "$cdir" | cmp -s - "$cdir/freeze.sha256"; then
    ok "freeze wrote map/ + briefs/ + freeze.sha256 + freeze.meta (checkout commit pinned)"
  else
    bad "freeze artifacts missing or wrong"
  fi
  bash "$SELF" freeze --base "$base" --contest fx --checkout "$co" --profile mock --code-subdir . \
    --map-fixture "$fix/zones.fixture.txt" --brief-fixture "$fix/briefs.fixture.txt" --agentis "$stub" > /dev/null 2>&1
  expect_rc 3 $? "a second freeze without --force is refused (the frozen base is never overwritten)"
  local cbase="$work/cbase"
  mkdir -p "$cbase/fx" && cp -R "$cdir/code" "$cdir/truth.tsv" "$cbase/fx/"
  { cat "$fix/briefs.fixture.txt"; } | sed "s/^Break invariant: \"totalAssets/Compare finding $(printf '%s-%s' H 7). Break invariant: \"totalAssets/" \
    > "$work/briefs-contaminated.txt"
  bash "$SELF" freeze --base "$cbase" --contest fx --checkout "$co" --profile mock --code-subdir . \
    --map-fixture "$fix/zones.fixture.txt" --brief-fixture "$work/briefs-contaminated.txt" --agentis "$stub" > /dev/null 2>&1
  rc=$?; expect_rc 4 "$rc" "freeze refuses briefs that carry a finding id (post-freeze contamination grep)"
  if [ ! -e "$cbase/fx/freeze.meta" ]; then ok "a contaminated freeze leaves no freeze.meta"; else bad "a contaminated freeze wrote freeze.meta"; fi

  echo "exam.sh self-test: plan"
  bash "$SELF" plan --base "$base" --contest fx --arm mock --repeat 1 --profile mock --checkout "$co" > "$work/plan.tsv" 2>/dev/null
  if [ "$(grep -vc '^#' "$work/plan.tsv")" -eq 2 ] && [ "$(awk -F'\t' '!/^#/ { print NF }' "$work/plan.tsv" | sort -u)" = 7 ]; then
    ok "plan: one 7-column row per frozen zone"
  else
    bad "plan: expected 2 rows of 7 columns"; sed 's/^/         | /' "$work/plan.tsv"
  fi
  bash "$SELF" plan --base "$base" --contest fx --arm mock --repeat 1 --profile mock --checkout "$co" --zones nope > /dev/null 2>&1
  expect_rc 2 $? "plan refuses a zone that is not in the frozen map"
  if [ "$(bash "$SELF" plan --base "$base" --contest fx --arm w --repeat 1 --profile mock --checkout "$co" --whole 2>/dev/null \
          | awk -F'\t' '!/^#/ { print $2 }')" = _all ]; then
    ok "plan --whole: one whole-contest row (zone _all)"
  else
    bad "plan --whole did not give one _all row"
  fi

  echo "exam.sh self-test: stage"
  local root="$work/root" a1
  bash "$SELF" stage --root "$root" --base "$base" --contest fx --zone src_pool --arm mock --repeat 1 --profile mock \
    --checkout "$co" > /dev/null 2>&1; expect_rc 0 $? "stage one zone"
  a1="$root/arms/fx/src_pool/mock-r1"
  if [ "$(python3 "$HELPER" zone-ids "$a1/fx/zone-hunt-out/map/zones.json")" = src_pool ]; then
    ok "stage: zones.json filtered to exactly the staged zone"
  else
    bad "stage: zones.json not filtered to src_pool"
  fi
  if cmp -s "$a1/fx/zone-hunt-out/map/scope.tsv" "$cdir/map/scope.tsv"; then
    ok "stage: a profile without INJECT_CLASSES leaves scope.tsv byte-identical"
  else
    bad "stage: scope.tsv changed without INJECT_CLASSES"
  fi
  if [ -L "$a1/fx/code" ] && [ ! -L "$a1/fx/zone-hunt-out/map" ] && grep -q 'SELF-CHECK PASS' "$a1/stage.log" \
     && [ -f "$a1/_gt/fx/truth.tsv" ] && [ -L "$a1/_gt/fx/judging" ] && [ -d "$a1/_gt/fx/zone-hunt-out/map" ] \
     && [ ! -e "$a1/fx/truth.tsv" ] && [ ! -e "$a1/fx/judging" ]; then
    ok "stage: code/ symlinked, map/ copied, truth.tsv + judging/ only in the sibling _gt/ view, self-check passed"
  else
    bad "stage: copy/symlink discipline or the coverage self-check is wrong"
  fi
  printf 'BACKEND=mock\nINJECT_CLASSES=C24,C6\n' > "$work/p-inject.env"
  bash "$SELF" stage --root "$root" --base "$base" --contest fx --zone src_pool --arm inj --repeat 1 --profile "$work/p-inject.env" \
    --checkout "$co" > /dev/null 2>&1; expect_rc 0 $? "stage with INJECT_CLASSES"
  local line1 line2
  line1="$(grep -F 'share pool | ' "$root/arms/fx/src_pool/inj-r1/fx/zone-hunt-out/map/scope.tsv")"
  python3 "$HELPER" inject-classes "$root/arms/fx/src_pool/inj-r1/fx/zone-hunt-out/map/scope.tsv" \
    "$root/arms/fx/src_pool/inj-r1/fx/zone-hunt-out/map/zones.json" C24,C6 > /dev/null
  line2="$(grep -F 'share pool | ' "$root/arms/fx/src_pool/inj-r1/fx/zone-hunt-out/map/scope.tsv")"
  if [ "$(printf '%s\n' "$line1" | awk -F' [|] ' '{ print $2 }')" = "C1,C6,C24" ] && [ "$line1" = "$line2" ]; then
    ok "stage: INJECT_CLASSES appends each class once (C6 already present) and a second injection is a no-op"
  else
    bad "stage: class injection wrong or not idempotent: '$line1' / '$line2'"
  fi
  local brief1; brief1="$(find "$cdir/briefs/briefs" -type f | head -1)"
  cp "$brief1" "$work/brief1.bak" && echo "tamper" >> "$brief1"
  bash "$SELF" stage --root "$root" --base "$base" --contest fx --zone src_feed --arm mock --repeat 1 --profile mock \
    --checkout "$co" > /dev/null 2>&1; expect_rc 3 $? "stage refuses a frozen base that drifted from freeze.sha256"
  cp "$work/brief1.bak" "$brief1"

  echo "exam.sh self-test: run (breadth + STAGE 4.5, knob hygiene)"
  export SEVERITY_RUBRIC=1   # the operator's shell carries a knob the mock profile does not set
  export STUB_ENV_DUMP="$work/env-mock.txt"
  bash "$SELF" run --root "$root" --base "$base" --contest fx --zone src_pool --arm mock --repeat 1 --profile mock \
    --checkout "$co" --agentis "$stub" > "$work/run1.out" 2>&1
  rc=$?; expect_rc 0 "$rc" "run with the mock profile"
  [ "$rc" -eq 0 ] || tail -15 "$a1/run.log" "$a1/deep.log" 2>/dev/null | sed 's/^/         | /'
  if [ "$(meta_get "$a1/run.meta" rc)" = 0 ] && [ "$(meta_get "$a1/run.meta" deep_rc)" = 0 ] && [ -f "$a1/.done" ] \
     && [ -n "$(meta_get "$a1/run.meta" start)" ] && [ -n "$(meta_get "$a1/run.meta" deep_end)" ] \
     && [ "$(meta_get "$a1/run.meta" checkout_commit)" = "$(git -C "$co" rev-parse HEAD)" ]; then
    ok "run: run.meta (start/end/rc, deep_start/deep_end/deep_rc=0, checkout commit) + .done written"
  else
    bad "run: run.meta / .done incomplete"; sed 's/^/         | /' "$a1/run.meta" 2>/dev/null
  fi
  if grep -q 'DEEP_HUNT_REACH=1 requires --deep-hunt' "$a1/run.log"; then
    bad "run: a deep.* knob leaked into the BREADTH call"
  else
    ok "run: the deep.* knobs stay out of the breadth call (DEEP_HUNT_REACH would have made it exit 2)"
  fi
  if [ "$(grep -vc '^contest' "$root/MANIFEST.tsv")" -eq 1 ] && head -1 "$root/MANIFEST.tsv" | grep -q $'^contest\tzone\tarm'; then
    ok "run: MANIFEST.tsv has its header + one row for the attempt"
  else
    bad "run: MANIFEST.tsv header/row count wrong"
  fi
  # run-discovery.sh itself passes the knob through as `SEVERITY_RUBRIC="${SEVERITY_RUBRIC:-}"` (empty = OFF), so
  # "absent" means no hunter call ever saw a non-empty value.
  if [ -s "$work/env-mock.txt" ] && ! grep -q '^SEVERITY_RUBRIC=.' "$work/env-mock.txt" \
     && grep -q '^CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK=1$' "$work/env-mock.txt"; then
    ok "knob hygiene: SEVERITY_RUBRIC=1 exported in the caller's shell never reaches the hunter (killswitches present)"
  else
    bad "knob hygiene: the hunter saw SEVERITY_RUBRIC under mock.env (or the stub never ran):" \
      "$(wc -c < "$work/env-mock.txt" 2>/dev/null) bytes, $(grep -E '^(SEVERITY_RUBRIC|CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK)=' "$work/env-mock.txt" 2>/dev/null | sort -u | paste -sd' ' -)"
  fi
  if [ -z "$(find "$(meta_get "$a1/run.meta" code)" "$a1/fx/zone-hunt-out" \( -name truth.tsv -o -name judging \) -print 2>/dev/null)" ] \
     && grep -q '^breadth_env=.*CLAUDE_CODE_NO_MODEL_FALLBACK=1' "$a1/run.meta" && grep -q '^deep_env=.*DEEP_HUNT_REACH=1' "$a1/run.meta"; then
    ok "run: the hunt's repo root and --out hold no truth.tsv / judging; run.meta records the effective breadth + deep env"
  else
    bad "run: ground truth visible to the hunt, or run.meta lacks the effective env"
  fi
  bash "$SELF" run --root "$root" --base "$base" --contest fx --zone src_pool --arm mock --repeat 1 --profile mock \
    --checkout "$co" --agentis "$stub" > /dev/null 2>&1; expect_rc 3 $? "run refuses an arm that already ran"
  if [ "$(meta_get "$a1/run.meta" rehunt_rc)" = none ] && [ -n "$(meta_get "$a1/run.meta" breadth_end)" ] \
     && [ "$(head -1 "$a1/void.txt" 2>/dev/null)" = VALID ] && grep -q $'^\\*\t.*\tskipped-mock\t' "$a1/attrib.tsv" 2>/dev/null \
     && [ "$(head -1 "$root/MANIFEST.tsv")" = "$MANIFEST_HEADER" ] \
     && [ "$(awk -F'\t' 'NR == 2 { print $(NF - 1) "|" $NF }' "$root/MANIFEST.tsv")" = "none|VALID" ] \
     && grep -q $'\tvoid=VALID$' "$a1/.done"; then
    ok "run (M3): no failed cell -> no re-hunt; attrib.tsv (skipped-mock), void.txt VALID, MANIFEST rehunt_rc + verdict, .done void="
  else
    bad "run (M3): rehunt_rc / attrib.tsv / void.txt / MANIFEST verdict wrong"
    sed 's/^/         | /' "$a1/void.txt" "$a1/attrib.tsv" 2>/dev/null; tail -2 "$root/MANIFEST.tsv" | sed 's/^/         | /'
  fi

  # Leak probe: every env name the pipeline reads (+ prefix-only names nobody listed) exported with a sentinel in the
  # caller's shell; none may reach the hunter.
  bash "$SELF" stage --root "$root" --base "$base" --contest fx --zone src_pool --arm probe --repeat 1 --profile mock \
    --checkout "$co" > /dev/null 2>&1
  (
    for n in $reads DF_FUTURE_KNOB FLAT_CYBORG_FUTURE LLM_FUTURE_CAP FORK_FUTURE MAX_THINKING_TOKENS ANTHROPIC_BASE_URL \
             ANTHROPIC_API_KEY ANTHROPIC_MODEL CLAUDE_CONFIG_DIR DISABLE_PROMPT_CACHING BASH_DEFAULT_TIMEOUT_MS \
             BASH_MAX_TIMEOUT_MS MCP_TIMEOUT; do
      case "$n" in DF_NO_SANDBOX|CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK|CLAUDE_CODE_NO_MODEL_FALLBACK|CLAUDE_CODE_FORCE_SESSION_PERSISTENCE) continue ;; esac
      printf '%s\n' "$allow" | grep -qxF "$n" && continue
      export "$n=exam-leak-probe"
    done
    export CLAUDE_CODE_OAUTH_TOKEN=exam-secret-probe   # allowlisted auth: passes, but is never recorded by value
    export STUB_ENV_DUMP="$work/env-probe.txt"
    bash "$SELF" run --root "$root" --base "$base" --contest fx --zone src_pool --arm probe --repeat 1 --profile mock \
      --checkout "$co" --agentis "$stub" > "$work/probe.out" 2>&1
  ); rc=$?
  local leaked; leaked="$(grep '=exam-leak-probe$' "$work/env-probe.txt" 2>/dev/null | cut -d= -f1 | sort -u | paste -sd' ' -)"
  if [ "$rc" -eq 0 ] && [ -s "$work/env-probe.txt" ] && [ -z "$leaked" ] \
     && ! grep -q 'exam-leak-probe' "$root/arms/fx/src_pool/probe-r1/breadth.env"; then
    ok "leak probe: $(printf '%s\n' $reads | grep -c .) pipeline env names + unlisted prefix names + Claude Code knobs exported as a sentinel never reach the hunter"
  else
    bad "leak probe: exit $rc; sentinel reached the hunter for: ${leaked:-<none, but the run failed>}"
    tail -5 "$work/probe.out" | sed 's/^/         | /'
  fi
  local pm="$root/arms/fx/src_pool/probe-r1/run.meta" qa_miss=""
  for n in FORGE_MAX_SLOTS LLM_MAX_DISCOVERY_CELLS LLM_MAX_VERIFY_GATES VECTOR_HUNT_POC_RUNNER DF_EXTERNAL_CACHE; do
    if grep -q "^$n=exam-leak-probe$" "$work/env-probe.txt" 2>/dev/null || ! grep -q "^env_cleared_set=.*\b$n\b" "$pm"; then
      qa_miss="$qa_miss $n"
    fi
  done
  if [ -z "$qa_miss" ]; then
    ok "leak probe: FORGE_MAX_SLOTS, LLM_MAX_DISCOVERY_CELLS, LLM_MAX_VERIFY_GATES, VECTOR_HUNT_POC_RUNNER, DF_EXTERNAL_CACHE exported by the caller are dropped (never reach the hunter; listed in env_cleared_set)"
  else
    bad "leak probe: not cleared or not recorded:$qa_miss"
  fi
  if grep -q '^env_cleared_set=.*MAX_THINKING_TOKENS' "$pm" && grep -q '^env_cleared_set=.*ANTHROPIC_BASE_URL' "$pm" \
     && grep -q '^env_cleared_set=.*CLAUDE_CONFIG_DIR' "$pm" && grep -q 'CLAUDE_CODE_OAUTH_TOKEN=<set>' "$pm" \
     && ! grep -rq 'exam-secret-probe' "$root/arms/fx/src_pool/probe-r1" "$root/MANIFEST.tsv"; then
    ok "run.meta records the Claude Code knobs the caller carried and dropped, and the allowlisted auth token only masked"
  else
    bad "run.meta misses the dropped Claude Code knobs or records the auth token by value"
    grep -E '^(env_cleared_set|breadth_env)=' "$pm" 2>/dev/null | cut -c1-300 | sed 's/^/         | /'
  fi
  bash "$SELF" stage --root "$root" --base "$base" --contest fx --zone src_feed --arm nosb --repeat 1 --profile mock \
    --checkout "$co" > /dev/null 2>&1
  DF_NO_SANDBOX=1 bash "$SELF" run --root "$root" --base "$base" --contest fx --zone src_feed --arm nosb --repeat 1 \
    --profile mock --checkout "$co" --agentis "$stub" > /dev/null 2>&1; rc=$?
  if [ "$rc" -eq 3 ] && [ ! -e "$root/arms/fx/src_feed/nosb-r1/run.meta" ]; then
    ok "run refuses outright when DF_NO_SANDBOX is set in the caller's shell (exit 3, nothing started)"
  else
    bad "run did not refuse DF_NO_SANDBOX (exit $rc)"
  fi
  touch "$cdir/code/truth.tsv"
  bash "$SELF" run --root "$root" --base "$base" --contest fx --zone src_feed --arm nosb --repeat 1 \
    --profile mock --checkout "$co" --agentis "$stub" > /dev/null 2>&1; rc=$?
  rm -f "$cdir/code/truth.tsv"
  expect_rc 3 "$rc" "run refuses a repo root that holds a truth.tsv (ground truth visible to the hunt)"
  printf 'BACKEND=mock\nenv.SEVERITY_RUBRIC=1\nDEEP_PASS=1\ndeep.DEEP_HUNT_PROMISES=1\n' > "$work/p-rubric.env"
  bash "$SELF" stage --root "$root" --base "$base" --contest fx --zone src_feed --arm rubric --repeat 1 \
    --profile "$work/p-rubric.env" --checkout "$co" > /dev/null 2>&1
  export STUB_ENV_DUMP="$work/env-rubric.txt"
  bash "$SELF" run --root "$root" --base "$base" --contest fx --zone src_feed --arm rubric --repeat 1 \
    --profile "$work/p-rubric.env" --checkout "$co" --agentis "$stub" > /dev/null 2>&1
  unset SEVERITY_RUBRIC
  if grep -q '^SEVERITY_RUBRIC=1$' "$work/env-rubric.txt" 2>/dev/null; then
    ok "knob hygiene: a profile's env.SEVERITY_RUBRIC=1 is PRESENT in the hunter's env"
  else
    bad "knob hygiene: env.SEVERITY_RUBRIC=1 never reached the hunter"
  fi
  local ra="$root/arms/fx/src_feed/rubric-r1"
  if [ "$(meta_get "$ra/run.meta" rc)" = 0 ] && [ "$(meta_get "$ra/run.meta" deep_rc)" = 2 ] \
     && grep -q 'DEEP_HUNT_PROMISES=1 requires DEEP_HUNT_REACH=1' "$ra/deep.log"; then
    ok "run: deep.* knobs reach the STAGE 4.5 call (PROMISES without REACH exits 2 there, breadth unaffected)"
  else
    bad "run: the deep.* knob did not reach the STAGE 4.5 call (rc=$(meta_get "$ra/run.meta" rc) deep=$(meta_get "$ra/run.meta" deep_rc))"
  fi
  printf 'BACKEND=mock\nHARD_STOP_S=2\nDEEP_PASS=1\n' > "$work/p-stop.env"
  bash "$SELF" stage --root "$root" --base "$base" --contest fx --zone src_feed --arm stop --repeat 1 \
    --profile "$work/p-stop.env" --checkout "$co" > /dev/null 2>&1
  export STUB_SLEEP=30
  unset STUB_ENV_DUMP
  bash "$SELF" run --root "$root" --base "$base" --contest fx --zone src_feed --arm stop --repeat 1 \
    --profile "$work/p-stop.env" --checkout "$co" --agentis "$stub" > /dev/null 2>&1
  rc=$?
  unset STUB_SLEEP
  local sa="$root/arms/fx/src_feed/stop-r1"
  if [ "$rc" -eq 124 ] && [ "$(meta_get "$sa/run.meta" rc)" = 124 ] && [ "$(meta_get "$sa/run.meta" deep_rc)" = skip-hard-stop ] \
     && [ -f "$sa/.done" ]; then
    ok "run: HARD_STOP_S=2 over a sleeping hunter records rc 124, skips STAGE 4.5, still writes .done"
  else
    bad "run: hard stop not recorded (exit $rc, meta rc=$(meta_get "$sa/run.meta" rc) deep=$(meta_get "$sa/run.meta" deep_rc))"
  fi
  if [ -z "$(bash "$SELF" kill --path "$sa" --dry-run 2>/dev/null)" ]; then
    ok "run: nothing is left running under a hard-stopped arm"
  else
    bad "run: processes survive the hard stop:"; bash "$SELF" kill --path "$sa" --dry-run 2>/dev/null | sed 's/^/         | /'
    bash "$SELF" kill --path "$sa" --grace 1 > /dev/null 2>&1
  fi

  echo "exam.sh self-test: M3 void-check over fixtures/exam-void/ (one arm per verdict)"
  local vfx="$CB_DIR/fixtures/exam-void" vw="$work/void-fx" vd vwant vgot vmiss=""
  mkdir -p "$vw" && cp -R "$vfx/." "$vw/"
  while IFS=$'\t' read -r vd vwant; do
    case "$vd" in ''|'#'*) continue ;; esac
    vgot="$(python3 "$HELPER" void-check "$vw/$vd" "$PATTERNS" 2>&1)"
    if [ "$vgot" = "$vwant" ] && [ "$(cat "$vw/$vd/void.txt")" = "$vwant" ]; then
      ok "void-check $vd -> $(printf '%s' "$vwant" | cut -f1-2 | tr '\t' ' ')"
    else
      bad "void-check $vd: got '$vgot', expected '$vwant'"; vmiss="$vmiss $vd"
    fi
  done < "$vfx/expected.tsv"
  if [ "$(grep -vc '^#' "$vfx/expected.tsv")" -ge 13 ] && grep -q $'^valid\tVALID$' "$vfx/expected.tsv" \
     && [ -f "$vfx/valid/fx/zone-hunt-out/discovery/src_pool/run/hunt_share_pool_C6.log.untraced" ] \
     && grep -q 'LLM transport error' "$vfx/valid/fx/zone-hunt-out/discovery/src_pool.attempt-1/run/hunt_share_pool_C1.log" \
     && grep -q 'hit your weekly limit' "$vfx/valid/fx/zone-hunt-out/discovery/src_pool/run/hunter.ag"; then
    ok "the VALID fixture keeps its negative controls: an .untraced METRIC cell, a recovered [LLM retry] line, a superseded failed attempt and a hunter.ag carrying every signature"
  else
    bad "fixtures/exam-void lost a negative control (or an expected row)"
  fi

  echo "exam.sh self-test: M3 run-window attribution (attrib)"
  local aa="$work/attrib-arm" ao troot="$work/transcripts" adisc averi adeep amap adrop acell
  ao="$aa/fx/zone-hunt-out"
  adisc="$ao/discovery/src_pool/run"; acell="$adisc/cell-share_pool_C1"; averi="$ao/verify/gates/1_Pool.sol_withdraw/refute-out/run"
  adeep="$ao/deep-hunt/src_pool-C1/run"; amap="$ao/map/run"; adrop="$ao/drop/run"
  mkdir -p "$acell" "$averi" "$adeep/repo/run" "$amap" "$adrop" "$troot"
  printf '%s\n' contest=fx backend=flat-cyborg model=claude-opus-4-8 start=2026-01-01T10:00:00Z \
    breadth_end=2026-01-01T10:30:00Z rehunt_end=- deep_start=2026-01-01T10:31:00Z deep_end=2026-01-01T10:50:00Z \
    end=2026-01-01T10:51:00Z rc=0 deep_rc=0 > "$aa/run.meta"
  # rec <cwd> <iso> <model> [fallback] -> one assistant record
  rec() { local fbb=""; [ -z "${4:-}" ] || fbb='{"type":"fallback"},'
          printf '{"type":"assistant","cwd":"%s","timestamp":"%s","message":{"role":"assistant","model":"%s","content":[%s{"type":"text","text":"x"}]}}\n' \
            "$1" "$2" "$3" "$fbb"; }
  store() { local d; d="$troot/$(python3 "$HELPER" project-slug "$1")"; mkdir -p "$d"; printf '%s\n' "$d"; }
  { rec "$acell" 2025-12-31T09:00:00.000Z claude-fable-5-1 fb; rec "$acell" 2026-01-01T10:05:00.000Z claude-opus-4-8
    rec "$acell" 2026-01-01T10:06:00.000Z claude-opus-4-8; } > "$(store "$acell")/s1.jsonl"
  rec /elsewhere/src_pool/run/cell-share_pool_C1 2026-01-01T10:07:00.000Z claude-fable-5-1 > "$(store "$acell")/collision.jsonl"
  rec "$averi" 2026-01-01T10:20:00.000Z claude-opus-4-8 > "$(store "$averi")/s2.jsonl"
  rec "$adeep" 2026-01-01T10:40:00.000Z claude-opus-4-8 > "$(store "$adeep")/s3.jsonl"
  rec "$amap" 2026-01-01T10:10:00.000Z claude-fable-5-1 > "$(store "$amap")/s4.jsonl"
  mkdir -p "$(store "$adeep")/sub/subagents" && rec "$adeep" 2026-01-01T10:41:00.000Z claude-opus-4-8 > "$(store "$adeep")/sub/subagents/a.jsonl"
  bash "$SELF" attrib --arm-dir "$aa" --transcripts-root "$troot" > "$work/attrib.out" 2>&1; rc=$?
  arow() { awk -F'\t' -v s="$1" '$1 == s { print $2 "|" $3 "|" $4 "|" $5 "|" $7 "|" $9 }' "$aa/attrib.tsv"; }
  if [ "$rc" -eq 0 ] && [ "$(arow discovery)" = "2|1|1|2|PURE-OPUS|ok" ] && [ "$(arow verify)" = "1|1|0|1|PURE-OPUS|ok" ] \
     && [ "$(arow deep-hunt)" = "1|2|0|2|PURE-OPUS|ok" ] && [ -z "$(arow map)" ] && [ "$(arow drop)" = "1|0|0|0|-|not-run" ] \
     && [ "$(python3 "$HELPER" void-check "$aa" "$PATTERNS")" = VALID ]; then
    ok "attrib: RUN dirs on disk -> exact store names (cell-* included, subagents too), cwd-confirmed (a colliding store file dropped), windowed PURE-OPUS per stage; map/ excluded, a model-free stage is not-run"
  else
    bad "attrib: wrong attribution table (exit $rc)"; sed 's/^/         | /' "$aa/attrib.tsv" "$work/attrib.out" 2>/dev/null | head -12
  fi
  rm -f "$(store "$adeep")/s3.jsonl" "$(store "$adeep")/sub/subagents/a.jsonl"
  rec "$adeep" 2026-01-01T10:20:00.000Z claude-opus-4-8 > "$(store "$adeep")/early.jsonl"
  bash "$SELF" attrib --arm-dir "$aa" --transcripts-root "$troot" > /dev/null 2>&1
  if [ "$(arow deep-hunt)" = "1|1|0|0|EMPTY|attribution-missing" ] \
     && [ "$(python3 "$HELPER" void-check "$aa" "$PATTERNS")" = "$(printf 'VOID\tattribution\tattrib.tsv:deep-hunt=EMPTY(attribution-missing)')" ]; then
    ok "attrib: a stage whose RUN dirs have no record inside its own window is attribution-missing -> VOID attribution"
  else
    bad "attrib: deep-hunt outside its window not flagged: $(arow deep-hunt)"
  fi
  eval "$(sed -n '/^claude_project_slug() {$/,/^}$/p' "$df_real/lib/claude-sandboxed.sh")"
  local longp; longp="$work/$(printf '%0230d' 0 | tr 0 r)/zone-hunt-out/verify/gates/1_x/refute-out/run"
  if command -v claude_project_slug > /dev/null 2>&1 && [ "$(claude_project_slug "$longp")" = "$(python3 "$HELPER" project-slug "$longp")" ] \
     && [ "$(claude_project_slug "$acell")" = "$(python3 "$HELPER" project-slug "$acell")" ]; then
    ok "attrib looks transcripts up under the SAME store names the hunt sandbox binds (lib/claude-sandboxed.sh; >200-char hashed name too)"
  else
    bad "exam-helper.py project-slug disagrees with lib/claude-sandboxed.sh claude_project_slug"
  fi

  echo "exam.sh self-test: M3 one-shot re-hunt of failed cells"
  local rh="$root/arms/fx/src_pool/rh-r1"
  bash "$SELF" stage --root "$root" --base "$base" --contest fx --zone src_pool --arm rh --repeat 1 --profile mock \
    --checkout "$co" > /dev/null 2>&1
  STUB_FAIL_CALLS=3 STUB_FAIL_STATE="$work/fail-rh" bash "$SELF" run --root "$root" --base "$base" --contest fx \
    --zone src_pool --arm rh --repeat 1 --profile mock --checkout "$co" --agentis "$stub" > /dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ] && [ "$(meta_get "$rh/run.meta" rehunt_rc)" = 0 ] \
     && [ -f "$rh/fx/zone-hunt-out/discovery/src_pool.attempt-1/run/hunt_share_pool_C1.log.novalid" ] \
     && grep -q '^CANDIDATE|' "$rh/fx/zone-hunt-out/discovery/src_pool/run/hunt_share_pool_C1.log" \
     && [ "$(head -1 "$rh/void.txt")" = VALID ] && [ -s "$rh/rehunt.log" ]; then
    ok "a transport-failed cell gets ONE in-arm re-hunt (--rehunt-include-partial --rehunt-max-attempts 2); the recovered arm is VALID, the failed attempt kept aside"
  else
    bad "one-shot re-hunt: exit $rc, rehunt_rc=$(meta_get "$rh/run.meta" rehunt_rc), void=$(head -1 "$rh/void.txt" 2>/dev/null)"
    tail -4 "$rh/rehunt.log" 2>/dev/null | sed 's/^/         | /'
  fi
  local rv="$root/arms/fx/src_pool/rhv-r1"
  bash "$SELF" stage --root "$root" --base "$base" --contest fx --zone src_pool --arm rhv --repeat 1 --profile mock \
    --checkout "$co" > /dev/null 2>&1
  STUB_FAIL_CALLS=99 STUB_FAIL_STATE="$work/fail-rhv" bash "$SELF" run --root "$root" --base "$base" --contest fx \
    --zone src_pool --arm rhv --repeat 1 --profile mock --checkout "$co" --agentis "$stub" > /dev/null 2>&1
  if [[ "$(meta_get "$rv/run.meta" rehunt_rc)" =~ ^[0-9]+$ ]] && [ -d "$rv/fx/zone-hunt-out/discovery/src_pool.attempt-1" ] \
     && [ "$(cut -f1-2 "$rv/void.txt")" = "$(printf 'VOID\ttransport')" ] \
     && [ "$(awk -F'\t' 'END { print $NF }' "$root/MANIFEST.tsv")" = VOID:transport ]; then
    ok "a cell still failed after the one re-hunt is VOID transport (void.txt + the MANIFEST verdict column)"
  else
    bad "still-failed re-hunt: rehunt_rc=$(meta_get "$rv/run.meta" rehunt_rc) void=$(head -1 "$rv/void.txt" 2>/dev/null)"
  fi
  printf 'BACKEND=mock\nMODEL=claude-opus-4-8\nREHUNT_TRANSPORT=0\n' > "$work/p-norehunt.env"
  local ro="$root/arms/fx/src_pool/rhoff-r1"
  bash "$SELF" stage --root "$root" --base "$base" --contest fx --zone src_pool --arm rhoff --repeat 1 \
    --profile "$work/p-norehunt.env" --checkout "$co" > /dev/null 2>&1
  STUB_FAIL_CALLS=3 STUB_FAIL_STATE="$work/fail-rhoff" bash "$SELF" run --root "$root" --base "$base" --contest fx \
    --zone src_pool --arm rhoff --repeat 1 --profile "$work/p-norehunt.env" --checkout "$co" --agentis "$stub" > /dev/null 2>&1
  if [ "$(meta_get "$ro/run.meta" rehunt_rc)" = skip-off ] && [ ! -e "$ro/fx/zone-hunt-out/discovery/src_pool.attempt-1" ] \
     && [ "$(cut -f1-2 "$ro/void.txt")" = "$(printf 'VOID\ttransport')" ]; then
    ok "REHUNT_TRANSPORT=0 turns the re-hunt off (rehunt_rc=skip-off) and the failed cell VOIDs the arm"
  else
    bad "REHUNT_TRANSPORT=0: rehunt_rc=$(meta_get "$ro/run.meta" rehunt_rc) void=$(head -1 "$ro/void.txt" 2>/dev/null)"
  fi

  echo "exam.sh self-test: multi-root freeze + stage + run (#2255)"
  local mbase="$work/mbase"
  mkdir -p "$mbase/mr" && cp -R "$df_real/fixtures/multi-root" "$mbase/mr/code" && cp "$fix/truth.tsv" "$mbase/mr/truth.tsv"
  bash "$SELF" freeze --base "$mbase" --contest mr --checkout "$co" --profile mock --project-roots core,market \
    --map-fixture "$df_real/fixtures/multi-root/zones.fixture.txt" --brief-fixture "$df_real/fixtures/multi-root/briefs.fixture.txt" \
    --agentis "$stub" > "$work/mfreeze.out" 2>&1
  rc=$?; expect_rc 0 "$rc" "freeze a multi-project clone from its root (--project-roots core,market)"
  [ "$rc" -eq 0 ] || sed 's/^/         | /' "$work/mfreeze.out" | tail -10
  if [ "$(meta_get "$mbase/mr/freeze.meta" project_roots)" = core,market ] && [ "$(meta_get "$mbase/mr/freeze.meta" map_roots)" = core,market ] \
     && [ "$(meta_get "$mbase/mr/freeze.meta" code_dir_rel)" = . ]; then
    ok "freeze.meta records the clone root + both project roots"
  else
    bad "freeze.meta multi-root fields wrong"; sed 's/^/         | /' "$mbase/mr/freeze.meta" 2>/dev/null
  fi
  printf 'BACKEND=mock\n' > "$work/p-plain.env"
  bash "$SELF" stage --root "$root" --base "$mbase" --contest mr --zone market_src --arm plain --repeat 1 \
    --profile "$work/p-plain.env" --checkout "$co" > /dev/null 2>&1
  bash "$SELF" run --root "$root" --base "$mbase" --contest mr --zone market_src --arm plain --repeat 1 \
    --profile "$work/p-plain.env" --checkout "$co" --agentis "$stub" > /dev/null 2>&1
  rc=$?
  local ma="$root/arms/mr/market_src/plain-r1"
  if [ "$rc" -eq 0 ] && [ "$(meta_get "$ma/run.meta" code)" = "$mbase/mr/code" ] && grep -q -- '--project-roots core,market' "$ma/run.log"; then
    ok "run: a multi-root arm hunts from the clone root with the frozen roots (the rehunt root assertion holds)"
  else
    bad "run: the multi-root arm failed (exit $rc)"; tail -5 "$ma/run.log" 2>/dev/null | sed 's/^/         | /'
  fi

  echo "exam.sh self-test: drive + triage hand-off"
  local droot="$work/droot" dplan="$work/dplan.tsv"
  bash "$SELF" plan --base "$base" --contest fx --arm mock --repeat 1 --profile mock --checkout "$co" > "$dplan" 2>/dev/null
  mkdir -p "$droot/logs"
  sh -c 'while :; do sleep 1; done' exam.sh drive &
  local fake=$!
  sleep 0.2
  echo "$fake" > "$droot/logs/dplan.lock"
  bash "$SELF" drive --root "$droot" --plan "$dplan" --agentis "$stub" > /dev/null 2>&1
  expect_rc 3 $? "drive refuses a plan whose lock names a live driver"
  kill -KILL "$fake" 2>/dev/null; wait "$fake" 2>/dev/null
  echo "$fake" > "$droot/logs/dplan.lock"   # now stale: that pid is gone
  bash "$SELF" drive --root "$droot" --plan "$dplan" --agentis "$stub" > "$work/drive.out" 2>&1
  rc=$?; expect_rc 0 "$rc" "drive a 2-row plan over a stale lock"
  local prog="$droot/logs/dplan.progress"
  if [ "$(grep -c $'\tSTART\t' "$prog" 2>/dev/null)" -eq 2 ] && [ "$(grep -c $'\tEND\t.*rc=0\tdeep=0\tvoid=VALID$' "$prog" 2>/dev/null)" -eq 2 ] \
     && [ -f "$droot/logs/dplan.done" ] && [ ! -e "$droot/logs/dplan.lock" ] \
     && [ -f "$droot/arms/fx/src_pool/mock-r1/.done" ] && [ -f "$droot/arms/fx/src_feed/mock-r1/.done" ]; then
    ok "drive: START/END per row, both arms .done, plan .done, lock released"
  else
    bad "drive: progress/markers wrong"; sed 's/^/         | /' "$prog" 2>/dev/null; tail -5 "$work/drive.out" | sed 's/^/         | /'
  fi
  if grep -q 're-exec from the snapshot' "$work/drive.out" && [ -n "$(find "$droot/logs" -path '*snapshot*/exam/exam.sh')" ]; then
    ok "drive: re-executed from a snapshot copy of exam/ under logs/"
  else
    bad "drive: no snapshot re-exec"
  fi
  local tsv="$droot/triage/fx-mock-r1.tsv"
  if [ -f "$tsv" ] && [ -f "$droot/triage/fx-mock-r1.md" ] && [ "$(grep -vc '^sev_id' "$tsv")" -eq "$(wc -l < "$fix/truth.tsv")" ] \
     && awk -F'\t' '$1 == "EX-1" { f = ($7 == "refuted") } END { exit f ? 0 : 1 }' "$tsv"; then
    ok "drive: the triage hand-off wrote fx-mock-r1.{tsv,md}; the stub's refuted candidate triages as refuted"
  else
    bad "drive: triage hand-off output missing or wrong"; sed 's/^/         | /' "$tsv" 2>/dev/null | head -5
  fi
  bash "$SELF" drive --root "$droot" --plan "$dplan" --agentis "$stub" > /dev/null 2>&1
  expect_rc 2 $? "drive without --resume refuses a plan whose arm dirs exist"
  git -C "$co" commit -q --allow-empty -m moved
  printf 'fx\tsrc_feed\tlate\t1\tmock\t%s\t%s\n' "$co" "$base" >> "$dplan"
  bash "$SELF" drive --root "$droot" --plan "$dplan" --resume --agentis "$stub" > /dev/null 2>&1
  if [ "$(grep -c $'\tSKIP\t' "$prog")" -eq 2 ] && grep -q $'\tlate\tr1\trc=refused-head-moved' "$prog" \
     && [ ! -e "$droot/arms/fx/src_feed/late-r1" ]; then
    ok "drive --resume: done rows skipped; a row whose checkout HEAD moved is refused (nothing staged)"
  else
    bad "drive --resume / HEAD pin wrong"; sed 's/^/         | /' "$prog"
  fi
  bash "$SELF" void-mark --arm-dir "$droot/arms/fx/src_feed/mock-r1" --reason "self-test operator void" > /dev/null 2>&1
  bash "$SELF" triage --root "$droot" --contest fx --arm mock --repeat 1 > /dev/null 2>&1
  if [ "$(cut -f1-2 "$droot/arms/fx/src_feed/mock-r1/void.txt")" = "$(printf 'VOID\toperator')" ] \
     && awk -F'\t' '$1 == "EX-2" { f = ($7 == "unmeasured") } END { exit f ? 0 : 1 }' "$tsv" \
     && awk -F'\t' '$1 == "EX-1" { f = ($7 == "refuted") } END { exit f ? 0 : 1 }' "$tsv"; then
    ok "void-mark -> VOID operator; the exam root's triage then reads that zone's rows as unmeasured (EX-2), the VALID zone's as before (EX-1)"
  else
    bad "a VOID zone is not triaged unmeasured"; awk -F'\t' '{ print $1, $7 }' "$tsv" 2>/dev/null | sed 's/^/         | /'
  fi

  echo "exam.sh self-test: M3 weekly-limit HALT, --resume over a VOID row, --retry-void"
  local wroot="$work/wroot" wplan="$work/wplan.tsv" wprog wa="$work/wroot/arms/fx/src_pool/wk-r1"
  printf 'fx\tsrc_pool\twk\t1\tmock\t%s\t%s\nfx\tsrc_feed\twk\t1\tmock\t%s\t%s\n' "$co" "$base" "$co" "$base" > "$wplan"
  STUB_FAIL_CALLS=99 STUB_FAIL_STATE="$work/fail-wk" STUB_FAIL_TEXT="$CB_DIR/fixtures/exam-void/weekly-limit-notice.txt" \
    bash "$SELF" drive --root "$wroot" --plan "$wplan" --agentis "$stub" > "$work/wdrive.out" 2>&1; rc=$?
  wprog="$wroot/logs/wplan.progress"
  if [ "$rc" -eq 6 ] && [ -f "$wroot/logs/wplan.halted" ] && grep -q $'\tsrc_pool\twk\tr1\trc=0\tdeep=skip-weekly-limit\tvoid=weekly-limit$' "$wprog" \
     && grep -q $'\tHALT\tfx\tsrc_pool\twk\tr1\t' "$wprog" && [ ! -e "$wroot/arms/fx/src_feed/wk-r1" ] \
     && [ ! -e "$wroot/logs/wplan.done" ] && [ "$(meta_get "$wa/run.meta" rehunt_rc)" = skip-weekly-limit ] \
     && [ ! -e "$wa/fx/zone-hunt-out/discovery/src_pool.attempt-1" ]; then
    ok "a usage-limit VOID HALTS the plan (exit 6, logs/<plan>.halted, no re-hunt and no STAGE 4.5 spent on it); row 2 is left unstarted"
  else
    bad "weekly-limit halt: exit $rc"; sed 's/^/         | /' "$wprog" 2>/dev/null; head -1 "$wa/void.txt" 2>/dev/null | sed 's/^/         | /'
  fi
  bash "$SELF" drive --root "$wroot" --plan "$wplan" --resume --agentis "$stub" > /dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ] && grep -q $'\tSKIP\tfx\tsrc_pool\twk\tr1\tvoid=weekly-limit' "$wprog" \
     && [ "$(head -1 "$wroot/arms/fx/src_feed/wk-r1/void.txt" 2>/dev/null)" = VALID ] && [ ! -e "$wroot/logs/wplan.halted" ] \
     && [ "$(cut -f1-2 "$wa/void.txt")" = "$(printf 'VOID\tweekly-limit')" ]; then
    ok "--resume never re-runs a VOID row (reported, left alone) and runs the unstarted row"
  else
    bad "--resume over a VOID row: exit $rc"; tail -4 "$wprog" 2>/dev/null | sed 's/^/         | /'
  fi
  bash "$SELF" drive --root "$wroot" --plan "$wplan" --retry-void --agentis "$stub" > /dev/null 2>&1; rc=$?
  if [ "$rc" -eq 0 ] && [ "$(cut -f1-2 "$wa.void-1/void.txt" 2>/dev/null)" = "$(printf 'VOID\tweekly-limit')" ] \
     && [ "$(head -1 "$wa/void.txt" 2>/dev/null)" = VALID ] && grep -q $'\tRETRY\tfx\tsrc_pool\twk\tr1\tvoid=weekly-limit kept as wk-r1.void-1' "$wprog" \
     && grep -q $'\tSKIP\tfx\tsrc_feed\twk\tr1\tdone' "$wprog" && [ -f "$wroot/logs/wplan.done" ]; then
    ok "--retry-void keeps the VOID attempt as wk-r1.void-1 and re-runs that row fresh (VALID); the VALID row is skipped"
  else
    bad "--retry-void: exit $rc"; tail -4 "$wprog" 2>/dev/null | sed 's/^/         | /'
  fi

  echo "exam.sh self-test: a running arm — live-arm refusals, kill-by-path of its controller, drive TERM"
  wait_for() { local i=0; while [ "$i" -lt 100 ]; do eval "$1" && return 0; sleep 0.2; i=$((i + 1)); done; return 1; }
  local la="$root/arms/fx/src_feed/live-r1" lpid
  bash "$SELF" stage --root "$root" --base "$base" --contest fx --zone src_feed --arm live --repeat 1 --profile mock \
    --checkout "$co" > /dev/null 2>&1
  STUB_SLEEP=40 bash "$SELF" run --root "$root" --base "$base" --contest fx --zone src_feed --arm live --repeat 1 \
    --profile mock --checkout "$co" --agentis "$stub" > /dev/null 2>&1 &
  local runbg=$!
  wait_for '[ -s "$la/run.pid" ] && [ -n "$(find "$la" -name "hunt_*" 2>/dev/null)" ]'; sleep 1
  lpid="$(head -1 "$la/run.pid" 2>/dev/null)"
  bash "$SELF" stage --root "$root" --base "$base" --contest fx --zone src_feed --arm live --repeat 1 --profile mock \
    --checkout "$co" > /dev/null 2>&1; expect_rc 3 $? "stage refuses an arm whose run is still alive (run.pid + /proc)"
  printf 'fx\tsrc_feed\tlive\t1\tmock\t%s\t%s\n' "$co" "$base" > "$work/live.tsv"
  bash "$SELF" drive --root "$root" --plan "$work/live.tsv" --resume --agentis "$stub" > /dev/null 2>&1
  if grep -q $'\tlive\tr1\trc=refused-live-run' "$root/logs/live.progress" 2>/dev/null && [ ! -e "$la.partial-1" ] \
     && [ "$(head -1 "$la/run.pid" 2>/dev/null)" = "$lpid" ]; then
    ok "drive --resume refuses the live arm (never moves it aside, never starts a second writer)"
  else
    bad "drive --resume touched a live arm"; sed 's/^/         | /' "$root/logs/live.progress" 2>/dev/null
  fi
  if bash "$SELF" kill --path "$la" --dry-run 2>/dev/null | awk -F'\t' -v p="$lpid" '$1 == p && $2 == "pidfile" { f = 1 } END { exit f ? 0 : 1 }'; then
    ok "kill --dry-run lists the arm's run controller by its run.pid (its args name the root, its cwd is elsewhere)"
  else
    bad "kill --dry-run does not list the run controller $lpid of $la"
  fi
  bash "$SELF" kill --path "$la" --grace 8 > "$work/kill-live.out" 2>&1; rc=$?
  wait "$runbg" 2>/dev/null
  if [ "$rc" -eq 0 ] && [ -n "$lpid" ] && [ ! -d "/proc/$lpid" ] && [ -f "$la/.done" ] && [ ! -e "$la/run.pid" ] \
     && [ "$(meta_get "$la/run.meta" rc)" = 143 ] && [ "$(meta_get "$la/run.meta" deep_rc)" = skip-killed ] \
     && [ -z "$(bash "$SELF" kill --path "$la" --dry-run 2>/dev/null)" ]; then
    ok "kill --path <arm> stops the arm's run controller too (pidfile); run records rc 143 and never starts STAGE 4.5"
  else
    bad "kill --path <arm>: exit $rc, controller $lpid $([ -d "/proc/$lpid" ] && echo ALIVE || echo gone), rc=$(meta_get "$la/run.meta" rc) deep=$(meta_get "$la/run.meta" deep_rc)"
    sed 's/^/         | /' "$work/kill-live.out"; [ -z "$lpid" ] || kill -KILL "$lpid" 2>/dev/null
    bash "$SELF" kill --path "$la" --grace 1 > /dev/null 2>&1
  fi
  # breadth killed from outside (the run controller itself NOT signalled) with a verify file already present:
  # rc 143 must never lead into STAGE 4.5.
  local xa="$root/arms/fx/src_feed/ext-r1" xpid tmo
  bash "$SELF" stage --root "$root" --base "$base" --contest fx --zone src_feed --arm ext --repeat 1 --profile mock \
    --checkout "$co" > /dev/null 2>&1
  mkdir -p "$xa/fx/zone-hunt-out/verify" && printf '{"verified": []}\n' > "$xa/fx/zone-hunt-out/verify/verified_findings.json"
  STUB_SLEEP=40 bash "$SELF" run --root "$root" --base "$base" --contest fx --zone src_feed --arm ext --repeat 1 \
    --profile mock --checkout "$co" --agentis "$stub" > /dev/null 2>&1 &
  xpid=$!
  wait_for '[ -s "$xa/run.pid" ] && [ -n "$(find "$xa" -name "hunt_*" 2>/dev/null)" ]'; sleep 1
  tmo="$(bash "$SELF" kill --path "$xa" --dry-run 2>/dev/null | awk -F'\t' '$3 ~ /^timeout / { print $1; exit }')"
  [ -z "$tmo" ] || kill -TERM "$tmo" 2>/dev/null
  wait "$xpid" 2>/dev/null
  if [ -n "$tmo" ] && [ "$(meta_get "$xa/run.meta" rc)" = 143 ] && [ "$(meta_get "$xa/run.meta" deep_rc)" = skip-killed ] \
     && [ ! -e "$xa/deep.log" ] && [ -z "$(bash "$SELF" kill --path "$xa" --dry-run 2>/dev/null)" ]; then
    ok "a breadth call killed from outside (rc 143) skips STAGE 4.5 even with verified_findings.json present"
  else
    bad "breadth killed from outside: timeout=$tmo rc=$(meta_get "$xa/run.meta" rc) deep=$(meta_get "$xa/run.meta" deep_rc)"
    bash "$SELF" kill --path "$xa" --grace 1 > /dev/null 2>&1
  fi
  local troot="$work/troot" ta dpid tpid
  ta="$troot/arms/fx/src_feed/term-r1"
  printf 'fx\tsrc_feed\tterm\t1\tmock\t%s\t%s\n' "$co" "$base" > "$work/tplan.tsv"
  STUB_SLEEP=40 bash "$SELF" drive --root "$troot" --plan "$work/tplan.tsv" --agentis "$stub" > /dev/null 2>&1 &
  dpid=$!
  wait_for '[ -s "$ta/run.pid" ] && [ -n "$(find "$ta" -name "hunt_*" 2>/dev/null)" ]'; sleep 1
  tpid="$(head -1 "$ta/run.pid" 2>/dev/null)"
  kill -TERM "$dpid" 2>/dev/null; wait "$dpid" 2>/dev/null; rc=$?
  if [ "$rc" -eq 143 ] && [ -n "$tpid" ] && [ ! -d "/proc/$tpid" ] && [ -f "$ta/.done" ] \
     && [ "$(meta_get "$ta/run.meta" rc)" = 143 ] && [ -z "$(bash "$SELF" kill --path "$ta" --dry-run 2>/dev/null)" ] \
     && grep -q 'rc=drive-signalled-143' "$troot/logs/tplan.progress"; then
    ok "TERM to drive terminates its run child (process group + run's own cleanup); nothing survives under the arm"
  else
    bad "TERM to drive: exit $rc, run $tpid $([ -d "/proc/$tpid" ] && echo ALIVE || echo gone), rc=$(meta_get "$ta/run.meta" rc) .done=$([ -f "$ta/.done" ] && echo yes || echo no)"
    bash "$SELF" kill --path "$ta" --dry-run 2>/dev/null | sed 's/^/         | left: /'
    tail -3 "$troot/logs/tplan.progress" 2>/dev/null | sed 's/^/         | /'
    bash "$SELF" kill --path "$troot" --grace 1 > /dev/null 2>&1
  fi

  echo "exam.sh self-test: kill-by-path"
  local kroot="$work/kill-root"
  mkdir -p "$kroot/sub"
  (cd "$kroot/sub" && exec sleep 300) &
  local sleeper=$!
  ST_SLEEPER="$sleeper"
  sleep 0.3
  local listing listed
  listing="$(cd "$kroot" && bash "$SELF" kill --path "$kroot" --dry-run 2>/dev/null)"
  listed="$(printf '%s\n' "$listing" | cut -f1)"
  # EXACTLY the sleeper: the caller subshell (cwd under the path) is an ancestor of the kill process and must
  # never be listed, nor the scan's own command substitutions (their args name the path).
  if [ "$listed" = "$sleeper" ]; then
    ok "kill --dry-run lists exactly the sleeper under the path (not its caller whose cwd is there, not itself)"
  else
    bad "kill --dry-run listed more (or less) than the sleeper $sleeper:"; printf '%s\n' "$listing" | sed 's/^/         | /'
    ps -o pid=,ppid=,args= -p "$(printf '%s\n' "$listed" | paste -sd, -)" 2>/dev/null | sed 's/^/         | ps: /'
  fi
  ln -s "$kroot" "$work/kill-link"
  if [ "$(bash "$SELF" kill --path "$work/kill-link" --dry-run 2>/dev/null | cut -f1)" = "$sleeper" ]; then
    ok "kill --path through a symlink resolves physically and still finds the sleeper (cwd match)"
  else
    bad "kill --path through a symlink found nothing (logical path vs physical /proc cwd)"
  fi
  (cd "$kroot" && bash "$SELF" kill --path "$kroot" --grace 2 > /dev/null 2>&1); rc=$?
  wait "$sleeper" 2>/dev/null
  if [ "$rc" -eq 0 ] && [ ! -d "/proc/$sleeper" ]; then
    ok "kill terminates it and reports nothing left"; ST_SLEEPER=""
  else
    bad "kill left the sleeper alive (exit $rc)"
  fi
  bash "$SELF" kill --path /tmp/exam-kill-too-shallow --dry-run > /dev/null 2>&1
  expect_rc 2 $? "kill refuses a path this close to / (fewer than three components)"

  echo
  if [ "$fails" -eq 0 ]; then echo "exam.sh self-test: PASS"; return 0; fi
  echo "exam.sh self-test: FAILED ($fails)"; return 1
}

usage() { awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$SELF"; }

sub="${1:-}"
[ $# -gt 0 ] && shift
case "$sub" in
  freeze) cmd_freeze "$@" ;;
  plan) cmd_plan "$@" ;;
  stage) cmd_stage "$@" ;;
  run) cmd_run "$@" ;;
  drive) cmd_drive "$@" ;;
  triage) cmd_triage "$@" ;;
  kill) cmd_kill "$@" ;;
  attrib) cmd_attrib "$@" ;;
  void-mark) cmd_void_mark "$@" ;;
  self-test) cmd_self_test ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
