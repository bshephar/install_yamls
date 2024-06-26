#!/bin/bash
# set -x

if [ "$EUID" -eq 0 ]; then
    echo "Please do not run as root."
    exit 1
fi

NETWORK_NAME=${NETWORK_NAME:-"crc-bmaas"}

function usage {
    echo
    echo "options:"
    echo "  --create        Create baremetal bridge on worker node"
    echo "  --cleanup       Delete baremetal bridge on worker node"
    echo
}

MY_TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "$MY_TMP_DIR"' EXIT

function create {
    local temp_file
    temp_file=$(mktemp -p "$MY_TMP_DIR")
    cat << EOF > "$temp_file"
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: $NETWORK_NAME
spec:
  desiredState:
    interfaces:
    - name: $NETWORK_NAME
      type: linux-bridge
      state: up
      mtu: 1500
      ipv4:
        dhcp: false
        address:
        - ip: $BMAAS_BRIDGE_IPADDRESS
          prefix-length: 24
        enabled: true
      bridge:
        options:
          stp:
            enabled: false
        port:
        - name: $IFACE
EOF
    # cat "$temp_file"
    oc -n openshift-nmstate apply -f "$temp_file"
}

function cleanup {
    local temp_file
    if oc -n openshift-nmstate get nodenetworkconfigurationpolicy.nmstate.io/"$NETWORK_NAME"; then
        temp_file=$(mktemp -p "$MY_TMP_DIR")
        cat << EOF > "$temp_file"
apiVersion: nmstate.io/v1
kind: NodeNetworkConfigurationPolicy
metadata:
  name: $NETWORK_NAME
spec:
  desiredState:
    interfaces:
    - name: $NETWORK_NAME
      type: linux-bridge
      state: absent
EOF
        # cat $temp_file
        oc -n openshift-nmstate apply -f "$temp_file"
        echo "Waiting 10 seconds before deleting the NNCP"
        # TODO(hjensas): Use "oc get nncp $NETWORK_NAME" and check status + reason instead
        #                It will move to Progressing to Configured state.
        sleep 30
        oc -n openshift-nmstate delete nodenetworkconfigurationpolicy.nmstate.io/"$NETWORK_NAME" --wait=true || true
    fi
}

case "$1" in
    "--create")
        ACTION="CREATE";
    ;;
    "--cleanup")
        ACTION="CLEANUP";
    ;;
    *)
        echo >&2 "Invalid option: $*";
        usage;
        exit 1
    ;;
esac


if [ -z "$ACTION" ]; then
    echo "Not enough input arguments"
    usage
    exit 1
fi

WORKER=$(oc get nodes -l node-role.kubernetes.io/worker -o jsonpath="{.items[*].metadata.name}")
MAC_ADDRESS=$(virsh --connect=qemu:///system domiflist crc | grep "${NETWORK_NAME}" | awk '{print $5}')
if [ -n "$MAC_ADDRESS" ]; then
    IFACE=$(oc debug node/"$WORKER" -- ip -o link | grep "link/ether ${MAC_ADDRESS,,}" | awk '{ print $2 }' | awk -F: '{ print $1 }')
fi

if [ "$ACTION" == "CREATE" ]; then
    if [ -z "$IFACE" ]; then
        echo "Unable to determine interface, cannot create bridge $NETWORK_NAME"
        exit 1
    fi
    create
elif [ "$ACTION" == "CLEANUP" ]; then
    if [ -z "$MAC_ADDRESS" ]; then
        echo "CRC instance does not have and interface on network ${NETWORK_NAME}"
    else
        cleanup
    fi
fi
