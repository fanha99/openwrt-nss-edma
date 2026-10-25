#!/bin/sh
# Read-only memory sampler for the CR8806, run on the router through ssh.
# One line per sample:
# time avail free slab sunrecl anon file vmalloc unaccounted(KB) nss_skb fw_payloads payload_fail rx_desc_fail(r0,r1)
while :; do
	awk -v t="$(date +%T)" '
	FILENAME=="/proc/meminfo" { m[$1]=$2 }
	FILENAME=="/proc/vmstat"  { v[$1]=$2 }
	END {
		pg = 4
		acc = v["nr_free_pages"] + v["nr_slab_reclaimable"] + v["nr_slab_unreclaimable"] + \
		      v["nr_anon_pages"] + v["nr_file_pages"] + v["nr_page_table_pages"]
		acc = acc * pg + m["KernelStack:"] + m["VmallocUsed:"]
		printf "%s avail=%d free=%d slab=%d sunr=%d anon=%d file=%d vmalloc=%d unacc=%d ",
			t, m["MemAvailable:"], m["MemFree:"], m["Slab:"], m["SUnreclaim:"],
			m["AnonPages:"], m["Cached:"], m["VmallocUsed:"], m["MemTotal:"] - acc
	}' /proc/meminfo /proc/vmstat
	S=/sys/kernel/debug/qca-nss-drv/stats
	skb=$(awk '/drv_nss_skb_count/{print $3}' $S/drv)
	tot=$(awk '/n2h_n2h_tot_payloads/{print $3}' $S/n2h)
	pf=$(awk '/n2h_payload_alloc_fails/{print $3}' $S/n2h)
	rf=$(awk '/rx_desc_alloc_fail/{printf "%s,", $3}' $S/wifili)
	echo "skb=$skb fwpay=$tot payfail=$pf rxfail=$rf"
	sleep 2
done
