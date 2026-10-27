# CR8806: ghi chép thử nghiệm RAM khi chạy NSS Wi-Fi offload

Branch `notes` chỉ chứa ghi chép, không chứa cây OpenWrt:
- `NOTES.md` (file này): các thử nghiệm RAM và Wi-Fi trên CR8806.
- `pr45-followup.md`: các bước test cho review PR 45 (tiếng Anh).
- `tools/`: script đo dùng trong hai file trên.

Mỗi thử nghiệm một mục: sửa gì, vì sao, đo thế nào, kết quả. Code nằm ở các branch của
cây OpenWrt (bên dưới). Khi ổn định, code được cherry-pick sang `main`. Các commit
`DEBUG:` không đưa vào. Trước đây ghi chép nằm trong thư mục `cr8806-memtest/` của branch
`cr8806-memtest`. Lịch sử được giữ nguyên khi tách sang branch này.

Sau khi upstream nhận PR 50, 51 (`999-997`, fraglist GRO tắt), nss-packages PR 9 (0149) và
sửa issue 52 (`c3po-tag-8021q` 7930126b66), branch được dựng lại lần nữa:

1. `main` (nhánh mặc định của fork fanha99/openwrt-xiaomi-cr8806-nss): upstream + NSS 256M
   mặc định cho CR8806 + feed pin (nss lại là kuncy7, đã có 0149) + README trang đầu.
   Release tag ở đây.
2. `testing`: `main` + những gì đang thử, hiện là `999-998` (mục 10). Thử ổn mới
   cherry-pick sang `main`.
3. `cr8806-memtest`: `testing` + `DEBUG: ... enable page_owner` (mục 3). Chỉ để đo, không
   gộp.
4. `notes`: ghi chép này.

Các bản dựng trước chỉ còn ở máy local (`archive/cr8806-memtest-v1`, `-v2`,
`-20261026`). Bản ngày 2026-10-26 tương ứng tag `cr8806-nss-2026.10.26`.

Phần qca-nss-drv dùng thẳng kuncy7/nss-packages `ipq50xx-rebase` (đã có profile
`NSS_MEM_PROFILE_LOW` cho CR8806 từ PR 7 và 0149 từ PR 9). Fork fanha99/nss-packages chỉ
còn giữ cho các tag release cũ.

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

- Bổ sung sau khi đọc `qca-dwmac-nss`: kuncy7 đã gặp đúng kiểu lỗi này khi đổi MTU. Comment
  ở `NETDEV_PRECHANGEMTU` trong `dwmac_nss_netdev_event()` nói `__stmmac_release()` trên GMAC
  đang claim gọi `napi_disable()` lần thứ hai, "blocks forever with rtnl held". Với MTU
  module trả GMAC lại trước; `ethtool -G`/`-L` không phát sự kiện netdev nào nên không được
  bảo vệ. Treo khi giữ rtnl khớp với việc router không reboot nhưng mạng không lên lại.
- Không thử được lúc chạy. Muốn lấy lại ~4 MiB phải sửa ở phía claim: giải phóng buffer
  RX của host khi claim (cấp lại khi release, vốn đã phải bounce interface), hoặc ring nhỏ
  từ lúc probe. Với `ethtool -G`/`-L` khi đang claim, nên trả `-EBUSY` (báo kuncy7).

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

## 11. Bản thường (999-997 + 999-998) và A/B chiều nhận với bản PR 45

Build `cr8806-main` (không page_owner) với hai patch ath11k ở mục 10, flash slot 0. Bản
đối chứng: bản PR 45 512K, flash slot 1.

4 lượt (9 phút uptime, laptop gần AP), so với bản PR 45 512K đo cùng cách:

| MemAvailable (MiB) | trước | sau lượt 1 | 2 | 3 | 4 |
|---|---|---|---|---|---|
| PR 45 512K | 19.2 | 15.4 | 18.4 | 15.9 | 14.5 |
| 999-997 + 999-998 | **28.5** | 27.4 | 25.9 | 24.4 | 22.5 |

Page cache sau 4 lượt 36 MiB (bản PR 45: 20). `n2h_payload_alloc_fails` không tăng (34),
dmesg sạch. Download 900-931 Mbit/s; upload chỉ 388-690.

Upload thấp nên kiểm tra 999-998: REO và RXDMA dùng link descriptor khi nhận. Trên radio
5 GHz có `RXDMA Overflow` và `REO Frame OOR` tăng mỗi lần upload. A/B ngay sau boot (~2.5
phút uptime), 3 lượt upload 30 s + 1 download, laptop -33..-39 dBm:

| | PR 45 512K | 999-997 + 999-998 |
|---|---|---|
| upload (Mbit/s) | 652 / 657 / 652 | 679 / 692 / 634 |
| download (Mbit/s) | 926 | 920 |
| `RXDMA Overflow` sau 3 lượt | 40972 | 36745 |
| `REO Frame OOR` sau 3 lượt | 31400 | 26669 |
| MemAvailable trong lúc đo (MiB) | 15-22 | 25-35 |

- Hai bản như nhau ở chiều nhận; overflow có cả ở bản cũ. 999-998 không làm thiếu link
  descriptor với một client. Upload hôm đó thấp ở cả hai bản (sóng/laptop), không do patch.
- Chưa thử nhiều client cùng lúc.

## 12. Bản kuncy nhờ chạy: upstream 7930126b66 + `ATH11K_NSS_MEM_PROFILE_256M` (PR 50)

Build đúng cách release của upstream: `.github/ci/ipq50xx/common.config` + `256m.config` +
`CONFIG_ATH11K_NSS_MEM_PROFILE_256M=y`, không LuCI, không `999-998`. Flash slot 0, chạy dài
với `memlong.sh` (mỗi 10 phút: meminfo, payload NSS, số client, `reo_reaped`,
`tx_desc_alloc_fail`, `Frame OOR` của hai radio) và `climon.sh` (mỗi phút mỗi client: tín
hiệu, byte, ping IPv6 link-local; sự kiện hostapd/ath11k/NSS).

Sau 12,5 giờ, 3 client 5 GHz (một client xem camera liên tục 1,3-2,4 Mbit/s). Tải nhẹ: khoảng 7,5 giờ có lưu lượng, ban đêm gần như không có gì, không có đợt dồn dập (xem mục 13):
- MemAvailable 16,5-25 MiB theo tải, `SUnreclaim` về lại 23,3 MiB khi rảnh.
- `n2h_payload_alloc_fails` 36, tất cả trong 2 phút đầu, sau đó không tăng.
- 5 GHz: `Frame OOR` 11.138, `tx_desc_alloc_fail` 58.758 / 3,81 M TX (1,5 %). Chưa có số
  đối chứng không profile.
- Issue 53 (QCN6122 ngừng nhận client sau 3-14 giờ): chưa gặp, `reo_reaped` vẫn tăng,
  client mới vào được ở 9,9 và 11,1 giờ.

`simulate_fw_crash` (12,7 giờ): trên IPQ5018 hai radio là hai user PD trên cùng một Q6, nên
assert radio nào cũng là lỗi root PD. q6wcss khởi động lại trong 0,15 s, cả hai radio
khôi phục. Client 5 GHz vào lại sau 4-35 s. Không mất bộ nhớ, payload fail không tăng.
Lần assert 5 GHz thiếu dòng `successfully recovered` vì `__ath11k_warn()` bị
ratelimit sau 11 cảnh báo WMI -108 lúc firmware đang tắt.

## 13. Tải nặng 5 GHz cho issue 53 (ring RXDMA 512)

Issue kuncy7/openwrt-nss-edma#53: trên AX53 v2 (cũng QCN6122, 256 MB), sau 3-14 giờ 5 GHz
ngừng nhận. Khoảng 800 buffer RX vào phần cứng rồi không ra, `rx_desc_in_use` 1324. kuncy
nghi ring RXDMA/refill 512 phần tử (patch 999-990) bị cạn khi có đợt dữ liệu dồn dập.

Cùng bản ở mục 12, uptime 14,5 giờ. 5 lượt, mỗi lượt: upload `-P 8` 60 s, upload `-P 4`
60 s, download `-P 4` 60 s, nghỉ 60 s. Một client HE160 ở xa hơn các lần trước (−67 đến
−74 dBm), server cắm dây.

| | trước | sau 5 lượt |
|---|---|---|
| `reo_reaped` 5 GHz | 2.769.683 | 47.290.877 |
| `rx_desc_in_use` | 511 | 511 ở mọi lần chụp |
| `rxdma_hw_desc_unavailable` / `rx_desc_alloc_fail` | 0 / 0 | 0 / 0 |
| RXDMA `Overflow` | 1.721 | 171.850 |
| REO `Frame OOR` | 12.635 | 58.275 |
| MemAvailable | 19 MiB | 13-25 MiB trong lúc chạy, 24 MiB sau |
| `kmalloc-4k` partial | 39 | 3-115 trong lúc chạy, 18 sau |
| `tx_desc_alloc_fail` 5 GHz | 58.758 | 9.300.862 |

- Upload 357-455 Mbit/s, download 639-740 Mbit/s. Thấp hơn các lần trước vì client xa
  hơn (PHY 0,5-1,4 Gbit/s).
- Ring 512 có tràn: `Overflow` tăng khoảng 170 nghìn, toàn bộ trong các phút upload.
  Nhưng lần nào cũng hồi phục, không kẹt.
- Số buffer "bị giữ" (`rxdma_buf_replenished` − `reo_reaped` − `wbm_src_dma` −
  `wbm_src_reo`):
  - Trước hai lần crash là 517.
  - Ngay sau hai lần crash là 1.539. Mỗi lần firmware khởi động lại nạp lại ring (+511),
    còn bộ đếm không reset.
  - Trong lúc tải nặng, số này trôi thêm khoảng 165 sau 44 triệu khung, trong khi
    `rx_desc_in_use` vẫn 511.
  - Kết luận: dựa vào `rx_desc_in_use`, không dựa vào hiệu số.
- `tx_desc_alloc_fail` 5 GHz (wifili hết TX descriptor khi gửi gói ra Wi-Fi) tăng khoảng
  9,2 triệu, chỉ trong lúc tải nặng. Trước đó đứng ở 58.758 từ sáng; sau đó 2,5 giờ dùng
  bình thường không tăng thêm.
  - `memlong.sh` lấy mẫu 10 phút một lần, nên không tách được upload với download:
    10:40-10:50 (lượt 1, phần lớn lượt 2) +247 nghìn; 10:50-11:00 (hết lượt 2, lượt 3, 4)
    +6,4 triệu; 11:00-11:10 (lượt 5) +2,6 triệu. Download (LAN → Wi-Fi) là nguồn TX lớn
    nhất nên dễ là nguyên nhân, nhưng chưa chứng minh; upload cũng gửi ACK TCP ra Wi-Fi.
  - Bản này bật `ATH11K_NSS_MEM_PROFILE_256M`, profile giới hạn pool TX descriptor ở
    4096 (`ATH11K_NSS_256M_TX_DESC_LIMIT`, patch 999-992).
    Chưa biết có phải do profile không: cần chạy cùng tải trên bản không profile (A/B ở
    "Việc còn lại"), và lần sau ghi `tx_desc_alloc_fail` theo từng phút (thêm vào
    `rxsnap.sh`).
- Đã gửi lên #53. `memlong.sh` trên router tự lưu danh sách kuncy cần nếu `reo_reaped`
  5 GHz đứng yên khi còn client.

## Việc còn lại

- Chạy tiếp mục 12 vài ngày, rồi chạy ngắn cùng commit không profile để so `Frame OOR`,
  `Overflow` và `tx_desc_alloc_fail`.
- Issue 53: thử ring RXDMA/refill 2048 (kuncy đề nghị) trên CR8806. Đo tốn bao nhiêu
  MemAvailable và `Overflow` dưới cùng tải ở mục 13.
  - Không nhầm với mục 8: đó là pool bộ đệm trống của firmware NSS (4096 → 2048),
    còn đây là kích thước ring 999-990 (512 → 2048).
  - Nhưng hai thứ dính nhau (giả định, cần đo): buffer nạp vào ring RXDMA lấy từ pool đó.
    Lúc nghỉ firmware đã dùng ~2100/4096. Ring 5 GHz 2048 giữ thêm ~1500, còn dư ~500,
    trong khi lúc LAN→Wi-Fi ở mục 8 chỗ trống đã xuống ~560. Dễ cạn pool như mục 8.
  - Khi thử, theo dõi thêm `payload_free_count` và `n2h_payload_alloc_fails` (n2h) lúc
    nghỉ và lúc tải. Nếu cạn, tăng `n2h_empty_pool_buf_core0` rồi tính cả phần RAM đó
    (~6 MiB mỗi radio với buffer 4 KiB) vào chi phí.
- 999-998: thử nhiều client (điện thoại, laptop, IoT) để chắc 16384 link descriptor đủ.
- BPF JIT: chỉ còn cách tắt `CONFIG_BPF_JIT` cho cả ipq50xx; hỏi upstream trước.
- Giải phóng buffer RX stmmac khi NSS claim (mục 9, sửa patch 0956).
- `coherent_pool`: xem PR 45. Pool bộ đệm trống NSS: mục 8, không hạ được.
