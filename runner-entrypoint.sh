#!/bin/bash
# Wrapper entrypoint for the roku-runner container.
# Reads the registration token written by the registrar sidecar,
# exports it as RUNNER_TOKEN, then exec's the upstream entrypoint.
# This keeps the App key out of the runner's env entirely — the
# only secret it ever sees is a one-shot registration token.
set -eu

TOKEN_FILE="/shared/runner-token"

if [ ! -r "$TOKEN_FILE" ]; then
  echo "roku-runner: $TOKEN_FILE missing or unreadable (registrar didn't run?)" >&2
  exit 1
fi

RUNNER_TOKEN="$(cat "$TOKEN_FILE")"
if [ -z "$RUNNER_TOKEN" ]; then
  echo "roku-runner: empty RUNNER_TOKEN" >&2
  exit 1
fi

export RUNNER_TOKEN

# Optional liveness heartbeat to Healthchecks.io.
# When HEALTHCHECKS_URL is set, ping <URL>/start at boot and <URL> every 60 s
# while this container is alive. Configure the HC check with period=1m and
# grace=5m so brief gaps between ephemeral job cycles don't false-alert.
# The background subshell dies with PID 1 when /entrypoint.sh exits, so we
# don't need explicit cleanup.
if [ -n "${HEALTHCHECKS_URL:-}" ]; then
  curl -fsS -m 10 -o /dev/null "$HEALTHCHECKS_URL/start" || true
  (
    while sleep 60; do
      curl -fsS -m 10 -o /dev/null "$HEALTHCHECKS_URL" || true
    done
  ) &
fi

exec /entrypoint.sh "$@"
