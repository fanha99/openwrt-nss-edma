# CR8806: follow-up tests for the review of PR #45

Test log for the questions raised on the Xiaomi CR8806 board PR
(kuncy7/openwrt-nss-edma#45). One section per step: what was changed, why, how it was
measured, the result. A step is committed (code, then its result) before the next one starts.
The notes are written so the steps can be repeated on another board.

This branch is the PR rebased on the current `c3po-tag-8021q`, plus the commits the
build in use carries (fraglist GRO off, pinned feeds), plus this directory. The earlier
RAM investigation is on branch `cr8806-memtest` (same fork): its `NOTES.md` has the method
and the numbers this log compares against.

## Questions to answer

1. 256M profile: the ath11k side was missing (`ath.mk`, `256m.config`, README row).
2. `coherent_pool`: other 256 MB boards use 512K, this one has 2M. Does 512K work?
3. `platform.sh`: the dual-slot sysupgrade logic has never run. Run it from each slot.
4. `05_cr8806_eth0_up`: board-specific, or tied to the GE PHY - PHY4 link?

## Test setup

- Board: Xiaomi CR8806 (IPQ5018 + QCN6122, 256 MiB, NSS offload for Ethernet and Wi-Fi),
  5 GHz HE160, client next to the AP.
- Load: `iperf3 -P 4 -t 60`, one run up and one down (`-R`), 60 s pause; one round = both
  runs. The client binds to its Wi-Fi address so traffic cannot take another path.
- Memory: `tools/memsample.sh` on the router, `/proc/meminfo` before and after each round;
  `tools/run-rounds.sh` drives four rounds from a Linux shell; `tools/win-wifi-up.sh`
  rejoins a Windows client's Wi-Fi after the router reboots.
- Build: `cr8806-main`-style (no `files/`, no debug options, feeds pinned in
  `feeds.conf.default`), the same `.config` for every step; only the change under test
  differs.

## Reference: build before this log

Same board, same load, four rounds (from `cr8806-memtest`, section 7): the build that
carries the nss-packages patch 0149 and has fraglist GRO off by default.

| | before | round 1 | round 2 | round 3 | round 4 |
|---|---|---|---|---|---|
| MemAvailable (MiB) | 18 | 12 | 13 | 12 | 12 |
| SUnreclaim (MiB) | 21 | 23 | 23 | 23 | 23 |

Throughput 788-841 Mbit/s up, 933-940 down. That build was made on the previous base
(`b0aa337`); the base moved by four commits (two userspace tools, the AX58 v2 board and
one `ath.mk` line) before this log.

## 1. Rebase on the current `c3po-tag-8021q`, ath11k profile for the board

Changes (in this order on the branch):

1. The board commit, rebased. Its message listed the slot in the install steps wrongly
   (`mtd18` / `flag_last_success 0` is slot 0); fixed.
2. `mac80211: ath11k: default the 256M profile on the Xiaomi CR8806`: the board joins the
   `ATH11K_MEM_PROFILE_256M` default in `ath.mk`, the `256m` CI group and the README row.
3. `mac80211: ath11k: default the 256M NSS profile on the Xiaomi CR8806`: the NSS-side
   ath11k profile, for this board only (see question to the maintainer below).
4. `cr8806: turn fraglist GRO off by default` and `feeds: pin the feeds`: carried from
   the build in use; not part of the PR.

Result: pending (the Kconfig check and a build come with step 2).

Open question for the maintainer: `ATH11K_NSS_MEM_PROFILE_256M` is `default n` and no other
256M board sets it; it is measured only on this board. Keep it per-board, or set it
for the whole `256m` group?
