= vxlan-builder =
This script is to create vxlan infrastructure in my home server.

== Usage ==
You can clone this repository and you can modify the vxlan.conf.

* vxlan_conf.yaml
```
HOST_BRIDGE_INTERFACE="br0"
VXLAN_GW_INNER_IP="192.168.2.254/24"
VXLAN_GW_OUTER_IP="192.168.1.254/24"
VXLAN_NAT_SOURCE_IP="192.168.2.0/24"
```

Then you can run the set_vxlan_env.sh_.

```
# ./set_vxlan_env.sh
```



