#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"
ID=org.gbaratte.sysmonitor
if kpackagetool5 -t Plasma/Applet -l 2>/dev/null | grep -q "$ID"; then
  kpackagetool5 -t Plasma/Applet -u package
else
  kpackagetool5 -t Plasma/Applet -i package
fi
