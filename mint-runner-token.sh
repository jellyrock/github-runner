#!/bin/sh
# Mint a short-lived GitHub Actions runner registration token from a GitHub App
# private key, then write it to a shared volume for the runner container to read.
#
# Runs in a one-shot "registrar" container that exits after writing the token.
# The runner container `depends_on: condition: service_completed_successfully`
# this script — so the runner doesn't start until the token is ready.
#
# WHY a sidecar instead of putting the App key in the runner container's env:
# `pull_request_target` workflows execute attacker-supplied PR code on this
# host. Anything in the runner container's process env is reachable by that
# code (e.g., `process.env.APP_PRIVATE_KEY`). By isolating the App key inside
# this short-lived container that exits before any workflow runs, a PR can
# never read it. The runner only sees the resulting registration token, which
# is one-shot, scoped to "register one runner once," and expires in ~1 hour.
#
# Required mounts (read-only):
#   /run/secrets/github-app/key.pem      — App private key (RSA PEM)
#   /run/secrets/github-app/app-id       — numeric App ID, single line
#   /run/secrets/github-app/install-id   — numeric Installation ID, single line
#   /run/secrets/github-app/repo-url     — "owner/repo" (e.g. "jellyrock/jellyrock")
#
# Required output mount:
#   /shared                              — shared volume; token written to /shared/runner-token

set -eu

KEY="/run/secrets/github-app/key.pem"
APP_ID_FILE="/run/secrets/github-app/app-id"
INSTALL_ID_FILE="/run/secrets/github-app/install-id"
REPO_FILE="/run/secrets/github-app/repo-url"
OUT="/shared/runner-token"

# Defense-in-depth against a stale token in the PERSISTENT registrar-shared
# volume: clear any token from a prior cycle before we do anything that could
# fail (missing secrets, API errors). The runner gates only on the token's
# presence, so a leftover token would let it start and register with a dead
# token → 404 crash-loop. The compose `command` also rm's this before the slow
# `apk add`; this is the belt to that suspenders in case the script is invoked
# some other way.
rm -f "$OUT"

for f in "$KEY" "$APP_ID_FILE" "$INSTALL_ID_FILE" "$REPO_FILE"; do
  [ -r "$f" ] || { echo "registrar: missing or unreadable: $f" >&2; exit 2; }
done

APP_ID=$(tr -d '[:space:]' < "$APP_ID_FILE")
INSTALL_ID=$(tr -d '[:space:]' < "$INSTALL_ID_FILE")
REPO=$(tr -d '[:space:]' < "$REPO_FILE")

case "$REPO" in
  */*) ;;
  *) echo "registrar: repo-url must be 'owner/repo', got: $REPO" >&2; exit 2 ;;
esac

NOW=$(date +%s)
EXP=$((NOW + 540))   # 9 min; GitHub max is 10

# POST to a GitHub API endpoint, tolerating transient failures.
#
# Why this exists: GitHub's API returns routine, short-lived 5xx/429s, and a
# single one used to be fatal. The old `curl -fsS ... | jq` piped an empty body
# into jq on any HTTP error, so the registrar died with an opaque `jq` exit 4;
# the runner then never started and systemd's StartLimitBurst parked the whole
# unit until a human intervened. A momentary blip became a multi-hour outage.
#
# So: retry on network errors and HTTP 429/5xx with backoff, fail fast on a
# genuine 4xx (bad creds / permissions — retrying won't help), and log the real
# HTTP status either way. Retry budget (~21s of sleeps) stays well under the
# registrar healthcheck's ~90s window so a slow mint can't be marked unhealthy.
#
# Args: <label> <auth-header-value> <url>
# Echoes the response body on HTTP 2xx; returns non-zero otherwise.
gh_post() {
  label="$1"; auth="$2"; url="$3"
  attempt=1; max=4
  while :; do
    resp=$(curl -sS -m 15 -w '\n%{http_code}' -X POST \
      -H "Authorization: $auth" \
      -H "Accept: application/vnd.github+json" \
      -H "X-GitHub-Api-Version: 2022-11-28" \
      "$url" 2>/dev/null) && rc=0 || rc=$?
    code=$(printf '%s' "$resp" | tail -n1)
    body=$(printf '%s' "$resp" | sed '$d')
    [ "$rc" -eq 0 ] || code="000"   # curl-level failure (timeout/DNS/reset)
    case "$code" in
      2*)
        printf '%s' "$body"
        return 0 ;;
      000|429|5*)
        if [ "$attempt" -ge "$max" ]; then
          echo "registrar: $label failed after $max attempts (last: HTTP $code)" >&2
          return 1
        fi
        delay=$((attempt * 3))   # 3s, 6s, 9s
        echo "registrar: $label transient HTTP $code — retry $attempt/$((max - 1)) in ${delay}s" >&2
        sleep "$delay"
        attempt=$((attempt + 1)) ;;
      *)
        echo "registrar: $label non-retryable HTTP $code" >&2
        return 1 ;;
    esac
  done
}

b64url() { openssl base64 -e -A | tr '+/' '-_' | tr -d '='; }
HEADER=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
PAYLOAD=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$NOW" "$EXP" "$APP_ID" | b64url)
SIG=$(printf '%s.%s' "$HEADER" "$PAYLOAD" \
        | openssl dgst -sha256 -sign "$KEY" -binary \
        | b64url)
JWT="$HEADER.$PAYLOAD.$SIG"

INSTALL_RESP=$(gh_post "installation access token" "Bearer $JWT" \
  "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens") \
  || { echo "registrar: could not obtain installation access token" >&2; exit 1; }
INSTALL_TOKEN=$(printf '%s' "$INSTALL_RESP" | jq -re '.token')

REG_RESP=$(gh_post "registration token" "token $INSTALL_TOKEN" \
  "https://api.github.com/repos/${REPO}/actions/runners/registration-token") \
  || { echo "registrar: could not obtain runner registration token" >&2; exit 1; }
REG_TOKEN=$(printf '%s' "$REG_RESP" | jq -re '.token')

[ -n "$REG_TOKEN" ] || { echo "registrar: empty registration token" >&2; exit 1; }

umask 077
TMP="${OUT}.tmp"
printf '%s' "$REG_TOKEN" > "$TMP"
mv "$TMP" "$OUT"

echo "registrar: registration token written to $OUT ($(wc -c < "$OUT") bytes); valid ~1h"

# Stay alive after writing the token. We can't exit 0 here: the systemd unit
# that drives this stack uses `docker compose up --abort-on-container-exit`,
# which would interpret the registrar exiting (even successfully) as a signal
# to tear down the whole project mid-runner-startup. Instead we stay running
# with a healthcheck that gates the runner via `condition: service_healthy`.
# When the runner exits (ephemeral mode, after one job), --abort-on-container-
# exit fires correctly and tears us down; systemd restarts the project, and
# this script runs again to mint a fresh token.
echo "registrar: idle (healthcheck-gated). waiting for project teardown..."
exec sleep infinity
