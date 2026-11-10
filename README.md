# HY2+ VPS 安装

在 Debian 13 的 Bash 中运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/yzzkk/hy2plus-install/main/install.sh)
```

支持使用 systemd 的 Linux amd64 和 arm64。菜单选 **1**，输入 VPS 域名及已有 TLS 证书和私钥的绝对路径。安装器会校验 v0.1.0 二进制的 SHA-256，生成配置并启动服务。若系统缺少依赖，请先安装 `curl`、`ca-certificates` 和 `openssl`。

在 VPS 防火墙和云安全组放行 **UDP 4443**。菜单选 **5** 可以读取客户端配置。配套 HY2+ 客户端启动后，可通过本机 SOCKS5 地址 `127.0.0.1:1080` 接入 sing-box。

安装包与上游许可证见 [v0.1.0 Release](https://github.com/yzzkk/hy2plus-install/releases/tag/v0.1.0)。
