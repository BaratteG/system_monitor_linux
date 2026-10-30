#!/usr/bin/env bash
# Usage: install.sh [cinnamon|kde]   (default: the current desktop)
set -e
cd "$(dirname "$0")"
desktop=${1:-$XDG_CURRENT_DESKTOP}

install_kde() {
  ID=org.gbaratte.sysmonitor
  if kpackagetool5 -t Plasma/Applet -l 2>/dev/null | grep -q "$ID"; then
    kpackagetool5 -t Plasma/Applet -u package
  else
    kpackagetool5 -t Plasma/Applet -i package
  fi
}

install_cinnamon() {
  UUID=sysmonitor-bar@gbaratte
  dest=${XDG_DATA_HOME:-$HOME/.local/share}/cinnamon/applets/$UUID
  rm -rf "$dest"
  mkdir -p "$dest"
  # -L: sysstats.sh is a link to the script shared with the KDE package
  cp -L cinnamon/"$UUID"/* "$dest"/
  # picks up the new code if the applet is already in a panel; Cinnamon 5.8 loses
  # the instances when it reloads an applet that has several, so only reload one
  instances=$(gsettings get org.cinnamon enabled-applets 2>/dev/null | grep -o "$UUID" | wc -l)
  if [ "$instances" -eq 1 ]; then
    gdbus call --session --dest org.Cinnamon --object-path /org/Cinnamon \
      --method org.Cinnamon.ReloadXlet "$UUID" APPLET >/dev/null
  elif [ "$instances" -gt 1 ]; then
    echo "$instances instances dans les panneaux : redémarrer Cinnamon pour les mettre à jour (Alt+F2, puis r)."
  fi
}

case "${desktop,,}" in
  *cinnamon*) install_cinnamon ;;
  *kde*) install_kde ;;
  *) echo "Bureau non reconnu : '$desktop'. Usage : $0 [cinnamon|kde]" >&2; exit 1 ;;
esac
