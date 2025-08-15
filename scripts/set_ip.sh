#!/bin/bash
# File that contains node and IP mapping information
ip_conf="nodes.json"
sudo iptables -F
echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward

# Get the current hostname of the machine
current_hostname=$(hostname -s)

# Function to extract the IP mapping from the configuration file
get_ip_mapping() {
    node=$1
    # Extract the IP mappings for the given node from ip.conf
    grep -E "^${node}:" $ip_conf | sed -E "s/${node}://g" | tr -d '{}" '
}

# Iterate over each node and their corresponding IP mappings in the ip.conf
while read -r line; do
    # Extract node and IP mappings
    node=$(echo "$line" | cut -d':' -f1)
    echo $node
    ip_mapping=$(echo "$line" | sed -E "s/${node}://g" | tr -d '{}" ')

    # Iterate over each IP pair for the current node
    echo "$ip_mapping" | sed 's/,/\n/g' | while read -r pair; do
        if [[ -z "$pair" || ! "$pair" =~ ":" ]]; then
            continue
        fi

        # Split the pair into first_ip and second_ip
        first_ip=$(echo $pair | cut -d':' -f1)
        second_ip=$(echo $pair | cut -d':' -f2)

        # If the hostname matches current_hostname
        if [[ "$node" == "$current_hostname" ]]; then
            echo "Running iptables for matching node: $first_ip -> $second_ip"

#            echo "sudo iptables -t nat -A PREROUTING -d $first_ip -j DNAT --to-destination $second_ip"
#            echo "sudo iptables -t nat -A POSTROUTING -s $second_ip -j MASQUERADE"
            sudo iptables -t nat -A PREROUTING -d $first_ip -j DNAT --to-destination $second_ip
            sudo iptables -t nat -A POSTROUTING -s $second_ip -j MASQUERADE
        else
            # If the hostname does not match current_hostname, reverse the iptables command
            echo "Running iptables for non-matching node: $second_ip -> $first_ip"
#            echo "sudo iptables -t nat -A PREROUTING -d $second_ip -j DNAT --to-destination $first_ip"
#            echo "sudo iptables -t nat -A POSTROUTING -s $first_ip -j MASQUERADE"
            sudo iptables -t nat -A PREROUTING -d $second_ip -j DNAT --to-destination  $first_ip
            sudo iptables -t nat -A OUTPUT -d $second_ip -j DNAT --to-destination $first_ip 
            sudo iptables -t nat -A POSTROUTING -s $first_ip -j MASQUERADE
        fi
    done

done < "$ip_conf"

sudo iptables -A INPUT -p udp -j ACCEPT
sudo iptables -A FORWARD -p tcp -j ACCEPT
sudo iptables -A OUTPUT -p tcp -j ACCEPT
sudo iptables -A OUTPUT -p udp -j ACCEPT
sudo iptables -A INPUT -p sctp -j ACCEPT
sudo iptables -A FORWARD -p sctp -j ACCEPT
sudo iptables -A OUTPUT -p sctp -j ACCEPT
