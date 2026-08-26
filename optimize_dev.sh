#!/bin/bash
# ============================================================
# optimize_dev.sh — Chẩn đoán & tối ưu an toàn máy Ubuntu Desktop
# Mọi thay đổi qua drop-in file riêng + manifest hoàn tác
# Cách dùng: sudo bash optimize_dev.sh
# ============================================================

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/optimize_$TS.log"
MANIFEST="$SCRIPT_DIR/backups/optimize_manifest.txt"

SYSCTL_TUNING_CONF="/etc/sysctl.d/99-dev-tuning.conf"
JOURNALD_CAP_CONF="/etc/systemd/journald.conf.d/99-dev-tuning.conf"

FAILED_ITEMS=()
ITEM_FAIL_BASE=0
SUMMARY_PRINTED=0

# ------------------------------------------------------------
# Hàm tiện ích chung
# ------------------------------------------------------------

have_cmd() { command -v "$1" >/dev/null 2>&1; }

pkg_ok() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -qx "install ok installed"; }

as_user() {
    sudo -u "$REAL_USER" env \
        HOME="$REAL_HOME" \
        XDG_RUNTIME_DIR="/run/user/$REAL_UID" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$REAL_UID/bus" \
        "$@"
}

begin_item() { ITEM_FAIL_BASE=${#FAILED_ITEMS[@]}; }

end_item() {
    if [ "${#FAILED_ITEMS[@]}" -eq "$ITEM_FAIL_BASE" ]; then
        echo -e "   ${GREEN}${BOLD}[HOÀN TẤT]${NC} Không phát sinh lỗi."
    else
        echo -e "   ${YELLOW}${BOLD}[CÓ LỖI]${NC} Một số bước lỗi, xem chi tiết: $LOG_FILE"
    fi
}

run_step() {
    local title="$1"; shift
    echo -e "   ${CYAN}➜ ${title}${NC}"
    if "$@"; then
        return 0
    else
        local rc=$?
        echo -e "     ${RED}[LỖI] thoát mã $rc — xem chi tiết trong $LOG_FILE${NC}"
        FAILED_ITEMS+=("$title")
        return 1
    fi
}

mark_ok()   { echo -e "   ${GREEN}[OK]${NC} $1"; }
mark_skip() { echo -e "   ${YELLOW}[ĐÃ ÁP DỤNG]${NC} $1 — bỏ qua"; }
cancelled() { echo -e "   ${YELLOW}Đã hủy — không có thay đổi nào.${NC}"; }

confirm() {
    local msg="$1"
    read -rp "$msg (y/N): " _ans
    [[ "$_ans" =~ ^[Yy]$ ]]
}

safe_rm_home() {
    local rel="$1"
    local target="$REAL_HOME/$rel"
    if [ -z "$REAL_HOME" ] || [ "$target" = "/" ] || [ "$target" = "$REAL_HOME" ] \
        || [[ "$rel" == *..* ]]; then
        echo -e "   ${RED}TỪ CHỐI xóa đường dẫn không an toàn: '$target'${NC}"
        return 1
    fi
    rm -rf -- "$target"
}

record() {
    mkdir -p "$(dirname "$MANIFEST")"
    echo "$TS|$1|$2|$3|$4" >> "$MANIFEST"
}

print_summary() {
    SUMMARY_PRINTED=1
    echo ""
    echo -e "${BOLD}================ TỔNG KẾT PHIÊN CHẠY ================${NC}"
    if [ "${#FAILED_ITEMS[@]}" -eq 0 ]; then
        echo -e "${GREEN}${BOLD}Không có mục nào lỗi.${NC}"
    else
        echo -e "${RED}${BOLD}Có ${#FAILED_ITEMS[@]} mục bị lỗi:${NC}"
        for it in "${FAILED_ITEMS[@]}"; do
            echo -e "  ${RED}✗${NC} $it"
        done
    fi
    echo -e "Log đầy đủ: ${CYAN}$LOG_FILE${NC}"
}

trap '[ $SUMMARY_PRINTED -eq 0 ] && print_summary' EXIT

# ------------------------------------------------------------
# Kiểm tra môi trường trước khi chạy
# ------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Script cần quyền root để tối ưu hệ thống.${NC}"
    echo -e "Hãy chạy lại bằng lệnh: ${BOLD}sudo bash $0${NC}"
    exit 1
fi

REAL_USER="${SUDO_USER:-}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    echo -e "${RED}Không xác định được user thường (SUDO_USER trống).${NC}"
    echo -e "Đăng nhập bằng user thường rồi chạy: ${BOLD}sudo bash $0${NC}"
    exit 1
fi

REAL_UID="$(id -u "$REAL_USER")"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo -e "${BOLD}User: $REAL_USER | Log: $LOG_FILE${NC}"

mem_total_kb() { awk '/MemTotal/ {print $2}' /proc/meminfo; }
mem_total_gb() { echo $(( $(mem_total_kb) / 1024 / 1024 )); }

# ------------------------------------------------------------
# [1] Chẩn đoán toàn diện (READ-ONLY)
# ------------------------------------------------------------

v_ok()   { echo -e "   ${GREEN}[TỐT]${NC} $1"; }
v_warn() { echo -e "   ${YELLOW}[CẢNH BÁO]${NC} $1"; }
v_bad()  { echo -e "   ${RED}[NGUYÊN NHÂN?]${NC} $1"; }
v_info() { echo -e "   ${CYAN}[INFO]${NC} $1"; }

diag_section() { echo ""; echo -e "${BLUE}${BOLD}--- $1 ---${NC}"; }

diag_all() {
    begin_item
    echo -e "${BLUE}${BOLD}== [1] CHẨN ĐOÁN TOÀN DIỆN (chỉ đọc, không sửa gì) ==${NC}"

    diag_section "Phần cứng & dung lượng"
    if have_cmd lscpu; then
        v_info "CPU: $(lscpu | awk -F': *' '/Model name/ {print $2; exit}')"
    fi
    v_info "RAM: $(mem_total_gb) GB | Swap tổng: $(free -m | awk '/^Swap:/ {print $2}') MB"
    if have_cmd lsblk && have_cmd findmnt; then
        local root_src rota
        root_src="$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')"
        rota="$(lsblk -no ROTA "$root_src" 2>/dev/null | head -n1)"
        if [ "$rota" = "0" ]; then
            v_ok "Ổ chứa hệ điều hành là SSD"
        elif [ "$rota" = "1" ]; then
            v_warn "Ổ HDD cơ khí — chậm hơn SSD rất nhiều khi build Flutter/mở Chrome"
        fi
    fi
    local use_pct
    use_pct="$(df -P / | awk 'NR==2 {gsub("%","",$5); print $5}')"
    if [ "${use_pct:-0}" -ge 90 ]; then
        v_bad "Disk / đã dùng ${use_pct}% — gần đầy làm hệ thống cực chậm → chạy mục [6]"
    elif [ "${use_pct:-0}" -ge 80 ]; then
        v_warn "Disk / đã dùng ${use_pct}% → nên dọn bằng mục [6]"
    else
        v_ok "Disk / còn đủ chỗ (đã dùng ${use_pct}%)"
    fi

    diag_section "Áp lực RAM/Swap (liên quan treo máy, Chrome treo)"
    local swap_total swap_used swappiness_val
    swap_total="$(free -m | awk '/^Swap:/ {print $2}')"
    swap_used="$(free -m | awk '/^Swap:/ {print $3}')"
    swappiness_val="$(sysctl -n vm.swappiness 2>/dev/null || echo 60)"
    if [ "${swap_total:-0}" -gt 0 ] && [ "${swap_used:-0}" -gt $((swap_total*70/100)) ]; then
        v_bad "Swap đang dùng ${swap_used}/${swap_total}MB (>70%) — máy đang thiếu RAM trầm trọng"
        echo -e "   ${YELLOW}  → Chạy mục [2]+[3], cân nhắc tắt bớt app/emulator khi build${NC}"
    elif [ "${swap_total:-0}" -eq 0 ]; then
        v_warn "Máy KHÔNG có swap — khi hết RAM sẽ treo cứng thay vì chậm → chạy mục [3]"
    else
        v_ok "Swap ổn định (${swap_used:-0}/${swap_total:-0}MB)"
    fi
    if [ "${swappiness_val:-60}" -gt 30 ]; then
        v_info "vm.swappiness=${swappiness_val} (mặc định cao) → mục [2] sẽ hạ xuống 10"
    else
        v_ok "vm.swappiness=${swappiness_val} hợp lý"
    fi
    if swapon --show=NAME,TYPE --noheadings 2>/dev/null | grep -qi zram; then
        v_ok "ZRAM đang hoạt động"
    else
        v_info "Chưa có ZRAM → nếu RAM ≤ 16GB nên bật mục [3]"
    fi

    diag_section "Lịch sử hết RAM (OOM) — thủ phạm treo máy kinh điển"
    if have_cmd journalctl; then
        local oom_count oom_last
        oom_count="$(journalctl -k -b --no-pager 2>/dev/null | grep -ciE 'out of memory|oom-kill' || true)"
        if [ "${oom_count:-0}" -gt 0 ]; then
            v_bad "Kernel ĐÃ giết process vì hết RAM ${oom_count} lần trong phiên này!"
            oom_last="$(journalctl -k -b --no-pager 2>/dev/null | grep -iE 'out of memory|oom-kill' | tail -n1)"
            echo -e "   ${YELLOW}  Sự kiện gần nhất: ${oom_last}${NC}"
            echo -e "   ${YELLOW}  → Chạy mục [2]+[3]; xem process nào ăn RAM ở cuối báo cáo này${NC}"
        else
            v_ok "Không có sự kiện hết RAM trong phiên boot hiện tại"
        fi
    fi

    diag_section "Card đồ họa (liên quan treo màn hình, giật giao diện)"
    if have_cmd journalctl; then
        if journalctl -b --no-pager 2>/dev/null | grep -qiE 'llvmpipe|software render'; then
            v_bad "Hệ thống đang RENDER BẰNG PHẦN MỀM (llvmpipe) — thiếu driver card đồ họa!"
            echo -e "   ${YELLOW}  → Giao diện/Chrome rất nặng máy. Cần cài driver GPU đúng hãng:${NC}"
            echo -e "   ${YELLOW}     Intel/AMD: thường có sẵn — kiểm tra 'sudo ubuntu-drivers install'${NC}"
            echo -e "   ${YELLOW}     NVIDIA: 'ubuntu-drivers devices' rồi 'sudo ubuntu-drivers install'${NC}"
        else
            v_ok "Không phát hiện render phần mềm (llvmpipe)"
        fi
    fi

    diag_section "Indexer Tracker (thủ phạm giật lag nền #1)"
    local tracker_procs
    tracker_procs="$(pgrep -u "$REAL_USER" -af 'tracker-miner' 2>/dev/null | wc -l)"
    if [ "${tracker_procs:-0}" -gt 0 ]; then
        v_warn "Tracker indexer đang chạy (${tracker_procs} process) — quét file ngầm liên tục"
        echo -e "   ${YELLOW}  → Chạy mục [4] để tắt${NC}"
    else
        v_ok "Tracker không chạy (hoặc đã tắt)"
    fi

    diag_section "Tiến trình nền khác"
    if pgrep -q -f 'unattended-upgr'; then
        v_info "unattended-upgrades đang chạy — thỉnh thoảng khựng vài giây khi nó tải/cài update là bình thường"
    fi
    if have_cmd fuser; then
        if fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; then
            v_warn "Có tiến trình đang giữ khóa dpkg (đang cài/gỡ gì đó) — đợi xong rồi mới chạy các mục"
        fi
    fi

    diag_section "Dung lượng rác có thể dọn"
    if have_cmd journalctl; then
        v_info "System journal chiếm: $(journalctl --disk-usage 2>/dev/null | awk '{print $7}' || echo '?') — mục [6] giới hạn 200MB"
    fi
    local kcount
    kcount="$(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null | wc -l)"
    if [ "${kcount:-0}" -gt 2 ]; then
        v_warn "Có ${kcount} kernel đang cài — mỗi bản chiếm ~400MB → mục [7] gỡ bản cũ"
    else
        v_ok "Số kernel hợp lý (${kcount})"
    fi
    local snap_old
    snap_old="$(snap list --all 2>/dev/null | awk '$NF ~ /disabled/ {n++} END {print n+0}')"
    if [ "${snap_old:-0}" -gt 0 ]; then
        v_warn "Snap có ${snap_old} phiên bản cũ (disabled) chưa xóa → mục [6]"
    fi
    if [ -d "$REAL_HOME/.cache/thumbnails" ]; then
        v_info "Thumbnail cache: $(du -sh "$REAL_HOME/.cache/thumbnails" 2>/dev/null | cut -f1) — mục [6] xóa"
    fi

    diag_section "Khởi động & dịch vụ lỗi"
    if have_cmd systemd-analyze; then
        v_info "Thời điểm sẵn sàng: $(systemd-analyze 2>/dev/null | head -n1)"
        systemd-analyze blame --no-pager 2>/dev/null | head -n5 | sed 's/^/       /'
    fi
    local failed_units
    failed_units="$(systemctl --failed --no-legend --plain 2>/dev/null | wc -l)"
    if [ "${failed_units:-0}" -gt 0 ]; then
        v_warn "${failed_units} unit systemd đang FAILED:"
        systemctl --failed --no-legend --plain 2>/dev/null | sed 's/^/       /'
    else
        v_ok "Không có unit systemd nào failed"
    fi

    diag_section "Top process hiện tại"
    echo -e "   ${BOLD}CPU:${NC}"
    ps ax -o pid,comm,%cpu --sort=-%cpu --no-headers 2>/dev/null | head -n3 | sed 's/^/       /'
    echo -e "   ${BOLD}RAM:${NC}"
    ps ax -o pid,comm,rss --sort=-rss --no-headers 2>/dev/null | head -n3 \
        | awk '{printf "       %s %s %.1f GB\n", $1, $2, $3/1048576}'
    echo ""
    echo -e "${BOLD}Gợi ý: xử lý theo thứ tự mục được chỉ ra bên trên. Sau mỗi mục chạy lại [1] để kiểm tra.${NC}"
    echo ""
    end_item
}

# ------------------------------------------------------------
# [2] Giảm áp lực RAM/Swap (sysctl drop-in)
# ------------------------------------------------------------

opt_ram_swap() {
    begin_item
    echo -e "${BLUE}${BOLD}== [2] Giảm áp lực RAM/Swap ==${NC}"
    if [ -f "$SYSCTL_TUNING_CONF" ]; then
        mark_skip "File tuning đã tồn tại ($SYSCTL_TUNING_CONF)"
        end_item
        return 0
    fi
    echo -e "   Sẽ tạo drop-in file: ${CYAN}$SYSCTL_TUNING_CONF${NC}"
    echo -e "     • vm.swappiness = 10      (hạn chế swap sớm, giữ app trên RAM)"
    echo -e "     • vm.vfs_cache_pressure = 50  (giữ cache metadata, giảm I/O)"
    echo -e "   Không sửa bất kỳ file gốc nào; hoàn tác = xóa file này."
    if confirm "   Xác nhận áp dụng?"; then
        cat > "$SYSCTL_TUNING_CONF" <<'EOF'
# Tao boi optimize_dev.sh - tinh chinh cho may lap trinh
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
        chmod 644 "$SYSCTL_TUNING_CONF"
        record "ram-swap" "file" "sysctl-tuning" "dropin-created"
        if run_step "sysctl --system (áp dụng)" sysctl --system; then
            local newval
            newval="$(sysctl -n vm.swappiness 2>/dev/null)"
            if [ "$newval" = "10" ]; then
                mark_ok "Đã áp dụng — vm.swappiness hiện = 10"
            else
                echo -e "   ${YELLOW}Cảnh báo: giá trị đọc lại = ${newval:-?} (không phải 10)${NC}"
            fi
        fi
    else
        cancelled
    fi
    end_item
}

# ------------------------------------------------------------
# [3] Bật ZRAM (nén RAM chống treo)
# ------------------------------------------------------------

opt_zram() {
    begin_item
    echo -e "${BLUE}${BOLD}== [3] Bật ZRAM (nén RAM, chống treo khi đầy RAM) ==${NC}"
    if swapon --show=NAME,TYPE --noheadings 2>/dev/null | grep -qi zram; then
        mark_skip "ZRAM đã hoạt động"
        end_item
        return 0
    fi
    local gb
    gb="$(mem_total_gb)"
    if [ "$gb" -gt 16 ]; then
        echo -e "   ${YELLOW}Máy có ${gb}GB RAM (>16GB) — ZRAM ít cần thiết nhưng vẫn có thể bật.${NC}"
    else
        echo -e "   Máy có ${gb}GB RAM — khuyến nghị mạnh nên bật ZRAM."
    fi
    echo -e "   Sẽ thực hiện:"
    echo -e "     • apt-get install zram-tools"
    echo -e "     • systemctl enable --now zramswap"
    echo -e "   Swap trên RAM nén (zstd, ~50% RAM) giúp máy không treo cứng khi đầy RAM."
    if confirm "   Xác nhận bật ZRAM?"; then
        if run_step "apt-get install zram-tools" apt-get install -y zram-tools; then
            record "zram" "pkg" "zram-tools" "installed"
            run_step "systemctl enable --now zramswap" systemctl enable --now zramswap.service
            sleep 1
            if swapon --show=NAME,TYPE --noheadings 2>/dev/null | grep -qi zram; then
                mark_ok "ZRAM đã hoạt động ($(swapon --show=NAME,SIZE --noheadings | grep -i zram | awk '{print $2}' | head -n1))"
            else
                echo -e "   ${YELLOW}Chưa thấy thiết bị zram — có thể cần khởi động lại máy.${NC}"
            fi
        fi
    else
        cancelled
    fi
    end_item
}

# ------------------------------------------------------------
# [4] Tắt Tracker indexer
# ------------------------------------------------------------

opt_tracker() {
    begin_item
    echo -e "${BLUE}${BOLD}== [4] Tắt Tracker indexer (chống quét file ngầm) ==${NC}"
    local units=(tracker-miner-fs-3.service tracker-miner-fs-control-3.service)
    local u state todo=()
    for u in "${units[@]}"; do
        state="$(as_user systemctl --user is-enabled "$u" 2>/dev/null || echo unknown)"
        if [ "$state" != "masked" ]; then
            todo+=("$u")
        fi
    done
    if [ ${#todo[@]} -eq 0 ]; then
        mark_skip "Tracker đã bị tắt từ trước"
        end_item
        return 0
    fi
    echo -e "   Sẽ thực hiện (cho user $REAL_USER):"
    for u in "${todo[@]}"; do
        echo -e "     • systemctl --user mask + stop: ${u}"
    done
    echo -e "     • Xóa cache chỉ mục: ~/.cache/tracker3, ~/.local/share/tracker3"
    echo -e "   ${GREEN}✓ Reversible: hoàn tác sẽ mở khóa về trạng thái cũ${NC}"
    if confirm "   Xác nhận tắt Tracker?"; then
        for u in "${todo[@]}"; do
            state="$(as_user systemctl --user is-enabled "$u" 2>/dev/null || echo unknown)"
            record "tracker" "service" "$u" "$state"
            run_step "mask $u" as_user systemctl --user mask "$u"
            run_step "stop $u" as_user systemctl --user stop "$u"
        done
        if [ -d "$REAL_HOME/.cache/tracker3" ]; then
            run_step "xóa ~/.cache/tracker3" safe_rm_home ".cache/tracker3"
        fi
        if [ -d "$REAL_HOME/.local/share/tracker3" ]; then
            run_step "xóa ~/.local/share/tracker3" safe_rm_home ".local/share/tracker3"
        fi
    else
        cancelled
    fi
    end_item
}

# ------------------------------------------------------------
# [5] Tắt animation GNOME
# ------------------------------------------------------------

opt_animations() {
    begin_item
    echo -e "${BLUE}${BOLD}== [5] Tắt animation GNOME (nhẹ giao diện) ==${NC}"
    local old
    old="$(as_user gsettings get org.gnome.desktop.interface enable-animations 2>/dev/null || echo unknown)"
    if [ "$old" = "false" ]; then
        mark_skip "Animation đã tắt từ trước"
        end_item
        return 0
    fi
    echo -e "   Sẽ đặt org.gnome.desktop.interface enable-animations = false (giá trị cũ: $old)"
    if confirm "   Xác nhận tắt animation?"; then
        if run_step "gsettings set enable-animations false" \
            as_user gsettings set org.gnome.desktop.interface enable-animations false; then
            record "animations" "gsetting" \
                "org.gnome.desktop.interface/enable-animations" "$old"
            mark_ok "Đã tắt — áp dụng ngay, không cần đăng xuất"
        fi
    else
        cancelled
    fi
    end_item
}

# ------------------------------------------------------------
# [6] Dọn dung lượng
# ------------------------------------------------------------

opt_cleanup() {
    begin_item
    echo -e "${BLUE}${BOLD}== [6] Dọn dung lượng (journal, apt, thumbnail, snap cũ) ==${NC}"
    echo -e "   Sẽ thực hiện:"
    echo -e "     • Giới hạn journal 200MB (drop-in) + vacuum ngay"
    echo -e "     • apt-get clean + autoremove --purge"
    echo -e "     • Xóa thumbnail cache của $REAL_USER"
    echo -e "     • snap refresh.retain=2 + xóa các revision disabled"
    if ! confirm "   Xác nhận dọn dẹp?"; then
        cancelled
        end_item
        return 0
    fi

    if [ ! -f "$JOURNALD_CAP_CONF" ]; then
        mkdir -p "$(dirname "$JOURNALD_CAP_CONF")"
        cat > "$JOURNALD_CAP_CONF" <<'EOF'
[Journal]
SystemMaxUse=200M
EOF
        chmod 644 "$JOURNALD_CAP_CONF"
        record "cleanup" "file" "journald-cap" "dropin-created"
        run_step "restart systemd-journald" systemctl restart systemd-journald
    else
        mark_skip "Journal đã giới hạn từ trước"
    fi
    run_step "journalctl --vacuum-size=180M" journalctl --vacuum-size=180M

    run_step "apt-get clean" apt-get clean
    run_step "apt-get autoremove --purge" apt-get autoremove --purge -y

    if [ -d "$REAL_HOME/.cache/thumbnails" ]; then
        run_step "xóa thumbnail cache" safe_rm_home ".cache/thumbnails"
    fi

    if have_cmd snap; then
        local old_retain
        old_retain="$(snap get system refresh.retain 2>/dev/null || echo unset)"
        if [ "$old_retain" != "2" ]; then
            run_step "snap set system refresh.retain=2" snap set system refresh.retain=2
            record "cleanup" "value" "snap-refresh-retain" "$old_retain"
        fi
        local sname srev
        while read -r sname srev; do
            [ -z "$sname" ] && continue
            run_step "snap remove $sname (revision $srev cũ)" snap remove "$sname" --revision="$srev"
        done < <(snap list --all 2>/dev/null | awk '$NF ~ /disabled/ {print $1, $3}')
    fi
    end_item
}

# ------------------------------------------------------------
# [7] Gỡ kernel cũ
# ------------------------------------------------------------

opt_kernels() {
    begin_item
    echo -e "${BLUE}${BOLD}== [7] Gỡ kernel cũ (giữ bản đang chạy + mới nhất) ==${NC}"
    if [ -n "$(dpkg --audit 2>/dev/null)" ]; then
        echo -e "${RED}dpkg đang ở trạng thái chưa hoàn tất (dpkg --audit có cảnh báo) — dừng để tránh hỏng package.${NC}"
        FAILED_ITEMS+=("[7] kernel (dpkg audit)")
        end_item
        return 1
    fi
    local running keep_latest
    running="$(uname -r)"
    mapfile -t ALL_VER < <(dpkg-query -W -f='${Package}\n' 'linux-image-[0-9]*' 2>/dev/null \
        | sed 's/^linux-image-//' | sort -uV)
    if [ ${#ALL_VER[@]} -le 2 ]; then
        mark_skip "Chỉ có ${#ALL_VER[@]} kernel — không có gì để gỡ"
        end_item
        return 0
    fi
    keep_latest="${ALL_VER[$(( ${#ALL_VER[@]} - 1 ))]}"
    local REMOVE_VER=() v
    for v in "${ALL_VER[@]}"; do
        [ "$v" = "$running" ] && continue
        [ "$v" = "$keep_latest" ] && continue
        REMOVE_VER+=("$v")
    done
    if [ ${#REMOVE_VER[@]} -eq 0 ]; then
        mark_skip "Không có kernel cũ nào ngoài bản đang chạy + mới nhất"
        end_item
        return 0
    fi
    local PURGE_PKGS=() base
    for v in "${REMOVE_VER[@]}"; do
        for base in linux-image linux-modules linux-modules-extra linux-headers; do
            if pkg_ok "${base}-${v}"; then
                PURGE_PKGS+=("${base}-${v}")
            fi
        done
    done
    echo -e "   Kernel đang chạy: ${GREEN}${running}${NC} (giữ)"
    echo -e "   Kernel mới nhất : ${GREEN}${keep_latest}${NC} (giữ)"
    echo -e "   ${RED}Sẽ gỡ các bản:${NC} ${REMOVE_VER[*]}"
    echo -e "   Các gói cụ thể:"
    local p
    for p in "${PURGE_PKGS[@]}"; do
        echo -e "     • $p"
    done
    if confirm "   Xác nhận gỡ kernel cũ?"; then
        if run_step "apt-get purge kernel cũ" apt-get purge -y "${PURGE_PKGS[@]}"; then
            for p in "${PURGE_PKGS[@]}"; do
                record "kernel" "pkg" "$p" "$(dpkg-query -W -f='${Version}' "$p" 2>/dev/null)"
            done
        fi
        run_step "apt-get autoremove --purge" apt-get autoremove --purge -y
    else
        cancelled
    fi
    end_item
}

# ------------------------------------------------------------
# [8] Bật fstrim.timer (SSD)
# ------------------------------------------------------------

opt_fstrim() {
    begin_item
    echo -e "${BLUE}${BOLD}== [8] Bật fstrim.timer (duy trì hiệu năng SSD) ==${NC}"
    local rota
    rota="$(lsblk -no ROTA "$(findmnt -no SOURCE / 2>/dev/null | sed 's/\[.*//')" 2>/dev/null | head -n1)"
    if [ "$rota" = "1" ]; then
        echo -e "   ${YELLOW}Ổ hệ điều hành là HDD — fstrim chỉ dành cho SSD, bỏ qua.${NC}"
        end_item
        return 0
    fi
    if systemctl is-enabled fstrim.timer >/dev/null 2>&1 \
        && systemctl is-active fstrim.timer >/dev/null 2>&1; then
        mark_skip "fstrim.timer đã bật"
        end_item
        return 0
    fi
    echo -e "   Sẽ chạy: systemctl enable --now fstrim.timer (trim tự động hàng tuần)"
    if confirm "   Xác nhận bật fstrim?"; then
        run_step "systemctl enable --now fstrim.timer" systemctl enable --now fstrim.timer
        record "fstrim" "service" "fstrim.timer" "was-disabled-or-inactive"
    else
        cancelled
    fi
    end_item
}

# ------------------------------------------------------------
# [H] Hoàn tác
# ------------------------------------------------------------

list_manifest() {
    local n=1 line ts item typ key val
    echo -e "${BOLD}Các thay đổi đã ghi nhận (mới nhất dưới cùng):${NC}"
    while IFS='|' read -r ts item typ key val; do
        printf "  [%2d] %-10s %-8s %s (%s)\n" "$n" "$item" "$typ" "$key" "$val"
        n=$((n+1))
    done < "$MANIFEST"
}

undo_one() {
    local ts="$1" item="$2" typ="$3" key="$4" val="$5"
    case "$typ" in
        file)
            case "$key" in
                sysctl-tuning)
                    run_step "hoàn tác sysctl (xóa drop-in)" rm -f -- "$SYSCTL_TUNING_CONF"
                    run_step "sysctl --system (trở về mặc định)" sysctl --system
                    ;;
                journald-cap)
                    run_step "hoàn tác giới hạn journal (xóa drop-in)" rm -f -- "$JOURNALD_CAP_CONF"
                    run_step "restart systemd-journald" systemctl restart systemd-journald
                    ;;
            esac
            ;;
        gsetting)
            local iface kname
            iface="${key%%/*}"; kname="${key##*/}"
            run_step "hoàn tác gsettings $iface $kname = $val" \
                as_user gsettings set "$iface" "$kname" "$val"
            ;;
        service)
            run_step "unmask $key" as_user systemctl --user unmask "$key"
            case "$val" in
                enabled)  run_step "enable --now $key (trạng thái cũ)" as_user systemctl --user enable --now "$key" ;;
                static|alias|indirect) run_step "start $key (trạng thái cũ)" as_user systemctl --user start "$key" ;;
                *) echo -e "     ${CYAN}Trạng thái cũ '$val' — chỉ unmask, không bật lại.${NC}" ;;
            esac
            ;;
        pkg)
            echo -e "   ${CYAN}➜ Cài lại $key = $val (cần Internet)${NC}"
            run_step "apt-get install $key=$val" apt-get install -y "$key=$val"
            ;;
        value)
            case "$key" in
                snap-refresh-retain)
                    if [ "$val" = "unset" ]; then
                        run_step "snap xóa refresh.retain (về mặc định 3)" snap unset system refresh.retain
                    else
                        run_step "snap set refresh.retain=$val" snap set system refresh.retain="$val"
                    fi
                    ;;
            esac
            ;;
    esac
}

opt_undo() {
    begin_item
    echo -e "${BLUE}${BOLD}== [H] HOÀN TÁC các tinh chỉnh ==${NC}"
    if [ ! -s "$MANIFEST" ]; then
        echo -e "${YELLOW}Manifest trống — chưa có thay đổi nào để hoàn tác.${NC}"
        end_item
        return 0
    fi
    list_manifest
    echo ""
    read -rp "Nhập SỐ THỨ TỰ cần hoàn tác (nhiều số cách nhau, 'all' = hết, Enter = hủy): " ans
    [ -z "$ans" ] && { cancelled; end_item; return 0; }

    local total
    total="$(wc -l < "$MANIFEST")"
    local nums=()
    if [ "$ans" = "all" ]; then
        local i
        for ((i=total; i>=1; i--)); do nums+=("$i"); done
    else
        local n
        for n in $ans; do
            if [[ ! "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "$total" ]; then
                echo -e "${RED}Số không hợp lệ: $n — bỏ qua.${NC}"
                continue
            fi
            nums+=("$n")
        done
    fi
    if [ ${#nums[@]} -eq 0 ]; then
        cancelled
        end_item
        return 0
    fi
    if ! confirm "Xác nhận hoàn tác ${#nums[@]} thay đổi?"; then
        cancelled
        end_item
        return 0
    fi

    mapfile -t nums < <(printf '%s\n' "${nums[@]}" | sort -rn)
    for n in "${nums[@]}"; do
        local line ts item typ key val
        line="$(sed -n "${n}p" "$MANIFEST")"
        IFS='|' read -r ts item typ key val <<< "$line"
        echo -e "\n${BOLD}Hoàn tác [$n]: $item / $typ / $key${NC}"
        undo_one "$ts" "$item" "$typ" "$key" "$val"
        sed -i "${n}d" "$MANIFEST"
    done
    end_item
}

# ------------------------------------------------------------
# Menu chính
# ------------------------------------------------------------

show_menu() {
    clear
    echo ""
    echo -e "${BOLD}${BLUE}=============================================================${NC}"
    echo -e "${BOLD}${BLUE}   CÔNG CỤ CHẨN ĐOÁN & TỐI ƯU AN TOÀN — UBUNTU DESKTOP${NC}"
    echo -e "${BOLD}${BLUE}   User: $REAL_USER | RAM: $(mem_total_gb)GB${NC}"
    echo -e "${BOLD}${BLUE}=============================================================${NC}"
    echo ""
    echo -e "   ${GREEN}[1]${NC}  CHẨN ĐOÁN toàn diện (read-only — hãy chạy mục này trước!)"
    echo ""
    echo -e "  ${BOLD}--- TỐI ƯU ---${NC}"
    echo -e "   ${GREEN}[2]${NC}  Giảm áp lực RAM/Swap (swappiness=10)"
    echo -e "   ${GREEN}[3]${NC}  Bật ZRAM (nén RAM — chữa treo do hết RAM)"
    echo -e "   ${GREEN}[4]${NC}  Tắt Tracker indexer (quét file ngầm)"
    echo -e "   ${GREEN}[5]${NC}  Tắt animation GNOME"
    echo -e "   ${GREEN}[6]${NC}  Dọn dung lượng (journal/apt/thumbnail/snap cũ)"
    echo -e "   ${GREEN}[7]${NC}  Gỡ kernel cũ (giữ bản đang chạy + mới nhất)"
    echo -e "   ${GREEN}[8]${NC}  Bật fstrim.timer (SSD)"
    echo ""
    echo -e "   ${GREEN}[H]${NC}  HOÀN TÁC các tinh chỉnh đã áp dụng"
    echo -e "   ${GREEN}[0]${NC}  Thoát"
    echo ""
}

pause_enter() {
    echo ""
    read -rp "Nhấn Enter để quay lại menu..." _
}

main_loop() {
    while true; do
        show_menu
        read -rp "Chọn mục: " choice
        case "$choice" in
            1)  diag_all;       pause_enter ;;
            2)  opt_ram_swap;   pause_enter ;;
            3)  opt_zram;       pause_enter ;;
            4)  opt_tracker;    pause_enter ;;
            5)  opt_animations; pause_enter ;;
            6)  opt_cleanup;    pause_enter ;;
            7)  opt_kernels;    pause_enter ;;
            8)  opt_fstrim;     pause_enter ;;
            [hH]) opt_undo;     pause_enter ;;
            0)  print_summary; exit 0 ;;
            "") ;;
            *)  echo -e "${RED}Lựa chọn không hợp lệ!${NC}"; sleep 1 ;;
        esac
    done
}

main_loop
