#!/bin/zsh
# Git hooks only run from a path git knows about; dropping files in .git/hooks is a dead
# file the moment someone clones elsewhere. Point the repo at the tracked directory.
set -euo pipefail
cd "$(dirname "$0")/../.."
chmod +x .githooks/*
git config core.hooksPath .githooks
echo "hooks installed: $(git config core.hooksPath)"
