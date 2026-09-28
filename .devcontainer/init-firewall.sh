#!/bin/bash
# Outbound network for the Claude Code container, in one of two modes chosen on the host:
#
#   open   (default)  web traffic (HTTP/HTTPS) goes anywhere; every other port is refused.
#   strict            only DNS, the container itself, and the hosts listed below.
#
# The mode comes from FIREWALL_MODE, set by scripts/claude-container.sh. That script is read-only
# inside, so Claude cannot pick the mode for itself. If this script fails, start.sh stops and Claude
# never starts — the container never runs without it.
#
# Open is the default because the container exists to keep a mistaken command inside this project,
# and the network has no part in that. What open gives up is a barrier against the project being
# sent out. Strict keeps that barrier, at the price of Claude not being able to read most web pages.
set -euo pipefail
IFS=$'\n\t'

mode="${FIREWALL_MODE:-open}"
case "$mode" in open|strict) ;; *) echo "Unknown FIREWALL_MODE: $mode"; exit 1 ;; esac

# Used by strict only. Add what the project restores from and reads.
ALLOWED_HOSTS=(
  api.anthropic.com
  claude.ai
  platform.claude.com
  registry.npmjs.org
  code.claude.com
  docs.claude.com
)

iptables -F
iptables -X

# DNS to the container's own resolvers only, and the container's loopback, before anything is
# closed. DNS open to any server would be a channel out of its own, in either mode.
resolvers="$(awk '$1 == "nameserver" && $2 ~ /^[0-9.]+$/ { print $2 }' /etc/resolv.conf)"
[ -n "$resolvers" ] || { echo "No IPv4 resolver in /etc/resolv.conf"; exit 1; }
while read -r ns; do
  for proto in udp tcp; do
    iptables -A OUTPUT -p "$proto" -d "$ns" --dport 53 -j ACCEPT
    iptables -A INPUT -p "$proto" -s "$ns" --sport 53 -j ACCEPT
  done
done <<< "$resolvers"
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# One ACCEPT rule per address rather than an ipset: a rootless container cannot load kernel modules,
# and the ipset hash module is not loaded on most hosts by default.
iptables -N ALLOWED
if [ "$mode" = strict ]; then
  for host in "${ALLOWED_HOSTS[@]}"; do
    addresses="$(dig +short A "$host" | grep -E '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || true)"
    if [ -z "$addresses" ]; then
      # Left out rather than fatal: the host just stays unreachable, which is the safe outcome.
      echo "Could not resolve $host — it stays blocked"
      continue
    fi
    while read -r ip; do iptables -A ALLOWED -d "$ip" -j ACCEPT; done <<< "$addresses"
  done
else
  # The web means the internet, not the home network: the router's admin page, printers and
  # network drives sit on private addresses, and port 80 is what most of them answer on.
  for range in 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16 100.64.0.0/10; do
    iptables -A ALLOWED -d "$range" -j REJECT --reject-with icmp-admin-prohibited
  done
  iptables -A ALLOWED -p tcp -m multiport --dports 80,443 -j ACCEPT
fi

iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -j ALLOWED
# Rejected rather than dropped, so a blocked request fails at once instead of hanging.
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# No IPv6 in either mode: the rules above are IPv4 only, so IPv6 would be a way round them. The
# launcher switches IPv6 off in the container (--sysctl), which makes an IPv6 connection fail at
# once. Dropping it here as well is the second lock; on its own, a drop makes requests hang.
if ip6tables -L >/dev/null 2>&1; then
  ip6tables -F
  ip6tables -P INPUT DROP
  ip6tables -P FORWARD DROP
  ip6tables -P OUTPUT DROP
  ip6tables -A INPUT -i lo -j ACCEPT
  ip6tables -A OUTPUT -o lo -j ACCEPT
fi

# Prove the mode before Claude is allowed to start.
# Two tries and a longer timeout, and any one of several hosts will do: a slow or broken site
# should not be able to stop the container from starting. All of them failing means something real.
reachable() {
  for attempt in 1 2; do
    for url in "$@"; do
      curl -s --connect-timeout 8 --max-time 15 -o /dev/null "$url" && return 0
    done
  done
  return 1
}
fail() { echo "Firewall check failed ($mode): $1"; exit 1; }

if [ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)" != 1 ]; then
  fail "IPv6 is not switched off"
fi
reachable https://api.anthropic.com || fail "api.anthropic.com is not reachable"
! dig +time=2 +tries=1 @1.1.1.1 example.com >/dev/null 2>&1 || fail "DNS to 1.1.1.1 is reachable"
if [ "$mode" = strict ]; then
  ! reachable https://example.com || fail "example.com is reachable"
  echo "Firewall up (strict): only the allowed hosts are reachable."
else
  reachable https://example.com https://www.cloudflare.com https://www.wikipedia.org \
    || fail "no site on the open web is reachable"
  ! timeout 5 bash -c 'exec 3<>/dev/tcp/github.com/22' 2>/dev/null || fail "port 22 is reachable"
  gateway="$(ip -4 route show default | awk '{ print $3; exit }')"
  if [ -n "$gateway" ]; then
    ! reachable "http://$gateway" || fail "the gateway $gateway is reachable"
  fi
  echo "Firewall up (open): web traffic allowed; home network, other ports and IPv6 refused."
fi
