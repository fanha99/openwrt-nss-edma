#!/bin/bash
# Make sure the Windows host's Wi-Fi adapter is on the given profile and has
# an IPv4 address; print that address. Run from WSL, e.g. after the router
# under test has rebooted and the laptop has not rejoined its Wi-Fi.
#
#   win-wifi-up.sh <profile> [interface]
#
# The interface defaults to $WIFI_IF, then "Wi-Fi". Exit 1 if there is no
# address within $WIFI_WAIT seconds (default 120).
set -u
PROFILE=${1:?usage: win-wifi-up.sh <profile> [interface]}
IF=${2:-${WIFI_IF:-Wi-Fi}}
WAIT=${WIFI_WAIT:-120}

state() { netsh.exe wlan show interfaces 2>/dev/null | tr -d '\r' | awk -v ifn="$IF" '
	/^ +Name +:/ { sub(/^ +Name +: /, ""); cur = $0 }
	cur == ifn && /^ +State +:/ { sub(/^ +State +: /, ""); st = $0 }
	cur == ifn && /^ +SSID +:/ { sub(/^ +SSID +: /, ""); ss = $0 }
	END { print st "|" ss }'; }
ipv4() { powershell.exe -NoProfile -Command "(Get-NetIPAddress -InterfaceAlias '$IF' -AddressFamily IPv4 -ErrorAction SilentlyContinue).IPAddress" 2>/dev/null | tr -d '\r' | grep -v '^169\.254\.' | head -1; }

end=$(( $(date +%s) + WAIT ))
tried=0
while [ "$(date +%s)" -lt $end ]; do
	s=$(state)
	if [ "$s" = "connected|$PROFILE" ]; then
		ip=$(ipv4)
		[ -n "$ip" ] && { echo "$ip"; exit 0; }
	elif [ $(( tried % 6 )) = 0 ]; then
		# every ~30 s: the router may still be booting or doing its 60 s DFS CAC
		echo "wifi: $s -> connecting $PROFILE on $IF" >&2
		netsh.exe wlan connect name="$PROFILE" interface="$IF" >/dev/null 2>&1
	fi
	tried=$(( tried + 1 ))
	sleep 5
done
echo "wifi: no IPv4 on $IF ($PROFILE) after ${WAIT}s, state: $(state)" >&2
exit 1
