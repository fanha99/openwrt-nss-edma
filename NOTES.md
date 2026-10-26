# CR8806: ghi chép thử nghiệm RAM khi chạy NSS Wi-Fi offload

Branch thử nghiệm. Mỗi thử nghiệm một mục: sửa gì, vì sao, đo thế nào, kết quả. Khi ổn
định, phần code được gộp lại thành commit trên branch chính; thư mục `cr8806-memtest/` và
các commit `DEBUG:` không đưa vào.

Từ mục 10, branch được dựng lại trên `cr8806-pr45-followup` (cây của bản đang chạy: board,
profile 256M, fraglist GRO tắt, feed pin có 0149, `coherent_pool=512K`, và ghi chép
`cr8806-pr45-tests/`). Bản cũ, nằm trên `cr8806-pr` trước PR 45, còn ở
`cr8806-memtest-v1`. Thứ tự commit:

1. `cr8806-pr45-followup`.
2. `DEBUG: ... enable page_owner` (mục 3). Chỉ để đo, không gộp.
3. Các commit `cr8806-memtest:`: ghi chép này và `tools/` (mục 1-9).
4. Thử nghiệm mục 10: hai patch ath11k (`999-997`, `999-998`) và script BPF JIT.
5. Ghi chép mục 10.

Phần qca-nss-drv nằm trong nss-packages, branch `cr8806-memtest` của fork
`fanha99/nss-packages`: profile `NSS_MEM_PROFILE_LOW` mặc định cho CR8806 (đã gửi PR
kuncy7/nss-packages#7) và patch 0149 (mục 4).

## Phần cứng và cách đo

- Xiaomi CR8806: IPQ5018 + QCN6122, 256 MiB RAM (kernel thấy 169 MiB, 90 MiB bị giữ lúc
  boot cho NSS, Q6, TZ...). NSS offload bật cho cả Ethernet và Wi-Fi.
- Bài test: client là laptop Windows nối Wi-Fi 5 GHz HE160 (kênh 36, đứng gần AP), server
  là máy cắm dây trong LAN; `iperf3 -P 4 -t 60`, một chiều lên, một chiều xuống
  (`-R`), nghỉ 60 s. Một "lượt" = cả ba phần. Client bind vào IP Wi-Fi (`-B`) để chắc
  chắn đi qua Wi-Fi (đã kiểm tra bằng bộ đếm byte của station và của cổng LAN).
- `tools/memsample.sh`: chạy trên router (qua ssh), mỗi 2 s in MemAvailable, Slab,
  SUnreclaim, page cache, phần "không tên" (MemTotal trừ mọi counter đã biết), số payload
  NSS đang giữ (`drv_nss_skb_count`, `n2h_n2h_tot_payloads`) và `rx_desc_alloc_fail`.
- `tools/run-rounds.sh`: chạy 4 lượt từ WSL, chụp `/proc/meminfo` + page_owner trước và
  sau mỗi lượt. `tools/win-wifi-up.sh` nối lại Wi-Fi của laptop (sau mỗi lần router reboot
  laptop không tự vào lại).
- `tools/page-owner-top.py`, `tools/page-owner-diff.py`: tổng hợp và so sánh
  `/sys/kernel/debug/page_owner_stacks/show_stacks` theo call stack.

Đọc số: mỗi payload NSS là một object 4 KiB, nên "slab thuần" = SUnreclaim − payload × 4 KiB.

## 1. Đối chứng: b0aa337 + `ATH11K_MEM_PROFILE_256M` (chọn tay)

Profile ath11k 256M, `NSS_MEM_PROFILE_LOW`, chưa có profile NSS 256M.

| | trước | lượt Wi-Fi→LAN | lượt LAN→Wi-Fi | sau |
|---|---|---|---|---|
| MemAvailable (MiB) | 6-10 | 5-9 | **1-6** | 1-4 |
| SUnreclaim (MiB) | 45 | 47 | 54-60 | 52-54 |
| payload NSS giữ | ~4500 | 5100-5500 | **7200-8700** | ~4900 |
| rx_desc_alloc_fail | 899 | +590 | | |

- LAN→Wi-Fi: phía dây đẩy nhanh hơn Wi-Fi phát, gói xếp hàng trong hàng đợi TX Wi-Fi
  của NSS (8192 descriptor mỗi radio), mỗi gói giữ một payload 4 KiB của host.
- Sau mỗi lượt slab thuần tăng ~7 MiB và không về; đo lặp lại thì RAM "tụt dần".

## 2. `ATH11K_NSS_MEM_PROFILE_256M=y`

Sửa: bật profile có sẵn trong `patches/nss-extra/ath11k/999-991..995` (TX descriptor và
giới hạn TX theo radio 8192 → 4096, TX completion 4096, bỏ mảng TX phía host, cache
page-frag RX riêng, CE5 256). Vì sao: chặn đúng hàng đợi TX Wi-Fi ở mục 1.

Kết quả (6 lượt, upload 667-798, download 892-934 Mbit/s):

| | đối chứng | profile NSS 256M |
|---|---|---|
| payload giữ khi LAN→Wi-Fi | 7200-8700 | 5100-6700 |
| MemAvailable thấp nhất khi chạy | 0.9 MiB | 6.4 MiB |
| slab thuần qua các lượt | +7.4 MiB/lượt | đi ngang 26-29 MiB |
| MemAvailable khi nghỉ sau test | 1-4 MiB | ~11.5-12 MiB |

Phụ: radio 5 GHz báo `tx_desc_alloc_fail` ~1.25 triệu (hàng đợi đầy thì firmware từ chối
thay vì giữ RAM; TCP chỉ retransmit 45 lần/60 s), `rx_desc_alloc_fail` tăng ~10-30 nghìn
mỗi lượt upload (pool descriptor RX của NSS, 3 × 512; host không thiếu payload).

Đưa vào `cr8806-pr`: CR8806 vào default của `ATH11K_MEM_PROFILE_256M` (trước đó không có,
build mới sẽ ra profile 1G) và `ATH11K_NSS_MEM_PROFILE_256M`. `NSS_MEM_PROFILE_LOW` nằm
trong feed nss-packages: trước phải chọn tay, giờ có commit riêng (kuncy7/nss-packages#7).

## 3. page_owner: phần nào giữ RAM sau tải

Commit `DEBUG:` trên branch này: `CONFIG_PAGE_OWNER` + `page_owner=on` (tốn ~4.5 MiB
`page_ext`). So sánh show_stacks trước test và sau 4 lượt:

- Tăng duy nhất đáng kể: **+8.7 MiB** ở `__alloc_skb <- ... <- nss_core_handle_napi_non_queue`,
  tức payload host cấp cho pool bộ đệm trống của firmware NSS (patch 0105 của qca-nss-drv,
  `alloc_skb` → `kmalloc-4096`).
- Trong đó: firmware giữ nhiều payload hơn sau tải (~3500 → 4861, ~+5 MiB, giảm dần khi
  nghỉ) và **phân mảnh slab**: `kmalloc-4k` có 396 slab order-3 dở dang chứa 2168 object,
  ~1000 ô trống ≈ 4 MiB không ai dùng được.
- Giảm: page cache (~−20 MiB, bị đẩy ra), buffer CE của ath11k (~−2 MiB).
- Mốc boot còn đáng xem: buffer CE ath11k ~13 MiB, link descriptor ath11k 8 MiB (DMA),
  2 page pool stmmac × 2 MiB (eth0, eth1, RX 512), atomic pool `coherent_pool=2M` 6 MiB,
  zstd stream 4 MiB (chưa rõ ai dùng).

## 4. qca-nss-drv: payload pool bộ đệm trống bằng nguyên một trang

Sửa (nss-packages, patch `0149-nss_core-back-fw-empty-buffer-payloads-with-whole-pages`):
`alloc_page()` + `build_skb()` thay cho `alloc_skb()`; payload 2368 byte vẫn vừa một trang,
chi phí mỗi payload không đổi, trang trả lại ngay khi skb được giải phóng. Payload không
vừa một trang (MRU jumbo) vẫn dùng kmalloc. Vì sao: bỏ phần ~4 MiB kẹt trong slab dở dang
ở mục 3, và bỏ việc phải cấp khối order-3 trong ngữ cảnh atomic.

Kết quả (4 lượt, cùng bản debug page_owner, cùng profile NSS 256M; upload 718-773,
download 931-940 Mbit/s, không lỗi NSS trong dmesg):

| | không 0149 (trước → sau 4 lượt) | có 0149 (trước → sau 4 lượt) |
|---|---|---|
| page_owner: payload pool bộ đệm trống (MiB) | 16.1 → 25.4 | 14.3 → 15.6 |
| page_owner: `pskb_expand_head <- skb_segment_list` (MiB) | 0 → 0.4 | 0.1 → 7.6 |
| SUnreclaim (MiB) | 36 → 46 | 22 → 31 |
| MemFree + Cached (MiB) | 49 → 33 | 49 → 31 |
| MemAvailable (MiB) | 16 → 9 | 14 → 6-7 |

- Payload pool bộ đệm trống không còn phình: patch làm đúng việc của nó.
- **Nhưng RAM dùng được không khá hơn.** SUnreclaim thấp hơn ~14 MiB chỉ là đổi chỗ
  ghi sổ: payload giờ là trang rời, không còn tính vào slab. MemFree + Cached gần như
  bằng nhau ở cả hai bản.
- Phần phân mảnh `kmalloc-4k` chuyển sang chỗ khác: sau test vẫn còn ~267 slab order-3
  dở dang, chứa ~930 object. page_owner gán các slab này cho ai tạo ra chúng trước, ở đây
  là các segment GSO fraglist của đường chậm (`rx-gro-list` bật trên eth0, eth1,
  br-lan; ~106 nghìn gói `ipv4_tcp_no_icme` đi qua Linux trước khi ECM tăng tốc luồng).
  Object sống lâu (buffer RX CE của ath11k...) nằm lại trong đó nên slab không trả về
  được. Sau 5 phút nghỉ vẫn giữ 7.6 MiB. Tăng 4.8 → 6.3 → 7.3 → 7.6, chậm dần, giống
  phân mảnh hơn là leak.
- Kết luận lúc đó: chưa đưa 0149 vào branch chính. Muốn có lợi thật phải giảm việc trộn
  object sống ngắn và sống lâu trong `kmalloc-4k`, không chỉ riêng payload NSS (mục 5-6).

## 5. Tắt fraglist GRO (`rx-gro-list`) trên bản 0149

Sửa (lúc chạy, không lưu): `ethtool -K <if> rx-gro-list off` cho eth0, eth1, các cổng
LAN, br-lan, các VLAN của bridge và 3 interface Wi-Fi. Fraglist GRO được bật mặc định cho
mọi interface bởi `target/linux/generic/hack-6.18/600-net-enable-fraglist-GRO-by-default.patch`.
Vì sao: ở mục 4, các slab `kmalloc-4k` dở dang được tạo bởi `skb_segment_list`, tức các
gói đường chậm bị gộp thành fraglist rồi cắt lại lúc gửi. Khi NSS đã nắm data plane thì
fraglist GRO chỉ còn tác dụng với vài nghìn gói đầu của mỗi luồng.

Đo lại sau reboot (cùng điểm xuất phát ~9 phút uptime như mục 4), 4 lượt, upload
682-825, download 888-939 Mbit/s:

| sau 4 lượt | không 0149 | 0149 | 0149 + tắt fraglist GRO |
|---|---|---|---|
| SUnreclaim trước → sau (MiB) | 36 → 46 | 22 → 31 | **21 → 24** |
| MemFree + Cached sau (MiB) | 33 | 31 | **37** |
| MemAvailable sau (MiB) | 9 | 6 | **13** |
| page_owner `skb_segment_list` (MiB) | 0.4 | 7.6 | 0 |
| `kmalloc-4k` slab dở dang | 396 | 267 | **42** |

- Hết phân mảnh slab: SUnreclaim gần như đứng yên qua 4 lượt. Payload pool bộ đệm
  trống dao động 14-19 MiB và trả bớt khi nghỉ.
- Throughput không giảm (upload còn nhỉnh hơn), dmesg không có lỗi NSS.
- MemAvailable khi đang chạy vẫn xuống 7-11 MiB. Đó là payload firmware NSS giữ trong
  hàng đợi lúc có tải, nghỉ thì lấy lại.
- Mới đo một lần. Cần chạy lại để biết độ dao động, và thử tắt fraglist GRO trên bản
  không có 0149 để biết mỗi thay đổi đóng góp bao nhiêu (mục 6).

## 6. Tắt fraglist GRO trên bản không 0149

Cùng cách làm như mục 5 (reboot, ~9 phút uptime, tắt `rx-gro-list` mọi interface), trên
bản debug không có 0149. Upload 531 (lượt 1, Wi-Fi dao động) rồi 747-753, download
893-931 Mbit/s.

So sánh cả bốn, cùng bản debug page_owner, cùng profile NSS 256M, mỗi ô một lần đo:

| | không 0149 | không 0149 + tắt GRO | 0149 | **0149 + tắt GRO** |
|---|---|---|---|---|
| MemFree + Cached trước → sau (MiB) | 49 → 33 | 53 → 38 | 49 → 31 | **46 → 37** |
| mất qua 4 lượt (MiB) | 16 | 15 | 18 | **9** |
| SUnreclaim trước → sau (MiB) | 36 → 46 | 35 → 46 | 22 → 31 | **21 → 24** |
| page_owner payload pool bộ đệm trống (MiB) | 16 → 25 | 14 → 24 | 14 → 16 | 14 → 18 |
| MemAvailable sau (MiB) | 9 | 10 | 6 | 13 |

- Mỗi thay đổi đứng riêng không giúp gì: chỗ phân mảnh `kmalloc-4k` chỉ chuyển từ payload
  NSS (không 0149) sang segment fraglist (không tắt GRO), hoặc ngược lại.
- Cả hai cùng lúc thì lượng RAM mất qua 4 lượt giảm một nửa (9 so với 15-18 MiB), và slab
  không tăng.
- Không 0149 thì payload pool tăng ~9 MiB dù số payload firmware giữ gần như không đổi
  (~4250): phần chênh là ô trống trong slab order-3 dở dang.

## 7. Bản thường: 0149 + fraglist GRO tắt sẵn trong image

Sửa: commit `qualcommax: ipq50xx: cr8806: turn fraglist GRO off by default` (file
`base-files/etc/uci-defaults/15_cr8806_ecm_gro_list`). ECM vốn đã có tuỳ chọn
`ecm.general.disable_gro_list` (mặc định 0), script hotplug `net` và init của ECM áp nó cho
mọi interface vật lý. Commit chỉ bật tuỳ chọn đó cho CR8806. Build từ `cr8806-pr` + commit
này, không có commit `DEBUG:` (không page_owner), qca-nss-drv có 0149.

Sau khi flash (giữ config), không gõ `ethtool` tay: eth0, eth1, lan1-3, wan và 3 interface
Wi-Fi tự `rx-gro-list off`. br-lan và các VLAN của nó vẫn `on` (không phải interface vật
lý), và cũng không cần: GRO chạy ở interface nhận.

4 lượt, upload 788-841, download 933-940 Mbit/s (tốt nhất trong các lần đo):

| | trước | lượt 1 | lượt 2 | lượt 3 | lượt 4 |
|---|---|---|---|---|---|
| MemAvailable (MiB) | 18 | 12 | 13 | 12 | 12 |
| MemFree / Cached (MiB) | 24 / 29 | | | | 25 / 15 |
| SUnreclaim (MiB) | 21 | 23 | 23 | 23 | 23 |

- Sau test: `kmalloc-4k` chỉ còn 4 slab dở dang (bản đối chứng 396), payload NSS 4266,
  dmesg không có lỗi NSS.
- MemAvailable xuống một nấc sau lượt đầu (payload firmware giữ, page cache bị đẩy bớt)
  rồi đứng yên 12-13 MiB, không còn tụt dần theo từng lượt. Page cache còn 15 MiB sau 4
  lượt, các bản debug chỉ còn 5-6 MiB.
- Không có page_owner nên MemAvailable lúc đầu cao hơn các bản debug ~4.5 MiB (`page_ext`).

## 8. Hạ pool bộ đệm trống của firmware NSS: 4096 → 2048 (lúc chạy, không lưu)

Sửa: `sysctl -w dev.nss.n2hcfg.n2h_empty_pool_buf_core0=2048`. Giá trị 4096 đến từ
`NSS_LOW_MEM_EMPTY_POOL_BUF_SZ` (profile LOW); sysctl này ghi được lúc chạy, driver gửi
`N2H_EMPTY_POOL_BUF_CFG` cho firmware và chờ ACK. Vì sao: lúc nghỉ firmware giữ ~4200
payload × 4 KiB ≈ 16 MiB, phần lớn nhất trong page_owner sau buffer CE ath11k.

Bản thường (PR 45 + `coherent_pool=512K`), uptime ~17 giờ. Lần này laptop đặt xa AP
hơn 6 m (tín hiệu -65..-70 dBm, ~360-550 Mbit/s mỗi chiều), nên throughput không so được
với các mục trước. Đối chứng 4096 chạy 4 lượt ngay trước đó ở cùng chỗ.

| | 4096 (đối chứng) | 2048 |
|---|---|---|
| payload firmware giữ lúc nghỉ | ~4200 (`payload_free_count` ~2100-2270) | ~2100 (`payload_free_count` 0) |
| MemAvailable lúc nghỉ (MiB) | 12-16 | 20 (+7.5 MiB ngay sau khi đổi) |
| `n2h_payload_alloc_fails` | 8, không tăng qua 4 lượt | tăng ngay khi nghỉ, 3.2 triệu sau ~1 phút tải |
| lượt upload đầu tiên | 357 Mbit/s | **0 byte**, laptop rớt Wi-Fi |

- Firmware trả payload về ngay khi đổi (skb 4834 → 2096 trong 10 s), nên phần RAM này
  đúng là do pool giữ.
- Nhưng ở 2048 firmware hết payload trống: số firmware đang dùng lúc nghỉ đã ~2100, không
  còn dư. Gói bị bỏ, traffic dừng. Trả về 4096 thì chạy lại bình thường (401/491 Mbit/s).
- Ngay ở 4096, lúc LAN→Wi-Fi `payload_free_count` xuống ~560 và có vài chục lần alloc
  fail. Biên ở 4096 đã mỏng; một giá trị giữa (vd. 3072) chỉ lấy được ~4 MiB với rủi ro
  cạn pool khi tải, nên không theo hướng này.

Kết luận: không hạ pool. Giữ 4096.

## 9. Thu nhỏ ring RX stmmac lúc chạy: `ethtool -G eth1 rx 64`, rồi eth0

Vì sao: eth0 và eth1 mỗi cái có page pool 2 MiB (RX 512), nhưng sau 15 giờ eth0 nhận 0
gói, eth1 210 gói: NSS nắm data plane, ring của host không dùng.

Kết quả: router mất hẳn đường dữ liệu. Không ping được từ LAN, cắm dây vào cổng LAN không
nhận DHCP, Wi-Fi vẫn phát và client vẫn nối được nhưng không có IP. Đèn vẫn bình
thường, router không reboot. Phải rút điện; sau boot ring về 512, mọi thứ chạy lại (giá
trị `ethtool` không lưu).

Nguyên nhân (đọc code, chưa có log vì `/tmp` mất khi rút điện): patch
`0956-net-stmmac-add-a-data-plane-claim-API-for-the-NSS-firmware` cho qca-dwmac-nss
"claim" GMAC: dừng DMA của host, tắt NAPI và IRQ, firmware NSS chạy DMA bằng ring riêng.
Buffer RX của host "stay allocated but unused". `ethtool -G` gọi
`stmmac_reinit_ringparam()`, tức `stmmac_release()` + `stmmac_open()`, trong khi claim
vẫn giữ: DMA của host khởi động lại trên cùng controller firmware đang dùng. Claim không
chặn việc đổi ring.

- Không thử được lúc chạy. Muốn lấy lại ~4 MiB phải sửa ở phía claim: giải phóng buffer
  RX của host khi claim (cấp lại khi release, vốn đã phải bounce interface), hoặc ring nhỏ
  từ lúc probe.
- Riêng việc `ethtool -G` (và có lẽ các thao tác khác gọi release/open, như đổi MTU) làm
  chết data plane khi đang claim là một lỗi nên báo cho patch 0956: nên trả `-EBUSY`.

## 10. ath11k: cache riêng cho mỗi pipe CE, link descriptor cho 32 client, BPF JIT

Ba commit, build cùng bản debug page_owner, trên cây của PR 45 (`coherent_pool=512K`, 0149,
fraglist GRO tắt):

1. `999-997-ath11k-nss-256m-ce-rx-fragment-caches.patch`. Buffer RX của CE (2048 byte)
   lấy từ `dev_alloc_skb()`, tức cache page-fragment chung theo CPU, 13 buffer trong một
   chunk 32 KiB, chunk chỉ trả lại khi cả 13 được giải phóng. Ở mục 3, page_owner gán
   16-18 MiB cho việc nạp lại buffer CE (lúc boot chỉ ~1.3 MiB), trong khi số buffer
   thật là 800 mỗi radio (CE1 512, CE2 32, CE5 256), ~3.7 MiB cả hai radio. Không driver
   nào khác dùng cache này: các pipe tự trộn với nhau. CE1 (HTT) nạp liên tục, CE2 (WMI)
   và CE5 (pktlog) hiếm khi; một buffer của pipe chậm giữ cả chunk buffer HTT đến khi pipe
   đó quay vòng. Sửa: trong profile NSS 256M, mỗi pipe một `page_frag_cache` riêng, cấp
   dưới `ce_lock` (vốn đã khoá việc nạp), drain khi dọn pipe.
2. `999-998-ath11k-nss-256m-link-descriptors.patch`. Pool link descriptor WBM tính cho 64
   client × 2 TID: 18560 descriptor, làm tròn 32768 × 128 byte = 4 MiB DMA mỗi radio.
   Profile NSS 256M tính cho 32 client: 9279 → 16384, 2 MiB mỗi radio.
3. `16_cr8806_bpf_jit_off` (uci-defaults ghi `net.core.bpf_jit_enable=0` vào sysctl.d).
   **Không có tác dụng**: chương trình BPF duy nhất là `ptp_classifier_init`, kernel tạo
   và JIT trong `sock_init` lúc boot, trước mọi sysctl. Vùng `bpf_prog_pack` 2 MiB vẫn
   còn. Muốn bỏ phải tắt `CONFIG_BPF_JIT` trong kernel config, mà config đó dùng chung cho
   mọi board ipq50xx. Bỏ commit này khi gộp.

Đo: flash slot 1 (giữ config), page_owner lúc 9 phút uptime, rồi 4 lượt như mục 4-6,
laptop gần AP (-33 dBm, HE160 MCS 11).

page_owner lúc nghỉ, 9 phút uptime (MiB):

| | mục 5 (0149 + tắt GRO, `coherent_pool=2M`) | mục 10 |
|---|---|---|
| buffer RX của CE | 17.9 | **4.3** |
| link descriptor | 8.1 | **4.1** |
| atomic pool (`coherent_pool`, PR 45) | 6.0 | 1.5 |
| DP RX / monitor (cache riêng của 993) | 3.6 | 3.5 |
| payload pool bộ đệm trống NSS | 14.3 | 14.4 |
| page cache | 24.8 | 36.5 |
| MemAvailable | 14.2 | **25.2** |

4 lượt: upload 780-812, download 930-943 Mbit/s (bằng các lần trước).

| | trước | lượt 1 | lượt 2 | lượt 3 | lượt 4 |
|---|---|---|---|---|---|
| MemAvailable (MiB) | 24 | 21 | 26 | 21 | 22 |
| MemFree / Cached (MiB) | 25 / 37 | 23 / 36 | 28 / 36 | 23 / 36 | 24 / 35 |
| SUnreclaim (MiB) | 22 | 23 | 23 | 23 | 24 |

- Buffer CE đứng yên 4.32 MiB qua 4 lượt (mục 5 sau 4 lượt: 14.3). Link descriptor 4.07.
- Sau 4 lượt page cache còn 35 MiB (bản debug ở mục 5: 5 MiB), MemAvailable thấp nhất khi
  đang chạy 18 MiB (mục 5: 7-11). Đây là bản debug, bản thường còn thêm ~4.5 MiB
  (`page_ext`).
- Không lỗi ath11k/NSS trong dmesg. `rx_desc_alloc_fail` của radio 5 GHz +127 nghìn qua 4
  lượt, cùng cỡ với mục 2 (pool descriptor RX của NSS, không phải RAM host).
- `n2h_payload_alloc_fails` tăng một đợt 36 → 1180 lúc đầu lượt upload thứ 4 (MemFree
  ~18 MiB, gần `min_free_kbytes` 16 MiB), không tăng nữa; throughput lượt đó vẫn 790. Các
  bản trước đếm 8-34 cho cả bài test. Cần xem lại trên bản thường.

Kết luận: 999-997 và 999-998 lấy lại ~17.5 MiB lúc nghỉ, không giảm throughput.

## Việc còn lại

- Build bản thường (không page_owner) với 999-997 + 999-998, đo lại, theo dõi
  `n2h_payload_alloc_fails`. Chạy dài 1-2 ngày.
- 999-998: thử nhiều client (điện thoại, laptop, IoT) để chắc 16384 link descriptor đủ.
- BPF JIT: chỉ còn cách tắt `CONFIG_BPF_JIT` cho cả ipq50xx; hỏi upstream trước.
- Giải phóng buffer RX stmmac khi NSS claim (mục 9, sửa patch 0956).
- `coherent_pool`: xem PR 45. Pool bộ đệm trống NSS: mục 8, không hạ được.
