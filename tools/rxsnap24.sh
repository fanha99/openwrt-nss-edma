#!/bin/sh
# One line of 2.4 GHz (IPQ5018) receive-ring and memory counters (issue #53 checks).
S=/sys/kernel/debug/qca-nss-drv/stats
w=$(awk 'BEGIN{f=1} /ATTACH/{f=0} f && /wifili\[0\]_reo_reaped /{r=$3} f && /wifili\[0\]_rxdma_buf_replenished /{p=$3} f && /wifili\[0\]_rx_desc_in_use /{u=$3} f && /wifili\[0\]_rxdma_hw_desc_unavailable /{h=$3} f && /wifili\[0\]_rx_desc_alloc_fail /{a=$3} f && /wifili\[0\]_tx_desc_alloc_fail /{t=$3} f && /wifili_wbm_src_dma /{d=$3} f && /wifili_wbm_src_reo /{e=$3} END{printf "reo=%s repl=%s held=%s inuse=%s hwunav=%s allocf=%s txdf=%s", r, p, p-r-d-e, u, h, a, t}' $S/wifili)
dp=$(awk '/Overflow:/{o=$2} /Frame OOR/{f=$3} END{printf "ovf=%s oor=%s", o, f}' /sys/kernel/debug/ath11k/ahb-c000000.wifi/soc_dp_stats)
m=$(awk '/MemAvailable/{a=$2} /SUnreclaim/{s=$2} END{printf "avail=%d sunr=%d", a/1024, s/1024}' /proc/meminfo)
echo "$w $dp $m k4p=$(cut -d' ' -f1 /sys/kernel/slab/kmalloc-4k/partial) payf=$(awk '/n2h_payload_alloc_fails/{print $3}' $S/n2h) pfree=$(awk '/n2h_payload_free_count/{print $3}' $S/n2h) skb=$(awk '/drv_nss_skb_count/{print $3}' $S/drv)"
