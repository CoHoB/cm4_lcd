#!/usr/bin/env bash
set -euo pipefail

# deploy_to_pi.sh
# Usage: ./deploy_to_pi.sh <pi-host> [pi-user]
#
# Copies content of `install/` to the Pi user's home and then uses sudo
# on the Pi to install the files into `/boot` and `/lib/modules` and runs
# `depmod -a`. It prompts for the `pi` user's password for SSH and then
# for the sudo password if required.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_INSTALL="${SCRIPT_DIR}/install"

if [ ! -d "$LOCAL_INSTALL" ]; then
    echo "install directory not found: $LOCAL_INSTALL" >&2
    exit 1
fi

REBOOT=false
OVERLAYS_ONLY=false
# simple arg parsing: optional flags then host [user]
while [ "${1:-}" != "" ] && [ "${1:0:2}" = "--" ]; do
  case "$1" in
    --reboot)
      REBOOT=true; shift ;;
    --overlays-only)
      OVERLAYS_ONLY=true; shift ;;
    *) break ;;
  esac
done

if [ $# -lt 1 ]; then
  echo "Usage: $0 [--reboot] <pi-host> [pi-user]" >&2
  exit 1
fi

PI_HOST="$1"
PI_USER="${2:-pi}"

# Remote temporary staging directory on the Pi. Use timestamp to avoid races.
REMOTE_TMP="/home/${PI_USER}/cohob_install_$(date +%s)"

# Ensure best-effort cleanup of remote temp dir on local exit (covers rsync failures
# or early aborts). This tries an ssh removal but never fails the local script.
cleanup_remote_tmp() {
  if [ -n "${PI_HOST:-}" ] && [ -n "${PI_USER:-}" ]; then
    ssh "${PI_USER}@${PI_HOST}" "rm -rf '${REMOTE_TMP}'" >/dev/null 2>&1 || true
  fi
}
trap cleanup_remote_tmp EXIT

echo "Rsync -> ${PI_USER}@${PI_HOST}:${REMOTE_TMP} (overlays-only=${OVERLAYS_ONLY})"
if [ "${OVERLAYS_ONLY}" = "true" ]; then
  # only copy overlays directory
  mkdir -p "$LOCAL_INSTALL/overlays"
  # Ensure remote tmp exists before rsync (some remote setups/permissions
  # can cause the receiver to be unable to create nested dirs).
  ssh "${PI_USER}@${PI_HOST}" "mkdir -p '${REMOTE_TMP}'"
  rsync -a --no-o --no-g --delete "$LOCAL_INSTALL/overlays/" "${PI_USER}@${PI_HOST}:${REMOTE_TMP}/overlays/" >/dev/null 2>&1
else
  # Ensure remote tmp exists before rsync to avoid mkdir failures on receiver
  ssh "${PI_USER}@${PI_HOST}" "mkdir -p '${REMOTE_TMP}'"
  rsync -a --no-o --no-g --delete "$LOCAL_INSTALL/" "${PI_USER}@${PI_HOST}:${REMOTE_TMP}/" >/dev/null 2>&1
fi

echo "Running remote install commands (will use sudo on remote)"
# Pass REMOTE_TMP as an environment variable to the remote bash and
# use a quoted heredoc so the local shell does not expand remote-only variables.
ssh "${PI_USER}@${PI_HOST}" "REMOTE_TMP='${REMOTE_TMP}' OVERLAYS_ONLY='${OVERLAYS_ONLY}' bash -s" <<'EOF'
set -euo pipefail
# Ensure remote temporary staging dir is removed on exit inside the remote session
trap 'rm -rf "${REMOTE_TMP}" >/dev/null 2>&1 || true' EXIT
echo "Remote tmp: ${REMOTE_TMP}"
echo "Overlays-only: ${OVERLAYS_ONLY}"
KREL_LOCAL="$(uname -r)"
echo "Remote kernel: \\$(uname -r)"

# Backups disabled - deploy directly
if [ "${OVERLAYS_ONLY}" != "true" ]; then
  echo "Skipping backup (disabled)"
fi

# Detect and install a kernel image from the package — only accept kernel8*.img
# Use nullglob so patterns that don't match disappear instead of remaining literal strings.
shopt -s nullglob || true
kernel_candidates=(
  "$REMOTE_TMP"/kernel8*.img
  "$REMOTE_TMP"/boot/kernel8*.img
  "$REMOTE_TMP"/boot/firmware/kernel8*.img
)
shopt -u nullglob || true

if [ ${#kernel_candidates[@]} -gt 0 ]; then
  CANDIDATE="${kernel_candidates[0]}"
  echo "Found kernel8 image to install: ${CANDIDATE}"
  sudo mkdir -p /boot/firmware
  echo "Installing kernel image to /boot/firmware/kernel8-cohob.img"
  # Try to preserve ownership first; if that fails (e.g. vfat target), retry
  if sudo cp "${CANDIDATE}" /boot/firmware/kernel8-cohob.img 2>/dev/null; then
    echo "Copied kernel image (preserved ownership)"
  else
    echo "Warning: copying kernel image failed"
  fi

  # Attempt to set owner and permissions; ignore errors (some filesystems don't support chown)
  if sudo chown root:root /boot/firmware/kernel8-cohob.img 2>/dev/null; then
    echo "Set owner to root:root"
  else
    echo "Could not set owner (filesystem may not support ownership); continuing"
  fi
  sudo chmod 644 /boot/firmware/kernel8-cohob.img 2>/dev/null || true
else
  echo "No kernel8*.img found in package; skipping kernel image install"
fi

# Install boot files if present
if [ "${OVERLAYS_ONLY}" != "true" ]; then
  if [ -d "${REMOTE_TMP}/boot" ]; then
    echo "Installing boot files to /boot/ (avoid preserving owner/group)"
    # Many /boot filesystems are vfat and don't support Unix owners/groups.
    # Use --no-o --no-g so rsync doesn't attempt chown/chgrp there, and
    # set sensible permissions with --chmod.
    sudo rsync -a --no-o --no-g --chmod=ugo=rwX --delete "${REMOTE_TMP}/boot/" /boot/ || \
      echo "Warning: rsync to /boot returned non-zero (may be expected on vfat); continuing"
  fi
fi

# Install overlays if present (some setups put overlays/ at top)
if [ -d "${REMOTE_TMP}/overlays" ]; then
  echo "Installing overlays to /boot/overlays/ (no delete, keep custom overlays)"
  sudo mkdir -p /boot/overlays
  sudo rsync -a --no-o --no-g --chmod=ugo=rwX "${REMOTE_TMP}/overlays/" /boot/overlays/ || \
    echo "Warning: rsync to /boot/overlays returned non-zero (may be expected on vfat); continuing"
fi

# Install modules
if [ "${OVERLAYS_ONLY}" != "true" ]; then
  if [ -d "${REMOTE_TMP}/lib/modules" ]; then
    echo "Installing modules to /lib/modules/"
    # Determine remote running kernel
    REMOTE_KREL="$(uname -r)"
    echo "Remote running kernel: ${REMOTE_KREL}"

    # Find module directories shipped in the package (e.g. 6.12.58-v8-cohob)
    shipped_dirs=("")
    pushd "${REMOTE_TMP}/lib/modules" >/dev/null 2>&1 || true
    shipped_dirs=( $(ls -1) )
    popd >/dev/null 2>&1 || true

    if [ -z "${shipped_dirs[*]:-}" ]; then
      echo "No module directories found in package; skipping module install"
    else
      # Install each shipped modules directory under its own name
      for d in "${shipped_dirs[@]}"; do
        echo "Installing shipped modules directory ${d} into /lib/modules/${d}/"
        sudo mkdir -p /lib/modules/${d}
        # Use rsync without --delete to preserve modules.* meta files
        sudo rsync -a "${REMOTE_TMP}/lib/modules/${d}/" /lib/modules/${d}/
        
        echo "Running depmod for ${d}"
        sudo depmod -a "${d}" || echo "Warning: depmod for ${d} failed"
      done
    fi
  fi
fi

# Install kernel config files if present
if [ "${OVERLAYS_ONLY}" != "true" ]; then
  # Find config files in the staged install directory
  shopt -s nullglob || true
  config_files=("${REMOTE_TMP}"/config-*)
  shopt -u nullglob || true
  
  if [ ${#config_files[@]} -gt 0 ]; then
    echo "Found ${#config_files[@]} kernel config file(s) to install"
    for cfg in "${config_files[@]}"; do
      cfg_basename="$(basename "${cfg}")"
      echo "Installing ${cfg_basename} to /boot/${cfg_basename}"
      sudo cp "${cfg}" "/boot/${cfg_basename}" || echo "Warning: failed to copy ${cfg_basename}"
      
      # Also try /boot/firmware/ (some Pi setups use this)
      if [ -d /boot/firmware ]; then
        sudo cp "${cfg}" "/boot/firmware/${cfg_basename}" || true
      fi
    done
  else
    echo "No config-* files found in package; skipping kernel config install"
  fi
fi

echo "Cleanup remote tmp"
rm -rf "${REMOTE_TMP}"

echo "Remote install done"
EOF

echo
echo "Done."

exit 0
