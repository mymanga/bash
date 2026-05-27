#!/bin/bash

set -e

# -----------------------------
# Parse arguments
# -----------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -net)
      SUBNET="$2"
      shift 2
      ;;
    *)
      echo "Usage: $0 -net <subnet>"
      exit 1
      ;;
  esac
done

[ -z "$SUBNET" ] && { echo "Error: -net is required"; exit 1; }

# -----------------------------
# Subnet handling
# -----------------------------
BASE_IP=$(echo "$SUBNET" | cut -d/ -f1)
BASE_NET=$(echo "$BASE_IP" | awk -F. '{print $1"."$2"."$3}')

echo "Using subnet: $SUBNET"
echo "Base network: $BASE_NET.0"

# -----------------------------
# Enable IPv4 forwarding
# -----------------------------
sed -i 's/^#\?net\.ipv4\.ip_forward=.*/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# -----------------------------
# UFW NAT configuration
# -----------------------------
BEFORE_RULES="/etc/ufw/before.rules"

[ ! -f "${BEFORE_RULES}.bak" ] && cp "$BEFORE_RULES" "${BEFORE_RULES}.bak"

# Remove previous block (idempotent)
sed -i '/# BEGIN MIKROTIK NAT/,/# END MIKROTIK NAT/d' "$BEFORE_RULES"

# Insert NAT rules
sed -i "/^\*filter/i \
# BEGIN MIKROTIK NAT\n\
*nat\n\
:PREROUTING ACCEPT [0:0]\n\
:POSTROUTING ACCEPT [0:0]\n\
\n\
# Masquerade Winbox return traffic\n\
-A POSTROUTING -p tcp -d ${SUBNET} --dport 8291 -j MASQUERADE\n\
\n\
# DNAT rules (.2 â†’ .10)\n\
-A PREROUTING -p tcp --dport 2002 -j DNAT --to-destination ${BASE_NET}.2:8291\n\
-A PREROUTING -p tcp --dport 2003 -j DNAT --to-destination ${BASE_NET}.3:8291\n\
-A PREROUTING -p tcp --dport 2004 -j DNAT --to-destination ${BASE_NET}.4:8291\n\
-A PREROUTING -p tcp --dport 2005 -j DNAT --to-destination ${BASE_NET}.5:8291\n\
-A PREROUTING -p tcp --dport 2006 -j DNAT --to-destination ${BASE_NET}.6:8291\n\
-A PREROUTING -p tcp --dport 2007 -j DNAT --to-destination ${BASE_NET}.7:8291\n\
-A PREROUTING -p tcp --dport 2008 -j DNAT --to-destination ${BASE_NET}.8:8291\n\
-A PREROUTING -p tcp --dport 2009 -j DNAT --to-destination ${BASE_NET}.9:8291\n\
-A PREROUTING -p tcp --dport 2010 -j DNAT --to-destination ${BASE_NET}.10:8291\n\
\n\
COMMIT\n\
# END MIKROTIK NAT\n\
" "$BEFORE_RULES"

# -----------------------------
# UFW forwarding rules (quiet + safe)
# -----------------------------
for i in {2..10}; do
  ufw route allow proto tcp to ${BASE_NET}.${i} port 8291 2>/dev/null || true
done

# -----------------------------
# Open external ports (quiet + safe)
# -----------------------------
for p in {2002..2010}; do
  ufw allow ${p}/tcp 2>/dev/null || true
done

# -----------------------------
# Reload firewall
# -----------------------------
ufw reload >/dev/null

echo "âœ” UFW NAT + forwarding configured successfully (.2 â†’ .10)"
