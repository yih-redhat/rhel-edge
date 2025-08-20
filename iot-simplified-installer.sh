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
        IMAGE_FILENAME="Fedora-IoT-provisioner-42-${COMPOSE_ID}.${ARCH}.iso"
        ;;
    "fedora-43")
        OSTREE_REF="fedora-iot/43/${ARCH}/iot"
        OS_VARIANT="fedora-unknown"
        IMAGE_FILENAME="Fedora-IoT-provisioner-43-${COMPOSE_ID}.${ARCH}.iso"
        ;;
    "fedora-44")
        OSTREE_REF="fedora-iot/44/${ARCH}/iot"
        OS_VARIANT="fedora-rawhide"
        IMAGE_FILENAME="Fedora-IoT-provisioner-44-${COMPOSE_ID}.${ARCH}.iso"
        ;;
    *)
        echo "unsupported distro: ${ID}-${VERSION_ID}"
        exit 1;;
esac

setup_fdo_server () {
    sudo dnf install -y \
        fdo-admin-cli \
        fdo-rendezvous-server \
        fdo-owner-onboarding-server \
        fdo-owner-cli \
        fdo-manufacturing-server \
        python3-pip

    sudo mkdir -p /etc/fdo/keys
    for obj in diun manufacturer device-ca owner; do
        sudo fdo-admin-tool generate-key-and-cert --destination-dir /etc/fdo/keys "$obj"
    done

    sudo mkdir -p \
        /etc/fdo/manufacturing-server.conf.d/ \
        /etc/fdo/owner-onboarding-server.conf.d/ \
        /etc/fdo/rendezvous-server.conf.d/ \
        /etc/fdo/serviceinfo-api-server.conf.d/

    sudo cp files/fdo/manufacturing-server.yml /etc/fdo/manufacturing-server.conf.d/
    sudo cp files/fdo/owner-onboarding-server.yml /etc/fdo/owner-onboarding-server.conf.d/
    sudo cp files/fdo/rendezvous-server.yml /etc/fdo/rendezvous-server.conf.d/
    sudo cp files/fdo/serviceinfo-api-server.yml /etc/fdo/serviceinfo-api-server.conf.d/

    sudo pip3 install yq
    sudo yq -iy '.service_info.diskencryption_clevis |= null' /etc/fdo/serviceinfo-api-server.conf.d/serviceinfo-api-server.yml

    # Start FDO services
    sudo systemctl start \
        fdo-owner-onboarding-server.service \
        fdo-rendezvous-server.service \
        fdo-manufacturing-server.service \
        fdo-serviceinfo-api-server.service

    # Wait for fdo server to be running
    timeout 300 bash -c '
    until [ "$(curl -s -X POST http://192.168.100.1:8080/ping)" == "pong" ]; do
        sleep 1
    done
    '

    # Check the exit status of timeout
    if [ $? -eq 124 ]; then
        echo "Error: fdo server timed out after 5 minutes"
        exit 1
    fi
}

setup_ignition () {
    sudo tee /var/www/html/fiot.ign > /dev/null << EOF
{
  "ignition": {
    "version": "3.4.0"
  },
  "passwd": {
    "users": [
      {
        "groups": [
          "wheel"
        ],
        "homeDir": "/home/admin",
        "name": "admin",
        "passwordHash": "\$6\$GRmb7S0p8vsYmXzH\$o0E020S.9JQGaHkszoog4ha4AQVs3sk8q0DvLjSMxoxHBKnB2FBXGQ/OkwZQfW/76ktHd0NX5nls2LPxPuUdl.",
        "shell": "/bin/bash"
      }
    ]
  }
}
EOF
}

download_image () {
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

setup_fdo_server

setup_ignition

virt-install --name "iot-${TEST_UUID}" \
            --memory 4096 \
            --vcpus 2 \
            --os-variant fedora-unknown \
            --disk path="/var/lib/libvirt/images/iot-${TEST_UUID}".qcow2,format=qcow2,size=20,bus=virtio \
            --network network=integration,mac=34:49:22:B0:83:30 \
            --graphics none \
            --boot uefi \
            --tpm backend.type=emulator,backend.version=2.0,model=tpm-tis \
            --extra-args="rd.neednet=1 coreos.inst.crypt_root=1 coreos.inst.isoroot=Fedora-${VERSION_ID}-IoT-${ARCH} coreos.inst.install_dev=/dev/vda coreos.inst.image_file=/run/media/iso/image.raw.xz coreos.inst.insecure fdo.manufacturing_server_url=http://192.168.100.1:8080 fdo.diun_pub_key_insecure=true coreos.inst.append=rd.neednet=1 coreos.inst.append=ignition.config.url=http://192.168.100.1/ignition/fiot.ign console=ttyS0" \
            --location "/var/lib/libvirt/images/${IMAGE_FILENAME}",initrd=images/pxeboot/initrd.img,kernel=images/pxeboot/vmlinuz

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

ansible-playbook -v -i "${TEMPDIR}/inventory" -e fdo_credential="true" check-iot.yaml || RESULTS=0

check_result

exit 0
