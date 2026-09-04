#!/bin/bash
# Static checks: manifest schema, QML against the installed shell imports,
# and the pure model under node. Fails closed: a missing shell checkout or
# an unresolved `qs.*` import is an error, not a skipped check.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
shell_dir="${OMARCHY_PATH:-/usr/share/omarchy}/shell"
qmllint=$(command -v qmllint || ls /usr/lib/qt6/bin/qmllint 2>/dev/null || true)

fail() {
  echo "lint: $*" >&2
  exit 1
}

omarchy plugin validate "$here"

[[ -f $shell_dir/Ui/qmldir && -f $shell_dir/Commons/qmldir ]] \
  || fail "no Omarchy shell checkout at $shell_dir (set OMARCHY_PATH)"
[[ -n $qmllint ]] || fail "qmllint not found (qt6-declarative)"

# The shell's `qs.*` modules resolve from an import root that has a `qs`
# directory; the shell checkout itself is that directory, so alias it.
imports=$(mktemp -d)
trap 'rm -rf "$imports"' EXIT
ln -s "$shell_dir" "$imports/qs"

output=$("$qmllint" -I "$imports" "$here/Service.qml" "$here/BarWidget.qml" "$here/Panel.qml" 2>&1) || {
  printf '%s\n' "$output"
  fail "qmllint reported errors"
}
if grep -qE "Failed to import|Warnings occurred while importing|not found\. Did you add all imports" <<<"$output"; then
  printf '%s\n' "$output"
  fail "qmllint could not resolve the shell imports; type checks did not run"
fi
# Unqualified-access and missing-property notes are the shell's dynamic
# properties (bar, shell, settings) showing through; the built-in plugins
# lint the same way. The one QProcess::ExitStatus line is qmllint not
# knowing the type of Quickshell's Process.exited second parameter, and
# "PanelWindow is not creatable" is qmllint misreading Quickshell's window
# type (the shell's own KeyboardPanel.qml trips it). Everything else is
# worth reading.
filtered=$(grep -vE "Unqualified access|missing-property|QProcess::ExitStatus|Type PanelWindow is not creatable|^\s|^$|^import |^pragma " <<<"$output" || true)
[[ -z $filtered ]] || printf '%s\n' "$filtered"

command -v node >/dev/null || fail "node not found; the model tests did not run"
node "$here/test/model.test.js"
