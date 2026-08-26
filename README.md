<div align="center">

# tuanlee-ubuntu-workstation

**Bộ script bash tiếng Việt chuẩn hóa máy Ubuntu Desktop cho đội lập trình web/app**

Cài môi trường · Gỡ sạch có kiểm soát · Chẩn đoán hiệu năng · Xác thực trạng thái

![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20%7C%2024.04_LTS-E95420?logo=ubuntu&logoColor=white&style=flat-square)
![Shell](https://img.shields.io/badge/shell-Bash-4EAA25?logo=gnu-bash&logoColor=white&style=flat-square)
![Ngôn ngữ](https://img.shields.io/badge/menu-tiếng_Việt-blue?style=flat-square)
![Verify](https://img.shields.io/badge/verify-read--only-success?style=flat-square)

</div>

---

## Mục lục

- [Tổng quan](#tổng-quan)
- [Yêu cầu hệ thống](#yêu-cầu-hệ-thống)
- [Bắt đầu nhanh](#bắt-đầu-nhanh)
- [Script `setup_dev.sh`](#script-setup_devsh)
- [Script `reset_dev.sh`](#script-reset_devsh)
- [Script `optimize_dev.sh`](#script-optimize_devsh)
- [Script `verify_dev.sh`](#script-verify_devsh)
- [Quy trình làm việc chuẩn](#quy-trình-làm-việc-chuẩn)
- [Kiến trúc trạng thái](#kiến-trúc-trạng-thái)
- [Nhật ký thay đổi](#nhật-ký-thay-đổi)
- [Xử lý sự cố nhanh](#xử-lý-sự-cố-nhanh)
- [Cấu trúc thư mục](#cấu-trúc-thư-mục)

---

## Tổng quan

| Script | Vai trò | Khi nào dùng |
|---|---|---|
| **`setup_dev.sh`** | Cài toàn bộ môi trường lập trình sau khi cài OS (menu, từng mục độc lập) | Máy mới cài OS, onboarding thành viên mới |
| **`reset_dev.sh`** | Gỡ sạch môi trường đã cài về đúng trạng thái mới cài OS — **không đụng data** | Test lại vòng cài đặt, debug script setup |
| **`optimize_dev.sh`** | Chẩn đoán và tối ưu an toàn khi máy chậm / giật lag / treo thoáng qua | Máy phản ánh chậm, build ì, Chrome treo |
| **`verify_dev.sh`** | State validator **read-only**: xác nhận state `INSTALLED` / `CLEAN` đúng thiết kế | Sau setup/reset, trước khi bàn giao máy |

### Đặc tính chung của cả 4 script

| Đặc tính | Ý nghĩa |
|---|---|
| Menu tiếng Việt | Chạy tương tác, chọn số |
| Cô lập lỗi | Mục nào lỗi chỉ được ghi nhận rồi bỏ qua — **không làm dừng các mục khác** |
| Idempotent | Chạy lại nhiều lần an toàn — đã cài / đã sạch thì tự bỏ qua |
| Log mỗi phiên | `logs/setup_*.log` · `logs/reset_*.log` · `logs/optimize_*.log` · `logs/verify_*.log` |
| Tổng kết cuối phiên | Liệt kê đúng những mục FAIL kèm đường dẫn log |
| Nhận diện user thật | Cài vào home của user đang đăng nhập (qua `SUDO_USER`) — không rơi vào `/root` |

---

## Yêu cầu hệ thống

| Thành phần | Yêu cầu |
|---|---|
| Hệ điều hành | Ubuntu Desktop 22.04 / 24.04 *(đã kiểm tra trên 24.04 LTS)* |
| Tài khoản | User thường + quyền `sudo` — **không** đăng nhập root trực tiếp |
| Mạng | Có kết nối Internet |
| Trình duyệt để đọc doc | GitHub/GitLab render đầy đủ badge, bảng và sơ đồ |

```bash
git clone <repo-url> tuanlee-ubuntu-workstation
cd tuanlee-ubuntu-workstation
```

> Tất cả script đều chạy theo cùng một mẫu: `sudo bash <script>.sh`

---

## Bắt đầu nhanh

```bash
sudo bash setup_dev.sh              # 1. cài môi trường (hoặc chọn mục [17] cài tất cả)
sudo bash verify_dev.sh --setup     # 2. xác nhận state INSTALLED — kỳ vọng 0 FAIL
sudo bash reset_dev.sh              # 3. (tuỳ chọn) gỡ sạch để test lại vòng cài
sudo bash verify_dev.sh --reset     # 4. xác nhận state CLEAN + data được bảo vệ
```

---

## Script `setup_dev.sh`

```bash
sudo bash setup_dev.sh
```

<details>
<summary><b>Xem menu đầy đủ</b></summary>

```text
--- WEB BACKEND ---
[1]  Cập nhật hệ thống (apt update/upgrade)
[2]  Cài Git
[3]  Cài Apache2 (+ mod_rewrite)
[4]  Cấu hình Apache nhiều project (localhost/tenproject)
[5]  Cài PHP 8.3 + extensions
[6]  Cài NVM
[7]  Cài Node.js LTS (qua NVM — cần mục 6)

--- DESKTOP TOOLS ---
[8]  Cài Visual Studio Code
[9]  Cài Google Chrome
[10] Cài Vim
[11] Cài Meld
[12] Cài IBus Bamboo (gõ tiếng Việt)

--- FLUTTER / ANDROID ---
[13] Cài Flutter SDK (~/development/flutter)
[14] Cài Android Studio (tuỳ chọn, dung lượng lớn)

--- VIRTUAL HOST ---
[15] Tạo Virtual Host cho project (http://<tên>.test)
[16] Xóa Virtual Host

--- KHÁC ---
[17] Cài TẤT CẢ mục [1]→[14] (bỏ qua lỗi, tổng kết cuối)
[0]  Thoát
```

</details>

### Hai cách truy cập project web

| Cách | URL | Cấu hình |
|---|---|---|
| Theo folder | `http://localhost/ten_project` | Mục **[4]** ghi `DocumentRoot /var/www/html` + khối `<Directory>` với `AllowOverride All` — tự backup file gốc (.setup-bak-*) trước khi sửa |
| Virtual Host riêng | `http://ten_project.test` | Mục **[15]** sinh conf + thêm `/etc/hosts` + chạy `configtest` trước khi reload — **fail sẽ tự rollback** |

> `.test` là TLD do IANA dành riêng cho mục đích test: không trùng site thật, HTTP chạy ngay không cần chứng chỉ.

### Ghi chú sau khi cài

| Component | Việc cần làm tay |
|---|---|
| IBus Bamboo | *Settings → Keyboard → Input Sources* → `+` → thêm *Vietnamese (Bamboo)*; đổi bàn phím bằng `Super+Space`. Chưa thấy Bamboo thì đăng xuất/đăng nhập lại |
| Flutter | Mở terminal mới rồi chạy `flutter doctor` |
| Android Studio | Mở Studio cài Android SDK, sau đó chạy `flutter doctor --android-licenses` |

---

## Script `reset_dev.sh`

Dùng để test lại vòng cài đặt mà **không cần cài lại OS / không mất data**.

```bash
sudo bash reset_dev.sh
```

Menu đối chiếu 1-1 với setup: mỗi mục gỡ đúng thứ setup đó đã cài. Mỗi mục **in rõ danh sách sắp gỡ/xóa** rồi hỏi `(y/N)` một lần duy nhất.

### Nguyên lý

- Gói apt dùng `apt-get purge` → xóa cả binary lẫn cấu hình trong `/etc` → cài lại ra đúng cấu hình mặc định nguyên bản
- NVM / Flutter cài thủ công → xóa thư mục + **lọc đúng từng dòng** đã chèn vào `.bashrc`/`.profile` (dòng khác giữ nguyên từng byte)
- PPA Bamboo được gỡ khỏi `sources.list.d` / `trusted.gpg.d`
- Dòng `127.0.0.1 <tên>.test` được gỡ khỏi `/etc/hosts`

### Ranh giới dữ liệu

| Được bảo vệ tuyệt đối | Sẽ bị xóa (theo thiết kế) |
|---|---|
| Toàn bộ project trong `/var/www/html` | Settings/extensions VS Code (`~/.vscode`, `~/.config/Code`) |
| Documents, code, dotfile cá nhân | Profile Chrome (bookmarks, extensions…) |
| Bộ gõ `ibus` gốc của hệ thống (chỉ gỡ `ibus-bamboo`)<br>`vim-tiny`, `vim-common` mặc định của Ubuntu Desktop | Cache nặng Flutter/Android (`~/.pub-cache`, `~/Android/Sdk`, `~/.gradle`, AVD) |

---

## Script `optimize_dev.sh`

Dành cho máy báo chậm, giật lag, treo màn hình thoáng qua, Chrome treo, build Flutter ì ạch — dù cùng cấu hình.

```bash
sudo bash optimize_dev.sh
```

<details>
<summary><b>Xem menu đầy đủ</b></summary>

```text
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

</details>

### Quy trình khuyến nghị

1. Chạy **[1] Chẩn đoán** — báo cáo dạng `[TỐT]` / `[CẢNH BÁO]` / `[NGUYÊN NHÂN?]`, mỗi phát hiện kèm "→ chạy mục [x]"
2. Áp dụng các mục được chỉ ra
3. Chạy lại **[1]** để xác nhận hết cảnh báo
4. Thấy phiền toái? **[H]** hoàn tác từng thay đổi qua manifest

### Những gì chẩn đoán tìm được

Lịch sử OOM killer (bằng chứng hết RAM gây treo) · render phần mềm `llvmpipe` (thiếu driver GPU) · áp lực swap · Tracker indexer · disk đầy · HDD vs SSD · kernel cũ · snap revision thừa · journal nặng · boot chậm ở service nào · unit failed · top process CPU/RAM

### Cam kết an toàn

- **Không sửa bất kỳ file cấu hình gốc nào của hệ thống** — mọi thay đổi là drop-in file riêng (`/etc/sysctl.d/99-dev-tuning.conf`, `/etc/systemd/journald.conf.d/…`) → xóa file = về mặc định
- Mọi thay đổi ghi vào manifest `backups/optimize_manifest.txt` (kèm giá trị cũ từng máy) → **[H] hoàn tác chính xác**
- Kernel: chỉ gỡ bản versioned, luôn giữ bản đang chạy + mới nhất; dừng nếu `dpkg` chưa hoàn tất trạng thái
- fstrim chỉ bật trên SSD; zram khuyến nghị theo dung lượng RAM thực tế

---

## Script `verify_dev.sh`

State validator **read-only tuyệt đối** — trả lời chính xác 5 câu hỏi:

1. Setup đã cài đủ chưa?
2. Version / config đúng như thiết kế chưa?
3. Reset đã gỡ đúng những gì setup quản lý chưa?
4. Reset có vô tình xóa data được bảo vệ không?
5. Chạy lặp có tạo duplicate / trạng thái bất thường không?

### Cú pháp

```bash
sudo bash verify_dev.sh --setup  [--skip component,component]
sudo bash verify_dev.sh --reset  [--skip component,component]
sudo bash verify_dev.sh --all    # chạy cả 2 suite, kết quả đọc theo từng suite
```

| Mode | Xác minh state | Suite kiểm tra |
|---|---|---|
| `--setup` | `INSTALLED` (sau `setup_dev.sh`) | 20 hạng mục |
| `--reset` | `CLEAN` (sau `reset_dev.sh`) | Gỡ sạch + data được bảo vệ |
| `--all` | Cả hai liên tiếp | Hai tổng kết riêng biệt |

**Exit code:** `0` = không có FAIL · `1` = có ít nhất một FAIL · `2` = sai tham số/thiếu quyền — tiện tích hợp CI/cron.

### Bốn mức verdict

| Verdict | Ý nghĩa |
|---|---|
| `[PASS]` | Đúng expected state |
| `[FAIL]` | Chắc chắn sai — in `Expected:` / `Found:` / `→ gợi ý xử lý thủ công` |
| `[WARN]` | Khác biệt đáng chú ý nhưng chưa đủ coi là thất bại (VD: binary còn nhưng package đã gỡ = nguồn cài ngoài apt) |
| `[SKIP]` | Không áp dụng (component bị `--skip`, hoặc vhost chưa từng tạo) |

### Output mẫu

```text
$ sudo bash verify_dev.sh --setup

===============================================================
  VERIFY SUITE: SETUP — trạng thái mong đợi là INSTALLED
===============================================================
  [PASS] Git (git version 2.43.0)
  [PASS] Apache2 (active + enabled)
  [PASS] mod_rewrite
  [PASS] Apache configtest (Syntax OK)
  [PASS] PHP 8.3 (8.3.6)
  [PASS] Flutter (3.47.1, owner=vcc, PATH đúng 1 lần)
  ...
  [SKIP] Virtual Host

================ TỔNG KẾT VERIFY (STATE: INSTALLED) ================
  PASS: 19   FAIL: 0   WARN: 0   SKIP: 1
Log: /home/vcc/tuanlee/script/logs/verify_20260826_141910.log
```

### Kiểm tra THEO EXPECTED STATE, không phải "lệnh có tồn tại"

Verify so khớp **trạng thái thiết kế**, ví dụ:

- **Node.js**: phải resolve qua đúng đường dẫn `~/.nvm/versions/node/*/bin` (chứng minh đúng install method), version dạng semver, alias `default` tham chiếu `lts/*`
- **NVM**: owner của `~/.nvm` phải là user thật (không phải root), khối config trong `.bashrc` xuất hiện **đúng 1 lần** (>1 = FAIL duplicate)
- **mod_rewrite**: symlink `mods-enabled/rewrite.load` **và** module xuất hiện trong `apache2ctl -M`
- **Apache configtest**: tin vào **exit code** của `apache2ctl configtest` thay vì parse text (chữ `Syntax OK` nằm ở stderr)
- **Flutter**: owner SDK phải là user thật, version đọc từ `bin/cache/flutter.version.json` (chuẩn SDK mới), PATH trong rc-files đúng 1 lần

### Duplicate detectors

Khối NVM ×N trong rc-files · dòng PATH Flutter ×N · hosts entry trùng domain · `ServerName *.test` trùng giữa 2 conf · PPA bamboo ×N entry.

### Protected data (verify cả 2 mode)

`/var/www/html` · `$HOME/Documents` · `vim-tiny`/`vim-common` (tồn tại **không** tính lỗi) · `ibus` hệ thống. Reset mà mất các mục này → FAIL kèm nhãn **CRITICAL**.

### Read-only tuyệt đối

Không apt / snap / sửa config / restart service / tự fix. Chỉ đọc, phân tích, báo cáo + gợi ý lệnh xử lý thủ công. Flutter version được đọc từ file SDK thay vì execute để tránh ghi cache.

### Tokens hợp lệ cho `--skip`

```text
git  apache  rewrite  configtest  conf  php  nvm  node  vscode
chrome  vim  meld  bamboo  flutter  android  vhost  hosts  rootuser  www  documents
```

### Giới hạn đã biết (thiết kế trung thực)

- Không chứng minh được các dòng KHÁC trong `.bashrc` nguyên vẹn byte sau reset nếu thiếu snapshot trước đó — verify xác minh được: dòng NVM/Flutter = 0 và file vẫn tồn tại
- Trên máy chủ thể có sẵn git/php/vim… cài ngoài repo, suite `--reset` có thể WARN "binary còn" — đây đúng semantics: binary thuộc nguồn cài lạ, không phải do setup quản lý

---

## Quy trình làm việc chuẩn

```bash
# ── Máy mới cài OS xong ──────────────────────────────
sudo bash setup_dev.sh              # cài lần lượt từng mục, hoặc [17] cài tất cả
sudo bash verify_dev.sh --setup     # xác nhận state INSTALLED đúng

# ── Test lại từ đầu (nâng cấp script, nghi ngờ cài sai bước) ──
sudo bash reset_dev.sh              # [13] RESET TẤT CẢ
sudo bash verify_dev.sh --reset     # xác nhận state CLEAN + data được bảo vệ
sudo bash setup_dev.sh              # cài lại, so sánh kết quả

# ── Thành viên phản ánh máy chậm / treo ──────────────
sudo bash optimize_dev.sh           # [1] chẩn đoán → xử lý theo gợi ý → [1] xác nhận lại
```

---

## Kiến trúc trạng thái

```mermaid
flowchart LR
    A(["CLEAN<br/>máy mới cài OS"]) -->|"setup_dev.sh"| B(["INSTALLED"])
    B -->|"reset_dev.sh"| A
    A -. "verify --reset" .-> A
    B -. "verify --setup" .-> B
    style A fill:#e8f5e9,stroke:#2e7d32
    style B fill:#e3f2fd,stroke:#1565c0
```

Đường nét đứt = verify chỉ **quan sát**, không bao giờ làm thay đổi state.

---

## Nhật ký thay đổi



---

## Xử lý sự cố nhanh

| Hiện tượng | Xử lý |
|---|---|
| Script báo "Script cần quyền root" | Chạy đúng `sudo bash <script>.sh` từ user thường, không chạy bằng tài khoản root |
| Verify FAIL dù chạy thủ công thấy ổn | Đọc dòng `Expected:` / `Found:` / `→ …` ngay dưới mục FAIL — script mô tả chính xác tiêu chí nó so khớp; đối chiếu rồi sửa tay theo gợi ý |
| Sau gỡ Bamboo, Settings còn tên "Vietnamese (Bamboo)" | Chọn nó và nhấn `-`; vô hại nếu để nguyên |
| ZRAM chưa thấy hoạt động sau mục [3] | Khởi động lại máy rồi kiểm tra `swapon --show` |
| Hoàn tác kernel báo thiếu mạng | Hoàn tác kernel cần Internet để `apt-get install` lại đúng version đã ghi |
| Một mục FAIL liên tục | Mở file log trong `logs/` tương ứng phiên chạy, tìm dòng `[LỖI]` gần nhất |

---

## Cấu trúc thư mục

```text
tuanlee-ubuntu-workstation/
├── README.md                  ← tài liệu bạn đang đọc
├── setup_dev.sh               # cài môi trường lập trình
├── reset_dev.sh               # gỡ sạch về mặc định OS
├── optimize_dev.sh            # chẩn đoán + tối ưu an toàn
├── verify_dev.sh              # state validator (read-only) cho setup/reset
├── .gitignore                 # bỏ qua logs/ và backups/
├── logs/                      # log tự sinh mỗi phiên chạy (git-ignore)
│   ├── setup_YYYYMMDD_HHMMSS.log
│   ├── reset_YYYYMMDD_HHMMSS.log
│   ├── optimize_YYYYMMDD_HHMMSS.log
│   └── verify_YYYYMMDD_HHMMSS.log
└── backups/
    └── optimize_manifest.txt  # manifest hoàn tác của optimize_dev.sh
```

---

<div align="center">

<sub>Duy trì bởi team tuanlee · Chạy tốt nhất trên Ubuntu Desktop 24.04 LTS</sub>

</div>
