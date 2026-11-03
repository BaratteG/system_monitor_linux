#!/usr/bin/env bash
# Usage: procstats.sh cpu
#        procstats.sh gpu [auto|nvidia|amd]
# Lists the busiest processes. Unlike sysstats.sh it only runs while the process
# panel is open. Prints a first line "#cpu", "#nvidia", "#amd" or "#none" (no
# per-process data), then one line per process, busiest first:
#   pid|killable|use|mem|name|command
#   killable: 1 if it belongs to the current user and the session survives without it
#   use: percent of the whole CPU (the same scale as the popup gauge) or of the GPU
#   mem: resident or video memory, MiB
# SYSSTATS_PROC overrides the path of /proc (tests).
export LC_ALL=C
proc=${SYSSTATS_PROC:-/proc}
limit=60

# "total <jiffies>" then one line per process
cpu_sample() {
  local u n s idle iow irq sirq st
  read -r _ u n s idle iow irq sirq st _ < "$proc/stat"
  echo "total $((u + n + s + idle + iow + irq + sirq + st))"
  # -H prefixes each line with its file: a process can put a newline in its
  # name, so a stat file may span lines, and its PID is taken from the path,
  # never from the text, which a process named "x\n1234 (y" would forge
  grep -aHs '' "$proc"/[0-9]*/stat
}

# %cpu of ps is an average over the whole life of the process, so measure a
# window instead; grep and not awk on the files: mawk stops on a vanished process
list_cpu() {
  local a b
  a=$(cpu_sample)
  sleep 1
  b=$(cpu_sample)
  printf '%s\n--\n%s\n' "$a" "$b" | awk -v page_kib=$(($(getconf PAGESIZE) / 1024)) '
    # handles the stat file of "pid", whose lines were gathered in "buf"
    function flush(   f, t, start, name, use) {
      # the name may hold spaces, parentheses and newlines: fields restart after the last ")"
      if (pid != "" && match(buf, /.*\)/)) {
        split(substr(buf, RLENGTH + 2), f, " ")
        t = f[12] + f[13]
        if (!second) prev[pid] = t
        # no memory: kernel thread
        else if (f[1] != "Z" && f[22] + 0 != 0) {
          start = index(buf, "(") + 1
          name = substr(buf, start, RLENGTH - start)
          gsub(/[|\n\r\t]/, " ", name)
          use = total > 0 ? 100 * (t - prev[pid]) / total : 0
          printf "%s|%.1f|%d|%s\n", pid, use, f[22] * page_kib / 1024, name
        }
      }
      pid = ""; buf = ""
    }
    $1 == "--" { flush(); second = 1; next }
    $1 == "total" { flush(); total = second ? $2 - total : $2; next }
    {
      i = index($0, "/stat:")
      if (!i) next
      p = substr($0, 1, i - 1)
      sub(/.*\//, "", p)
      if (p == pid) { buf = buf "\n" substr($0, i + 6); next }
      flush()
      if (p ~ /^[0-9]+$/) { pid = p; buf = substr($0, i + 6) }
    }
    END { flush() }'
}

# the columns of pmon depend on the driver: find them by name in the header
list_nvidia() {
  command -v nvidia-smi >/dev/null 2>&1 || return 1
  local out
  out=$(timeout 3 nvidia-smi pmon -c 1 -s um 2>/dev/null) && [ -n "$out" ] || return 1
  awk '
    /^# *gpu/ { for (i = 2; i <= NF; i++) col[$i] = i - 1; next }
    /^#/ { next }
    $col["pid"] ~ /^[0-9]+$/ { printf "%s|%d|%d|\n", $col["pid"], $col["sm"], $col["fb"] }
  ' <<< "$out"
}

fdinfo_sample() {
  date +%s%N
  grep -sHE '^drm-(client-id|engine-(gfx|compute)|(memory|total)-vram):' "$proc"/[0-9]*/fdinfo/*
}

# amdgpu publishes per client counters (ns of engine time) in fdinfo; a client
# seen through several file descriptors counts once
list_amd() {
  local a b
  a=$(fdinfo_sample)
  sleep 1
  b=$(fdinfo_sample)
  printf '%s\n--\n%s\n' "$a" "$b" | awk -F: '
    $1 == "--" { second = 1; next }
    NF == 1 { if (second) elapsed = $1 - elapsed; else elapsed = $1; next }
    {
      n = split($1, path, "/")
      pid = path[n - 2]
      if ($2 == "drm-client-id") { client[$1] = pid ":" $3 + 0; next }
      c = client[$1]
      if (c == "" || seen[second, c, $2]++) next
      if ($2 ~ /vram/) { if (second && $3 + 0 > mem[c] + 0) mem[c] = $3 + 0 }
      else if (second) busy[c] += $3
      else busy[c] -= $3
      if (second) clients[c] = pid
    }
    END {
      for (c in clients) {
        pid = clients[c]
        use[pid] += elapsed > 0 && busy[c] > 0 ? 100 * busy[c] / elapsed : 0
        kib[pid] += mem[c]
      }
      for (pid in use)
        if (use[pid] >= 0.5 || kib[pid] > 0)
          printf "%s|%d|%d|\n", pid, (use[pid] > 100 ? 100 : use[pid]), kib[pid] / 1024
    }'
}

# keeps the busiest lines and adds the owner, the name and the command line
rank() {
  local pid use mem name killable args cmd
  sort -t '|' -k2,2nr -k3,3nr | head -n "$limit" | while IFS='|' read -r pid use mem name; do
    [[ $pid =~ ^[0-9]+$ ]] || continue
    mapfile 2>/dev/null -d '' -t args < "$proc/$pid/cmdline" || continue
    [ -n "$name" ] || read -r name 2>/dev/null < "$proc/$pid/comm"
    killable=0
    [ -O "$proc/$pid" ] && killable=1
    # killing these ends the desktop session; the kernel cuts names to 15
    # characters, and this has to be read before the name is replaced below
    case "$name" in
      systemd|dbus-daemon|dbus-broker*|Xorg|Xwayland|ksmserver|kwin_*|plasmashell|plasma_session|startplasma*) killable=0 ;;
      cinnamon|cinnamon-sess*|cinnamon-laun*|muffin) killable=0 ;;
    esac
    if [ "${#name}" -ge 15 ] && [ -n "${args[0]}" ]; then
      name=${args[0]%% *}
      name=${name##*/}
    fi
    cmd="${args[*]}"
    cmd=${cmd//[$'\n\r\t']/ }
    printf '%s|%s|%s|%s|%s|%s\n' "$pid" "$killable" "$use" "$mem" "${name//[|$'\n\r\t']/ }" "${cmd:0:300}"
  done
}

case "${1:-cpu}" in
  gpu)
    src=${2:-auto}
    kind=none rows=""
    if [ "$src" != amd ] && rows=$(list_nvidia); then kind=nvidia; fi
    if [ "$kind" = none ] && [ "$src" != nvidia ]; then
      rows=$(list_amd)
      [ -n "$rows" ] && kind=amd
    fi
    echo "#$kind"
    [ -n "$rows" ] && rank <<< "$rows"
    ;;
  *)
    echo '#cpu'
    list_cpu | rank
    ;;
esac
exit 0
