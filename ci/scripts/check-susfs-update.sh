#!/usr/bin/env bash
# Check whether a newer SUSFS4KSU commit is available for the branch pinned in
# ci/scripts/apply-patches.sh, and optionally sync the pin.
set -euo pipefail

PIN_FILE="ci/scripts/apply-patches.sh"
DOC_FILE="README.md"
BRANCH=""
UPDATE=0
JSON_OUT=""
FAIL_ON_UPDATE=0

die() { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
  case "$1" in
    --pin-file)       PIN_FILE="$2"; shift 2 ;;
    --doc-file)       DOC_FILE="$2"; shift 2 ;;
    --branch)         BRANCH="$2"; shift 2 ;;
    --json)           JSON_OUT="$2"; shift 2 ;;
    --update)         UPDATE=1; shift ;;
    --fail-on-update) FAIL_ON_UPDATE=1; shift ;;
    -h|--help)
      printf '%s\n' \
        'Usage: check-susfs-update.sh [options]' \
        '' \
        'Options:' \
        '  --pin-file FILE       File containing SUSFS_REPO/BRANCH/COMMIT pins' \
        '                        (default: ci/scripts/apply-patches.sh)' \
        "  --doc-file FILE       Also rewrite old SHA occurrences in this file" \
        "                        (default: README.md; use '' to disable)" \
        '  --branch BRANCH       Override the SUSFS branch to query' \
        '  --json FILE           Write a machine-readable report to FILE' \
        '  --update              Rewrite pin/doc files when an update is available' \
        '  --fail-on-update      Exit 2 when an update is available'
      exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done

[ -f "$PIN_FILE" ] || die "pin file not found: $PIN_FILE"

# Read the current pins from apply-patches.sh (single source of truth).
read -r PINNED_SHA PINNED_BRANCH REPO_URL < <(
  python3 - "$PIN_FILE" "$BRANCH" <<'PY'
import re, sys
path, branch_override = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()

def grab(pattern, label):
    m = re.search(pattern, text, re.M)
    if not m:
        sys.exit("could not find %s in %s" % (label, path))
    return m.group(1)

sha = grab(r'^SUSFS_COMMIT="\$\{SUSFS_COMMIT:-([0-9a-f]{40})\}"', "SUSFS_COMMIT").strip()
branch = (branch_override or grab(r'^SUSFS_BRANCH="([^"]+)"', "SUSFS_BRANCH")).strip()
repo = grab(r'^SUSFS_REPO="([^"]+)"', "SUSFS_REPO").strip()
print(sha, branch, repo)
PY
)

PROJECT=$(python3 - "$REPO_URL" <<'PY'
import re, sys, urllib.parse
url = sys.argv[1].strip()
path = re.sub(r'^https?://gitlab\.com/', '', url).removesuffix('.git')
print(urllib.parse.quote(path, safe=''))
PY
)
ENC_BRANCH=$(python3 - "$PINNED_BRANCH" <<'PY'
import sys, urllib.parse
print(urllib.parse.quote(sys.argv[1].strip(), safe=''))
PY
)

BRANCH_URL="https://gitlab.com/api/v4/projects/${PROJECT}/repository/branches/${ENC_BRANCH}"
VERSION_URL="https://gitlab.com/api/v4/projects/${PROJECT}/repository/files/kernel_patches%2Finclude%2Flinux%2Fsusfs.h/raw?ref=${ENC_BRANCH}"

CURL=(curl -fsSL --retry 3 --retry-delay 5 --connect-timeout 20 --max-time 120)

CHECK_ERROR="false"
LATEST_SHA=""
LATEST_TITLE=""
LATEST_URL=""
LATEST_DATE=""
SUSFS_VERSION=""

if ! BRANCH_JSON="$("${CURL[@]}" "$BRANCH_URL" 2>/dev/null)"; then
  CHECK_ERROR="true"
  echo "::warning::Unable to query GitLab for SUSFS branch '${PINNED_BRANCH}'; update status unknown." >&2
else
  mapfile -t COMMIT_INFO < <(
    printf '%s' "$BRANCH_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)
c = d.get("commit") or {}
for key in ("id", "title", "web_url", "created_at"):
    print(str(c.get(key, "")).strip())
'
  )
  for i in "${!COMMIT_INFO[@]}"; do
    COMMIT_INFO[$i]="${COMMIT_INFO[$i]%$'\r'}"
  done
  LATEST_SHA="${COMMIT_INFO[0]:-}"
  LATEST_TITLE="${COMMIT_INFO[1]:-}"
  LATEST_URL="${COMMIT_INFO[2]:-}"
  LATEST_DATE="${COMMIT_INFO[3]:-}"
  if VERSION_TEXT="$("${CURL[@]}" "$VERSION_URL" 2>/dev/null)"; then
    SUSFS_VERSION="$(printf '%s\n' "$VERSION_TEXT" | python3 -c '
import re, sys
m = re.search(r"^#define SUSFS_VERSION \"([^\"]+)\"", sys.stdin.read(), re.M)
print(m.group(1) if m else "")
')"
  fi
fi

UPDATE_AVAILABLE="false"
[ -n "$LATEST_SHA" ] && [ "$PINNED_SHA" != "$LATEST_SHA" ] && UPDATE_AVAILABLE="true"

emit() {
  local key="$1" value="$2"
  printf '%s=%s\n' "$key" "$value"
  if [ -n "${GITHUB_OUTPUT:-}" ]; then
    printf '%s=%s\n' "$key" "$value" >> "$GITHUB_OUTPUT"
  fi
}

printf 'SUSFS branch       : %s\n' "$PINNED_BRANCH"
printf 'Pinned commit      : %s\n' "$PINNED_SHA"
printf 'Latest commit      : %s\n' "${LATEST_SHA:-unknown}"
printf 'Latest title       : %s\n' "${LATEST_TITLE:-unknown}"
printf 'Latest date        : %s\n' "${LATEST_DATE:-unknown}"
printf 'SUSFS version      : %s\n' "${SUSFS_VERSION:-unknown}"
printf 'Update available   : %s\n' "$UPDATE_AVAILABLE"

emit check_error "$CHECK_ERROR"
emit update_available "$UPDATE_AVAILABLE"
emit pinned_sha "$PINNED_SHA"
emit latest_sha "$LATEST_SHA"
emit susfs_version "$SUSFS_VERSION"
emit latest_title "$LATEST_TITLE"
emit latest_url "$LATEST_URL"
emit latest_date "$LATEST_DATE"
emit branch "$PINNED_BRANCH"

if [ "$UPDATE_AVAILABLE" = "true" ] && [ "${GITHUB_ACTIONS:-}" = "true" ]; then
  echo "::warning::SUSFS update available: ${PINNED_SHA:0:12} -> ${LATEST_SHA:0:12} (${LATEST_TITLE})"
fi

if [ -n "$JSON_OUT" ]; then
  CHECK_ERROR="$CHECK_ERROR" UPDATE_AVAILABLE="$UPDATE_AVAILABLE" \
  PINNED_SHA="$PINNED_SHA" LATEST_SHA="$LATEST_SHA" SUSFS_VERSION="$SUSFS_VERSION" \
  LATEST_TITLE="$LATEST_TITLE" LATEST_URL="$LATEST_URL" LATEST_DATE="$LATEST_DATE" \
  BRANCH="$PINNED_BRANCH" python3 - "$JSON_OUT" <<'PY'
import json, os, sys
env_map = {
    "check_error": "CHECK_ERROR",
    "update_available": "UPDATE_AVAILABLE",
    "pinned_sha": "PINNED_SHA",
    "latest_sha": "LATEST_SHA",
    "susfs_version": "SUSFS_VERSION",
    "latest_title": "LATEST_TITLE",
    "latest_url": "LATEST_URL",
    "latest_date": "LATEST_DATE",
    "branch": "BRANCH",
}
data = {key: os.environ.get(env, "") for key, env in env_map.items()}
with open(sys.argv[1], "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
PY
fi

if [ "$UPDATE" -eq 1 ] && [ "$UPDATE_AVAILABLE" = "true" ]; then
  python3 - "$PIN_FILE" "$DOC_FILE" "$PINNED_SHA" "$LATEST_SHA" <<'PY'
import os, sys
pin, doc, old, new = sys.argv[1:5]
for path in (pin, doc):
    if not path or not os.path.isfile(path):
        continue
    text = open(path, encoding="utf-8").read()
    if old not in text:
        continue
    open(path, "w", encoding="utf-8", newline="").write(text.replace(old, new))
PY
  printf 'Updated SUSFS pin to %s in %s' "$LATEST_SHA" "$PIN_FILE"
  [ -n "$DOC_FILE" ] && [ -f "$DOC_FILE" ] && printf ' and %s' "$DOC_FILE"
  printf '\n'
fi

if [ "$FAIL_ON_UPDATE" -eq 1 ] && [ "$UPDATE_AVAILABLE" = "true" ]; then
  exit 2
fi
