#!/bin/bash
# Convenience wrapper — symlink or copy this to somewhere in your PATH.
# e.g.:  ln -s ~/Projects/asana-whisperer/aw ~/.local/bin/aw

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" && exec bundle exec bin/asana-whisperer "$@"
