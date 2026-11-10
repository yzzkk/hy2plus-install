#!/usr/bin/env bash
set -euo pipefail
umask 077

repo=yzzkk/hy2plus-install
version=v0.1.0
config_dir=/etc/hy2plus
service=hy2plus
admin=()
if (( EUID != 0 )); then admin=(sudo); fi

require_commands() {
  for cmd in "$@"; do
    command -v "$cmd" >/dev/null || { printf '缺少命令：%s\n' "$cmd" >&2; return 1; }
  done
}

start_service() {
  if ! "${admin[@]}" systemctl enable --now "$service"; then
    "${admin[@]}" journalctl -u "$service" -n 30 --no-pager
    return 1
  fi
  sleep 2
  if ! systemctl is-active --quiet "$service"; then
    "${admin[@]}" journalctl -u "$service" -n 30 --no-pager
    return 1
  fi
  printf 'HY2 服务已启动。\n'
}

wait_for_listener() {
  local port=$1 attempt pid sockets
  for ((attempt=0; attempt<90; attempt++)); do
    if ! systemctl is-active --quiet "$service"; then break; fi
    pid=$(systemctl show -p MainPID --value "$service")
    sockets=$("${admin[@]}" ss -H -lunp "sport = :$port")
    if [[ $pid != 0 && $sockets == *"pid=$pid,"* ]]; then return 0; fi
    sleep 2
  done
  printf '服务未在 UDP %s 就绪，请检查签发或启动日志。\n' "$port" >&2
  "${admin[@]}" journalctl -u "$service" -n 30 --no-pager
  return 1
}

install_server() (
  mode=$1
  require_commands curl sha256sum openssl systemctl install grep ss
  if (( EUID != 0 )); then require_commands sudo; sudo -v; fi
  if "${admin[@]}" test -e "$config_dir/config.yaml"; then
    printf '已有配置。启动现有服务可选择 2。\n' >&2
    exit 1
  fi

  read -rp 'VPS 域名：' domain
  [[ $domain =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9]+$ ]] ||
    { printf '域名格式无效。\n' >&2; exit 1; }
  read -rp 'UDP 端口 [4443]：' port
  port=${port:-4443}
  if [[ ! $port =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1024 || 10#$port > 65535 )); then
    printf '请输入 1024 至 65535 之间的端口。\n' >&2
    exit 1
  fi
  port=$((10#$port))
  read -rp '证书方式 [1=自动签发并续期 / 2=使用已有证书，默认 1]：' cert_mode
  cert_mode=${cert_mode:-1}
  case "$cert_mode" in
    1)
      if [[ -n $(ss -H -ltn 'sport = :80') ]]; then
        printf 'TCP 80 已有服务监听。请选择已有证书，或释放 TCP 80 后重试。\n' >&2
        exit 1
      fi
      printf '自动签发需要域名解析到本机，且公网 TCP 80 可访问。\n'
      ;;
    2)
    read -rp '完整证书 fullchain.pem 的绝对路径：' cert
    read -rp '私钥 privkey.pem 的绝对路径：' cert_key
    [[ $cert = /* && $cert_key = /* ]] ||
      { printf '请填写证书和私钥的绝对路径。\n' >&2; exit 1; }
  
    cert_pub=$("${admin[@]}" openssl x509 -in "$cert" -noout -pubkey)
    key_pub=$("${admin[@]}" openssl pkey -in "$cert_key" -passin pass: -pubout)
    [[ $cert_pub == "$key_pub" ]] ||
      { printf '证书与私钥不匹配。\n' >&2; exit 1; }
    "${admin[@]}" openssl x509 -in "$cert" -noout -checkend 0
    if ! "${admin[@]}" openssl x509 -in "$cert" -noout -checkhost "$domain" |
        grep -Fqx "Hostname $domain does match certificate"; then
      printf '证书与域名不匹配。\n' >&2
      exit 1
    fi
      ;;
    *) printf '无效的证书方式。\n' >&2; exit 2 ;;
  esac

  case "$(uname -s)/$(uname -m)" in
    Linux/x86_64)
      asset=hy2plus-linux-amd64
      checksum=b14c847e8594a071ffd192909a5f6a5c124407fec0c4c726882d88dcfe5ebcd0
      ;;
    Linux/aarch64)
      asset=hy2plus-linux-arm64
      checksum=56f8ddd03f8797a0b1d8945b0febb23f55d36e252a26e59dcc56fa238a5972f6
      ;;
    *) printf '此安装器支持 Linux x86_64 和 aarch64。\n' >&2; exit 1 ;;
  esac

  tmp=$(mktemp -d)
  trap 'rm -f -- "$tmp/$asset" "$tmp/config.yaml" "$tmp/client.yaml" "$tmp/client-uri.txt" "$tmp/hy2plus.service"; rmdir -- "$tmp"' EXIT
  curl -q -fsSL --retry 3 --proto '=https' --proto-redir '=https' \
    "https://github.com/$repo/releases/download/$version/$asset" -o "$tmp/$asset"
  printf '%s  %s\n' "$checksum" "$tmp/$asset" | sha256sum --check -

  {
  cat <<'UNIT'
[Unit]
Description=HY2 / HY2+ server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
DynamicUser=yes
NoNewPrivileges=yes
LoadCredential=config.yaml:/etc/hy2plus/config.yaml
UNIT
  if [[ $cert_mode == 1 ]]; then
    cat <<'UNIT'
StateDirectory=hy2plus
StateDirectoryMode=0700
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
UNIT
  else
    cat <<'UNIT'
LoadCredential=fullchain.pem:/etc/hy2plus/fullchain.pem
LoadCredential=privkey.pem:/etc/hy2plus/privkey.pem
UNIT
  fi
  cat <<'UNIT'
ExecStart=/usr/local/bin/hy2plus server -c %d/config.yaml
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
UNIT
  } > "$tmp/hy2plus.service"

  "${admin[@]}" install -d -m 0700 "$config_dir"
  "${admin[@]}" install -m 0755 "$tmp/$asset" /usr/local/bin/hy2plus
  "${admin[@]}" install -m 0644 "$tmp/hy2plus.service" /etc/systemd/system/hy2plus.service
  "${admin[@]}" systemctl daemon-reload

  proxy_password=$(openssl rand -hex 24)
  cat > "$tmp/config.yaml" <<EOF
listen: ":$port"
auth:
  type: password
  password: "$proxy_password"
EOF
  if [[ $cert_mode == 1 ]]; then
    cat >> "$tmp/config.yaml" <<EOF
acme:
  domains:
    - "$domain"
  ca: letsencrypt
  type: http
  dir: /var/lib/hy2plus/acme
EOF
  else
    cat >> "$tmp/config.yaml" <<'EOF'
tls:
  cert: /run/credentials/hy2plus.service/fullchain.pem
  key: /run/credentials/hy2plus.service/privkey.pem
EOF
  fi

  if [[ $mode == private ]]; then
    shared_key=$(openssl rand -hex 32)
    cat >> "$tmp/config.yaml" <<EOF
obfs:
  type: private-v1
  privateKey: "$shared_key"
quic:
  disablePathMTUDiscovery: true
EOF
    cat > "$tmp/client.yaml" <<EOF
server: "$domain:$port"
auth: "$proxy_password"
tls:
  sni: "$domain"
obfs:
  type: private-v1
  privateKey: "$shared_key"
quic:
  disablePathMTUDiscovery: true
socks5:
  listen: "127.0.0.1:1080"
EOF
  else
    obfs_password=$(openssl rand -hex 24)
    cat >> "$tmp/config.yaml" <<EOF
obfs:
  type: salamander
  salamander:
    password: "$obfs_password"
EOF
    printf 'hysteria2://%s@%s:%s/?insecure=0&sni=%s&alpn=h3&obfs=salamander&obfs-password=%s#hy2\n' \
      "$proxy_password" "$domain" "$port" "$domain" "$obfs_password" > "$tmp/client-uri.txt"
  fi

  if [[ $cert_mode == 2 ]]; then
    "${admin[@]}" install -m 0600 "$cert" "$config_dir/fullchain.pem"
    "${admin[@]}" install -m 0600 "$cert_key" "$config_dir/privkey.pem"
  fi
  if [[ $mode == private ]]; then
    "${admin[@]}" install -m 0600 "$tmp/client.yaml" "$config_dir/client.yaml"
  else
    "${admin[@]}" install -m 0600 "$tmp/client-uri.txt" "$config_dir/client-uri.txt"
  fi
  "${admin[@]}" install -m 0600 "$tmp/config.yaml" "$config_dir/config.yaml"
  start_service
  wait_for_listener "$port"
  printf '请在 VPS 防火墙和云安全组放行 UDP %s。\n' "$port"
  if [[ $mode == private ]]; then
    printf '客户端配置保存在 %s/client.yaml，可通过菜单 5 查看。\n' "$config_dir"
  else
    printf '\n复制下面的链接到支持 HY2 链接导入的客户端。\n'
    cat "$tmp/client-uri.txt"
  fi
)

show_domain_alias() {
  require_commands openssl grep
  local uri domain auth port suffix pattern
  if ! "${admin[@]}" test -r "$config_dir/client-uri.txt"; then
    printf '此选项需要菜单 1 安装生成的 HY2 导入链接。\n' >&2
    return 1
  fi
  read -rp '备用域名（需要解析到同一台 VPS）：' domain
  if [[ ! $domain =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9]+$ ]]; then
    printf '域名格式无效。\n' >&2
    return 1
  fi
  if ! "${admin[@]}" openssl x509 -in "$config_dir/fullchain.pem" -noout -checkhost "$domain" |
      grep -Fqx "Hostname $domain does match certificate"; then
    printf '备用域名需要手动部署的证书，且证书必须覆盖该域名。\n' >&2
    return 1
  fi
  uri=$("${admin[@]}" cat "$config_dir/client-uri.txt")
  pattern='^hysteria2://([0-9a-f]+)@[A-Za-z0-9.-]+:([0-9]+)/\?insecure=0&sni=[A-Za-z0-9.-]+([&#].*)?$'
  if [[ ! $uri =~ $pattern ]]; then
    printf '现有链接格式不符合本安装器的导出格式。\n' >&2
    return 1
  fi
  auth=${BASH_REMATCH[1]}
  port=${BASH_REMATCH[2]}
  suffix=${BASH_REMATCH[3]:-}
  printf 'hysteria2://%s@%s:%s/?insecure=0&sni=%s%s\n' "$auth" "$domain" "$port" "$domain" "$suffix"
}

printf '\nHY2+ VPS 管理菜单\n'
printf '%s\n' '1) 安装 HY2 + Salamander（输出可导入链接）' '2) 启用并启动已有服务' \
  '3) 查看服务状态' '4) 查看最近日志' '5) 显示导入链接或客户端配置' '6) 安装 HY2+ private-v1' \
  '7) 生成备用域名导入链接' '0) 退出'
read -rp '请选择 [1]：' choice
case "${choice:-1}" in
  1) install_server standard ;;
  2) start_service ;;
  3) systemctl status "$service" --no-pager ;;
  4) "${admin[@]}" journalctl -u "$service" -n 50 --no-pager ;;
  5)
    if "${admin[@]}" test -f "$config_dir/client-uri.txt"; then
      "${admin[@]}" cat "$config_dir/client-uri.txt"
    else
      "${admin[@]}" cat "$config_dir/client.yaml"
    fi
    ;;
  6) install_server private ;;
  7) show_domain_alias ;;
  0) exit 0 ;;
  *) printf '无效选项。\n' >&2; exit 2 ;;
esac
