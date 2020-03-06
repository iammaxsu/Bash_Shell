#!/bin/bash

# Send/receive 10 ICMP packages between two network ports
echo Transmit 10 ICMP frames between ens1f0 (192.168.253.1) and ens1f1 (192.168.253.2):
echo 
ip netns exec ns_ens1f0 ping 192.168.253.2 -c 10
