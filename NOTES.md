# CR8806: ghi chép thử nghiệm RAM khi chạy NSS Wi-Fi offload

Branch thử nghiệm, nằm trên `cr8806-pr`. Mỗi thử nghiệm một mục: sửa gì, vì sao, đo thế
nào, kết quả. Khi ổn định, phần code được gộp lại thành commit trên `cr8806-pr`; thư mục
`cr8806-memtest/` và các commit `DEBUG:` không đưa vào branch chính.

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
trong feed nss-packages, vẫn phải chọn tay.

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
- Kết luận: chưa đưa 0149 vào branch chính. Muốn có lợi thật phải giảm việc trộn object
  sống ngắn và sống lâu trong `kmalloc-4k`, không chỉ riêng payload NSS.

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
  không có 0149 để biết mỗi thay đổi đóng góp bao nhiêu.

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

## Việc còn lại

- Chạy dài 1-2 ngày trên bản ở mục 7 để biết phần "không tên" (~61 MiB) có dừng lại không.
- Gộp vào `cr8806-pr`: commit fraglist GRO đã nằm ngay trên `cr8806-pr`. Patch 0149 là PR
  riêng vào nss-packages.
- Thử nghiệm tiếp theo (chưa làm): hạ `n2h_high_water_core0`, giảm CE buffer ath11k,
  page pool stmmac khi NSS đã nắm data plane, `coherent_pool`.
