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
exec /entrypoint.sh "$@"
