# PVE Quick Menu - `42`

Script menu lệnh nhanh cho Proxmox VE, gõ `42` để dùng.

## Cài đặt / Cập nhật (1 dòng)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/nauthnael/pve-42/main/install.sh)
```

Chạy lệnh này trên bất kỳ PVE nào — tự động cài mới hoặc cập nhật bản cũ.

## Menu hiện tại

| # | Tên | Chức năng |
|---|-----|-----------|
| 1 | Aro Report | Chạy `aro-manager.sh report` trên các CT đang running |
| 2 | Aro Update | Tải & chạy `aro-manager.sh update` (có retry wget) |
| 3 | Aro Restart | Chạy `aro-manager.sh restart` trên các CT đang running |
| 4 | CT Restart | Restart CT đang chạy, CT đang off thì start |
| 5 | CT Stop | Tắt các CT (`pct stop`) |
| 6 | Aro Update Watchdog | Tải & chạy `aro-manager.sh update --watchdog-only` |
| 7 | Open VNC | Thêm iptables forward VNC cho CT (tự xóa sau 2h) |
| 8 | Check Network CT | Kiểm tra CT mất IP, tùy chọn renew DHCP |
| 9 | Check ARO Score | Kiểm tra điểm ARO node, xuất CSV |
| 10 | Kết nối Dashboard | Enable ARO dashboard URL/API cho các CT đã chọn |
| 11 | Deploy ARO | Deploy ARO theo proxy từ `/root/ct-list.csv` |

## Quy trình cập nhật script

1. Sửa `42.sh` trên máy local / qua Claude
2. Commit & push lên GitHub
3. Chạy lệnh 1 dòng bên trên trên từng PVE

## Cấu trúc repo

```
pve-42/
├── 42.sh          # Script chính
├── install.sh     # Script cài đặt / cập nhật
└── README.md
```
