#!/usr/bin/env bash
set -euo pipefail
umask 077

repo=yzzkk/hy2plus-install
version=v0.1.0
config_dir=/etc/hy2plus
service=hy2plus
admin=()
if (( EUID != 0 )); then admin=(sudo); fi

write_private_client_config() {
  cat <<EOF
server: "$1"
auth: "$2"
tls:
  sni: "$3"
obfs:
  type: private-v1
  privateKey: "$4"
quic:
  disablePathMTUDiscovery: true
socks5:
  listen: "127.0.0.1:1080"
EOF
}

show_private_link() {
  local config=$1 address auth sni key
  local address_pattern='^server: "([A-Za-z0-9.-]+:[0-9]{1,5})"$'
  local auth_pattern='^auth: "([0-9a-f]{48})"$'
  local sni_pattern='^  sni: "([A-Za-z0-9.-]+)"$'
  local key_pattern='^  privateKey: "([0-9a-f]{64})"$'
  local line
  while IFS= read -r line; do
    if [[ $line =~ $address_pattern ]]; then address=${BASH_REMATCH[1]}; fi
    if [[ $line =~ $auth_pattern ]]; then auth=${BASH_REMATCH[1]}; fi
    if [[ $line =~ $sni_pattern ]]; then sni=${BASH_REMATCH[1]}; fi
    if [[ $line =~ $key_pattern ]]; then key=${BASH_REMATCH[1]}; fi
  done <<< "$config"
  if [[ -z ${address:-} || -z ${auth:-} || -z ${sni:-} || -z ${key:-} ]]; then
    printf '无法从现有客户端配置生成 private-v1 链接。\n' >&2
    return 1
  fi
  printf 'private-v1 分享链接（使用本脚本的 import-private 导入）：\n'
  printf 'hysteria2://%s@%s/?insecure=0&sni=%s&alpn=h3&obfs=private-v1&obfs-password=%s#hy2plus\n' \
    "$auth" "$address" "$sni" "$key"
}

import_private_link() (
  local uri port
  local pattern='^hysteria2://([0-9a-f]{48})@([A-Za-z0-9.-]+):([0-9]{1,5})/\?insecure=0&sni=([A-Za-z0-9.-]+)&alpn=h3&obfs=private-v1&obfs-password=([0-9a-f]{64})#hy2plus$'
  if [[ $# -ne 1 || -z $1 ]]; then
    printf '用法：bash install.sh import-private client.yaml\n' >&2
    exit 2
  fi
  IFS= read -rsp '粘贴 private-v1 链接后按回车：' uri
  if [[ -t 0 ]]; then printf '\n' >&2; fi
  if [[ ! $uri =~ $pattern ]]; then
    printf '链接格式无效，请完整复制安装器生成的 private-v1 链接。\n' >&2
    exit 2
  fi
  port=$((10#${BASH_REMATCH[3]}))
  if (( port < 1024 || port > 65535 )); then
    printf '链接端口无效。\n' >&2
    exit 2
  fi
  set -o noclobber
  write_private_client_config "${BASH_REMATCH[2]}:$port" "${BASH_REMATCH[1]}" \
    "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}" > "$1"
)

if [[ ${1:-} == import-private ]]; then
  shift
  import_private_link "$@"
  exit
fi

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
  printf 'HY2 服务已收到启动请求。\n'
}

wait_for_listener() {
  local port=$1 attempt invocation ready_log
  for ((attempt=0; attempt<90; attempt++)); do
    if ! systemctl is-active --quiet "$service"; then break; fi
    invocation=$(systemctl show -p InvocationID --value "$service")
    if [[ $invocation =~ ^[0-9a-f]{32}$ ]]; then
      ready_log=$("${admin[@]}" journalctl --no-pager -q -o cat -n 1 \
        --grep='server up and running' "_SYSTEMD_INVOCATION_ID=$invocation")
      if [[ -n $ready_log ]]; then return 0; fi
    fi
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
  read -rp 'UDP 端口 [8443]：' port
  port=${port:-8443}
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
    write_private_client_config "$domain:$port" "$proxy_password" "$domain" "$shared_key" > "$tmp/client.yaml"
  else
    obfs_password=$(openssl rand -hex 24)
    cat >> "$tmp/config.yaml" <<EOF
obfs:
  type: $mode
  $mode:
    password: "$obfs_password"
EOF
    printf 'hysteria2://%s@%s:%s/?insecure=0&sni=%s&alpn=h3&obfs=%s&obfs-password=%s#hy2\n' \
      "$proxy_password" "$domain" "$port" "$domain" "$mode" "$obfs_password" > "$tmp/client-uri.txt"
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
    show_private_link "$(cat "$tmp/client.yaml")"
  else
    printf '\n复制下面的链接到支持 HY2 链接导入的客户端。\n'
    cat "$tmp/client-uri.txt"
  fi
)

show_domain_alias() {
  require_commands openssl grep
  local uri domain auth port suffix pattern
  if ! "${admin[@]}" test -r "$config_dir/client-uri.txt"; then
    printf '此选项需要菜单 1 或 8 安装生成的 HY2 导入链接。\n' >&2
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

uninstall_server() {
  local unit_file=/etc/systemd/system/hy2plus.service
  local binary=/usr/local/bin/hy2plus
  local fragment backup_dir answer

  require_commands systemctl grep mktemp mv rm
  if (( EUID != 0 )); then require_commands sudo; sudo -v; fi

  systemctl show -p Version --value >/dev/null
  if ! fragment=$(systemctl show -p FragmentPath --value "$service" 2>/dev/null); then
    if "${admin[@]}" test -e "$unit_file"; then
      printf '无法确认服务状态，卸载已停止。\n' >&2
      return 1
    fi
    fragment=
  fi
  if [[ -n $fragment && $fragment != "$unit_file" ]]; then
    printf '服务来自其他安装路径：%s。请用对应安装方式卸载。\n' "$fragment" >&2
    return 1
  fi
  if "${admin[@]}" test -e "$unit_file" &&
     ! "${admin[@]}" grep -Fxq 'ExecStart=/usr/local/bin/hy2plus server -c %d/config.yaml' "$unit_file"; then
    printf '服务文件与本安装器生成的文件不匹配。\n' >&2
    return 1
  fi
  if ! "${admin[@]}" test -e "$unit_file" &&
     ! "${admin[@]}" test -e "$binary" &&
     ! "${admin[@]}" test -d "$config_dir"; then
    printf 'HY2+ 已卸载。\n'
    return 0
  fi

  read -rp '卸载会中断代理连接。输入 UNINSTALL 确认：' answer
  if [[ $answer != UNINSTALL ]]; then
    printf '已取消卸载。\n'
    return 0
  fi

  if [[ -n $fragment ]]; then
    "${admin[@]}" systemctl disable --now "$service"
  fi
  if "${admin[@]}" test -d "$config_dir"; then
    backup_dir=$("${admin[@]}" mktemp -d /etc/hy2plus-backup.XXXXXXXX)
    "${admin[@]}" mv -T -- "$config_dir" "$backup_dir/config"
    printf '配置备份：%s/config\n' "$backup_dir"
  fi
  "${admin[@]}" rm -f -- "$unit_file" "$binary"
  "${admin[@]}" systemctl daemon-reload
  printf 'HY2+ 已卸载。自动签发的证书仍保存在 /var/lib/hy2plus/acme（如果此前启用）。\n'
}

printf '\nHY2+ VPS 管理菜单\n'
printf '%s\n' '1) 安装 HY2 + Salamander（输出可导入链接）' '2) 启用并启动已有服务' \
  '3) 查看服务状态' '4) 查看最近日志' '5) 显示导入链接或客户端配置' '6) 安装 HY2+ private-v1' \
  '7) 生成备用域名导入链接' '8) 安装 HY2 + Gecko（需要客户端支持）' \
  '9) 卸载 HY2+' '0) 退出'
read -rp '请选择 [1]：' choice
case "${choice:-1}" in
  1) install_server salamander ;;
  2) start_service ;;
  3) systemctl status "$service" --no-pager ;;
  4) "${admin[@]}" journalctl -u "$service" -n 50 --no-pager ;;
  5)
    if "${admin[@]}" test -f "$config_dir/client-uri.txt"; then
      "${admin[@]}" cat "$config_dir/client-uri.txt"
    else
      client_config=$("${admin[@]}" cat "$config_dir/client.yaml")
      printf '%s\n\n' "$client_config"
      show_private_link "$client_config"
    fi
    ;;
  6) install_server private ;;
  7) show_domain_alias ;;
  8) install_server gecko ;;
  9) uninstall_server ;;
  0) exit 0 ;;
  *) printf '无效选项。\n' >&2; exit 2 ;;
esac
