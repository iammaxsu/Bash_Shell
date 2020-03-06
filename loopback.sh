#!/bin/bash
INTERFACE_1=ens1f0
INTERFACE_2=ens1f1

ip netns add ns_${INTERFACE_1}
ip netns add ns_${INTERFACE_2}

ip link set ${INTERFACE_1} netns ns_${INTERFACE_1}
ip netns exec ns_${INTERFACE_1} ip addr add dev ${INTERFACE_1} 192.168.253.1/24
ip netns exec ns_${INTERFACE_1} ip link set dev ${INTERFACE_1} up

ip link set ${INTERFACE_2} netns ns_${INTERFACE_2}
ip netns exec ns_${INTERFACE_2} ip addr add dev ${INTERFACE_2} 192.168.253.2/24
ip netns exec ns_${INTERFACE_2} ip link set dev ${INTERFACE_2} up
