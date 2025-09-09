#!/usr/bin/env bash
set -euo pipefail
# Usage: build.sh <workdir> <outdir> <zip_prefix>
WORKDIR="${1:-work}"
OUTDIR="${2:-out}"
ZIP_PREFIX="${3:-KLTE-RTL8821AU-NH}"

mkdir -p "$WORKDIR" "$OUTDIR"
ROOT="$(pwd)"
cd "$WORKDIR"

KERNEL_DIR="$PWD/kernel"
DRIVER_DIR="$PWD/rtl8812au"
AK3_DIR="$PWD/AnyKernel3"
BUILD_DIR="$PWD/build"

# CROSS_COMPILE and ARCH should be set by environment
: "${CROSS_COMPILE:?CROSS_COMPILE must be set (e.g. /path/to/arm-eabi-)}"
export ARCH=arm
export KBUILD_BUILD_USER=${KBUILD_BUILD_USER:-nethunter}
export KBUILD_BUILD_HOST=${KBUILD_BUILD_HOST:-buildhost}

mkdir -p "$BUILD_DIR"

cd "$KERNEL_DIR"

# Auto-detect a klte defconfig
DEFCONFIG=$(ls arch/arm/configs 2>/dev/null | grep -iE 'klte.*defconfig|nethunter.*klte.*defconfig|lineage.*klte.*defconfig' | head -n1 || true)
if [ -z "$DEFCONFIG" ]; then
  DEFCONFIG=$(ls arch/arm/configs 2>/dev/null | grep -i 'msm8974.*defconfig' | head -n1 || true)
fi
if [ -z "$DEFCONFIG" ]; then
  echo "Could not find a klte/msm8974 defconfig. Edit scripts/build.sh and set DEFCONFIG manually."
  exit 1
fi
echo "Using defconfig: $DEFCONFIG"

# Build kernel
make O="$BUILD_DIR" "$DEFCONFIG"
yes "" | make O="$BUILD_DIR" olddefconfig
make -j"$(nproc)" O="$BUILD_DIR" zImage modules || make -j4 O="$BUILD_DIR" zImage modules

# locate zImage
if [ -f "$BUILD_DIR/arch/arm/boot/zImage-dtb" ]; then
  ZIMG="$BUILD_DIR/arch/arm/boot/zImage-dtb"
elif [ -f "$BUILD_DIR/arch/arm/boot/zImage" ]; then
  ZIMG="$BUILD_DIR/arch/arm/boot/zImage"
else
  echo "zImage not found in build dir."
  exit 1
fi
echo "Kernel image: $ZIMG"

# Build driver (universal rtl8812au supports 8821AU)
cd "$DRIVER_DIR" || (echo "Driver dir missing" && exit 1)
make clean || true

EXTRA_CFLAGS="-DCONFIG_PLATFORM_ANDROID=1 -Wno-error"
make ARCH=arm CROSS_COMPILE="${CROSS_COMPILE}" KSRC="$BUILD_DIR" KDIR="$BUILD_DIR" USER_EXTRA_CFLAGS="$EXTRA_CFLAGS" -j"$(nproc)" || true

MODKO=$(find "$DRIVER_DIR" -maxdepth 2 -type f -name '*.ko' | head -n1 || true)
if [ -z "$MODKO" ]; then
  MODKO=$(find "$DRIVER_DIR" -type f -name '8812au.ko' -o -name '8821au.ko' | head -n1 || true)
fi
if [ -z "$MODKO" ]; then
  MODKO=$(find "$BUILD_DIR" -type f -name '*.ko' | head -n1 || true)
fi
if [ -z "$MODKO" ]; then
  echo "Driver .ko not found. Module build likely failed. Continuing to package kernel only."
else
  echo "Module built: $MODKO"
fi

# Prepare AnyKernel3
cd "$AK3_DIR" || (echo "AnyKernel3 missing" && exit 1)
cp -f "$ZIMG" "$AK3_DIR/zImage"
MODDEST="$AK3_DIR/modules/system/lib/modules"
mkdir -p "$MODDEST"
if [ -n "$MODKO" ]; then
  cp -f "$MODKO" "$MODDEST/8812au.ko"
fi
mkdir -p "$AK3_DIR/modules/post-fs-data.d"
cat > "$AK3_DIR/modules/post-fs-data.d/50-rtl8812au.sh" <<'EOF'
#!/system/bin/sh
for p in /vendor/lib/modules /system/lib/modules /lib/modules; do
  if [ -f "$p/8812au.ko" ]; then
    insmod "$p/8812au.ko" 2>/dev/null || modprobe 8812au 2>/dev/null
    break
  fi
done
EOF
chmod 0755 "$AK3_DIR/modules/post-fs-data.d/50-rtl8812au.sh"

# Optionally set device name in anykernel.sh (best-effort)
if grep -q '^device.name1' anykernel.sh 2>/dev/null; then
  sed -i 's/^device.name1=.*/device.name1=klte/' anykernel.sh || true
fi

# Create ZIP
cd "$AK3_DIR"
DATESTR=$(date +%Y%m%d)
ZIPNAME="${ZIP_PREFIX}-${DATESTR}.zip"
rm -f "../$ZIPNAME"
zip -r9 "../$ZIPNAME" . -x ".git*" -x "README.md" -x "LICENSE"
mv "../$ZIPNAME" "$ROOT/$OUTDIR/"

echo "Built flashable zip: $ROOT/$OUTDIR/$ZIPNAME"
