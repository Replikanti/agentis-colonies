#!/usr/bin/env bash
# exam.sh — the #2262 held-out EXAM RUNNER (M2: runner core). A reusable, contest-agnostic replacement for the
# host-only harness scripts every held-out measurement used to run on: freeze a contest's map + briefs from a
# pinned tool checkout, stage one zone (or the whole contest) into an arm dir, run the breadth pass with a KNOB
# PROFILE and optionally STAGE 4.5 over the same output, leave per-run metadata + done markers, drive a plan of
# rows sequentially, kill everything under a path, and hand the finished arms to triage.py.
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
#            Verifies freeze.sha256 (exit 3 on drift), COPIES map/ + briefs/ + truth.tsv into the arm dir,
#            SYMLINKS code/ + judging/, filters zones.json to that zone (`_all` keeps every zone), appends the
#            profile's INJECT_CLASSES to the zone's scope.tsv class field once each (no classes = byte-identical),
#            runs lib/zone-coverage.py init and checks `gaps` yields exactly the staged zone(s).
#   run      (the stage args) [--agentis <bin>]
#            Breadth: `timeout HARD_STOP_S run-zone-hunt.sh --rehunt-gaps` with the profile's env.* knobs.
#            STAGE 4.5 (DEEP_PASS=1, verify/verified_findings.json present, breadth not hard-stopped): a second
#            `timeout` call with --deep-hunt --deep-hunt-only over the SAME --out and the deep.* knobs. A hard stop
#            (rc 124) kills everything left under the arm dir. An EXIT trap ALWAYS writes run.meta, the arm's .done
#            marker and one MANIFEST.tsv row, even after a crash.
#   drive    --root <root> --plan <plan.tsv> [--resume] [--agentis <bin>]
#            stage + run per row, sequentially (one live arm at a time), under a PID lock; START/END lines in
#            logs/<plan>.progress, logs/<plan>.done at the end. Re-execs from a snapshot of exam/ under logs/
#            (bash reads a script incrementally, so a pull mid-plan would otherwise corrupt the run). Pins each
#            checkout's HEAD at first use and refuses a row whose checkout has moved. --resume skips rows with a
#            .done marker. Ends with the triage hand-off below for every (contest, arm, repeat) of the plan.
#   triage   --root <root> --contest <id> --arm <label> --repeat <n>
#            triage.py over every finished zone tree of that arm, against the frozen base's FULL map (located via
#            run.meta); a hard-stopped tree is passed as --unmeasured, a zone with no tree is unmeasured by
#            triage itself. Writes <root>/triage/<contest>-<arm>-r<n>.{tsv,md}.
#   kill     --path <dir> [--dry-run] [--grace <s>]
#            Kill-by-path: every process whose args name <dir> (or a path under it) or whose cwd is under it —
#            never this process or its ancestors. SIGTERM, grace (default 10 s), SIGKILL, then a check that
#            nothing is left. Refuses a path with fewer than three components (/, /tmp/x, a home dir). Reads `ps -eo pid=,ppid=,args=` + /proc/<pid>/cwd; never a pattern-matching
#            process killer, which would match its own command line.
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
#                                                       checkout HEAD pins
#   <root>/arms/<contest>/<zone>/<arm>-r<N>/            run.meta run.log deep.log stage.log stage.meta .done
#       <contest>/{truth.tsv, code -> base, judging -> base, zone-hunt-out/}
#   <root>/triage/<contest>-<arm>-r<N>.{tsv,md}
# The inner <contest>/ level keeps `generation-recall.sh --from-work <arm-dir> --id <contest>` working.
#
# Needs bash, python3, git, GNU `timeout` and /proc (Linux). Exit: 0 ok; 1 a self-test / kill check failed;
# 2 usage or profile error; 3 missing prerequisite, dirty / contaminated checkout, drift, refused overwrite or a
# live lock; 4 contaminated freeze output; 5 fallback briefs (freeze). `run` exits with the breadth rc (else a
# non-zero deep rc).
set -uo pipefail

ME="exam.sh"
EXAM_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$EXAM_DIR/exam.sh"
HELPER="$EXAM_DIR/exam-helper.py"
PROFILES_DIR="$EXAM_DIR/profiles"
CB_DIR="$(cd "$EXAM_DIR/.." && pwd)"
TRIAGE="$CB_DIR/triage.py"
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

abs_dir()  { (cd "$1" 2>/dev/null && pwd); }
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
P_SCOPE_DOCS=""; ENV_KV=(); DEEP_KV=(); PASS_NAMES=()
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

# Knob hygiene (#2262 STOP-1 decision 2): the caller's environment is inherited, but every knob of the registry
# is UNSET before the profile is applied — except the profile's own pass.<NAME>s, which must be present.
clear_knobs() {
  local f="$1" reg n p keep
  reg="$(python3 "$HELPER" knob-registry "$PROFILES_DIR" "$f")" || die 2 "cannot build the knob registry"
  for n in $reg; do
    keep=0
    for p in ${PASS_NAMES[@]+"${PASS_NAMES[@]}"}; do [ "$p" = "$n" ] && keep=1; done
    [ "$keep" -eq 1 ] || unset "$n"
  done
  for p in ${PASS_NAMES[@]+"${PASS_NAMES[@]}"}; do
    [ -n "${!p+x}" ] || die 3 "the profile inherits $p (pass.$p) but it is not set in the environment"
  done
}

file_sha() { sha256sum "$1" | cut -d' ' -f1; }

# The frozen artifact manifest: sha256 of every file under map/ + briefs/, sorted relative paths.
freeze_manifest() {
  (cd "$1" && find map briefs -type f -print0 | LC_ALL=C sort -z | xargs -0 -r sha256sum)
}

# ----------------------------------------------------------------------------------------------------------
# kill-by-path
# ----------------------------------------------------------------------------------------------------------
# Every process (pid<TAB>why<TAB>args) that names PATH in its args or runs with its cwd under PATH, minus this
# process, its ancestors and its own descendants (the command substitutions of this very scan).
kill_scan() {
  local path="$1" snap line pid why cwd
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
  done < <(printf '%s\n' "$snap" | awk -v self="$$" -v p="$path" '
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
      for (k = 1; k <= n; k++) { q = order[k]
        if ((q in ex) || (q in desc)) continue
        if (args[q] ~ /^\[.*\]$/) continue
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
  if [ -d "$path" ]; then path="$(abs_dir "$path")"; fi
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
  clear_knobs "$profile"

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
  echo "[freeze $(utc)] contest=$contest checkout=$commit backend=$P_BACKEND model=${P_MODEL:--}" >> "$log"
  (cd "$df" && bash map-zones.sh "${margs[@]}" "${common[@]}") >> "$log" 2>&1 \
    || die 3 "freeze: map-zones.sh failed (see $log)"
  [ -f "$cdir/map/zones.json" ] && grep -qv '^#' "$cdir/map/scope.tsv" 2>/dev/null \
    || die 3 "freeze: map-zones.sh produced no zones.json / scope.tsv lines (see $log)"
  local -a bargs=(--zones "$cdir/map/zones.json" --scope "$cdir/map/scope.tsv" --out "$cdir/briefs" --repo "$code")
  [ -z "$brieffx" ] || bargs+=(--fixture "$brieffx")
  local bout; bout="$(cd "$df" && bash gen-briefs.sh "${bargs[@]}" "${common[@]}" 2>&1)"
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
  cp -a "$cdir/map" "$out/map" && cp -a "$cdir/briefs" "$out/briefs" && cp "$cdir/truth.tsv" "$armdir/$A_CONTEST/truth.tsv" \
    || die 3 "stage: copying the frozen base failed"
  ln -s "$cdir/code" "$armdir/$A_CONTEST/code"
  [ ! -e "$cdir/judging" ] || ln -s "$cdir/judging" "$armdir/$A_CONTEST/judging"
  slogf "copied map/ briefs/ truth.tsv from $cdir; code/ (+ judging/) symlinked read-only"
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
  (cd "$df" && python3 lib/zone-coverage.py init --zones "$zones_json" --out "$out/coverage/zone-coverage.json" \
      --zone-list "$out/.zone-list.tsv" --repo "$A_CONTEST" --commit "$commit" \
      --zone-cell-budget 0 --run-cell-budget 0) >> "$slog" 2>&1 || die 3 "stage: zone-coverage.py init failed"
  local gaps want got
  gaps="$(cd "$df" && python3 lib/zone-coverage.py gaps --file "$out/coverage/zone-coverage.json" --max-attempts 2)" \
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

MANIFEST_HEADER=$'contest\tzone\tarm\trepeat\tprofile\tprofile_sha256\tcheckout_commit\tmodel\tbackend\tstart\tend\trc\tdeep_start\tdeep_end\tdeep_rc\tarm_dir'

# run state, read by the EXIT trap
R_ARMDIR=""; R_START=""; R_RC=""; R_DEEP_START="-"; R_DEEP_END="-"; R_DEEP_RC="skip"; R_COMMIT=""; R_DIRTY=""
R_CODE=""; R_ROOTS=""

run_finish() {
  local rc=$? end meta
  [ -n "$R_RC" ] || R_RC="$rc"
  end="$(utc)"
  meta="$R_ARMDIR/run.meta"
  {
    echo "contest=$A_CONTEST"; echo "zone=$A_ZONE"; echo "arm=$A_ARM"; echo "repeat=$A_REPEAT"
    echo "start=$R_START"; echo "end=$end"; echo "rc=$R_RC"
    echo "deep_start=$R_DEEP_START"; echo "deep_end=$R_DEEP_END"; echo "deep_rc=$R_DEEP_RC"
    echo "base=$A_BASE"; echo "code=$R_CODE"; echo "project_roots=$R_ROOTS"
    echo "checkout=$A_CHECKOUT"; echo "checkout_commit=$R_COMMIT"; echo "checkout_dirty=$R_DIRTY"
    echo "backend=$P_BACKEND"; echo "model=${P_MODEL:--}"; echo "jobs=$P_JOBS"; echo "deep_jobs=$P_DEEP_JOBS"
    echo "hard_stop_s=$P_HARD_STOP_S"; echo "deep_pass=$P_DEEP_PASS"; echo "scope_docs=${P_SCOPE_DOCS:--}"
    echo "env_knobs=$(printf '%s\n' ${ENV_KV[@]+"${ENV_KV[@]}"} | paste -sd' ' -)"
    echo "deep_knobs=$(printf '%s\n' ${DEEP_KV[@]+"${DEEP_KV[@]}"} | paste -sd' ' -)"
    echo "pass_knobs=$(printf '%s\n' ${PASS_NAMES[@]+"${PASS_NAMES[@]}"} | paste -sd' ' -)"
    echo "profile=$(basename "$A_PROFILE")"; echo "profile_sha256=$(file_sha "$A_PROFILE")"
  } > "$meta.tmp" && mv "$meta.tmp" "$meta"
  local mf="$A_ROOT/MANIFEST.tsv"
  [ -s "$mf" ] || printf '%s\n' "$MANIFEST_HEADER" > "$mf"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$A_CONTEST" "$A_ZONE" "$A_ARM" "$A_REPEAT" "$(basename "$A_PROFILE")" "$(file_sha "$A_PROFILE")" "$R_COMMIT" \
    "${P_MODEL:--}" "$P_BACKEND" "$R_START" "$end" "$R_RC" "$R_DEEP_START" "$R_DEEP_END" "$R_DEEP_RC" \
    "arms/$A_CONTEST/$A_ZONE/$A_ARM-r$A_REPEAT" >> "$mf"
  printf 'rc=%s\tdeep=%s\tend=%s\n' "$R_RC" "$R_DEEP_RC" "$end" > "$R_ARMDIR/.done"
  note "run: [$A_CONTEST $A_ZONE $A_ARM r$A_REPEAT] END rc=$R_RC deep=$R_DEEP_RC -> $R_ARMDIR"
}

cmd_run() {
  parse_arm_args run "$@"
  local cdir="$A_BASE/$A_CONTEST" df="$A_CHECKOUT/dark-factory"
  R_ARMDIR="$(arm_dir "$A_ROOT" "$A_CONTEST" "$A_ZONE" "$A_ARM" "$A_REPEAT")"
  local out="$R_ARMDIR/$A_CONTEST/zone-hunt-out"
  [ -f "$out/map/zones.json" ] && [ -f "$out/coverage/zone-coverage.json" ] && [ -d "$out/briefs/briefs" ] \
    || die 3 "run: $R_ARMDIR is not staged (exam.sh stage first)"
  [ ! -e "$R_ARMDIR/.done" ] || die 3 "run: $R_ARMDIR already ran (.done)"
  [ -f "$cdir/freeze.meta" ] || die 3 "run: $cdir is not frozen"
  local code_rel; code_rel="$(meta_get "$cdir/freeze.meta" code_dir_rel)"
  R_ROOTS="$(meta_get "$cdir/freeze.meta" project_roots)"; [ -n "$R_ROOTS" ] || R_ROOTS="-"
  R_CODE="$cdir/code"; [ -z "$code_rel" ] || [ "$code_rel" = . ] || R_CODE="$cdir/code/$code_rel"
  [ -d "$R_CODE" ] || die 3 "run: code dir $R_CODE missing"
  load_profile "$A_PROFILE"
  clear_knobs "$A_PROFILE"
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

  trap run_finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  R_START="$(utc)"
  echo "[run $R_START] breadth: env ${ENV_KV[*]+${ENV_KV[*]}} timeout $P_HARD_STOP_S run-zone-hunt.sh ${common[*]} ${breadth[*]}" >> "$R_ARMDIR/run.log"
  (cd "$df" && env ${ENV_KV[@]+"${ENV_KV[@]}"} timeout "$P_HARD_STOP_S" bash run-zone-hunt.sh "${common[@]}" "${breadth[@]}") \
    >> "$R_ARMDIR/run.log" 2>&1
  R_RC=$?
  if [ "$R_RC" -eq 124 ]; then
    echo "[run $(utc)] HARD STOP after ${P_HARD_STOP_S}s — killing what is left under the arm dir" >> "$R_ARMDIR/run.log"
    kill_by_path "$R_ARMDIR" 0 10 >> "$R_ARMDIR/run.log" 2>&1 || true
  fi
  if [ "$P_DEEP_PASS" = 1 ]; then
    if [ "$R_RC" -eq 124 ]; then
      R_DEEP_RC="skip-hard-stop"
    elif [ ! -f "$out/verify/verified_findings.json" ]; then
      R_DEEP_RC="skip-no-verify"
    else
      R_DEEP_START="$(utc)"
      echo "[deep $R_DEEP_START] env ${DEEP_KV[*]+${DEEP_KV[*]}} timeout $P_HARD_STOP_S run-zone-hunt.sh ${common[*]} --deep-hunt --deep-hunt-only --jobs $P_DEEP_JOBS" >> "$R_ARMDIR/deep.log"
      (cd "$df" && env ${DEEP_KV[@]+"${DEEP_KV[@]}"} timeout "$P_HARD_STOP_S" bash run-zone-hunt.sh "${common[@]}" \
          --deep-hunt --deep-hunt-only --jobs "$P_DEEP_JOBS") >> "$R_ARMDIR/deep.log" 2>&1
      R_DEEP_RC=$?
      R_DEEP_END="$(utc)"
      if [ "$R_DEEP_RC" -eq 124 ]; then
        echo "[deep $(utc)] HARD STOP after ${P_HARD_STOP_S}s — killing what is left under the arm dir" >> "$R_ARMDIR/deep.log"
        kill_by_path "$R_ARMDIR" 0 10 >> "$R_ARMDIR/deep.log" 2>&1 || true
      fi
    fi
  fi
  [ "$R_RC" -eq 0 ] || exit "$R_RC"
  case "$R_DEEP_RC" in ''|*[!0-9]*|0) exit 0 ;; *) exit "$R_DEEP_RC" ;; esac
}

# ----------------------------------------------------------------------------------------------------------
# triage hand-off
# ----------------------------------------------------------------------------------------------------------
# The M2 arm verdict: VALID unless a call was hard-stopped. (#2262 M3 replaces this with the attribution +
# void-pattern check and a void.txt per arm.)
arm_verdict() {
  local meta="$1/run.meta" rc drc
  rc="$(meta_get "$meta" rc)"; drc="$(meta_get "$meta" deep_rc)"
  if [ "$rc" = 124 ] || [ "$drc" = 124 ]; then echo "hard-stop"; else echo "VALID"; fi
}

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
    v="$(arm_verdict "$d")"
    if [ "$v" = VALID ]; then
      [ -d "$d/$contest/zone-hunt-out/discovery" ] && runs+=(--run "$zone=$d/$contest/zone-hunt-out")
    elif [ "$zone" != _all ]; then
      unmeasured+=(--unmeasured "$zone:$v")
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

cmd_drive() {
  local root="" plan="" resume=0 agentis="agentis" orig=("$@")
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) need_val "$#" "$1"; root="$2"; shift 2 ;;
      --plan) need_val "$#" "$1"; plan="$2"; shift 2 ;;
      --resume) resume=1; shift ;;
      --agentis) need_val "$#" "$1"; agentis="$2"; shift 2 ;;
      *) die 2 "drive: unknown flag $1" ;;
    esac
  done
  [ -n "$root" ] && [ -n "$plan" ] || die 2 "drive: --root and --plan are required"
  [ -f "$plan" ] || die 2 "drive: plan not found: $plan"
  need_platform
  mkdir -p "$root/logs" || die 3 "drive: cannot create $root/logs"
  root="$(abs_dir "$root")"
  local pname; pname="$(basename "$plan")"; pname="${pname%.tsv}"
  safe_id "$pname" || die 2 "drive: the plan file name '$pname' is not a safe label"
  local logs="$root/logs" lock="$root/logs/$pname.lock"
  if [ "${EXAM_FROM_SNAPSHOT:-}" != 1 ]; then
    if lock_live "$lock"; then die 3 "drive: plan '$pname' is already driven by pid $(head -1 "$lock")"; fi
    local snap; snap="$logs/$pname.snapshot-$(date -u +%Y%m%dT%H%M%SZ)-$$"
    mkdir -p "$snap/exam" || die 3 "drive: cannot create the snapshot"
    cp "$SELF" "$HELPER" "$snap/exam/" && cp -R "$PROFILES_DIR" "$snap/exam/profiles" \
      && cp "$TRIAGE" "$CB_DIR/score-match.py" "$CB_DIR/hypotheses-to-leads.py" "$snap/" \
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
    resolve_profile "$p" > /dev/null || exit 2
    if [ "$resume" -eq 0 ] && [ -e "$(arm_dir "$root" "$c" "$z" "$a" "$n")" ]; then
      die 2 "drive: $plan:$line_no: $(arm_dir "$root" "$c" "$z" "$a" "$n") exists — use --resume"
    fi
    R_C+=("$c"); R_Z+=("$z"); R_A+=("$a"); R_N+=("$n"); R_P+=("$p"); R_K+=("$k"); R_B+=("$b")
  done < "$plan"
  [ "${#R_C[@]}" -gt 0 ] || die 2 "drive: the plan has no rows"

  local prog="$logs/$pname.progress" dlog="$logs/$pname.log" heads="$logs/$pname.heads"
  touch "$heads"
  local i armdir head pinned src rrc rc drc ran=0 skipped=0 refused=0
  for i in "${!R_C[@]}"; do
    c="${R_C[$i]}"; z="${R_Z[$i]}"; a="${R_A[$i]}"; n="${R_N[$i]}"; p="${R_P[$i]}"; k="${R_K[$i]}"; b="${R_B[$i]}"
    armdir="$(arm_dir "$root" "$c" "$z" "$a" "$n")"
    if [ "$resume" -eq 1 ] && [ -f "$armdir/.done" ]; then
      printf '%s\tSKIP\t%s\t%s\t%s\tr%s\tdone\n' "$(utc)" "$c" "$z" "$a" "$n" >> "$prog"
      skipped=$((skipped + 1)); continue
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
    bash "$SELF" run --root "$root" --base "$b" --contest "$c" --zone "$z" --arm "$a" --repeat "$n" \
      --profile "$p" --checkout "$k" --agentis "$agentis" >> "$dlog" 2>&1
    rrc=$?
    rc="$(meta_get "$armdir/run.meta" rc)"; drc="$(meta_get "$armdir/run.meta" deep_rc)"
    printf '%s\tEND\t%s\t%s\t%s\tr%s\trc=%s\tdeep=%s\n' "$(utc)" "$c" "$z" "$a" "$n" "${rc:-$rrc}" "${drc:-skip}" >> "$prog"
    ran=$((ran + 1))
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
  printf '%s\tDONE\tran=%s\tskipped=%s\trefused=%s\n' "$(utc)" "$ran" "$skipped" "$refused" > "$logs/$pname.done"
  note "drive: plan '$pname' done (ran=$ran skipped=$skipped refused=$refused) -> $prog"
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
  for pr in unknown dollar name nomodel; do
    python3 "$HELPER" profile "$work/p-$pr.env" > /dev/null 2>&1; expect_rc 2 $? "profile with a bad line ($pr) is refused"
  done
  local reg; reg="$(python3 "$HELPER" knob-registry "$PROFILES_DIR")"
  if printf '%s\n' "$reg" | grep -qx SEVERITY_RUBRIC && printf '%s\n' "$reg" | grep -qx OPERATIONALIZE_LENS \
     && printf '%s\n' "$reg" | grep -qx DEEP_HUNT_JOBS; then
    ok "the knob registry holds the shipped profile knobs + KNOBS"
  else
    bad "the knob registry lost a shipped knob"
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
  if [ -L "$a1/fx/code" ] && [ -L "$a1/fx/judging" ] && [ ! -L "$a1/fx/zone-hunt-out/map" ] && grep -q 'SELF-CHECK PASS' "$a1/stage.log"; then
    ok "stage: code/ + judging/ symlinked, map/ copied, coverage self-check passed"
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
  bash "$SELF" run --root "$root" --base "$base" --contest fx --zone src_pool --arm mock --repeat 1 --profile mock \
    --checkout "$co" --agentis "$stub" > /dev/null 2>&1; expect_rc 3 $? "run refuses an arm that already ran"
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
  if [ "$(grep -c $'\tSTART\t' "$prog" 2>/dev/null)" -eq 2 ] && [ "$(grep -c $'\tEND\t.*rc=0\tdeep=0$' "$prog" 2>/dev/null)" -eq 2 ] \
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
  self-test) cmd_self_test ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
