#!/usr/bin/env bash
# diagnose_panel_fixed.sh — bereinigte Version
# Sammlung von Prüfungen für das EK79007AD3-Display auf dem Pi.

set -euo pipefail

LOG_PREFIX="[diag]"
echolog() { echo "$LOG_PREFIX $*"; }

brief_usage() {
  cat <<EOF
Usage: $(basename "$0") [--remote user@host]
Runs a sequence of checks for the EK79007AD3 panel and prints a summary.

Options:
  --remote <user@host>   Run checks on the remote host via SSH (uses sudo)


Checks performed:
 - loaded kernel modules relevant to DSI/VC4/panel
 - dmesg lines for vc4/dsi/panel and init/readback traces
 - DRM connector status (card1-DSI-1)
 - device-tree panel node (/proc/device-tree/*/panel@*) properties
 - installed panel module files under /lib/modules
 - simple check for BIST module file

Run on the Pi as root or a user with permission to read /proc/device-tree and dmesg.
EOF
}

dump_header() { printf "\n===== %s =====\n" "$1"; }

check_lsmod() {
  dump_header "Loaded modules (panel/vc4/drm/mipi)"
  lsmod | grep -E 'panel_ek79007ad3|vc4|drm|mipi|dsi' || true
}

check_dmesg() {
  dump_header "dmesg: relevant lines (vc4/dsi/panel/drm/mipi)"
  dmesg | grep -iE 'dsi|vc4|panel-ek79007ad3|drm|mipi' -n | tail -n 200 || true

  dump_header "dmesg: specific panel/DSI lifecycle messages"
  dmesg | grep -iE 'Exit sleep mode sent|Failed to exit sleep mode|Display ON sent|Pixel format set to|Init sequence SUCCESS|Calling bridge pre_enable|Bridge pre_enable done' -n || true
}

check_dsi_errors() {
  dump_header "DSI host errors / timeouts"
  # These logs often include 'HSTX_TO', 'PR_TO', 'LPRX_TO', 'ERR_CONTROL', 'ERR_CONT_LP'
  dmesg | grep -iE 'HSTX_TO|PR_TO|LPRX_TO|ERR_CONTROL|ERR_CONT_LP|ERR_SYNC_ESC|ETIMEDOUT|TA_TO' -n || true
}

check_drm_connector() {
  dump_header "DRM connector status"
  # Look up any DSI connector dynamically instead of hardcoding card1-DSI-1
  found=0
  for c in /sys/class/drm/*-DSI-*; do
    [ -e "$c" ] || continue
    if [ -f "$c/status" ]; then
      echo -n "$(basename "$c"): "; cat "$c/status" || true
    else
      echo "$(basename "$c"): (status file not present)"
    fi
    found=1
  done
  if [ "$found" -eq 0 ]; then
    echo "No DSI connector entries found under /sys/class/drm"
  fi
  echo
}

check_device_tree_panel() {
  dump_header "Device-Tree: panel nodes"
  find /proc/device-tree -type d -name "panel*" 2>/dev/null | while read -r p; do
    echo "== $p =="
    ls -la "$p" || true
    for f in compatible model name status reg enable-gpios reset-gpios pinctrl-0; do
      if [ -f "$p/$f" ]; then
        printf "%s: " "$f"
        # If a text-property, print as string, else try to decode phandle/cells
        if val=$(cat "$p/$f" 2>/dev/null | tr -d "\0"); then
            if [ -n "$val" ]; then
              # If the property contains non-printable characters, treat it as binary
              if printf '%s' "$val" | LC_ALL=C grep -q '[^ -~\n]'; then
                echo "(binary/contains-nonprintable)"
                hexdump -C "$p/$f" 2>/dev/null | sed -n '1,6p' || true
                if [ "$f" = "enable-gpios" ] || [ "$f" = "reset-gpios" ]; then
                  decode_gpios_property "$p/$f"
                elif [ "$f" = "pinctrl-0" ] || [ "$f" = "pinctrl-1" ]; then
                  decode_pinctrl_property "$p/$f"
                fi
              else
                printf "%s\n" "$val"
              fi
            else
            # Property present but empty -> look like binary/cell data (phandle/specifier)
            echo "(binary/empty)"
            hexdump -C "$p/$f" 2>/dev/null | sed -n '1,6p' || true
          fi
        else
          echo "[Fehler beim Lesen der Datei]"
        fi
      fi
    done
  done
}

# Decode a binary property containing a sequence of 32-bit big-endian cells into
# decimal cell values. Uses python3 when available for robust decoding.
decode_dt_cells() {
  local file="$1"
  if [ ! -f "$file" ]; then
    return 1
  fi
  # Prefer xxd for simple, portable big-endian word grouping if available
  if command -v xxd >/dev/null 2>&1; then
    hex=$(xxd -p -c4 "$file" | tr -d '\n' | fold -w8 | paste -sd ' ' -)
    for h in $hex; do
      # convert hex to unsigned decimal; bash supports 16# prefix
      printf "%u " $((16#$h))
    done
    echo
    return 0
  fi
  # Fallback: try python decoding if present
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import struct,sys; f='${file}'; data=open(f,'rb').read(); if not data: sys.exit(0);\
if len(data)%4!=0: cells=list(data); else: cells=list(struct.unpack('>'+'I'*(len(data)//4), data)); print(' '.join(str(c) for c in cells))"
    return 0
  fi
  # Last fallback: hexdump into 32-bit words if the hexdump version supports it
  hexdump -v -e '1/4 "%u "' "$file" 2>/dev/null || hexdump -C "$file" | sed -n '1,6p'
}

# Resolve a phandle (integer) to a device-tree node path by checking
# phandle / linux,phandle files under /proc/device-tree.
resolve_phandle() {
  local ph="$1"
  # normalize to integer
  ph=$((ph + 0))
  # find candidate nodes with phandle or linux,phandle
  local f
  while IFS= read -r -d '' f; do
    if [ -f "$f" ]; then
      # read 4-byte big-endian int
      if command -v xxd >/dev/null 2>&1; then
        val_hex=$(xxd -p -c4 "$f" | tr -d '\n' | sed 's/^\([0-9a-fA-F]\{8\}\).*/\1/') || continue
        val=$((16#$val_hex))
      else
        val_hex=$(hexdump -v -e '1/4 "%08x"' -n 4 "$f" 2>/dev/null) || continue
        val=$((0x$val_hex))
      fi
      if [ "$val" -eq "$ph" ]; then
        dirname="$(dirname "$f")"
        echo "$dirname"
        return 0
      fi
    fi
  done < <(find /proc/device-tree -type f \( -name phandle -o -name linux,phandle \) -print0 2>/dev/null)
  return 1
}

# Given a binary file with GPIO specifiers (<phandle pin flags>), decode each group
# and print human-readable information. It expects groups of 3 cells (controller phandle, pin, flags).
decode_gpios_property() {
  local file="$1"
  if [ ! -f "$file" ]; then
    return 1
  fi
  cells=$(decode_dt_cells "$file" 2>/dev/null || true)
  if [ -z "$cells" ]; then
    echo "(no cells found / not decodable)"
    return 0
  fi
  set -- $cells
  while [ $# -gt 0 ]; do
    ph=$1; shift || true
    pin=${1:-}; shift || true
    flags=${1:-0}; shift || true
    node=$(resolve_phandle "$ph" 2>/dev/null) || node="(phandle:$ph not resolved)"
    echo "controller: $node (ph:$ph), pin: ${pin:-?}, flags: ${flags:-0}"
  done
}

# decode pinctrl-like properties: groups of 1 or 2 cells: <phandle> or <phandle index>
decode_pinctrl_property() {
  local file="$1"
  if [ ! -f "$file" ]; then
    return 1
  fi
  cells=$(decode_dt_cells "$file" 2>/dev/null || true)
  if [ -z "$cells" ]; then
    echo "(no cells found / not decodable)"
    return 0
  fi
  set -- $cells
  while [ $# -gt 0 ]; do
    ph=$1; shift || true
    idx=${1:-}
    if [ -n "$idx" ]; then
      shift || true
    fi
    node=$(resolve_phandle "$ph" 2>/dev/null) || node="(phandle:$ph not resolved)"
    echo "pinctrl: $node (ph:$ph)${idx:+, index:$idx}"
  done
}

check_pinctrl() {
  dump_header "Pinctrl status for Reset/Enable pins (per directives.md)"
  # Attempt to detect pinctrl values for common GPIOs (17/27) used by the overlay
  if command -v pinctrl >/dev/null 2>&1; then
    echolog "pinctrl available - attempting to list pin state for gpios 17/27"
    pinctrl get 17 || true
    pinctrl get 27 || true
  else
    echolog "pinctrl not found; skipping pinctrl checks (use 'pinctrl' from kernel tools)"
  fi
}

check_module_files() {
  dump_header "Installed panel module files"
  uname_r=$(uname -r)
  ls -l /lib/modules/${uname_r}/kernel/drivers/gpu/drm/panel | grep ek79007 || true
  echo
  dump_header "Installed module archive"
  ls -l /lib/modules/${uname_r}/kernel/drivers/gpu/drm/panel/panel-ek79007ad3*.xz || true
}
summary() {
  dump_header "Quick summary / guidance"
  # Pick a DSI connector if present, otherwise report unknown
  dsi_status="unknown"
  for c in /sys/class/drm/*-DSI-*; do
    [ -e "$c" ] || continue
    if [ -f "$c/status" ]; then
      dsi_status="$(cat "$c/status" 2>/dev/null || echo unknown)"
      break
    fi
  done
  echo "- DRM connector: $dsi_status"
  echo -n "- Panel driver loaded: "; lsmod | grep -q panel_ek79007ad3 && echo yes || echo no
  echo -n "- Init sequence in dmesg: "; dmesg | grep -i 'Init sequence SUCCESS' >/dev/null 2>&1 && echo yes || echo no
  echo "- If init succeeded but screen is black consider:"
  echo "  * Verify AVDD/VGH/VGL/VCOM voltages (hardware)"
  echo "  * Verify FPC connector seating and wiring"
  echo "  * Try BIST module to force testpattern (software)"
}

main() {
  if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    brief_usage
    exit 0
  fi

  if [ "${1:-}" = "--remote" ] || [ "${1:-}" = "-r" ]; then
    if [ -z "${2:-}" ]; then
      echo "Error: --remote requires user@host" >&2
      exit 2
    fi
    HOST="$2"
    echolog "Running remote diagnosis on ${HOST} (via SSH)..."
    REMOTE_PREFIX="ssh ${HOST} sudo -i"
    # Teste SSH-Verbindung vorab
    if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$HOST" "exit" 2>/dev/null; then
      echolog "Fehler: SSH-Verbindung zu ${HOST} fehlgeschlagen. Bitte Zugang und Netzwerk prüfen."
      exit 255
    fi
    # Führe alle Diagnosen remote aus als ein zusammenhängendes Root-Skript via heredoc.
    ssh "${HOST}" 'sudo -i -- bash -s' <<'REMOTE_SCRIPT'
echo
printf "===== Remote: Loaded modules (panel/vc4/drm/mipi) =====\n"
lsmod | grep -E 'panel_ek79007ad3|vc4|drm|mipi|dsi' || true

printf "\n===== Remote: dmesg (vc4/dsi/panel/drm/mipi) =====\n"
dmesg | grep -iE 'dsi|vc4|panel-ek79007ad3|drm|mipi' -n | tail -n 200 || true

printf "\n===== Remote: DRM connector status =====\n"
found=0
for c in /sys/class/drm/*-DSI-*; do
  [ -e "$c" ] || continue
  if [ -f "$c/status" ]; then
    echo "$(basename "$c"): $(cat "$c/status" 2>/dev/null || echo unknown)"
  else
    echo "$(basename "$c"): (status file not present)"
  fi
  found=1
done
if [ "$found" -eq 0 ]; then
  echo "No DSI connector entries found under /sys/class/drm on remote host"
fi

printf "\n===== Remote: Device-Tree: panel nodes =====\n"
# Helper: decode binary property cells (1-line space separated decimal ints)
decode_dt_cells() {
  local file="$1"
  if [ ! -f "$file" ]; then
    return 1
  fi
    # Prefer xxd if available for stable word grouping
    if command -v xxd >/dev/null 2>&1; then
      hex=$(xxd -p -c4 "$file" | tr -d '\n' | fold -w8 | paste -sd ' ' -)
      for h in $hex; do
        printf "%u " $((16#$h))
      done
      echo
    else
      if command -v python3 >/dev/null 2>&1; then
        python3 -c "import struct,sys; f='$file'; data=open(f,'rb').read(); if not data: sys.exit(0); if len(data)%4!=0: cells=list(data); else: cells=list(struct.unpack('>'+'I'*(len(data)//4), data)); print(' '.join(str(c) for c in cells))"
      else
        hexdump -v -e '1/4 "%u "' "$file" 2>/dev/null || hexdump -C "$file" | sed -n '1,6p'
      fi
    fi
}

# resolve phandle -> node path
resolve_phandle() {
  local ph="$1"
  ph=$((ph + 0))
  for f in $(find /proc/device-tree -type f \( -name phandle -o -name linux,phandle \) 2>/dev/null); do
    if [ -f "$f" ]; then
      if command -v xxd >/dev/null 2>&1; then
        val_hex=$(xxd -p -c4 "$f" | tr -d '\n' | sed 's/^\([0-9a-fA-F]\{8\}\).*/\1/') || continue
        val=$((16#$val_hex))
      else
        val_hex=$(hexdump -v -e '1/4 "%08x"' -n 4 "$f" 2>/dev/null) || continue
        val=$((0x$val_hex))
      fi
      if [ "$val" -eq "$ph" ]; then
        dirname="$(dirname "$f")"
        echo "$dirname"
        return 0
      fi
    fi
  done
  return 1
}

# decode GPIO array: groups of 3 cells (phandle, pin, flags)
decode_gpios_property() {
  local f="$1"
  cells=$(decode_dt_cells "$f" 2>/dev/null || true)
  if [ -z "$cells" ]; then
    echo "(no cells found)"
    return 0
  fi
  set -- $cells
  while [ $# -gt 0 ]; do
    ph=$1; shift
    pin=${1:-}; shift || true
    flags=${1:-0}; shift || true
    node=$(resolve_phandle "$ph" 2>/dev/null) || node="(ph:$ph not resolved)"
    echo "controller: $node (ph:$ph), pin: ${pin:-?}, flags: ${flags:-0}"
  done
}

# decode pinctrl property: groups of 1 or 2 cells (phandle [, index])
decode_pinctrl_property() {
  local f="$1"
  cells=$(decode_dt_cells "$f" 2>/dev/null || true)
  if [ -z "$cells" ]; then
    echo "(no cells found/decodable)"
    return 0
  fi
  set -- $cells
  while [ $# -gt 0 ]; do
    ph=$1; shift || true
    idx=${1:-}
    if [ -n "$idx" ]; then
      shift || true
    fi
    node=$(resolve_phandle "$ph" 2>/dev/null) || node="(ph:$ph not resolved)"
    echo "pinctrl: $node (ph:$ph)${idx:+, index:$idx}"
  done
}

found=0
  for p in /proc/device-tree/*/*/panel* /proc/device-tree/*/panel*; do
  [ -d "$p" ] || continue
  found=1
  echo "== $p =="
  for f in compatible model name status reg enable-gpios reset-gpios pinctrl-0; do
    if [ -f "$p/$f" ]; then
      printf "%s: " "$f"
      if val=$(cat "$p/$f" 2>/dev/null | tr -d "\0"); then
          # If the property has nonprintable byte(s), treat as binary and decode
          if printf '%s' "$val" | LC_ALL=C grep -q '[^ -~\n]'; then
            echo "(binary/contains-nonprintable)"
            hexdump -C "$p/$f" 2>/dev/null | sed -n '1,6p' || true
            if [ "$f" = "enable-gpios" ] || [ "$f" = "reset-gpios" ]; then
              decode_gpios_property "$p/$f"
            elif [ "$f" = "pinctrl-0" ] || [ "$f" = "pinctrl-1" ]; then
              decode_pinctrl_property "$p/$f"
            fi
          elif [ -n "$val" ]; then
            printf "%s\n" "$val"
          else
            # Property present but empty as string -> likely binary (phandle/specifier)
            echo "(binary/empty)"
            hexdump -C "$p/$f" 2>/dev/null | sed -n '1,6p' || true
            if [ "$f" = "enable-gpios" ] || [ "$f" = "reset-gpios" ]; then
              decode_gpios_property "$p/$f"
            elif [ "$f" = "pinctrl-0" ] || [ "$f" = "pinctrl-1" ]; then
              decode_pinctrl_property "$p/$f"
            fi
          fi
      else
        echo "[Fehler beim Lesen der Datei]"
      fi
    fi
  done
done
if [ "$found" -eq 0 ]; then
  echo "[Info: Keine Panel-Knoten in /proc/device-tree gefunden]"
fi

printf "\n===== Remote: Installed panel module files =====\n"
uname_r=$(uname -r)
ls -l /lib/modules/${uname_r}/kernel/drivers/gpu/drm/panel 2>/dev/null | grep ek79007 || true

printf "\n===== Remote: Installed module archive =====\n"
ls -l /lib/modules/${uname_r}/kernel/drivers/gpu/drm/panel/panel-ek79007ad3*.xz 2>/dev/null || true

printf "\n===== Remote: Quick summary =====\n"
# remote: pick first DSI connector status
_dsi_status="unknown"
for c in /sys/class/drm/*-DSI-*; do
  [ -e "$c" ] || continue
  if [ -f "$c/status" ]; then
    _dsi_status="$(cat "$c/status" 2>/dev/null || echo unknown)"
    break
  fi
done
echo "- DRM connector: ${_dsi_status}"
lsmod | grep -q panel_ek79007ad3 && echo "- Panel driver loaded: yes" || echo "- Panel driver loaded: no"
dmesg | grep -i "Init sequence SUCCESS" >/dev/null 2>&1 && echo "- Init sequence: yes" || echo "- Init sequence: no"
REMOTE_SCRIPT
    rc=$?
    if [ "$rc" -ne 0 ]; then
      echolog "Remote finished with exit code ${rc} (non-fatal)."
    else
      echolog "Remote diagnosis finished"
    fi
    exit 0
  fi

  echolog "Starting panel diagnosis..."
  check_lsmod
  check_dmesg
  check_drm_connector
  check_device_tree_panel
  check_pinctrl
  check_module_files
  check_dsi_errors
  summary
  echolog "Diagnosis complete."
}

main "$@"
