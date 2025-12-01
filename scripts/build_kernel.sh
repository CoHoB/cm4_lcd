#!/usr/bin/env bash
set -euo pipefail

# start time for total runtime
START_TIME=$(date +%s)

# Simple kernel build helper for cross-compiling Raspberry Pi kernel
# Usage: ./build_kernel.sh [build|modules_install|package|all]

TOPDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINUX_DIR="$TOPDIR/linux"

if [ ! -d "$LINUX_DIR" ]; then
  echo "Error: linux directory not found at $LINUX_DIR"
  exit 1
fi

cd "$LINUX_DIR"

CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
ARCH="arm64"
JOBS="${JOBS:-$(nproc)}"
KERNEL="${KERNEL:-kernel8}"
LOCALVERSION="${LOCALVERSION:--cohob}"
INSTALL_DIR="${INSTALL_DIR:-$TOPDIR/install}"

usage() {
  echo "Usage: $0 [build|modules_install|package|all|clean|incremental|module|vc4|quick]"
  echo "  build           - Build kernel Image, modules and device trees"
  echo "  modules_install - Install modules to install directory"
  echo "  package         - Package kernel and overlays"
  echo "  all             - Clean + build + modules_install + package (SLOW)"
  echo "  clean           - Clean all build artifacts"
  echo "  incremental     - Build + modules_install + package (no clean, still installs ALL modules)"
  echo "  module          - Build only panel-ek79007ad3 module (FASTEST)"
  echo "  vc4             - Build only vc4 module (FAST)"
  echo "  quick           - Build kernel + package (skip modules_install for speed)"
  exit 1
}

_do_clean() {
  echo "Cleaning build artifacts..."
  make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE clean
  # Also remove specific module objects to force rebuild
  find . -name 'panel-ek79007ad3*.o' -o -name 'panel-ek79007ad3*.ko' | xargs rm -f
  # Clean install directory only on explicit clean
  rm -rf "$INSTALL_DIR"
  echo "Clean done (including install directory)"
}

_do_build() {
  echo "Building Image, modules and dtbs (ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE LOCALVERSION=$LOCALVERSION)"
  make -j"$JOBS" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE LOCALVERSION=$LOCALVERSION Image modules dtbs
}

_do_modules_install() {
  echo "Installing modules to ${INSTALL_DIR}"
  # Keep install dir intact for incremental builds
  mkdir -p "$INSTALL_DIR/overlays"
  export INSTALL_MOD_PATH="$INSTALL_DIR"
  make ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE LOCALVERSION=$LOCALVERSION modules_install
  # show where modules were installed (helps detect LOCALVERSION mismatches)
  KREL=$(make kernelrelease LOCALVERSION=$LOCALVERSION)
  echo "Installed modules path: $INSTALL_DIR/lib/modules/$KREL/"
  if [ -d "$INSTALL_DIR/lib/modules/$KREL" ]; then
    find "$INSTALL_DIR/lib/modules/$KREL" -name 'panel-ek79007ad3*.ko' -print || echo 'panel-ek79007ad3 not found in installed modules'
  fi
}

_do_package() {
  KREL=$(make kernelrelease LOCALVERSION=$LOCALVERSION)
  echo "Kernel release: $KREL"

  mkdir -p "$INSTALL_DIR"
  cp -v .config "$INSTALL_DIR/config-${KREL}"
  cp -v arch/arm64/boot/Image "$INSTALL_DIR/${KERNEL}${LOCALVERSION}.img"
  cp -v arch/arm64/boot/dts/*.dtb "$INSTALL_DIR/" || true
  cp -v arch/arm64/boot/dts/overlays/*.dtb* "$INSTALL_DIR/overlays/" || true
  cp -v arch/arm64/boot/dts/overlays/README "$INSTALL_DIR/overlays/" || true

  echo "Packaging done. Modules in: $INSTALL_DIR/lib/modules/$KREL"
}

_do_module_only() {
  echo "Building only panel-ek79007ad3 module..."
  make -j"$JOBS" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE LOCALVERSION=$LOCALVERSION M=drivers/gpu/drm/panel modules
  
  KREL=$(make -s kernelrelease LOCALVERSION=$LOCALVERSION)
  echo "Installing panel module to ${INSTALL_DIR}"
  
  # Install both panel modules (standard + BIST)
  MODULE_PATH="$INSTALL_DIR/lib/modules/$KREL/kernel/drivers/gpu/drm/panel"
  mkdir -p "$MODULE_PATH"
  cp -v drivers/gpu/drm/panel/panel-ek79007ad3.ko "$MODULE_PATH/" 2>/dev/null || true
  cp -v drivers/gpu/drm/panel/panel-ek79007ad3-bist.ko "$MODULE_PATH/" 2>/dev/null || true
  
  # Compress with xz
  xz -f "$MODULE_PATH/panel-ek79007ad3.ko" 2>/dev/null || true
  xz -f "$MODULE_PATH/panel-ek79007ad3-bist.ko" 2>/dev/null || true
  
  echo "Modules installed:"
  ls -lh "$MODULE_PATH/panel-ek79007ad3"*.ko.xz 2>/dev/null || echo "  (no modules found)"
}

_do_vc4_only() {
  echo "Building only vc4 module..."
  make -j"$JOBS" ARCH=$ARCH CROSS_COMPILE=$CROSS_COMPILE LOCALVERSION=$LOCALVERSION M=drivers/gpu/drm/vc4 modules
  
  KREL=$(make -s kernelrelease LOCALVERSION=$LOCALVERSION)
  echo "Installing vc4 module to ${INSTALL_DIR}"
  
  # Install just this module
  MODULE_PATH="$INSTALL_DIR/lib/modules/$KREL/kernel/drivers/gpu/drm/vc4"
  mkdir -p "$MODULE_PATH"
  cp -v drivers/gpu/drm/vc4/vc4.ko "$MODULE_PATH/"
  
  # Compress with xz
  xz -f "$MODULE_PATH/vc4.ko"
  
  echo "Module installed: $MODULE_PATH/vc4.ko.xz"
  ls -lh "$MODULE_PATH/vc4.ko.xz"
}

case "${1:-all}" in
  clean) _do_clean ;;
  build) _do_build ;;
  modules_install) _do_modules_install ;;
  package) _do_package ;;
  module) _do_module_only ;;
  vc4) _do_vc4_only ;;
  quick)
    _do_build
    _do_package
    ;;
  incremental)
    _do_build
    _do_modules_install
    _do_package
    ;;
  all)
    _do_clean
    _do_build
    _do_modules_install
    _do_package
    ;;
  *) usage ;;
esac

END_TIME=$(date +%s)
ELAPSED=$((END_TIME-START_TIME))
HOURS=$((ELAPSED/3600))
MINS=$((ELAPSED%3600/60))
SECS=$((ELAPSED%60))
printf "\nTotal runtime: %d seconds (%02d:%02d:%02d hh:mm:ss)\n" "$ELAPSED" "$HOURS" "$MINS" "$SECS"

echo
echo "Done."