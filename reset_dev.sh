#!/bin/bash
# ============================================================
# reset_dev.sh — Gỡ sạch môi trường lập trình đã cài bởi setup_dev.sh
# Đưa máy về trạng thái mặc định như OS mới cài (KHÔNG đụng data)
# Cách dùng: sudo bash reset_dev.sh
# ============================================================

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/reset_$TS.log"

FAILED_ITEMS=()
ITEM_FAIL_BASE=0
SUMMARY_PRINTED=0

# ------------------------------------------------------------
# Hàm tiện ích chung
# ------------------------------------------------------------

have_cmd() { command -v "$1" >/dev/null 2>&1; }

pkg_ok() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -qx "install ok installed"; }

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
mark_skip() { echo -e "   ${YELLOW}[ĐÃ SẠCH]${NC} $1 — bỏ qua"; }

cancelled() { echo -e "   ${YELLOW}Đã hủy — không có thay đổi nào.${NC}"; }

confirm() {
    local msg="$1"
    read -rp "$msg (y/N): " _ans
    [[ "$_ans" =~ ^[Yy]$ ]]
}

print_summary() {
    SUMMARY_PRINTED=1
    echo ""
    echo -e "${BOLD}================ TỔNG KẾT PHIÊN RESET ================${NC}"
    if [ "${#FAILED_ITEMS[@]}" -eq 0 ]; then
        echo -e "${GREEN}${BOLD}Không có mục nào lỗi. Máy đã về trạng thái sạch!${NC}"
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
    echo -e "${RED}Script cần quyền root để gỡ cài đặt.${NC}"
    echo -e "Hãy chạy lại bằng lệnh: ${BOLD}sudo bash $0${NC}"
    exit 1
fi

REAL_USER="${SUDO_USER:-}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    echo -e "${RED}Không xác định được user thường (SUDO_USER trống).${NC}"
    echo -e "Đăng nhập bằng user thường rồi chạy: ${BOLD}sudo bash $0${NC}"
    exit 1
fi

REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo -e "${RED}${BOLD}CẢNH BÁO: Script sẽ GỠ các ứng dụng lập trình và XÓA cấu hình/dữ liệu của chúng${NC}"
echo -e "${RED}(settings VS Code, profile Chrome, cache Flutter/Android...). KHÔNG đụng tới:${NC}"
echo -e "${GREEN}  ✓ Mọi project trong /var/www/html${NC}"
echo -e "${GREEN}  ✓ Documents, code, dotfile cá nhân ngoài những dòng do NVM/Flutter thêm vào .bashrc/.profile${NC}"

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

filter_rc_lines() {
    local awkprog="$1"; shift
    local f
    for f in "$@"; do
        [ -f "$f" ] || continue
        local tmp
        tmp="$(mktemp "$f.resetXXXXXX")"
        chown --reference="$f" "$tmp" 2>/dev/null
        chmod --reference="$f" "$tmp" 2>/dev/null
        awk "$awkprog" "$f" > "$tmp" && mv "$tmp" "$f"
    done
}

RC_FILES=("$REAL_HOME/.bashrc" "$REAL_HOME/.profile" "$REAL_HOME/.bash_profile")

# ------------------------------------------------------------
# [1] Gỡ Git
# ------------------------------------------------------------

reset_git() {
    begin_item
    echo -e "${BLUE}${BOLD}== [1] Gỡ Git ==${NC}"
    if ! pkg_ok git; then
        mark_skip "Git chưa cài"
        end_item
        return 0
    fi
    echo -e "   Sẽ thực hiện:"
    echo -e "     • apt-get purge git git-man"
    echo -e "     • apt-get autoremove --purge"
    if confirm "   Xác nhận gỡ Git?"; then
        run_step "apt-get purge git" apt-get purge -y git git-man
        run_step "apt-get autoremove --purge" apt-get autoremove --purge -y
    else
        cancelled
    fi
    end_item
}

# ------------------------------------------------------------
# [2] Gỡ Apache2
# ------------------------------------------------------------

reset_apache() {
    begin_item
    echo -e "${BLUE}${BOLD}== [2] Gỡ Apache2 (về trạng thái chưa từng cài) ==${NC}"
    if ! pkg_ok apache2 && [ ! -d /etc/apache2 ]; then
        mark_skip "Apache2 chưa cài"
        end_item
        return 0
    fi
    echo -e "   Sẽ thực hiện:"
    echo -e "     • apt-get purge apache2 apache2-bin apache2-data apache2-utils"
    echo -e "     • Xóa /etc/apache2 (gồm 000-default.conf đã sửa + file backup)"
    echo -e "     • Xóa /var/log/apache2"
    echo -e "   ${GREEN}✓ /var/www/html KHÔNG bị động đến${NC}"
    if confirm "   Xác nhận gỡ Apache2?"; then
        run_step "apt-get purge apache2" \
            apt-get purge -y apache2 apache2-bin apache2-data apache2-utils
        run_step "xóa /etc/apache2 còn sót" rm -rf -- /etc/apache2
        run_step "xóa /var/log/apache2 còn sót" rm -rf -- /var/log/apache2
        run_step "apt-get autoremove --purge" apt-get autoremove --purge -y
    else
        cancelled
    fi
    end_item
}

# ------------------------------------------------------------
# [3] Gỡ PHP + extensions
# ------------------------------------------------------------

reset_php() {
    begin_item
    echo -e "${BLUE}${BOLD}== [3] Gỡ PHP + toàn bộ extension ==${NC}"
    local PHP_PKGS=()
    mapfile -t PHP_PKGS < <(dpkg-query -W -f='${Package}\n' 2>/dev/null \
        | grep -E '^(php|libapache2-mod-php)' || true)
    if [ ${#PHP_PKGS[@]} -eq 0 ]; then
        mark_skip "PHP chưa cài"
        end_item
        return 0
    fi
    echo -e "   Các gói PHP sẽ bị purge (${#PHP_PKGS[@]}):"
    local p
    for p in "${PHP_PKGS[@]}"; do
        echo -e "     • $p"
    done
    echo -e "     • apt-get autoremove --purge"
    if confirm "   Xác nhận gỡ PHP?"; then
        run_step "apt-get purge các gói PHP" apt-get purge -y "${PHP_PKGS[@]}"
        if pkg_ok apache2 && systemctl is-active --quiet apache2; then
            run_step "restart apache2 (sau khi bỏ module PHP)" systemctl restart apache2
        fi
        run_step "apt-get autoremove --purge" apt-get autoremove --purge -y
    else
        cancelled
    fi
    end_item
}

# ------------------------------------------------------------
# [4] Gỡ NVM + Node.js
# ------------------------------------------------------------

reset_nvm() {
    begin_item
    echo -e "${BLUE}${BOLD}== [4] Gỡ NVM + Node.js (cho user $REAL_USER) ==${NC}"
    local has_nvm_dir=0 has_rc=0 f
    [ -d "$REAL_HOME/.nvm" ] && has_nvm_dir=1
    for f in "${RC_FILES[@]}"; do
        [ -f "$f" ] && grep -qE 'NVM_DIR|nvm\.sh' "$f" && has_rc=1
    done
    if [ $has_nvm_dir -eq 0 ] && [ $has_rc -eq 0 ]; then
        mark_skip "NVM/Node.js chưa cài"
        end_item
        return 0
    fi
    echo -e "   Sẽ thực hiện:"
    [ $has_nvm_dir -eq 1 ] && echo -e "     • Xóa ~/.nvm (toàn bộ version Node.js bên trong) và ~/.npm"
    [ $has_rc -eq 1 ] && echo -e "     • Lọc đúng dòng khởi tạo NVM khỏi .bashrc/.profile (dòng khác giữ nguyên)"
    if confirm "   Xác nhận gỡ NVM + Node.js?"; then
        if [ $has_nvm_dir -eq 1 ]; then
            run_step "xóa ~/.nvm" safe_rm_home ".nvm"
            run_step "xóa ~/.npm" safe_rm_home ".npm"
        fi
        if [ $has_rc -eq 1 ]; then
            # shellcheck disable=SC2016
            run_step "dọn dòng NVM trong rc-files" filter_rc_lines \
                'index($0,"NVM_DIR")==0 && index($0,"nvm.sh")==0' "${RC_FILES[@]}"
        fi
    else
        cancelled
    fi
    end_item
}

# ------------------------------------------------------------
# [5] Gỡ VS Code
# ------------------------------------------------------------

reset_vscode() {
    begin_item
    echo -e "${BLUE}${BOLD}== [5] Gỡ Visual Studio Code ==${NC}"
    if ! pkg_ok code && [ ! -d "$REAL_HOME/.vscode" ] && [ ! -d "$REAL_HOME/.config/Code" ]; then
        mark_skip "VS Code chưa cài"
        end_item
        return 0
    fi
    echo -e "   Sẽ thực hiện:"
    pkg_ok code && echo -e "     • apt-get purge code"
    echo -e "     • Xóa ~/.vscode (extensions) và ~/.config/Code (settings) — ${RED}mất toàn bộ settings/extensions${NC}"
    if confirm "   Xác nhận gỡ VS Code?"; then
        if pkg_ok code; then
            run_step "apt-get purge code" apt-get purge -y code
            run_step "apt-get autoremove --purge" apt-get autoremove --purge -y
        fi
        run_step "xóa ~/.vscode" safe_rm_home ".vscode"
        run_step "xóa ~/.config/Code" safe_rm_home ".config/Code"
    else
        cancelled
    fi
    end_item
}

# ------------------------------------------------------------
# [6] Gỡ Google Chrome
# ------------------------------------------------------------

reset_chrome() {
    begin_item
    echo -e "${BLUE}${BOLD}== [6] Gỡ Google Chrome ==${NC}"
    if ! pkg_ok google-chrome-stable && [ ! -d "$REAL_HOME/.config/google-chrome" ]; then
        mark_skip "Google Chrome chưa cài"
        end_item
        return 0
    fi
    echo -e "   Sẽ thực hiện:"
    pkg_ok google-chrome-stable && echo -e "     • apt-get purge google-chrome-stable"
    echo -e "     • Xóa ~/.config/google-chrome và ~/.cache/google-chrome — ${RED}mất bookmarks/history/extensions${NC}"
    if confirm "   Xác nhận gỡ Chrome?"; then
        if pkg_ok google-chrome-stable; then
            run_step "apt-get purge google-chrome-stable" apt-get purge -y google-chrome-stable
            run_step "apt-get autoremove --purge" apt-get autoremove --purge -y
        fi
        run_step "xóa ~/.config/google-chrome" safe_rm_home ".config/google-chrome"
        run_step "xóa ~/.cache/google-chrome" safe_rm_home ".cache/google-chrome"
    else
        cancelled
    fi
    end_item
}

# ------------------------------------------------------------
# [7] Gỡ Vim (giữ vim-tiny như OS mới)
# ------------------------------------------------------------

reset_vim() {
    begin_item
    echo -e "${BLUE}${BOLD}== [7] Gỡ Vim (OS mới chỉ có sẵn vim-tiny) ==${NC}"
    local VPKGS=()
    pkg_ok vim           && VPKGS+=("vim")
    pkg_ok vim-runtime   && VPKGS+=("vim-runtime")
    pkg_ok vim-gtk3      && VPKGS+=("vim-gtk3")
    pkg_ok vim-gui-common && VPKGS+=("vim-gui-common")
    if [ ${#VPKGS[@]} -eq 0 ]; then
        mark_skip "Không có bản Vim đầy đủ nào (đúng trạng thái OS mới)"
        end_item
        return 0
    fi
    echo -e "   Sẽ thực hiện:"
    local p
    for p in "${VPKGS[@]}"; do
        echo -e "     • apt-get purge $p"
    done
    echo -e "   ${GREEN}✓ Giữ nguyên vim-tiny, vim-common (mặc định của Ubuntu Desktop)${NC}"
    if confirm "   Xác nhận gỡ Vim?"; then
        run_step "apt-get purge các gói Vim" apt-get purge -y "${VPKGS[@]}"
        run_step "apt-get autoremove --purge" apt-get autoremove --purge -y
    else
        cancelled
    fi
    end_item
}

# ------------------------------------------------------------
# [8] Gỡ Meld
# ------------------------------------------------------------

reset_meld() {
    begin_item
    echo -e "${BLUE}${BOLD}== [8] Gỡ Meld ==${NC}"
    if ! pkg_ok meld; then
        mark_skip "Meld chưa cài"
        end_item
        return 0
    fi
    echo -e "   Sẽ thực hiện:"
    echo -e "     • apt-get purge meld"
    echo -e "     • apt-get autoremove --purge"
    if confirm "   Xác nhận gỡ Meld?"; then
        run_step "apt-get purge meld" apt-get purge -y meld
        run_step "apt-get autoremove --purge" apt-get autoremove --purge -y
    else
        cancelled
    fi
    end_item
}

# ------------------------------------------------------------
# [9] Gỡ IBus Bamboo (giữ nguyên ibus hệ thống)
# ------------------------------------------------------------

reset_ibus_bamboo() {
    begin_item
    echo -e "${BLUE}${BOLD}== [9] Gỡ IBus Bamboo + PPA (giữ ibus hệ thống) ==${NC}"
    local has_pkg=0 has_ppa=0
    pkg_ok ibus-bamboo && has_pkg=1
    ls /etc/apt/sources.list.d/*bamboo* >/dev/null 2>&1 && has_ppa=1
    if [ $has_pkg -eq 0 ] && [ $has_ppa -eq 0 ]; then
        mark_skip "IBus Bamboo chưa cài"
        end_item
        return 0
    fi
    echo -e "   Sẽ thực hiện:"
    [ $has_pkg -eq 1 ] && echo -e "     • apt-get purge ibus-bamboo"
    echo -e "     • Gỡ PPA bamboo-engine khỏi sources.list.d / trusted.gpg.d / preferences.d"
    echo -e "     • apt-get update"
    echo -e "   ${GREEN}✓ Không đụng tới bộ gõ ibus gốc của hệ thống${NC}"
    if confirm "   Xác nhận gỡ IBus Bamboo?"; then
        if [ $has_pkg -eq 1 ]; then
            run_step "apt-get purge ibus-bamboo" apt-get purge -y ibus-bamboo
        fi
        have_cmd add-apt-repository && \
            run_step "add-apt-repository -r (gỡ PPA)" \
                add-apt-repository -r -y ppa:bamboo-engine/ibus-bamboo
        run_step "dọn file PPA còn sót" bash -c \
            'rm -f /etc/apt/sources.list.d/*bamboo* /etc/apt/trusted.gpg.d/*bamboo* /etc/apt/preferences.d/*bamboo*; exit 0'
        run_step "apt-get update" apt-get update
        echo ""
        echo -e "   ${YELLOW}Ghi chú: nếu trong Settings → Keyboard → Input Sources vẫn còn tên"
        echo -e "   'Vietnamese (Bamboo)', hãy chọn nó và nhấn '-' để xóa thủ công (vô hại nếu để).${NC}"
        echo ""
    else
        cancelled
    fi
    end_item
}

# ------------------------------------------------------------
# [10] Gỡ Flutter SDK
# ------------------------------------------------------------

reset_flutter() {
    begin_item
    echo -e "${BLUE}${BOLD}== [10] Gỡ Flutter SDK (cho user $REAL_USER) ==${NC}"
    local flutter_dir="$REAL_HOME/development/flutter"
    local has_sdk=0 has_rc=0 has_cache=0 f
    [ -d "$flutter_dir" ] && has_sdk=1
    for f in "${RC_FILES[@]}"; do
        [ -f "$f" ] && grep -q 'development/flutter/bin' "$f" && has_rc=1
    done
    if [ -d "$REAL_HOME/.pub-cache" ] || [ -d "$REAL_HOME/.dart" ] || \
        [ -d "$REAL_HOME/.dart-tool" ] || [ -d "$REAL_HOME/.config/flutter" ]; then
        has_cache=1
    fi
    if [ $has_sdk -eq 0 ] && [ $has_rc -eq 0 ] && [ $has_cache -eq 0 ]; then
        mark_skip "Flutter chưa cài"
        end_item
        return 0
    fi
    echo -e "   Sẽ thực hiện:"
    [ $has_sdk -eq 1 ] && echo -e "     • Xóa ~/development/flutter (SDK)"
    [ $has_rc -eq 1 ] && echo -e "     • Lọc dòng PATH của Flutter khỏi .bashrc/.profile"
    [ $has_cache -eq 1 ] && echo -e "     • Xóa cache: ~/.pub-cache, ~/.dart, ~/.dart-tool, ~/.config/flutter"
    if confirm "   Xác nhận gỡ Flutter SDK?"; then
        if [ $has_sdk -eq 1 ]; then
            run_step "xóa ~/development/flutter" safe_rm_home "development/flutter"
            rmdir "$REAL_HOME/development" 2>/dev/null || true
        fi
        if [ $has_rc -eq 1 ]; then
            # shellcheck disable=SC2016
            run_step "dọn dòng PATH Flutter trong rc-files" filter_rc_lines \
                'index($0,"development/flutter/bin")==0' "${RC_FILES[@]}"
        fi
        if [ $has_cache -eq 1 ]; then
            run_step "xóa ~/.pub-cache" safe_rm_home ".pub-cache"
            run_step "xóa ~/.dart" safe_rm_home ".dart"
            run_step "xóa ~/.dart-tool" safe_rm_home ".dart-tool"
            run_step "xóa ~/.config/flutter" safe_rm_home ".config/flutter"
        fi
    else
        cancelled
    fi
    end_item
}

# ------------------------------------------------------------
# [11] Gỡ Android Studio
# ------------------------------------------------------------

reset_android_studio() {
    begin_item
    echo -e "${BLUE}${BOLD}== [11] Gỡ Android Studio ==${NC}"
    local has_snap=0 has_data=0
    have_cmd snap && snap list android-studio >/dev/null 2>&1 && has_snap=1
    if [ -d "$REAL_HOME/Android" ] || [ -d "$REAL_HOME/.android" ] || \
        [ -d "$REAL_HOME/.gradle" ] || [ -d "$REAL_HOME/snap/android-studio" ]; then
        has_data=1
    fi
    if [ $has_snap -eq 0 ] && [ $has_data -eq 0 ]; then
        mark_skip "Android Studio chưa cài"
        end_item
        return 0
    fi
    echo -e "   Sẽ thực hiện:"
    [ $has_snap -eq 1 ] && echo -e "     • snap remove android-studio"
    echo -e "     • Xóa ~/snap/android-studio, ~/Android (SDK+AVD), ~/.android, ~/.gradle"
    echo -e "       ${RED}Mất toàn bộ Android SDK, máy ảo AVD, Gradle cache (có thể tải lại sau)${NC}"
    if confirm "   Xác nhận gỡ Android Studio?"; then
        if [ $has_snap -eq 1 ]; then
            run_step "snap remove android-studio" snap remove android-studio
        fi
        run_step "xóa ~/snap/android-studio" safe_rm_home "snap/android-studio"
        run_step "xóa ~/Android (SDK/AVD)" safe_rm_home "Android"
        run_step "xóa ~/.android" safe_rm_home ".android"
        run_step "xóa ~/.gradle" safe_rm_home ".gradle"
    else
        cancelled
    fi
    end_item
}

# ------------------------------------------------------------
# [12] Dọn Virtual Host (*.test)
# ------------------------------------------------------------

reset_vhosts() {
    begin_item
    echo -e "${BLUE}${BOLD}== [12] Dọn Virtual Host (*.test) ==${NC}"

    VH_SITES=()
    VH_DOMAINS=()
    shopt -s nullglob
    for c in /etc/apache2/sites-available/*.conf; do
        local site domain
        site="$(basename "$c" .conf)"
        domain="$(awk '/^[[:space:]]*ServerName[[:space:]]+/ {print $2; exit}' "$c")"
        if [[ "$domain" == *.test ]]; then
            VH_SITES+=("$site")
            VH_DOMAINS+=("$domain")
        fi
    done
    shopt -u nullglob

    local hosts_test_count=0
    if [ -f /etc/hosts ]; then
        hosts_test_count=$(grep -cE '^127\.0\.0\.1[[:space:]]+[A-Za-z0-9._-]+\.test([[:space:]]|$)' /etc/hosts || true)
    fi

    if [ ${#VH_DOMAINS[@]} -eq 0 ] && [ "$hosts_test_count" -eq 0 ]; then
        mark_skip "Không còn virtual host *.test nào"
        end_item
        return 0
    fi

    echo -e "   Phát hiện:"
    local i
    for i in "${!VH_DOMAINS[@]}"; do
        echo -e "     • Vhost: ${VH_DOMAINS[$i]} (/etc/apache2/sites-available/${VH_SITES[$i]}.conf)"
    done
    [ "$hosts_test_count" -gt 0 ] && echo -e "     • $hosts_test_count dòng '*.test' trong /etc/hosts"
    if confirm "   Xác nhận dọn Virtual Host?"; then
        for i in "${!VH_DOMAINS[@]}"; do
            run_step "a2dissite ${VH_SITES[$i]}" a2dissite "${VH_SITES[$i]}"
            run_step "xóa file conf ${VH_SITES[$i]}.conf" \
                rm -f -- "/etc/apache2/sites-available/${VH_SITES[$i]}.conf"
        done
        if [ ${#VH_DOMAINS[@]} -gt 0 ] && pkg_ok apache2 && systemctl is-active --quiet apache2; then
            if apachectl configtest; then
                run_step "reload apache2" systemctl reload apache2
            else
                apachectl configtest
                FAILED_ITEMS+=("[12] configtest sau khi dọn vhost")
            fi
        fi
        if [ "$hosts_test_count" -gt 0 ]; then
            local tmp
            tmp="$(mktemp /etc/hosts.resetXXXXXX)"
            chown --reference=/etc/hosts "$tmp" 2>/dev/null
            chmod --reference=/etc/hosts "$tmp" 2>/dev/null
            awk '!/^127\.0\.0\.1[[:space:]]+[A-Za-z0-9._-]+\.test([[:space:]]|$)/' /etc/hosts > "$tmp"
            echo -e "   ${CYAN}Các dòng sẽ bị gỡ khỏi /etc/hosts:${NC}"
            diff --old-line-format=' • %L' --new-line-format='' --unchanged-line-format='' \
                /etc/hosts "$tmp" || true
            run_step "gỡ dòng *.test khỏi /etc/hosts" mv "$tmp" /etc/hosts
        fi
    else
        cancelled
    fi
    end_item
}

# ------------------------------------------------------------
# [13] RESET TẤT CẢ
# ------------------------------------------------------------

reset_all() {
    begin_item
    echo -e "${BLUE}${BOLD}== [13] RESET TẤT CẢ (mục 1→12) ==${NC}"
    echo -e "${RED}${BOLD}Toàn bộ ứng dụng lập trình sẽ bị gỡ, mọi cấu hình về mặc định như OS mới.${NC}"
    echo -e "${RED}Settings/extensions VS Code, profile Chrome, SDK/AVD Android sẽ bị XÓA.${NC}"
    echo -e "${GREEN}/var/www/html và dữ liệu cá nhân được bảo toàn.${NC}"
    if ! confirm "   Bạn THẬT SỰ muốn reset tất cả?"; then
        cancelled
        end_item
        return 0
    fi
    reset_git
    reset_apache
    reset_php
    reset_nvm
    reset_vscode
    reset_chrome
    reset_vim
    reset_meld
    reset_ibus_bamboo
    reset_flutter
    reset_android_studio
    reset_vhosts
    end_item
}

# ------------------------------------------------------------
# Menu chính
# ------------------------------------------------------------

show_menu() {
    clear
    echo ""
    echo -e "${BOLD}${BLUE}=============================================================${NC}"
    echo -e "${BOLD}${BLUE}   CÔNG CỤ RESET MÔI TRƯỜNG LẬP TRÌNH — VỀ TRẠNG THÁI MÁY MỚI${NC}"
    echo -e "${BOLD}${BLUE}   User: $REAL_USER${NC}"
    echo -e "${BOLD}${BLUE}=============================================================${NC}"
    echo ""
    echo -e "  ${BOLD}--- HỆ THỐNG & WEB SERVER ---${NC}"
    echo -e "   ${GREEN}[1]${NC}  Gỡ Git"
    echo -e "   ${GREEN}[2]${NC}  Gỡ Apache2 (xóa sạch /etc/apache2 về mặc định)"
    echo -e "   ${GREEN}[3]${NC}  Gỡ PHP + mọi extension"
    echo ""
    echo -e "  ${BOLD}--- NODE.JS ---${NC}"
    echo -e "   ${GREEN}[4]${NC}  Gỡ NVM + Node.js (xóa ~/.nvm + dọn .bashrc)"
    echo ""
    echo -e "  ${BOLD}--- ỨNG DỤNG LẬP TRÌNH ---${NC}"
    echo -e "   ${GREEN}[5]${NC}  Gỡ Visual Studio Code (kèm settings/extensions)"
    echo -e "   ${GREEN}[6]${NC}  Gỡ Google Chrome (kèm profile)"
    echo -e "   ${GREEN}[7]${NC}  Gỡ Vim (về vim-tiny như OS mới)"
    echo -e "   ${GREEN}[8]${NC}  Gỡ Meld"
    echo -e "   ${GREEN}[9]${NC}  Gỡ IBus Bamboo + PPA (giữ ibus hệ thống)"
    echo ""
    echo -e "  ${BOLD}--- FLUTTER / ANDROID ---${NC}"
    echo -e "   ${GREEN}[10]${NC} Gỡ Flutter SDK (+ cache ~/.pub-cache...)"
    echo -e "   ${GREEN}[11]${NC} Gỡ Android Studio (+ ~/Android/Sdk, ~/.gradle, AVD)"
    echo ""
    echo -e "  ${BOLD}--- KHÁC ---${NC}"
    echo -e "   ${GREEN}[12]${NC} Dọn Virtual Host (*.test) khỏi /etc/hosts + sites-available"
    echo -e "   ${GREEN}[13]${NC} RESET TẤT CẢ mục [1]→[12]"
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
        read -rp "Chọn mục [0-13]: " choice
        case "$choice" in
            1)  reset_git;           pause_enter ;;
            2)  reset_apache;        pause_enter ;;
            3)  reset_php;           pause_enter ;;
            4)  reset_nvm;           pause_enter ;;
            5)  reset_vscode;        pause_enter ;;
            6)  reset_chrome;        pause_enter ;;
            7)  reset_vim;           pause_enter ;;
            8)  reset_meld;          pause_enter ;;
            9)  reset_ibus_bamboo;   pause_enter ;;
            10) reset_flutter;       pause_enter ;;
            11) reset_android_studio; pause_enter ;;
            12) reset_vhosts;        pause_enter ;;
            13) reset_all;           pause_enter ;;
            0)  print_summary; exit 0 ;;
            "") ;;
            *)  echo -e "${RED}Lựa chọn không hợp lệ!${NC}"; sleep 1 ;;
        esac
    done
}

main_loop
