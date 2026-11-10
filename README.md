# HY2+ VPS 安装

在 Debian 13 的 Bash 中运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yzzkk/hy2plus-install/main/install.sh)
```

支持使用 systemd 的 Linux amd64 和 arm64。首次安装时填写 VPS 域名、UDP 端口（默认 4443）及已有 TLS 证书和私钥的绝对路径。若缺少依赖，请先安装 `curl`、`ca-certificates` 和 `openssl`。安装器会校验 v0.1.0 二进制的 SHA-256，生成配置并启动服务。

- **菜单 1：HY2 + Salamander。** 启动后显示带有 `obfs=salamander` 和 `obfs-password` 的 `hysteria2://` 链接，可导入支持这两个参数的 sing-box 图形客户端。TLS 验证保持开启，需要客户端信任证书链。
- **菜单 6：HY2+ private-v1。** 使用自定义 UDP 封包和配套 HY2+ 客户端。配套客户端启动后，通过本机 SOCKS5 地址 `127.0.0.1:1080` 接入 sing-box。

在 VPS 防火墙和云安全组放行安装时选择的 UDP 端口。菜单 **5** 可重新查看导入链接或客户端配置，内容包含连接凭据。已有配置时安装器会停止，防止覆盖正在使用的服务。

安装包与上游许可证见 [v0.1.0 Release](https://github.com/yzzkk/hy2plus-install/releases/tag/v0.1.0)。
