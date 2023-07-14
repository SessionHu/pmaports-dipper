#!/bin/sh -e

if [ "$(id -u)" = 0 ]; then
	set -x
	wget "https://gitlab.com/postmarketOS/ci-common/-/raw/master/install_pmbootstrap.sh"
	sh ./install_pmbootstrap.sh
	exec su "${TESTUSER:-pmos}" -c "sh -e $0"
fi

curl -o https://connolly.tech/autotester/rrst-0.1.0-r0.apk
apk add rrst-0.1.0-r0.apk
apk add picocom fastboot

rrst -d -c /etc/rrst/axolotl.ini &

pmbootstrap config ui "$UI"
pmbootstrap config device "$DEVICE"
pmbootstrap -y init

pmbootstrap install --password 147147
pmbootstrap flasher flash_rootfs
pmbootstrap flasher flash_kernel
fastboot reboot

picocom "$(rrst pty)"
