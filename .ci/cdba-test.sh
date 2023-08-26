#!/bin/sh -e
# Build and test the ramdisk for a given device

if [ "$(id -u)" = 0 ]; then
	set -x
	wget "https://gitlab.com/postmarketOS/ci-common/-/raw/master/install_pmbootstrap.sh"
	sh ./install_pmbootstrap.sh
	apk -q add expect
	exec su "${TESTUSER:-pmos}" -c "sh -e $0 $1 $2"
fi

set -x
DEVICE="$1"
CDBA_DEVICE="$2"
set +x
CDBA_HOST="vault.connolly.tech"
CDBA_PORT="2233"

mkdir -p ~/.ssh
cat > ~/.ssh/config <<EOF
Host tiger.cdba
	User cdba
	Port $CDBA_PORT
	HostName $CDBA_HOST
	StrictHostKeyChecking no
EOF

chown -R "$(id -u):$(id -g)" ~/.ssh
chmod 700 ~/.ssh

eval $(ssh-agent -s)
echo "$CDBA_SSH_KEY" | tr -d '\r' | ssh-add -

cat ~/.ssh/config
cdba -h tiger.cdba -l


# Build the ramdisk
export PYTHONUNBUFFERED=1

pmbootstrap config device "$DEVICE"

pmbootstrap initfs hook_add debug-shell
pmbootstrap export

cat > /tmp/cdba.expect <<EOF
spawn cdba -h tiger.cdba -b $CDBA_DEVICE $(pmbootstrap config work)/chroot_rootfs_$(pmbootstrap config device)/boot/boot.img
set timeout 60
expect "### postmarketOS initramfs ###"
expect "WARNING: debug-shell is active"
expect "~ #"
send -- "uname -a\r"
expect "~ #"
send -- ". init_functions.h"
expect "~ #"
send -- "find_boot_partition\r"
expect "/dev/mapper/userdata1"
send_user -- "\n"
EOF

echo "Running expect script:"
cat /tmp/cdba.expect

set -x
expect -f /tmp/cdba.expect
