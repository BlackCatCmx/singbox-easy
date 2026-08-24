# singbox-easy

面向 Debian/Ubuntu VPS 的精简 sing-box 一键安装与管理脚本，支持 VLESS Reality、Hysteria2、Shadowsocks 2022 和 Hysteria2 UDP 端口跳跃。

## 安装

不带参数时自动安装，并创建一个随机端口的 VLESS Reality 配置：

```bash
curl -fsSL https://raw.githubusercontent.com/BlackCatCmx/singbox-easy/main/install.sh | sudo bash
```

指定 Reality 参数：

```bash
curl -fsSL https://raw.githubusercontent.com/BlackCatCmx/singbox-easy/main/install.sh | sudo bash -s -- --protocol reality --name home --port 443 --sni www.microsoft.com --address proxy.example.com
```

安装 Hysteria2：

```bash
curl -fsSL https://raw.githubusercontent.com/BlackCatCmx/singbox-easy/main/install.sh | sudo bash -s -- --protocol hysteria2 --name mobile --port 8443
```

启用 Hysteria2 端口跳跃：

```bash
curl -fsSL https://raw.githubusercontent.com/BlackCatCmx/singbox-easy/main/install.sh | sudo bash -s -- --protocol hysteria2 --name mobile --hy2-port-range 20000:30000
```

跳跃范围起点是 sing-box 的监听端口。服务商需要放行或转发完整 UDP 范围；如果本机跳跃规则创建失败，脚本会关闭跳跃并使用范围起点作为普通单端口。

安装 Shadowsocks 2022：

```bash
curl -fsSL https://raw.githubusercontent.com/BlackCatCmx/singbox-easy/main/install.sh | sudo bash -s -- --protocol shadowsocks --name backup --port 8388
```

## 可用参数

```text
--protocol VALUE         reality、hysteria2 或 shadowsocks，默认 reality
--name NAME              初始配置名称，默认 default
--port PORT              监听端口，默认随机空闲端口
--address ADDRESS        分享链接中的公网 IP 或域名，默认自动检测
--sni DOMAIN             Reality SNI，默认 www.cloudflare.com
--hy2-port-range RANGE   Hysteria2 UDP 跳跃范围，例如 20000:30000
--no-profile             只安装程序，不创建初始配置
--ref GIT_REF            从指定分支、标签或提交安装
--help                   显示帮助
```

同时指定 `--port` 和 `--hy2-port-range` 时，端口必须等于范围起点。

## 管理命令

```bash
sbe add reality home --port 443 --sni www.microsoft.com
sbe add hysteria2 mobile --port 8443
sbe add hysteria2 mobile --port-range 20000:30000
sbe add shadowsocks backup --port 8388

sbe list
sbe show home
sbe set home port 8443
sbe set home sni www.microsoft.com
sbe set home address proxy.example.com
sbe remove home

sbe check
sbe status
sbe start
sbe stop
sbe restart
sbe logs
sbe update
sbe uninstall
```

修改已启用跳跃的 Hy2 监听端口会同时关闭端口跳跃。删除最后一个配置后服务自动停止，再次添加配置时自动启动。
