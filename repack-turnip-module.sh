#!/bin/bash -e
#
# Repack a prebuilt community Turnip driver as a Magisk / KernelSU module.
#
# Community builds (StevenMXZ, purple-turnip, whitebelyash, ...) ship as
# AdrenoTools .adpkg archives: an emulator loads the .so at runtime from its own
# private directory. This script converts such a build into a system module that
# replaces the Vulkan HAL in system/vendor/lib64/hw/vulkan.adreno.so, i.e. the
# same slot the in-tree build in build-turnip.sh uses.
#
# Override the inputs through the environment, e.g.
#   DRIVER_URL=... DRIVER_LIB=vulkan.purple.so VER=26.3.0-t30 ./repack-turnip-module.sh
#
# NOTE: the driver is repacked as-is. No upstream patches are added or removed.

set -euo pipefail

DRIVER_URL="${DRIVER_URL:-https://github.com/StevenMXZ/Adreno-Tools-Drivers/releases/download/v39/Turnip_v27.0.0-R2.zip}"
DRIVER_LIB="${DRIVER_LIB:-libvulkan_freedreno.so}"
VER="${VER:-27.0.0-stevenmxz-r2}"
VCODE="${VCODE:-2026111301}"
DRIVER_AUTHOR="${DRIVER_AUTHOR:-StevenMXZ}"
MESA_STREAM="${MESA_STREAM:-Mesa 27.0.0-devel}"

green='\033[0;32m'
red='\033[0;31m'
nocolor='\033[0m'

workdir="$(pwd)/turnip_workdir"
magiskdir="$workdir/turnip_module"

DRIVER_FILE="vulkan.turnip.so"
META_FILE="meta.json"
ZIP_FILE_MAGISK="Turnip-${VER}-MAGISK-KSU.zip"
ZIP_FILE_EMULATOR="Turnip-${VER}-EMULATOR.zip"

for dep in patchelf unzip curl zip; do
    command -v "$dep" >/dev/null 2>&1 || {
        echo -e "$red - $dep not found, cannot continue. $nocolor"
        exit 1
    }
done

rm -rf "$workdir"
mkdir -p "$workdir"
cd "$workdir"

echo "Downloading prebuilt driver..." $'\n'
curl -sSL --fail "$DRIVER_URL" --output driver.zip

echo "Extracting ${DRIVER_LIB}..." $'\n'
unzip -o driver.zip "$DRIVER_LIB" > /dev/null
if [ ! -f "$DRIVER_LIB" ]; then
    echo -e "$red $DRIVER_LIB not found inside the archive. $nocolor"
    exit 1
fi

# Refuse to package a driver for the wrong architecture: EI_CLASS=2 (64-bit),
# EI_DATA=1 (little endian), e_machine=0xB7 (AArch64).
elfclass="$(od -An -tu1 -j4 -N1 "$DRIVER_LIB" | tr -d ' \n')"
elfdata="$(od -An -tu1 -j5 -N1 "$DRIVER_LIB" | tr -d ' \n')"
machine="$(od -An -tx1 -j18 -N2 "$DRIVER_LIB" | tr -d ' \n')"
if [ "$elfclass" != "2" ] || [ "$elfdata" != "1" ] || [ "$machine" != "b700" ]; then
    echo -e "$red Not a little-endian AArch64 ELF (class=$elfclass data=$elfdata machine=$machine). $nocolor"
    exit 1
fi

cp "$DRIVER_LIB" vulkan.adreno.so
cp "$DRIVER_LIB" "$DRIVER_FILE"

# The Android loader resolves the HAL by full path, so DT_SONAME is not strictly
# required, but keep it consistent with the installed file name exactly like the
# in-tree build does.
patchelf --set-soname vulkan.adreno.so vulkan.adreno.so
patchelf --set-soname "$DRIVER_FILE" "$DRIVER_FILE"

echo "Prepare magisk module structure..." $'\n'
p1="system/vendor/lib64/hw"
mkdir -p "$magiskdir/$p1"
cp vulkan.adreno.so "$magiskdir/$p1/"
cd "$magiskdir"

meta="META-INF/com/google/android"
mkdir -p "$meta"

cat <<'EOF' >"$meta/update-binary"
#!/sbin/sh

#################
# Initialization
#################

umask 022

# echo before loading util_functions
ui_print() { echo "$1"; }

require_new_magisk() {
  ui_print "*******************************"
  ui_print " Please install Magisk v25.2+! "
  ui_print "*******************************"
  exit 1
}

#########################
# Load util_functions.sh
#########################

OUTFD=$2
ZIPFILE=$3

mount /data 2>/dev/null

if [ -f /data/adb/magisk/util_functions.sh ]; then
  . /data/adb/magisk/util_functions.sh
elif [ -f /data/adb/ksu/util_functions.sh ]; then
  . /data/adb/ksu/util_functions.sh
elif [ -f /data/adb/ap/util_functions.sh ]; then
  . /data/adb/ap/util_functions.sh
else
  require_new_magisk
fi

[ -n "$MAGISK_VER_CODE" ] && [ "$MAGISK_VER_CODE" -lt 25200 ] && require_new_magisk

install_module
exit 0
EOF

cat <<'EOF' >"$meta/updater-script"
#MAGISK
EOF

cat <<'EOF' >"uninstall.sh"
#!/system/bin/sh
find /data/user/*/*/*cache /data/data/*/*cache /data/user_de/*/*/*cache -mindepth 1 -maxdepth 3 \
    \( -iname "*shader*" -o -iname "*graphitecache*" -o -iname "*gpucache*" \) \
    -exec rm -rf {} + 2>/dev/null || true
EOF

cat <<EOF >"module.prop"
id=turnip-mesa
name=Freedreno Turnip Vulkan Driver COMMUNITY
version=v${VER}
versionCode=${VCODE}
author=${DRIVER_AUTHOR} (repacked by V3KT0R-87 tooling)
description=Turnip built from ${MESA_STREAM} by ${DRIVER_AUTHOR}, repacked as a system module.
EOF

cat <<'EOF' >"customize.sh"
MODVER=`grep_prop version $MODPATH/module.prop`
MODVERCODE=`grep_prop versionCode $MODPATH/module.prop`

ui_print ""
ui_print "Version=$MODVER "
ui_print "MagiskVersion=$MAGISK_VER"
ui_print ""
ui_print "Freedreno Turnip Vulkan Driver COMMUNITY"
ui_print "Adreno Driver Support Group - Telegram"
ui_print ""
sleep 1.25

ui_print ""
ui_print "Checking Device info ..."
sleep 1.25

SDK_VER=$(getprop ro.build.version.sdk)
[ -z "$SDK_VER" ] && SDK_VER=$(getprop ro.system.build.version.sdk)
[ "${SDK_VER:-0}" -lt 34 ] && abort "Android 14 is now required! Aborting ..."
ui_print ""
ui_print "Everything looks fine .... proceeding"
ui_print ""
ui_print "Installing Driver Please Wait ..."
ui_print ""

sleep 1.25
set_perm_recursive $MODPATH/system 0 0 0755 0644
set_perm $MODPATH/system/vendor/lib64/hw/vulkan.adreno.so 0 0 0644 u:object_r:same_process_hal_file:s0

ui_print ""
ui_print " Cleaning GPU Cache ... Please wait!"
find /data/user/*/*/*cache /data/data/*/*cache /data/user_de/*/*/*cache -mindepth 1 -maxdepth 3 \
    \( -iname "*shader*" -o -iname "*graphitecache*" -o -iname "*gpucache*" \) \
    -exec rm -rf {} + 2>/dev/null || true

ui_print ""
ui_print "- GPU Cache Cleared ..."
ui_print ""

ui_print "Driver installed Successfully"
sleep 1.25

ui_print ""
ui_print "All done, Please REBOOT device"
ui_print ""
EOF

echo "Packing driver files into Magisk/KSU module ..." $'\n'

chmod 0755 "$meta/update-binary"
chmod 0755 customize.sh
chmod 0755 uninstall.sh

zip -r "$workdir/$ZIP_FILE_MAGISK" * > /dev/null

[ -f "$workdir/$ZIP_FILE_MAGISK" ] || {
    echo -e "${red}Error: Zipping driver files failed.${nocolor}"
    exit 1
}

cd "$workdir"

cat <<EOF > "$META_FILE"
{
  "schemaVersion": 1,
  "name": "Freedreno Turnip Driver ${VER}",
  "description": "Repacked from ${DRIVER_AUTHOR} (${MESA_STREAM})",
  "author": "${DRIVER_AUTHOR}",
  "packageVersion": "1",
  "vendor": "Mesa3D",
  "driverVersion": "${MESA_STREAM}",
  "minApi": 34,
  "libraryName": "vulkan.turnip.so"
}
EOF

if ! zip "$ZIP_FILE_EMULATOR" "$DRIVER_FILE" "$META_FILE" > /dev/null; then
    echo -e "${red}Error: Zipping emulator files failed.${nocolor}"
    exit 1
fi

rm -f "$META_FILE"

echo -e "$green Repack finished. $nocolor" $'\n'
echo "Magisk-KSU Module : $workdir/$ZIP_FILE_MAGISK" $'\n'
echo "Emulator          : $workdir/$ZIP_FILE_EMULATOR" $'\n'
