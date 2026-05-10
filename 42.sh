#!/bin/bash

# ============================================================
#  42 - Quick Command Menu for Proxmox
#  Setup: chmod +x 42.sh && sudo cp 42.sh /usr/local/bin/42
# ============================================================

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
WHITE='\033[1;37m'
DIM='\033[2m'
BOLD='\033[1m'
NC='\033[0m'

APP_VERSION="1.0"

# ─────────────────────────────────────────────
#  MENU ITEMS
# ─────────────────────────────────────────────
MENU_NAMES=()
MENU_DESCS=()
MENU_FUNCS=()

MENU_NAMES+=("Aro Report");         MENU_DESCS+=("Chạy aro-manager.sh report trên các CT đang running");          MENU_FUNCS+=("cmd_aro_report")
MENU_NAMES+=("Aro Update");         MENU_DESCS+=("Tải & chạy aro-manager.sh update (có retry wget)");             MENU_FUNCS+=("cmd_aro_update")
MENU_NAMES+=("Aro Restart");        MENU_DESCS+=("Chạy aro-manager.sh restart trên các CT đang running");         MENU_FUNCS+=("cmd_aro_restart")
MENU_NAMES+=("CT Start");           MENU_DESCS+=("Khởi động các CT (pct start)");                                 MENU_FUNCS+=("cmd_ct_start")
MENU_NAMES+=("CT Stop");            MENU_DESCS+=("Tắt các CT (pct stop)");                                        MENU_FUNCS+=("cmd_ct_stop")
MENU_NAMES+=("Aro Update Watchdog");MENU_DESCS+=("Tải & chạy aro-manager.sh update --watchdog-only (có retry)");  MENU_FUNCS+=("cmd_aro_update_watchdog")
MENU_NAMES+=("Open VNC");           MENU_DESCS+=("Thêm iptables forward VNC cho CT (tự xóa sau 2h)");             MENU_FUNCS+=("cmd_open_vnc")
MENU_NAMES+=("Check Network CT");   MENU_DESCS+=("Kiểm tra CT mất IP, tùy chọn renew DHCP tự động");             MENU_FUNCS+=("cmd_check_network")
MENU_NAMES+=("Check ARO Score");    MENU_DESCS+=("Kiểm tra điểm ARO node, tùy chọn xuất CSV");                   MENU_FUNCS+=("cmd_check_score")

# ── Thêm lệnh mới bên dưới ──
# MENU_NAMES+=("Tên lệnh"); MENU_DESCS+=("Mô tả"); MENU_FUNCS+=("cmd_ten_lenh")

# ─────────────────────────────────────────────
#  PARSE CT ID
#  Input : "220-222 225 230-232,240"
#  Output: danh sách ID không trùng, tăng dần
# ─────────────────────────────────────────────
parse_ct_input() {
    local raw="$1" result=""
    raw="${raw// /,}"
    raw=$(echo "$raw" | tr -s ',')
    IFS=',' read -ra parts <<< "$raw"
    for part in "${parts[@]}"; do
        [[ -z "$part" ]] && continue
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            local s="${BASH_REMATCH[1]}" e="${BASH_REMATCH[2]}"
            if (( s > e )); then
                echo -e "\n  ${RED}✗ Range không hợp lệ: ${BOLD}${part}${NC}${RED} (start > end)${NC}" >&2
                return 1
            fi
            result+=" $(seq "$s" "$e")"
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            result+=" $part"
        else
            echo -e "\n  ${RED}✗ Không nhận dạng được: ${BOLD}'${part}'${NC}" >&2
            echo -e "  ${DIM}Dùng: ${WHITE}222${DIM}  hoặc  ${WHITE}220-239${DIM}  hoặc  ${WHITE}220-222,225,230-232${NC}" >&2
            return 1
        fi
    done
    [[ -z "$result" ]] && { echo -e "\n  ${RED}✗ Không có CT nào được nhập.${NC}" >&2; return 1; }
    echo "$result" | tr ' ' '\n' | sort -un | tr '\n' ' '
}

# ─────────────────────────────────────────────
#  HỎI SỐ LUỒNG
#  Trả về số luồng qua stdout
# ─────────────────────────────────────────────
ask_threads() {
    local default=4
    echo -ne "  ${YELLOW}Số luồng song song (Enter = ${default}): ${NC}" >&2
    read -r t
    t="${t// /}"
    if [[ -z "$t" ]]; then
        echo "$default"
    elif [[ "$t" =~ ^[0-9]+$ ]] && (( t >= 1 )); then
        echo "$t"
    else
        echo -e "  ${DIM}Không hợp lệ, dùng mặc định ${default}${NC}" >&2
        echo "$default"
    fi
}

# ─────────────────────────────────────────────
#  PARALLEL ENGINE
#  Chạy hàm worker song song, buffer output,
#  in theo thứ tự CT ID khi xong.
#
#  Cách dùng:
#    run_parallel <threads> <ct_list> <worker_func> [extra_args...]
#
#  Worker func nhận: <ctid> <tmpdir> [extra_args...]
#  Worker ghi output vào: $tmpdir/$ctid.out
#  Worker ghi status vào: $tmpdir/$ctid.status  (ok|skip|fail)
# ─────────────────────────────────────────────
run_parallel() {
    local threads="$1"; shift
    local ct_list="$1"; shift
    local worker="$1"; shift
    local extra_args=("$@")

    local tmpdir
    tmpdir=$(mktemp -d /tmp/42_parallel_XXXXXX)

    # Semaphore: dùng named pipe để giới hạn luồng
    local semaphore="$tmpdir/.sem"
    mkfifo "$semaphore"
    # Nạp đúng 'threads' token vào pipe
    ( for _ in $(seq 1 "$threads"); do echo; done > "$semaphore" ) &
    local sem_pid=$!
    exec 9<>"$semaphore"

    local pids=()
    local ct_arr=($ct_list)

    for ctid in "${ct_arr[@]}"; do
        # Chờ token (giới hạn luồng)
        read -u 9

        (
            # Chạy worker, output vào tmpfile
            "$worker" "$ctid" "$tmpdir" "${extra_args[@]}" \
                > "$tmpdir/${ctid}.out" 2>&1
            # Trả token
            echo >&9
        ) &
        pids+=($!)
    done

    # Chờ tất cả xong
    for pid in "${pids[@]}"; do
        wait "$pid"
    done

    # Đóng semaphore
    exec 9>&-
    kill "$sem_pid" 2>/dev/null
    wait "$sem_pid" 2>/dev/null

    # In output theo thứ tự CT ID
    local ok=0 skipped=0 failed=0
    for ctid in "${ct_arr[@]}"; do
        local out="$tmpdir/${ctid}.out"
        local stat_file="$tmpdir/${ctid}.status"
        local status="unknown"
        [[ -f "$stat_file" ]] && status=$(cat "$stat_file")

        if [[ -s "$out" ]]; then
            cat "$out"
        fi

        case "$status" in
            ok)   (( ok++ ))      ;;
            skip) (( skipped++ )) ;;
            fail) (( failed++ ))  ;;
        esac
    done

    rm -rf "$tmpdir"

    # Trả tổng kết ra stdout để caller dùng
    echo "__STATS__ ok=$ok skipped=$skipped failed=$failed"
}

# ─────────────────────────────────────────────
#  WORKER FUNCTIONS
#  Mỗi worker xử lý 1 CT, ghi output vào tmpdir
# ─────────────────────────────────────────────

_worker_aro_run() {
    local ctid="$1" tmpdir="$2" action="$3" color="$4"
    local out="$tmpdir/${ctid}.out"

    if ! pct status "$ctid" 2>/dev/null | grep -q "running"; then
        echo -e "  ${DIM}[CT ${ctid}] không running, bỏ qua${NC}"
        echo "skip" > "$tmpdir/${ctid}.status"
        return
    fi

    echo -e "  ${!color}=== CT ${ctid} ===${NC}"
    pct exec "$ctid" -- bash /root/aro-manager.sh "$action" 2>&1 \
        | sed "s/^/  [CT ${ctid}] /"
    echo ""
    echo "ok" > "$tmpdir/${ctid}.status"
}

_worker_aro_update() {
    local ctid="$1" tmpdir="$2"
    local MAX_RETRY=3 MIN_SIZE=1024

    if ! pct status "$ctid" 2>/dev/null | grep -q "running"; then
        echo -e "  ${DIM}[CT ${ctid}] không running, bỏ qua${NC}"
        echo "skip" > "$tmpdir/${ctid}.status"
        return
    fi

    echo -e "  ${YELLOW}=== CT ${ctid} ===${NC}"

    local attempt=0 download_ok=false
    while (( attempt < MAX_RETRY )); do
        (( attempt++ ))
        echo -e "  ${DIM}[CT ${ctid}] [${attempt}/${MAX_RETRY}] Đang tải aro-manager.sh...${NC}"
        pct exec "$ctid" -- bash -c \
            "wget -4 --no-cache -q -O /root/aro-manager.sh \
            https://raw.githubusercontent.com/nauthnael/aro-manager/main/aro-manager.sh" 2>/dev/null
        local size
        size=$(pct exec "$ctid" -- bash -c "stat -c%s /root/aro-manager.sh 2>/dev/null || echo 0")
        if (( size >= MIN_SIZE )); then
            echo -e "  ${GREEN}[CT ${ctid}] ✓ Tải OK (${size} bytes)${NC}"
            download_ok=true; break
        else
            echo -e "  ${RED}[CT ${ctid}] ✗ File ${size} bytes — thử lại...${NC}"
            sleep 2
        fi
    done

    if [[ "$download_ok" == false ]]; then
        echo -e "  ${RED}[CT ${ctid}] ✗ Tải thất bại sau ${MAX_RETRY} lần${NC}"
        echo ""
        echo "fail" > "$tmpdir/${ctid}.status"
        return
    fi

    echo -e "  ${DIM}[CT ${ctid}] Đang chạy update...${NC}"
    pct exec "$ctid" -- bash -c \
        "chmod +x /root/aro-manager.sh && sudo bash /root/aro-manager.sh update" 2>&1 \
        | sed "s/^/  [CT ${ctid}] /"
    echo ""
    echo "ok" > "$tmpdir/${ctid}.status"
}

_worker_aro_watchdog() {
    local ctid="$1" tmpdir="$2"
    local MAX_RETRY=3 MIN_SIZE=1024

    if ! pct status "$ctid" 2>/dev/null | grep -q "running"; then
        echo -e "  ${DIM}[CT ${ctid}] không running, bỏ qua${NC}"
        echo "skip" > "$tmpdir/${ctid}.status"
        return
    fi

    echo -e "  ${CYAN}=== CT ${ctid} ===${NC}"

    local attempt=0 download_ok=false
    while (( attempt < MAX_RETRY )); do
        (( attempt++ ))
        echo -e "  ${DIM}[CT ${ctid}] [${attempt}/${MAX_RETRY}] Đang tải aro-manager.sh...${NC}"
        pct exec "$ctid" -- bash -c \
            "wget -4 --no-cache -q -O /root/aro-manager.sh \
            https://raw.githubusercontent.com/nauthnael/aro-manager/main/aro-manager.sh" 2>/dev/null
        local size
        size=$(pct exec "$ctid" -- bash -c "stat -c%s /root/aro-manager.sh 2>/dev/null || echo 0")
        if (( size >= MIN_SIZE )); then
            echo -e "  ${GREEN}[CT ${ctid}] ✓ Tải OK (${size} bytes)${NC}"
            download_ok=true; break
        else
            echo -e "  ${RED}[CT ${ctid}] ✗ File ${size} bytes — thử lại...${NC}"
            sleep 2
        fi
    done

    if [[ "$download_ok" == false ]]; then
        echo -e "  ${RED}[CT ${ctid}] ✗ Tải thất bại sau ${MAX_RETRY} lần${NC}"
        echo ""
        echo "fail" > "$tmpdir/${ctid}.status"
        return
    fi

    echo -e "  ${DIM}[CT ${ctid}] Đang chạy update --watchdog-only...${NC}"
    pct exec "$ctid" -- bash -c \
        "chmod +x /root/aro-manager.sh && sudo bash /root/aro-manager.sh update --watchdog-only" 2>&1 \
        | sed "s/^/  [CT ${ctid}] /"
    echo ""
    echo "ok" > "$tmpdir/${ctid}.status"
}

_worker_ct_power() {
    local ctid="$1" tmpdir="$2" action="$3" color="$4"

    local status
    status=$(pct status "$ctid" 2>/dev/null)
    if [[ -z "$status" ]]; then
        echo -e "  ${DIM}[CT ${ctid}] không tồn tại, bỏ qua${NC}"
        echo "skip" > "$tmpdir/${ctid}.status"; return
    fi
    if [[ "$action" == "start" ]] && echo "$status" | grep -q "running"; then
        echo -e "  ${DIM}[CT ${ctid}] đang running rồi, bỏ qua${NC}"
        echo "skip" > "$tmpdir/${ctid}.status"; return
    fi
    if [[ "$action" == "stop" ]] && echo "$status" | grep -q "stopped"; then
        echo -e "  ${DIM}[CT ${ctid}] đã stopped rồi, bỏ qua${NC}"
        echo "skip" > "$tmpdir/${ctid}.status"; return
    fi

    echo -ne "  ${!color}[${action}]${NC} CT ${ctid} ... "
    if pct "$action" "$ctid" 2>&1; then
        echo -e "  ${GREEN}✓${NC}"
        echo "ok" > "$tmpdir/${ctid}.status"
    else
        echo -e "  ${RED}✗${NC}"
        echo "fail" > "$tmpdir/${ctid}.status"
    fi
}

# ─────────────────────────────────────────────
#  HELPER: nhập CT + threads rồi gọi run_parallel
# ─────────────────────────────────────────────
_prompt_and_run() {
    local title="$1" color="$2" worker="$3"; shift 3
    local extra_args=("$@")

    echo ""
    echo -e "${!color}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${WHITE}  ${title}${NC}"
    echo -e "${!color}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${DIM}Kết hợp dãy và số lẻ (vd: ${WHITE}220-222,225,230-232${DIM}):${NC}"
    echo -ne "  ${YELLOW}CT range/ID: ${NC}"
    read -r input

    if [[ -z "$input" ]]; then
        echo -e "\n  ${DIM}Đã hủy.${NC}\n"; return
    fi

    local ct_list
    ct_list=$(parse_ct_input "$input") || { echo ""; return 1; }
    local ct_arr=($ct_list)

    echo ""
    echo -e "  ${DIM}Sẽ xử lý ${WHITE}${#ct_arr[@]} CT${DIM}:${NC} ${ct_list}"
    local threads
    threads=$(ask_threads)
    echo ""
    echo -e "  ${GREEN}▶ Bắt đầu với ${threads} luồng...${NC}"
    echo -e "${DIM}  ─────────────────────────────────────${NC}"
    echo ""

    local stats
    stats=$(run_parallel "$threads" "$ct_list" "$worker" "${extra_args[@]}")
    local ok skipped failed
    ok=$(echo    "$stats" | grep -oP 'ok=\K[0-9]+')
    skipped=$(echo "$stats" | grep -oP 'skipped=\K[0-9]+')
    failed=$(echo  "$stats" | grep -oP 'failed=\K[0-9]+')

    echo -e "${DIM}  ─────────────────────────────────────${NC}"
    local summary="  ${GREEN}✓ Hoàn thành:${NC} ${WHITE}${ok} CT OK${NC}"
    [[ "$failed"  -gt 0 ]] && summary+=", ${RED}${failed} thất bại${NC}"
    [[ "$skipped" -gt 0 ]] && summary+=", ${DIM}${skipped} bỏ qua${NC}"
    echo -e "$summary"
    echo ""
}

# ─────────────────────────────────────────────
#  MENU COMMANDS
# ─────────────────────────────────────────────

cmd_aro_report()  { _prompt_and_run "Aro Report"  "CYAN"    "_worker_aro_run"  "report"  "CYAN";   }
cmd_aro_restart() { _prompt_and_run "Aro Restart" "RED"     "_worker_aro_run"  "restart" "RED";    }
cmd_aro_update()  { _prompt_and_run "Aro Update"  "YELLOW"  "_worker_aro_update";                  }
cmd_aro_update_watchdog() { _prompt_and_run "Aro Update Watchdog" "CYAN" "_worker_aro_watchdog";   }
cmd_ct_start()    { _prompt_and_run "CT Start"    "GREEN"   "_worker_ct_power" "start"  "GREEN";   }
cmd_ct_stop()     { _prompt_and_run "CT Stop"     "RED"     "_worker_ct_power" "stop"   "RED";     }

# ── Open VNC (không dùng parallel vì mỗi CT cần logic riêng với iptables) ──
cmd_open_vnc() {
    local AUTO_DELETE_SECS=7200

    echo ""
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${WHITE}  Open VNC - Thêm iptables forward${NC}"
    echo -e "${MAGENTA}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${DIM}Nhập CT ID (vd: ${WHITE}539${DIM}) — có thể nhập nhiều:${NC}"
    echo -ne "  ${YELLOW}CT ID: ${NC}"
    read -r input

    input="${input// /,}"
    input=$(echo "$input" | tr -s ',')
    if [[ -z "$input" ]]; then
        echo -e "\n  ${DIM}Đã hủy.${NC}\n"; return
    fi

    local wan_if
    wan_if=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')
    if [[ -z "$wan_if" ]]; then
        echo -e "\n  ${RED}✗ Không detect được WAN interface${NC}\n"; return 1
    fi

    local expire_time
    expire_time=$(date -d "+${AUTO_DELETE_SECS} seconds" +"%H:%M" 2>/dev/null \
        || date -v +${AUTO_DELETE_SECS}S +"%H:%M" 2>/dev/null)

    # Lấy IP của host trên WAN interface
    local host_ip
    host_ip=$(ip -4 -o addr show "$wan_if" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1)
    [[ -z "$host_ip" ]] && host_ip=$(ip route get 1.1.1.1 2>/dev/null | awk '/src/{print $7; exit}')

    echo ""
    echo -e "  ${DIM}WAN interface: ${WHITE}${wan_if}${NC}  ${DIM}Host IP: ${WHITE}${host_ip}${NC}"
    echo -e "  ${DIM}Rule tự xóa sau: ${WHITE}2 giờ${DIM} (lúc ${WHITE}${expire_time}${DIM})${NC}"
    echo ""

    local ok=0 failed=0
    IFS=',' read -ra ids <<< "$input"

    for ctid in "${ids[@]}"; do
        ctid="${ctid// /}"
        if ! [[ "$ctid" =~ ^[0-9]+$ ]]; then
            echo -e "  ${RED}✗ '${ctid}' không phải số, bỏ qua${NC}"
            (( failed++ )); continue
        fi

        if ! pct status "$ctid" 2>/dev/null | grep -q "running"; then
            echo -e "  ${RED}✗ CT $ctid: không running — cần running để lấy IP${NC}"
            (( failed++ )); continue
        fi

        local ct_ip
        ct_ip=$(pct exec "$ctid" -- ip -4 -o addr show eth0 2>/dev/null \
            | awk '{print $4}' | cut -d/ -f1 | head -1)
        if [[ -z "$ct_ip" ]]; then
            echo -e "  ${RED}✗ CT $ctid: không lấy được IP${NC}"
            (( failed++ )); continue
        fi

        local suffix
        suffix=$(printf "%02d" $(( ctid % 100 )))
        local vnc_port="420${suffix}"

        local add_nat="iptables -t nat -A PREROUTING -i ${wan_if} -p tcp --dport ${vnc_port} -j DNAT --to-destination ${ct_ip}:5901"
        local del_nat="iptables -t nat -D PREROUTING -i ${wan_if} -p tcp --dport ${vnc_port} -j DNAT --to-destination ${ct_ip}:5901"
        local add_fwd="iptables -A FORWARD -p tcp -d ${ct_ip} --dport 5901 -j ACCEPT"
        local del_fwd="iptables -D FORWARD -p tcp -d ${ct_ip} --dport 5901 -j ACCEPT"

        echo -e "  ${MAGENTA}=== CT ${ctid} ===${NC}"
        echo -e "  ${DIM}IP: ${WHITE}${ct_ip}${NC}  ${DIM}Port: ${WHITE}${vnc_port}${NC}  ${DIM}→ ${WHITE}5901${NC}"
        echo ""

        if iptables -t nat -C PREROUTING -i "${wan_if}" -p tcp --dport "${vnc_port}" \
                -j DNAT --to-destination "${ct_ip}:5901" 2>/dev/null; then
            echo -e "  ${DIM}  Rule NAT đã tồn tại, bỏ qua${NC}"
        else
            eval "$add_nat" && echo -e "  ${GREEN}  ✓ NAT${NC} ${DIM}...dport ${vnc_port} → ${ct_ip}:5901${NC}" \
                || { echo -e "  ${RED}  ✗ NAT thất bại${NC}"; (( failed++ )); continue; }
        fi

        if iptables -C FORWARD -p tcp -d "${ct_ip}" --dport 5901 -j ACCEPT 2>/dev/null; then
            echo -e "  ${DIM}  Rule FORWARD đã tồn tại, bỏ qua${NC}"
        else
            eval "$add_fwd" && echo -e "  ${GREEN}  ✓ FWD${NC} ${DIM}...d ${ct_ip} --dport 5901 ACCEPT${NC}" \
                || { echo -e "  ${RED}  ✗ FORWARD thất bại${NC}"; (( failed++ )); continue; }
        fi

        ( sleep "${AUTO_DELETE_SECS}" \
            && eval "${del_nat}" 2>/dev/null \
            && eval "${del_fwd}" 2>/dev/null ) &
        disown

        echo -e "  ${YELLOW}  ⏱ Tự xóa rule lúc ${expire_time}${NC}"
        echo -e "  ${BOLD}${CYAN}  ➜ Kết nối: ${host_ip}:${vnc_port}${NC}"
        echo ""
        (( ok++ ))
    done

    echo -e "${DIM}  ─────────────────────────────────────${NC}"
    local summary="  ${GREEN}✓ Hoàn thành:${NC} ${WHITE}${ok} CT đã thêm rule${NC}"
    [[ $failed -gt 0 ]] && summary+=", ${RED}${failed} thất bại${NC}"
    echo -e "$summary"
    echo ""
}

# ── Check Network CT ──
_get_ct_ipv4() {
    local ctid="$1"
    pct exec "$ctid" -- bash -c \
        "ip -4 -o addr show dev eth0 2>/dev/null | awk '{print \$4}' | cut -d/ -f1 | head -1" 2>/dev/null
}

_get_ct_lease_ip() {
    local ctid="$1" lease_file="$2"
    [[ ! -f "$lease_file" ]] && return

    local mac
    mac=$(pct config "$ctid" 2>/dev/null \
        | grep -E '^net[0-9]+:' \
        | grep -oP 'hwaddr=\K[0-9A-Fa-f:]+' \
        | head -1 | tr '[:upper:]' '[:lower:]')

    [[ -z "$mac" ]] && return
    grep -i "$mac" "$lease_file" | awk '{print $3}' | tail -1
}

cmd_check_network() {
    local LEASE_FILE="/var/lib/misc/dnsmasq.leases"

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${WHITE}  Check Network CT${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    if [[ ! -f "$LEASE_FILE" ]]; then
        echo -e "  ${YELLOW}⚠ Không tìm thấy $LEASE_FILE, sẽ kiểm tra IP trực tiếp trong CT.${NC}"
        echo ""
    fi

    echo -e "  ${DIM}Kết hợp dãy và số lẻ (vd: ${WHITE}220-222,225,230-232${DIM}):${NC}"
    echo -ne "  ${YELLOW}CT range/ID: ${NC}"
    read -r input

    if [[ -z "$input" ]]; then
        echo -e "\n  ${DIM}Đã hủy.${NC}\n"; return
    fi

    local ct_list
    ct_list=$(parse_ct_input "$input") || { echo ""; return 1; }
    local ct_arr=($ct_list)

    echo ""
    echo -e "  ${DIM}Đang quét ${WHITE}${#ct_arr[@]} CT đã chọn${DIM}:${NC} ${ct_list}"
    echo ""

    local lost=() ok=0 total=0 skipped=0

    for ctid in "${ct_arr[@]}"; do
        if ! pct status "$ctid" 2>/dev/null | grep -q "running"; then
            echo -e "  ${DIM}[skip] CT $ctid không running hoặc không tồn tại${NC}"
            (( skipped++ ))
            continue
        fi
        (( total++ ))

        local ct_ip lease_ip
        ct_ip=$(_get_ct_ipv4 "$ctid")
        lease_ip=$(_get_ct_lease_ip "$ctid" "$LEASE_FILE")

        if [[ -z "$ct_ip" ]]; then
            if [[ -n "$lease_ip" ]]; then
                echo -e "  ${RED}[✗]${NC} CT $ctid — ${RED}không có IP trong CT${NC} ${DIM}(lease cũ: $lease_ip)${NC}"
            else
                echo -e "  ${RED}[✗]${NC} CT $ctid — ${RED}không có IP trên eth0${NC}"
            fi
            lost+=("$ctid")
        else
            echo -e "  ${GREEN}[✓]${NC} CT $ctid — IP: ${WHITE}${ct_ip}${NC}"
            (( ok++ ))
        fi
    done

    echo ""
    echo -e "${DIM}  ─────────────────────────────────────${NC}"
    local summary="  ${DIM}Tổng: ${WHITE}$total CT running đã chọn${NC} — ${GREEN}$ok OK${NC}"
    [[ ${#lost[@]} -gt 0 ]] && summary+=", ${RED}${#lost[@]} mất IP${NC}"
    [[ $skipped -gt 0 ]] && summary+=", ${DIM}${skipped} bỏ qua${NC}"
    echo -e "$summary"
    echo ""

    if [[ ${#lost[@]} -eq 0 ]]; then
        echo -e "  ${GREEN}✓ Tất cả CT đều có IP.${NC}\n"; return 0
    fi

    echo -ne "  ${YELLOW}Renew DHCP cho ${#lost[@]} CT mất IP? (y/N): ${NC}"
    read -r confirm
    echo ""
    if [[ ! "$confirm" =~ ^[yY]$ ]]; then
        echo -e "  ${DIM}Bỏ qua renew.${NC}\n"; return 0
    fi

    # Hỏi số luồng cho renew
    local threads
    threads=$(ask_threads)
    echo ""
    echo -e "  ${GREEN}▶ Renew DHCP với ${threads} luồng...${NC}"
    echo -e "${DIM}  ─────────────────────────────────────${NC}"
    echo ""

    local lost_list="${lost[*]}"
    local stats
    stats=$(run_parallel "$threads" "$lost_list" "_worker_renew_dhcp" "$LEASE_FILE")
    echo "$stats" | sed '/^__STATS__/d'

    local r_ok r_fail
    r_ok=$(echo   "$stats" | grep -oP 'ok=\K[0-9]+')
    r_fail=$(echo "$stats" | grep -oP 'failed=\K[0-9]+')

    echo -e "${DIM}  ─────────────────────────────────────${NC}"
    local rsummary="  ${GREEN}✓ Renew xong:${NC} ${WHITE}${r_ok} CT OK${NC}"
    [[ "$r_fail" -gt 0 ]] && rsummary+=", ${RED}${r_fail} thất bại${NC}"
    echo -e "$rsummary"
    echo ""
}

_worker_renew_dhcp() {
    local ctid="$1" tmpdir="$2" lease_file="$3"
    echo -ne "  CT $ctid ... "

    local method=""
    if pct exec "$ctid" -- networkctl renew eth0 2>/dev/null; then
        method="networkctl renew"
    elif pct exec "$ctid" -- dhcpcd eth0 2>/dev/null; then
        method="dhcpcd"
    else
        echo -e "${RED}✗ thất bại${NC}"
        echo "fail" > "$tmpdir/${ctid}.status"
        return
    fi

    local new_ip attempt

    for attempt in $(seq 1 10); do
        new_ip=$(_get_ct_ipv4 "$ctid")
        [[ -n "$new_ip" ]] && break

        new_ip=$(_get_ct_lease_ip "$ctid" "$lease_file")
        [[ -n "$new_ip" ]] && break

        sleep 1
    done

    if [[ -n "$new_ip" ]]; then
        echo -e "${GREEN}✓ ${method} OK${NC} ${DIM}→ IP mới:${NC} ${WHITE}${new_ip}${NC}"
        echo "ok" > "$tmpdir/${ctid}.status"
    else
        echo -e "${YELLOW}⚠ ${method} OK nhưng chưa đọc được IP mới${NC}"
        echo "fail" > "$tmpdir/${ctid}.status"
    fi
}

# ─────────────────────────────────────────────
#  WORKER: lấy điểm ARO score của 1 CT
# ─────────────────────────────────────────────
_worker_check_score() {
    local ctid="$1" tmpdir="$2"

    # Lấy hostname từ pct config
    local hostname
    hostname=$(pct config "$ctid" 2>/dev/null | grep -E '^hostname:' | awk '{print $2}')
    [[ -z "$hostname" ]] && hostname="N/A"

    # Kiểm tra CT đang running
    if ! pct status "$ctid" 2>/dev/null | grep -q "running"; then
        echo "${ctid}|${hostname}|N/A|N/A|skip" > "$tmpdir/${ctid}.row"
        echo "skip" > "$tmpdir/${ctid}.status"
        return
    fi

    # Lấy dòng log cuối có yesterday
    local log_line
    log_line=$(pct exec "$ctid" -- bash -c         "grep -a '"yesterday"' '/home/ubuntu/.local/share/com.aro.ARONetwork/logs/ARO Desktop.log' 2>/dev/null | tail -1")

    # Parse score
    local score
    score=$(echo "$log_line" | grep -oP '"yesterday":\K[0-9.]+')
    [[ -z "$score" ]] && score="N/A"

    # Parse uptime → %
    local uptime_raw uptime_pct
    uptime_raw=$(echo "$log_line" | grep -oP '"uptime":\K[0-9.]+')
    if [[ -n "$uptime_raw" ]]; then
        uptime_pct=$(awk -v u="$uptime_raw" 'BEGIN {printf "%.2f%%", u * 100}')
    else
        uptime_pct="N/A"
    fi

    echo "${ctid}|${hostname}|${score}|${uptime_pct}|ok" > "$tmpdir/${ctid}.row"
    echo "ok" > "$tmpdir/${ctid}.status"
}

# ─────────────────────────────────────────────
#  MENU: Check ARO Score
# ─────────────────────────────────────────────
cmd_check_score() {
    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${WHITE}  Check ARO Score${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    echo -e "  ${DIM}Kết hợp dãy và số lẻ (vd: ${WHITE}220-222,225,230-232${DIM}):${NC}"
    echo -ne "  ${YELLOW}CT range/ID: ${NC}"
    read -r input

    if [[ -z "$input" ]]; then
        echo -e "\n  ${DIM}Đã hủy.${NC}\n"; return
    fi

    local ct_list
    ct_list=$(parse_ct_input "$input") || { echo ""; return 1; }
    local ct_arr=($ct_list)

    echo ""
    echo -e "  ${DIM}Sẽ kiểm tra ${WHITE}${#ct_arr[@]} CT${DIM}:${NC} ${ct_list}"
    local threads
    threads=$(ask_threads)
    echo ""
    echo -e "  ${GREEN}▶ Đang lấy điểm với ${threads} luồng...${NC}"
    echo -e "${DIM}  ─────────────────────────────────────${NC}"
    echo ""

    # Chạy parallel, lấy tmpdir từ output (hack: dùng tmpdir cố định)
    local tmpdir
    tmpdir=$(mktemp -d /tmp/42_score_XXXXXX)

    local semaphore="$tmpdir/.sem"
    mkfifo "$semaphore"
    ( for _ in $(seq 1 "$threads"); do echo; done > "$semaphore" ) &
    local sem_pid=$!
    exec 9<>"$semaphore"

    local pids=()
    for ctid in "${ct_arr[@]}"; do
        read -u 9
        ( _worker_check_score "$ctid" "$tmpdir" > /dev/null 2>&1; echo >&9 ) &
        pids+=($!)
    done
    for pid in "${pids[@]}"; do wait "$pid"; done
    exec 9>&-; kill "$sem_pid" 2>/dev/null; wait "$sem_pid" 2>/dev/null

    # Thu thập kết quả, sắp xếp theo score (N/A xuống cuối)
    local results=()
    local ok=0 skipped=0

    for ctid in "${ct_arr[@]}"; do
        local row_file="$tmpdir/${ctid}.row"
        local stat_file="$tmpdir/${ctid}.status"
        [[ ! -f "$row_file" ]] && continue
        local row; row=$(cat "$row_file")
        local status; status=$(cat "$stat_file" 2>/dev/null)
        [[ "$status" == "skip" ]] && (( skipped++ )) || (( ok++ ))
        results+=("$row")
    done

    # Hiển thị bảng — sort theo score số, N/A xuống cuối
    echo -e "  ${BOLD}${WHITE}$(printf '%-8s %-20s %-12s %s' 'CT ID' 'Hostname' 'Score' 'Uptime')${NC}"
    echo -e "  ${DIM}$(printf '%-8s %-20s %-12s %s' '──────' '────────────────────' '────────────' '──────')${NC}"

    # Sort: dòng có score số lên trên (desc), N/A xuống cuối
    local sorted_num=() sorted_na=()
    for row in "${results[@]}"; do
        local score; score=$(echo "$row" | cut -d'|' -f3)
        if [[ "$score" == "N/A" ]]; then
            sorted_na+=("$row")
        else
            sorted_num+=("$row")
        fi
    done

    # Sort numeric desc
    IFS=$'\n' sorted_num=($(printf '%s\n' "${sorted_num[@]}" | sort -t'|' -k3 -rn))
    unset IFS

    local all_rows=("${sorted_num[@]}" "${sorted_na[@]}")

    for row in "${all_rows[@]}"; do
        local ctid;     ctid=$(echo     "$row" | cut -d'|' -f1)
        local hostname; hostname=$(echo "$row" | cut -d'|' -f2)
        local score;    score=$(echo    "$row" | cut -d'|' -f3)
        local uptime;   uptime=$(echo   "$row" | cut -d'|' -f4)
        local status;   status=$(echo   "$row" | cut -d'|' -f5)

        local score_esc
        if [[ "$score" == "N/A" || "$status" == "skip" ]]; then
            score_esc="$DIM"
        elif (( $(echo "$score >= 80" | bc -l 2>/dev/null) )); then
            score_esc="$GREEN"
        elif (( $(echo "$score >= 50" | bc -l 2>/dev/null) )); then
            score_esc="$YELLOW"
        else
            score_esc="$RED"
        fi

        echo -e "  $(printf '%-8s %-20s' "$ctid" "$hostname")${score_esc}$(printf '%-12s' "$score")${NC}${DIM}${uptime}${NC}"
    done

    echo ""
    echo -e "${DIM}  ─────────────────────────────────────${NC}"
    local summary="  ${DIM}Tổng: ${WHITE}$ok CT có dữ liệu${NC}"
    [[ $skipped -gt 0 ]] && summary+=", ${DIM}${skipped} bỏ qua (không running)${NC}"
    echo -e "$summary"
    echo ""

    # Hỏi có lưu CSV không
    echo -ne "  ${YELLOW}Lưu kết quả ra file CSV? (y/N): ${NC}"
    read -r save_confirm
    echo ""

    if [[ "$save_confirm" =~ ^[yY]$ ]]; then
        local datestamp
        datestamp=$(date '+%d-%m-%Y')
        local csv_file="/root/aro_score_${datestamp}.csv"

        echo "CT ID,Hostname,Score,Uptime" > "$csv_file"
        for row in "${all_rows[@]}"; do
            local ctid;     ctid=$(echo     "$row" | cut -d'|' -f1)
            local hostname; hostname=$(echo "$row" | cut -d'|' -f2)
            local score;    score=$(echo    "$row" | cut -d'|' -f3)
            local uptime;   uptime=$(echo   "$row" | cut -d'|' -f4)
            echo "${ctid},${hostname},${score},${uptime}" >> "$csv_file"
        done

        echo -e "  ${GREEN}✓ Đã lưu:${NC} ${WHITE}${csv_file}${NC}"
        echo -e "  ${DIM}$(wc -l < "$csv_file") dòng (gồm header)${NC}"
        echo ""
    fi

    rm -rf "$tmpdir"
}

# ─────────────────────────────────────────────
#  MENU DISPLAY & NAVIGATION
# ─────────────────────────────────────────────
draw_header() {
    clear
    echo ""
    echo -e "${BOLD}${MAGENTA}  ╔══════════════════════════════════════╗${NC}"
    echo -e "${BOLD}${MAGENTA}  ║${NC}  ${WHITE}${BOLD}✦  PROXMOX QUICK COMMANDS  ✦${NC}       ${BOLD}${MAGENTA}║${NC}"
    echo -e "${BOLD}${MAGENTA}  ║${NC}              ${DIM}version ${APP_VERSION}${NC}              ${BOLD}${MAGENTA}║${NC}"
    echo -e "${BOLD}${MAGENTA}  ╚══════════════════════════════════════╝${NC}"
    echo -e "  ${DIM}$(hostname) · $(date '+%Y-%m-%d %H:%M')${NC}"
    echo ""
}

draw_menu() {
    echo -e "  ${CYAN}────────────────────────────────────────────────────────────────────────────${NC}"
    local total=${#MENU_NAMES[@]}
    local cols=3
    local rows=$(( (total + cols - 1) / cols ))
    local row col idx num

    for (( row=0; row<rows; row++ )); do
        echo -n "  "
        for (( col=0; col<cols; col++ )); do
            idx=$(( row + col * rows ))
            if (( idx < total )); then
                num=$(( idx + 1 ))
                printf "${BOLD}${YELLOW}[%2d]${NC} ${WHITE}%-22s${NC}" "$num" "${MENU_NAMES[$idx]}"
            fi
        done
        echo ""
    done
    echo ""
    echo -e "  ${BOLD}${RED}[ 0]${NC} ${DIM}Thoát${NC}"
    echo -e "  ${CYAN}────────────────────────────────────────────────────────────────────────────${NC}"
    echo ""
    echo -ne "  ${BOLD}Chọn lệnh: ${NC}"
}

main() {
    while true; do
        draw_header
        draw_menu
        if ! read -r choice; then
            echo -e "\n  ${DIM}Tạm biệt!${NC}\n"; exit 0
        fi

        if [[ "$choice" == "0" || "$choice" == "q" || "$choice" == "Q" ]]; then
            echo -e "\n  ${DIM}Tạm biệt!${NC}\n"; exit 0
        fi

        local total=${#MENU_NAMES[@]}
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= total )); then
            local idx=$(( choice - 1 ))
            local func="${MENU_FUNCS[$idx]}"
            if declare -f "$func" > /dev/null; then
                "$func"
            else
                echo -e "\n  ${RED}✗ Hàm '$func' chưa được định nghĩa!${NC}\n"
            fi
            echo -ne "  ${DIM}Nhấn Enter để quay lại menu...${NC}"
            read -r
        else
            echo -e "\n  ${RED}✗ Lựa chọn không hợp lệ.${NC}"
            sleep 1
        fi
    done
}

main
