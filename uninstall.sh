#!/bin/bash
# Stop anything ringing, remove the plugin and every bar entry it had, and
# delete its state file. Nothing else is installed on the system.
#
#   uninstall.sh               # remove the plugin and its state
#   uninstall.sh --keep-state  # remove the plugin, keep the alarms and
#                              # cities for a later reinstall
set -uo pipefail

id="io.github.nousd.chime"
keep=0
case "${1:-}" in
  "") ;;
  --keep-state) keep=1 ;;
  -h|--help) sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) echo "uninstall: unknown option '$1' (only --keep-state is accepted)" >&2; exit 2 ;;
esac

fail() {
  echo "uninstall: $*" >&2
  exit 1
}

if omarchy-shell shell ping >/dev/null 2>&1; then
  omarchy-shell chime stop >/dev/null 2>&1 || true
  # A split layout is two bar entries; fold them into one so the removal
  # below takes the last one with it.
  omarchy-shell chime layout merge >/dev/null 2>&1 || true
  sleep 1
fi

omarchy plugin remove "$id" --yes || fail "omarchy plugin remove failed; the plugin is still installed"

# The removal drops one bar entry. With the shell down the merge above did not
# run, so a split layout would leave a second one behind; sweep every entry.
shell_json="$HOME/.config/omarchy/shell.json"
if [[ -f $shell_json ]] && command -v jq >/dev/null; then
  cleaned=$(jq --arg id "$id" '
    if (.bar? | type) == "object" and (.bar.layout? | type) == "object" then
      .bar.layout |= with_entries(
        .value |= (if type == "array" then map(select(
          (type == "string" and . == $id) or (type == "object" and .id == $id) | not
        )) else . end))
    else . end' "$shell_json") && [[ -n $cleaned ]] && [[ $cleaned != "$(cat "$shell_json")" ]] && {
    tmp=$(mktemp "$shell_json.XXXXXX") && printf '%s\n' "$cleaned" >"$tmp" && mv -f "$tmp" "$shell_json" \
      && echo "Removed leftover bar entries from $shell_json."
  }
fi

state_dir="${XDG_STATE_HOME:-$HOME/.local/state}/chime"
if (( keep )); then
  echo "Removed $id. State kept in $state_dir."
else
  rm -rf "$state_dir"
  echo "Removed $id and $state_dir."
fi
