#!/usr/bin/env bash
# Usage: sudo ./enable-cpu-power.sh [--remove]
# Lets the user who runs sudo read the RAPL energy counters, so that the
# widget can show the CPU power draw.
#
# energy_uj is root-only (0400) on purpose: fine-grained energy counters are a
# side channel (PLATYPUS, CVE-2020-8694). So the file is chown'ed to a single
# user, not made world-readable (no chmod: it stays 0400).
#
# A systemd unit is used rather than a udev RUN rule: SELinux can block such a
# rule, and ExecStartPre loads the module first, which removes the race with
# the powercap files appearing.
set -e

unit=/etc/systemd/system/sysmonitor-rapl.service
# ":?" only matches the top-level zones (intel-rapl:0), not the subzones
zones='/sys/class/powercap/intel-rapl:?/energy_uj'

if [ "$(id -u)" -ne 0 ]; then
  echo "Ce script doit être lancé avec les droits root : sudo $0 [--remove]" >&2
  exit 1
fi

case "${1:-}" in
  ''|--remove) ;;
  *) echo "Usage : sudo $0 [--remove]" >&2; exit 1 ;;
esac

if [ "${1:-}" = "--remove" ]; then
  systemctl disable --now sysmonitor-rapl.service 2>/dev/null || true
  rm -f "$unit"
  systemctl daemon-reload
  for f in $zones; do
    [ -e "$f" ] && chown root:root "$f"
  done
  echo "Accès à la consommation du CPU retiré."
else
  user=${SUDO_USER:-}
  if [ -z "$user" ] || [ "$user" = root ]; then
    echo "Lance ce script avec sudo depuis ton compte utilisateur (pas depuis root)." >&2
    exit 1
  fi
  if ! id "$user" >/dev/null 2>&1; then
    echo "Utilisateur introuvable : $user" >&2
    exit 1
  fi
  cat > "$unit" <<UNIT
[Unit]
Description=Lecture de la consommation du CPU (RAPL) pour sysmonitor-bar

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=-/usr/sbin/modprobe intel_rapl_msr
ExecStart=/bin/sh -c 'chown $user $zones'

[Install]
WantedBy=multi-user.target
UNIT
  systemctl daemon-reload
  systemctl enable --now sysmonitor-rapl.service
  echo "Accès à la consommation du CPU donné à l'utilisateur $user."
  echo "Pour annuler : sudo $0 --remove"
fi
