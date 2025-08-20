#!/bin/bash
set -euox pipefail

# Provision the software under test.
./iot-setup.sh

# Get OS data.
source /etc/os-release

ARCH=$(uname -m)
TEST_UUID=$(uuidgen)
TEMPDIR=$(mktemp -d)
GUEST_IP=192.168.100.50
SSH_OPTIONS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5)
SSH_KEY=key/ostree_key
SSH_KEY_PUB=$(cat "${SSH_KEY}".pub)

COMPOSE_URL="https://kojipkgs.fedoraproject.org/compose/iot/${COMPOSE}/compose/IoT/${ARCH}/iso/"
COMPOSE_ID=$(echo ${COMPOSE} | cut -d- -f4)

case "${ID}-${VERSION_ID}" in
    "fedora-42")
        OSTREE_REF="fedora-iot/42/${ARCH}/iot"
        OS_VARIANT="fedora-unknown"
        IMAGE_FILENAME="Fedora-IoT-ostree-42-${COMPOSE_ID}.${ARCH}.iso"
        ;;
    "fedora-43")
        OSTREE_REF="fedora-iot/43/${ARCH}/iot"
        OS_VARIANT="fedora-unknown"
        IMAGE_FILENAME="Fedora-IoT-ostree-43-${COMPOSE_ID}.${ARCH}.iso"
        ;;
    "fedora-44")
        OSTREE_REF="fedora-iot/44/${ARCH}/iot"
        OS_VARIANT="fedora-rawhide"
        IMAGE_FILENAME="Fedora-IoT-ostree-44-${COMPOSE_ID}.${ARCH}.iso"
        ;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1;;
esac

function modksiso {
    isomount=$(mktemp -d)
    kspath=$(mktemp -d)

    iso="$1"
    newiso="$2"

    echo "Mounting ${iso} -> ${isomount}"
    sudo mount -v -o ro "${iso}" "${isomount}"

    cleanup() {
        sudo umount -v "${isomount}"
        rmdir -v "${isomount}"
        rm -rv "${kspath}"
    }

    trap cleanup RETURN

    ksfiles=("${isomount}"/*.ks)
    ksfile="${ksfiles[0]}"  # there shouldn't be more than one anyway
    echo "Found kickstart file ${ksfile}"

    ksbase=$(basename "${ksfile}")
    newksfile="${kspath}/${ksbase}"
    oldks=$(cat "${ksfile}")
    echo "Preparing modified kickstart file"
    cat > "${newksfile}" << EOFKS
text
network --bootproto=dhcp --device=link --activate --onboot=on
zerombr
clearpart --all --initlabel --disklabel=msdos
autopart --nohome --noswap --type=plain
user --name=admin --groups=wheel --iscrypted --password=\$6\$1LgwKw9aOoAi/Zy9\$Pn3ErY1E8/yEanJ98evqKEW.DZp24HTuqXPJl6GYCm8uuobAmwxLv7rGCvTRZhxtcYdmC0.XnYRSR9Sh6de3p0
sshkey --username=admin "${SSH_KEY_PUB}"
${oldks}
poweroff
%post --log=/var/log/anaconda/post-install.log --erroronfail
# no sudo password for user admin
echo -e 'admin\tALL=(ALL)\tNOPASSWD: ALL' >> /etc/sudoers
echo -e 'installeruser\tALL=(ALL)\tNOPASSWD: ALL' >> /etc/sudoers
%end
EOFKS

    echo "Writing new ISO"
    sudo mkksiso -c "console=ttyS0,115200" "${newksfile}" "${iso}" "${newiso}"

    echo "==== NEW KICKSTART FILE ===="
    cat "${newksfile}"
    echo "============================"
}

function download_image {
    IMAGE_URL="${COMPOSE_URL}/${IMAGE_FILENAME}"
    sudo wget --progress=bar "$IMAGE_URL"
    if [ $? -eq 0 ] && [ -f "$IMAGE_FILENAME" ]; then
        echo "Download completed successfully: ${IMAGE_FILENAME}"
    else
        echo "Download failed. Please check the URL and try again."
        exit 1
    fi
}

wait_for_ssh_up () {
    SSH_STATUS=$(sudo ssh "${SSH_OPTIONS[@]}" -i "${SSH_KEY}" admin@"${1}" '/bin/bash -c "echo -n READY"')
    if [[ $SSH_STATUS == READY ]]; then
        echo 1
    else
        echo 0
    fi
}

check_result () {
    greenprint "Checking for test result"
    if [[ $RESULTS == 1 ]]; then
        greenprint "💚 Success"
    else
        greenprint "❌ Failed"
        clean_up
        exit 1
    fi
}

download_image

modksiso "${IMAGE_FILENAME}" "/var/lib/libvirt/images/${IMAGE_FILENAME}"

virt-install  --name="iot-${TEST_UUID}" \
            --disk path="/var/lib/libvirt/images/iot-${TEST_UUID}.qcow2",size=20,format=qcow2 \
            --ram 4096 \
            --vcpus 2 \
            --network network=integration,mac=34:49:22:B0:83:30 \
            --os-variant fedora-unknown \
            --cdrom "/var/lib/libvirt/images/${IMAGE_FILENAME}" \
            --nographics \
            --noautoconsole \
            --wait=-1 \
            --noreboot

# Start VM.
greenprint "Start VM"
sudo virsh start "iot-${TEST_UUID}"

# Check for ssh ready to go.
greenprint "🛃 Checking for SSH is ready to go"
for _ in $(seq 0 30); do
    RESULTS="$(wait_for_ssh_up $GUEST_IP)"
    if [[ $RESULTS == 1 ]]; then
        echo "SSH is ready now! 🥳"
        break
    fi
    sleep 10
done

tee "${TEMPDIR}"/inventory > /dev/null << EOF
[ostree_guest]
${GUEST_IP}
[ostree_guest:vars]
ansible_python_interpreter=/usr/bin/python3
ansible_user=admin
ansible_private_key_file=${SSH_KEY}
ansible_ssh_common_args="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
EOF

ansible-playbook -v -i "${TEMPDIR}/inventory" -e fdo_credential="false" check-iot.yaml || RESULTS=0

check_result

exit 0
