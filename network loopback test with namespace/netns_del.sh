#! /bin/bash 
# Find the net namespace and delete it!
# v0.0.1
# 4.3.2024, ADLINK, Msu



netns_del=()


# Find the amount of net namespace & put into an array:
for ((i=1; i<=$(ls /var/run/netns | awk '{print $1}' | wc -l); i++)); do
	netns_del+=("$(ls /var/run/netns | awk '{print $1}' | sed -n ${i}p)")
done

# Report the amount of array element & the content of array: (can be removed!)
echo "${#netns_del[@]}"
echo "${netns_del[@]}"

# Delete net namespace: 
for ((i=0; i<=${#netns_del[@]}; i++)); do
	sudo ip netns del ${netns_del[i]}
done

