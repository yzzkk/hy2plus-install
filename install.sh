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
  printf 'HY2+ 服务已启动，客户端连接需要放行 UDP 4443。\n'
}

install_server() (
  require_commands curl sha256sum openssl systemctl install grep
  if (( EUID != 0 )); then require_commands sudo; sudo -v; fi
  if "${admin[@]}" test -e "$config_dir/config.yaml"; then
    printf '已有配置。启动现有服务可选择 2。\n' >&2
    exit 1
  fi

  read -rp 'VPS 域名：' domain
  [[ $domain =~ ^[A-Za-z0-9][A-Za-z0-9.-]*\.[A-Za-z0-9]+$ ]] ||
    { printf '域名格式无效。\n' >&2; exit 1; }
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
  trap 'rm -f -- "$tmp/$asset" "$tmp/config.yaml" "$tmp/client.yaml" "$tmp/hy2plus.service"; rmdir -- "$tmp"' EXIT
  curl -q -fsSL --retry 3 --proto '=https' --proto-redir '=https' \
    "https://github.com/$repo/releases/download/$version/$asset" -o "$tmp/$asset"
  printf '%s  %s\n' "$checksum" "$tmp/$asset" | sha256sum --check -

  cat > "$tmp/hy2plus.service" <<'UNIT'
[Unit]
Description=HY2+ private-v1 server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
DynamicUser=yes
NoNewPrivileges=yes
LoadCredential=config.yaml:/etc/hy2plus/config.yaml
LoadCredential=fullchain.pem:/etc/hy2plus/fullchain.pem
LoadCredential=privkey.pem:/etc/hy2plus/privkey.pem
ExecStart=/usr/local/bin/hy2plus server -c %d/config.yaml
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
UNIT

  "${admin[@]}" install -d -m 0700 "$config_dir"
  "${admin[@]}" install -m 0755 "$tmp/$asset" /usr/local/bin/hy2plus
  "${admin[@]}" install -m 0644 "$tmp/hy2plus.service" /etc/systemd/system/hy2plus.service
  "${admin[@]}" systemctl daemon-reload

  shared_key=$(openssl rand -hex 32)
  proxy_password=$(openssl rand -hex 24)
  cat > "$tmp/config.yaml" <<EOF
listen: ":4443"
tls:
  cert: /run/credentials/hy2plus.service/fullchain.pem
  key: /run/credentials/hy2plus.service/privkey.pem
auth:
  type: password
  password: "$proxy_password"
obfs:
  type: private-v1
  privateKey: "$shared_key"
quic:
  disablePathMTUDiscovery: true
EOF
  cat > "$tmp/client.yaml" <<EOF
server: "$domain:4443"
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

  "${admin[@]}" install -m 0600 "$cert" "$config_dir/fullchain.pem"
  "${admin[@]}" install -m 0600 "$cert_key" "$config_dir/privkey.pem"
  "${admin[@]}" install -m 0600 "$tmp/client.yaml" "$config_dir/client.yaml"
  "${admin[@]}" install -m 0600 "$tmp/config.yaml" "$config_dir/config.yaml"
  printf '客户端配置保存在 %s/client.yaml，可通过菜单 5 查看。\n' "$config_dir"
  start_service
)

printf '\nHY2+ VPS 管理菜单\n'
printf '%s\n' '1) 安装、生成配置并启动' '2) 启用并启动已有服务' \
  '3) 查看服务状态' '4) 查看最近日志' '5) 显示客户端配置（含密钥）' '0) 退出'
read -rp '请选择 [1]：' choice
case "${choice:-1}" in
  1) install_server ;;
  2) start_service ;;
  3) systemctl status "$service" --no-pager ;;
  4) "${admin[@]}" journalctl -u "$service" -n 50 --no-pager ;;
  5) "${admin[@]}" cat "$config_dir/client.yaml" ;;
  0) exit 0 ;;
  *) printf '无效选项。\n' >&2; exit 2 ;;
esac
