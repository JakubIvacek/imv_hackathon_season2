#!/usr/bin/env bash
# Starts a local Canton Sandbox + Daml Navigator for one variant.
#
# Usage:
#   ./run-demo.sh no-zk
#   ./run-demo.sh canton-privacy
#   ./run-demo.sh zk-snark
#
# Builds the project, boots the sandbox, runs the Setup.daml init-script
# (allocates demo parties + creates a starter NewsEvent/MediaItem), and opens
# Navigator at http://localhost:7500. Ctrl+C stops everything.

set -euo pipefail

VARIANT="${1:-}"
case "$VARIANT" in
  no-zk|canton-privacy|zk-snark) ;;
  *)
    echo "Usage: $0 {no-zk|canton-privacy|zk-snark}" >&2
    exit 1
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR/$VARIANT"

if [ ! -d "$PROJECT_DIR" ]; then
  echo "No such variant directory: $PROJECT_DIR" >&2
  exit 1
fi

export PATH="$HOME/.daml/bin:$PATH"

if ! command -v daml >/dev/null 2>&1; then
  echo "daml CLI not found on PATH. Install the Daml SDK first: https://get.daml.com" >&2
  exit 1
fi

# daml start needs a JVM. Point JAVA_HOME at one if it isn't already on PATH.
if ! command -v java >/dev/null 2>&1 && [ -z "${JAVA_HOME:-}" ]; then
  echo "No 'java' on PATH and JAVA_HOME is unset. daml start needs a JVM (11+/17)." >&2
  echo "Set JAVA_HOME to a JDK/JRE install and re-run." >&2
  exit 1
fi
if [ -n "${JAVA_HOME:-}" ]; then
  export PATH="$JAVA_HOME/bin:$PATH"
fi

echo "Starting $VARIANT ..."
echo "Navigator will be at http://localhost:7500 once ready."
cd "$PROJECT_DIR"
exec daml start
