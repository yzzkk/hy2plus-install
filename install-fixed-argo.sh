#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

config_dir=/etc/hy2plus-argo
origin_unit=hy2plus-argo-xray.service
tunnel_unit=hy2plus-argo-cloudflared.service
unit_dir=/etc/systemd/system

if [[ $(uname -s) != Linux || $EUID != 0 ]]; then
  printf '请在使用 systemd 的 Linux VPS 上以 root 运行。\n' >&2
  exit 1
fi

if [[ ${1:-} == show ]]; then
  cat "$config_dir/client-uri.txt"
  exit
fi
if (( $# != 0 )); then
  printf '用法：bash install-fixed-argo.sh [show]\n' >&2
  exit 2
fi

for tool in xray cloudflared systemctl flock ss openssl install mktemp curl; do
  if ! command -v "$tool" >/dev/null; then
    printf '缺少命令：%s。请先安装后再运行。\n' "$tool" >&2
    exit 1
  fi
done
xray_bin=$(type -P xray)
cloudflared_bin=$(type -P cloudflared)
if [[ ! $xray_bin =~ ^/[A-Za-z0-9/_.-]+$ || ! $cloudflared_bin =~ ^/[A-Za-z0-9/_.-]+$ ]]; then
  printf '无法确认 Xray 或 cloudflared 的可执行文件路径。\n' >&2
  exit 1
fi
tunnel_help=$("$cloudflared_bin" tunnel run --help)
if [[ $tunnel_help != *--token-file* ]]; then
  printf '当前 cloudflared 需要升级到支持 --token-file 的版本。\n' >&2
  exit 1
fi
systemctl show -p Version --value >/dev/null

exec 9>/run/lock/hy2plus-argo.lock
if ! flock -n 9; then
  printf '已有固定 Argo 安装任务正在运行。\n' >&2
  exit 1
fi
for path in "$config_dir" "$unit_dir/$origin_unit" "$unit_dir/$tunnel_unit"; do
  if [[ -e $path || -L $path ]]; then
    printf '已有安装文件 %s。可以用 show 查看已生成的链接。\n' "$path" >&2
    exit 1
  fi
done

read -rp 'Cloudflare 隧道的固定子域名：' hostname
if [[ ! $hostname =~ ^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ || ${#hostname} -gt 253 ]]; then
  printf '域名格式无效。\n' >&2
  exit 2
fi
read -rp 'VPS 本机回源端口 [18080]：' port
port=${port:-18080}
if [[ ! $port =~ ^[0-9]{1,5}$ ]] || (( 10#$port < 1024 || 10#$port > 65535 )); then
  printf '请输入 1024 至 65535 之间的端口。\n' >&2
  exit 2
fi
port=$((10#$port))
if [[ -n $(ss -H -ltn "sport = :$port") ]]; then
  printf 'TCP %s 已被占用。\n' "$port" >&2
  exit 1
fi
printf '请在 Cloudflare 将 %s 的公开主机名路由指向 http://127.0.0.1:%s。\n' "$hostname" "$port"
IFS= read -rsp '粘贴该命名隧道的令牌后按回车：' tunnel_token
printf '\n'
if [[ ! $tunnel_token =~ ^[A-Za-z0-9_+/=-]+$ ]]; then
  printf '令牌格式无效。请粘贴令牌本身。\n' >&2
  exit 2
fi

uuid=$("$xray_bin" uuid)
if [[ ! $uuid =~ ^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$ ]]; then
  printf 'Xray 未返回有效的 UUID。\n' >&2
  exit 1
fi
ws_path="/$(openssl rand -hex 16)"
stage=$(mktemp -d)
applying=0

cleanup() {
  local status=$?
  trap - EXIT INT TERM HUP
  if (( applying )); then
    systemctl disable --now "$tunnel_unit" "$origin_unit" >&2 || true
    for path in "$unit_dir/$origin_unit" "$unit_dir/$tunnel_unit" \
        "$config_dir/xray.json" "$config_dir/token" "$config_dir/client-uri.txt"; do
      if [[ -f $path ]]; then unlink "$path" || true; fi
    done
    rmdir "$config_dir" 2>/dev/null || true
    systemctl daemon-reload || true
  fi
  for path in "$stage/xray.json" "$stage/token" "$stage/client-uri.txt" \
      "$stage/$origin_unit" "$stage/$tunnel_unit"; do
    if [[ -f $path ]]; then unlink "$path" || true; fi
  done
  rmdir "$stage" || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

printf '%s\n' "$tunnel_token" > "$stage/token"
unset tunnel_token
cat > "$stage/xray.json" <<EOF
{
  "log": {"loglevel": "warning"},
  "inbounds": [{
    "listen": "127.0.0.1",
    "port": $port,
    "protocol": "vless",
    "settings": {"clients": [{"id": "$uuid"}], "decryption": "none"},
    "streamSettings": {
      "network": "ws",
      "security": "none",
      "wsSettings": {"path": "$ws_path"}
    }
  }],
  "outbounds": [{"protocol": "freedom"}]
}
EOF
"$xray_bin" run -test -config "$stage/xray.json"
printf 'vless://%s@%s:443?encryption=none&security=tls&sni=%s&type=ws&host=%s&path=%%2F%s#Fixed-Argo\n' \
  "$uuid" "$hostname" "$hostname" "$hostname" "${ws_path#/}" > "$stage/client-uri.txt"

cat > "$stage/$origin_unit" <<EOF
[Unit]
Description=Fixed Argo Xray WebSocket origin
After=network.target

[Service]
DynamicUser=yes
LoadCredential=xray.json:$config_dir/xray.json
ExecStart=$xray_bin run -config %d/xray.json
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
cat > "$stage/$tunnel_unit" <<EOF
[Unit]
Description=Fixed Argo named Cloudflare Tunnel
Wants=network-online.target
Requires=$origin_unit
After=network-online.target $origin_unit

[Service]
Type=notify
DynamicUser=yes
LoadCredential=tunnel-token:$config_dir/token
ExecStart=$cloudflared_bin tunnel --no-autoupdate run --token-file %d/tunnel-token
Restart=on-failure
TimeoutStartSec=30s

[Install]
WantedBy=multi-user.target
EOF

applying=1
install -d -m 0700 "$config_dir"
install -m 0600 "$stage/xray.json" "$stage/token" "$stage/client-uri.txt" "$config_dir/"
install -m 0644 "$stage/$origin_unit" "$stage/$tunnel_unit" "$unit_dir/"
systemctl daemon-reload
systemctl enable --now "$tunnel_unit"
systemctl is-active --quiet "$origin_unit"
systemctl is-active --quiet "$tunnel_unit"
applying=0

status=$(curl -q -s --http1.1 --max-time 5 -o /dev/null -w '%{http_code}' \
  -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
  -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
  "https://$hostname$ws_path" || true)
if [[ $status == 101 ]]; then
  printf '公网 WebSocket 握手通过。\n'
else
  printf '隧道服务已启动。公网握手返回 %s，请核对 Cloudflare 路由后再测试。\n' "${status:-未知}" >&2
fi
printf '导入 SMBox 的节点链接：\n'
cat "$config_dir/client-uri.txt"
