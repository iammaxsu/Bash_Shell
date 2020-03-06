#!/bin/bash

echo Transmit ICMP frames from ens1f0 to ens1f1:
ip netns exec ns_ens1f0 ping 192.168.253.2 -c 10
echo
echo
echo Transmit ICMP frames from ens1f1 to ens1f0:
ip netns exec ns_ens1f1 ping 192.168.253.1 -c 10
