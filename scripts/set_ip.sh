#!/bin/bash
# Programs the DNAT/MASQUERADE rules that map each node's exposed 10.1.N.x
# addresses onto the inner VM's 10.2.N.x addresses (and the reverse for peers).
#
# This runs on EVERY boot (via chronos-net.service), not just first provision,
# because iptables rules and the address aliases they reference are runtime-only
# state that a reboot discards. It must therefore be safe to run repeatedly:
#
#   - NAT rules go into dedicated CHRONOS_* chains that are flushed on entry, so
#     a re-run replaces them instead of stacking a second full set (~1265 rules
#     at machineNum=1, ~2788 at machineNum=3). The jump rules into those chains
#     are added only if absent.
#   - The config file is addressed absolutely. It used to be the bare relative
#     path "nodes.json", so running this from any other directory silently
#     produced no rules at all.

# File that contains node and IP mapping information
ip_conf="${CHRONOS_NODES_JSON:-/local/chronos/etc/nodes.json}"

if [ ! -s "$ip_conf" ]; then
    echo "FATAL: node/IP map not found or empty: $ip_conf" >&2
    echo "Generate it with generate_config.sh <node-count> $ip_conf" >&2
    exit 1
fi

echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward

# Get the current hostname of the machine
current_hostname=$(hostname -s)

# Dedicated chains make the NAT half of this script idempotent. Create them if
# missing, flush them if they already exist, then make sure each is jumped to
# from its builtin chain exactly once.
for chain in CHRONOS_PRE CHRONOS_OUT CHRONOS_POST; do
    sudo iptables -t nat -N "$chain" 2>/dev/null || sudo iptables -t nat -F "$chain"
done
sudo iptables -t nat -C PREROUTING  -j CHRONOS_PRE  2>/dev/null || sudo iptables -t nat -A PREROUTING  -j CHRONOS_PRE
sudo iptables -t nat -C OUTPUT      -j CHRONOS_OUT  2>/dev/null || sudo iptables -t nat -A OUTPUT      -j CHRONOS_OUT
sudo iptables -t nat -C POSTROUTING -j CHRONOS_POST 2>/dev/null || sudo iptables -t nat -A POSTROUTING -j CHRONOS_POST

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
            sudo iptables -t nat -A CHRONOS_PRE  -d $first_ip -j DNAT --to-destination $second_ip
            sudo iptables -t nat -A CHRONOS_POST -s $second_ip -j MASQUERADE
        else
            # If the hostname does not match current_hostname, reverse the iptables command
            sudo iptables -t nat -A CHRONOS_PRE  -d $second_ip -j DNAT --to-destination $first_ip
            sudo iptables -t nat -A CHRONOS_OUT  -d $second_ip -j DNAT --to-destination $first_ip
            sudo iptables -t nat -A CHRONOS_POST -s $first_ip -j MASQUERADE
        fi
    done

done < "$ip_conf"

# Filter-table policy. Left as a flush-then-append so it stays idempotent by
# construction, and so the packet-filtering behaviour is bit-for-bit what it was
# before this script became a boot-time unit.
#
# NOTE: the flush also clears Docker's filter rules while leaving its FORWARD
# policy at DROP, and the ACCEPT rules below cover tcp/sctp forwarding but not
# udp. That predates this change and is deliberately left alone here rather than
# altered blind; see restart-nodeN.md.
sudo iptables -F

sudo iptables -A INPUT -p udp -j ACCEPT
sudo iptables -A FORWARD -p tcp -j ACCEPT
sudo iptables -A OUTPUT -p tcp -j ACCEPT
sudo iptables -A OUTPUT -p udp -j ACCEPT
sudo iptables -A INPUT -p sctp -j ACCEPT
sudo iptables -A FORWARD -p sctp -j ACCEPT
sudo iptables -A OUTPUT -p sctp -j ACCEPT
