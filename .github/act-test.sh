#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# Local workflow test runner using act (https://github.com/nektos/act)
#
# Usage:
#   .github/act-test.sh [test]
#
# Available tests:
#   all         Run all tests (default)
#   happy       Happy path: valid version bump
#   downgrade   Version downgrade must fail
#   invalid     Invalid semver must fail
#   no-change   Push with no Chart.yaml change must skip release job
#
# Prerequisites:
#   - act installed (brew install act)
#   - Docker running (lima-docker or Docker Desktop)
#   - .github/act.secrets populated with a valid GITHUB_TOKEN
#
# Environment:
#   DOCKER_HOST   Override Docker socket path (auto-detected if unset)
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WORKFLOW="$SCRIPT_DIR/workflows/release-charts.yml"
EVENT_FILE="$SCRIPT_DIR/act-push-event.json"
SECRETS_FILE="$SCRIPT_DIR/act.secrets"
CHART_DIR="$REPO_ROOT/app"
CHART_YAML="$CHART_DIR/Chart.yaml"

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
pass() { echo -e "${GREEN}✅ PASS${NC}: $*"; }
fail() { echo -e "${RED}❌ FAIL${NC}: $*"; }
info() { echo -e "${CYAN}──${NC} $*"; }
warn() { echo -e "${YELLOW}⚠️  ${NC}$*"; }

# ── Preflight checks ──────────────────────────────────────────────────────────
check_prerequisites() {
  if ! command -v act &>/dev/null; then
    echo "act not found. Install with: brew install act"; exit 1
  fi
  if ! command -v git &>/dev/null; then
    echo "git not found."; exit 1
  fi
  if [ ! -f "$SECRETS_FILE" ]; then
    echo "Missing $SECRETS_FILE — copy from act.secrets.example and fill in GITHUB_TOKEN"; exit 1
  fi
  if ! grep -q 'GITHUB_TOKEN=' "$SECRETS_FILE" || grep -q 'fake-token' "$SECRETS_FILE"; then
    warn "GITHUB_TOKEN in act.secrets looks like a placeholder. Tests requiring gh CLI may fail."
  fi
}

# ── Docker socket auto-detection ──────────────────────────────────────────────
detect_docker_host() {
  if [ -n "${DOCKER_HOST:-}" ]; then
    echo "$DOCKER_HOST"; return
  fi
  # Lima (default on Apple Silicon)
  local lima_sock="$HOME/.lima/docker/sock/docker.sock"
  if [ -S "$lima_sock" ]; then
    echo "unix://$lima_sock"; return
  fi
  # Docker Desktop
  if [ -S /var/run/docker.sock ]; then
    echo "unix:///var/run/docker.sock"; return
  fi
  echo ""
}

# ── Git helpers ───────────────────────────────────────────────────────────────
current_version() {
  grep '^version:' "$CHART_YAML" | awk '{print $2}'
}

set_version() {
  local ver="$1"
  sed -i '' "s/^version: .*/version: $ver/" "$CHART_YAML"
}

commit_chart() {
  local msg="$1"
  git -C "$REPO_ROOT" add "$CHART_YAML"
  git -C "$REPO_ROOT" commit -q -m "$msg"
}

update_event_payload() {
  # Point the event payload before/after at the last two commits
  local after before
  after=$(git -C "$REPO_ROOT" rev-parse HEAD)
  before=$(git -C "$REPO_ROOT" rev-parse HEAD~1)
  sed -i '' "s/\"before\": \".*\"/\"before\": \"$before\"/" "$EVENT_FILE"
  sed -i '' "s/\"after\": \".*\"/\"after\": \"$after\"/"   "$EVENT_FILE"
}

restore_version() {
  local ver="$1"
  set_version "$ver"
  git -C "$REPO_ROOT" add "$CHART_YAML"
  git -C "$REPO_ROOT" commit -q -m "chore: restore version to $ver after test"
}

# ── act runner ────────────────────────────────────────────────────────────────
run_act() {
  local docker_host="$1"
  DOCKER_HOST="$docker_host" act push \
    -W "$WORKFLOW" \
    -e "$EVENT_FILE" \
    --secret-file "$SECRETS_FILE" \
    -P ubuntu-latest=-self-hosted \
    2>&1
}

# Returns 0 if act output contains job success, 1 if job failed
act_succeeded() {
  echo "$1" | grep -q "Job succeeded" && ! echo "$1" | grep -q "Job failed"
}

act_failed() {
  echo "$1" | grep -q "Job failed"
}

# ── Individual test cases ─────────────────────────────────────────────────────

test_happy_path() {
  info "Test: happy path — valid patch bump"
  local orig_ver; orig_ver=$(current_version)
  local parts major minor patch
  IFS='.' read -r major minor patch <<< "$orig_ver"
  local new_ver="${major}.${minor}.$((patch + 1))"

  set_version "$new_ver"
  commit_chart "test: bump $orig_ver → $new_ver (happy path)"
  update_event_payload

  local output; output=$(run_act "$DOCKER_HOST_VAL")

  # Restore immediately before asserting so repo is clean on failure too
  restore_version "$orig_ver"
  update_event_payload

  # All steps up to the GHCR push must pass. The GHCR login/push may fail
  # locally when act.secrets holds a placeholder token — that is expected and
  # does not indicate a workflow logic error. With a real token the push would
  # publish a chart to ghcr.io, so avoid the happy path with a live token
  # unless you actually intend to publish.
  local pre_push_ok=true
  echo "$output" | grep -q "Version OK (patch bump)"     || pre_push_ok=false
  echo "$output" | grep -q "✅  Success - Main Helm lint"  || pre_push_ok=false
  echo "$output" | grep -q "Generate release notes"      || pre_push_ok=false

  local push_failure
  push_failure=$(echo "$output" | grep -E "(GitHub Container Registry|Push chart to GHCR)" | grep "❌" || true)

  if $pre_push_ok && [ -n "$push_failure" ]; then
    pass "happy path ($orig_ver → $new_ver) — all pre-push steps passed; GHCR push skipped locally (expected)"
  elif act_succeeded "$output"; then
    pass "happy path ($orig_ver → $new_ver) — all steps passed"
  else
    fail "happy path — unexpected failure before GHCR push step:"
    echo "$output" | grep -E "(error|❌|✅|Run Main)" | tail -20
    return 1
  fi
}

test_version_downgrade() {
  info "Test: version downgrade must fail"
  local orig_ver; orig_ver=$(current_version)
  local parts major minor patch
  IFS='.' read -r major minor patch <<< "$orig_ver"
  local new_ver="${major}.${minor}.$((patch - 1))"

  # Guard: can't downgrade patch below 0
  if [ "$patch" -eq 0 ]; then
    warn "Patch is already 0, using minor downgrade"
    new_ver="${major}.$((minor - 1)).0"
  fi

  set_version "$new_ver"
  commit_chart "test: downgrade $orig_ver → $new_ver (must fail)"
  update_event_payload

  local output; output=$(run_act "$DOCKER_HOST_VAL")

  restore_version "$orig_ver"
  update_event_payload

  if act_failed "$output" && echo "$output" | grep -q "Version must be strictly increasing"; then
    pass "version downgrade correctly rejected ($orig_ver → $new_ver)"
  else
    fail "version downgrade — expected workflow to fail with monotonic error"
    echo "$output" | grep -E "(error|❌|Run Main)" | tail -10
    return 1
  fi
}

test_invalid_semver() {
  info "Test: invalid semver must fail"
  local orig_ver; orig_ver=$(current_version)

  set_version "1.2.3-beta"
  commit_chart "test: invalid semver 1.2.3-beta (must fail)"
  update_event_payload

  local output; output=$(run_act "$DOCKER_HOST_VAL")

  restore_version "$orig_ver"
  update_event_payload

  if act_failed "$output" && echo "$output" | grep -q "not valid semver"; then
    pass "invalid semver correctly rejected"
  else
    fail "invalid semver — expected workflow to fail with format error"
    echo "$output" | grep -E "(error|❌|Run Main)" | tail -10
    return 1
  fi
}

test_no_chart_change() {
  info "Test: push with no Chart.yaml change must skip release job"

  # Make a non-Chart.yaml commit
  local readme="$REPO_ROOT/app/README.md"
  echo "" >> "$readme"
  git -C "$REPO_ROOT" add "$readme"
  git -C "$REPO_ROOT" commit -q -m "test: values-only change, no Chart.yaml bump"
  update_event_payload

  local output; output=$(run_act "$DOCKER_HOST_VAL")

  # Restore readme
  git -C "$REPO_ROOT" checkout HEAD~1 -- "$readme" 2>/dev/null || true
  git -C "$REPO_ROOT" add "$readme" 2>/dev/null || true
  git -C "$REPO_ROOT" commit -q -m "chore: restore readme after test" 2>/dev/null || true
  update_event_payload

  if echo "$output" | grep -q "has_changes=false" && ! echo "$output" | grep -q "Release app"; then
    pass "no Chart.yaml change — release job correctly skipped"
  else
    fail "no Chart.yaml change — expected release job to be skipped"
    echo "$output" | grep -E "(error|❌|has_changes|Run Main)" | tail -10
    return 1
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  local test="${1:-all}"

  check_prerequisites

  DOCKER_HOST_VAL=$(detect_docker_host)
  if [ -z "$DOCKER_HOST_VAL" ]; then
    echo "Could not find a running Docker socket. Start Docker and retry."; exit 1
  fi
  info "Using Docker host: $DOCKER_HOST_VAL"

  echo ""
  echo "═══════════════════════════════════════════════"
  echo "  Release Charts — Local Workflow Tests"
  echo "═══════════════════════════════════════════════"
  echo ""

  local failed=0

  run_test() {
    local name="$1"; local fn="$2"
    echo ""
    if ! $fn; then
      failed=$((failed + 1))
    fi
  }

  case "$test" in
    happy)      run_test "happy path"         test_happy_path ;;
    downgrade)  run_test "version downgrade"  test_version_downgrade ;;
    invalid)    run_test "invalid semver"     test_invalid_semver ;;
    no-change)  run_test "no chart change"    test_no_chart_change ;;
    all)
      run_test "happy path"         test_happy_path
      run_test "version downgrade"  test_version_downgrade
      run_test "invalid semver"     test_invalid_semver
      run_test "no chart change"    test_no_chart_change
      ;;
    *)
      echo "Unknown test: $test"
      echo "Usage: $0 [all|happy|downgrade|invalid|no-change]"
      exit 1
      ;;
  esac

  echo ""
  echo "═══════════════════════════════════════════════"
  if [ "$failed" -eq 0 ]; then
    echo -e "  ${GREEN}All tests passed${NC}"
  else
    echo -e "  ${RED}${failed} test(s) failed${NC}"
  fi
  echo "═══════════════════════════════════════════════"
  echo ""

  exit "$failed"
}

main "${1:-all}"
