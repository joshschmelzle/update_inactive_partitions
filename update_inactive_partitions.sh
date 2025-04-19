#!/bin/bash -e
# update_inactive_partitions.sh - Update inactive partition set from compressed OS image
#
# Works with limited space by streaming the compressed image directly to partitions
#
# Requires: gunzip dd blkid mount sed
#
# Version: v0.2
# Author: Josh Schmelzle
# License: BSD-3

if [ "$(id -u)" -ne 0 ]; then
    echo "Error: need elevated permissions ... run as root (sudo) ..."
    exit 1
fi

if [ $# -ne 1 ]; then
    echo "Usage: $0 <image.img.gz>"
    exit 1
fi

IMAGE_FILE="$1"

if [ ! -f "$IMAGE_FILE" ]; then
    echo "Error: Image file not found: $IMAGE_FILE ..."
    exit 1
fi

if [[ "$IMAGE_FILE" != *.gz ]]; then
    echo "Error: This script requires a compressed .img.gz file ..."
    exit 1
fi

for cmd in gunzip dd blkid mount sed; do
    if ! command -v $cmd &> /dev/null; then
        echo "Error: Required command '$cmd' not found ..." 
        exit 1
    fi
done

CURRENT_ROOT=$(mount | grep ' on / ' | awk '{print $1}')
echo "Current root: $CURRENT_ROOT"

if [[ $CURRENT_ROOT == *"mmcblk0p2"* ]]; then
    echo "Currently booted from A partition set"
    ACTIVE_SET="A"
    INACTIVE_BOOT="/dev/mmcblk0p5"
    INACTIVE_ROOT="/dev/mmcblk0p6"
    ACTIVE_BOOT="/dev/mmcblk0p1"
    ACTIVE_ROOT="/dev/mmcblk0p2"
    HOME_PART="/dev/mmcblk0p7"
    BOOT_PARTITION=5 
    INACTIVE_BOOT_NUM=5
    ACTIVE_BOOT_NUM=1
elif [[ $CURRENT_ROOT == *"mmcblk0p6"* ]]; then
    echo "Currently booted from B partition set"
    ACTIVE_SET="B"
    INACTIVE_BOOT="/dev/mmcblk0p1"
    INACTIVE_ROOT="/dev/mmcblk0p2"
    ACTIVE_BOOT="/dev/mmcblk0p5"
    ACTIVE_ROOT="/dev/mmcblk0p6"
    HOME_PART="/dev/mmcblk0p7"
    BOOT_PARTITION=0
    INACTIVE_BOOT_NUM=1
    ACTIVE_BOOT_NUM=5
else
    echo "Error: Unable to determine current boot partition ..."
    echo "Current root: $CURRENT_ROOT"
    exit 1
fi

INACTIVE_SET=$([ "$ACTIVE_SET" == "A" ] && echo "B" || echo "A")
echo "Updating $INACTIVE_SET partition set"
echo "Inactive boot: $INACTIVE_BOOT"
echo "Inactive root: $INACTIVE_ROOT"

INACTIVE_BOOT_PARTUUID=$(blkid -s PARTUUID -o value $INACTIVE_BOOT)
INACTIVE_ROOT_PARTUUID=$(blkid -s PARTUUID -o value $INACTIVE_ROOT)
HOME_PARTUUID=$(blkid -s PARTUUID -o value $HOME_PART)
ACTIVE_ROOT_PARTUUID=$(blkid -s PARTUUID -o value $ACTIVE_ROOT)
ACTIVE_BOOT_PARTUUID=$(blkid -s PARTUUID -o value $ACTIVE_BOOT)

echo "Inactive boot PARTUUID: $INACTIVE_BOOT_PARTUUID"
echo "Inactive root PARTUUID: $INACTIVE_ROOT_PARTUUID"
echo "Active boot PARTUUID: $ACTIVE_BOOT_PARTUUID"
echo "Active root PARTUUID: $ACTIVE_ROOT_PARTUUID"
echo "Home PARTUUID: $HOME_PARTUUID"

echo "=== WLAN Pi $INACTIVE_SET partition update ==="
echo "Using compressed OS image: $IMAGE_FILE"

TEMP_DIR=$(mktemp -d)
mkdir -p "$TEMP_DIR/mnt_boot" "$TEMP_DIR/mnt_root"

echo "Analyzing compressed image structure ..."
gunzip -c "$IMAGE_FILE" | dd bs=512 count=34 of="$TEMP_DIR/mbr.img" 2>/dev/null
PART_INFO=$(fdisk -l "$TEMP_DIR/mbr.img" 2>/dev/null || echo "Failed to read partition info")
echo "$PART_INFO"

echo "Defining default partition offsets ..."
BOOT_START=8192
BOOT_SIZE=524288  # 256MB
ROOT_START=532480

if echo "$PART_INFO" | grep -q 'img1'; then
    BOOT_START=$(echo "$PART_INFO" | grep 'img1' | awk '{print $2}')
    BOOT_END=$(echo "$PART_INFO" | grep 'img1' | awk '{print $3}')
    BOOT_SIZE_ORIGINAL=$((BOOT_END - BOOT_START + 1))
    
    TARGET_SIZE=$(lsblk -b ${INACTIVE_BOOT} -o SIZE -n | tr -d '[:space:]')
    TARGET_SECTORS=$((TARGET_SIZE / 512))
    
    if [ $BOOT_SIZE_ORIGINAL -gt $TARGET_SECTORS ]; then
        echo "WARNING: Boot partition in image ($(($BOOT_SIZE_ORIGINAL * 512 / 1024 / 1024)) MB) is larger than target partition ($(($TARGET_SIZE / 1024 / 1024)) MB) ..."
        echo "Will copy only what fits in the target partition ..."
        BOOT_SIZE=$TARGET_SECTORS
    else
        BOOT_SIZE=$BOOT_SIZE_ORIGINAL
    fi
    
    echo "Detected boot partition start: $BOOT_START, size: $BOOT_SIZE sectors ($(($BOOT_SIZE * 512 / 1024 / 1024)) MB) ..."
else
    echo "Could not detect boot partition details from image, using defaults ..."
    BOOT_SIZE=524288  # 256MB in sectors
fi

if echo "$PART_INFO" | grep -q 'img2'; then
    ROOT_START=$(echo "$PART_INFO" | grep 'img2' | awk '{print $2}')
    echo "Detected root partition start: $ROOT_START"
fi

echo "Using boot partition offset: $BOOT_START sectors"
echo "Using root partition offset: $ROOT_START sectors"

if [ -v BOOT_SIZE_ORIGINAL ] && [ $BOOT_SIZE -lt $BOOT_SIZE_ORIGINAL ]; then
    echo "Streaming partial boot partition ($(($BOOT_SIZE * 512 / 1024 / 1024)) MB of $(($BOOT_SIZE_ORIGINAL * 512 / 1024 / 1024)) MB) to $INACTIVE_BOOT ..."
    echo "WARNING: if boot partition contents are >256 MB, boot files will be missing due to size limitation!"
else
    echo "Streaming boot partition to $INACTIVE_BOOT ..."
fi
gunzip -c "$IMAGE_FILE" | dd bs=512 skip=$BOOT_START count=$BOOT_SIZE of="$INACTIVE_BOOT" conv=notrunc status=progress

echo "Streaming root partition to $INACTIVE_ROOT ..."
gunzip -c "$IMAGE_FILE" | dd bs=512 skip=$ROOT_START of="$INACTIVE_ROOT" conv=notrunc status=progress

echo "Mounting updated partitions for configuration ..."
mount "$INACTIVE_BOOT" "$TEMP_DIR/mnt_boot"
mount "$INACTIVE_ROOT" "$TEMP_DIR/mnt_root"

if [ -f "$TEMP_DIR/mnt_boot/cmdline.txt" ]; then
    echo "Found cmdline.txt in image, updating for both A and B partitions ..."
    
    echo ""
    echo "Original cmdline.txt content:"
    cat "$TEMP_DIR/mnt_boot/cmdline.txt"
    
    cp "$TEMP_DIR/mnt_boot/cmdline.txt" "$TEMP_DIR/mnt_boot/cmdline.txt.new"
    echo "Replacing root PARTUUID with ${INACTIVE_ROOT_PARTUUID} for inactive partition ..."
    sed -i "s|root=PARTUUID=[^ ]*|root=PARTUUID=${INACTIVE_ROOT_PARTUUID}|" "$TEMP_DIR/mnt_boot/cmdline.txt.new"
    
    echo ""
    echo "Modified cmdline.txt content:"
    cat "$TEMP_DIR/mnt_boot/cmdline.txt.new"
    
    mv "$TEMP_DIR/mnt_boot/cmdline.txt.new" "$TEMP_DIR/mnt_boot/cmdline.txt"
    
    echo "Creating cmdline-b.txt with active root PARTUUID ${ACTIVE_ROOT_PARTUUID} ..."
    echo ""
    cp "$TEMP_DIR/mnt_boot/cmdline.txt" "$TEMP_DIR/mnt_boot/cmdline-b.txt"
    sed -i "s|root=PARTUUID=${INACTIVE_ROOT_PARTUUID}|root=PARTUUID=${ACTIVE_ROOT_PARTUUID}|" "$TEMP_DIR/mnt_boot/cmdline-b.txt"
else
    echo "Warning: cmdline.txt not found in image. Creating from scratch ..."
    echo ""
    BASE_CMDLINE="console=ttyAMA3,115200 console=tty1 root=PARTUUID=PLACEHOLDER rootfstype=ext4 fsck.repair=yes rootwait"
    
    echo "Creating cmdline.txt for inactive root partition (PARTUUID=${INACTIVE_ROOT_PARTUUID}) ..."
    echo "${BASE_CMDLINE/PLACEHOLDER/$INACTIVE_ROOT_PARTUUID}" > "$TEMP_DIR/mnt_boot/cmdline.txt"
    echo ""
    echo "Creating cmdline-b.txt for active root partition (PARTUUID=${ACTIVE_ROOT_PARTUUID}) ..."
    echo "${BASE_CMDLINE/PLACEHOLDER/$ACTIVE_ROOT_PARTUUID}" > "$TEMP_DIR/mnt_boot/cmdline-b.txt"
fi

echo "--------------------------------"
echo "Final cmdline.txt:"
cat "$TEMP_DIR/mnt_boot/cmdline.txt"
echo "--------------------------------"
echo "Final cmdline-b.txt:"
cat "$TEMP_DIR/mnt_boot/cmdline-b.txt"
echo "--------------------------------"

echo "Creating tryboot.txt ..."
cat > "$TEMP_DIR/mnt_boot/tryboot.txt" << EOF
# This configuration will be used when booting in tryboot mode
# Point to the alternate partition
kernel=wlanpi-kernel8.img
os_prefix=$ACTIVE_BOOT_NUM:/
cmdline=cmdline-b.txt
EOF

echo "Creating autoboot.txt on inactive boot partition ..."
cat > "$TEMP_DIR/mnt_boot/autoboot.txt" << EOF
[all]
tryboot_a_b=1
boot_partition=$INACTIVE_BOOT_NUM

[tryboot]
boot_partition=$ACTIVE_BOOT_NUM
EOF

echo "Updating autoboot.txt on active boot partition ..."
cat > /boot/autoboot.txt << EOF
[all]
tryboot_a_b=1
boot_partition=$ACTIVE_BOOT_NUM

[tryboot]
boot_partition=$INACTIVE_BOOT_NUM
EOF

echo "Updating fstab in inactive root partition ..."
cat > "$TEMP_DIR/mnt_root/etc/fstab" << EOF
PARTUUID=${INACTIVE_ROOT_PARTUUID}  /        ext4    defaults,noatime  0  1
PARTUUID=${INACTIVE_BOOT_PARTUUID}  /boot    vfat    defaults          0  2
PARTUUID=${HOME_PARTUUID}           /home    ext4    defaults,noatime  0  2
EOF

echo "Unmounting partitions ..."
umount "$TEMP_DIR/mnt_boot"
umount "$TEMP_DIR/mnt_root"

echo "Cleaning up ..."
rm -rf "$TEMP_DIR"

echo "=== $INACTIVE_SET partitions update complete ==="
echo ""
echo "If try boot is working, these should function to switch partition sets:"
echo "sudo reboot '5 tryboot'  # When going from A to B"
echo "sudo reboot '1 tryboot'  # When going from B to A"