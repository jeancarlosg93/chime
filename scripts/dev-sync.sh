#!/bin/bash
# Copy this checkout into the user plugin directory the way
# `omarchy plugin add` would, validate it, and hot-reload the shell.
#
#   scripts/dev-sync.sh                       # sync + validate + rescan
#   scripts/dev-sync.sh --restart             # ...then restart the shell
#   scripts/dev-sync.sh --enable [placement]  # ...and put the widget on the
#                                             # bar, e.g. --after omarchy.clock
#
# The shell reloads plugin code on save, so re-running this after an edit is
# most of the development loop. A change to Panel.qml (loaded through the
# widget's Loader) keeps serving the cached copy until the shell restarts,
# hence --restart. Alarms, timers and clocks survive the restart: they live
# in the state file.

set -euo pipefail

usage() {
  sed -n '2,14p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

restart=0
enable=0
placement=()
while (( $# > 0 )); do
  case "$1" in
    --restart) restart=1; shift ;;
    --enable) enable=1; shift; placement=("$@"); break ;;
    -h|--help) usage; exit 0 ;;
    *) echo "dev-sync: unknown option '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
id=$(jq -r '.id' "$here/manifest.json")
dest="$HOME/.config/omarchy/plugins/$id"

mkdir -p "$dest"
rsync -a --delete --exclude '.git' "$here/" "$dest/"
omarchy plugin validate "$dest"
omarchy-shell -q shell rescanPlugins

if (( restart )); then
  if ! omarchy restart shell >/dev/null 2>&1; then
    echo "dev-sync: synced, but 'omarchy restart shell' failed" >&2
    exit 1
  fi
fi

if (( enable )); then
  sleep 1
  omarchy plugin enable "$id" "${placement[@]}"
fi

echo "Installed $id into $dest"
