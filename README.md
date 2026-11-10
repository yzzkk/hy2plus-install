# HY2+ VPS 安装

在 Debian 13 的 Bash 中运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yzzkk/hy2plus-install/main/install.sh)
```

支持使用 systemd 的 Linux amd64 和 arm64。首次安装时填写 VPS 域名和 UDP 端口（默认 8443），然后选择证书方式。默认使用 Let’s Encrypt 自动签发并续期，也可以输入已有 TLS 证书和私钥的绝对路径。若缺少依赖，请先安装 `curl`、`ca-certificates`、`openssl` 和 `iproute2`。安装器会校验 v0.1.0 二进制的 SHA-256，生成配置并启动服务。

- **菜单 1：HY2 + Salamander。** 启动后显示带有 `obfs=salamander` 和 `obfs-password` 的 `hysteria2://` 链接，可导入支持这两个参数的 sing-box 图形客户端。TLS 验证保持开启，需要客户端信任证书链。
- **菜单 8：HY2 + Gecko。** 在 Salamander 基础上，将 QUIC 握手数据报拆分为带随机填充的片段。导入链接使用 `obfs=gecko`，需要客户端内核支持 Gecko，且导入器能读取该参数。后续短头数据包仍使用 Salamander。
- **菜单 6：HY2+ private-v1。** 使用自定义 UDP 封包和配套 HY2+ 客户端。配套客户端启动后，通过本机 SOCKS5 地址 `127.0.0.1:1080` 接入 sing-box。

自动签发使用 HTTP-01。请让域名的 A 记录（以及存在的 AAAA 记录）指向可用的 VPS 地址，Cloudflare 记录选择 DNS only（灰云）。在 VPS 防火墙和云安全组放行公网 TCP 80，保持该端口可用于后续续期。证书与私钥由 HY2 保存在 `/var/lib/hy2plus/acme`。

在 VPS 防火墙和云安全组放行安装时选择的 UDP 端口。菜单 **5** 可重新查看导入链接或客户端配置，内容包含连接凭据。已有配置时安装器会停止，防止覆盖正在使用的服务。

给现有 HY2 + Salamander 或 HY2 + Gecko 节点加备用域名时，先让新域名解析到同一台 VPS，并使用手动部署、覆盖该域名的 TLS 证书。重新运行安装命令并选 **7**，即可生成新域名的导入链接。生成的链接沿用原节点的端口、认证密码和混淆密码。

卸载时，重新运行上方命令，选择 **9** 并输入 `UNINSTALL`。脚本会停止服务、取消开机启动，移除程序和 systemd 服务文件。配置会移到 `/etc/hy2plus-backup.*/config`，自动签发的证书会保留在 `/var/lib/hy2plus/acme`。

安装包与上游许可证见 [v0.1.0 Release](https://github.com/yzzkk/hy2plus-install/releases/tag/v0.1.0)。
