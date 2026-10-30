#!/usr/bin/env bash
# Usage: uninstall.sh [cinnamon|kde]   (default: the current desktop)
desktop=${1:-$XDG_CURRENT_DESKTOP}

case "${desktop,,}" in
  *cinnamon*) rm -rf "${XDG_DATA_HOME:-$HOME/.local/share}/cinnamon/applets/sysmonitor-bar@gbaratte" ;;
  *kde*) kpackagetool5 -t Plasma/Applet -r org.gbaratte.sysmonitor ;;
  *) echo "Bureau non reconnu : '$desktop'. Usage : $0 [cinnamon|kde]" >&2; exit 1 ;;
esac
