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
            | cut -d ' ' -f 2)

    [[ -z "$HOST_BRIDGE_IP" ]] && {
        log_err "Failed to get IP of the interface \"$HOST_BRIDGE_INTERFACE\""
        return 1
    }

    return 0
}

log_err() {
    echo "ERROR: $1" >&2
}
log_info() {
    echo "INFO: $1"
}

set_vxlan() {
    # Create interfaces
    (
        # Create a GW connects VXLAN and outer local network segments.
        set -e
        x_ip_link_add_vxlan ${VXLAN_NAME} ${HOST_BRIDGE_IP} ${HOST_BRIDGE_INTERFACE}
        #brctl addbr br100
        x_brctl_addif ${VXLAN_EXTERNAL_BRIDGE_NAME} ${VXLAN_NAME}
        brctl stp ${VXLAN_EXTERNAL_BRIDGE_NAME} off
        #ip link set up dev br100
        ip link set up dev ${VXLAN_EXTERNAL_BRIDGE_NAME}

        x_ip_netns_add ${VXLAN_GW_NAME}
        x_ip_link_add_name_veth veth1 veth1-br
        x_brctl_addif ${VXLAN_EXTERNAL_BRIDGE_NAME} veth1-br
        x_ip_link_set_veth_to_netns veth1 ${VXLAN_GW_NAME}
        x_ip_link_add_name_veth veth2 veth2-br
        x_ip_link_set_veth_to_netns veth2 ${VXLAN_GW_NAME}
        x_brctl_addif ${HOST_BRIDGE_INTERFACE} veth2-br

        ip link set veth1-br up
        ip netns exec ${VXLAN_GW_NAME} ip link set veth1 up
        ip link set veth2-br up
        ip netns exec ${VXLAN_GW_NAME} ip link set veth2 up

        ip netns exec ${VXLAN_GW_NAME} sysctl net.ipv4.ip_forward=1

        # Add IP to the interface on namespace
        x_ip_address_add_to_interface_on_netns ${VXLAN_GW_NAME} ${VXLAN_GW_INNER_IP} veth1
        x_ip_address_add_to_interface_on_netns ${VXLAN_GW_NAME} ${VXLAN_GW_OUTER_IP} veth2
        x_add_default_gw_on_netns ${VXLAN_GW_NAME} ${PROVIDER_GW}
    ) || {
        echo "Failed to create bridges and a namespace." >&2
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

x_add_default_gw_on_netns() {
    local netns_name="$1"
    local next_hop_ip="$2"

    ip netns exec $netns_name ip route show default | grep -q -P '^default ' && {
        log_info "Default gateway has already set on netns \"$netns_name\". Skipping set it"
        return 0
    }

    ip netns exec $netns_name ip route add default via $next_hop_ip
}

x_ip_address_add_to_interface_on_netns() {
    local netns_name="$1"
    local ip="$2"
    local interface_in_netns="$3"

    local interface_ip="$(ip netns exec $netns_name ip address show $interface_in_netns | grep -o "inet [0-9]*\.[0-9]*\.[0-9]*\.[0-9]*" | cut -d ' ' -f 2)"

    [[ "$interface_ip" == "$ip" ]] && {
        log_info "IP \"$ip\" has already set in netns \"$netns_name\". Skipping set it"
        return 0
    }

    ip netns exec ${VXLAN_GW_NAME} ip address add ${VXLAN_GW_INNER_IP} dev veth1
}

# Add bridge only if it was not added.
x_brctl_addif() {
    local bridge_name_to_add="$1"
    local bridge_name_to_be_added="$2"
    local line

    while read line; do
        [[ "$line" == "$bridge_name_to_be_added" ]] && {
            log_info "The bridge \"$bridge_name_to_be_added\" is already added to \"$bridge_name_to_add\"."
            return 0
        }
    done < <(brctl show $bridge_name_to_add | tail +2 | sed -e 's/.*\s\([^\s]\+\)$/\1/g')

    brctl addif $bridge_name_to_add $bridge_name_to_be_added || {
        log_err "Failed to add bridge \"$bridge_name_to_be_added\" to \"$bridge_name_to_add\"."
        return 1
    }

    log_info "Succeeded in adding a bridge \"$bridge_name_to_be_added\" to \"$bridge_name_to_add\"."
    return 0
}

x_ip_link_set_veth_to_netns() {
    local veth_name="$1"
    local vxlan_gw_netns_name="$2"
    local line

    while read line; do
        [[ "$line" == "$veth_name" ]] && {
            log_info "veth \"$veth_name\" has already been set in netns \"$vxlan_gw_netns_name\""
            return 0
        }
    done < <(ip netns exec $vxlan_gw_netns_name ip link show | grep -P '^[0-9]+: ' | sed -e 's/^[0-9]\+: \([^@]\+\)\(@.*\)\?:.*/\1/g')

    ip link set $veth_name netns $vxlan_gw_netns_name
}

x_ip_netns_add() {
    local netns_name="$1"
    local line
    while read line; do
        [[ "$line" == "$netns_name" ]] && {
            log_info "netns \"$netns_name\" has already existed. Skipping add it"
            return 0
        }
    done < <(ip netns ls | cut -d ' ' -f1)

    ip netns add $netns_name
}

x_ip_link_add_name_veth() {
    local veth_name="$1"
    local veth_peer_name="$2"

    ethtool -S $veth_peer_name > /dev/null 2>&1 && {
        log_info "veth \"$veth_name\" with peer \"$veth_peer_name\" is already existed. Skipping add it"
        return 1
    }

    ip link add name $veth_name type veth peer name $veth_perr_name
}

x_ip_link_add_vxlan() {
    local vxlan_name="$1"
    local host_bridge_ip="$2"
    local host_bridge_interface="$3"

    ip link show $vxlan_name > /dev/null 2>&1 && {
        log_info "VXLAN $vxlan_name has already been installed."
        return 0
    }

     ip link add $vxlan_name type vxlan id 9 dstport 4789 \
            local $host_bridge_ip group 239.1.1.1 dev $host_bridge_interface
}

main "$@"

