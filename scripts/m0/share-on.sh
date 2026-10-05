#!/bin/zsh
# Usage: sudo zsh share-on.sh   (loads NAT for 192.168.42.0/24 into anchor com.apple/questlink)
set -e
EG=$(echo 'show State:/Network/Global/IPv4' | scutil | awk '/PrimaryInterface/{print $3}')
: ${EG:?no primary interface}
echo "nat on $EG inet from 192.168.42.0/24 to ! 192.168.42.0/24 -> ($EG)" | pfctl -a com.apple/questlink -f -
pfctl -a com.apple/questlink -s nat
TOKEN=$(pfctl -E 2>&1 | awk -F': ' '/Token/{print $2}')
echo "$TOKEN" > ~/projects/personal/ncm/docs/evidence/S1-20261005/pf-token
echo "pf enabled, token=$TOKEN, forwarding=$(sysctl -n net.inet.ip.forwarding)"
