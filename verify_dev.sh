#!/bin/bash
# ============================================================
# verify_dev.sh — STATE VALIDATOR cho setup_dev.sh / reset_dev.sh
# HOÀN TOÀN READ-ONLY: chỉ đọc/phân tích/báo cáo, không sửa gì
# Cách dùng:
#   sudo bash verify_dev.sh --setup  [--skip component,component]
#   sudo bash verify_dev.sh --reset
#   sudo bash verify_dev.sh --all
# ============================================================

set -o pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[1;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS="$(date +%Y%m%d_%H%M%S)"
LOG_DIR="$SCRIPT_DIR/logs"
LOG_FILE="$LOG_DIR/verify_$TS.log"

WWW_ROOT="/var/www/html"
APACHE_CONF="/etc/apache2/sites-available/000-default.conf"
APACHE_SITES="/etc/apache2/sites-available"
APACHE_ENABLED="/etc/apache2/sites-enabled"

MODE=""
SKIP_LIST=""
CURRENT_SUITE=""

PC=0; FC=0; WC=0; SC=0
FAILED_TITLES=()

# ------------------------------------------------------------
# Framework
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

is_skipped() {
    local comp
    comp="$(echo "$1" | tr '[:upper:]' '[:lower:]')"
    [[ ",$(echo "$SKIP_LIST" | tr '[:upper:]' '[:lower:]')," == *",$comp,"* ]]
}

emit() {
    local v="$1" title="$2"
    case "$v" in
        PASS) PC=$((PC+1)); echo -e "  ${GREEN}[PASS]${NC} $title" ;;
        FAIL) FC=$((FC+1)); FAILED_TITLES+=("[$CURRENT_SUITE] $title")
              echo -e "  ${RED}${BOLD}[FAIL]${NC} $title" ;;
        WARN) WC=$((WC+1)); echo -e "  ${YELLOW}[WARN]${NC} $title" ;;
        SKIP) SC=$((SC+1)); echo -e "  ${DIM}[SKIP]${NC} $title" ;;
    esac
}

detail() { echo -e "        $*"; }

print_summary() {
    SUMMARY_PRINTED=1
    echo ""
    echo -e "${BOLD}================ TỔNG KẾT VERIFY ($SUITE_LABEL) ================${NC}"
    echo -e "  ${GREEN}PASS: $PC${NC}   ${RED}FAIL: $FC${NC}   ${YELLOW}WARN: $WC${NC}   ${DIM}SKIP: $SC${NC}"
    if [ ${#FAILED_TITLES[@]} -gt 0 ]; then
        echo -e "${RED}${BOLD}Các mục FAIL:${NC}"
        local t
        for t in "${FAILED_TITLES[@]}"; do
            echo -e "  ${RED}✗${NC} $t"
        done
    fi
    echo -e "Log: ${CYAN}$LOG_FILE${NC}"
}

TOTAL_FAILS=0

trap '[ $SUMMARY_PRINTED -eq 0 ] && print_summary' EXIT
SUMMARY_PRINTED=0

finish_suite() {
    print_summary
    TOTAL_FAILS=$((TOTAL_FAILS + FC))
    SUMMARY_PRINTED=0
}

usage() {
    cat <<EOF
Cách dùng: sudo bash verify_dev.sh <mode> [--skip c1,c2,...]

Modes:
  --setup   Kiểm tra trạng thái SAU KHI CHẠY setup_dev.sh (state INSTALLED)
  --reset   Kiểm tra trạng thái SAU KHI CHẠY reset_dev.sh (state CLEAN)
  --all     Chạy cả hai suite liên tiếp (kết quả đọc theo từng suite)

--skip: danh sách component chủ ý không yêu cầu, cách nhau bởi dấu phẩy.
Tokens hợp lệ: git apache rewrite configtest conf php nvm node vscode
chrome vim meld bamboo flutter android vhost hosts rootuser www documents

Exit code: 0 = không có FAIL, 1 = có ít nhất một FAIL.
EOF
}

# ------------------------------------------------------------
# Môi trường
# ------------------------------------------------------------

if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Script cần quyền root để đọc đầy đủ trạng thái hệ thống.${NC}"
    echo -e "Chạy lại bằng: ${BOLD}sudo bash $0 <mode>${NC}"
    exit 2
fi
REAL_USER="${SUDO_USER:-}"
if [ -z "$REAL_USER" ] || [ "$REAL_USER" = "root" ]; then
    echo -e "${RED}Không xác định được user thường (SUDO_USER trống).${NC}"
    echo -e "Đăng nhập bằng user thường rồi chạy: ${BOLD}sudo bash $0 <mode>${NC}"
    exit 2
fi
REAL_UID="$(id -u "$REAL_USER")"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"

mkdir -p "$LOG_DIR"
touch "$LOG_FILE"
chmod 644 "$LOG_FILE"
exec > >(tee -a "$LOG_FILE") 2>&1

RC_FILES=("$REAL_HOME/.bashrc" "$REAL_HOME/.profile" "$REAL_HOME/.bash_profile")

rc_grep_count() {
    local pat="$1" f c out=0
    for f in "${RC_FILES[@]}"; do
        [ -f "$f" ] || continue
        c="$(grep -cE "$pat" "$f" 2>/dev/null)" || c=0
        out=$((out + c))
    done
    echo "$out"
}

nvm_query() {
    as_user bash -c ". '$REAL_HOME/.nvm/nvm.sh' >/dev/null 2>&1; $1" 2>/dev/null
}

# ------------------------------------------------------------
# Các check — MODE SETUP (state INSTALLED)
# ------------------------------------------------------------

setup_git() {
    if is_skipped git; then emit SKIP "Git"; detail "--skip"; return; fi
    if pkg_ok git && have_cmd git; then
        emit PASS "Git ($(git --version 2>/dev/null))"
    elif have_cmd git; then
        emit WARN "Git"
        detail "Binary có nhưng package git không qua dpkg — nguồn cài lạ?"
        detail "→ Kiểm tra: dpkg-query -W git"
    else
        emit FAIL "Git"
        detail "Expected: git cài qua apt (dpkg) + binary hoạt động"
        detail "Found: không thấy cả hai"
        detail "→ Chạy mục [2] trong setup_dev.sh; xem logs/setup_*.log"
    fi
}

setup_apache_core() {
    if is_skipped apache; then emit SKIP "Apache2"; detail "--skip"; return; fi
    local problems=()
    pkg_ok apache2 || problems+=("package apache2 chưa cài")
    systemctl is-active --quiet apache2 || problems+=("service apache2 không active")
    [ "$(systemctl is-enabled apache2 2>/dev/null)" = "enabled" ] || problems+=("service chưa enable")
    if [ ${#problems[@]} -eq 0 ]; then
        emit PASS "Apache2 (active + enabled)"
    else
        emit FAIL "Apache2"
        local p
        for p in "${problems[@]}"; do detail "Found: $p"; done
        detail "→ Chạy mục [3] setup_dev.sh; xem logs/setup_*.log"
    fi
}

setup_rewrite() {
    if is_skipped rewrite; then emit SKIP "mod_rewrite"; detail "--skip"; return; fi
    if [ -e /etc/apache2/mods-enabled/rewrite.load ] \
        && apache2ctl -M 2>/dev/null | grep -qw rewrite_module; then
        emit PASS "mod_rewrite"
    else
        emit FAIL "mod_rewrite"
        detail "Expected: mods-enabled/rewrite.load + xuất hiện trong apache2ctl -M"
        detail "→ a2enmod rewrite rồi systemctl reload apache2 (thủ công — verify không tự sửa)"
    fi
}

setup_configtest() {
    if is_skipped configtest; then emit SKIP "Apache configtest"; detail "--skip"; return; fi
    local ct_out ct_rc
    ct_out="$(apache2ctl configtest 2>&1)"; ct_rc=$?
    # Lưu ý: "Syntax OK" nằm ở stderr, nên tin exit code thay vì parse stdout
    if [ "$ct_rc" -eq 0 ]; then
        emit PASS "Apache configtest (Syntax OK)"
    else
        emit FAIL "Apache configtest"
        detail "Expected: apache2ctl configtest thoát mã 0 (Syntax OK)"
        detail "Found: rc=$ct_rc — $(head -n2 <<< "$ct_out" | tr '\n' ' ')"
        detail "→ Không tự động sửa. Soi logs/setup_*.log và apache2ctl configtest"
    fi
}

setup_multiproject_conf() {
    if is_skipped conf; then emit SKIP "Apache multi-project conf"; detail "--skip"; return; fi
    local miss=()
    [ -f "$APACHE_CONF" ] || miss+=("không tồn tại $APACHE_CONF")
    if [ ${#miss[@]} -eq 0 ]; then
        grep -qE '^\s*DocumentRoot\s+/var/www/html' "$APACHE_CONF" \
            || miss+=("thiếu 'DocumentRoot /var/www/html'")
        grep -q '<Directory /var/www/html>' "$APACHE_CONF" \
            || miss+=("thiếu khối <Directory /var/www/html>")
        grep -q 'AllowOverride All' "$APACHE_CONF" \
            || miss+=("thiếu AllowOverride All")
        grep -q 'Require all granted' "$APACHE_CONF" \
            || miss+=("thiếu Require all granted")
    fi
    if [ ${#miss[@]} -eq 0 ]; then
        local bakcount bakf
        bakcount=0
        for bakf in "$APACHE_CONF".setup-bak-*; do
            [ -e "$bakf" ] && bakcount=$((bakcount+1))
        done
        emit PASS "Apache multi-project conf (localhost/tenproject)"
        [ "$bakcount" -gt 0 ] && detail "${DIM}Info: có $bakcount file backup gốc (.setup-bak-*)${NC}"
    else
        emit FAIL "Apache multi-project conf"
        local m
        for m in "${miss[@]}"; do detail "Found: $m"; done
        detail "→ Chạy mục [4] setup_dev.sh; xem logs/setup_*.log"
    fi
}

setup_php() {
    if is_skipped php; then emit SKIP "PHP 8.3"; detail "--skip"; return; fi
    if ! pkg_ok php || ! pkg_ok libapache2-mod-php || ! have_cmd php; then
        emit FAIL "PHP 8.3"
        detail "Expected: php + libapache2-mod-php cài qua apt, binary php hoạt động"
        detail "Found: pkg php=$(pkg_ok php && echo yes || echo no), mod-php=$(pkg_ok libapache2-mod-php && echo yes || echo no)"
        detail "→ Chạy mục [5] setup_dev.sh; xem logs/setup_*.log"
        return
    fi
    local ver
    ver="$(php -r 'echo PHP_VERSION;' 2>/dev/null)"
    if [[ "$ver" =~ ^8\.3\. ]]; then
        emit PASS "PHP 8.3 ($ver)"
    else
        emit FAIL "PHP 8.3"
        detail "Expected: 8.3.x (Ubuntu 24.04 repo)"
        detail "Found: ${ver:-không đọc được version}"
        detail "→ Kiểm tra logs/setup_*.log; không tự động nâng/hạ version"
    fi
}

setup_php_ext() {
    if is_skipped php; then emit SKIP "PHP extensions"; detail "--skip"; return; fi
    if ! have_cmd php; then
        emit SKIP "PHP extensions"
        detail "php binary không tồn tại — đã FAIL ở dòng trên"
        return
    fi
    local m list missing=()
    list="$(php -m 2>/dev/null)"
    for m in curl gd mbstring xml zip bcmath intl sqlite3; do
        grep -qx "$m" <<< "$list" || missing+=("$m")
    done
    if [ ${#missing[@]} -eq 0 ]; then
        emit PASS "PHP extensions (curl gd mbstring xml zip bcmath intl sqlite3)"
    else
        emit FAIL "PHP extensions"
        detail "Thiếu: ${missing[*]}"
        detail "→ Cài thủ công: sudo apt-get install php8.3-${missing[0]} ... hoặc chạy lại mục [5]"
    fi
}

setup_nvm() {
    if is_skipped nvm; then emit SKIP "NVM"; detail "--skip"; return; fi
    local nvm_dir="$REAL_HOME/.nvm" nvm_sh="$REAL_HOME/.nvm/nvm.sh"
    if [ ! -f "$nvm_sh" ]; then
        emit FAIL "NVM"
        detail "Expected: $nvm_sh tồn tại (cho user $REAL_USER)"
        detail "Found: không thấy — hoặc chưa cài, hoặc bị cài nhầm vào /home khác"
        detail "→ Chạy mục [6] setup_dev.sh; xem logs/setup_*.log"
        return
    fi
    local owner
    owner="$(stat -c '%U' "$nvm_dir" 2>/dev/null)"
    if [ "$owner" != "$REAL_USER" ]; then
        emit FAIL "NVM"
        detail "Expected: owner của ~/.nvm là $REAL_USER"
        detail "Found: $owner"
        detail "→ chown -R $REAL_USER: '$nvm_dir' (thủ công)"
        return
    fi
    local ver
    ver="$(nvm_query 'nvm --version')"
    if ! [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        emit FAIL "NVM"
        detail "Expected: nvm --version trả semver khi source ~/.nvm/nvm.sh"
        detail "Found: '${ver:-rỗng}'"
        detail "→ Xem logs/setup_*.log"
        return
    fi
    local blk
    blk="$(rc_grep_count 'export NVM_DIR=')"
    if [ "$blk" -gt 1 ]; then
        emit FAIL "NVM"
        detail "Phát hiện DUPLICATE: khối NVM được chèn $blk lần trong rc-files (chỉ được 1)"
        detail "→ Xóa bớt block thừa trong ~/.bashrc (verify không tự sửa)"
    else
        emit PASS "NVM (v$ver, owner=$owner, rc-block đúng 1 lần)"
    fi
}

setup_node() {
    if is_skipped node; then emit SKIP "Node.js LTS"; detail "--skip"; return; fi
    if [ ! -f "$REAL_HOME/.nvm/nvm.sh" ]; then
        emit SKIP "Node.js LTS"
        detail "NVM chưa có — đã báo ở dòng NVM phía trên"
        return
    fi
    local npath nver alias_out
    npath="$(nvm_query 'command -v node')"
    if [ -z "$npath" ]; then
        emit FAIL "Node.js LTS"
        detail "Expected: node resolve QUA ~/.nvm/versions/node/*/bin (chứng minh cài đúng method)"
        detail "Found: nvm không trả về node nào"
        detail "→ Chạy mục [7] setup_dev.sh; xem logs/setup_*.log"
        return
    fi
    case "$npath" in
        "$REAL_HOME"/.nvm/versions/node/*) : ;;
        *)
            emit FAIL "Node.js LTS"
            detail "Expected: node nằm dưới $REAL_HOME/.nvm/versions/node/"
            detail "Found: $npath (nguồn cài khác NVM)"
            detail "→ Không tự xử lý; xác nhận ý đồ rồi gỡ/cài lại đúng method"
            return ;;
    esac
    nver="$(nvm_query 'node --version')"
    if ! [[ "$nver" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        emit FAIL "Node.js LTS"
        detail "Expected: node --version dạng vX.Y.Z"
        detail "Found: '${nver:-rỗng}'"
        return
    fi
    alias_out="$(nvm_query 'nvm alias default' 2>/dev/null)"
    if grep -q 'lts' <<< "$alias_out"; then
        emit PASS "Node.js LTS ($nver qua NVM, default=lts/*)"
    else
        emit WARN "Node.js LTS"
        detail "Node hoạt động ($nver) nhưng alias default không tham chiếu lts/*:"
        detail "Found: $(head -n1 <<< "$alias_out")"
        detail "→ Chạy: nvm alias default 'lts/*' (thủ công)"
    fi
}

setup_vscode() {
    if is_skipped vscode; then emit SKIP "Visual Studio Code"; detail "--skip"; return; fi
    if pkg_ok code && have_cmd code; then
        emit PASS "Visual Studio Code ($(code --version 2>/dev/null | head -n1))"
    else
        emit FAIL "Visual Studio Code"
        detail "Expected: package 'code' (deb Microsoft) + binary"
        detail "→ Chạy mục [8] setup_dev.sh; xem logs/setup_*.log"
    fi
}

setup_chrome() {
    if is_skipped chrome; then emit SKIP "Google Chrome"; detail "--skip"; return; fi
    if pkg_ok google-chrome-stable && have_cmd google-chrome; then
        emit PASS "Google Chrome ($(google-chrome --version 2>/dev/null))"
    else
        emit FAIL "Google Chrome"
        detail "Expected: package google-chrome-stable + binary"
        detail "→ Chạy mục [9] setup_dev.sh; xem logs/setup_*.log"
    fi
}

setup_vim() {
    if is_skipped vim; then emit SKIP "Vim"; detail "--skip"; return; fi
    if pkg_ok vim; then
        emit PASS "Vim (package vim đầy đủ)"
    else
        emit FAIL "Vim"
        detail "Expected: package 'vim' đầy đủ"
        detail "Found: chỉ có vim-tiny/vim-common mặc định của OS (hoặc không có)"
        detail "→ Chạy mục [10] setup_dev.sh; xem logs/setup_*.log"
    fi
}

setup_meld() {
    if is_skipped meld; then emit SKIP "Meld"; detail "--skip"; return; fi
    if pkg_ok meld && have_cmd meld; then
        emit PASS "Meld"
    else
        emit FAIL "Meld"
        detail "→ Chạy mục [11] setup_dev.sh; xem logs/setup_*.log"
    fi
}

setup_bamboo() {
    if is_skipped bamboo; then emit SKIP "IBus Bamboo"; detail "--skip"; return; fi
    local src_count=0 srcf
    for srcf in /etc/apt/sources.list.d/*bamboo*; do
        [ -e "$srcf" ] && src_count=$((src_count+1))
    done
    if ! pkg_ok ibus-bamboo; then
        emit FAIL "IBus Bamboo"
        detail "Expected: package ibus-bamboo từ PPA bamboo-engine"
        detail "→ Chạy mục [12] setup_dev.sh; xem logs/setup_*.log"
        return
    fi
    if [ "$src_count" -gt 1 ]; then
        emit FAIL "IBus Bamboo"
        detail "DUPLICATE PPA: có $src_count file *bamboo* trong sources.list.d (chỉ được 1)"
        detail "→ Xóa bớt file .list thừa (verify không tự sửa)"
    elif [ "$src_count" -eq 0 ]; then
        emit WARN "IBus Bamboo"
        detail "Package đã cài nhưng KHÔNG thấy PPA entry trong sources.list.d"
        detail "→ Bản cập nhật sau sẽ không tải được; kiểm tra tay: ls /etc/apt/sources.list.d/"
    else
        emit PASS "IBus Bamboo (pkg + PPA đúng 1 entry)"
    fi
}

setup_flutter() {
    if is_skipped flutter; then emit SKIP "Flutter"; detail "--skip"; return; fi
    local sdk="$REAL_HOME/development/flutter"
    if [ ! -x "$sdk/bin/flutter" ]; then
        emit FAIL "Flutter"
        detail "Expected: $sdk/bin/flutter tồn tại + executable (cho user $REAL_USER)"
        detail "→ Chạy mục [13] setup_dev.sh; xem logs/setup_*.log"
        return
    fi
    local owner
    owner="$(stat -c '%U' "$sdk" 2>/dev/null)"
    if [ "$owner" != "$REAL_USER" ]; then
        emit FAIL "Flutter"
        detail "Expected: owner SDK là $REAL_USER (KHÔNG phải root)"
        detail "Found: $owner"
        detail "→ chown -R $REAL_USER: '$sdk' (thủ công)"
        return
    fi
    local fver=""
    local jfile="$sdk/bin/cache/flutter.version.json"
    if [ -f "$jfile" ] && have_cmd jq; then
        fver="$(jq -r '.frameworkVersion // .flutterVersion // empty' "$jfile" 2>/dev/null)"
    elif [ -f "$jfile" ]; then
        fver="$(grep -oP '"frameworkVersion":\s*"\K[^"]+' "$jfile" 2>/dev/null)"
    fi
    if [ -z "$fver" ] && [ -f "$sdk/version" ]; then
        fver="$(head -n1 "$sdk/version" 2>/dev/null)"
    fi
    local pline
    pline="$(rc_grep_count 'development/flutter/bin')"
    local problems=()
    [ -z "$fver" ] && problems+=("không đọc được file version trong SDK")
    [ "$pline" -gt 1 ] && problems+=("DUPLICATE: PATH Flutter xuất hiện $pline lần trong rc-files (chỉ được 1)")
    [ "$pline" -eq 0 ] && problems+=("thiếu dòng PATH trong rc-files")
    if [ ${#problems[@]} -eq 0 ]; then
        emit PASS "Flutter (${fver:-?}, owner=$owner, PATH đúng 1 lần)"
        detail "${DIM}Gợi ý chạy tay: flutter doctor (verify không execute để giữ read-only)${NC}"
    else
        emit FAIL "Flutter"
        local p
        for p in "${problems[@]}"; do detail "Found: $p"; done
        detail "→ Sửa thủ công theo từng dòng ở trên; xem logs/setup_*.log"
    fi
}

setup_android() {
    if is_skipped android; then emit SKIP "Android Studio"; detail "--skip"; return; fi
    if ! have_cmd snap; then
        emit WARN "Android Studio"
        detail "Máy không có lệnh 'snap' — không thể xác minh"
        return
    fi
    if snap list android-studio >/dev/null 2>&1; then
        emit PASS "Android Studio (snap)"
    else
        emit FAIL "Android Studio"
        detail "Expected: snap android-studio (classic) — trừ khi team chủ ý bỏ qua"
        detail "→ Chạy mục [14] setup_dev.sh hoặc thêm --skip android"
    fi
}

setup_vhosts() {
    if is_skipped vhost; then emit SKIP "Virtual Host"; detail "--skip"; return; fi
    if [ ! -d "$APACHE_SITES" ]; then
        emit SKIP "Virtual Host"
        detail "Apache chưa cài — không có gì để verify"
        return
    fi
    local conf site domain
    declare -A SEEN_DOMAINS=()
    local VH_TOTAL=0 bad=0
    shopt -s nullglob
    for conf in "$APACHE_SITES"/*.conf; do
        domain="$(awk '/^[[:space:]]*ServerName[[:space:]]+/ {print $2; exit}' "$conf")"
        [[ "$domain" == *.test ]] || continue
        VH_TOTAL=$((VH_TOTAL+1))
        site="$(basename "$conf" .conf)"
        if [ -n "${SEEN_DOMAINS[$domain]:-}" ]; then
            bad=$((bad+1))
            detail "DUPLICATE ServerName: '$domain' xuất hiện ở $site.conf và ${SEEN_DOMAINS[$domain]}.conf"
            continue
        fi
        SEEN_DOMAINS["$domain"]="$site"
        if [ ! -L "$APACHE_ENABLED/$site.conf" ]; then
            bad=$((bad+1)); detail "Vhost $domain: chưa enable (thiếu symlink sites-enabled/$site.conf)"
        fi
        local docroot
        docroot="$(awk '/^[[:space:]]*DocumentRoot[[:space:]]+/ {print $2; exit}' "$conf")"
        if [ -z "$docroot" ] || [ ! -d "$docroot" ]; then
            bad=$((bad+1)); detail "Vhost $domain: DocumentRoot '$docroot' không hợp lệ/không tồn tại"
        fi
        local hcount
        hcount="$(grep -cxF "127.0.0.1 $domain" /etc/hosts 2>/dev/null)" || hcount=0
        if [ "$hcount" -ne 1 ]; then
            bad=$((bad+1)); detail "Vhost $domain: hosts entry xuất hiện $hcount lần (phải đúng 1)"
        fi
    done
    shopt -u nullglob
    if [ "$VH_TOTAL" -eq 0 ]; then
        emit SKIP "Virtual Host"
        detail "Không có vhost *.test nào được tạo (mục [15] là tùy chọn theo project)"
        return
    fi
    if [ "$bad" -eq 0 ]; then
        emit PASS "Virtual Host ($VH_TOTAL vhost nhất quán)"
    else
        emit FAIL "Virtual Host"
        detail "Có $bad vấn đề ở trên trong tổng số $VH_TOTAL vhost"
        detail "→ Tạo lại bằng mục [15]/[16] setup_dev.sh (có rollback sẵn)"
    fi
}

setup_hosts() {
    if is_skipped hosts; then emit SKIP "/etc/hosts (*.test)"; detail "--skip"; return; fi
    local malformed dup
    dup="$(sort /etc/hosts 2>/dev/null | uniq -d | grep -c '\.test' || true)"
    if [ "${malformed:-0}" -gt 0 ]; then
        emit FAIL "/etc/hosts (*.test)"
        detail "Có $malformed dòng chứa '.test' nhưng KHÔNG đúng định dạng setup ghi:"
        awk '!/^127\.0\.0\.1[[:space:]]+[A-Za-z0-9._-]+\.test([[:space:]]|$)/ && /\.test([[:space:]]|$)/' /etc/hosts \
            | head -n5 | sed 's/^/          /'
        detail "→ Sửa/xóa tay các dòng này (verify không tự sửa)"
    elif [ "${dup:-0}" -gt 0 ]; then
        emit FAIL "/etc/hosts (*.test)"
        detail "DUPLICATE: $dup dòng *.test bị lặp y hệt"
        detail "→ Xóa bớt dòng thừa (verify không tự sửa)"
    else
        emit PASS "/etc/hosts (*.test định dạng chuẩn, không trùng)"
    fi
}

setup_rootuser() {
    if is_skipped rootuser; then emit SKIP "Real user installation"; detail "--skip"; return; fi
    local stray=()
    [ -e /root/.nvm ] && stray+=("/root/.nvm")
    [ -e /root/development/flutter ] && stray+=("/root/development/flutter")
    if [ ${#stray[@]} -eq 0 ]; then
        emit PASS "Real user installation (không có rác trong /root)"
    else
        emit FAIL "Real user installation"
        local s
        for s in "${stray[@]}"; do detail "Found: $s (setup phải cài cho $REAL_USER, không phải root)"; done
        detail "→ Có thể đã chạy setup bằng root thay vì sudo — xóa tay các thư mục trên"
    fi
}

setup_www() {
    if is_skipped www; then emit SKIP "Protected: /var/www/html"; detail "--skip"; return; fi
    if [ -d "$WWW_ROOT" ]; then
        emit PASS "Protected: /var/www/html tồn tại"
    else
        emit FAIL "Protected: /var/www/html"
        detail "CRITICAL: web root biến mất — không phải tác vụ của setup/reset!"
        detail "→ Kiểm tra ai đã xóa; khôi phục từ backup"
    fi
}

run_setup_suite() {
    CURRENT_SUITE="SETUP"
    SUITE_LABEL="STATE: INSTALLED (sau setup_dev.sh)"
    echo ""
    echo -e "${BLUE}${BOLD}===============================================================${NC}"
    echo -e "${BLUE}${BOLD}  VERIFY SUITE: SETUP — trạng thái mong đợi là INSTALLED${NC}"
    echo -e "${BLUE}${BOLD}===============================================================${NC}"
    setup_git
    setup_apache_core
    setup_rewrite
    setup_configtest
    setup_multiproject_conf
    setup_php
    setup_php_ext
    setup_nvm
    setup_node
    setup_vscode
    setup_chrome
    setup_vim
    setup_meld
    setup_bamboo
    setup_flutter
    setup_android
    setup_vhosts
    setup_hosts
    setup_rootuser
    setup_www
}

# ------------------------------------------------------------
# Các check — MODE RESET (state CLEAN)
# ------------------------------------------------------------

reset_git() {
    if is_skipped git; then emit SKIP "Git removed"; detail "--skip"; return; fi
    if pkg_ok git; then
        emit FAIL "Git removed"
        detail "Expected: package git đã bị purge"
        detail "→ Chạy mục [1] reset_dev.sh; xem logs/reset_*.log"
    elif have_cmd git; then
        emit WARN "Git removed"
        detail "Package git đã gỡ nhưng binary vẫn còn (nguồn cài ngoài apt?)"
        detail "→ Xác định nguồn: command -v git"
    else
        emit PASS "Git removed"
    fi
}

reset_apache() {
    if is_skipped apache; then emit SKIP "Apache2 removed"; detail "--skip"; return; fi
    local prob=()
    pkg_ok apache2 && prob+=("package apache2 vẫn còn")
    [ -d /etc/apache2 ] && prob+=("thư mục /etc/apache2 vẫn còn (reset phải rm -rf)")
    systemctl is-active --quiet apache2 && prob+=("service apache2 vẫn đang chạy")
    if [ ${#prob[@]} -eq 0 ]; then
        emit PASS "Apache2 removed (pkg + /etc/apache2 + service)"
    else
        emit FAIL "Apache2 removed"
        local p
        for p in "${prob[@]}"; do detail "Found: $p"; done
        detail "→ Chạy mục [2] reset_dev.sh; xem logs/reset_*.log"
    fi
}

reset_php() {
    if is_skipped php; then emit SKIP "PHP removed"; detail "--skip"; return; fi
    local left
    left="$(dpkg-query -W -f='${Package}\n' 2>/dev/null | grep -E '^(php|libapache2-mod-php)' || true)"
    if [ -z "$left" ] && ! have_cmd php; then
        emit PASS "PHP removed (không còn gói php* nào)"
    else
        emit FAIL "PHP removed"
        detail "Expected: 0 package khớp ^(php|libapache2-mod-php)"
        detail "Found: $(echo "$left" | tr '\n' ' ')"
        detail "→ Chạy mục [3] reset_dev.sh (purge danh sách động); xem logs/reset_*.log"
    fi
}

reset_nvm() {
    if is_skipped nvm; then emit SKIP "NVM removed"; detail "--skip"; return; fi
    local prob=()
    [ -d "$REAL_HOME/.nvm" ] && prob+=("$REAL_HOME/.nvm vẫn còn")
    [ -d "$REAL_HOME/.npm" ] && prob+=("$REAL_HOME/.npm vẫn còn")
    local blk
    blk="$(rc_grep_count 'NVM_DIR|nvm\.sh')"
    [ "$blk" -gt 0 ] && prob+=("còn $blk dòng NVM trong rc-files")
    if [ ${#prob[@]} -eq 0 ]; then
        emit PASS "NVM removed (dir + rc-lines sạch)"
        detail "${DIM}Giới hạn: verify không chứng minh được các dòng KHÁC trong .bashrc nguyên vẹn byte — cần snapshot trước reset để so.${NC}"
    else
        emit FAIL "NVM removed"
        local p
        for p in "${prob[@]}"; do detail "Found: $p"; done
        detail "→ Chạy mục [4] reset_dev.sh; xem logs/reset_*.log"
    fi
}

reset_node() {
    if is_skipped node; then emit SKIP "Node.js (qua NVM) removed"; detail "--skip"; return; fi
    if [ -x /usr/bin/node ] || [ -x /usr/local/bin/node ]; then
        emit WARN "Node.js (qua NVM) removed"
        detail "Node ngoài NVM vẫn tồn tại (/usr/bin hoặc /usr/local/bin)"
        detail "→ Đây KHÔNG phải node do setup cài — xác định nguồn rồi quyết định giữ/gỡ"
    else
        emit PASS "Node.js (qua NVM) removed"
    fi
}

reset_vscode() {
    if is_skipped vscode; then emit SKIP "VS Code removed"; detail "--skip"; return; fi
    local prob=()
    pkg_ok code && prob+=("package code vẫn còn")
    [ -d "$REAL_HOME/.vscode" ] && prob+=("$REAL_HOME/.vscode vẫn còn")
    [ -d "$REAL_HOME/.config/Code" ] && prob+=("$REAL_HOME/.config/Code vẫn còn")
    if [ ${#prob[@]} -eq 0 ]; then
        emit PASS "VS Code removed (pkg + profile)"
    else
        emit FAIL "VS Code removed"
        local p
        for p in "${prob[@]}"; do detail "Found: $p"; done
        detail "→ Chạy mục [5] reset_dev.sh"
    fi
}

reset_chrome() {
    if is_skipped chrome; then emit SKIP "Chrome removed"; detail "--skip"; return; fi
    local prob=()
    pkg_ok google-chrome-stable && prob+=("package google-chrome-stable vẫn còn")
    [ -d "$REAL_HOME/.config/google-chrome" ] && prob+=("$REAL_HOME/.config/google-chrome vẫn còn")
    if [ ${#prob[@]} -eq 0 ]; then
        emit PASS "Chrome removed (pkg + profile)"
    else
        emit FAIL "Chrome removed"
        local p
        for p in "${prob[@]}"; do detail "Found: $p"; done
        detail "→ Chạy mục [6] reset_dev.sh"
    fi
}

reset_vim() {
    if is_skipped vim; then emit SKIP "Vim removed (giữ vim-tiny)"; detail "--skip"; return; fi
    local full=()
    pkg_ok vim && full+=("vim")
    pkg_ok vim-runtime && full+=("vim-runtime")
    pkg_ok vim-gtk3 && full+=("vim-gtk3")
    if [ ${#full[@]} -gt 0 ]; then
        emit FAIL "Vim removed (giữ vim-tiny)"
        detail "Expected: chỉ vim-tiny/vim-common (mặc định OS) — các bản đầy đủ phải purge"
        detail "Found vẫn còn: ${full[*]}"
        detail "→ Chạy mục [7] reset_dev.sh"
        return
    fi
    if have_cmd vim; then
        local owner_pkg
        owner_pkg="$(dpkg -S "$(command -v vim)" 2>/dev/null | cut -d: -f1)"
        if [ "$owner_pkg" = "vim-tiny" ]; then
            emit PASS "Vim removed (chỉ còn vim-tiny — được bảo vệ, đúng như OS mới)"
        else
            emit WARN "Vim removed"
            detail "Binary vim còn nhưng thuộc package lạ: ${owner_pkg:-unknown}"
            detail "→ Xác định nguồn: dpkg -S $(command -v vim)"
        fi
    else
        emit PASS "Vim removed (chỉ còn vim-tiny — được bảo vệ, đúng như OS mới)"
    fi
}

reset_meld() {
    if is_skipped meld; then emit SKIP "Meld removed"; detail "--skip"; return; fi
    if pkg_ok meld; then
        emit FAIL "Meld removed"
        detail "→ Chạy mục [8] reset_dev.sh"
    else
        emit PASS "Meld removed"
    fi
}

reset_bamboo() {
    if is_skipped bamboo; then emit SKIP "IBus Bamboo removed"; detail "--skip"; return; fi
    local prob=()
    pkg_ok ibus-bamboo && prob+=("package ibus-bamboo vẫn còn")
    local leftover=0 aptf
    for aptf in /etc/apt/sources.list.d/*bamboo* \
                /etc/apt/trusted.gpg.d/*bamboo* \
                /etc/apt/preferences.d/*bamboo*; do
        [ -e "$aptf" ] && leftover=$((leftover+1))
    done
    [ "$leftover" -gt 0 ] && prob+=("còn $leftover file PPA *bamboo* trong /etc/apt")
    if [ ${#prob[@]} -eq 0 ]; then
        emit PASS "IBus Bamboo removed (pkg + PPA sạch)"
    else
        emit FAIL "IBus Bamboo removed"
        local p
        for p in "${prob[@]}"; do detail "Found: $p"; done
        detail "→ Chạy mục [9] reset_dev.sh"
    fi
}

reset_flutter() {
    if is_skipped flutter; then emit SKIP "Flutter removed"; detail "--skip"; return; fi
    local prob=()
    [ -d "$REAL_HOME/development/flutter" ] && prob+=("$REAL_HOME/development/flutter vẫn còn")
    local pline
    pline="$(rc_grep_count 'development/flutter/bin')"
    [ "$pline" -gt 0 ] && prob+=("còn $pline dòng PATH Flutter trong rc-files")
    [ -d "$REAL_HOME/.pub-cache" ] && prob+=("$REAL_HOME/.pub-cache vẫn còn")
    if [ ${#prob[@]} -eq 0 ]; then
        emit PASS "Flutter removed (SDK + PATH + cache)"
    else
        emit FAIL "Flutter removed"
        local p
        for p in "${prob[@]}"; do detail "Found: $p"; done
        detail "→ Chạy mục [10] reset_dev.sh"
    fi
}

reset_android() {
    if is_skipped android; then emit SKIP "Android Studio removed"; detail "--skip"; return; fi
    if have_cmd snap && snap list android-studio >/dev/null 2>&1; then
        emit FAIL "Android Studio removed"
        detail "snap android-studio vẫn còn"
        detail "→ Chạy mục [11] reset_dev.sh"
        return
    fi
    local leftovers=() d
    for d in "snap/android-studio" "Android" ".android" ".gradle"; do
        [ -e "$REAL_HOME/$d" ] && leftovers+=("$REAL_HOME/$d")
    done
    if [ ${#leftovers[@]} -eq 0 ]; then
        emit PASS "Android Studio removed (snap + data dirs)"
    else
        emit WARN "Android Studio removed"
        detail "Snap đã gỡ nhưng còn: ${leftovers[*]}"
        detail "→ Có thể do app/tool khác tạo lại (gradle CLI...). Nếu chắc chắn là rác: xóa tay"
    fi
}

reset_vhosts() {
    if is_skipped vhost; then emit SKIP "Virtual Host removed"; detail "--skip"; return; fi
    if [ ! -d "$APACHE_SITES" ]; then
        emit PASS "Virtual Host removed"
        detail "${DIM}/etc/apache2 không còn (đã bị purge cùng Apache) — hiển nhiên sạch${NC}"
        return
    fi
    local conf domain left=()
    shopt -s nullglob
    for conf in "$APACHE_SITES"/*.conf; do
        domain="$(awk '/^[[:space:]]*ServerName[[:space:]]+/ {print $2; exit}' "$conf")"
        [[ "$domain" == *.test ]] && left+=("$domain ($(basename "$conf"))")
    done
    shopt -u nullglob
    if [ ${#left[@]} -eq 0 ]; then
        emit PASS "Virtual Host removed (0 vhost *.test)"
    else
        emit FAIL "Virtual Host removed"
        detail "Còn: ${left[*]}"
        detail "→ Chạy mục [12] reset_dev.sh"
    fi
}

reset_hosts() {
    if is_skipped hosts; then emit SKIP "/etc/hosts (*.test) removed"; detail "--skip"; return; fi
    local n
    n="$(grep -cE '^127\.0\.0\.1[[:space:]]+[A-Za-z0-9._-]+\.test([[:space:]]|$)' /etc/hosts 2>/dev/null)" || n=0
    if [ "${n:-0}" -eq 0 ]; then
        emit PASS "/etc/hosts (*.test) removed"
    else
        emit FAIL "/etc/hosts (*.test) removed"
        detail "Còn $n dòng:"
        grep -E '^127\.0\.0\.1[[:space:]]+[A-Za-z0-9._-]+\.test([[:space:]]|$)' /etc/hosts \
            | sed 's/^/          /'
        detail "→ Chạy mục [12] reset_dev.sh"
    fi
}

reset_rootuser() {
    if is_skipped rootuser; then emit SKIP "Real user residue"; detail "--skip"; return; fi
    local stray=()
    [ -e /root/.nvm ] && stray+=("/root/.nvm")
    [ -e /root/development/flutter ] && stray+=("/root/development/flutter")
    if [ ${#stray[@]} -eq 0 ]; then
        emit PASS "Real user installation residue (không có gì trong /root)"
    else
        emit FAIL "Real user installation residue"
        detail "Found: ${stray[*]}"
        detail "→ Reset không đụng /root — xóa tay"
    fi
}

reset_protected() {
    echo -e "  ${BOLD}--- Protected data (reset PHẢI giữ nguyên) ---${NC}"

    if is_skipped www; then
        emit SKIP "Protected: /var/www/html"
        detail "--skip"
    elif [ -d "$WWW_ROOT" ]; then
        emit PASS "Protected: /var/www/html còn nguyên ($(/usr/bin/ls -A "$WWW_ROOT" | wc -l) mục)"
    else
        emit FAIL "Protected: /var/www/html"
        detail "CRITICAL: project data BIẾN MẤT sau reset!"
        detail "→ Khôi phục ngay từ backup; điều tra logs/reset_*.log"
    fi

    if is_skipped documents; then
        emit SKIP "Protected: ~/Documents"
        detail "--skip"
    elif [ -d "$REAL_HOME/Documents" ]; then
        emit PASS "Protected: ~/Documents tồn tại"
    else
        emit FAIL "Protected: ~/Documents"
        detail "Thư mục chuẩn Ubuntu Desktop biến mất — nghi ngờ mất data"
        detail "→ Nếu máy vốn không có Documents từ trước: dùng --skip documents"
    fi

    local vt vc
    vt="$(pkg_ok vim-tiny && echo có || echo không)"
    vc="$(pkg_ok vim-common && echo có || echo không)"
    emit PASS "Protected: vim-tiny($vt) / vim-common($vc) — sự tồn tại là BÌNH THƯỜNG, không tính lỗi"

    if pkg_ok ibus; then
        emit PASS "Protected: ibus hệ thống còn nguyên"
    else
        emit FAIL "Protected: ibus hệ thống"
        detail "Package ibus core bị gỡ — reset CHỈ được gỡ ibus-bamboo!"
        detail "→ Cài lại: sudo apt-get install ibus; điều tra logs/reset_*.log"
    fi
}

run_reset_suite() {
    CURRENT_SUITE="RESET"
    SUITE_LABEL="STATE: CLEAN (sau reset_dev.sh)"
    echo ""
    echo -e "${BLUE}${BOLD}===============================================================${NC}"
    echo -e "${BLUE}${BOLD}  VERIFY SUITE: RESET — trạng thái mong đợi là CLEAN${NC}"
    echo -e "${BLUE}${BOLD}===============================================================${NC}"
    reset_git
    reset_apache
    reset_php
    reset_nvm
    reset_node
    reset_vscode
    reset_chrome
    reset_vim
    reset_meld
    reset_bamboo
    reset_flutter
    reset_android
    reset_vhosts
    reset_hosts
    reset_rootuser
    reset_protected
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --setup) MODE="${MODE:+both}setup" ;;
        --reset) MODE="${MODE:+both}reset" ;;
        --all)   MODE="both" ;;
        --skip)  SKIP_LIST="$2"; shift ;;
        *) echo -e "${RED}Tham số không hợp lệ: $1${NC}"; usage; exit 2 ;;
    esac
    shift
done

if [ -z "$MODE" ]; then
    usage
    exit 2
fi

echo -e "${BOLD}VERIFY DEV ENVIRONMENT — user: $REAL_USER | mode: $MODE${NC}"

if [ "$MODE" = "setup" ] || [ "$MODE" = "both" ]; then
    run_setup_suite
    finish_suite
fi
if [ "$MODE" = "reset" ] || [ "$MODE" = "both" ]; then
    PC=0; FC=0; WC=0; SC=0; FAILED_TITLES=()
    run_reset_suite
    finish_suite
fi

if [ "$TOTAL_FAILS" -gt 0 ]; then
    exit 1
fi
exit 0
