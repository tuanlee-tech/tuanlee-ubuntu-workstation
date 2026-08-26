#!/bin/bash
# ============================================================
# setup_dev.sh — Cài đặt môi trường lập trình cho Ubuntu Desktop
# Cách dùng: sudo bash setup_dev.sh
# ============================================================

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/setup_$TS.log"

WWW_ROOT="/var/www/html"
APACHE_DEFAULT_CONF="/etc/apache2/sites-available/000-default.conf"
NVM_VERSION="v0.40.3"
NVM_SH=""
FLUTTER_DIR=""

FAILED_ITEMS=()
ITEM_FAIL_BASE=0
SUMMARY_PRINTED=0

# ------------------------------------------------------------
# Hàm tiện ích chung
# ------------------------------------------------------------

have_cmd() { command -v "$1" >/dev/null 2>&1; }

pkg_ok() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -qx "install ok installed"; }

as_user() { sudo -u "$REAL_USER" env HOME="$REAL_HOME" "$@"; }

begin_item() { ITEM_FAIL_BASE=${#FAILED_ITEMS[@]}; }

end_item() {
    if [ "${#FAILED_ITEMS[@]}" -eq "$ITEM_FAIL_BASE" ]; then
        echo -e "   ${GREEN}${BOLD}[HOÀN TẤT]${NC} Mục này cài đặt thành công."
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
mark_skip() { echo -e "   ${YELLOW}[ĐÃ CÀI]${NC} $1 — bỏ qua"; }

print_summary() {
    SUMMARY_PRINTED=1
    echo ""
    echo -e "${BOLD}================ TỔNG KẾT PHIÊN CHẠY ================${NC}"
    if [ "${#FAILED_ITEMS[@]}" -eq 0 ]; then
        echo -e "${GREEN}${BOLD}Không có mục nào lỗi. Hoàn tất!${NC}"
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
    echo -e "${RED}Script cần quyền root để cài đặt.${NC}"
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
REAL_GROUP="$(id -gn "$REAL_USER")"
NVM_SH="$REAL_HOME/.nvm/nvm.sh"
FLUTTER_DIR="$REAL_HOME/development/flutter"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo -e "${BOLD}User: $REAL_USER | Home: $REAL_HOME | Log: $LOG_FILE${NC}"

if ! curl -fsSI --max-time 8 https://www.google.com >/dev/null 2>&1; then
    echo -e "${YELLOW}[CẢNH BÁO] Có vẻ máy chưa có Internet — các mục tải về sẽ thất bại.${NC}"
fi

if ! have_cmd curl; then
    apt-get update -qq
    apt-get install -y curl
fi

# ------------------------------------------------------------
# [1] Cập nhật hệ thống
# ------------------------------------------------------------

item_update() {
    begin_item
    echo -e "${BLUE}${BOLD}== [1] Cập nhật hệ thống ==${NC}"
    run_step "apt-get update" apt-get update
    run_step "apt-get upgrade" apt-get upgrade -y
    end_item
}

# ------------------------------------------------------------
# [2] Git
# ------------------------------------------------------------

item_git() {
    begin_item
    echo -e "${BLUE}${BOLD}== [2] Cài Git ==${NC}"
    if have_cmd git; then
        mark_skip "Git đã có sẵn ($(git --version))"
    else
        if run_step "apt-get install git" apt-get install -y git; then
            mark_ok "Đã cài $(git --version)"
        fi
    fi
    end_item
}

# ------------------------------------------------------------
# [3] Apache2 + mod_rewrite
# ------------------------------------------------------------

item_apache() {
    begin_item
    echo -e "${BLUE}${BOLD}== [3] Cài Apache2 ==${NC}"
    if pkg_ok apache2; then
        mark_skip "apache2 đã có sẵn"
    else
        run_step "apt-get install apache2" apt-get install -y apache2
    fi
    run_step "a2enmod rewrite" a2enmod rewrite
    run_step "systemctl enable --now apache2" systemctl enable --now apache2
    end_item
}

# ------------------------------------------------------------
# [4] Cấu hình Apache nhiều project (localhost/tenproject)
# ------------------------------------------------------------

item_apache_conf() {
    begin_item
    echo -e "${BLUE}${BOLD}== [4] Cấu hình Apache nhiều project (localhost/tenproject) ==${NC}"
    if [ ! -f "$APACHE_DEFAULT_CONF" ]; then
        echo -e "${RED}Không tìm thấy $APACHE_DEFAULT_CONF — hãy chạy mục [3] trước.${NC}"
        FAILED_ITEMS+=("[4] cấu hình apache (thiếu 000-default.conf)")
        end_item
        return 1
    fi
    if grep -q "AllowOverride All" "$APACHE_DEFAULT_CONF"; then
        mark_skip "000-default.conf đã cấu hình nhiều project"
    else
        local bak="$APACHE_DEFAULT_CONF.setup-bak-$TS"
        cp "$APACHE_DEFAULT_CONF" "$bak"
        mark_ok "Đã backup file gốc: $bak"

        cat > "$APACHE_DEFAULT_CONF" <<'EOF'
<VirtualHost *:80>
	ServerAdmin webmaster@localhost
	DocumentRoot /var/www/html

	<Directory /var/www/html>
		Options Indexes FollowSymLinks
		AllowOverride All
		Require all granted
	</Directory>

	ErrorLog ${APACHE_LOG_DIR}/error.log
	CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>
EOF

        if apachectl configtest; then
            if systemctl reload apache2; then
                mark_ok "Đã áp dụng — truy cập project theo kiểu http://localhost/ten_project"
            else
                FAILED_ITEMS+=("[4] reload apache2")
            fi
        else
            echo -e "${RED}configtest thất bại — khôi phục file backup${NC}"
            cp "$bak" "$APACHE_DEFAULT_CONF"
            apachectl configtest
            systemctl reload apache2
            FAILED_ITEMS+=("[4] ghi 000-default.conf (đã rollback)")
        fi
    fi
    end_item
}

# ------------------------------------------------------------
# [5] PHP 8.3 + extensions
# ------------------------------------------------------------

item_php() {
    begin_item
    echo -e "${BLUE}${BOLD}== [5] Cài PHP 8.3 + extensions ==${NC}"
    if pkg_ok php && pkg_ok libapache2-mod-php; then
        mark_skip "PHP đã có sẵn (phiên bản $(php -r 'echo PHP_VERSION;' 2>/dev/null))"
    else
        run_step "apt-get install php + extensions" \
            apt-get install -y php libapache2-mod-php php-cli php-curl php-gd \
            php-mbstring php-xml php-zip php-bcmath php-intl php-sqlite3
    fi
    if pkg_ok apache2 && systemctl is-active --quiet apache2; then
        run_step "restart apache2 để load module PHP" systemctl restart apache2
    fi
    if have_cmd php; then
        mark_ok "PHP đang chạy: $(php -r 'echo PHP_VERSION;' 2>/dev/null)"
    fi
    end_item
}

# ------------------------------------------------------------
# [6] NVM
# ------------------------------------------------------------

item_nvm() {
    begin_item
    echo -e "${BLUE}${BOLD}== [6] Cài NVM (cho user $REAL_USER) ==${NC}"
    if [ -f "$NVM_SH" ]; then
        mark_skip "NVM đã có tại ~/.nvm"
    else
        run_step "tải NVM $NVM_VERSION" curl -fsSL \
            -o /tmp/nvm-install.sh \
            "https://raw.githubusercontent.com/nvm-sh/nvm/$NVM_VERSION/install.sh"
        run_step "chạy installer NVM" as_user bash /tmp/nvm-install.sh
        rm -f /tmp/nvm-install.sh
    fi
    end_item
}

# ------------------------------------------------------------
# [7] Node.js LTS qua NVM
# ------------------------------------------------------------

item_node() {
    begin_item
    echo -e "${BLUE}${BOLD}== [7] Cài Node.js LTS (qua NVM) ==${NC}"
    if [ ! -f "$NVM_SH" ]; then
        echo -e "${RED}Chưa có NVM — hãy chạy mục [6] trước.${NC}"
        FAILED_ITEMS+=("[7] Node.js LTS (chưa có NVM)")
        end_item
        return 1
    fi
    if as_user bash -c ". '$NVM_SH' >/dev/null 2>&1 && command -v node >/dev/null 2>&1"; then
        mark_skip "Node.js đã có ($(as_user bash -c ". '$NVM_SH' >/dev/null 2>&1; node --version"))"
    else
        run_step "nvm install --lts" as_user bash -c \
            ". '$NVM_SH' && nvm install --lts && nvm alias default 'lts/*'"
        as_user bash -c ". '$NVM_SH' && node --version && npm --version"
    fi
    end_item
}

# ------------------------------------------------------------
# [8] VS Code
# ------------------------------------------------------------

item_vscode() {
    begin_item
    echo -e "${BLUE}${BOLD}== [8] Cài Visual Studio Code ==${NC}"
    if pkg_ok code; then
        mark_skip "VS Code đã có sẵn"
    else
        if run_step "tải .deb VS Code từ Microsoft" curl -fSL \
            -o /tmp/code_latest.deb \
            "https://update.code.visualstudio.com/latest/linux-deb-x64/stable"; then
            run_step "apt-get install ./code_latest.deb" apt-get install -y /tmp/code_latest.deb
            rm -f /tmp/code_latest.deb
        fi
    fi
    have_cmd code && mark_ok "VS Code: $(code --version | head -n1)"
    end_item
}

# ------------------------------------------------------------
# [9] Google Chrome
# ------------------------------------------------------------

item_chrome() {
    begin_item
    echo -e "${BLUE}${BOLD}== [9] Cài Google Chrome ==${NC}"
    if pkg_ok google-chrome-stable; then
        mark_skip "Google Chrome đã có sẵn"
    else
        if run_step "tải .deb Chrome từ Google" curl -fSL \
            -o /tmp/google-chrome-stable.deb \
            "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"; then
            run_step "apt-get install ./google-chrome-stable.deb" \
                apt-get install -y /tmp/google-chrome-stable.deb
            rm -f /tmp/google-chrome-stable.deb
        fi
    fi
    have_cmd google-chrome && mark_ok "Chrome: $(google-chrome --version)"
    end_item
}

# ------------------------------------------------------------
# [10] Vim
# ------------------------------------------------------------

item_vim() {
    begin_item
    echo -e "${BLUE}${BOLD}== [10] Cài Vim ==${NC}"
    if have_cmd vim; then
        mark_skip "Vim đã có sẵn ($(vim --version | head -n1 | awk '{print $1, $5}'))"
    else
        run_step "apt-get install vim" apt-get install -y vim
    fi
    end_item
}

# ------------------------------------------------------------
# [11] Meld
# ------------------------------------------------------------

item_meld() {
    begin_item
    echo -e "${BLUE}${BOLD}== [11] Cài Meld (so sánh code) ==${NC}"
    if have_cmd meld; then
        mark_skip "Meld đã có sẵn"
    else
        run_step "apt-get install meld" apt-get install -y meld
    fi
    end_item
}

# ------------------------------------------------------------
# [12] IBus Bamboo
# ------------------------------------------------------------

item_ibus_bamboo() {
    begin_item
    echo -e "${BLUE}${BOLD}== [12] Cài IBus Bamboo (gõ tiếng Việt) ==${NC}"
    if ! pkg_ok software-properties-common; then
        run_step "apt-get install software-properties-common" \
            apt-get install -y software-properties-common
    fi
    run_step "add PPA bamboo-engine/ibus-bamboo" \
        add-apt-repository -y ppa:bamboo-engine/ibus-bamboo
    run_step "apt-get update" apt-get update
    if pkg_ok ibus-bamboo; then
        mark_skip "ibus-bamboo đã có sẵn"
    else
        run_step "apt-get install ibus-bamboo" apt-get install -y ibus-bamboo
    fi

    echo ""
    echo -e "${BOLD}HƯỚNG DẪN bật gõ tiếng Việt sau khi cài:${NC}"
    echo -e "  1. Mở ${CYAN}Settings → Keyboard → Input Sources${NC}"
    echo -e "  2. Nhấn ${CYAN}+${NC} → tìm ${CYAN}Vietnamese (Bamboo)${NC} → Add"
    echo -e "  3. Đổi bàn phím bằng tổ hợp ${CYAN}Super+Space${NC}"
    echo -e "  4. Nếu chưa thấy Bamboo: đăng xuất & đăng nhập lại máy"
    echo ""
    end_item
}

# ------------------------------------------------------------
# [13] Flutter SDK
# ------------------------------------------------------------

item_flutter() {
    begin_item
    echo -e "${BLUE}${BOLD}== [13] Cài Flutter SDK → ~/development/flutter ==${NC}"

    run_step "cài deps build Linux desktop" apt-get install -y \
        curl git unzip xz-utils zip clang cmake ninja-build pkg-config \
        libgtk-3-dev libglu1-mesa

    if [ -x "$FLUTTER_DIR/bin/flutter" ]; then
        mark_skip "Flutter SDK đã có tại $FLUTTER_DIR"
    else
        local url
        url="$(curl -fsSL https://storage.googleapis.com/flutter_infra_release/releases/releases_linux.json \
            | python3 -c '
import sys, json
d = json.load(sys.stdin)
base = d["base_url"]
stable_hash = d["current_release"]["stable"]
archive = next(r["archive"] for r in d["releases"] if r["hash"] == stable_hash)
print(base + "/" + archive)
')"
        if [ -z "$url" ]; then
            echo -e "${RED}Không đọc được danh sách release Flutter.${NC}"
            FAILED_ITEMS+=("[13] Flutter (không lấy được URL stable)")
            end_item
            return 1
        fi
        mark_ok "Bản stable mới nhất: $url"

        if run_step "tải Flutter SDK" curl -fSL -o /tmp/flutter.tar.xz "$url"; then
            mkdir -p "$REAL_HOME/development"
            run_step "giải nén vào ~/development" tar -xJf /tmp/flutter.tar.xz -C "$REAL_HOME/development"
            rm -f /tmp/flutter.tar.xz
            chown -R "$REAL_USER:$REAL_GROUP" "$REAL_HOME/development"

            as_user bash -c "grep -qs 'development/flutter/bin' '$REAL_HOME/.bashrc' || printf '\nexport PATH=\"\$HOME/development/flutter/bin:\$PATH\"\n' >> '$REAL_HOME/.bashrc'"
            mark_ok "Đã thêm PATH vào ~/.bashrc của $REAL_USER"
            echo -e "   ${YELLOW}Lưu ý: mở terminal mới rồi chạy '${BOLD}flutter doctor${NC}${YELLOW}' để kiểm tra.${NC}"
            echo -e "   ${YELLOW}Muốn build app Android thì cài thêm mục [14].${NC}"
        fi
    fi
    end_item
}

# ------------------------------------------------------------
# [14] Android Studio
# ------------------------------------------------------------

item_android_studio() {
    begin_item
    echo -e "${BLUE}${BOLD}== [14] Cài Android Studio (snap, dung lượng lớn ~1.5GB) ==${NC}"
    if ! have_cmd snap; then
        echo -e "${RED}Không tìm thấy lệnh 'snap' — hãy cài snapd trước (Ubuntu Desktop thường có sẵn).${NC}"
        FAILED_ITEMS+=("[14] Android Studio (thiếu snap)")
        end_item
        return 1
    fi
    if snap list android-studio >/dev/null 2>&1; then
        mark_skip "Android Studio đã có sẵn"
    else
        run_step "snap install android-studio --classic" snap install android-studio --classic
        echo -e "   ${YELLOW}Sau khi cài xong: mở Android Studio → cài Android SDK →${NC}"
        echo -e "   ${YELLOW}chạy '${BOLD}flutter doctor --android-licenses${NC}${YELLOW}' để chấp nhận license.${NC}"
    fi
    end_item
}

# ------------------------------------------------------------
# [15] Tạo Virtual Host (*.test)
# ------------------------------------------------------------

pick_project() {
    PROJECT_LIST=()
    local i=1 d name
    echo -e "${BOLD}Các folder hiện có trong $WWW_ROOT:${NC}"
    for d in "$WWW_ROOT"/*/; do
        [ -d "$d" ] || continue
        name="$(basename "$d")"
        PROJECT_LIST+=("$name")
        printf "   [%2d] %s\n" "$i" "$name"
        i=$((i+1))
    done
    [ ${#PROJECT_LIST[@]} -eq 0 ] && echo -e "   ${YELLOW}(trống)${NC}"
    return 0
}

create_vhost() {
    local proj="$1"
    local domain="${proj}.test"
    local docroot="$WWW_ROOT/$proj"
    local conf="/etc/apache2/sites-available/${proj}.conf"

    if [ -f "$conf" ]; then
        read -rp "   File $conf đã tồn tại. Ghi đè? (y/N): " ow
        if [[ ! "$ow" =~ ^[Yy]$ ]]; then
            echo -e "   ${YELLOW}Bỏ qua tạo vhost cho $domain${NC}"
            return 1
        fi
    fi

    cat > "$conf" <<EOF
<VirtualHost *:80>
	ServerName $domain
	DocumentRoot $docroot

	<Directory $docroot>
		Options Indexes FollowSymLinks
		AllowOverride All
		Require all granted
	</Directory>

	ErrorLog \${APACHE_LOG_DIR}/${proj}-error.log
	CustomLog \${APACHE_LOG_DIR}/${proj}-access.log combined
</VirtualHost>
EOF

    a2ensite "$proj"

    if ! grep -qxF "127.0.0.1 $domain" /etc/hosts; then
        echo "127.0.0.1 $domain" >> /etc/hosts
        mark_ok "Đã thêm '127.0.0.1 $domain' vào /etc/hosts"
    fi

    if apachectl configtest; then
        systemctl reload apache2
        mark_ok "Virtual Host hoạt động: ${GREEN}http://$domain${NC} → $docroot"
        return 0
    else
        echo -e "   ${RED}configtest thất bại — rollback vhost $domain${NC}"
        a2dissite "$proj"
        rm -f "$conf"
        grep -vxF "127.0.0.1 $domain" /etc/hosts > /tmp/hosts.new \
            && cat /tmp/hosts.new > /etc/hosts && rm -f /tmp/hosts.new
        apachectl configtest
        systemctl reload apache2
        FAILED_ITEMS+=("[15] vhost $domain (đã rollback)")
        return 1
    fi
}

item_vhost_create() {
    begin_item
    echo -e "${BLUE}${BOLD}== [15] Tạo Virtual Host (http://<tên>.test) ==${NC}"
    if [ ! -d /etc/apache2/sites-available ]; then
        echo -e "${RED}Apache chưa cài — hãy chạy mục [3] trước.${NC}"
        FAILED_ITEMS+=("[15] tạo vhost (chưa có Apache)")
        end_item
        return 1
    fi

    while true; do
        pick_project
        echo ""
        read -rp "Nhập SỐ THỨ TỰ hoặc TÊN folder (Enter = quay lại menu): " ans
        [ -z "$ans" ] && break

        local proj=""
        if [[ "$ans" =~ ^[0-9]+$ ]]; then
            proj="${PROJECT_LIST[$((ans-1))]:-}"
        else
            proj="$ans"
        fi

        if [ -z "$proj" ] || [[ ! "$proj" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
            echo -e "${RED}Tên không hợp lệ hoặc số thứ tự sai.${NC}"
            continue
        fi
        if [ ! -d "$WWW_ROOT/$proj" ]; then
            echo -e "${RED}Folder '$WWW_ROOT/$proj' không tồn tại.${NC}"
            continue
        fi

        create_vhost "$proj"

        echo ""
        read -rp "Tạo tiếp vhost cho project khác? (y/N): " more
        [[ "$more" =~ ^[Yy]$ ]] || break
    done
    end_item
}

# ------------------------------------------------------------
# [16] Xóa Virtual Host
# ------------------------------------------------------------

item_vhost_delete() {
    begin_item
    echo -e "${BLUE}${BOLD}== [16] Xóa Virtual Host (*.test) ==${NC}"

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

    if [ ${#VH_DOMAINS[@]} -eq 0 ]; then
        echo -e "${YELLOW}Không có virtual host *.test nào để xóa.${NC}"
        end_item
        return 0
    fi

    echo -e "${BOLD}Các vhost đang có:${NC}"
    for i in "${!VH_DOMAINS[@]}"; do
        printf "   [%2d] %-30s (%s.conf)\n" "$((i+1))" "${VH_DOMAINS[$i]}" "${VH_SITES[$i]}"
    done
    echo ""
    read -rp "Chọn SỐ thứ tự cần xóa (Enter = quay lại menu): " ans
    [ -z "$ans" ] && { end_item; return 0; }

    if [[ ! "$ans" =~ ^[0-9]+$ ]] || [ "$ans" -lt 1 ] || [ "$ans" -gt ${#VH_DOMAINS[@]} ]; then
        echo -e "${RED}Lựa chọn không hợp lệ.${NC}"
        end_item
        return 1
    fi

    local idx=$((ans-1))
    local site="${VH_SITES[$idx]}"
    local domain="${VH_DOMAINS[$idx]}"
    local conf="/etc/apache2/sites-available/${site}.conf"

    read -rp "Xác nhận xóa '$domain'? (y/N): " ok
    if [[ ! "$ok" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Đã hủy.${NC}"
        end_item
        return 0
    fi

    a2dissite "$site"
    rm -f "$conf"
    if grep -qxF "127.0.0.1 $domain" /etc/hosts; then
        grep -vxF "127.0.0.1 $domain" /etc/hosts > /tmp/hosts.new \
            && cat /tmp/hosts.new > /etc/hosts && rm -f /tmp/hosts.new
        mark_ok "Đã gỡ dòng hosts của $domain"
    fi

    if apachectl configtest; then
        systemctl reload apache2
        mark_ok "Đã xóa vhost $domain"
    else
        apachectl configtest
        FAILED_ITEMS+=("[16] xóa vhost $domain (configtest fail)")
    fi
    end_item
}

# ------------------------------------------------------------
# [17] Cài tất cả (1→14)
# ------------------------------------------------------------

item_install_all() {
    begin_item
    echo -e "${BLUE}${BOLD}== [17] CÀI TẤT CẢ (mục 1→14) ==${NC}"
    echo -e "${YELLOW}Quá trình có thể mất 30–60 phút tùy mạng. Mục nào lỗi sẽ bị bỏ qua và tổng kết cuối cùng.${NC}"
    read -rp "Bắt đầu cài TẤT CẢ? (y/N): " go
    if [[ ! "$go" =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Đã hủy.${NC}"
        end_item
        return 0
    fi
    item_update
    item_git
    item_apache
    item_apache_conf
    item_php
    item_nvm
    item_node
    item_vscode
    item_chrome
    item_vim
    item_meld
    item_ibus_bamboo
    item_flutter
    item_android_studio
    end_item
}

# ------------------------------------------------------------
# Menu chính
# ------------------------------------------------------------

show_menu() {
    clear
    echo ""
    echo -e "${BOLD}${BLUE}=============================================================${NC}"
    echo -e "${BOLD}${BLUE}   CÔNG CỤ CÀI ĐẶT MÔI TRƯỜNG LẬP TRÌNH — UBUNTU DESKTOP${NC}"
    echo -e "${BOLD}${BLUE}   User: $REAL_USER${NC}"
    echo -e "${BOLD}${BLUE}=============================================================${NC}"
    echo ""
    echo -e "  ${BOLD}--- HỆ THỐNG & WEB SERVER ---${NC}"
    echo -e "   ${GREEN}[1]${NC}  Cập nhật hệ thống (apt update/upgrade)"
    echo -e "   ${GREEN}[2]${NC}  Cài Git"
    echo -e "   ${GREEN}[3]${NC}  Cài Apache2 (+ mod_rewrite)"
    echo -e "   ${GREEN}[4]${NC}  Cấu hình Apache nhiều project (localhost/tenproject)"
    echo -e "   ${GREEN}[5]${NC}  Cài PHP 8.3 + extensions"
    echo ""
    echo -e "  ${BOLD}--- NODE.JS ---${NC}"
    echo -e "   ${GREEN}[6]${NC}  Cài NVM"
    echo -e "   ${GREEN}[7]${NC}  Cài Node.js LTS (qua NVM)"
    echo ""
    echo -e "  ${BOLD}--- ỨNG DỤNG LẬP TRÌNH ---${NC}"
    echo -e "   ${GREEN}[8]${NC}  Cài Visual Studio Code"
    echo -e "   ${GREEN}[9]${NC}  Cài Google Chrome"
    echo -e "   ${GREEN}[10]${NC} Cài Vim"
    echo -e "   ${GREEN}[11]${NC} Cài Meld"
    echo -e "   ${GREEN}[12]${NC} Cài IBus Bamboo (gõ tiếng Việt)"
    echo ""
    echo -e "  ${BOLD}--- FLUTTER / ANDROID ---${NC}"
    echo -e "   ${GREEN}[13]${NC} Cài Flutter SDK (~/development/flutter)"
    echo -e "   ${GREEN}[14]${NC} Cài Android Studio (tùy chọn, dung lượng lớn)"
    echo ""
    echo -e "  ${BOLD}--- VIRTUAL HOST ---${NC}"
    echo -e "   ${GREEN}[15]${NC} Tạo Virtual Host cho project (http://<tên>.test)"
    echo -e "   ${GREEN}[16]${NC} Xóa Virtual Host"
    echo ""
    echo -e "  ${BOLD}--- KHÁC ---${NC}"
    echo -e "   ${GREEN}[17]${NC} Cài TẤT CẢ mục [1]→[14] (bỏ qua lỗi, tổng kết cuối)"
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
        read -rp "Chọn mục [0-17]: " choice
        case "$choice" in
            1)  item_update;          pause_enter ;;
            2)  item_git;             pause_enter ;;
            3)  item_apache;          pause_enter ;;
            4)  item_apache_conf;     pause_enter ;;
            5)  item_php;             pause_enter ;;
            6)  item_nvm;             pause_enter ;;
            7)  item_node;            pause_enter ;;
            8)  item_vscode;          pause_enter ;;
            9)  item_chrome;          pause_enter ;;
            10) item_vim;             pause_enter ;;
            11) item_meld;            pause_enter ;;
            12) item_ibus_bamboo;     pause_enter ;;
            13) item_flutter;         pause_enter ;;
            14) item_android_studio;  pause_enter ;;
            15) item_vhost_create;    pause_enter ;;
            16) item_vhost_delete;    pause_enter ;;
            17) item_install_all;     pause_enter ;;
            0)  print_summary; exit 0 ;;
            "") ;;
            *)  echo -e "${RED}Lựa chọn không hợp lệ!${NC}"; sleep 1 ;;
        esac
    done
}

main_loop
