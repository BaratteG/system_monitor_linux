#!/usr/bin/env bash
# Usage: sysstats.sh [auto|nvidia|amd] [network interface, empty = auto]
# Prints one line: key=value;key=value;...  (missing values: -1 or empty)
src="${1:-auto}"
net_if_cfg="${2:-}"
LC_ALL=C

read -r _ u n s idle iow irq sirq st _ < /proc/stat
cpu_total=$((u + n + s + idle + iow + irq + sirq + st))
cpu_idle=$((idle + iow))

# CPU temperature (millidegrees), first source found wins:
#   k10temp / zenpower (AMD): Tdie if exposed, else Tctl minus the known
#     Tctl offset of Ryzen 1000/2000 "X" and Threadripper 1000/2000
#   coretemp (Intel): hottest "Package id N" (all sockets)
#   kernel thermal zone x86_pkg_temp
# SYSSTATS_HWMON / SYSSTATS_THERMAL / SYSSTATS_CPUINFO override the paths (tests).
hwmon_dir=${SYSSTATS_HWMON:-/sys/class/hwmon}
thermal_dir=${SYSSTATS_THERMAL:-/sys/class/thermal}
cpuinfo=${SYSSTATS_CPUINFO:-/proc/cpuinfo}

# prints the input of the temperature labelled $2 in hwmon dir $1
hwmon_label() {
  local l
  for l in "$1"/temp*_label; do
    [ "$(cat "$l" 2>/dev/null)" = "$2" ] && { cat "${l%_label}_input" 2>/dev/null; return 0; }
  done
  return 1
}

tctl_offset() {
  case "$(grep -m1 '^model name' "$cpuinfo" 2>/dev/null)" in
    *"Ryzen 5 1600X"*|*"Ryzen 7 1700X"*|*"Ryzen 7 1800X"*) echo 20000 ;;
    *"Ryzen 7 2700X"*) echo 10000 ;;
    *"Threadripper 19"*|*"Threadripper 29"*) echo 27000 ;;
    *) echo 0 ;;
  esac
}

cpu_temp_m=""
for h in "$hwmon_dir"/hwmon*; do
  case "$(cat "$h/name" 2>/dev/null)" in
    k10temp|zenpower)
      v=$(hwmon_label "$h" Tdie)
      if [ -z "$v" ]; then
        v=$(hwmon_label "$h" Tctl || cat "$h/temp1_input" 2>/dev/null)
        [ -n "$v" ] && v=$((v - $(tctl_offset)))
      fi
      cpu_temp_m=$v
      break ;;
    coretemp)
      v=$(for l in "$h"/temp*_label; do
            case "$(cat "$l" 2>/dev/null)" in "Package id"*) cat "${l%_label}_input" ;; esac
          done 2>/dev/null | sort -n | tail -n1)
      [ -z "$v" ] && v=$(cat "$h"/temp*_input 2>/dev/null | sort -n | tail -n1)
      if [ -n "$v" ] && { [ -z "$cpu_temp_m" ] || [ "$v" -gt "$cpu_temp_m" ]; }; then cpu_temp_m=$v; fi
      ;;
  esac
done
if [ -z "$cpu_temp_m" ]; then
  for z in "$thermal_dir"/thermal_zone*; do
    [ "$(cat "$z/type" 2>/dev/null)" = "x86_pkg_temp" ] || continue
    cpu_temp_m=$(cat "$z/temp" 2>/dev/null)
    break
  done
fi
cpu_temp=-1
case "$cpu_temp_m" in
  ''|*[!0-9-]*) ;;
  *) cpu_temp=$(awk -v v="$cpu_temp_m" 'BEGIN{ if (v > 0) printf "%.1f", v/1000; else print -1 }') ;;
esac

# average current frequency over all threads, MHz
cpu_freq=$(cat /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq 2>/dev/null \
  | awk '{s+=$1} END{if (NR) printf "%d", s/NR/1000; else print -1}')

mem_total=0; mem_avail=0
while read -r k v _; do
  case "$k" in
    MemTotal:) mem_total=$v ;;
    MemAvailable:) mem_avail=$v ;;
  esac
done < /proc/meminfo
mem_total=$((mem_total / 1024)); mem_avail=$((mem_avail / 1024))

gpu_use=-1; gpu_temp=-1; gpu_freq=-1; vram_used=-1; vram_total=-1; gpu_name=""; gpu_kind=""

try_nvidia() {
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  local out
  out=$(timeout 2 nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total,clocks.gr,name \
        --format=csv,noheader,nounits 2>/dev/null | head -n1) || return 1
  [ -n "$out" ] || return 1
  IFS=',' read -r a b c d f e <<< "$out"
  trim() { echo "$1" | tr -d '[:space:]'; }
  gpu_use=$(trim "$a"); gpu_temp=$(trim "$b"); vram_used=$(trim "$c"); vram_total=$(trim "$d")
  gpu_name=$(echo "$e" | sed 's/^ *//;s/ *$//;s/;/ /g')
  case "$gpu_use" in ''|*[!0-9]*) gpu_use=-1 ;; esac
  case "$gpu_temp" in ''|*[!0-9]*) gpu_temp=-1 ;; esac
  case "$vram_used" in ''|*[!0-9]*) vram_used=-1 ;; esac
  case "$vram_total" in ''|*[!0-9]*) vram_total=-1 ;; esac
  gpu_freq=$(trim "$f")
  case "$gpu_freq" in ''|*[!0-9]*) gpu_freq=-1 ;; esac
  gpu_kind=nvidia
  return 0
}

try_amd() {
  local c d t
  for c in /sys/class/drm/card[0-9]*; do
    case "$c" in *-*) continue ;; esac
    d="$c/device"
    [ -r "$d/gpu_busy_percent" ] || continue
    [ "$(cat "$d/vendor" 2>/dev/null)" = "0x1002" ] || continue
    gpu_use=$(cat "$d/gpu_busy_percent" 2>/dev/null); gpu_use=${gpu_use:--1}
    if [ -r "$d/mem_info_vram_used" ]; then
      vram_used=$(( $(cat "$d/mem_info_vram_used") / 1048576 ))
      vram_total=$(( $(cat "$d/mem_info_vram_total") / 1048576 ))
    fi
    t=$(cat "$d"/hwmon/hwmon*/temp1_input 2>/dev/null | head -n1)
    [ -n "$t" ] && gpu_temp=$((t / 1000))
    t=$(cat "$d"/hwmon/hwmon*/freq1_input 2>/dev/null | head -n1)
    [ -n "$t" ] && gpu_freq=$((t / 1000000))
    gpu_name="AMD GPU"
    gpu_kind=amd
    return 0
  done
  return 1
}

case "$src" in
  nvidia) try_nvidia ;;
  amd) try_amd ;;
  *) try_nvidia || try_amd ;;
esac

# network: cumulative bytes; auto = every physical interface that is up
# (skips lo, bridges, docker/veth, VPN tunnels -> no double counting)
net_rx=0; net_tx=0; net_names=""
for i in /sys/class/net/*; do
  n=${i##*/}
  if [ -n "$net_if_cfg" ]; then
    [ "$n" = "$net_if_cfg" ] || continue
  else
    [ -e "$i/device" ] || continue
    [ "$(cat "$i/operstate" 2>/dev/null)" = "up" ] || continue
  fi
  r=$(cat "$i/statistics/rx_bytes" 2>/dev/null) || continue
  t=$(cat "$i/statistics/tx_bytes" 2>/dev/null) || continue
  net_rx=$((net_rx + r)); net_tx=$((net_tx + t))
  net_names="${net_names:+$net_names, }$n"
done

echo "cpuTotal=$cpu_total;cpuIdle=$cpu_idle;cpuTemp=$cpu_temp;cpuFreq=$cpu_freq;memTotal=$mem_total;memAvail=$mem_avail;gpuUse=$gpu_use;gpuTemp=$gpu_temp;gpuFreq=$gpu_freq;vramUsed=$vram_used;vramTotal=$vram_total;gpuName=$gpu_name;gpuKind=$gpu_kind;netRx=$net_rx;netTx=$net_tx;netIf=$net_names"
