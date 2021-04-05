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

    HOST_BRIDGE_IP=$(ip address show dev "$HOST_BRIDGE_INTERFACE" \
            | grep -o "inet [0-9]*\.[0-9]*\.[0-9]*\.[0-9]*" \
            | grep -o "[0-9]*\.[0-9]*\.[0-9]*\.[0-9]*")

    return 0
}

set_vxlan() {
    ip link add vxlan100 type vxlan id 100 dstport 4789 \
            local ${HOST_BRIDGE_IP} group 239.1.1.1 dev $HOST_BRIDGE_INTERFACE

    # Create interfaces
    (
        # Create a GW connects VXLAN and outer local network segments.
        set -e
        brctl addbr br100
        brctl addif br100 vxlan100
        brctl stp br100 off
        ip link set up dev br100
        ip link set up dev vxlan100

        ip link add name veth1 type veth peer name veth1-br
        ip netns add vxlan100gw
        brctl addif br100 veth1-br
        ip link set veth1 netns vxlan100gw
        ip link add name veth2 type veth peer name veth2-br
        ip link set veth2 netns vxlan100gw
        brctl addif br0 veth2-br

        ip link set veth1-br up
        ip netns exec vxlan100gw ip link set veth1 up
        ip link set veth2-br up
        ip netns exec vxlan100gw ip link set veth2 up

        ip netns exec vxlan100gw sysctl net.ipv4.ip_forward=1
    ) || {
        echo "Failed to create bridges and a namespace." >&2
        return 1
    }

    #ip netns exec vxlan100gw ip address add 192.168.2.1/24 dev veth1
    ip netns exec vxlan100gw ip address add ${VXLAN_GW_INNER_IP} dev veth1 || {
        echo "Failed to set vxlan gw inner IP as ${VXLAN_GW_INNER_IP} on veth1" >&2
        return 1
    }
    #ip netns exec vxlan100gw ip address add 192.168.1.254/24 dev veth2
    ip netns exec vxlan100gw ip address add ${VXLAN_GW_OUTER_IP} dev veth2 || {
        echo "Failed to set vxlan gw inner IP as ${VXLAN_GW_OUTER_IP} on veth2" >&2
        return 1
    }

    ip netns exec vxlan100gw ip route add default via 192.168.1.1 || {
        echo "Failed to set default gw IP 192.168.1.1 of the namespace vxlan100gw." >&2
        return 1
    }

    # Set NAT MASQUERADE
    (
        set -e
        ip netns exec vxlan100gw iptables --table nat --flush
        ip netns exec vxlan100gw iptables --table nat --append POSTROUTING --source ${VXLAN_NAT_SOURCE_IP} --jump MASQUERADE
        ip netns exec vxlan100gw iptables -n --table nat --list
    ) || {
        echo "Failed to set MASQUERADE of the iptables." >&2
        return 1
    }

    return 0
}

main "$@"

