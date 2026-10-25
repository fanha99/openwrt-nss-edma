#!/bin/bash
# Four iperf3 rounds through the router's Wi-Fi (60 s up, 60 s down, 60 s
# idle), with /proc/meminfo and page_owner show_stacks taken before the first
# round and after each idle gap. The client is the Windows host running WSL,
# bound to its Wi-Fi address; the server is a wired machine on the LAN.
#
#   ROUTER=<ip> SERVER=<iperf3 -s host> WIFI_PROFILE=<profile> \
#   IPERF=/mnt/c/.../iperf3.exe OUT=<dir> run-rounds.sh
#
# Without page_owner (normal builds) the show_stacks part of each snapshot is
# just an error line; the meminfo part is still there.
set -u
: "${ROUTER:?}" "${SERVER:?}" "${WIFI_PROFILE:?}" "${IPERF:?}" "${OUT:?}"
TOOLS=$(dirname "$(readlink -f "$0")")
mkdir -p "$OUT"
snap() {
	ssh -o BatchMode=yes root@$ROUTER 'cat /proc/meminfo; echo ===; cat /sys/kernel/debug/page_owner_stacks/show_stacks' > "$OUT/stacks-$1.txt" 2>&1
	echo "$(date +%T) snap $1 $(grep MemAvailable "$OUT/stacks-$1.txt")" >> "$OUT/rounds.log"
}
cd "$(dirname "$IPERF")" || exit 1
: > "$OUT/rounds.log"
snap pre
for r in 1 2 3 4; do
	for d in up down; do
		o=""; [ $d = down ] && o="-R"
		WIFI_IP=$("$TOOLS/win-wifi-up.sh" "$WIFI_PROFILE") || { echo "$(date +%T) abort: Wi-Fi not up" >> "$OUT/rounds.log"; exit 1; }
		res=$(timeout 90 "./$(basename "$IPERF")" -c "$SERVER" -B "$WIFI_IP" -t 60 -P 4 $o 2>&1 | grep -E "SUM.*receiver" | tr -s ' ')
		[ -n "$res" ] || { echo "$(date +%T) abort: round=$r dir=$d gave no result" >> "$OUT/rounds.log"; exit 1; }
		echo "$(date +%T) round=$r dir=$d $res" >> "$OUT/rounds.log"
	done
	sleep 60
	snap r$r
done
echo "$(date +%T) done" >> "$OUT/rounds.log"
