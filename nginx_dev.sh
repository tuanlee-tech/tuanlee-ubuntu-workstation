#!/bin/bash
# ============================================================
# nginx_dev.sh — Cài đặt / gỡ cài đặt nginx + quản lý project local
# Cách dùng: sudo bash nginx_dev.sh
#
#   [1] Cài nginx             [5] Danh sách + bật/tắt site
#   [2] Trạng thái            [6] Sửa cấu hình site
#   [3] Tạo project mới       [7] Xóa site
#   [4] Thêm project có sẵn   [8] Gỡ hoàn toàn nginx
#                              [9] Bật lại Apache :80 · tạm tắt nginx
# ============================================================

set -o pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d-%H%M%S)"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/nginx_$TS.log"

WWW_ROOT="/var/www/html"
HOSTS_FILE="/etc/hosts"
NGINX_AVAIL="/etc/nginx/sites-available"
NGINX_EN="/etc/nginx/sites-enabled"
APACHE_DIR="/etc/apache2"
APACHE_PORT=8080                # cổng dành cho Apache khi nhường cổng 80
BAK_SUFFIX=".nginxdev.bak"      # hậu tố backup do script này tạo
STATE_FILE="$SCRIPT_DIR/backups/nginx_state.txt"

FAILED_ITEMS=()
ITEM_FAIL_BASE=0
SUMMARY_PRINTED=0
FPM_SOCK=""

# ------------------------------------------------------------
# Hàm tiện ích chung (giống setup_dev.sh)
# ------------------------------------------------------------

have_cmd() { command -v "$1" >/dev/null 2>&1; }

pkg_ok() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -qx "install ok installed"; }

as_user() { sudo -u "$REAL_USER" env HOME="$REAL_HOME" "$@"; }

begin_item() { ITEM_FAIL_BASE=${#FAILED_ITEMS[@]}; }

end_item() {
    if [ "${#FAILED_ITEMS[@]}" -eq "$ITEM_FAIL_BASE" ]; then
        echo -e "   ${GREEN}${BOLD}[HOÀN TẤT]${NC} Mục này hoàn thành."
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
    echo -e "${RED}Script cần quyền root để thao tác nginx/Apache.${NC}"
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

mkdir -p "$LOG_DIR" "$(dirname "$STATE_FILE")"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

echo -e "${BOLD}User: $REAL_USER | Home: $REAL_HOME | Log: $LOG_FILE${NC}"

# ------------------------------------------------------------
# State manifest — ghi nhớ script này đã làm gì với Apache
# ------------------------------------------------------------

state_init() {
    if [ ! -f "$STATE_FILE" ]; then
        {
            echo "# nginx_dev.sh — state (tự sinh, đừng sửa tay)"
            echo "CREATED=$TS"
        } > "$STATE_FILE"
        chmod 664 "$STATE_FILE"
    fi
}

state_get() {
    [ -f "$STATE_FILE" ] || return 1
    grep -E "^$1=" "$STATE_FILE" 2>/dev/null | tail -n 1 | cut -d= -f2-
}

state_set() {
    state_init
    local k="$1" v="$2" tmp
    tmp="$(mktemp /tmp/nginx_state.XXXXXX)"
    grep -vE "^$k=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
    printf '%s=%s\n' "$k" "$v" >> "$tmp"
    cat "$tmp" > "$STATE_FILE"
    rm -f "$tmp"
}

state_del() {
    [ -f "$STATE_FILE" ] || return 0
    local k="$1" tmp
    tmp="$(mktemp /tmp/nginx_state.XXXXXX)"
    grep -vE "^$k=" "$STATE_FILE" > "$tmp" 2>/dev/null || true
    cat "$tmp" > "$STATE_FILE"
    rm -f "$tmp"
}

state_add_domain() {
    state_init
    grep -qxF "DOMAIN=$1" "$STATE_FILE" 2>/dev/null || echo "DOMAIN=$1" >> "$STATE_FILE"
}

state_del_domain() {
    [ -f "$STATE_FILE" ] || return 0
    local tmp
    tmp="$(mktemp /tmp/nginx_state.XXXXXX)"
    grep -vxF "DOMAIN=$1" "$STATE_FILE" > "$tmp" 2>/dev/null || true
    cat "$tmp" > "$STATE_FILE"
    rm -f "$tmp"
}

state_domains() {
    [ -f "$STATE_FILE" ] || return 0
    grep -E '^DOMAIN=' "$STATE_FILE" 2>/dev/null | cut -d= -f2-
}

# ------------------------------------------------------------
# Hàm chuyên dụng nginx / Apache
# ------------------------------------------------------------

nginx_installed() { pkg_ok nginx; }

# In ra tên process đang giữ cổng 80 (thoát mã 1 nếu cổng trống)
port80_owner() {
    local line
    line="$(ss -ltnp 2>/dev/null | awk '$4 ~ /:80$/ { print; exit }')"
    [ -z "$line" ] && return 1
    if [[ "$line" =~ users:\(\(\"([^\"]+)\" ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    # ss không lộ process (hoặc parse lỗi) → suy đoán theo service đang chạy
    if systemctl is-active --quiet apache2; then echo "apache2"; return 0; fi
    if systemctl is-active --quiet nginx;    then echo "nginx";    return 0; fi
    echo "unknown"
}

nginx_test_reload() {
    if nginx -t; then
        systemctl reload nginx
        return $?
    fi
    return 1
}

# Escape chuỗi để dùng làm biểu thức chính quy (sed ERE)
esc_re() { printf '%s' "$1" | sed -e 's/[][\.*^$()+?{|]/\\&/g'; }

# /etc/hosts kết thúc thiếu newline → mọi lần append sau sẽ dính vào dòng cuối
hosts_touch_nl() {
    if [ -s "$HOSTS_FILE" ] && [ -n "$(tail -c 1 "$HOSTS_FILE")" ]; then
        printf '\n' >> "$HOSTS_FILE"
    fi
}

# Đúng nghĩa đen: domain có trong một entry 127.0.0.1 hợp lệ không
hosts_has() {
    [ -f "$HOSTS_FILE" ] || return 1
    awk -v d="$1" '
        $1 == "127.0.0.1" {
            for (i = 2; i <= NF; i++) if ($i == d) found = 1
        }
        END { exit !found }' "$HOSTS_FILE"
}

# Dọn vết "127.0.0.1 <domain>" bị dính sai vào dòng khác (do file thiếu newline)
hosts_scrub() {
    local d="$1" ed
    ed="$(esc_re "$d")"
    grep -q "127\.0\.0\.1[[:space:]]\+$ed" "$HOSTS_FILE" 2>/dev/null || return 0
    sed -i -E "s#127\.0\.0\.1[[:space:]]+$ed##g" "$HOSTS_FILE"
    hosts_touch_nl
}

hosts_add() {
    local d="$1"
    hosts_has "$d" && return 0
    hosts_scrub "$d"
    hosts_touch_nl
    printf '127.0.0.1 %s\n' "$d" >> "$HOSTS_FILE"
    if hosts_has "$d"; then
        mark_ok "Đã thêm '127.0.0.1 $d' vào $HOSTS_FILE"
        return 0
    fi
    echo -e "   ${RED}Không ghi được $HOSTS_FILE — kiểm tra quyền/file.${NC}"
    FAILED_ITEMS+=("thêm hosts $d")
    return 1
}

hosts_del() {
    local d="$1" tmp
    if ! hosts_has "$d"; then
        hosts_scrub "$d"      # chỉ dọn vết dính sai (nếu có)
        return 0
    fi
    tmp="$(mktemp /tmp/hosts.XXXXXX)"
    awk -v d="$d" '
        /^[[:space:]]*#/ || NF == 0 { print; next }
        $1 == "127.0.0.1" {
            out = $1; n = 0
            for (i = 2; i <= NF; i++) if ($i != d) { out = out " " $i; n++ }
            if (n > 0) print out
            next
        }
        { print }' "$HOSTS_FILE" > "$tmp"
    cat "$tmp" > "$HOSTS_FILE"
    rm -f "$tmp"
    mark_ok "Đã gỡ dòng hosts của $d"
}

domain_of() {  # domain_of <file-conf>
    [ -f "$1" ] || return 1
    local d
    d="$(awk '/^[[:space:]]*server_name[[:space:]]/ { d=$2; sub(/;.*/, "", d); print d; exit }' "$1")"
    [ -n "$d" ] || return 1
    echo "$d"
}

docroot_of() {
    [ -f "$1" ] || return 1
    local r
    r="$(awk '/^[[:space:]]*root[[:space:]]/ { r=$2; sub(/;.*/, "", r); print r; exit }' "$1")"
    [ -n "$r" ] || return 1
    echo "$r"
}

site_enabled() { [ -e "$NGINX_EN/$1.conf" ]; }

require_nginx() {
    if ! nginx_installed; then
        echo -e "   ${RED}nginx chưa cài — hãy chạy mục [1] trước.${NC}"
        FAILED_ITEMS+=("yêu cầu nginx (chưa cài)")
        return 1
    fi
    if [ ! -d "$NGINX_AVAIL" ]; then
        echo -e "   ${RED}Không thấy $NGINX_AVAIL — cài đặt nginx chưa hoàn chỉnh.${NC}"
        FAILED_ITEMS+=("yêu cầu nginx (thiếu $NGINX_AVAIL)")
        return 1
    fi
    return 0
}

# ------------------------------------------------------------
# PHP-FPM — máy chưa có PHP thì cài, có rồi thì chỉ static + gợi ý
# ------------------------------------------------------------

php_fpm_installed() {
    dpkg-query -W -f='${Status}' 'php*-fpm' 2>/dev/null | grep -q "install ok installed"
}

php_fpm_socket() {
    local s unit
    for s in /run/php/php*-fpm.sock; do
        [ -S "$s" ] && { echo "$s"; return 0; }
    done
    unit="$(systemctl list-unit-files --no-legend 2>/dev/null \
            | awk '$1 ~ /^php[0-9.]+-fpm\.service$/ { print $1; exit }')"
    [ -n "$unit" ] || return 1
    systemctl enable --now "$unit" >/dev/null 2>&1 || systemctl start "$unit" >/dev/null 2>&1
    sleep 1
    for s in /run/php/php*-fpm.sock; do
        [ -S "$s" ] && { echo "$s"; return 0; }
    done
    return 1
}

docroot_has_php() {
    [ -d "$1" ] || return 1
    [ -n "$(find "$1" -maxdepth 2 -name '*.php' -print -quit 2>/dev/null)" ]
}

docroot_has_index() {
    [ -f "$1/index.html" ] || [ -f "$1/index.htm" ] || [ -f "$1/index.php" ]
}

# ------------------------------------------------------------
# Tự động phát hiện docroot phù hợp cho từng project
# ------------------------------------------------------------
# Hàm smart_detect_docroot tìm thư mục web thực tế của project.
# Thứ tự ưu tiên:
#   1. Thư mục web phổ biến (public/, web/, htdocs/, www/, dist/, build/) có index
#   2. Root folder có index (project tĩnh thông thường)
#   3. Fallback về root folder (có thể cấu hình thủ công sau)
# ------------------------------------------------------------
smart_detect_docroot() {
    local project_dir="$1"
    local web_dirs=("public" "web" "htdocs" "www" "dist" "build")
    local sub

    # 1. Tìm trong các thư mục web phổ biến
    for sub in "${web_dirs[@]}"; do
        if [ -d "$project_dir/$sub" ] && docroot_has_index "$project_dir/$sub"; then
            echo "$project_dir/$sub"
            return 0
        fi
    done

    # 2. Root folder có index → dùng root
    if docroot_has_index "$project_dir"; then
        echo "$project_dir"
        return 0
    fi

    # 3. Fallback: trả về root, để người dùng tự cấu hình nếu cần
    echo "$project_dir"
    return 0
}

install_php_fpm() {
    run_step "apt-get install php-fpm" apt-get install -y \
        php-fpm php-cli php-curl php-gd php-mbstring php-xml php-zip \
        php-intl php-bcmath php-sqlite3
}

# Thiết lập FPM_SOCK cho site sắp tạo. Thoát mã 0 = chạy PHP, 1 = static HTML.
# Thứ tự quyết định:
#   1. đã có socket php-fpm            → dùng ngay
#   2. có package nhưng dựng socket fail → static
#   3. project CÓ file PHP mà thiếu fpm  → HỎI người dùng
#   4. máy chưa có PHP bao giờ           → cài luôn
#   5. còn lại (site static, máy có PHP module) → static + gợi ý
ensure_php() {
    local docroot="$1" ans
    FPM_SOCK=""
    if FPM_SOCK="$(php_fpm_socket)"; then
        return 0
    fi
    if php_fpm_installed; then
        # đã cài php-fpm nhưng không dựng dậy được socket
        return 1
    fi
    if docroot_has_php "$docroot"; then
        echo -e "   ${YELLOW}[CẢNH BÁO]${NC} Project có file PHP nhưng máy chưa có PHP-FPM."
        if ! read -rp "   Cài PHP-FPM ngay? (Y/n, Enter = có): " ans; then
            echo -e "   ${YELLOW}Không đọc được input — bỏ qua, site chạy static.${NC}"
            return 1
        fi
        if [[ "$ans" =~ ^[Nn]$ ]]; then
            return 1
        fi
        echo -e "   ${CYAN}➜ ${NC}Cài PHP-FPM + extensions${NC}"
        install_php_fpm
        if FPM_SOCK="$(php_fpm_socket)"; then return 0; fi
        return 1
    fi
    if ! have_cmd php; then
        echo -e "   ${CYAN}➜ ${NC}Máy chưa có PHP — cài PHP-FPM + extensions${NC}"
        install_php_fpm
        if FPM_SOCK="$(php_fpm_socket)"; then return 0; fi
        return 1
    fi
    return 1
}

php_hint() {
    if ! have_cmd php; then
        echo -e "   ${YELLOW}Gợi ý:${NC} muốn site chạy PHP, cài sau bằng: ${BOLD}sudo apt install php-fpm${NC}"
    elif ! php_fpm_installed; then
        echo -e "   ${YELLOW}Gợi ý:${NC} máy đã có PHP nhưng thiếu PHP-FPM — cài: ${BOLD}sudo apt install php-fpm${NC}"
    fi
}

# ------------------------------------------------------------
# Sinh / đọc cấu hình site
# ------------------------------------------------------------

write_site_conf() {   # write_site_conf <ten> <domain> <docroot>
    local name="$1" domain="$2" docroot="$3"
    local conf="$NGINX_AVAIL/$name.conf"
    local sock="${FPM_SOCK:-}"
    local idx_line="index index.html index.htm;"
    local try_line="try_files \$uri \$uri/ =404;"
    local listen6=""
    local php_block=""

    [ -f /proc/net/if_inet6 ] && listen6="    listen [::]:80;"

    if [ -n "$sock" ]; then
        idx_line="index index.html index.htm index.php;"
        try_line="try_files \$uri \$uri/ /index.php?\$query_string;"
        php_block="
    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:$sock;
        fastcgi_hide_header X-Powered-By;
    }
"
    else
        php_block="
    # PHP-FPM chưa có — trả 404 thay vì để nginx phát source .php
    location ~ \.php\$ {
        return 404;
    }
"
    fi

    cat > "$conf" <<EOF
# Tạo bởi nginx_dev.sh — $(date '+%Y-%m-%d %H:%M:%S')
server {
    listen 80;
$listen6

    server_name $domain;
    root $docroot;
    $idx_line
    client_max_body_size 64m;

    access_log /var/log/nginx/$name-access.log;
    error_log  /var/log/nginx/$name-error.log;

    location / {
        $try_line
    }
$php_block
    location ~ /\.(?!well-known\.).* {
        deny all;
    }
}
EOF
    chmod 644 "$conf"
}

# Tạo site hoàn chỉnh: conf + symlink + hosts + nginx -t (fail = rollback)
create_site() {   # create_site <ten> <domain> <docroot>
    local name="$1" domain="$2" docroot="$3"
    local conf="$NGINX_AVAIL/$name.conf"
    local link="$NGINX_EN/$name.conf"

    if [ ! -d "$docroot" ]; then
        echo -e "   ${RED}Không thấy thư mục $docroot — bỏ qua.${NC}"
        FAILED_ITEMS+=("tạo site $domain (thiếu docroot)")
        return 1
    fi

    if [ -f "$conf" ]; then
        local ow oldroot
        oldroot="$(docroot_of "$conf" 2>/dev/null)"
        if [ -n "$oldroot" ] && [ "$oldroot" != "$docroot" ]; then
            echo -e "   ${YELLOW}Site '$name' đang trỏ vào: $oldroot${NC}"
        fi
        read -rp "   Ghi đè để trỏ vào $docroot? (y/N): " ow
        if [[ ! "$ow" =~ ^[Yy]$ ]]; then
            echo -e "   ${YELLOW}Bỏ qua site $domain${NC}"
            return 1
        fi
    fi

    if ensure_php "$docroot"; then
        mark_ok "PHP-FPM sẵn sàng: $FPM_SOCK"
    else
        FPM_SOCK=""
        echo -e "   ${YELLOW}Site này chạy static HTML.${NC}"
        if docroot_has_php "$docroot"; then
            echo -e "   ${RED}⚠ Project có file PHP:${NC} 'http://$domain/' sẽ trả ${BOLD}403/404${NC} vì nginx chưa chạy PHP."
            echo -e "   ${YELLOW}  Khắc phục:${NC} cài php-fpm rồi chạy lại mục [4] và trả lời 'y' để script thêm block PHP."
        fi
        php_hint
    fi

    # Tự động phát hiện docroot phù hợp (public/, web/, dist/, ...)
    local detected
    detected="$(smart_detect_docroot "$docroot")"
    if [ "$detected" != "$docroot" ]; then
        echo -e "   ${CYAN}➜ ${NC}Phát hiện docroot web:${NC} $detected${NC}"
        docroot="$detected"
    elif ! docroot_has_index "$docroot"; then
        echo -e "   ${YELLOW}⚠ Folder không có index.html/index.htm/index.php → 'http://$domain/' sẽ 403.${NC}"
    fi

    write_site_conf "$name" "$domain" "$docroot"
    ln -sfn "../sites-available/$name.conf" "$link"
    hosts_add "$domain"

    if nginx_test_reload; then
        mark_ok "Site hoạt động: ${GREEN}http://$domain${NC} → $docroot"
        state_add_domain "$domain"
        return 0
    fi

    echo -e "   ${RED}nginx -t thất bại — rollback site $domain${NC}"
    rm -f "$link" "$conf"
    hosts_del "$domain"
    nginx -t
    systemctl reload nginx 2>/dev/null
    FAILED_ITEMS+=("tạo site $domain (nginx -t fail, đã rollback)")
    return 1
}

collect_sites() {   # điền SITE_NAMES / SITE_DOMAINS / SITE_DOCROOTS / SITE_STATES
    SITE_NAMES=(); SITE_DOMAINS=(); SITE_DOCROOTS=(); SITE_STATES=()
    local c name
    shopt -s nullglob
    for c in "$NGINX_AVAIL"/*.conf; do
        name="$(basename "$c" .conf)"
        SITE_NAMES+=("$name")
        SITE_DOMAINS+=("$(domain_of "$c")")
        SITE_DOCROOTS+=("$(docroot_of "$c")")
        if site_enabled "$name"; then SITE_STATES+=("bật"); else SITE_STATES+=("tắt"); fi
    done
    shopt -u nullglob
}

# In danh sách site; trả về mã 0 nếu có ít nhất 1 site
print_sites() {
    collect_sites
    if [ ${#SITE_NAMES[@]} -eq 0 ]; then
        echo -e "   ${YELLOW}Chưa có site nào trong $NGINX_AVAIL.${NC}"
        return 1
    fi
    printf "   %-18s %-26s %-6s %s\n" "TÊN" "DOMAIN" "TRẠNG" "DOCROOT"
    local i
    for i in "${!SITE_NAMES[@]}"; do
        printf "   [%d] %-14s %-26s %-6s %s\n" \
            "$((i+1))" "${SITE_NAMES[$i]}" "${SITE_DOMAINS[$i]}" \
            "${SITE_STATES[$i]}" "${SITE_DOCROOTS[$i]}"
    done
    return 0
}

# Chọn 1 site theo số thứ tự → in danh sách, đọc số, ghi SITE_IDX
pick_site() {
    echo ""
    if ! print_sites; then
        return 1
    fi
    echo ""
    read -rp "Chọn SỐ thứ tự site (Enter = quay lại menu): " ans
    [ -z "$ans" ] && return 1
    if [[ ! "$ans" =~ ^[0-9]+$ ]] || [ "$ans" -lt 1 ] || [ "$ans" -gt ${#SITE_NAMES[@]} ]; then
        echo -e "   ${RED}Lựa chọn không hợp lệ.${NC}"
        return 1
    fi
    SITE_IDX=$((ans-1))
    return 0
}

# ------------------------------------------------------------
# Xử lý xung đột cổng 80 với Apache2
# ------------------------------------------------------------

apache_restore_conf() {   # khôi phục file cấu hình Apache từ backup
    local f restored=0
    shopt -s nullglob
    if [ -f "$APACHE_DIR/ports.conf$BAK_SUFFIX" ]; then
        cp -p "$APACHE_DIR/ports.conf$BAK_SUFFIX" "$APACHE_DIR/ports.conf"
        restored=1
    fi
    for f in "$APACHE_DIR"/sites-available/*.conf"$BAK_SUFFIX"; do
        cp -p "$f" "${f%$BAK_SUFFIX}"
        restored=1
    done
    shopt -u nullglob
    [ "$restored" -eq 1 ]
}

apache_drop_backups() {
    local f
    shopt -s nullglob
    rm -f "$APACHE_DIR/ports.conf$BAK_SUFFIX"
    for f in "$APACHE_DIR"/sites-available/*.conf"$BAK_SUFFIX"; do
        rm -f "$f"
    done
    shopt -u nullglob
}

apache_move_to_8080() {
    echo -e "   ${CYAN}➜ ${NC}Chuyển Apache2 sang cổng $APACHE_PORT (tự động backup${NC}"
    local f

    if [ -f "$APACHE_DIR/ports.conf" ]; then
        [ -f "$APACHE_DIR/ports.conf$BAK_SUFFIX" ] \
            || cp -p "$APACHE_DIR/ports.conf" "$APACHE_DIR/ports.conf$BAK_SUFFIX"
        sed -i -E \
            -e "s/^Listen[[:space:]]+80[[:space:]]*$/Listen $APACHE_PORT/" \
            -e "s/^Listen[[:space:]]+\[::\]:80[[:space:]]*$/Listen [::]:$APACHE_PORT/" \
            "$APACHE_DIR/ports.conf"
    fi

    shopt -s nullglob
    for f in "$APACHE_DIR"/sites-available/*.conf; do
        [ -f "$f$BAK_SUFFIX" ] || cp -p "$f" "$f$BAK_SUFFIX"
        sed -i -E "s#(<VirtualHost[^>]*):80>#\1:$APACHE_PORT>#g" "$f"
    done
    shopt -u nullglob

    if apache2ctl configtest; then
        run_step "systemctl restart apache2" systemctl restart apache2
        state_set APACHE_MODE port
        mark_ok "Apache2 chuyển sang cổng $APACHE_PORT — cổng 80 trống cho nginx"
        return 0
    fi

    echo -e "   ${RED}Apache configtest thất bại — hoàn tác thay đổi cổng.${NC}"
    apache_restore_conf
    apache2ctl configtest
    return 1
}

apache_stop_for_nginx() {
    echo -e "   ${CYAN}➜ ${NC}Dừng + tắt apache2 để nginx giữ cổng 80${NC}"
    run_step "systemctl disable --now apache2" systemctl disable --now apache2
    state_set APACHE_MODE stopped
    mark_ok "apache2 đã dừng và bị disable (script sẽ hỏi bật lại khi gỡ nginx)"
}

apache_restore_to_80() {   # hoàn tác Apache về cổng 80 — gọi khi gỡ nginx hoặc khi chọn mục [9]
    local mode
    mode="$(state_get APACHE_MODE)"
    case "$mode" in
        port)
            if ! pkg_ok apache2; then
                echo -e "   ${YELLOW}apache2 không còn cài — bỏ qua khôi phục cổng.${NC}"
                return 0
            fi
            if ! apache_restore_conf; then
                echo -e "   ${YELLOW}Không tìm thấy backup Apache (.nginxdev.bak).${NC}"
                return 1
            fi
            if ! apache2ctl configtest; then
                echo -e "   ${YELLOW}configtest fail sau khi khôi phục — giữ backup để kiểm tra tay.${NC}"
                return 1
            fi
            run_step "systemctl restart apache2 (cổng 80)" systemctl restart apache2
            apache_drop_backups
            mark_ok "Apache2 đã về lại cổng 80"
            state_del APACHE_MODE
            return 0
            ;;
        stopped)
            if pkg_ok apache2; then
                run_step "systemctl enable --now apache2" systemctl enable --now apache2
                mark_ok "apache2 đã được bật lại"
            fi
            state_del APACHE_MODE
            return 0
            ;;
        *)
            # script chưa từng đụng Apache — chỉ cần dựng service lên
            if pkg_ok apache2; then
                run_step "systemctl enable --now apache2" systemctl enable --now apache2
            fi
            return 0
            ;;
    esac
}

resolve_port80() {   # 0 = tiếp tục cài, 1 = hủy
    local owner choice
    if ! owner="$(port80_owner)"; then
        mark_ok "Cổng 80 đang trống — không có xung đột"
        return 0
    fi

    if [ "$owner" = "nginx" ]; then
        mark_ok "nginx đang giữ cổng 80 — không có xung đột"
        return 0
    fi

    echo -e "   ${YELLOW}[CẢNH BÁO] Cổng 80 đang bị chiếm bởi:${BOLD} $owner${NC}"
    echo ""

    if [ "$owner" = "apache2" ] || [ "$owner" = "apache2ctl" ] || [ "$owner" = "httpd" ]; then
        echo -e "   ${BOLD}Chọn cách xử lý Apache2:${NC}"
        echo -e "   ${GREEN}[1]${NC} Đổi Apache2 sang cổng $APACHE_PORT (vẫn chạy, có backup, hoàn tác được)"
        echo -e "   ${GREEN}[2]${NC} Dừng + tắt Apache2 (nginx giữ trọn cổng 80)"
        echo -e "   ${GREEN}[3]${NC} Hủy cài nginx"
        read -rp "   Chọn [1-3]: " choice
        case "$choice" in
            1)  apache_move_to_8080 || return 1 ;;
            2)  apache_stop_for_nginx ;;
            *)  echo -e "   ${YELLOW}Đã hủy cài nginx.${NC}"; return 1 ;;
        esac
        return 0
    fi

    echo -e "   ${YELLOW}Đây không phải Apache2 — script không tự đụng service lạ.${NC}"
    read -rp "   Vẫn cài nginx (có thể fail bind cổng 80)? (y/N): " choice
    [[ "$choice" =~ ^[Yy]$ ]] || { echo -e "   ${YELLOW}Đã hủy cài nginx.${NC}"; return 1; }
    return 0
}

# ------------------------------------------------------------
# [1] Cài nginx
# ------------------------------------------------------------

item_nginx_install() {
    begin_item
    echo -e "${BLUE}${BOLD}== [1] Cài nginx ==${NC}"

    if nginx_installed; then
        mark_skip "nginx $(nginx -v 2>&1 | sed 's|.*/nginx/||')"
        # đã tạm tắt ở mục [9]? → phải nhường lại cổng 80 trước khi start
        resolve_port80 || { end_item; return 1; }
        run_step "systemctl enable nginx" systemctl enable nginx
        run_step "systemctl start nginx" systemctl start nginx
        sleep 1
        local owner
        if owner="$(port80_owner)"; then
            if [ "$owner" = "nginx" ]; then
                mark_ok "nginx đang giữ cổng 80"
            else
                FAILED_ITEMS+=("[1] nginx không giữ được cổng 80 (bị $owner chiếm)")
            fi
        else
            FAILED_ITEMS+=("[1] không có process nào listen cổng 80")
        fi
        state_del NGINX_MODE
        end_item
        return 0
    fi

    if have_cmd curl && ! curl -fsSI --max-time 8 http://vn.archive.ubuntu.com >/dev/null 2>&1; then
        echo -e "   ${YELLOW}[CẢNH BÁO] Có vẻ máy chưa có Internet — apt có thể thất bại.${NC}"
    fi

    resolve_port80 || { end_item; return 1; }

    run_step "apt-get install nginx" apt-get install -y nginx
    if ! nginx_installed; then
        end_item
        return 1
    fi

    run_step "nginx -t" nginx -t
    run_step "systemctl enable --now nginx" systemctl enable --now nginx
    sleep 1

    local owner
    if owner="$(port80_owner)"; then
        if [ "$owner" = "nginx" ]; then
            mark_ok "nginx đang giữ cổng 80"
        else
            FAILED_ITEMS+=("[1] nginx không giữ được cổng 80 (bị $owner chiếm)")
        fi
    else
        FAILED_ITEMS+=("[1] không có process nào listen cổng 80")
    fi
    end_item
}

# ------------------------------------------------------------
# [2] Trạng thái
# ------------------------------------------------------------

item_nginx_status() {
    begin_item
    echo -e "${BLUE}${BOLD}== [2] Trạng thái nginx & site ==${NC}"

    if nginx_installed; then
        mark_ok "Gói nginx: $(dpkg-query -W -f='${Version}' nginx 2>/dev/null)"
    else
        echo -e "   ${YELLOW}Gói nginx: chưa cài (chạy mục [1])${NC}"
        end_item
        return 0
    fi

    if systemctl is-active --quiet nginx; then
        if systemctl is-enabled nginx >/dev/null 2>&1; then
            mark_ok "Service: active + enabled"
        else
            echo -e "   ${YELLOW}Service: active nhưng disabled — bật khi boot: systemctl enable nginx${NC}"
        fi
    else
        if [ "$(state_get NGINX_MODE)" = "paused" ]; then
            echo -e "   ${YELLOW}Service: đã tạm tắt bởi mục [9] — chạy mục [1] để bật lại${NC}"
        else
            echo -e "   ${RED}Service: $(systemctl is-active nginx 2>/dev/null) — chạy mục [1]${NC}"
        fi
    fi

    local owner
    if owner="$(port80_owner)"; then
        if [ "$owner" = "nginx" ]; then
            mark_ok "Cổng 80: nginx"
        else
            echo -e "   ${YELLOW}Cổng 80: bị $owner chiếm${NC}"
        fi
    else
        echo -e "   ${YELLOW}Cổng 80: trống${NC}"
    fi

    if nginx -t >/dev/null 2>&1; then
        mark_ok "nginx -t: Syntax OK"
    else
        echo -e "   ${RED}nginx -t THẤT BẠI:${NC}"
        nginx -t 2>&1 | sed 's/^/       /'
        FAILED_ITEMS+=("nginx -t fail")
    fi

    local amode
    amode="$(state_get APACHE_MODE)"
    case "$amode" in
        port)    mark_ok "Apache2: đã chuyển sang cổng $APACHE_PORT bởi script này" ;;
        stopped) mark_ok "Apache2: đã dừng/disabled bởi script này" ;;
    esac
    if [ "$(state_get NGINX_MODE)" = "paused" ]; then
        mark_ok "nginx: đang tạm tắt (mục [9]) — chạy mục [1] để bật lại"
    fi

    echo ""
    print_sites || true

    if php_fpm_installed; then
        mark_ok "PHP-FPM: đã cài ($(php_fpm_socket || echo 'chưa chạy'))"
    elif have_cmd php; then
        echo -e "   ${YELLOW}PHP: đã có nhưng thiếu php-fpm → site chỉ chạy static${NC}"
    else
        echo -e "   ${YELLOW}PHP: chưa có → site chạy static${NC}"
    fi

    end_item
}

# ------------------------------------------------------------
# [3] Tạo project mới
# ------------------------------------------------------------

valid_name() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; }

# Đưa tên folder bất kỳ về dạng dùng được làm domain/conf:
#   nail360UserLight → nail360-user-light · files-lexor-com → files-lexor-com · A.B_C → a-b-c
slugify() {
    printf '%s' "$1" \
        | sed -E 's/([a-z0-9])([A-Z])/\1-\2/g' \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//' \
        | cut -c1-63 \
        | sed -E 's/-+$//'
}

valid_domain() {
    [[ "$1" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]]
}

# Chuẩn hoá domain người dùng gõ: bỏ khoảng trắng 2 đầu/thường hoá/thêm .test nếu thiếu
norm_domain() {
    local d
    d="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
    d="${d%.}"
    if [ -n "$d" ] && [[ "$d" != *.* ]]; then
        d="$d.test"
    fi
    printf '%s' "$d"
}

index_template() {   # index_template <ten> <file>
    cat > "$2" <<EOF
<!doctype html>
<html lang="vi">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>$1</title>
    <style>
        body { font-family: system-ui, sans-serif; margin: 0; min-height: 100vh;
               display: grid; place-items: center; background: #0f172a; color: #e2e8f0; }
        .card { text-align: center; padding: 3rem 2rem; border: 1px solid #334155;
                border-radius: 12px; background: #1e293b; }
        h1 { margin: 0 0 .5rem; color: #38bdf8; }
        p  { margin: .25rem 0; color: #94a3b8; }
        code { background: #0f172a; padding: .15rem .4rem; border-radius: 4px; }
    </style>
</head>
<body>
    <div class="card">
        <h1>$1</h1>
        <p>Project local đã sẵn sàng.</p>
        <p>Thư mục web: <code>$WWW_ROOT/$1</code></p>
        <p>Thay file <code>index.html</code> để bắt đầu.</p>
    </div>
</body>
</html>
EOF
}

item_project_create() {
    begin_item
    echo -e "${BLUE}${BOLD}== [3] Tạo project mới (folder + index + vhost) ==${NC}"
    require_nginx || { end_item; return 1; }

    local name slug ch
    read -rp "   Tên project: " name
    if [ -z "$name" ]; then
        echo -e "   ${YELLOW}Chưa nhập tên — hủy.${NC}"
        end_item
        return 0
    fi
    slug="$(slugify "$name")"
    if [ -z "$slug" ] || ! valid_name "$slug"; then
        echo -e "   ${RED}Tên '$name' không suy ra được domain — hãy dùng tên có chữ/số.${NC}"
        FAILED_ITEMS+=("[3] tên project không dùng được")
        end_item
        return 1
    fi
    if [ "$slug" != "$name" ]; then
        echo -e "   ${YELLOW}'$name' không dùng trực tiếp được → thư mục + site:${NC} ${BOLD}$slug${NC} (http://$slug.test)"
        read -rp "   Dùng '$slug'? (Y/n): " ch
        if [[ "$ch" =~ ^[Nn]$ ]]; then
            echo -e "   ${YELLOW}Đã hủy.${NC}"
            end_item
            return 0
        fi
    fi
    name="$slug"

    local docroot="$WWW_ROOT/$name"
    if [ -d "$docroot" ]; then
        echo -e "   ${YELLOW}Thư mục $docroot đã tồn tại — dùng luôn folder này.${NC}"
    else
        run_step "mkdir $docroot" mkdir -p "$docroot"
        chown -R "$REAL_USER:$REAL_GROUP" "$docroot"
        mark_ok "Đã tạo $docroot (owner: $REAL_USER)"
    fi

    if [ ! -f "$docroot/index.html" ] && [ ! -f "$docroot/index.php" ]; then
        index_template "$name" "$docroot/index.html"
        chown "$REAL_USER:$REAL_GROUP" "$docroot/index.html"
        mark_ok "Đã sinh index.html mẫu"
    else
        echo -e "   ${YELLOW}Folder đã có index — giữ nguyên.${NC}"
    fi

    create_site "$name" "${name}.test" "$docroot"
    end_item
}

# ------------------------------------------------------------
# [4] Thêm project có sẵn
# ------------------------------------------------------------

item_project_add() {
    begin_item
    echo -e "${BLUE}${BOLD}== [4] Thêm project có sẵn (folder → http://<tên>.test) ==${NC}"
    require_nginx || { end_item; return 1; }

    local dirs=() d name i=1
    shopt -s nullglob
    for d in "$WWW_ROOT"/*/; do
        dirs+=("$(basename "$d")")
    done
    shopt -u nullglob

    if [ ${#dirs[@]} -eq 0 ]; then
        echo -e "   ${YELLOW}Không có folder nào trong $WWW_ROOT.${NC}"
        end_item
        return 1
    fi

    echo -e "   ${BOLD}Các folder trong $WWW_ROOT:${NC}"
    for name in "${dirs[@]}"; do
        local mark=""
        [ -f "$NGINX_AVAIL/$name.conf" ] && mark="  ${YELLOW}(đã có site)${NC}"
        printf "   [%2d] %b%s%b\n" "$i" "$mark" "$name" "$NC"
        i=$((i+1))
    done
    echo ""
    read -rp "   Chọn SỐ thứ tự (Enter = quay lại): " ans
    [ -z "$ans" ] && { end_item; return 0; }
    if [[ ! "$ans" =~ ^[0-9]+$ ]] || [ "$ans" -lt 1 ] || [ "$ans" -gt ${#dirs[@]} ]; then
        echo -e "   ${RED}Lựa chọn không hợp lệ.${NC}"
        FAILED_ITEMS+=("[4] lựa chọn không hợp lệ")
        end_item
        return 1
    fi

    name="${dirs[$((ans-1))]}"
    local slug domain ch
    slug="$(slugify "$name")"
    if [ -z "$slug" ] || ! valid_name "$slug"; then
        echo -e "   ${RED}Tên folder '$name' không suy ra được domain — hãy đổi tên folder.${NC}"
        FAILED_ITEMS+=("[4] tên folder không dùng được")
        end_item
        return 1
    fi

    echo -e "   ${BOLD}Folder:${NC}   $name"
    echo -e "   ${BOLD}Site/conf:${NC} $slug"
    while true; do
        read -rp "   Domain (Enter = ${slug}.test): " ch
        if [ -z "$ch" ]; then
            domain="${slug}.test"
            break
        fi
        ch="$(norm_domain "$ch")"
        if valid_domain "$ch"; then
            domain="$ch"
            break
        fi
        echo -e "   ${RED}Chưa hợp lệ: '$ch'${NC} — mẫu: my-site.test  (Enter = dùng mặc định)"
    done

    echo -e "   ${CYAN}➜ ${NC}http://$domain → $WWW_ROOT/$name${NC}"
    create_site "$slug" "$domain" "$WWW_ROOT/$name"
    end_item
}

# ------------------------------------------------------------
# [5] Danh sách + bật/tắt
# ------------------------------------------------------------

item_sites_toggle() {
    begin_item
    echo -e "${BLUE}${BOLD}== [5] Danh sách site + BẬT/TẮT ==${NC}"
    require_nginx || { end_item; return 1; }

    if ! print_sites; then
        end_item
        return 0
    fi

    echo ""
    read -rp "   Chọn SỐ để bật/tắt (Enter = quay lại): " ans
    [ -z "$ans" ] && { end_item; return 0; }
    if [[ ! "$ans" =~ ^[0-9]+$ ]] || [ "$ans" -lt 1 ] || [ "$ans" -gt ${#SITE_NAMES[@]} ]; then
        echo -e "   ${RED}Lựa chọn không hợp lệ.${NC}"
        FAILED_ITEMS+=("[5] lựa chọn không hợp lệ")
        end_item
        return 1
    fi

    local idx=$((ans-1))
    local name="${SITE_NAMES[$idx]}"
    local conf="$NGINX_AVAIL/$name.conf"
    local link="$NGINX_EN/$name.conf"
    local before="${SITE_STATES[$idx]}"
    local after="tắt"

    if [ "$before" = "tắt" ]; then
        ln -sfn "../sites-available/$name.conf" "$link"
        after="bật"
    else
        rm -f "$link"
    fi

    if nginx_test_reload; then
        mark_ok "Site '$name' chuyển sang trạng thái: ${BOLD}$after${NC}"
    else
        echo -e "   ${RED}nginx -t thất bại — hoàn tác.${NC}"
        if [ "$before" = "bật" ]; then
            ln -sfn "../sites-available/$name.conf" "$link"
        else
            rm -f "$link"
        fi
        nginx -t
        systemctl reload nginx 2>/dev/null
        FAILED_ITEMS+=("[5] bật/tắt $name (nginx -t fail, đã hoàn tác)")
    fi
    end_item
}

# ------------------------------------------------------------
# [6] Sửa cấu hình site
# ------------------------------------------------------------

pick_editor() {
    if [ -n "${EDITOR:-}" ] && have_cmd "$EDITOR"; then
        echo "$EDITOR"
    elif have_cmd nano; then
        echo nano
    elif have_cmd vim; then
        echo vim
    elif have_cmd editor; then
        echo editor
    else
        return 1
    fi
}

site_conf_changed() {   # site_conf_changed <conf> <backup> — giữ nguyên nếu nginx -t fail
    local conf="$1" bak="$2"
    if nginx_test_reload; then
        rm -f "$bak"
        mark_ok "Đã lưu và reload nginx"
        return 0
    fi
    echo -e "   ${RED}nginx -t thất bại — khôi phục file trước khi sửa.${NC}"
    cp -p "$bak" "$conf"
    rm -f "$bak"
    nginx -t
    systemctl reload nginx 2>/dev/null
    FAILED_ITEMS+=("sửa $conf (nginx -t fail, đã rollback)")
    return 1
}

item_site_edit() {
    begin_item
    echo -e "${BLUE}${BOLD}== [6] Sửa cấu hình site ==${NC}"
    require_nginx || { end_item; return 1; }
    pick_site || { end_item; return 0; }

    local name="${SITE_NAMES[$SITE_IDX]}"
    local conf="$NGINX_AVAIL/$name.conf"
    local choice

    echo ""
    echo -e "   ${BOLD}Chọn cách sửa:$NC"
    echo -e "   ${GREEN}[1]${NC} Mở file trong editor ($conf)"
    echo -e "   ${GREEN}[2]${NC} Đổi domain"
    echo -e "   ${GREEN}[3]${NC} Đổi DocumentRoot"
    read -rp "   Chọn [1-3]: " choice

    local bak="/tmp/${name}.conf.nginxdev.bak.$$"
    cp -p "$conf" "$bak"

    case "$choice" in
        1)
            local ed
            if ! ed="$(pick_editor)"; then
                echo -e "   ${RED}Không tìm thấy editor (nano/vim/editor).${NC}"
                rm -f "$bak"
                FAILED_ITEMS+=("[6] mở editor")
                end_item
                return 1
            fi
            echo -e "   ${CYAN}➜ ${NC}Mở $ed — thoát editor rồi script sẽ chạy nginx -t${NC}"
            "$ed" "$conf"
            site_conf_changed "$conf" "$bak"
            ;;
        2)
            local old new
            old="$(domain_of "$conf")"
            echo -e "   ${YELLOW}Domain hiện tại:${NC} $old"
            while true; do
                read -rp "   Domain mới (Enter = giữ nguyên): " new
                if [ -z "$new" ]; then
                    echo -e "   ${YELLOW}Giữ nguyên domain.${NC}"
                    rm -f "$bak"
                    end_item
                    return 0
                fi
                new="$(norm_domain "$new")"
                if valid_domain "$new"; then
                    break
                fi
                echo -e "   ${RED}Chưa hợp lệ: '$new'${NC} — mẫu: my-site.test  (Enter = giữ nguyên)"
            done
            sed -i "0,/server_name/s/server_name[^;]*;/server_name $new;/" "$conf"
            if site_conf_changed "$conf" "$bak"; then
                hosts_add "$new"
                [ "$old" != "$new" ] && hosts_del "$old"
                state_add_domain "$new"
                [ "$old" != "$new" ] && state_del_domain "$old"
                mark_ok "Domain mới: ${GREEN}http://$new${NC}"
            fi
            ;;
        3)
            local newroot
            echo -e "   ${YELLOW}DocumentRoot hiện tại:${NC} $(docroot_of "$conf")"
            read -rp "   Đường dẫn mới (bắt đầu bằng $WWW_ROOT/): " newroot
            if [ ! -d "$newroot" ]; then
                echo -e "   ${RED}Thư mục không tồn tại: $newroot${NC}"
                rm -f "$bak"
                FAILED_ITEMS+=("[6] docroot không tồn tại")
                end_item
                return 1
            fi
            sed -i "0,/root/s#root[^;]*;#root $newroot;#" "$conf"
            site_conf_changed "$conf" "$bak"
            ;;
        *)
            echo -e "   ${YELLOW}Đã hủy.${NC}"
            rm -f "$bak"
            ;;
    esac
    end_item
}

# ------------------------------------------------------------
# [7] Xóa site
# ------------------------------------------------------------

item_site_delete() {
    begin_item
    echo -e "${BLUE}${BOLD}== [7] Xóa site (giữ nguyên file project) ==${NC}"
    require_nginx || { end_item; return 1; }
    pick_site || { end_item; return 0; }

    local name="${SITE_NAMES[$SITE_IDX]}"
    local domain="${SITE_DOMAINS[$SITE_IDX]}"
    local conf="$NGINX_AVAIL/$name.conf"
    local link="$NGINX_EN/$name.conf"
    local ok

    echo ""
    echo -e "   Sắp xóa: ${BOLD}$domain${NC} ($conf)"
    echo -e "   ${YELLOW}Giữ nguyên:${NC} ${SITE_DOCROOTS[$SITE_IDX]}"
    read -rp "   Xác nhận xóa? (y/N): " ok
    if [[ ! "$ok" =~ ^[Yy]$ ]]; then
        echo -e "   ${YELLOW}Đã hủy.${NC}"
        end_item
        return 0
    fi

    rm -f "$link" "$conf"
    [ -n "$domain" ] && hosts_del "$domain"
    [ -n "$domain" ] && state_del_domain "$domain"
    rm -f "/var/log/nginx/$name-access.log" "/var/log/nginx/$name-error.log"

    if nginx_test_reload; then
        mark_ok "Đã xóa site $domain — file project vẫn còn"
    else
        nginx -t
        FAILED_ITEMS+=("[7] xóa $domain (nginx -t fail)")
    fi
    end_item
}

# ------------------------------------------------------------
# [8] Gỡ hoàn toàn nginx
# ------------------------------------------------------------

item_nginx_uninstall() {
    begin_item
    echo -e "${BLUE}${BOLD}== [8] Gỡ hoàn toàn nginx ==${NC}"

    local domains=() d ok
    while IFS= read -r d; do
        [ -n "$d" ] && domains+=("$d")
    done < <(collect_uninstall_domains | sort -u)

    echo -e "   ${BOLD}Danh sách sẽ bị gỡ:${NC}"
    if nginx_installed; then
        echo "     - Gói apt: nginx* (nginx, nginx-common, module phụ) + autoremove"
    else
        echo "     - Gói apt: (chưa cài — chỉ dọn dư liệu)"
    fi
    if [ ${#domains[@]} -gt 0 ]; then
        printf "     - Dòng /etc/hosts của: %s\n" "${domains[*]}"
    fi
    if [ -d "$NGINX_AVAIL" ]; then
        echo "     - Toàn bộ $NGINX_AVAIL và $NGINX_EN"
    fi
    local amode
    amode="$(state_get APACHE_MODE)"
    case "$amode" in
        port)    echo "     - Đưa Apache2 về lại cổng 80 (hoàn tác)";;
        stopped) echo "     - Bật lại apache2 (đã bị script dừng)";;
    esac
    echo -e "     ${GREEN}KHÔNG${NC} đụng tới $WWW_ROOT và mọi file project"
    echo ""
    read -rp "   Tiếp tục gỡ? (y/N): " ok
    if [[ ! "$ok" =~ ^[Yy]$ ]]; then
        echo -e "   ${YELLOW}Đã hủy.${NC}"
        end_item
        return 0
    fi

    if nginx_installed; then
        run_step "apt-get purge 'nginx*'" apt-get purge -y 'nginx*'
        run_step "apt-get autoremove" apt-get autoremove -y
    fi

    if [ -d /etc/nginx ]; then
        echo -e "   ${CYAN}➜ ${NC}Dọn /etc/nginx còn sót${NC}"
        rm -rf /etc/nginx
    fi

    for d in "${domains[@]}"; do
        hosts_del "$d"
    done

    apache_restore_to_80 || true

    rm -f "$STATE_FILE"
    mark_ok "Gỡ nginx xong — dữ liệu project trong $WWW_ROOT giữ nguyên"
    end_item
}

collect_uninstall_domains() {
    local c
    # domain đọc từ conf còn lại
    shopt -s nullglob
    for c in "$NGINX_AVAIL"/*.conf; do
        domain_of "$c"
    done
    shopt -u nullglob
    # domain đã ghi vào state (phòng khi conf bị xóa tay)
    state_domains
}

# ------------------------------------------------------------
# [9] Bật lại Apache cổng 80 · tạm tắt nginx
# ------------------------------------------------------------

item_apache_back_80() {
    begin_item
    echo -e "${BLUE}${BOLD}== [9] Bật lại Apache cổng 80 · tạm tắt nginx ==${NC}"

    if ! pkg_ok apache2; then
        echo -e "   ${RED}apache2 chưa cài — tắt nginx thì sẽ không còn server nào.${NC}"
        FAILED_ITEMS+=("[9] apache2 chưa cài")
        end_item
        return 1
    fi

    local amode choice owner
    amode="$(state_get APACHE_MODE)"

    echo -e "   ${BOLD}Việc sẽ làm:${NC}"
    echo "     1. systemctl stop + disable nginx   (tạm — mục [1] sẽ bật lại)"
    case "$amode" in
        port)    echo "     2. Đưa Apache2 từ cổng $APACHE_PORT về lại cổng 80 (hoàn tác backup)";;
        stopped) echo "     2. enable --now apache2   (script này đã từng dừng nó)";;
        *)       echo "     2. enable --now apache2   (Apache giữ nguyên cấu hình :80)";;
    esac
    echo "     3. Kiểm tra ai thực sự giữ cổng 80"
    echo -e "   ${YELLOW}Site nginx (http://<tên>.test) sẽ KHÔNG phản hồi trong lúc tạm tắt.${NC}"
    echo ""
    read -rp "   Tiếp tục? (y/N): " choice
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        echo -e "   ${YELLOW}Đã hủy.${NC}"
        end_item
        return 0
    fi

    # 1. dừng nginx trước để giải phóng cổng 80 cho Apache
    if nginx_installed; then
        run_step "systemctl stop nginx" systemctl stop nginx
        run_step "systemctl disable nginx" systemctl disable nginx
        state_set NGINX_MODE paused
        mark_ok "nginx đã tạm tắt (stop + disable)"
    else
        echo -e "   ${YELLOW}nginx chưa cài — chỉ dựng Apache.${NC}"
    fi

    # 2. đưa Apache về cổng 80
    if ! apache_restore_to_80; then
        FAILED_ITEMS+=("[9] đưa Apache về cổng 80")
    fi

    # 3. xác minh ai giữ cổng 80
    sleep 1
    if owner="$(port80_owner)"; then
        if [ "$owner" = "apache2" ]; then
            mark_ok "Apache2 đang giữ cổng 80"
        else
            FAILED_ITEMS+=("[9] cổng 80 đang bị $owner chiếm")
        fi
    else
        FAILED_ITEMS+=("[9] không có process nào listen cổng 80")
    fi
    end_item
}

# ------------------------------------------------------------
# Menu
# ------------------------------------------------------------

show_menu() {
    clear
    echo ""
    echo -e "${BOLD}${BLUE}=============================================================${NC}"
    echo -e "${BOLD}${BLUE}   NGINX — CÀI ĐẶT / GỠ CÀI ĐẶT / QUẢN LÝ PROJECT LOCAL${NC}"
    echo -e "${BOLD}${BLUE}   User: $REAL_USER${NC}"
    echo -e "${BOLD}${BLUE}=============================================================${NC}"
    echo ""
    echo -e "  ${BOLD}--- NGINX ---${NC}"
    echo -e "   ${GREEN}[1]${NC}  Cài nginx (kiểm tra cổng 80 trước)"
    echo -e "   ${GREEN}[2]${NC}  Trạng thái (service · cổng · nginx -t · site)"
    echo ""
    echo -e "  ${BOLD}--- QUẢN LÝ PROJECT ---${NC}"
    echo -e "   ${GREEN}[3]${NC}  Tạo project mới (folder + index + vhost)"
    echo -e "   ${GREEN}[4]${NC}  Thêm project có sẵn (folder → http://<tên>.test)"
    echo -e "   ${GREEN}[5]${NC}  Danh sách site + BẬT/TẮT"
    echo -e "   ${GREEN}[6]${NC}  Sửa cấu hình site (editor / domain / docroot)"
    echo -e "   ${GREEN}[7]${NC}  Xóa site (giữ nguyên file project)"
    echo ""
    echo -e "  ${BOLD}--- NGHIỆP VỤ ---${NC}"
    echo -e "   ${GREEN}[8]${NC}  Gỡ hoàn toàn nginx"
    echo -e "   ${GREEN}[9]${NC}  Bật lại Apache cổng 80 · tạm tắt nginx"
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
        read -rp "Chọn mục [0-9]: " choice
        case "$choice" in
            1)  item_nginx_install;     pause_enter ;;
            2)  item_nginx_status;      pause_enter ;;
            3)  item_project_create;    pause_enter ;;
            4)  item_project_add;       pause_enter ;;
            5)  item_sites_toggle;      pause_enter ;;
            6)  item_site_edit;         pause_enter ;;
            7)  item_site_delete;       pause_enter ;;
            8)  item_nginx_uninstall;   pause_enter ;;
            9)  item_apache_back_80;    pause_enter ;;
            0)  print_summary; exit 0 ;;
            "") ;;
            *)  echo -e "${RED}Lựa chọn không hợp lệ!${NC}"; sleep 1 ;;
        esac
    done
}

main_loop
