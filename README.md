# tuanlee-ubuntu-workstation

Bộ script bash tiếng Việt giúp đội lập trình web/app chuẩn hóa máy Ubuntu Desktop:

- **`setup_dev.sh`** — Cài đặt toàn bộ môi trường lập trình sau khi cài OS (menu, từng mục độc lập)
- **`reset_dev.sh`** — Gỡ sạch môi trường đã cài, đưa máy về trạng thái như mới cài OS (không đụng data)
- **`optimize_dev.sh`** — Chẩn đoán & tối ưu an toàn khi máy bị chậm/giật lag/treo thoáng qua

Điểm chung của cả 3 script:

| Đặc tính | Ý nghĩa |
|---|---|
| Menu tiếng Việt | Chạy tương tác, chọn số |
| Cô lập lỗi | Mục nào lỗi chỉ được ghi nhận và bỏ qua, **không làm dừng các mục khác** |
| Idempotent | Chạy lại nhiều lần an toàn — đã cài/đã sạch thì tự bỏ qua |
| Log mỗi phiên | `logs/setup_*.log`, `logs/reset_*.log`, `logs/optimize_*.log` |
| Tổng kết cuối phiên | Liệt kê đúng những mục FAIL kèm đường dẫn log |
| Nhận diện user thật | Cài vào home của user đang đăng nhập (qua `SUDO_USER`), không rơi vào `/root` |

---

## Yêu cầu

- Ubuntu Desktop 22.04 / 24.04 (đã kiểm tra trên 24.04 LTS)
- Chạy bằng tài khoản người dùng thường, dùng `sudo` để gọi script (**không** đăng nhập root trực tiếp)
- Có kết nối Internet

```bash
git clone <repo-url> tuanlee-ubuntu-workstation
cd tuanlee-ubuntu-workstation
```

---

## 1. `setup_dev.sh` — Cài môi trường lập trình

```bash
sudo bash setup_dev.sh
```

### Menu

```
[1]  Cập nhật hệ thống (apt update/upgrade)
[2]  Cài Git
[3]  Cài Apache2 (+ mod_rewrite)
[4]  Cấu hình Apache nhiều project (localhost/tenproject)
[5]  Cài PHP 8.3 + extensions
[6]  Cài NVM
[7]  Cài Node.js LTS (qua NVM — cần mục 6)
[8]  Cài Visual Studio Code
[9]  Cài Google Chrome
[10] Cài Vim
[11] Cài Meld
[12] Cài IBus Bamboo (gõ tiếng Việt)
[13] Cài Flutter SDK (~/development/flutter)
[14] Cài Android Studio (snap, tùy chọn)
[15] Tạo Virtual Host cho project (http://<tên>.test)
[16] Xóa Virtual Host
[17] Cài TẤT CẢ mục [1]→[14] (bỏ qua lỗi, tổng kết cuối)
[0]  Thoát
```

### Hai cách truy cập project web

| Cách | URL | Cấu hình |
|---|---|---|
| Theo folder | `http://localhost/ten_project` | Mục **[4]** ghi `DocumentRoot /var/www/html` + `<Directory>` với `AllowOverride All` (tự backup file gốc trước khi sửa) |
| Virtual Host riêng | `http://ten_project.test` | Mục **[15]** sinh conf + thêm `/etc/hosts` + `apachectl configtest` trước khi reload — **fail sẽ tự rollback** |

> `.test` là TLD do IANA dành riêng cho mục đích test: không trùng site thật, HTTP chạy ngay không cần chứng chỉ.

### Ghi chú sau khi cài

- **IBus Bamboo**: mở *Settings → Keyboard → Input Sources* → `+` → thêm *Vietnamese (Bamboo)*; đổi bàn phím bằng `Super+Space`. Nếu chưa thấy Bamboo, đăng xuất/đăng nhập lại.
- **Flutter**: mở terminal mới rồi chạy `flutter doctor`.
- **Android Studio**: mở Studio cài Android SDK, sau đó chạy `flutter doctor --android-licenses`.

---

## 2. `reset_dev.sh` — Gỡ sạch về trạng thái máy mới

Dùng để test lại vòng cài đặt mà **không cần cài lại OS / không mất data**.

```bash
sudo bash reset_dev.sh
```

Menu đối chiếu 1-1 với setup: mỗi mục gỡ đúng thứ setup đó đã cài. Mỗi mục sẽ **in rõ danh sách sắp gỡ/xóa** rồi hỏi `(y/N)` một lần duy nhất.

### Nguyên lý

- Gói apt dùng `apt-get purge` → xóa cả binary lẫn cấu hình trong `/etc` → cài lại ra đúng cấu hình mặc định nguyên bản
- NVM/Flutter cài thủ công → xóa thư mục + **lọc đúng từng dòng** NVM/Flutter đã chèn vào `.bashrc`/`.profile` (dòng khác giữ nguyên từng byte)
- PPA Bamboo được gỡ khỏi `sources.list.d` / `trusted.gpg.d`
- Dòng `127.0.0.1 <tên>.test` được gỡ khỏi `/etc/hosts`

### Được bảo vệ tuyệt đối

- ✅ Toàn bộ project trong `/var/www/html`
- ✅ Documents, code, dotfile cá nhân
- ✅ Bộ gõ `ibus` gốc của hệ thống (chỉ gỡ `ibus-bamboo`)
- ✅ `vim-tiny`, `vim-common` — mặc định có sẵn của Ubuntu Desktop

### Sẽ bị xóa (theo thiết kế)

- Settings/extensions VS Code (`~/.vscode`, `~/.config/Code`)
- Profile Chrome (bookmarks, extensions...)
- Cache nặng Flutter/Android (`~/.pub-cache`, `~/Android/Sdk`, `~/.gradle`, AVD)

---

## 3. `optimize_dev.sh` — Chẩn đoán & tối ưu an toàn

Dành cho máy báo chậm, giật lag, treo màn hình thoáng qua, Chrome treo, build Flutter ì ạch — dù cùng cấu hình.

```bash
sudo bash optimize_dev.sh
```

```
[1] CHẨN ĐOÁN toàn diện (read-only — hãy chạy mục này trước!)
[2] Giảm áp lực RAM/Swap (swappiness=10, vfs_cache_pressure=50)
[3] Bật ZRAM (nén RAM — chữa treo do hết RAM)
[4] Tắt Tracker indexer (quét file ngầm)
[5] Tắt animation GNOME
[6] Dọn dung lượng (journal 200MB, apt, thumbnail, snap cũ)
[7] Gỡ kernel cũ (giữ bản đang chạy + mới nhất)
[8] Bật fstrim.timer (SSD)
[H] HOÀN TÁC các tinh chỉnh đã áp dụng
[0] Thoát
```

### Quy trình khuyến nghị

1. Chạy **[1] Chẩn đoán** — báo cáo dạng `[TỐT]/[CẢNH BÁO]/[NGUYÊN NHÂN?]`, mỗi phát hiện chỉ kèm "→ chạy mục [x]"
2. Áp dụng các mục được chỉ ra
3. Chạy lại **[1]** để xác nhận hết cảnh báo
4. Thấy phiền toái gì? **[H]** hoàn tác từng thay đổi

### Những gì chẩn đoán tìm được

Lịch sử OOM killer (bằng chứng hết RAM gây treo) · render phần mềm `llvmpipe` (thiếu driver GPU) · áp lực swap · Tracker indexer · disk đầy · HDD vs SSD · kernel cũ · snap revision thừa · journal nặng · boot chậm ở service nào · unit failed · top process CPU/RAM

### Cam kết an toàn

- **Không sửa bất kỳ file cấu hình gốc nào của hệ thống** — mọi thay đổi là drop-in file riêng (`/etc/sysctl.d/99-dev-tuning.conf`, `/etc/systemd/journald.conf.d/...`) → xóa file = về mặc định
- Mọi thay đổi ghi vào manifest `backups/optimize_manifest.txt` (kèm giá trị cũ từng máy) → **[H] hoàn tác chính xác**
- Kernel: chỉ gỡ bản versioned, luôn giữ bản đang chạy + mới nhất; dừng nếu `dpkg` đang ở trạng thái chưa hoàn tất
- fstrim chỉ bật trên SSD; zram khuyến nghị theo dung lượng RAM thực tế

---

## Quy trình làm việc điển hình cho team

```bash
# Máy mới cài OS xong
sudo bash setup_dev.sh          # cài lần lượt từng mục, hoặc [17] cài tất cả

# Muốn test lại từ đầu (vd: nâng cấp script, nghi ngờ cài sai bước nào đó)
sudo bash reset_dev.sh          # [13] RESET TẤT CẢ
sudo bash setup_dev.sh          # cài lại, so sánh kết quả

# Thành viên phản ánh máy chậm / treo
sudo bash optimize_dev.sh       # [1] chẩn đoán → xử lý theo gợi ý → [1] xác nhận lại
```

## Cấu trúc thư mục

```
tuanlee-ubuntu-workstation/
├── README.md            ← bạn đang đọc
├── setup_dev.sh         # cài môi trường
├── reset_dev.sh         # gỡ sạch về mặc định
├── optimize_dev.sh      # chẩn đoán + tối ưu an toàn
├── logs/                # log tự sinh mỗi lần chạy (git-ignore nếu muốn)
└── backups/
    └── optimize_manifest.txt   # manifest hoàn tác của optimize_dev.sh
```

## Xử lý sự cố nhanh

| Hiện tượng | Xử lý |
|---|---|
| Script báo "Script cần quyền root" | Chạy đúng `sudo bash <script>.sh` từ user thường, không chạy bằng tài khoản root |
| Sau gỡ Bamboo, Settings còn tên "Vietnamese (Bamboo)" | Chọn nó và nhấn `-`; vô hại nếu để nguyên |
| ZRAM chưa thấy hoạt động sau mục [3] | Khởi động lại máy rồi kiểm tra `swapon --show` |
| Hoàn tác kernel báo thiếu mạng | Hoàn tác kernel cần Internet để `apt-get install` lại đúng version đã ghi |
| Một mục FAIL liên tục | Mở file log trong `logs/` tương ứng phiên chạy, tìm dòng `[LỖI]` gần nhất |
