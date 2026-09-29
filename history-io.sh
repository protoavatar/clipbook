#!/bin/bash

# Bounded, no-follow access to the clipboard history file.
#
# The shell used to read ~/.local/state/omarchy/clipboard-history.json with a
# Quickshell FileView, which followed symlinks and loaded the whole file into
# memory. Anything that could replace that path (another user process, a
# hostile app running as the same user) could therefore make the long-lived
# shell read an arbitrary or unbounded file.
#
# Usage:
#   history-io.sh read <max-bytes> <src> <cache> <stamp> [<src> <cache> <stamp> ...] [--force]
#
# `read` copies at most <max-bytes> into <cache>, which is a private file under
# the plugin's runtime dir, and only when the source changed (size + mtime in
# <stamp>). It refuses symlinks and anything that is not a regular file, and
# the actual copy runs with O_NOFOLLOW so the source cannot be swapped for a
# symlink between the check and the read.

set -u

# The cache holds a full copy of the clipboard history, so it must not be
# world-readable: a normal 022 umask would leave the copy at 0644, and any other
# local user could read it. Everything this script creates is owner-only.
umask 077

MAX_BLOCK=65536

cmd="${1:-}"

copy_bounded() {
  local src="$1" dst="$2" max="$3"
  local blocks=$(( (max + MAX_BLOCK - 1) / MAX_BLOCK ))
  local tmp="$dst.tmp.$$"
  if dd if="$src" of="$tmp" bs="$MAX_BLOCK" count="$blocks" \
        iflag=nofollow,fullblock status=none 2>/dev/null; then
    chmod 600 "$tmp" 2>/dev/null || true
    # An unchanged copy must not touch the cache, so the FileView watching it
    # does not reload (and re-parse) on every poll.
    if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
      rm -f "$tmp"
      return 0
    fi
    mv -f "$tmp" "$dst"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

read_pair() {
  local src="$1" cache="$2" stamp="$3" max="$4" force="${5:-}"
  local size mtime current previous

  mkdir -p "$(dirname -- "$cache")" "$(dirname -- "$stamp")" 2>/dev/null || return 0
  # Owner-only directory: the cache is a full copy of the clipboard history.
  chmod 700 "$(dirname -- "$cache")" 2>/dev/null || true
  chmod 700 "$(dirname -- "$stamp")" 2>/dev/null || true

  # Regular file only: no symlink, no directory, no device, no fifo.
  [ -L "$src" ] && { rm -f "$cache"; return 0; }
  [ -f "$src" ] || { rm -f "$cache"; return 0; }

  size=$(stat -c %s -- "$src" 2>/dev/null) || return 0
  # Nanosecond mtime: two writes of the same size inside one second must still
  # register as a change.
  mtime=$(stat -c %y -- "$src" 2>/dev/null) || return 0
  current="$size:$mtime"

  if [ -z "$force" ] && [ "$current" = "$(cat -- "$stamp" 2>/dev/null || true)" ]; then
    return 0
  fi
  printf '%s' "$current" >"$stamp" 2>/dev/null && chmod 600 "$stamp" 2>/dev/null || true

  # Oversized input: drop the cache instead of truncating into a corrupt file
  # that would look like a broken history.
  if [ "$size" -gt "$max" ]; then
    rm -f "$cache"
    return 0
  fi

  copy_bounded "$src" "$cache" "$max" || rm -f "$cache"
}

case "$cmd" in
read)
  shift
  [ $# -ge 4 ] || exit 2
  max="$1"
  shift
  force=""
  for arg in "$@"; do
    [ "$arg" = "--force" ] && force=1
  done
  while [ $# -gt 0 ]; do
    if [ "$1" = "--force" ]; then
      shift
      continue
    fi
    [ $# -ge 3 ] || exit 2
    read_pair "$1" "$2" "$3" "$max" "$force"
    shift 3
  done
  ;;
write)
  echo "history-io.sh: write is not supported" >&2
  exit 2
  ;;
*)
  echo "usage: history-io.sh read <max-bytes> <src> <cache> <stamp> [<src> <cache> <stamp> ...] [--force]" >&2
  exit 2
  ;;
esac
