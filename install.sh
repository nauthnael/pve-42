#!/bin/bash

# ============================================================
#  install.sh - Cài đặt / Cập nhật lệnh 42
#  Dùng: bash <(curl -fsSL https://raw.githubusercontent.com/nauthnael/pve-42/main/install.sh)
# ============================================================

REPO="nauthnael/pve-42"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"
INSTALL_PATH="/usr/local/bin/42"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║${NC}  ${WHITE}${BOLD}✦  PVE Quick Menu - Installer  ✦${NC}    ${BOLD}${CYAN}║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════╝${NC}"
echo ""

# Kiểm tra root
if [[ $EUID -ne 0 ]]; then
    echo -e "  ${RED}✗ Cần chạy với quyền root${NC}"
    echo -e "  ${DIM}Dùng: sudo bash <(curl ...)${NC}"
    exit 1
fi

# Kiểm tra curl
if ! command -v curl &>/dev/null; then
    echo -e "  ${YELLOW}⚠ curl chưa cài, đang cài...${NC}"
    apt-get install -y curl -qq
fi

# Kiểm tra đã cài chưa
if [[ -f "$INSTALL_PATH" ]]; then
    MODE="update"
    echo -e "  ${DIM}Phát hiện bản cũ — sẽ cập nhật${NC}"
else
    MODE="install"
    echo -e "  ${DIM}Cài đặt lần đầu${NC}"
fi

echo ""
echo -e "  ${DIM}Đang tải 42.sh từ GitHub...${NC}"

# Tải về tmp trước, kiểm tra rồi mới replace
TMP=$(mktemp /tmp/42_XXXXXX.sh)

if ! curl -fsSL "${RAW_BASE}/42.sh" -o "$TMP"; then
    echo -e "  ${RED}✗ Tải thất bại — kiểm tra kết nối mạng${NC}"
    rm -f "$TMP"
    exit 1
fi

# Kiểm tra file hợp lệ (phải có shebang và >100 dòng)
LINES=$(wc -l < "$TMP")
if [[ $LINES -lt 100 ]] || ! head -1 "$TMP" | grep -q "#!/bin/bash"; then
    echo -e "  ${RED}✗ File tải về không hợp lệ (${LINES} dòng)${NC}"
    rm -f "$TMP"
    exit 1
fi

# Backup bản cũ nếu đang update
if [[ "$MODE" == "update" && -f "$INSTALL_PATH" ]]; then
    BACKUP="${INSTALL_PATH}.bak"
    cp "$INSTALL_PATH" "$BACKUP"
    echo -e "  ${DIM}Backup bản cũ → ${BACKUP}${NC}"
fi

# Cài đặt
cp "$TMP" "$INSTALL_PATH"
chmod +x "$INSTALL_PATH"
rm -f "$TMP"

echo ""
if [[ "$MODE" == "install" ]]; then
    echo -e "  ${GREEN}✓ Đã cài đặt:${NC} ${WHITE}${INSTALL_PATH}${NC}"
else
    echo -e "  ${GREEN}✓ Đã cập nhật:${NC} ${WHITE}${INSTALL_PATH}${NC} ${DIM}(${LINES} dòng)${NC}"
fi

echo ""
echo -e "  ${BOLD}Gõ ${CYAN}42${NC}${BOLD} rồi Enter để dùng!${NC}"
echo ""
