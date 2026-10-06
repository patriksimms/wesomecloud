#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "xcodegen is required to generate WesomeCloud.xcodeproj." >&2
  echo "Install it with: brew install xcodegen" >&2
  exit 127
fi

xcodegen generate --spec project.yml
