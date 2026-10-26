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

Check: a fresh config with only the board, `kmod-ath11k` and `ATH11K_NSS_SUPPORT` selected
(`make defconfig`, after `rm -rf tmp/info && make prepare-tmpinfo`) resolves to
`ATH11K_MEM_PROFILE_256M=y`, `ATH11K_NSS_MEM_PROFILE_256M=y` and `NSS_MEM_PROFILE_LOW=y`
(the last one comes from the feed, kuncy7/nss-packages#7, here the fork's pinned feed).
The `.config` of the build in use resolves to the same values; the only difference is
the new AX58 v2 symbols. Without `ATH11K_NSS_SUPPORT` the NSS 256M profile is not offered
at all (its `depends on`); the CI `common.config` sets it.

Result: the ath11k side is complete for a build for this board alone. No board run for
this step; the rebuild with step 2 covers it.

Open question for the maintainer: `ATH11K_NSS_MEM_PROFILE_256M` is `default n` and no other
256M board sets it; it is measured only on this board. Keep it per-board, or set it
for the whole `256m` group?

## 2. `coherent_pool=512K`

Question: the other 256 MB boards run with `coherent_pool=512K`, this board had `2M`.
Does it still work, and what does it give back?

Change: `ipq5018-cr8806.dts`, `coherent_pool=2M` -> `512K` (`swiotlb=1` kept, as on the
AX3000T v2). ~~Patch 0828 (MPD loader allocates with `GFP_KERNEL`) is in the base.~~
Correction: that is wrong. 2M was needed while the MPD firmware loader (`mdt_loader`) took
its segment buffers from the atomic pool (patches 0812/0828). Both patches were removed with
the multiPD rework of ath11k (`10c267b1fb`), and the `mdt_loader.c` of the kernel built here
has no such allocation, so the base no longer has that user of the pool.

Baseline, same board running the 2M build, idle after a few days:

- `/sys/kernel/debug/dma_pools/pool_size_{dma,dma32,kernel}`: 2097152 each, 6 MiB in all.
- MemAvailable 10.7 MiB, MemTotal 168.75 MiB.
- No `qcom-q6-mpd` errors in dmesg.

Expected: three pools of 512 KiB, 4.5 MiB less held. What to check after the flash:
both radios up (~~the QCN6122 Q6 probe is what failed with `-12` without 0828~~ a `-12` at
the Q6 probe would mean something still draws on the atomic pool), no `dma alloc`
errors in dmesg, `pool_size_*` values, then four rounds.

Result: works. Flashed into the other slot with the config kept (build `0b9f0de696`).

Boot checks:

- `/proc/cmdline` has `coherent_pool=512K`; `pool_size_dma`, `_dma32` and `_kernel` are
  524288 each (1.5 MiB, was 6 MiB).
- No `dma alloc`, `-12`, `qcom-q6-mpd` or OOM line in dmesg; both radios up (5 GHz HE160
  on channel 36, and 2.4 GHz); `NSS 256 MiB: active` on both ath11k devices.
- Pools unchanged after four rounds: nothing drew on them.

Four rounds, same load as the reference (MiB = kB / 1024):

| | before | round 1 | round 2 | round 3 | round 4 |
|---|---|---|---|---|---|
| MemAvailable (MiB) | 19.2 | 15.4 | 18.4 | 15.9 | 14.5 |
| SUnreclaim (MiB) | 23.0 | 23.6 | 23.3 | 24.5 | 23.9 |
| Mbit/s up / down | | 759 / 925 | 781 / 930 | 796 / 936 | 797 / 928 |

NSS payloads held after the last round: 4771.

Reading it:

- MemAvailable after the rounds is 14.5-18.4 MiB, against 12-13 MiB in the reference
  build, and 19.2 MiB before the load against 18. ~~That is about what the 4.5 MiB of pools
  should give back.~~ Correction: that comparison does not show the 4.5 MiB. Before the
  load the difference is 1.2 MiB, after it 2 to 6 MiB; page cache moves MemAvailable by a
  few MiB between snapshots (it was not monotonic here), and the reference is another base
  measured days earlier. What is shown is the pool size itself: the boot log has
  `DMA: preallocated 512 KiB ... pool for atomic allocations` three times (1.5 MiB held,
  6 MiB with 2M), there is no CMA on this board so the pools come from the page allocator,
  and MemTotal is the same (172800 kB) because the pages are allocated, not removed. So
  4.5 MiB less is held by construction; a measured gain would need the same build booted
  with 2M and with 512K, idle, MemFree compared at the same uptime. Not done.
- SUnreclaim is the same as in the reference (23-24.5 MiB): the pools are not slab.
- Throughput is in the range of the reference (788-841 up, 933-940 down) at the low end
  for upload: round 1 is 759. One run per cell, not enough to call that a change.
- The base is not the same as the reference build (see the reference section), and the
  reference was measured days earlier, so the comparison is indicative.
- `wan` reports `rx-gro-list: off [requested on]`: that interface cannot be switched, and
  it carries no traffic in this test. Not looked into.

Answer to the question: 512K works on this board. ~~With 0828 the Q6 probe does not need
the atomic pool.~~ The Q6 probe does not need the atomic pool in this base (no MPD loader
in the kernel); the measurement does not separate that from any other cause. It holds
4.5 MiB less by pool size; the MemAvailable numbers above do not confirm that on their own.

## 3. `sysupgrade` from each slot

Question: `platform.sh` for this board (write the running slot, set the boot flags to it)
had never run. Does a plain `sysupgrade` write the slot it runs from and does U-Boot boot
that slot next?

Change: none. The `sysupgrade.bin` of the build from step 2 is copied to `/tmp` and run with
`sysupgrade -v` (config kept, the default), once from each slot. Same image both times, so
a good result shows the flow and the flags, not that the content changed.

Before each run: `ubi.mtd`, the boot flags, and a checksum over `/etc/config/*`. After
the reboot: the same, plus pools, radios, NSS profile lines and dmesg.

Flags before, slot 1 running: `flag_last_success=1 flag_boot_rootfs=1 flag_ota_reboot=0
flag_try_sys1_failed=0 flag_try_sys2_failed=0 boot_wait=on uart_en=1`.

| run | from | after reboot | flags after | config checksum |
|---|---|---|---|---|
| 1 | slot 1 (`ubi.mtd=rootfs_1`) | slot 1 | `last_success=1 boot_rootfs=1 ota_reboot=0` | unchanged |
| 2 | slot 0 (`ubi.mtd=rootfs`) | slot 0 | `last_success=0 boot_rootfs=0 ota_reboot=0` | unchanged |

Between the runs the board was switched to slot 0 by hand (`fw_setenv flag_last_success 0`,
`flag_boot_rootfs 0`, `reboot`).

After run 2, slot 0: `coherent_pool=512K`, the three pools 524288, no DMA / Q6 / OOM line in
dmesg, `NSS 256 MiB: active` on both radios, all three SSIDs up (5 GHz HE160 channel 36),
`rx-gro-list: off` on eth0, eth1, lan1, lan3, eth0 and eth1 up. MemAvailable 22.7 MiB idle.

Result: the flow ran from both slots and the board came back on the slot it ran from. The
log of each run ends at "Commencing upgrade" (the ssh session is closed by sysupgrade), and
the image was identical to what was already there, so the write itself is not shown
independently; what is shown is that sysupgrade ran, the board rebooted and came back
with the right slot, flags and config. The flags the script sets
(`flag_last_success`, `flag_boot_rootfs` = the running slot, the failure flags cleared)
are the ones U-Boot reads, and the board came back on the slot that was written, each time
without a console. Not covered: an image of a different build (config migration), a
sysupgrade without keeping settings (`-n`), a failed write, and the stock firmware in the
other slot (both slots here carry OpenWrt, so "leave the other slot alone" was not
tested with stock in it).

## 4. `05_cr8806_eth0_up`: the board, or the link?

Question: does the Redmi AX5400, which has the same GE PHY to PHY4 link, need the preinit
hook too?

Not tested: there is no AX5400 here. What the tree shows:

- Same topology in both DTS files: GMAC0 reaches the QCA8337 through the IPQ5018 GE PHY
  and switch PHY4 (switch port 5, `phy-mode = "gmii"`, `ethernet = <&gmac0>`), both with
  `qcom,dac-preset-short-cable` on `&ge_phy`.
- Different use of eth0 in `02_network`: on the AX5400 `wan` has conduit `eth0`, so
  netifd opens eth0 as part of bringing `wan` up. On the CR8806 `wan` is on `eth1`
  (so that it is NSS-offloaded) and nothing opens eth0, which is what the hook does.
- The CR8806 failure it works around: PHY4 starts autoneg at probe (~2 s), and gives up
  gigabit after ~13 s if the GE PHY is not yet advertising 1000BASE-T, because nothing opened
  eth0 and attached that PHY by then.

So the likely cause is the link, and it shows only where nothing opens eth0 early. The AX5400
as shipped opens it through `wan`. A board that moves its WAN off eth0, or a user who does
(the README describes an AX5400 on the single-link layout with WAN on eth1), could hit the
same thing. This is reasoning from the DTS and `02_network`, not a measurement.

How to check on an AX5400 (not done): put `wan` on `eth1`, reboot without the hook, look at
the PHY4 link in `ethtool eth0` and the QCA8337 port-4 status after 20 s; then add
`ip link set eth0 up` at preinit and compare.

Result: unanswered by test. Left as a hook for this board only, as the maintainer allowed;
asked whoever has an AX5400 to run the check above.

## 5. Review outcome (PR 45)

The maintainer accepted steps 1-4 and asked for these changes, now in the PR branch:

- `coherent_pool=512K` added to the PR as its own commit, with the result of step 2 in the
  commit message. The test commit on this branch is the same DTS change.
- The comment of `05_cr8806_eth0_up` now says the hook is about the link, is needed only where
  nothing else opens eth0 early, and should not be copied to a board without checking PHY4 first.
- The ath11k NSS 256M profile commit (`ATH11K_NSS_MEM_PROFILE_256M` default) was dropped from
  the PR: the releases build one `kmod-ath11k` for the whole 256m group, so a per-board default
  would switch the option on for every 256 MB board in the release image, none of which has run
  it. It stays in my own builds (set `CONFIG_ATH11K_NSS_MEM_PROFILE_256M=y`). If other 256 MB
  boards are tested with it, it can go in for the group on its own.
