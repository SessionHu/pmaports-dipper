#!/bin/sh

. ./init_functions.sh

ERRORLINES=10
CONFIGFS=/config/usb_gadget

# Default values for USB-related deviceinfo variables
usb_idVendor="0x1209" # Generic
usb_idProduct="0x4201" # Random ID
usb_serialnumber="postmarketOS"
usb_rndis_function="rndis.usb0"
usb_mass_storage_function="mass_storage.0"

log() {
	echo $1 | tee /dev/tty1
}

fatal_error() {
	#clear

	# Move cursor into row 80
	#echo -e "\033[80;0H"

	# Print the error message over the error splash
	echo "  $1"

	loop_forever
}

# $1: target image
setup_usb_configfs() {
	# See: https://www.kernel.org/doc/Documentation/usb/gadget_configfs.txt
	ROOTFS_IMAGE="$1"

	if ! [ -e "$CONFIGFS" ]; then
		fatal_error "$CONFIGFS does not exist"
	fi

	echo "Setting up an USB gadget through configfs..."
	# Create an usb gadet configuration
	mkdir $CONFIGFS/g1 || ( fatal_error "Couldn't create $CONFIGFS/g1" )
	echo "$usb_idVendor"  > "$CONFIGFS/g1/idVendor"
	echo "$usb_idProduct" > "$CONFIGFS/g1/idProduct"

	# Create english (0x409) strings
	mkdir $CONFIGFS/g1/strings/0x409 || echo "  Couldn't create $CONFIGFS/g1/strings/0x409"

	# shellcheck disable=SC2154
	echo "$MANUFACTURER" > "$CONFIGFS/g1/strings/0x409/manufacturer"
	echo "$usb_serialnumber"        > "$CONFIGFS/g1/strings/0x409/serialnumber"
	# shellcheck disable=SC2154
	echo "$PRODUCT"         > "$CONFIGFS/g1/strings/0x409/product"

	# Create rndis/mass_storage function
	mkdir $CONFIGFS/g1/functions/"$usb_rndis_function" \
		|| echo "  Couldn't create $CONFIGFS/g1/functions/$usb_rndis_function"
	mkdir $CONFIGFS/g1/functions/"$usb_mass_storage_function" \
		|| echo "  Couldn't create $CONFIGFS/g1/functions/$usb_mass_storage_function"

	# Create configuration instance for the gadget
	mkdir $CONFIGFS/g1/configs/c.1 \
		|| echo "  Couldn't create $CONFIGFS/g1/configs/c.1"
	mkdir $CONFIGFS/g1/configs/c.1/strings/0x409 \
		|| echo "  Couldn't create $CONFIGFS/g1/configs/c.1/strings/0x409"
	echo "rndis" > $CONFIGFS/g1/configs/c.1/strings/0x409/configuration \
		|| echo "  Couldn't write configration name"

	# Make sure the node for the eMMC exists
	# if [ -z "$(ls $EMMC)" ]; then
	# 	fatal_error "$EMMC could not be opened, possible eMMC defect"
	# fi

	# Set up mass storage to the target image
	echo $ROOTFS_IMAGE > $CONFIGFS/g1/functions/"$usb_mass_storage_function"/lun.0/file

	# Rename the mass storage device
	echo "postmarketOS Liveboot" > $CONFIGFS/g1/functions/"$usb_mass_storage_function"/lun.0/inquiry_string

	# Link the rndis/mass_storage instance to the configuration
	ln -s $CONFIGFS/g1/functions/"$usb_rndis_function" $CONFIGFS/g1/configs/c.1 \
		|| echo "  Couldn't symlink $usb_rndis_function"
	ln -s $CONFIGFS/g1/functions/"$usb_mass_storage_function" $CONFIGFS/g1/configs/c.1 \
		|| echo "  Couldn't symlink $usb_mass_storage_function"

	# Check if there's an USB Device Controller
	if [ -z "$(ls /sys/class/udc)" ]; then
		fatal_error "No USB Device Controller available"
	fi

	# shellcheck disable=SC2005
	echo "$(ls /sys/class/udc)" > $CONFIGFS/g1/UDC || ( fatal_error "Couldn't write to UDC" )
}

configfs_cleanup() {
	echo "Cleaning up configfs..."
	echo "" > $CONFIGFS/g1/UDC || ( fatal_error "Couldn't write to UDC" )
	rm $CONFIGFS/g1/functions/"$usb_mass_storage_function"/lun.0/file \
		|| echo "  Couldn't remove /lun.0/file"
	
	rm $CONFIGFS/g1/configs/c.1/strings/0x409/configuration \
		|| echo "  Couldn't remove configration name"
	rm -rf $CONFIGFS/g1/configs/c.1/strings/0x409 \
		|| echo "  Couldn't delete $CONFIGFS/g1/configs/c.1/strings/0x409"
	rm -rf $CONFIGFS/g1/configs/c.1 \
		|| echo "  Couldn't delete $CONFIGFS/g1/configs/c.1"
	rm -rf $CONFIGFS/g1/ \
		|| echo "  Couldn't delete $CONFIGFS/g1"
	rmmod f_mass_storage || echo "  Couldn't remove f_mass_storage"
	rmmod usb_f_mass_storage || echo "  Couldn't remove usb_f_mass_storage"
}

show_splash_loading

set -x
#clear
mkdir -p /liveboot/mnt
mount -t tmpfs -o size=4g tmpfs /liveboot
FREEMEMKB=$(cat /proc/meminfo | grep "MemFree:" | grep -Eo "[0-9]+")
echo "Device has $FREEMEMKB kB free"
if [ "$FREEMEMKB" -lt "2097152" ]; then
	fatal_error "Not enough free memory to run the liveboot"
	exit 2
fi

fallocate -l 600M /liveboot/target.img
mkfs.vfat /liveboot/target.img -n "PMOS"
setup_usb_configfs /liveboot/target.img
log "COPY THE ROOTFS TO THE TARGET, WHEN DONE EJECT THE DEVICE AND PRESS VOLUME DOWN"
hkdm &
while ! [ -f /liveboot/confirm ]; do
	sleep 1
done
configfs_cleanup
mount
losetup -a

mkdir /liveboot/mnt
mount /liveboot/target.img /liveboot/mnt
echo "Unpacking rootfs"
FILE=$(ls -1 /liveboot/mnt/ | head -1)
mv /liveboot/mnt/"$FILE" /liveboot/rootfs.img.xz
echo "unmounting target image"
umount /liveboot/mnt
echo "Deleting target image"
rm /liveboot/target.img
log "Unpacking rootfs, this may take some time"
if ! unxz /liveboot/rootfs.img.xz; then
	fatal_error "Unpacking rootfs failed"
	exit 2
fi
fdisk -l /liveboot/rootfs.img
mount
kpartx -afs /liveboot/rootfs.img
blkid
ls /dev
mount /dev/loop1p2 /sysroot
mount /dev/loop1p1 /sysroot/boot
echo "Mounting rootfs"
# mount_root_partition
# mount_boot_partition /sysroot/boot "rw"
echo "Switching root to /sysroot"
switch_root /sysroot /sbin/init

echo "AAAAAAAAAAAAAAAA"
loop_forever
