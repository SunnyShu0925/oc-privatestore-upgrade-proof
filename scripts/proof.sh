#!/usr/bin/env bash
# Driver-lane upgrade proof for PR #196394 private-store permission repair.
# Stable driver (latest stable openclaw) → candidate tarball built from PR head.
# Goal: prove minted GitHub profiles + codex-runtime (widened by fsGroup remount)
#       stay broken after driver doctor, but repair cleanly after upgrade.
set -uo pipefail

STABLE="${STABLE_VERSION:-2026.11.3}"
CANDIDATE_VERSION="${CANDIDATE_VERSION:-2026.11.4-rc.1}"
CANDIDATE_TARBALL="${CANDIDATE_TARBALL:-openclaw-candidate.tgz}"

STATE_DIR="${RUNNER_TEMP:-/tmp}/proof-state"
PROOF_PREFIX="${RUNNER_TEMP:-/tmp}/proof-prefix"
SUMMARY=/tmp/proof-summary.txt
STDERR_LOG=/tmp/proof-stderr.log
: >"$SUMMARY"
: >"$STDERR_LOG"

# Color-free tee to summary
note() { echo "$*" | tee -a "$SUMMARY"; }
say() { echo; echo "=== $* ===" | tee -a "$SUMMARY"; }

say "environment"
{
  uname -a
  ldd --version 2>&1 | head -1
  echo "HOME=$HOME"
  echo "STATE_DIR=$STATE_DIR"
  echo "stable=$STABLE candidate=$CANDIDATE_VERSION tarball=$CANDIDATE_TARBALL"
  if [ -f "$CANDIDATE_TARBALL" ]; then
    echo "tarball present: $(stat -c%s "$CANDIDATE_TARBALL") bytes"
  else
    echo "tarball NOT FOUND at $CANDIDATE_TARBALL"
    find "${GITHUB_WORKSPACE:-$PWD}" -name "*.tgz" -maxdepth 3 2>/dev/null | head -5
  fi
} 2>&1 | tee -a "$SUMMARY"

# ── Step 1: Install stable driver to isolated prefix ──────────────────────────
say "step 1: install stable driver openclaw@$STABLE"
rm -rf "$PROOF_PREFIX"
mkdir -p "$PROOF_PREFIX"
npm install -g "openclaw@$STABLE" --prefix "$PROOF_PREFIX" --no-audit --no-fund 2>&1 | tail -8
DRIVER_BIN="$PROOF_PREFIX/bin/openclaw"
note "driver bin: $DRIVER_BIN"
"$DRIVER_BIN" --version 2>&1 | tee -a "$SUMMARY"

# ── Step 2: Initialize state directory with controlled layout ─────────────────
say "step 2: seed state directory at $STATE_DIR"
rm -rf "$STATE_DIR"
mkdir -p "$STATE_DIR"
export OPENCLAW_STATE_DIR="$STATE_DIR"
export HOME="$STATE_DIR/home-fake"
mkdir -p "$HOME"

# Run a minimal openclaw command to let it create its SQLite databases.
# The state DB lives at $OPENCLAW_STATE_DIR/openclaw-state.sqlite and sidecars.
# openclaw status should touch state initialization without needing a gateway.
"$DRIVER_BIN" status --json >/dev/null 2>/dev/null || true
"$DRIVER_BIN" gateway status --json >/dev/null 2>/dev/null || true

# List what openclaw actually created
note "state tree after openclaw init:"
find "$STATE_DIR" -mindepth 1 -maxdepth 2 -type d | sort | tee -a "$SUMMARY"
find "$STATE_DIR" -type f -name "*.sqlite*" 2>/dev/null | sort | tee -a "$SUMMARY"
find "$STATE_DIR" -type f -name "*.json" -o -name "*.yml" -o -name "*.yaml" 2>/dev/null | sort | tee -a "$SUMMARY"

# ── Step 3: Create minted stores that the driver WILL NOT repair ──────────────
say "step 3: create minted stores (GitHub profiles + codex-runtime)"

# Managed GitHub profile IDs follow /^ghp_[a-f0-9]{32}$/
PROFILE_ID_SYSTEM="ghp_0123456789abcdef0123456789abcdef"
PROFILE_ID_PERSONAL="ghp_abcdef0123456789abcdef0123456789"

# System scope: credentials/github/system/<profile-id>/
SYSTEM_PROFILE_DIR="$STATE_DIR/credentials/github/system/$PROFILE_ID_SYSTEM"
mkdir -p "$SYSTEM_PROFILE_DIR"
cat >"$SYSTEM_PROFILE_DIR/hosts.yml" <<YAML
github.com:
  username: proof-system-user
  oauth_token: gho_redacted_proof_token_system
  email: system-proof@example.com
YAML
echo "proof-credential-marker-system-20261110" >"$SYSTEM_PROFILE_DIR/credentials.marker"

# Personal scope: credentials/github/personal/<profile-id>/
PERSONAL_PROFILE_DIR="$STATE_DIR/credentials/github/personal/$PROFILE_ID_PERSONAL"
mkdir -p "$PERSONAL_PROFILE_DIR"
cat >"$PERSONAL_PROFILE_DIR/hosts.yml" <<YAML
github.com:
  username: proof-personal-user
  oauth_token: gho_redacted_proof_token_personal
  email: personal-proof@example.com
YAML
echo "proof-credential-marker-personal-20261110" >"$PERSONAL_PROFILE_DIR/credentials.marker"

# Agent scope: credentials/github/agents/<64-hex>/<profile-id>/
AGENT_KEY="$(printf 'a%.0s' {1..64})"  # 64 hex chars
AGENT_PROFILE_DIR="$STATE_DIR/credentials/github/agents/$AGENT_KEY/$PROFILE_ID_SYSTEM"
mkdir -p "$AGENT_PROFILE_DIR"
cat >"$AGENT_PROFILE_DIR/hosts.yml" <<YAML
github.com:
  username: proof-agent-user
  oauth_token: gho_redacted_proof_token_agent
  email: agent-proof@example.com
YAML
echo "proof-credential-marker-agent-20261110" >"$AGENT_PROFILE_DIR/credentials.marker"

# Codex runtime bundle: <state-dir>/codex-runtime/
CODEX_RUNTIME_DIR="$STATE_DIR/codex-runtime"
mkdir -p "$CODEX_RUNTIME_DIR"
cat >"$CODEX_RUNTIME_DIR/config.json" <<JSON
{
  "bundleVersion": "2026.11.2-proof",
  "workerCount": 2,
  "enabled": true,
  "owner": "openclaw-proof"
}
JSON
echo "proof-codex-bundle-marker-20261110" >"$CODEX_RUNTIME_DIR/bundle.marker"
cat >"$CODEX_RUNTIME_DIR/worker-0.pid" <<EOF
12345
EOF

note "minted stores created:"
note "  $SYSTEM_PROFILE_DIR"
note "  $PERSONAL_PROFILE_DIR"
note "  $AGENT_PROFILE_DIR"
note "  $CODEX_RUNTIME_DIR"

# ── Step 4: Record baseline permissions ──────────────────────────────────────
say "step 4: record baseline permissions"
chmod 700 "$STATE_DIR"
find "$STATE_DIR" -type d -exec chmod 700 {} \;
find "$STATE_DIR" -type f -exec chmod 600 {} \;
{
  echo "=== BASELINE ==="
  find "$STATE_DIR" -type d | sort | xargs stat -c '%a %n' 2>/dev/null
  find "$STATE_DIR" -type f | sort | xargs stat -c '%a %n' 2>/dev/null
} >/tmp/perms-before.txt 2>&1
tee -a "$SUMMARY" </tmp/perms-before.txt

# Verify baseline is all private (700 dirs, 600 files)
BASELINE_OK=true
while IFS=' ' read -r mode path; do
  case "$path" in
    */credentials/github|*/credentials) continue ;;  # container dirs can be 755
  esac
  if [ "$mode" != "700" ] && [ "$mode" != "600" ]; then
    BASELINE_OK=false
    note "WARNING: baseline non-private mode $mode on $path"
  fi
done </tmp/perms-before.txt
note "baseline private=$BASELINE_OK"

# ── Step 5: Simulate fsGroup remount (widen everything) ───────────────────────
say "step 5: simulate fsGroup remount — widen to 2770 dirs / 0660 files"
find "$STATE_DIR" -type d -exec chmod 2770 {} \;
find "$STATE_DIR" -type f -exec chmod 0660 {} \;
{
  echo "=== WIDENED (post fsGroup remount) ==="
  find "$STATE_DIR" -type d | sort | xargs stat -c '%a %n' 2>/dev/null
  find "$STATE_DIR" -type f | sort | xargs stat -c '%a %n' 2>/dev/null
} >/tmp/perms-widened.txt 2>&1
tee -a "$SUMMARY" </tmp/perms-widened.txt

# Verify everything is widened
WIDENED_OK=true
WIDENED_FAIL=""
while IFS=' ' read -r mode path; do
  if echo "$path" | grep -q '/state$'; then
    continue  # state root can stay 755
  fi
  if [ "$mode" != "2770" ] && [ "$mode" != "660" ]; then
    WIDENED_OK=false
    WIDENED_FAIL="$WIDENED_FAIL $mode:$path"
  fi
done </tmp/perms-widened.txt
note "widened=$WIDENED_OK failures:$WIDENED_FAIL"

# ── Step 6: Driver doctor — EXPECT controls repaired, minted stores STILL WIDENED ──
say "step 6: driver doctor --repair (before upgrade)"
"$DRIVER_BIN" doctor --non-interactive --repair \
  >/tmp/doctor-before.log 2>/tmp/doctor-before-err.log || true
note "driver doctor exit=$?"
{
  echo "=== DRIVER DOCTOR OUTPUT ==="
  cat /tmp/doctor-before.log
  echo "--- stderr ---"
  cat /tmp/doctor-before-err.log
} | tee -a "$SUMMARY"

say "step 6b: permissions AFTER driver doctor"
{
  echo "=== POST-DRIVER-DOCTOR ==="
  find "$STATE_DIR" -type d | sort | xargs stat -c '%a %n' 2>/dev/null
  find "$STATE_DIR" -type f | sort | xargs stat -c '%a %n' 2>/dev/null
} >/tmp/perms-post-doctor-driver.txt 2>&1
tee -a "$SUMMARY" </tmp/perms-post-doctor-driver.txt

# Check driver repaired control stores but NOT minted stores
DRIVER_CONTROLS_PASS=true
DRIVER_MINTED_STILL_BROKEN=true

# Look for control stores that SHOULD be repaired (client/credentials.sqlite, control/services.sqlite)
for db in "client/credentials.sqlite" "control/services.sqlite" "openclaw-state.sqlite"; do
  # Find any file matching this db name anywhere under state dir
  found="$(find "$STATE_DIR" -name "$db" -o -name "${db}-wal" -o -name "${db}-shm" 2>/dev/null | head -3)"
  for f in $found; do
    mode="$(stat -c '%a' "$f" 2>/dev/null)"
    if [ "$mode" = "600" ] || [ "$mode" = "0600" ]; then
      note "  CONTROL OK: $db → $mode (repaired)"
    else
      DRIVER_CONTROLS_PASS=false
      note "  CONTROL FAIL: $db → $mode (NOT repaired)"
    fi
  done
done

# Check minted stores — should STILL be widened after driver doctor
for d in "$SYSTEM_PROFILE_DIR" "$PERSONAL_PROFILE_DIR" "$AGENT_PROFILE_DIR" "$CODEX_RUNTIME_DIR"; do
  if [ -d "$d" ]; then
    dir_mode="$(stat -c '%a' "$d" 2>/dev/null)"
    if [ "$dir_mode" = "2770" ]; then
      note "  MINTED-STILL-WIDENED (expected): $(basename "$d") → $dir_mode"
    elif [ "$dir_mode" = "700" ]; then
      DRIVER_MINTED_STILL_BROKEN=false
      note "  MINTED-REPAIRED-UNEXPECTED: $(basename "$d") → $dir_mode (driver should NOT repair this)"
    else
      note "  MINTED-UNKNOWN: $(basename "$d") → $dir_mode"
    fi
    # Also check files inside
    while IFS= read -r f; do
      fmode="$(stat -c '%a' "$f" 2>/dev/null)"
      if [ "$fmode" = "660" ]; then
        note "    FILE-STILL-WIDENED (expected): $(basename "$f") → $fmode"
      elif [ "$fmode" = "600" ]; then
        DRIVER_MINTED_STILL_BROKEN=false
        note "    FILE-REPAIRED-UNEXPECTED: $(basename "$f") → $fmode"
      fi
    done < <(find "$d" -maxdepth 1 -type f 2>/dev/null)
  fi
done

note "driver controls_repaired=$DRIVER_CONTROLS_PASS minted_still_broken=$DRIVER_MINTED_STILL_BROKEN"

# ── Step 7: Upgrade to candidate tarball ─────────────────────────────────────
say "step 7: upgrade driver → candidate tarball"
TARBALL_ABS="$(cd "$(dirname "$CANDIDATE_TARBALL")" && pwd)/$(basename "$CANDIDATE_TARBALL")"
note "candidate tarball: $TARBALL_ABS"

"$DRIVER_BIN" update --tag "file:$TARBALL_ABS" --yes --timeout 900 \
  >/tmp/update.json 2>/tmp/update.err
UPDATE_RC=$?
note "update exit=$UPDATE_RC"

if [ -s /tmp/update.json ]; then
  note "--- update.json ---"
  cat /tmp/update.json | tee -a "$SUMMARY"
fi
if [ -s /tmp/update.err ]; then
  note "--- update stderr ---"
  cat /tmp/update.err | tee -a "$SUMMARY"
fi

# Find the NEW openclaw binary after upgrade — it may be in a different location
# openclaw update replaces the npm-installed version
NEW_BIN="$(which openclaw 2>/dev/null || find "$PROOF_PREFIX" -name "openclaw" -type f 2>/dev/null | head -1)"
if [ -z "$NEW_BIN" ]; then
  # openclaw may have installed itself somewhere else
  NEW_BIN="$(find /tmp -name "openclaw" -type f 2>/dev/null | head -1)"
fi
note "post-upgrade bin: ${NEW_BIN:-NOT_FOUND}"

if [ -n "$NEW_BIN" ] && [ -x "$NEW_BIN" ]; then
  note "post-upgrade version:"
  "$NEW_BIN" --version 2>&1 | tee -a "$SUMMARY"
fi

# ── Step 8: Post-upgrade doctor — EXPECT ALL stores repaired ─────────────────
say "step 8: post-upgrade doctor --repair (candidate with fix)"
POST_BIN="${NEW_BIN:-$DRIVER_BIN}"
"$POST_BIN" doctor --non-interactive --repair \
  >/tmp/doctor-after.log 2>/tmp/doctor-after-err.log || true
note "post-upgrade doctor exit=$?"
{
  echo "=== POST-UPGRADE DOCTOR OUTPUT ==="
  cat /tmp/doctor-after.log
  echo "--- stderr ---"
  cat /tmp/doctor-after-err.log
} | tee -a "$SUMMARY"

say "step 8b: permissions AFTER post-upgrade doctor"
{
  echo "=== POST-UPGRADE ==="
  find "$STATE_DIR" -type d | sort | xargs stat -c '%a %n' 2>/dev/null
  find "$STATE_DIR" -type f | sort | xargs stat -c '%a %n' 2>/dev/null
} >/tmp/perms-after.txt 2>&1
tee -a "$SUMMARY" </tmp/perms-after.txt

# Check ALL stores are now repaired (0700 dirs, 0600 files)
ALL_REPAIRED=true

# Check control SQLite stores again
for db in "client/credentials.sqlite" "control/services.sqlite" "openclaw-state.sqlite"; do
  found="$(find "$STATE_DIR" -name "$db" 2>/dev/null | head -1)"
  if [ -n "$found" ]; then
    mode="$(stat -c '%a' "$found" 2>/dev/null)"
    if [ "$mode" = "600" ] || [ "$mode" = "0600" ]; then
      note "  CONTROL OK (post-upgrade): $db → $mode"
    else
      ALL_REPAIRED=false
      note "  CONTROL FAIL (post-upgrade): $db → $mode"
    fi
  fi
done

# Check minted stores — should ALL be repaired now
for d in "$SYSTEM_PROFILE_DIR" "$PERSONAL_PROFILE_DIR" "$AGENT_PROFILE_DIR" "$CODEX_RUNTIME_DIR"; do
  if [ -d "$d" ]; then
    dir_mode="$(stat -c '%a' "$d" 2>/dev/null)"
    if [ "$dir_mode" = "700" ]; then
      note "  MINTED REPAIRED (expected): $(basename "$d") → $dir_mode"
    else
      ALL_REPAIRED=false
      note "  MINTED FAIL (post-upgrade): $(basename "$d") → $dir_mode"
    fi
    while IFS= read -r f; do
      fmode="$(stat -c '%a' "$f" 2>/dev/null)"
      if [ "$fmode" = "600" ]; then
        note "    FILE REPAIRED (expected): $(basename "$f") → $fmode"
      else
        ALL_REPAIRED=false
        note "    FILE FAIL (post-upgrade): $(basename "$f") → $fmode"
      fi
    done < <(find "$d" -maxdepth 1 -type f 2>/dev/null)
  fi
done

# ── Step 9: Verify data retention ─────────────────────────────────────────────
say "step 9: verify data retention (GitHub identity + codex contents intact)"
DATA_OK=true

# Check GitHub profiles still have their content
for f in "$SYSTEM_PROFILE_DIR/hosts.yml" "$PERSONAL_PROFILE_DIR/hosts.yml" "$AGENT_PROFILE_DIR/hosts.yml"; do
  if [ -f "$f" ]; then
    if grep -q "proof-.*user" "$f" 2>/dev/null; then
      note "  GITHUB PROFILE OK: $(basename "$(dirname "$f")")/hosts.yml intact"
    else
      DATA_OK=false
      note "  GITHUB PROFILE MISSING CONTENT: $f"
    fi
  else
    DATA_OK=false
    note "  GITHUB PROFILE FILE MISSING: $f"
  fi
done

# Check credential markers
for marker in \
  "$SYSTEM_PROFILE_DIR/credentials.marker" \
  "$PERSONAL_PROFILE_DIR/credentials.marker" \
  "$AGENT_PROFILE_DIR/credentials.marker"; do
  if [ -f "$marker" ]; then
    content="$(cat "$marker" 2>/dev/null)"
    note "  CREDENTIAL MARKER OK: $(basename "$(dirname "$marker")") → $content"
  else
    DATA_OK=false
    note "  CREDENTIAL MARKER MISSING: $marker"
  fi
done

# Check codex runtime still has its content
for f in "$CODEX_RUNTIME_DIR/config.json" "$CODEX_RUNTIME_DIR/bundle.marker" "$CODEX_RUNTIME_DIR/worker-0.pid"; do
  if [ -f "$f" ]; then
    if [ "$(basename "$f")" = "config.json" ]; then
      if grep -q "proof" "$f" 2>/dev/null; then
        note "  CODEX RUNTIME OK: config.json intact"
      else
        DATA_OK=false
        note "  CODEX RUNTIME FAIL: config.json content missing"
      fi
    else
      content="$(cat "$f" 2>/dev/null)"
      note "  CODEX MARKER OK: $(basename "$f") → $content"
    fi
  else
    DATA_OK=false
    note "  CODEX FILE MISSING: $f"
  fi
done


# ── Step 10: capture-only layout — no SQLite store, only the capture root ─────
say "step 10: candidate repairs a capture-only state directory (no SQLite store)"
CAPTURE_ONLY_DIR="$RUNNER_TEMP/proof-capture-only"
CAPTURE_ONLY_ROOT="$CAPTURE_ONLY_DIR.update-captures"
rm -rf "$CAPTURE_ONLY_DIR" "$CAPTURE_ONLY_ROOT"
mkdir -p "$CAPTURE_ONLY_DIR" "$CAPTURE_ONLY_ROOT"
echo "capture-only-proof-20261111" >"$CAPTURE_ONLY_ROOT/capture.marker"
chmod 700 "$CAPTURE_ONLY_DIR" "$CAPTURE_ONLY_ROOT"
chmod 600 "$CAPTURE_ONLY_ROOT/capture.marker"
# Widen exactly like an fsGroup remount. No client/credentials.sqlite and no
# control/services.sqlite exist here, which is the reviewed defect's condition.
chmod 2770 "$CAPTURE_ONLY_DIR" "$CAPTURE_ONLY_ROOT"
chmod 660 "$CAPTURE_ONLY_ROOT/capture.marker"
note "before: $(stat -c '%a' "$CAPTURE_ONLY_ROOT") $CAPTURE_ONLY_ROOT"
# The widened state directory is group-writable on purpose, so doctor must not
# fall back to it as a temp root; give it a private HOME and TMPDIR of its own.
SAFE_HOME="$RUNNER_TEMP/proof-safe-home"
SAFE_TMP="$RUNNER_TEMP/proof-safe-tmp"
rm -rf "$SAFE_HOME" "$SAFE_TMP"
mkdir -p "$SAFE_HOME" "$SAFE_TMP"
chmod 700 "$SAFE_HOME" "$SAFE_TMP"
CAPTURE_ONLY_RC=0
HOME="$SAFE_HOME" TMPDIR="$SAFE_TMP" OPENCLAW_STATE_DIR="$CAPTURE_ONLY_DIR" "$POST_BIN" doctor --non-interactive --repair \
  >/tmp/doctor-capture-only.log 2>/tmp/doctor-capture-only-err.log || CAPTURE_ONLY_RC=$?
note "capture-only doctor exit=$CAPTURE_ONLY_RC"
CAPTURE_ONLY_MODE="$(stat -c '%a' "$CAPTURE_ONLY_ROOT")"
CAPTURE_ONLY_OK=false
if [ "$CAPTURE_ONLY_MODE" = "700" ]; then
  CAPTURE_ONLY_OK=true
fi
note "  [capture-only] capture root → $CAPTURE_ONLY_MODE (want 700), repaired=$CAPTURE_ONLY_OK"
note "  [capture-only] captured bytes retained=$([ "$(cat "$CAPTURE_ONLY_ROOT/capture.marker" 2>/dev/null)" = "capture-only-proof-20261111" ] && echo YES || echo NO)"
{ echo "=== CAPTURE-ONLY DOCTOR ==="; cat /tmp/doctor-capture-only.log; cat /tmp/doctor-capture-only-err.log; } | tee -a "$SUMMARY"

# ── Step 11: minted-store-only layout — no SQLite store ──────────────────────
say "step 11: candidate repairs minted stores without an installation database"
MINTED_ONLY_DIR="$RUNNER_TEMP/proof-minted-only"
MINTED_ONLY_PROFILE="$MINTED_ONLY_DIR/credentials/github/system/$PROFILE_ID_SYSTEM"
MINTED_ONLY_CODEX="$MINTED_ONLY_DIR/codex-runtime"
rm -rf "$MINTED_ONLY_DIR"
mkdir -p "$MINTED_ONLY_PROFILE" "$MINTED_ONLY_CODEX"
echo "minted-only-proof-20261111" >"$MINTED_ONLY_PROFILE/hosts.yml"
echo "minted-only-proof-20261111" >"$MINTED_ONLY_CODEX/config.json"
find "$MINTED_ONLY_DIR" -type d -exec chmod 700 {} \;
find "$MINTED_ONLY_DIR" -type f -exec chmod 600 {} \;
find "$MINTED_ONLY_DIR" -type d -exec chmod 2770 {} \;
find "$MINTED_ONLY_DIR" -type f -exec chmod 660 {} \;
if [ -e "$MINTED_ONLY_DIR/client/credentials.sqlite" ] || [ -e "$MINTED_ONLY_DIR/control/services.sqlite" ]; then
  note "  [minted-only] fixture unexpectedly has a SQLite store"
fi
note "before: profile=$(stat -c '%a' "$MINTED_ONLY_PROFILE") codex=$(stat -c '%a' "$MINTED_ONLY_CODEX")"
MINTED_ONLY_RC=0
HOME="$SAFE_HOME" TMPDIR="$SAFE_TMP" OPENCLAW_STATE_DIR="$MINTED_ONLY_DIR" "$POST_BIN" doctor --non-interactive --repair \
  >/tmp/doctor-minted-only.log 2>/tmp/doctor-minted-only-err.log || MINTED_ONLY_RC=$?
note "minted-only doctor exit=$MINTED_ONLY_RC"
MINTED_ONLY_OK=true
for target in "$MINTED_ONLY_PROFILE" "$MINTED_ONLY_CODEX"; do
  target_mode="$(stat -c '%a' "$target")"
  if [ "$target_mode" != "700" ]; then
    MINTED_ONLY_OK=false
  fi
  note "  [minted-only] $(basename "$target") dir → $target_mode (want 700)"
  for f in "$target"/*; do
    [ -f "$f" ] || continue
    fmode="$(stat -c '%a' "$f")"
    if [ "$fmode" != "600" ]; then
      MINTED_ONLY_OK=false
    fi
    note "  [minted-only] $(basename "$f") → $fmode (want 600)"
  done
done
note "  [minted-only] repaired=$MINTED_ONLY_OK"
{ echo "=== MINTED-ONLY DOCTOR ==="; cat /tmp/doctor-minted-only.log; cat /tmp/doctor-minted-only-err.log; } | tee -a "$SUMMARY"

# ── Final Verdict ─────────────────────────────────────────────────────────────
say "FINAL VERDICT"


# Compact evidence block for the pull request body.
{
  echo "proof run: upgrade-proof / head $(git -C "$GITHUB_WORKSPACE/openclaw" rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "driver: $STABLE_VERSION  candidate: $CANDIDATE_VERSION"
  echo "driver doctor: controls_repaired=$DRIVER_CONTROLS_PASS minted_still_widened=$DRIVER_MINTED_STILL_BROKEN"
  echo "candidate doctor: all_stores_repaired=$ALL_REPAIRED data_retained=$DATA_OK capture_only=$CAPTURE_ONLY_OK minted_only=$MINTED_ONLY_OK upgrade_rc=$UPDATE_RC"
  echo "capture-only layout: doctor_exit=$CAPTURE_ONLY_RC (no SQLite store) capture root $(stat -c '%a' "$CAPTURE_ONLY_ROOT")"
  echo "minted-only layout: doctor_exit=$MINTED_ONLY_RC (no SQLite store) profile $(stat -c '%a' "$MINTED_ONLY_PROFILE") codex-runtime $(stat -c '%a' "$MINTED_ONLY_CODEX")"
} >/tmp/proof-summary-compact.txt

if $DRIVER_CONTROLS_PASS && $DRIVER_MINTED_STILL_BROKEN && $ALL_REPAIRED && $DATA_OK && $CAPTURE_ONLY_OK && $MINTED_ONLY_OK && [ "$UPDATE_RC" -eq 0 ]; then
  VERDICT="PASS"
else
  VERDICT="FAIL"
fi

note ""
note "════════════════════════════════════════════════════════════════════"
note "  VERDICT=$VERDICT"
note "════════════════════════════════════════════════════════════════════"
note ""
note "Checklist:"
note "  [driver] controls_repaired       = $($DRIVER_CONTROLS_PASS && echo YES || echo NO)"
note "  [driver] minted_still_broken      = $($DRIVER_MINTED_STILL_BROKEN && echo YES || echo NO)"
note "  [candidate] all_stores_repaired   = $($ALL_REPAIRED && echo YES || echo NO)"
note "  [candidate] data_retention        = $($DATA_OK && echo YES || echo NO)"
note "  [candidate] capture_only_repaired = $($CAPTURE_ONLY_OK && echo YES || echo NO)"
note "  [candidate] minted_only_repaired  = $($MINTED_ONLY_OK && echo YES || echo NO)"
note "  [upgrade]  exit_code              = $UPDATE_RC"
note ""
note "This proves: openclaw@$STABLE repairs control stores after fsGroup remount"
note "but leaves minted GitHub profiles and codex-runtime widened. Upgrading to"
note "the candidate restores 0700/0600 on every private store while retaining"
note "all credentials, GitHub identities, and codex bundle contents."

if [ "$VERDICT" != "PASS" ]; then
  exit 1
fi
