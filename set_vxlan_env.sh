#!/usr/bin/env bash

cd "$( dirname "${BASH_SOURCE[0]}" )"
SCRIPT_DIR="$(pwd)"
CONFIG_FILE="${SCRIPT_DIR}/vxlan.conf"
HOST_BRIDGE_IP=

main() {
    cd "$SCRIPT_DIR"

    init_env || return 1
    set_vxlan || return 1
}

init_env() {
    . "$CONFIG_FILE"

    VXLAN_EXTERNAL_BRIDGE_NAME=${VXLAN_EXTERNAL_BRIDGE_NAME:-br9}
    VXLAN_NAME=${VXLAN_NAME:-vxlan9}
    VXLAN_GW_NAME=${VXLAN_GW_NAME:-vxlan9gw}

    HOST_BRIDGE_IP=$(ip address show dev "$HOST_BRIDGE_INTERFACE" \
            | grep -o "inet [0-9]*\.[0-9]*\.[0-9]*\.[0-9]*" \
            | grep -o "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*")

    return 0
}

log_err() {
    echo "ERROR: $1" >&2
}
log_info() {
    echo "INFO: $1"
}

set_vxlan() {


    ip link add ${VXLAN_NAME} type vxlan id 9 dstport 4789 \
            local ${HOST_BRIDGE_IP} group 239.1.1.1 dev $HOST_BRIDGE_INTERFACE || {
        log_err "Failed to create a name space \"vxlan100\""
        return 1
    }

    # Create interfaces
    (
        # Create a GW connects VXLAN and outer local network segments.
        set -e
        #brctl addbr br100
        brctl addif ${VXLAN_EXTERNAL_BRIDGE_NAME} ${VXLAN_NAME}
        brctl stp ${VXLAN_EXTERNAL_BRIDGE_NAME} off
        #ip link set up dev br100
        ip link set up dev ${VXLAN_NAME}

        ip link add name veth1 type veth peer name veth1-br
        ip netns add ${VXLAN_GW_NAME}
        brctl addif ${VXLAN_EXTERNAL_BRIDGE_NAME} veth1-br
        ip link set veth1 netns ${VXLAN_GW_NAME}
        ip link add name veth2 type veth peer name veth2-br
        ip link set veth2 netns ${VXLAN_GW_NAME}
        brctl addif br0 veth2-br

        ip link set veth1-br up
        ip netns exec ${VXLAN_GW_NAME} ip link set veth1 up
        ip link set veth2-br up
        ip netns exec ${VXLAN_GW_NAME} ip link set veth2 up

        ip netns exec ${VXLAN_GW_NAME} sysctl net.ipv4.ip_forward=1
    ) || {
        echo "Failed to create bridges and a namespace." >&2
        return 1
    }

    #ip netns exec vxlan100gw ip address add 192.168.2.1/24 dev veth1
    ip netns exec ${VXLAN_GW_NAME} ip address add ${VXLAN_GW_INNER_IP} dev veth1 || {
        echo "Failed to set vxlan gw inner IP as ${VXLAN_GW_INNER_IP} on veth1" >&2
        return 1
    }
    #ip netns exec vxlan100gw ip address add 192.168.1.254/24 dev veth2
    ip netns exec ${VXLAN_GW_NAME} ip address add ${VXLAN_GW_OUTER_IP} dev veth2 || {
        echo "Failed to set vxlan gw inner IP as ${VXLAN_GW_OUTER_IP} on veth2" >&2
        return 1
    }

    ip netns exec ${VXLAN_GW_NAME} ip route add default via ${PRIVODER_GW} || {
        echo "Failed to set default gw IP ${PROVIDER_GW} of the namespace ${VXLAN_GW_NAME}." >&2
        return 1
    }

    # Set NAT MASQUERADE
    (
        set -e
        ip netns exec ${VXLAN_GW_NAME} iptables --table nat --flush
        ip netns exec ${VXLAN_GW_NAME} iptables --table nat \
                --append POSTROUTING --source ${VXLAN_NAT_SOURCE_IP_TO_EXTERNAL_NETWORK} --jump MASQUERADE
        ip netns exec ${VXLAN_GW_NAME} iptables --table nat \
                --append POSTROUTING --source ${VXLAN_NAT_SOURCE_IP_TO_INNER_SEGMENT} \
                --destination ${VXLAN_NAT_SOURCE_IP_TO_OUTER_SEGMENT} --jump MASQUERADE
        ip netns exec ${VXLAN_GW_NAME} iptables --table nat --list
    ) || {
        log_err "Failed to set MASQUERADE of the iptables."
        return 1
    }

    return 0
}

x_brctl_addif() {
    local vxlan_external_bridge_name="$1"
    local vxlan_name="$2"
}

main "$@"

