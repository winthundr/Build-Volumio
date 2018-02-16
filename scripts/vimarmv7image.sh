#!/bin/sh

# Default build for Debian 32bit
ARCH="armv7"

while getopts ":v:p:a:" opt; do
  case $opt in
    v)
      VERSION=$OPTARG
      ;;
    p)
      PATCH=$OPTARG
      ;;
    a)
      ARCH=$OPTARG
      ;;
  esac
done

BUILDDATE=$(date -I)
IMG_FILE="Volumio${VERSION}-${BUILDDATE}-vim-armv7.img"

if [ "$ARCH" = arm ]; then
  DISTRO="Raspbian"
else
  DISTRO="Debian 32bit"
fi

echo "Creating Image File ${IMG_FILE} with ${DISTRO} rootfs"

dd if=/dev/zero of=${IMG_FILE} bs=1M count=2800

echo "Creating Image Bed"
LOOP_DEV=`sudo losetup -f --show ${IMG_FILE}`
# Note: leave the first 20Mb free for the firmware
parted -s "${LOOP_DEV}" mklabel msdos
parted -s "${LOOP_DEV}" mkpart primary fat32 1 64
parted -s "${LOOP_DEV}" mkpart primary ext3 65 2500
parted -s "${LOOP_DEV}" mkpart primary ext3 2500 100%
parted -s "${LOOP_DEV}" set 1 boot on
parted -s "${LOOP_DEV}" print
partprobe "${LOOP_DEV}"
kpartx -s -a "${LOOP_DEV}"

BOOT_PART=`echo /dev/mapper/"$( echo ${LOOP_DEV} | sed -e 's/.*\/\(\w*\)/\1/' )"p1`
SYS_PART=`echo /dev/mapper/"$( echo ${LOOP_DEV} | sed -e 's/.*\/\(\w*\)/\1/' )"p2`
DATA_PART=`echo /dev/mapper/"$( echo ${LOOP_DEV} | sed -e 's/.*\/\(\w*\)/\1/' )"p3`
echo "Using: " ${BOOT_PART}
echo "Using: " ${SYS_PART}
echo "Using: " ${DATA_PART}
if [ ! -b "${BOOT_PART}" ]
then
	echo "${BOOT_PART} doesn't exist"
	exit 1
fi

echo "Creating boot and rootfs filesystems"
mkfs -t vfat -n BOOT "${BOOT_PART}"
mkfs -F -t ext4 -L volumio "${SYS_PART}"
mkfs -F -t ext4 -L volumio_data "${DATA_PART}"
sync

echo "Preparing for the AML kernel and platform files"
if [ -d platform-aml ]
then
	echo "Pull from repo"
	cd platform-aml
	git pull
	cd ..
else
	echo "Clone all Khadas files from repo"
	git clone https://github.com/150balbes/platform-aml.git platform-aml
#	cd ..
fi

echo "Copying the bootloader"
dd if=platform-aml/s9xxx/uboot/u-boot.bin.sd.bin of=${LOOP_DEV} conv=fsync bs=1 count=442
dd if=platform-aml/s9xxx/uboot/u-boot.bin.sd.bin of=${LOOP_DEV} conv=fsync bs=512 skip=1 seek=1
sync

echo "Preparing for Volumio rootfs"
if [ -d /mnt ]
then
	echo "/mount folder exist"
else
	mkdir /mnt
fi
if [ -d /mnt/volumio ]
then
	echo "Volumio Temp Directory Exists - Cleaning it"
	rm -rf /mnt/volumio/*
else
	echo "Creating Volumio Temp Directory"
	mkdir /mnt/volumio
fi

echo "Creating mount point for the images partition"
mkdir /mnt/volumio/images
mount -t ext4 "${SYS_PART}" /mnt/volumio/images
mkdir /mnt/volumio/rootfs
echo "Creating mount point for the boot partition"
mkdir /mnt/volumio/rootfs/boot
mount -t vfat "${BOOT_PART}" /mnt/volumio/rootfs/boot

echo "Copying Volumio RootFs"
cp -pdR build/$ARCH/root/* /mnt/volumio/rootfs
echo "Copying Khadas boot files"
cp -pdR platform-aml/s9xxx/boot/* /mnt/volumio/rootfs/boot
echo "Copying Khadas modules"
cp -pdR platform-aml/s9xxx/lib/modules /mnt/volumio/rootfs/lib/
echo "Copying Khadas firmware"
cp -pdR platform-aml/s9xxx/lib/firmware /mnt/volumio/rootfs/lib/
echo "Copying Khadas etc files"
cp -pdR platform-aml/s9xxx/etc/* /mnt/volumio/rootfs/etc
echo "Copying Khadas usr/bin files"
cp -pdR platform-aml/s9xxx/usr/* /mnt/volumio/rootfs/usr
sync

echo "Preparing to run chroot for more VIM configuration"
cp scripts/vimarmv7config.sh /mnt/volumio/rootfs
cp scripts/initramfs/init.nextarm /mnt/volumio/rootfs/root/init
#cp scripts/initramfs/init.next_nofs /mnt/volumio/rootfs/root/init
cp scripts/initramfs/mkinitramfs-custom.sh /mnt/volumio/rootfs/usr/local/sbin
#copy the scripts for updating from usb
wget -P /mnt/volumio/rootfs/root http://repo.volumio.org/Volumio2/Binaries/volumio-init-updater

mount /dev /mnt/volumio/rootfs/dev -o bind
mount /proc /mnt/volumio/rootfs/proc -t proc
mount /sys /mnt/volumio/rootfs/sys -t sysfs
echo $PATCH > /mnt/volumio/rootfs/patch

if [ -f "/mnt/volumio/rootfs/$PATCH/patch.sh" ] && [ -f "config.js" ]; then
        echo "Starting config.js"
        node config.js $PATCH
fi

echo "Creating s905_autoscript.txt"
UUID_DATA=$(blkid -s UUID -o value ${DATA_PART})
UUID_IMG=$(blkid -s UUID -o value ${SYS_PART})
UUID_BOOT=$(blkid -s UUID -o value ${BOOT_PART})
echo "setenv boot_part imgpart=UUID=${UUID_IMG} imgfile=/volumio_current.sqsh bootpart=UUID=${UUID_BOOT} datapart=UUID=${UUID_DATA}" > /mnt/volumio/rootfs/boot/s905_autoscript.txt
cat /mnt/volumio/rootfs/boot/txt/s905_autoscript.cmd >> /mnt/volumio/rootfs/boot/s905_autoscript.txt

chroot /mnt/volumio/rootfs /bin/bash -x <<'EOF'
su -
/vimarmv7config.sh
EOF

#cleanup
rm /mnt/volumio/rootfs/vimarmv7config.sh
rm /mnt/volumio/rootfs/root/init

echo "Unmounting Temp devices"
umount -l /mnt/volumio/rootfs/dev
umount -l /mnt/volumio/rootfs/proc
umount -l /mnt/volumio/rootfs/sys

echo "==> VIM device installed"

#echo "Removing temporary platform files"
#echo "(you can keep it safely as long as you're sure of no changes)"
#rm -r platform-aml
sync

echo "Preparing rootfs base for SquashFS"

if [ -d /mnt/squash ]; then
	echo "Volumio SquashFS Temp Dir Exists - Cleaning it"
	rm -rf /mnt/squash/*
else
	echo "Creating Volumio SquashFS Temp Dir"
	mkdir /mnt/squash
fi

echo "Copying Volumio rootfs to Temp Dir"
cp -rp /mnt/volumio/rootfs/* /mnt/squash/

if [ -e /mnt/kernel_current.tar ]; then
	echo "Volumio Kernel Partition Archive exists - Cleaning it"
	rm -rf /mnt/kernel_current.tar
fi

echo "Creating Kernel Partition Archive"
tar cf /mnt/kernel_current.tar --exclude='resize-volumio-datapart' -C /mnt/squash/boot/ .

echo "Removing the Kernel"
rm -rf /mnt/squash/boot/*

echo "Creating SquashFS, removing any previous one"
rm -r Volumio.sqsh
mksquashfs /mnt/squash/* Volumio.sqsh

echo "Squash filesystem created"
echo "Cleaning squash environment"
rm -rf /mnt/squash

#copy the squash image inside the boot partition
cp Volumio.sqsh /mnt/volumio/images/volumio_current.sqsh
sync
echo "Unmounting Temp Devices"
umount -l /mnt/volumio/images
umount -l /mnt/volumio/rootfs/boot

dmsetup remove_all
losetup -d ${LOOP_DEV}
sync
