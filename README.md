# vxlan-builder
This script is to create vxlan infrastructure in my home server.

# Usage
You can clone this repository and you can modify the vxlan.conf.

* vxlan.conf
```
HOST_BRIDGE_INTERFACE="br0"
VXLAN_GW_INNER_IP="192.168.2.254/24"
VXLAN_GW_OUTER_IP="192.168.1.254/24"
VXLAN_NAT_SOURCE_IP_TO_INTERNET="192.168.2.0/24"
VXLAN_NAT_SOURCE_IP_TO_VXLAN="192.168.1.0/24"
```

Then you can run the set_vxlan_env.sh_.

```
# ./set_vxlan_env.sh
```

# systemd
You can set this script to run at boot time by adding systemd.
Below is an example of systemd config file.
The instruction assumes vxlan-builder has already installed at "/opt/vxlan-builder".

* /etc/systemd/system/custom-vxlan.service
```
[Unit]
Description = Custom VXLAN Setting Service
After = network.target

[Service]
ExecStart = /opt/vxlan-builder/set_vxlan_env.sh
Type = oneshot

[Install]
WantedBy = multi-user.target
```

Check whether custom-vxlan.service was already installed.

```
systemctl list-unit-files --type=service | grep vxlan
> custom-vxlan.service                   ...         ...
```

Enable custom-vxlan.service then start it.

```
systemctl enable custom-vxlan.service
systemctl start custom-vxlan.service
systemctl status custom-vxlan.service
```

