#!/usr/bin/env bash
set -euo pipefail
IFS=$'\n\t'

#==============================================================================
# sing-box 多协议一键管理脚本
# 支持: SS / VMess-WS-TLS / VLESS-REALITY / VLESS-WS-TLS / Trojan / Hysteria2 / TUIC
#==============================================================================

# ---- 常量 & 颜色 ----
RED='\033[0;31m'    GREEN='\033[0;32m'    YELLOW='\033[1;33m'
BLUE='\033[0;34m'   CYAN='\033[0;36m'     MAGENTA='\033[0;35m'
BOLD='\033[1m'      NC='\033[0m'

# 自动检测或使用默认路径
detect_singbox_paths() {
    # 按优先级检查已知安装路径
    if [[ -x /etc/s-box/sing-box ]]; then
        SINGBOX_BIN="/etc/s-box/sing-box"
        SINGBOX_CONFIG_DIR="/etc/s-box"
        SINGBOX_CONFIG="${SINGBOX_CONFIG_DIR}/sb.json"
    elif [[ -x /usr/local/bin/sing-box ]]; then
        SINGBOX_BIN="/usr/local/bin/sing-box"
        SINGBOX_CONFIG_DIR="/etc/sing-box"
        SINGBOX_CONFIG="${SINGBOX_CONFIG_DIR}/config.json"
    elif [[ -x /usr/bin/sing-box ]]; then
        SINGBOX_BIN="/usr/bin/sing-box"
        SINGBOX_CONFIG_DIR="/etc/sing-box"
        SINGBOX_CONFIG="${SINGBOX_CONFIG_DIR}/config.json"
    else
        # 默认 (安装时会创建)
        SINGBOX_BIN="/usr/local/bin/sing-box"
        SINGBOX_CONFIG_DIR="/etc/sing-box"
        SINGBOX_CONFIG="${SINGBOX_CONFIG_DIR}/config.json"
    fi
    SINGBOX_SERVICE="/etc/systemd/system/sing-box.service"
}

# 初始化路径
detect_singbox_paths

GITHUB_API="https://api.github.com/repos/Sagernet/sing-box/releases/latest"

# ---- 工具函数 ----
print_ok()    { echo -e "  ${GREEN}[✓]${NC} $*"; }
print_err()   { echo -e "  ${RED}[✗]${NC} $*"; }
print_info()  { echo -e "  ${CYAN}[→]${NC} $*"; }
print_warn()  { echo -e "  ${YELLOW}[!]${NC} $*"; }

banner() {
    clear
    echo -e "${MAGENTA}"
    echo "  ╔══════════════════════════════════════════════╗"
    echo "  ║          sing-box 多协议节点管理脚本          ║"
    echo "  ║            v1.0  |  sing-box 内核             ║"
    echo "  ╚══════════════════════════════════════════════╝"
    echo -e "${NC}"
}

press_any_key() {
    echo
    read -r -p "  按回车键继续..." _
}

input() {
    local prompt="$1" default="$2" val
    read -r -p "  $prompt [$default]: " val
    echo "${val:-$default}"
}

input_required() {
    local prompt="$1" val
    while true; do
        read -r -p "  $prompt: " val
        [[ -n "$val" ]] && { echo "$val"; return; }
        print_warn "此项不能为空"
    done
}

input_port() {
    local prompt="${1:-端口}" default="${2:-}" val
    while true; do
        val=$(input "$prompt" "${default:-$(shuf -i 10000-65000 -n 1)}")
        if [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 1 && val <= 65535 )); then
            if ss -tuln | grep -q ":$val "; then
                print_warn "端口 $val 已被占用，请换一个"
            else
                echo "$val"; return
            fi
        else
            print_warn "请输入 1-65535 之间的数字"
        fi
    done
}

confirm() {
    local prompt="${1:-确认?}" ans
    read -r -p "  $prompt [y/N]: " ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

# ---- 系统检测 & 依赖 ----
detect_os() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        OS="${ID}"
        OS_VERSION="${VERSION_ID}"
    else
        print_err "无法检测系统版本"; exit 1
    fi
}

install_deps() {
    detect_os
    local deps="curl wget jq"
    print_info "安装依赖: $deps ..."

    case "$OS" in
        debian|ubuntu)
            apt-get update -qq && apt-get install -y -qq $deps ;;
        centos|rhel|fedora|rocky|almalinux)
            yum install -y -q $deps 2>/dev/null || dnf install -y -q $deps ;;
        *)
            print_warn "未知系统，请手动安装: $deps"
            press_any_key ;;
    esac

    # 可选: qrencode (生成二维码)
    if ! command -v qrencode &>/dev/null; then
        case "$OS" in
            debian|ubuntu) apt-get install -y -qq qrencode 2>/dev/null || true ;;
            centos|rhel|fedora|rocky|almalinux) yum install -y -q qrencode 2>/dev/null || true ;;
        esac
    fi

    print_ok "依赖安装完成"
}

# ---- sing-box 安装 / 更新 ----
install_singbox() {
    banner
    echo -e "${BOLD}安装 / 更新 sing-box${NC}"
    echo

    detect_os

    # 检测架构
    local arch
    case "$(uname -m)" in
        x86_64)  arch="amd64" ;;
        aarch64|arm64) arch="arm64" ;;
        *) print_err "不支持的架构: $(uname -m)"; return 1 ;;
    esac

    print_info "系统: ${OS} | 架构: ${arch}"

    # 获取最新版本
    print_info "获取 sing-box 最新版本..."
    local latest_ver
    latest_ver=$(curl -s "${GITHUB_API}" | jq -r '.tag_name' 2>/dev/null)
    if [[ -z "$latest_ver" || "$latest_ver" == "null" ]]; then
        print_err "无法获取最新版本号，请检查网络"
        return 1
    fi

    print_info "最新版本: ${latest_ver}"

    local current_ver=""
    if [[ -x "$SINGBOX_BIN" ]]; then
        current_ver=$("$SINGBOX_BIN" version 2>/dev/null | head -1 | grep -oP '[\d]+\.[\d]+\.[\d]+' || echo "未知")
        print_info "当前版本: ${current_ver}"
    fi

    if [[ "$current_ver" == "${latest_ver#v}" ]]; then
        print_ok "已是最新版本"
        press_any_key; return
    fi

    if ! confirm "确认安装/更新到 ${latest_ver}?"; then
        return
    fi

    # 下载
    local dl_url="https://github.com/Sagernet/sing-box/releases/download/${latest_ver}/sing-box-${latest_ver#v}-linux-${arch}.tar.gz"
    local tmpdir; tmpdir=$(mktemp -d)

    print_info "下载中... ${dl_url}"
    if ! curl -L --progress-bar "$dl_url" -o "$tmpdir/sing-box.tar.gz"; then
        print_err "下载失败"; rm -rf "$tmpdir"; return 1
    fi

    tar -xzf "$tmpdir/sing-box.tar.gz" -C "$tmpdir"

    # 找到解压目录
    local sb_dir
    sb_dir=$(find "$tmpdir" -name 'sing-box' -type d | head -1)

    # 停止旧服务
    systemctl stop sing-box 2>/dev/null || true

    # 安装二进制
    cp -f "${sb_dir}/sing-box" "$SINGBOX_BIN"
    chmod +x "$SINGBOX_BIN"

    # 安装 systemd 服务
    mkdir -p "$SINGBOX_CONFIG_DIR"

    if [[ ! -f "$SINGBOX_SERVICE" ]]; then
        cat > "$SINGBOX_SERVICE" << SERVICE_EOF
[Unit]
Description=sing-box
Documentation=https://sing-box.sagernet.org
After=network.target network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_CONFIG}
Restart=on-failure
RestartSec=10
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE_EOF
        systemctl daemon-reload
        systemctl enable sing-box 2>/dev/null || true
    fi

    # 初始化空 config
    if [[ ! -f "$SINGBOX_CONFIG" ]]; then
        cat > "$SINGBOX_CONFIG" << 'CONFIG_EOF'
{
  "log": { "level": "info" },
  "inbounds": [],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
CONFIG_EOF
    fi

    rm -rf "$tmpdir"

    # 创建快捷命令
    setup_alias

    print_ok "sing-box ${latest_ver} 安装完成"
    echo
    echo -e "  ${CYAN}提示: 以后直接输入 ${GREEN}sb${NC}${CYAN} 即可唤出管理面板${NC}"
    press_any_key
}

setup_alias() {
    local script_path
    script_path="$(readlink -f "$0")"
    echo "#!/usr/bin/env bash" > /usr/local/bin/sb
    echo "sudo bash '$script_path'" >> /usr/local/bin/sb
    chmod +x /usr/local/bin/sb
    print_ok "快捷命令已创建: sb"
}

# ---- JSON 操作 (用 jq) ----
json_add_inbound() {
    local inbound_json="$1"
    local tmp; tmp=$(mktemp)
    jq --argjson obj "$inbound_json" '.inbounds += [$obj]' "$SINGBOX_CONFIG" > "$tmp" && mv "$tmp" "$SINGBOX_CONFIG"
}

json_delete_inbound() {
    local tag="$1"
    local tmp; tmp=$(mktemp)
    jq --arg tag "$tag" 'del(.inbounds[] | select(.tag == $tag))' "$SINGBOX_CONFIG" > "$tmp" && mv "$tmp" "$SINGBOX_CONFIG"
}

json_get_inbound() {
    local tag="$1"
    jq -r --arg tag "$tag" '.inbounds[] | select(.tag == $tag)' "$SINGBOX_CONFIG" 2>/dev/null
}

json_list_tags() {
    jq -r '.inbounds[]?.tag // empty' "$SINGBOX_CONFIG" 2>/dev/null
}

json_list_ports() {
    jq -r '.inbounds[]? | "\(.tag) -> :\(.listen_port) [\(.type)]"' "$SINGBOX_CONFIG" 2>/dev/null
}

json_count_inbounds() {
    jq -r '.inbounds | length' "$SINGBOX_CONFIG" 2>/dev/null || echo 0
}

# ---- 服务管理 ----
service_ctl() {
    local action="$1"
    case "$action" in
        start)   systemctl start sing-box 2>/dev/null && print_ok "服务已启动" || print_err "启动失败";;
        stop)    systemctl stop sing-box 2>/dev/null && print_ok "服务已停止" || print_err "停止失败";;
        restart) systemctl restart sing-box 2>/dev/null && print_ok "服务已重启" || print_err "重启失败";;
        status)
            echo
            systemctl status sing-box --no-pager 2>/dev/null || print_warn "服务状态获取失败"
            ;;
        logs)
            echo
            journalctl -u sing-box -n 50 --no-pager -o cat 2>/dev/null || print_warn "日志读取失败"
            ;;
    esac
}

is_running() {
    systemctl is-active --quiet sing-box 2>/dev/null
}

apply_config() {
    local tag="$1"
    # 验证 config
    if ! "$SINGBOX_BIN" check -c "$SINGBOX_CONFIG" &>/dev/null; then
        print_err "配置验证失败，已回滚"
        json_delete_inbound "$tag"
        return 1
    fi

    if is_running; then
        systemctl restart sing-box
        print_ok "节点 <${tag}> 已生效 (已重启服务)"
    else
        if confirm "服务未运行，是否立即启动?"; then
            service_ctl start
        else
            print_info "配置已保存，服务未启动"
        fi
    fi
}

# ---- 生成随机值 ----
gen_uuid()    { sing-box generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid; }
gen_password() { head -c 24 /dev/urandom | base64 | tr -d "=+/"; }
gen_shortid() { head -c 4 /dev/urandom | od -A n -t x1 | tr -d ' \n'; }
gen_reality_keys() {
    "$SINGBOX_BIN" generate reality-keypair 2>/dev/null || {
        # fallback to openssl
        local priv; priv=$(openssl genpkey -algorithm X25519 2>/dev/null | openssl pkey -text -noout 2>/dev/null | grep -A1 'priv' | tail -1 | tr -d ' :')
        local pub; pub=$(openssl pkey -pubout -in <(echo "$priv") 2>/dev/null | openssl pkey -pubin -text -noout | grep -A1 'pub' | tail -1 | tr -d ' :')
        echo "privateKey: $priv"
        echo "publicKey: $pub"
    }
}

# ---- 获取公网 IP ----
get_public_ip() {
    curl -s -4 ip.sb 2>/dev/null || curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 api.ipify.org 2>/dev/null || echo "未知"
}

# ---- 生成分享链接 ----
gen_ss_link() {
    local method="$1" password="$2" host="$3" port="$4" tag="$5"
    local b64; b64=$(echo -n "${method}:${password}" | base64 -w0)
    echo "ss://${b64}@${host}:${port}#${tag}"
}

gen_vmess_link() {
    local uuid="$1" host="$2" port="$3" net="$4" path="$5" tls="$6" sni="$7" tag="$8"
    local json; json=$(jq -n --arg v "2" --arg ps "$tag" --arg add "$host" --arg port "$port" \
        --arg id "$uuid" --arg net "$net" --arg path "$path" --arg tls "$tls" --arg sni "$sni" \
        '{v: $v, ps: $ps, add: $add, port: $port, id: $id, net: $net, path: $path, tls: $tls, sni: $sni, type: "none"}')
    echo "vmess://$(echo -n "$json" | base64 -w0)"
}

gen_vless_link() {
    local uuid="$1" host="$2" port="$3" net="$4" path="$5" tls="$6" sni="$7" flow="$8" pbk="$9" sid="${10}" fp="${11}" tag="${12}"
    local params="type=${net}&security=${tls}"
    [[ -n "$sni" ]] && params+="&sni=${sni}"
    [[ -n "$path" ]] && params+="&path=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$path'))" 2>/dev/null || echo "$path")"
    [[ -n "$flow" ]] && params+="&flow=${flow}"
    [[ -n "$pbk" ]] && params+="&pbk=${pbk}"
    [[ -n "$sid" ]] && params+="&sid=${sid}"
    [[ -n "$fp" ]] && params+="&fp=${fp}"
    echo "vless://${uuid}@${host}:${port}?${params}#$(python3 -c "import urllib.parse; print(urllib.parse.quote('$tag'))" 2>/dev/null || echo "$tag")"
}

gen_trojan_link() {
    local password="$1" host="$2" port="$3" sni="$4" tag="$5"
    echo "trojan://${password}@${host}:${port}?security=tls&sni=${sni}&type=tcp#$(python3 -c "import urllib.parse; print(urllib.parse.quote('$tag'))" 2>/dev/null || echo "$tag")"
}

gen_hysteria2_link() {
    local password="$1" host="$2" port="$3" sni="$4" tag="$5"
    local params="insecure=0"
    [[ -n "$sni" ]] && params+="&sni=${sni}"
    echo "hysteria2://${password}@${host}:${port}?${params}#$(python3 -c "import urllib.parse; print(urllib.parse.quote('$tag'))" 2>/dev/null || echo "$tag")"
}

gen_tuic_link() {
    local uuid="$1" password="$2" host="$3" port="$4" sni="$5" tag="$6"
    local params="congestion_control=bbr&udp_relay_mode=native&alpn=h3"
    [[ -n "$sni" ]] && params+="&sni=${sni}"
    echo "tuic://${uuid}:${password}@${host}:${port}?${params}#$(python3 -c "import urllib.parse; print(urllib.parse.quote('$tag'))" 2>/dev/null || echo "$tag")"
}

# URL 编码
urlencode() {
    local str="$*"
    python3 -c "import urllib.parse; print(urllib.parse.quote('$str'))" 2>/dev/null || echo "$str"
}

# 生成二维码 (终端内)
qr_show() {
    local text="$1" title="$2"
    echo -e "\n${CYAN}━━━ ${title} ━━━${NC}"
    if command -v qrencode &>/dev/null; then
        echo
        qrencode -t ANSIUTF8 -m 1 -s 2 "$text"
    else
        echo
        echo -e "${YELLOW}提示: 安装 qrencode 可显示二维码${NC}"
    fi
    echo -e "\n${GREEN}分享链接:${NC}"
    echo "$text"
}

# ---- 协议配置生成器 ----
add_ss() {
    echo
    echo -e "${BOLD}===== 添加 Shadowsocks 节点 =====${NC}"
    local tag; tag="ss-$(date +%s)"
    local port; port=$(input_port "端口" "8388")
    echo
    echo "  加密方式:"
    echo "    a) 2022-blake3-aes-128-gcm (推荐)"
    echo "    b) aes-256-gcm"
    echo "    c) aes-128-gcm"
    echo "    d) chacha20-ietf-poly1305"
    local method_choice; read -r -p "  选择 [a]: " method_choice
    local method
    case "${method_choice:-a}" in
        a) method="2022-blake3-aes-128-gcm" ;;
        b) method="aes-256-gcm" ;;
        c) method="aes-128-gcm" ;;
        d) method="chacha20-ietf-poly1305" ;;
        *) method="2022-blake3-aes-128-gcm" ;;
    esac
    local password; password=$(input "密码 (留空自动生成)" "$(gen_password)")

    local inbound_json
    inbound_json=$(jq -n \
        --arg type "shadowsocks" --arg tag "$tag" --arg listen "::" \
        --arg port "$port" --arg method "$method" --arg password "$password" \
        '{type: $type, tag: $tag, listen: $listen, listen_port: ($port|tonumber), method: $method, password: $password}')
    json_add_inbound "$inbound_json"

    apply_config "$tag"

    local ip; ip=$(get_public_ip)
    echo
    print_ok "节点 <$tag> 添加完成"
    echo
    local link; link=$(gen_ss_link "$method" "$password" "$ip" "$port" "$tag")
    qr_show "$link" "Shadowsocks"
}

add_vmess_ws_tls() {
    echo
    echo -e "${BOLD}===== 添加 VMess + WebSocket + TLS 节点 =====${NC}"
    local tag; tag="vmess-ws-tls-$(date +%s)"
    local port; port=$(input_port "端口" "443")
    local uuid; uuid=$(input "UUID (留空自动生成)" "$(gen_uuid)")
    local ws_path; ws_path=$(input "WebSocket 路径" "/ws")
    local domain; domain=$(input_required "TLS 域名")
    local cert_path; cert_path=$(input "TLS 证书路径 (/path/to/fullchain.pem)" "/etc/ssl/certs/${domain}.pem")
    local key_path; key_path=$(input "TLS 私钥路径 (/path/to/privkey.pem)" "/etc/ssl/private/${domain}.key")

    if [[ ! -f "$cert_path" ]]; then
        print_warn "证书文件 $cert_path 不存在，请确认路径正确"
        if ! confirm "继续添加?"; then return; fi
    fi

    local inbound_json
    inbound_json=$(jq -n \
        --arg type "vmess" --arg tag "$tag" --arg listen "::" \
        --arg port "$port" --arg uuid "$uuid" \
        --arg path "$ws_path" --arg cert "$cert_path" --arg key "$key_path" \
        --arg sni "$domain" \
        '{
            type: $type, tag: $tag, listen: $listen, listen_port: ($port|tonumber),
            users: [{ uuid: $uuid, alterId: 0 }],
            transport: { type: "ws", path: $path, headers: { Host: $sni } },
            tls: { enabled: true, server_name: $sni, certificate_path: $cert, key_path: $key }
        }')
    json_add_inbound "$inbound_json"

    apply_config "$tag"

    local ip; ip=$(get_public_ip)
    local link; link=$(gen_vmess_link "$uuid" "$domain" "$port" "ws" "$ws_path" "tls" "$domain" "$tag")
    echo
    print_ok "节点 <$tag> 添加完成"
    qr_show "$link" "VMess+WS+TLS"
}

add_vless_reality() {
    echo
    echo -e "${BOLD}===== 添加 VLESS + REALITY 节点 =====${NC}"
    local tag; tag="vless-reality-$(date +%s)"
    local port; port=$(input_port "端口" "443")
    local uuid; uuid=$(input "UUID (留空自动生成)" "$(gen_uuid)")
    local flow; flow="xtls-rprx-vision"

    # REALITY 目标
    echo
    echo "  REALITY 伪装目标 (dest):"
    echo "    a) www.microsoft.com:443 (推荐)"
    echo "    b) www.apple.com:443"
    echo "    c) www.amazon.com:443"
    echo "    d) 自定义"
    local dest_choice; read -r -p "  选择 [a]: " dest_choice
    local dest
    case "${dest_choice:-a}" in
        a) dest="www.microsoft.com:443" ;;
        b) dest="www.apple.com:443" ;;
        c) dest="www.amazon.com:443" ;;
        d) dest=$(input_required "自定义 dest (host:port)") ;;
    esac

    local server_name; server_name="${dest%:*}"
    local short_id; short_id=$(input "Short ID (留空自动生成)" "$(gen_shortid)")

    print_info "生成 REALITY 密钥对..."
    local keys; keys=$(gen_reality_keys)
    local priv_key; priv_key=$(echo "$keys" | grep -oP 'privateKey:\s*\K\S+')
    local pub_key; pub_key=$(echo "$keys" | grep -oP 'publicKey:\s*\K\S+' | head -1)

    if [[ -z "$priv_key" ]]; then
        print_err "密钥生成失败"; return 1
    fi

    local inbound_json
    inbound_json=$(jq -n \
        --arg type "vless" --arg tag "$tag" --arg listen "::" \
        --arg port "$port" --arg uuid "$uuid" \
        --arg flow "$flow" --arg dest "$dest" --arg sni "$server_name" \
        --arg short_id "$short_id" --arg priv_key "$priv_key" \
        '{
            type: $type, tag: $tag, listen: $listen, listen_port: ($port|tonumber),
            users: [{ uuid: $uuid, flow: $flow }],
            tls: {
                enabled: true,
                server_name: $sni,
                reality: {
                    enabled: true,
                    handshake: { server: $dest, server_name: $sni },
                    private_key: $priv_key,
                    short_id: [$short_id]
                }
            }
        }')
    json_add_inbound "$inbound_json"

    apply_config "$tag"

    local ip; ip=$(get_public_ip)
    local link; link=$(gen_vless_link "$uuid" "$ip" "$port" "tcp" "" "reality" "$server_name" "$flow" "$pub_key" "$short_id" "chrome" "$tag")
    echo
    print_ok "节点 <$tag> 添加完成"
    echo -e "\n${YELLOW}REALITY 公钥 (客户端需要):${NC} $pub_key"
    qr_show "$link" "VLESS+REALITY"
}

add_vless_ws_tls() {
    echo
    echo -e "${BOLD}===== 添加 VLESS + WebSocket + TLS 节点 =====${NC}"
    local tag; tag="vless-ws-tls-$(date +%s)"
    local port; port=$(input_port "端口" "443")
    local uuid; uuid=$(input "UUID (留空自动生成)" "$(gen_uuid)")
    local ws_path; ws_path=$(input "WebSocket 路径" "/vless-ws")
    local domain; domain=$(input_required "TLS 域名")
    local cert_path; cert_path=$(input "TLS 证书路径" "/etc/ssl/certs/${domain}.pem")
    local key_path; key_path=$(input "TLS 私钥路径" "/etc/ssl/private/${domain}.key")

    local inbound_json
    inbound_json=$(jq -n \
        --arg type "vless" --arg tag "$tag" --arg listen "::" \
        --arg port "$port" --arg uuid "$uuid" \
        --arg path "$ws_path" --arg cert "$cert_path" --arg key "$key_path" \
        --arg sni "$domain" \
        '{
            type: $type, tag: $tag, listen: $listen, listen_port: ($port|tonumber),
            users: [{ uuid: $uuid }],
            transport: { type: "ws", path: $path, headers: { Host: $sni } },
            tls: { enabled: true, server_name: $sni, certificate_path: $cert, key_path: $key }
        }')
    json_add_inbound "$inbound_json"

    apply_config "$tag"

    local link; link=$(gen_vless_link "$uuid" "$domain" "$port" "ws" "$ws_path" "tls" "$domain" "" "" "" "" "$tag")
    echo
    print_ok "节点 <$tag> 添加完成"
    qr_show "$link" "VLESS+WS+TLS"
}

add_trojan() {
    echo
    echo -e "${BOLD}===== 添加 Trojan + TLS 节点 =====${NC}"
    local tag; tag="trojan-$(date +%s)"
    local port; port=$(input_port "端口" "443")
    local password; password=$(input "密码 (留空自动生成)" "$(gen_password)")
    local domain; domain=$(input_required "TLS 域名")
    local cert_path; cert_path=$(input "TLS 证书路径" "/etc/ssl/certs/${domain}.pem")
    local key_path; key_path=$(input "TLS 私钥路径" "/etc/ssl/private/${domain}.key")

    local inbound_json
    inbound_json=$(jq -n \
        --arg type "trojan" --arg tag "$tag" --arg listen "::" \
        --arg port "$port" --arg password "$password" \
        --arg cert "$cert_path" --arg key "$key_path" --arg sni "$domain" \
        '{
            type: $type, tag: $tag, listen: $listen, listen_port: ($port|tonumber),
            users: [{ password: $password }],
            tls: { enabled: true, server_name: $sni, certificate_path: $cert, key_path: $key }
        }')
    json_add_inbound "$inbound_json"

    apply_config "$tag"

    local link; link=$(gen_trojan_link "$password" "$domain" "$port" "$domain" "$tag")
    echo
    print_ok "节点 <$tag> 添加完成"
    qr_show "$link" "Trojan+TLS"
}

add_hysteria2() {
    echo
    echo -e "${BOLD}===== 添加 Hysteria2 节点 =====${NC}"
    local tag; tag="hysteria2-$(date +%s)"
    local port; port=$(input_port "端口" "4443")

    echo
    echo "  模式:"
    echo "    a) 不带 TLS (端口跳跃模式，简单)"
    echo "    b) 带 TLS (需要域名+证书，更安全)"
    local mode_choice; read -r -p "  选择 [a]: " mode_choice
    mode_choice="${mode_choice:-a}"

    local password; password=$(input "密码 (留空自动生成)" "$(gen_password)")

    local inbound_json domain="" cert_path="" key_path=""
    if [[ "$mode_choice" == "b" ]]; then
        domain=$(input_required "TLS 域名")
        cert_path=$(input "TLS 证书路径" "/etc/ssl/certs/${domain}.pem")
        key_path=$(input "TLS 私钥路径" "/etc/ssl/private/${domain}.key")
        inbound_json=$(jq -n \
            --arg type "hysteria2" --arg tag "$tag" --arg listen "::" \
            --arg port "$port" --arg password "$password" \
            --arg cert "$cert_path" --arg key "$key_path" --arg sni "$domain" \
            '{
                type: $type, tag: $tag, listen: $listen, listen_port: ($port|tonumber),
                users: [{ password: $password }],
                tls: { enabled: true, server_name: $sni, certificate_path: $cert, key_path: $key }
            }')
    else
        inbound_json=$(jq -n \
            --arg type "hysteria2" --arg tag "$tag" --arg listen "::" \
            --arg port "$port" --arg password "$password" \
            '{
                type: $type, tag: $tag, listen: $listen, listen_port: ($port|tonumber),
                users: [{ password: $password }]
            }')
    fi

    json_add_inbound "$inbound_json"

    apply_config "$tag"

    local ip; ip=$(get_public_ip)
    local link; link=$(gen_hysteria2_link "$password" "$ip" "$port" "${domain:-}" "$tag")
    echo
    print_ok "节点 <$tag> 添加完成"
    qr_show "$link" "Hysteria2"
}

add_tuic() {
    echo
    echo -e "${BOLD}===== 添加 TUIC 节点 =====${NC}"
    local tag; tag="tuic-$(date +%s)"
    local port; port=$(input_port "端口" "5555")
    local uuid; uuid=$(input "UUID (留空自动生成)" "$(gen_uuid)")
    local password; password=$(input "密码 (留空自动生成)" "$(gen_password)")

    echo
    echo "  模式:"
    echo "    a) 不带 TLS (简单)"
    echo "    b) 带 TLS (需要域名+证书)"
    local mode_choice; read -r -p "  选择 [a]: " mode_choice
    mode_choice="${mode_choice:-a}"

    local inbound_json domain="" cert_path="" key_path=""
    if [[ "$mode_choice" == "b" ]]; then
        domain=$(input_required "TLS 域名")
        cert_path=$(input "TLS 证书路径" "/etc/ssl/certs/${domain}.pem")
        key_path=$(input "TLS 私钥路径" "/etc/ssl/private/${domain}.key")
        inbound_json=$(jq -n \
            --arg type "tuic" --arg tag "$tag" --arg listen "::" \
            --arg port "$port" --arg uuid "$uuid" --arg password "$password" \
            --arg cert "$cert_path" --arg key "$key_path" --arg sni "$domain" \
            '{
                type: $type, tag: $tag, listen: $listen, listen_port: ($port|tonumber),
                users: [{ uuid: $uuid, password: $password }],
                tls: { enabled: true, server_name: $sni, certificate_path: $cert, key_path: $key },
                congestion_control: "bbr"
            }')
    else
        inbound_json=$(jq -n \
            --arg type "tuic" --arg tag "$tag" --arg listen "::" \
            --arg port "$port" --arg uuid "$uuid" --arg password "$password" \
            '{
                type: $type, tag: $tag, listen: $listen, listen_port: ($port|tonumber),
                users: [{ uuid: $uuid, password: $password }],
                congestion_control: "bbr"
            }')
    fi

    json_add_inbound "$inbound_json"

    apply_config "$tag"

    local ip; ip=$(get_public_ip)
    local link; link=$(gen_tuic_link "$uuid" "$password" "$ip" "$port" "${domain:-}" "$tag")
    echo
    print_ok "节点 <$tag> 添加完成"
    qr_show "$link" "TUIC"
}

# ---- 添加节点入口 ----
add_node_menu() {
    while true; do
        banner
        echo -e "${BOLD}添加节点${NC}"
        echo
        echo "  1) Shadowsocks"
        echo "  2) VMess + WebSocket + TLS"
        echo "  3) VLESS + REALITY         ← 推荐 (免域名)"
        echo "  4) VLESS + WebSocket + TLS"
        echo "  5) Trojan + TLS"
        echo "  6) Hysteria2               ← 高性能"
        echo "  7) TUIC"
        echo "  0) 返回主菜单"
        echo
        local choice; read -r -p "  请选择 [0-7]: " choice

        case "$choice" in
            1) add_ss ; press_any_key ;;
            2) add_vmess_ws_tls ; press_any_key ;;
            3) add_vless_reality ; press_any_key ;;
            4) add_vless_ws_tls ; press_any_key ;;
            5) add_trojan ; press_any_key ;;
            6) add_hysteria2 ; press_any_key ;;
            7) add_tuic ; press_any_key ;;
            0) return ;;
            *) print_warn "无效选择" ; sleep 1 ;;
        esac
    done
}

# ---- 删除节点 ----
delete_node() {
    banner
    echo -e "${BOLD}删除节点${NC}"
    echo

    local tags; tags=$(json_list_tags)
    if [[ -z "$tags" ]]; then
        print_warn "没有已配置的节点"
        press_any_key; return
    fi

    echo "  当前节点:"
    echo
    local i=1
    local tag_arr=()
    while IFS= read -r t; do
        local info; info=$(jq -r --arg tag "$t" '.inbounds[] | select(.tag == $tag) | "\(.type) -> :\(.listen_port)"' "$SINGBOX_CONFIG")
        echo "  $i) $t  [$info]"
        tag_arr+=("$t")
        ((i++))
    done <<< "$tags"
    echo

    local num; read -r -p "  选择要删除的节点 [1-$((i-1)), 0=取消]: " num
    if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#tag_arr[@]} )); then
        local target="${tag_arr[$((num-1))]}"
        if confirm "确认删除节点 <${target}>?"; then
            json_delete_inbound "$target"
            if is_running; then
                systemctl restart sing-box
            fi
            print_ok "节点 <$target> 已删除"
        fi
    elif [[ "$num" != "0" ]]; then
        print_warn "无效选择"
    fi
    press_any_key
}

# ---- 修改节点 ----
modify_node_menu() {
    banner
    echo -e "${BOLD}修改节点${NC}"
    echo

    local tags; tags=$(json_list_tags)
    if [[ -z "$tags" ]]; then
        print_warn "没有已配置的节点"
        press_any_key; return
    fi

    echo "  当前节点:"
    echo
    local i=1
    local tag_arr=()
    while IFS= read -r t; do
        local info; info=$(jq -r --arg tag "$t" '.inbounds[] | select(.tag == $tag) | "\(.type) -> :\(.listen_port)"' "$SINGBOX_CONFIG")
        echo "  $i) $t  [$info]"
        tag_arr+=("$t")
        ((i++))
    done <<< "$tags"
    echo

    local num; read -r -p "  选择要修改的节点 [1-$((i-1)), 0=取消]: " num
    if [[ "$num" =~ ^[0-9]+$ ]] && (( num >= 1 && num <= ${#tag_arr[@]} )); then
        local target="${tag_arr[$((num-1))]}"
        local typ; typ=$(jq -r --arg tag "$target" '.inbounds[] | select(.tag == $tag) | .type' "$SINGBOX_CONFIG")
        print_info "节点类型: $typ"
        echo

        echo "  可修改项:"
        echo "  1) 端口"
        echo "  2) UUID/密码"
        echo "  3) WebSocket 路径"
        echo "  0) 取消"

        local ch; read -r -p "  选择: " ch
        case "$ch" in
            1)
                local new_port; new_port=$(input_port "新端口")
                local tmp; tmp=$(mktemp)
                jq --arg tag "$target" --argjson port "$new_port" \
                    '(.inbounds[] | select(.tag == $tag) | .listen_port) = $port' "$SINGBOX_CONFIG" > "$tmp"
                mv "$tmp" "$SINGBOX_CONFIG"
                if is_running; then systemctl restart sing-box; fi
                print_ok "端口已修改为 $new_port"
                ;;
            2)
                local new_val; new_val=$(input_required "新值")
                local tmp; tmp=$(mktemp)
                local pfield
                case "$typ" in
                    shadowsocks) pfield="password" ;;
                    vmess)       pfield="users[0].uuid" ;;
                    vless)       pfield="users[0].uuid" ;;
                    trojan)      pfield="users[0].password" ;;
                    hysteria2)   pfield="users[0].password" ;;
                    tuic)        pfield="users[0].uuid" ;;
                    *) print_err "不支持的协议"; return ;;
                esac
                jq --arg tag "$target" --arg val "$new_val" \
                    "(.inbounds[] | select(.tag == \$tag) | .${pfield}) = \$val" "$SINGBOX_CONFIG" > "$tmp"
                mv "$tmp" "$SINGBOX_CONFIG"
                if is_running; then systemctl restart sing-box; fi
                print_ok "已修改"
                ;;
            3)
                if [[ "$typ" =~ vmess|vless ]]; then
                    local new_path; new_path=$(input_required "新 WebSocket 路径 (以 / 开头)")
                    local tmp; tmp=$(mktemp)
                    jq --arg tag "$target" --arg path "$new_path" \
                        '(.inbounds[] | select(.tag == $tag) | .transport.path) = $path' "$SINGBOX_CONFIG" > "$tmp"
                    mv "$tmp" "$SINGBOX_CONFIG"
                    if is_running; then systemctl restart sing-box; fi
                    print_ok "路径已修改"
                else
                    print_warn "该节点不支持 WS 路径修改"
                fi
                ;;
            0) ;;
            *) print_warn "无效选择" ;;
        esac
    fi
    press_any_key
}

# ---- 查看所有节点 ----
view_all_nodes() {
    banner
    echo -e "${BOLD}所有节点${NC}"
    echo

    local count; count=$(json_count_inbounds)
    echo -e "  共 ${CYAN}${count}${NC} 个节点"
    echo
    if [[ "$count" -eq 0 ]]; then
        print_warn "还没有添加任何节点"
    else
        jq -r '.inbounds[] | "  ┌─ \(.tag)\n  │  协议: \(.type)\n  │  端口: :\(.listen_port)"' "$SINGBOX_CONFIG" 2>/dev/null
    fi

    echo
    local ip; ip=$(get_public_ip)
    echo -e "  公网 IP: ${GREEN}${ip}${NC}"

    if is_running; then
        echo -e "  服务状态: ${GREEN}运行中${NC}"
    else
        echo -e "  服务状态: ${RED}未运行${NC}"
    fi
    echo
    press_any_key
}

# ---- 查看连接信息 ----
view_connections() {
    banner
    echo -e "${BOLD}节点连接信息${NC}"
    echo

    local tags; tags=$(json_list_tags)
    if [[ -z "$tags" ]]; then
        print_warn "没有已配置的节点"
        press_any_key; return
    fi

    local ip; ip=$(get_public_ip)

    local i=1
    local tag_arr=()
    while IFS= read -r t; do
        tag_arr+=("$t")
        echo -e "  ${GREEN}$i)${NC} $t"
        ((i++))
    done <<< "$tags"

    echo
    local num; read -r -p "  选择要查看的节点 [1-$((i-1)), 0=返回]: " num
    if [[ ! "$num" =~ ^[0-9]+$ ]] || (( num < 1 || num > ${#tag_arr[@]} )); then
        return
    fi

    local target="${tag_arr[$((num-1))]}"
    local node; node=$(json_get_inbound "$target")
    local typ; typ=$(echo "$node" | jq -r '.type')
    local port; port=$(echo "$node" | jq -r '.listen_port')

    echo
    echo -e "${BOLD}节点:${NC} $target"
    echo -e "${BOLD}协议:${NC} $typ"
    echo -e "${BOLD}地址:${NC} $ip"
    echo -e "${BOLD}端口:${NC} $port"

    local link=""
    case "$typ" in
        shadowsocks)
            local method password
            method=$(echo "$node" | jq -r '.method')
            password=$(echo "$node" | jq -r '.password')
            link=$(gen_ss_link "$method" "$password" "$ip" "$port" "$target")
            ;;
        vmess)
            local uuid ws_path tls_enabled sni
            uuid=$(echo "$node" | jq -r '.users[0].uuid')
            ws_path=$(echo "$node" | jq -r '.transport.path // "/"')
            tls_enabled=$(echo "$node" | jq -r '.tls.enabled // false')
            sni=$(echo "$node" | jq -r '.tls.server_name // ""')
            link=$(gen_vmess_link "$uuid" "$ip" "$port" "ws" "$ws_path" "$tls_enabled" "$sni" "$target")
            ;;
        vless)
            local uuid ws_path tls_type sni flow pbk sid
            uuid=$(echo "$node" | jq -r '.users[0].uuid')
            tls_type=$(echo "$node" | jq -r '.tls.reality.enabled // "none"')
            [[ "$tls_type" == "true" ]] && tls_type="reality"
            [[ "$tls_type" == "false" || "$tls_type" == "null" ]] && tls_type=$(echo "$node" | jq -r '.tls.enabled // "none"')
            sni=$(echo "$node" | jq -r '.tls.server_name // ""')
            flow=$(echo "$node" | jq -r '.users[0].flow // ""')
            local priv_key; priv_key=$(echo "$node" | jq -r '.tls.reality.private_key // ""')
            pbk=""
            [[ -n "$priv_key" ]] && pbk=$(derive_pubkey "$priv_key")
            sid=$(echo "$node" | jq -r '.tls.reality.short_id[0] // ""')
            ws_path=$(echo "$node" | jq -r '.transport.path // ""')
            link=$(gen_vless_link "$uuid" "$ip" "$port" "tcp" "$ws_path" "$tls_type" "$sni" "$flow" "$pbk" "$sid" "chrome" "$target")
            ;;
        trojan)
            local password sni
            password=$(echo "$node" | jq -r '.users[0].password')
            sni=$(echo "$node" | jq -r '.tls.server_name // ""')
            link=$(gen_trojan_link "$password" "$ip" "$port" "$sni" "$target")
            ;;
        hysteria2)
            local password sni cert
            password=$(echo "$node" | jq -r '.users[0].password')
            sni=$(echo "$node" | jq -r '.tls.server_name // ""')
            if [[ -z "$sni" ]]; then
                cert=$(echo "$node" | jq -r '.tls.certificate_path // ""')
                [[ -n "$cert" && -f "$cert" ]] && sni=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | grep -oP 'CN\s*=\s*\K[^/\n]+' | head -1)
            fi
            link=$(gen_hysteria2_link "$password" "$ip" "$port" "${sni:-}" "$target")
            ;;
        tuic)
            local uuid password sni
            uuid=$(echo "$node" | jq -r '.users[0].uuid')
            password=$(echo "$node" | jq -r '.users[0].password')
            sni=$(echo "$node" | jq -r '.tls.server_name // ""')
            link=$(gen_tuic_link "$uuid" "$password" "$ip" "$port" "$sni" "$target")
            ;;
    esac

    if [[ -n "$link" ]]; then
        qr_show "$link" "$typ 分享链接"
    fi
    press_any_key
}

# ---- 服务管理 ----
service_menu() {
    while true; do
        banner
        echo -e "${BOLD}服务管理${NC}"
        echo
        local status; status=$(systemctl is-active sing-box 2>/dev/null || echo "未安装")
        if [[ "$status" == "active" ]]; then
            echo -e "  状态: ${GREEN}运行中${NC}"
        else
            echo -e "  状态: ${RED}${status}${NC}"
        fi
        echo
        echo "  1) 启动服务"
        echo "  2) 停止服务"
        echo "  3) 重启服务"
        echo "  4) 查看状态"
        echo "  5) 查看日志 (最近 50 行)"
        echo "  6) 开启自启"
        echo "  0) 返回主菜单"
        echo
        local ch; read -r -p "  请选择 [0-6]: " ch
        case "$ch" in
            1) service_ctl start ; press_any_key ;;
            2) service_ctl stop ; press_any_key ;;
            3) service_ctl restart ; press_any_key ;;
            4) service_ctl status ; press_any_key ;;
            5) service_ctl logs ; press_any_key ;;
            6) systemctl enable sing-box 2>/dev/null && print_ok "已开启自启" || print_err "开启失败" ; press_any_key ;;
            0) return ;;
            *) print_warn "无效选择" ; sleep 1 ;;
        esac
    done
}

# ---- 系统优化 ----
system_optimize() {
    banner
    echo -e "${BOLD}系统优化${NC}"
    echo
    echo "  1) 开启 BBR 加速"
    echo "  2) 查看 BBR 状态"
    echo "  3) 优化系统参数 (文件描述符/网络)"
    echo "  0) 返回"
    echo
    local ch; read -r -p "  请选择 [0-3]: " ch

    case "$ch" in
        1)
            echo
            print_info "开启 BBR..."
            echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
            echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
            sysctl -p &>/dev/null
            if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
                print_ok "BBR 已开启"
            else
                print_warn "可能需要重启才能生效"
            fi
            ;;
        2)
            echo
            sysctl net.ipv4.tcp_congestion_control 2>/dev/null
            ;;
        3)
            echo
            print_info "优化系统参数..."
            cat >> /etc/sysctl.conf << 'SYSCTL_EOF'
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 87380 33554432
net.ipv4.tcp_wmem = 4096 65536 33554432
net.ipv4.tcp_fastopen = 3
fs.file-max = 1048576
SYSCTL_EOF
            sysctl -p &>/dev/null
            ulimit -n 1048576
            print_ok "系统参数已优化"
            ;;
        0) return ;;
        *) ;;
    esac
    press_any_key
}

# ---- 卸载 ----
uninstall() {
    banner
    echo -e "${RED}${BOLD}!! 卸载 sing-box !!${NC}"
    echo
    print_warn "此操作将删除所有节点配置，不可恢复！"
    echo
    if ! confirm "确认卸载?"; then
        return
    fi
    echo
    print_info "停止服务..."
    systemctl stop sing-box 2>/dev/null || true
    systemctl disable sing-box 2>/dev/null || true
    rm -f "$SINGBOX_SERVICE"
    systemctl daemon-reload

    print_info "删除文件..."
    rm -rf "$SINGBOX_CONFIG_DIR"
    rm -f "$SINGBOX_BIN"

    print_ok "sing-box 已卸载"
    press_any_key
}

# ---- 主菜单 ----
main_menu() {
    while true; do
        banner

        # 检测状态
        local sb_installed=""
        if [[ -x "$SINGBOX_BIN" ]]; then
            sb_installed="已安装: $("$SINGBOX_BIN" version 2>/dev/null | head -1 | grep -oP '[\d]+\.[\d]+\.[\d]+' || echo '?')"
        else
            sb_installed="${RED}未安装${NC}"
        fi

        local node_count; node_count=$(json_count_inbounds)
        local running_info=""
        if systemctl is-active --quiet sing-box 2>/dev/null; then
            running_info="${GREEN}运行中${NC}"
        else
            running_info="${RED}未运行${NC}"
        fi

        echo -e "  ${BLUE}内核:${NC} $sb_installed  |  ${BLUE}节点数:${NC} $node_count  |  ${BLUE}状态:${NC} $running_info"
        echo
        echo "  ┌──── 节点管理 ──────────────────────────┐"
        echo "  │  1) 添加节点                           │"
        echo "  │  2) 删除节点                           │"
        echo "  │  3) 修改节点                           │"
        echo "  │  4) 查看所有节点                       │"
        echo "  │  5) 查看连接信息 (分享链接/二维码)      │"
        echo "  ├──── 内核 & 服务 ───────────────────────┤"
        echo "  │  6) 安装/更新 sing-box 内核            │"
        echo "  │  7) 服务管理 (启动/停止/重启/日志)      │"
        echo "  ├──── 系统 & 其他 ───────────────────────┤"
        echo "  │  8) 系统优化 (BBR)                     │"
        echo "  │  9) 卸载 sing-box                      │"
        echo "  │  0) 退出                               │"
        echo "  └────────────────────────────────────────┘"
        echo
        local choice; read -r -p "  请选择 [0-9]: " choice

        case "$choice" in
            1) add_node_menu ;;
            2) delete_node ;;
            3) modify_node_menu ;;
            4) view_all_nodes ;;
            5) view_connections ;;
            6)
                install_deps
                install_singbox
                ;;
            7) service_menu ;;
            8) system_optimize ;;
            9) uninstall ;;
            0)
                echo; echo -e "${GREEN}  再见!${NC}"; echo
                exit 0
                ;;
            *)
                print_warn "无效选择"
                sleep 1
                ;;
        esac
    done
}

# ---- 密钥推导 ----
derive_pubkey() {
    local priv="$1"
    python3 -c "
import base64, sys
try:
    from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
    priv_bytes = base64.urlsafe_b64decode(sys.argv[1] + '==')
    priv_key = X25519PrivateKey.from_private_bytes(priv_bytes)
    pub_bytes = priv_key.public_key().public_bytes(Encoding.Raw, PublicFormat.Raw)
    print(base64.urlsafe_b64encode(pub_bytes).decode().rstrip('='))
except Exception as e:
    print('', file=sys.stderr)
" "$priv" 2>/dev/null
}

# ---- 批量操作 ----
show_all_links() {
    local ip; ip=$(get_public_ip)
    echo
    echo -e "${BOLD}══════ 所有节点分享链接 (v2rayN / sing-box 通用) ══════${NC}"
    echo
    local tags; tags=$(json_list_tags)
    if [[ -z "$tags" ]]; then
        print_warn "没有已配置的节点"
        return
    fi
    while IFS= read -r t; do
        local node typ port link
        node=$(json_get_inbound "$t")
        typ=$(echo "$node" | jq -r '.type')
        port=$(echo "$node" | jq -r '.listen_port')
        link=""
        case "$typ" in
            shadowsocks)
                local m; m=$(echo "$node" | jq -r '.method')
                local pw; pw=$(echo "$node" | jq -r '.password')
                link=$(gen_ss_link "$m" "$pw" "$ip" "$port" "$t")
                ;;
            vmess)
                local u; u=$(echo "$node" | jq -r '.users[0].uuid')
                local wp; wp=$(echo "$node" | jq -r '.transport.path // "/"')
                local tl; tl=$(echo "$node" | jq -r '.tls.enabled // false')
                local sn; sn=$(echo "$node" | jq -r '.tls.server_name // ""')
                link=$(gen_vmess_link "$u" "$ip" "$port" "ws" "$wp" "$tl" "$sn" "$t")
                ;;
            vless)
                local u; u=$(echo "$node" | jq -r '.users[0].uuid')
                local fl; fl=$(echo "$node" | jq -r '.users[0].flow // ""')
                local wp; wp=$(echo "$node" | jq -r '.transport.path // ""')
                local tl; tl=$(echo "$node" | jq -r 'if .tls.reality.enabled then "reality" elif .tls.enabled then "tls" else "none" end')
                local sn; sn=$(echo "$node" | jq -r '.tls.server_name // ""')
                local priv_key; priv_key=$(echo "$node" | jq -r '.tls.reality.private_key // ""')
                local pbk=""
                if [[ -n "$priv_key" ]]; then
                    pbk=$(derive_pubkey "$priv_key")
                fi
                local sid; sid=$(echo "$node" | jq -r '.tls.reality.short_id[0] // ""')
                local fp="chrome"
                link=$(gen_vless_link "$u" "$ip" "$port" "tcp" "$wp" "$tl" "$sn" "$fl" "$pbk" "$sid" "$fp" "$t")
                ;;
            trojan)
                local pw; pw=$(echo "$node" | jq -r '.users[0].password')
                local sn; sn=$(echo "$node" | jq -r '.tls.server_name // ""')
                link=$(gen_trojan_link "$pw" "$ip" "$port" "$sn" "$t")
                ;;
            hysteria2)
                local pw; pw=$(echo "$node" | jq -r '.users[0].password')
                local sn; sn=$(echo "$node" | jq -r '.tls.server_name // ""')
                # 如果配置里没有 server_name，尝试从证书读取 CN
                if [[ -z "$sn" ]]; then
                    local cert; cert=$(echo "$node" | jq -r '.tls.certificate_path // ""')
                    if [[ -n "$cert" && -f "$cert" ]]; then
                        sn=$(openssl x509 -in "$cert" -noout -subject 2>/dev/null | grep -oP 'CN\s*=\s*\K[^/\n]+' | head -1)
                    fi
                fi
                link=$(gen_hysteria2_link "$pw" "$ip" "$port" "${sn:-}" "$t")
                ;;
            tuic)
                local u; u=$(echo "$node" | jq -r '.users[0].uuid')
                local pw; pw=$(echo "$node" | jq -r '.users[0].password')
                local sn; sn=$(echo "$node" | jq -r '.tls.server_name // ""')
                link=$(gen_tuic_link "$u" "$pw" "$ip" "$port" "$sn" "$t")
                ;;
        esac
        echo -e "${GREEN}${t}${NC}  [${typ}]  :${port}"
        echo "  $link"
        echo
    done <<< "$tags"
    echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
}

close_port() {
    local port="$1"
    echo
    print_info "检查端口 $port ..."
    local pids; pids=$(ss -tlnp | grep ":$port " | grep -oP 'pid=\K[0-9]+' | sort -u)
    if [[ -z "$pids" ]]; then
        print_ok "端口 $port 未被占用"
    else
        for pid in $pids; do
            print_warn "关闭端口 $port (PID: $pid)"
            kill "$pid" 2>/dev/null || true
        done
        print_ok "端口 $port 已关闭"
    fi
}

purge_config() {
    echo
    if [[ -f "$SINGBOX_CONFIG" ]]; then
        print_warn "备份旧配置到 ${SINGBOX_CONFIG}.bak ..."
        cp "$SINGBOX_CONFIG" "${SINGBOX_CONFIG}.bak"
        cat > "$SINGBOX_CONFIG" << 'CONFIG_EOF'
{
  "log": { "level": "info" },
  "inbounds": [],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
CONFIG_EOF
        print_ok "配置已清空，备份保留在 ${SINGBOX_CONFIG}.bak"
    else
        print_info "没有旧配置文件"
    fi
}

# ---- 命令行快速添加节点 ----
cmd_add_reality() {
    local port="${1:-443}"
    local dest="${2:-www.microsoft.com:443}"
    local uuid="${3:-}"
    [[ -z "$uuid" ]] && uuid=$("$SINGBOX_BIN" generate uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
    local tag; tag="vless-reality-$(date +%s)"
    local server_name="${dest%:*}"
    local dest_port="${dest##*:}"
    local short_id; short_id=$(head -c 4 /dev/urandom | od -A n -t x1 | tr -d ' \n')
    local keys; keys=$("$SINGBOX_BIN" generate reality-keypair 2>/dev/null)
    local priv_key; priv_key=$(echo "$keys" | grep -oP 'PrivateKey:\s*\K\S+')
    local pub_key; pub_key=$(echo "$keys" | grep -oP 'PublicKey:\s*\K\S+' | head -1)

    if [[ -z "$priv_key" ]]; then
        print_err "REALITY 密钥生成失败"
        exit 1
    fi

    print_info "添加 VLESS+REALITY 端口 $port dest=$dest ..."

    local inbound_json
    inbound_json=$(jq -n \
        --arg type "vless" --arg tag "$tag" --arg listen "::" \
        --arg port "$port" --arg uuid "$uuid" --arg flow "xtls-rprx-vision" \
        --arg server "$server_name" --arg dest_port "$dest_port" --arg sni "$server_name" \
        --arg short_id "$short_id" --arg priv_key "$priv_key" \
        '{
            type: $type, tag: $tag, listen: $listen, listen_port: ($port|tonumber),
            users: [{ uuid: $uuid, flow: $flow }],
            tls: {
                enabled: true, server_name: $sni,
                reality: {
                    enabled: true,
                    handshake: { server: $server, server_port: ($dest_port|tonumber) },
                    private_key: $priv_key, short_id: [$short_id]
                }
            }
        }')
    json_add_inbound "$inbound_json"

    if ! "$SINGBOX_BIN" check -c "$SINGBOX_CONFIG" &>/dev/null; then
        print_err "配置验证失败，回滚"
        json_delete_inbound "$tag"
        exit 1
    fi

    systemctl restart sing-box 2>/dev/null || systemctl start sing-box 2>/dev/null
    print_ok "节点 <$tag> 添加完成"
    echo
    local ip; ip=$(get_public_ip)
    local link; link=$(gen_vless_link "$uuid" "$ip" "$port" "tcp" "" "reality" "$server_name" "xtls-rprx-vision" "$pub_key" "$short_id" "chrome" "$tag")
    qr_show "$link" "VLESS+REALITY"
}

cmd_add_hysteria2() {
    local port="${1:-50319}"
    local password="${2:-}"
    local cert_dir="${3:-}"
    [[ -z "$password" ]] && password=$(head -c 24 /dev/urandom | base64 | tr -d '=+/')
    local tag; tag="hysteria2-$(date +%s)"

    # 检测证书
    local cert_path="" key_path="" sni=""
    if [[ -n "$cert_dir" ]]; then
        cert_path="$cert_dir/fullchain.pem"
        key_path="$cert_dir/privkey.pem"
    elif [[ -f /etc/s-box/cert.pem && -f /etc/s-box/private.key ]]; then
        cert_path="/etc/s-box/cert.pem"
        key_path="/etc/s-box/private.key"
        sni=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | grep -oP 'CN\s*=\s*\K[^/\n]+' | head -1)
    elif [[ -f /etc/sing-box/certs/hy2.crt && -f /etc/sing-box/certs/hy2.key ]]; then
        cert_path="/etc/sing-box/certs/hy2.crt"
        key_path="/etc/sing-box/certs/hy2.key"
    fi

    print_info "添加 Hysteria2 端口 $port ..."

    local inbound_json
    if [[ -n "$cert_path" && -f "$cert_path" ]]; then
        inbound_json=$(jq -n \
            --arg type "hysteria2" --arg tag "$tag" --arg listen "::" \
            --arg port "$port" --arg password "$password" \
            --arg cert "$cert_path" --arg key "$key_path" --arg sni "${sni:-}" \
            '{
                type: $type, tag: $tag, listen: $listen, listen_port: ($port|tonumber),
                users: [{ password: $password }],
                tls: { enabled: true, alpn: ["h3"], certificate_path: $cert, key_path: $key }
            }')
    else
        # 无证书模式 - 自签
        mkdir -p /etc/sing-box/certs
        openssl req -x509 -newkey rsa:2048 -keyout /etc/sing-box/certs/hy2.key -out /etc/sing-box/certs/hy2.crt -days 3650 -nodes -subj '/CN=sing-box' 2>/dev/null
        cert_path="/etc/sing-box/certs/hy2.crt"
        key_path="/etc/sing-box/certs/hy2.key"
        sni="sing-box"
        inbound_json=$(jq -n \
            --arg type "hysteria2" --arg tag "$tag" --arg listen "::" \
            --arg port "$port" --arg password "$password" \
            --arg cert "$cert_path" --arg key "$key_path" \
            '{
                type: $type, tag: $tag, listen: $listen, listen_port: ($port|tonumber),
                users: [{ password: $password }],
                tls: { enabled: true, alpn: ["h3"], certificate_path: $cert, key_path: $key }
            }')
    fi

    json_add_inbound "$inbound_json"

    if ! "$SINGBOX_BIN" check -c "$SINGBOX_CONFIG" &>/dev/null; then
        print_err "配置验证失败，回滚"
        json_delete_inbound "$tag"
        exit 1
    fi

    systemctl restart sing-box 2>/dev/null || systemctl start sing-box 2>/dev/null
    print_ok "节点 <$tag> 添加完成"
    echo
    local ip; ip=$(get_public_ip)
    local insecure="0"
    [[ "$sni" == "sing-box" ]] && insecure="1"
    local link; link=$(gen_hysteria2_link "$password" "$ip" "$port" "${sni:-}" "$tag" | sed "s/insecure=0/insecure=$insecure/")
    qr_show "$link" "Hysteria2"
}

# ---- 入口 ----
main() {
    # 检查 root
    if [[ "$EUID" -ne 0 ]]; then
        echo "请以 root 权限运行: sudo bash $0"
        exit 1
    fi

    # 检查依赖
    if ! command -v jq &>/dev/null; then
        echo
        print_info "首次运行，安装依赖..."
        install_deps
    fi

    # 命令行参数
    case "${1:-}" in
        --links)
            show_all_links
            exit 0
            ;;
        --close-port)
            close_port "${2:-0}"
            exit 0
            ;;
        --purge)
            purge_config
            exit 0
            ;;
        --add-reality)
            cmd_add_reality "${2:-443}" "${3:-}" "${4:-}"
            exit 0
            ;;
        --add-hysteria2)
            cmd_add_hysteria2 "${2:-50319}" "${3:-}" "${4:-}"
            exit 0
            ;;
        --help|-h)
            echo "用法: sudo bash $0 [选项]"
            echo "  (无参数)            进入交互式管理面板"
            echo "  --links             导出所有节点的分享链接"
            echo "  --close-port N      关闭指定端口"
            echo "  --purge             清空配置 (备份到 .bak)"
            echo "  --add-reality PORT [DEST] [UUID]     快速添加 VLESS+REALITY"
            echo "  --add-hysteria2 PORT [PASSWORD] [CERT_DIR]  快速添加 Hysteria2"
            echo "  --help              显示此帮助"
            exit 0
            ;;
    esac

    # 建立快捷命令 (如果脚本路径变了则更新)
    if [[ ! -f /usr/local/bin/sb ]] || ! grep -q "$(readlink -f "$0")" /usr/local/bin/sb 2>/dev/null; then
        setup_alias 2>/dev/null || true
    fi

    # 初始化 config (如果已安装但配置丢失)
    if [[ -x "$SINGBOX_BIN" ]] && [[ ! -f "$SINGBOX_CONFIG" ]]; then
        mkdir -p "$SINGBOX_CONFIG_DIR"
        cat > "$SINGBOX_CONFIG" << 'CONFIG_EOF'
{
  "log": { "level": "info" },
  "inbounds": [],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
CONFIG_EOF
    fi

    main_menu
}

main "$@"
