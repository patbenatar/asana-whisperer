#!/bin/zsh
# Convenience wrapper — symlink or copy this to somewhere in your PATH.
# e.g.:  ln -s ~/Projects/asana-whisperer/aw ~/.local/bin/aw

SCRIPT_DIR="${0:A:h}"
cd "$SCRIPT_DIR" && exec bundle exec bin/asana-whisperer "$@"
