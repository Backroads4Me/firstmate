#!/usr/bin/env bash
# Behavior tests for bin/fm-live-lab.sh (readiness checks and teardown) and
# bin/fm-claude-trust.sh --lab-home.
#
# Every readiness check is proven both ways against a real private tmux server
# and real processes, with no harness: it passes on a lab in the shape up builds
# and fails, by name, on the recorded lab miss it exists to catch. The live
# end-to-end run on the real harnesses is the builder's own `up`.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-live-lab)
: > "$TMP_ROOT/pids"
: > "$TMP_ROOT/tmux-dirs"
LIVE_LAB="$ROOT/bin/fm-live-lab.sh"
TRUST="$ROOT/bin/fm-claude-trust.sh"

live_lab_cleanup() {
  local dir pid
  while read -r pid; do [ -n "$pid" ] && kill "$pid" 2>/dev/null; done < "$TMP_ROOT/pids"
  while read -r dir; do
    [ -n "$dir" ] || continue
    env -u TMUX TMUX_TMPDIR="$dir" tmux kill-server 2>/dev/null
    case "$dir" in /tmp/fml.*) rm -rf "$dir" ;; esac
  done < "$TMP_ROOT/tmux-dirs"
  rm -rf "/tmp/fm-labt$$-mate" "/tmp/fm-labt$$-worker" "/tmp/fm-labt$$-other" /tmp/fm-labt"$$"-*+*
  fm_test_cleanup
}
trap live_lab_cleanup EXIT

command -v tmux >/dev/null 2>&1 || { echo "ok - skipped: tmux is not installed"; exit 0; }

FAKE_HOME="$TMP_ROOT/fakehome"
mkdir -p "$FAKE_HOME/.pi/agent" "$FAKE_HOME/.treehouse/existing-pool"
printf '{}\n' > "$FAKE_HOME/.pi/agent/trust.json"
export HOME="$FAKE_HOME"
unset CLAUDE_CONFIG_DIR TMUX

MATE_ID="labt$$-mate"
WORKER_ID="labt$$-worker"
NONCE=abc12345

digest() { shasum -a 256 "$1" | awk '{print $1}'; }

# make_lab <name> <harness> [<claude-config-dir>]: a lab root in the shape up
# builds, with a live private tmux server. Every readiness input starts in its
# passing state.
make_lab() {
  local root="$TMP_ROOT/$1" harness=$2 claude_dir=${3:-} home tmux_dir lock_pid
  home="$root/home"
  mkdir -p "$root"
  "$ROOT/bin/fm-lab-home.sh" create "$home" >/dev/null || fail "lab home create"
  cp -R "$ROOT/bin" "$home/bin"
  cp "$ROOT/AGENTS.md" "$home/AGENTS.md"
  mkdir -p "$home/.pi" "$root/mate/state" "$root/gates" "$root/treehouse"
  cp -R "$ROOT/.pi/extensions" "$home/.pi/extensions"
  git -C "$home" init -q -b main
  git -C "$home" add -A bin AGENTS.md .pi
  git -C "$home" -c user.name=t -c user.email=t@example.invalid commit -qm lab
  tmux_dir=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$home") || fail "lab tmux dir"
  printf '%s\n' "$tmux_dir" >> "$TMP_ROOT/tmux-dirs"
  find "$HOME/.treehouse" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort > "$root/.treehouse-before"
  {
    echo 'fm-live-lab v1'
    echo "harness=$harness"
    echo "home=$home"
    echo "expect_host=yes"
    echo "mate=yes"
    echo "worker=yes"
    echo "nonce=$NONCE"
    echo "mate_id=$MATE_ID"
    echo "worker_id=$WORKER_ID"
    echo "pi_trust=$(digest "$HOME/.pi/agent/trust.json")"
    echo "claude_config_dir=$claude_dir"
    echo "tmux_dir=$tmux_dir"
  } > "$root/.fm-live-lab"

  lab_tmux "$root" new-session -d -s firstmate -n lab -c "$root" 'exec sleep 600'
  lab_tmux "$root" new-window -d -t firstmate: -n main -c "$home" "printf 'LABREADY-$NONCE\n'; exec sleep 600"
  lab_tmux "$root" new-window -d -t firstmate: -n "fm-$MATE_ID" -c "$root/mate" 'exec sleep 600'
  lab_tmux "$root" new-window -d -t firstmate: -n "fm-$WORKER_ID" -c "$root" 'exec sleep 600'
  fm_write_meta "$home/state/$MATE_ID.meta" "window=firstmate:fm-$MATE_ID" "tasktmp=/tmp/fm-$MATE_ID"
  fm_write_meta "$home/state/$WORKER_ID.meta" "window=firstmate:fm-$WORKER_ID" "tasktmp=/tmp/fm-$WORKER_ID"
  printf 'paused [at=1]: waiting on gate file %s to exist\n' "$root/gates/$WORKER_ID" > "$home/state/$WORKER_ID.status"

  lock_pid=$(lab_tmux "$root" display-message -p -t firstmate:=main '#{pane_pid}')
  printf '%s\n' "$lock_pid" > "$home/state/.lock"
  printf '%s\n' "$(lab_tmux "$root" display-message -p -t "firstmate:=fm-$MATE_ID" '#{pane_pid}')" > "$root/mate/state/.lock"
  start_watcher "$home"
  printf 'host\t%s\tx\n' "$(start_sleeper)" > "$home/state/.supervision-host"
  printf '%s\n' \
    '{"seq":1,"epoch":1,"key":"k","id":"a","tag":"captain","text":"probe"}' \
    '{"seq":2,"epoch":2,"key":"k","id":"b","tag":"main","text":"LABREADY"}' > "$home/state/.host-mirror.jsonl"
  write_pi_markers "$home" "$lock_pid"
  [ "$harness" = claude ] && node -e 'const fs=require("node:fs");const [s,h,r]=process.argv.slice(1);fs.writeFileSync(s,JSON.stringify({keep:1,projects:{[h]:{hasTrustDialogAccepted:true},[r+"/mate"]:{hasTrustDialogAccepted:true},"/elsewhere/project":{hasTrustDialogAccepted:true}}},null,2)+"\n")' \
    "${claude_dir:-$HOME}/.claude.json" "$home" "$root"
  printf '%s\n' "$root"
}

lab_tmux() {  # <root> <tmux args...>
  local dir
  dir=$(sed -n 's/^tmux_dir=//p' "$1/.fm-live-lab")
  shift
  env -u TMUX TMUX_TMPDIR="$dir" tmux "$@"
}

start_sleeper() {
  sleep 600 >/dev/null 2>&1 &
  printf '%s\n' "$!" >> "$TMP_ROOT/pids"
  printf '%s\n' "$!"
}

start_watcher() {  # <home>: a live process holding a matching watcher lock
  local home=$1 pid lock="$1/state/.watch.lock"
  pid=$(start_sleeper)
  mkdir -p "$lock"
  printf '%s\n' "$pid" > "$lock/pid"
  printf '%s\n' "$home" > "$lock/fm-home"
  printf '%s\n' "$home/bin/fm-watch.sh" > "$lock/watcher-path"
  fm_test_pid_identity "$pid" > "$lock/pid-identity"
  touch "$home/state/.last-watcher-beat"
}

write_pi_markers() {  # <home> <lock-pid>
  local home=$1 pid=$2
  v() { FM_HOME="$home" bash -c '. "$1/bin/fm-wake-lib.sh"; fm_pi_extension_version "$1/.pi/extensions/$2"' _ "$home" "$1"; }
  printf '%s\n%s\ngeneration=1 phase=active\n' "$(v fm-primary-pi-watch.ts)" "$pid" > "$home/state/.pi-watch-extension-loaded"
  printf '%s\n%s\n' "$(v fm-primary-turnend-guard.ts)" "$pid" > "$home/state/.pi-turnend-extension-loaded"
  printf '%s\n' "$pid" > "$home/state/.pi-branch-extension-loaded"
}

run_check() {  # <root>: sets CHECK_OUT and CHECK_RC
  CHECK_OUT=$("$LIVE_LAB" check "$1" 2>&1)
  CHECK_RC=$?
}

set_record() {  # <root> <key> <value>
  sed -i.bak "s|^$2=.*|$2=$3|" "$1/.fm-live-lab" && rm -f "$1/.fm-live-lab.bak"
}

# ---- Claude lab: every check passes on the shape up builds -----------------

C=$(make_lab c claude)
CH="$C/home"
run_check "$C"
expect_code 0 "$CHECK_RC" "a Claude lab in up's shape is ready: $CHECK_OUT"
for name in primary probe trust mirror host watcher mate worker treehouse; do
  assert_contains "$CHECK_OUT" "ok $name:" "the $name check passes on a ready Claude lab"
done
pass "a ready Claude lab passes every readiness check"

# primary: the lab session lock must name a live process (session start ran).
printf '999999\n' > "$CH/state/.lock"
run_check "$C"
expect_code 1 "$CHECK_RC" "a dead session lock is not ready"
assert_contains "$CHECK_OUT" "fail primary: the lab session lock names no live process" "primary names the dead lock"
lab_tmux "$C" display-message -p -t firstmate:=main '#{pane_pid}' > "$CH/state/.lock"
pass "primary fails when session start never took the lab lock"

# primary: a lab home that is a linked worktree is not the genuine primary
# checkout a mirrored Claude primary needs.
WT_CASE="$TMP_ROOT/wtcase"
fm_git_worktree "$WT_CASE/project" "$WT_CASE/wt" lab-wt
cp "$C/.fm-live-lab" "$WT_CASE/.fm-live-lab"
set_record "$WT_CASE" home "$WT_CASE/wt"
lab_tmux "$C" new-window -d -t firstmate: -n wtmain -c "$WT_CASE/wt" 'exec sleep 600'
lab_tmux "$C" kill-window -t firstmate:=main
lab_tmux "$C" rename-window -t firstmate:=wtmain main
run_check "$WT_CASE"
assert_contains "$CHECK_OUT" "fail primary: the lab home is not a primary checkout" "primary refuses a linked-worktree home"
lab_tmux "$C" kill-window -t firstmate:=main
lab_tmux "$C" new-window -d -t firstmate: -n main -c "$CH" "printf 'LABREADY-$NONCE\n'; exec sleep 600"
lab_tmux "$C" display-message -p -t firstmate:=main '#{pane_pid}' > "$CH/state/.lock"
pass "primary fails when the primary runs in a linked worktree instead of the lab's primary checkout"

# probe: the nonce reply proves the model is accepted and a turn completed.
set_record "$C" nonce 00000000
run_check "$C"
assert_contains "$CHECK_OUT" "fail probe: no LABREADY-00000000 reply" "probe names the missing reply"
set_record "$C" nonce "$NONCE"
pass "probe fails when the primary never answered its nonce"

# trust: the workspace-trust prompt wedged the first lab.
cp "$HOME/.claude.json" "$TMP_ROOT/claude.json.keep"
node -e 'const fs=require("node:fs");const [s,h]=process.argv.slice(1);const j=JSON.parse(fs.readFileSync(s,"utf8"));delete j.projects[h];fs.writeFileSync(s,JSON.stringify(j))' "$HOME/.claude.json" "$CH"
run_check "$C"
assert_contains "$CHECK_OUT" "fail trust: $CH has no registered Claude workspace trust" "trust names the untrusted home"
cp "$TMP_ROOT/claude.json.keep" "$HOME/.claude.json"
pass "trust fails when the lab home has no registered Claude trust"

# mirror: the dialog mirror feed must be wired and hold both sides.
cp "$CH/state/.host-mirror.jsonl" "$TMP_ROOT/mirror.keep"
head -n 1 "$TMP_ROOT/mirror.keep" > "$CH/state/.host-mirror.jsonl"
run_check "$C"
assert_contains "$CHECK_OUT" "fail mirror: the dialog mirror has no captain and main entry yet (captain=1 main=0)" "mirror needs a main entry"
rm -f "$CH/state/.host-mirror.jsonl"
run_check "$C"
assert_contains "$CHECK_OUT" "fail mirror: fm-host-mirror.sh check exited 1" "mirror fails without a mirror file"
cp "$TMP_ROOT/mirror.keep" "$CH/state/.host-mirror.jsonl"
pass "mirror fails when the feed is unwired or has not recorded a whole turn"

# host: expected on Claude, refused when it should be absent.
host_pid=$(awk -F '\t' '{print $2}' "$CH/state/.supervision-host")
kill "$host_pid" 2>/dev/null
wait "$host_pid" 2>/dev/null
run_check "$C"
assert_contains "$CHECK_OUT" "fail host: no live supervision host (expected one)" "host names the missing host"
set_record "$C" expect_host no
run_check "$C"
assert_contains "$CHECK_OUT" "ok host: none running, as expected" "an opted-out lab expects no host"
assert_not_contains "$CHECK_OUT" "mirror" "an opted-out lab skips the mirror"
host_pid=$(start_sleeper)
printf 'host\t%s\tx\n' "$host_pid" > "$CH/state/.supervision-host"
run_check "$C"
assert_contains "$CHECK_OUT" "fail host: supervision host pid $host_pid runs (expected none)" "an opted-out lab refuses a host"
set_record "$C" expect_host yes
pass "host passes and fails according to --expect-host"

# watcher: a stale beacon is not supervision.
touch -t 202001010000 "$CH/state/.last-watcher-beat"
run_check "$C"
assert_contains "$CHECK_OUT" "fail watcher: no live watcher with a fresh beacon" "watcher names the stale beacon"
touch "$CH/state/.last-watcher-beat"
pass "watcher fails on a stale beacon"

# mate: its own window, targeted exactly. A missing window must not resolve to
# another one (tmux falls back to the current window for an unknown name).
lab_tmux "$C" kill-window -t "firstmate:=fm-$MATE_ID"
run_check "$C"
assert_contains "$CHECK_OUT" "fail mate: the $MATE_ID window is not running" "mate names its missing window"
lab_tmux "$C" new-window -d -t firstmate: -n "fm-$MATE_ID" -c "$C/mate" 'exec sleep 600'
rm -f "$C/mate/state/.lock"
run_check "$C"
assert_contains "$CHECK_OUT" "fail mate: the mate holds no session lock yet" "mate needs its own session lock"
lab_tmux "$C" display-message -p -t "firstmate:=fm-$MATE_ID" '#{pane_pid}' > "$C/mate/state/.lock"
pass "mate fails when its window is gone or it never reached its charter"

# worker: it must have declared its gate wait.
: > "$CH/state/$WORKER_ID.status"
run_check "$C"
assert_contains "$CHECK_OUT" "fail worker: the worker has not declared its gate wait yet" "worker needs its paused line"
printf 'paused [at=1]: waiting on gate file %s to exist\n' "$C/gates/$WORKER_ID" > "$CH/state/$WORKER_ID.status"
pass "worker fails until the worker parks on its gate"

# treehouse: a worker pool must land inside the lab, never in ~/.treehouse.
mkdir "$HOME/.treehouse/notes-leaked"
run_check "$C"
assert_contains "$CHECK_OUT" "fail treehouse: new ~/.treehouse entries: notes-leaked" "treehouse names the leaked pool"
rmdir "$HOME/.treehouse/notes-leaked"
run_check "$C"
expect_code 0 "$CHECK_RC" "the Claude lab is ready again after every restore: $CHECK_OUT"
pass "treehouse fails when a pool lands in ~/.treehouse"

# ---- Pi lab: extensions and the session-only trust store -------------------

P=$(make_lab p pi)
PH="$P/home"
run_check "$P"
expect_code 0 "$CHECK_RC" "a Pi lab in up's shape is ready: $CHECK_OUT"
assert_contains "$CHECK_OUT" "ok extensions: fm-primary-pi-watch fm-primary-turnend-guard fm-branch-supervision" "all three extensions load"
assert_contains "$CHECK_OUT" "ok trust: Pi trust store unchanged" "the Pi trust store is untouched"
assert_not_contains "$CHECK_OUT" "mirror" "a Pi lab has no host mirror check"
rm -f "$PH/state/.pi-branch-extension-loaded"
run_check "$P"
assert_contains "$CHECK_OUT" "fail extensions: fm-branch-supervision.ts is not loaded by the lock holder" "the missing branch extension is named"
printf '%s\n' "$(sed -n 1p "$PH/state/.lock")" > "$PH/state/.pi-branch-extension-loaded"
printf 'stale\n' > "$PH/state/.pi-turnend-extension-loaded"
run_check "$P"
assert_contains "$CHECK_OUT" "fail extensions: fm-primary-turnend-guard.ts is not loaded at its current build" "a stale turn-end build is named"
pass "extensions fail when the Pi lab lacks the branch extension or loads a stale build"

# ---- down -------------------------------------------------------------------

NOT_LAB="$TMP_ROOT/not-a-lab"
mkdir -p "$NOT_LAB/keep"
out=$("$LIVE_LAB" down "$NOT_LAB" 2>&1)
expect_code 1 "$?" "down refuses a path without a lab record"
assert_contains "$out" "carries no lab record" "the refusal names the missing record"
assert_present "$NOT_LAB/keep" "a refused down removes nothing"
pass "down refuses anything up did not build"

C_HASH=$(printf '%s' "$CH" | shasum -a 256 | awk '{print $1}')
OTHER_ID="labt$$-other"
fm_write_meta "$CH/state/$OTHER_ID.meta" "window=firstmate:fm-$OTHER_ID" "tasktmp=/tmp/fm-$OTHER_ID"
mkdir -p "/tmp/fm-$WORKER_ID/gotmp" "/tmp/fm-$MATE_ID" "/tmp/fm-$WORKER_ID+$C_HASH" "/tmp/fm-$OTHER_ID+$C_HASH" "/tmp/fm-$OTHER_ID"
printf 'sleep 600\n' > "$C/stray.sh"
bash "$C/stray.sh" &
STRAY=$!
until STRAY_CHILD=$(pgrep -P "$STRAY" sleep); do sleep 0.1; done
# A sibling lab root that shares this root as a string prefix is not this lab.
mkdir -p "${C}2"
printf 'sleep 600\n' > "${C}2/stray.sh"
bash "${C}2/stray.sh" 2>/dev/null &
SIBLING=$!
printf '%s\n' "$SIBLING" >> "$TMP_ROOT/pids"
# The worker spawn failed after keeping its task temp dirs, before its meta.
rm -f "$CH/state/$WORKER_ID.meta"
C_TMUX=$(sed -n 's/^tmux_dir=//p' "$C/.fm-live-lab")
out=$("$LIVE_LAB" down "$C" 2>&1)
expect_code 0 "$?" "down of a clean Claude lab succeeds: $out"
! kill -0 "$STRAY" 2>/dev/null || fail "down stops processes that name the lab root"
! kill -0 "$STRAY_CHILD" 2>/dev/null || fail "down stops their descendants, which need not name the root"
assert_absent "$C" "down removes the lab root"
kill -0 "$SIBLING" 2>/dev/null || fail "down leaves a sibling root's process running"
pkill -P "$SIBLING" 2>/dev/null
kill "$SIBLING" 2>/dev/null
assert_absent "$C_TMUX" "down removes the private tmux directory"
assert_absent "/tmp/fm-$WORKER_ID" "down removes the worker's task temp dir, even without its meta"
assert_absent "/tmp/fm-$MATE_ID" "down removes the mate's task temp dir"
assert_absent "/tmp/fm-$WORKER_ID+$C_HASH" "down removes the worker's launch dir"
assert_absent "/tmp/fm-$OTHER_ID+$C_HASH" "down removes a lab-spawned task's launch dir scoped to the lab home"
assert_present "/tmp/fm-$OTHER_ID" "down keeps a task temp dir another home could share"
kept=$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));console.log(JSON.stringify([j.keep,Object.keys(j.projects).sort()]))' "$HOME/.claude.json")
assert_equals '[1,["/elsewhere/project"]]' "$kept" "down removes exactly the lab's Claude project entries"
assert_contains "$out" "removed: 2 Claude project entries" "down reports the removed entries"
pass "down stops the lab, removes its trust entries and task temp dirs, and keeps everything else"

# The Claude store up selected is the one check and down use, even from a later
# shell with another CLAUDE_CONFIG_DIR, and a symlinked store stays a symlink.
SC="$TMP_ROOT/claude-config"
mkdir -p "$SC"
S=$(make_lab s claude "$SC")
mv "$SC/.claude.json" "$TMP_ROOT/claude-store-target.json"
ln -s "$TMP_ROOT/claude-store-target.json" "$SC/.claude.json"
HOME_STORE_BEFORE=$(digest "$HOME/.claude.json")
CHECK_OUT=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/other-config" "$LIVE_LAB" check "$S" 2>&1)
assert_contains "$CHECK_OUT" "ok trust: $S/home is trusted in the Claude store" "check reads the recorded store"
out=$(CLAUDE_CONFIG_DIR="$TMP_ROOT/other-config" "$LIVE_LAB" down "$S" 2>&1)
expect_code 0 "$?" "down of a lab on a configured store succeeds: $out"
assert_contains "$out" "removed: 2 Claude project entries" "down removes the entries from the recorded store"
[ -L "$SC/.claude.json" ] || fail "down keeps a symlinked Claude store a symlink"
kept=$(node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));console.log(JSON.stringify([j.keep,Object.keys(j.projects).sort()]))' "$TMP_ROOT/claude-store-target.json")
assert_equals '[1,["/elsewhere/project"]]' "$kept" "down rewrites the symlink's target"
assert_equals "$HOME_STORE_BEFORE" "$(digest "$HOME/.claude.json")" "down leaves the default store alone"
pass "check and down use the recorded Claude store and keep a symlinked store linked"

printf '{"trusted":["/somewhere"]}\n' > "$HOME/.pi/agent/trust.json"
run_check "$P"
assert_contains "$CHECK_OUT" "fail trust: the Pi trust store changed since up began" "a written Pi trust store is caught"
pass "trust fails on Pi when the lab wrote the persistent Pi trust store"

out=$("$LIVE_LAB" down "$P" 2>&1)
expect_code 1 "$?" "down reports a changed Pi trust store"
assert_contains "$out" "the Pi trust store changed since up began; left as is" "the Pi trust change is named"
assert_absent "$P" "the lab is still removed"
assert_equals '{"trusted":["/somewhere"]}' "$(cat "$HOME/.pi/agent/trust.json")" "down never rewrites the Pi trust store"
pass "down removes the lab but reports, without reverting, a written Pi trust store"

# ---- up argument safety -----------------------------------------------------

EXISTING="$TMP_ROOT/existing"
mkdir -p "$EXISTING/keep"
out=$("$LIVE_LAB" up --harness claude "$EXISTING" 2>&1)
expect_code 1 "$?" "up refuses an existing lab root"
assert_contains "$out" "a lab root must not exist yet" "the refusal names the existing root"
assert_present "$EXISTING/keep" "a refused up touches nothing"
out=$("$LIVE_LAB" up --harness codex "$TMP_ROOT/new" 2>&1)
expect_code 1 "$?" "up refuses an unsupported harness"
assert_absent "$TMP_ROOT/new" "a refused harness creates nothing"
pass "up refuses an existing root and an unsupported harness"

# ---- fm-claude-trust.sh --lab-home -------------------------------------------

T="$TMP_ROOT/trust"
mkdir -p "$T/config"
"$ROOT/bin/fm-lab-home.sh" create "$T/home" >/dev/null
cp "$ROOT/AGENTS.md" "$T/home/AGENTS.md"
mkdir -p "$T/home/bin"
git -C "$T/home" init -q -b main
out=$(CLAUDE_CONFIG_DIR="$T/config" "$TRUST" --lab-home "$T/home" 2>&1)
expect_code 0 "$?" "a marked lab primary checkout is trusted: $out"
TH=$(cd -P "$T/home" && pwd -P)
node -e 'const j=JSON.parse(require("node:fs").readFileSync(process.argv[1],"utf8"));process.exit(j.projects[process.argv[2]].hasTrustDialogAccepted===true&&!("hasClaudeMdExternalIncludesApproved" in j.projects[process.argv[2]])?0:1)' \
  "$T/config/.claude.json" "$TH" || fail "lab-home trust is trust-only"

mkdir -p "$T/plain/bin"
cp "$ROOT/AGENTS.md" "$T/plain/AGENTS.md"
git -C "$T/plain" init -q -b main
out=$(CLAUDE_CONFIG_DIR="$T/config" "$TRUST" --lab-home "$T/plain" 2>&1)
expect_code 1 "$?" "an unmarked checkout is refused"
assert_contains "$out" "carries no lab-home marker" "the refusal names the missing marker"

fm_git_worktree "$T/proj" "$T/wt" lab-trust-wt
printf 'fm-lab-home v1\n' > "$T/wt/.fm-lab-home"
cp "$ROOT/AGENTS.md" "$T/wt/AGENTS.md"
mkdir -p "$T/wt/bin"
out=$(CLAUDE_CONFIG_DIR="$T/config" "$TRUST" --lab-home "$T/wt" 2>&1)
expect_code 1 "$?" "a linked worktree is refused"
assert_contains "$out" "is a linked worktree" "the refusal names the linked worktree"

rm "$T/home/.fm-lab-home"
ln -s "$T/wt/.fm-lab-home" "$T/home/.fm-lab-home"
out=$(CLAUDE_CONFIG_DIR="$T/config" "$TRUST" --lab-home "$T/home" 2>&1)
expect_code 1 "$?" "a symlinked marker is refused"
assert_contains "$out" "is a symlink" "the refusal names the symlink"
pass "fm-claude-trust.sh --lab-home trusts only a marked lab primary checkout"
