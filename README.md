# singbox-easy

一个精简、透明的 sing-box 服务端安装与管理脚本。

项目只处理 sing-box 本身，不修改系统 DNS，不安装 Caddy，不调整 BBR，也不导入其他一键脚本的配置。

> 非 sing-box 官方项目。

## 支持范围

- Debian、Ubuntu
- systemd
- AMD64、ARM64
- VLESS-REALITY
- Hysteria2
- Shadowsocks 2022

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/BlackCatCmx/singbox-easy/main/install.sh | sudo bash
```

安装完成后会自动创建名为 `default` 的 VLESS-REALITY 配置，并显示分享链接。

如果不希望自动创建配置：

```bash
curl -fsSL https://raw.githubusercontent.com/BlackCatCmx/singbox-easy/main/install.sh | sudo bash -s -- --no-profile
```

此模式只安装程序和 systemd 服务文件，服务保持禁用和停止；第一次添加配置后自动启用并启动。

## 使用

```text
sbe add reality home
sbe add hysteria2 mobile --port 443
sbe add shadowsocks backup --address proxy.example.com

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

`sbe uninstall` 会停止服务，并直接删除程序、证书及全部配置，不进行保留确认。

## 文件位置

```text
/etc/singbox-easy/
├── bin/sing-box
├── config.json
├── conf.d/
├── state/
└── tls/

/etc/systemd/system/singbox-easy.service
/usr/local/bin/sbe
```

配置文件和包含分享链接的状态文件权限为 `0600`。

## 安全模型

- 所有下载均使用正常的 HTTPS 证书验证。
- sing-box 发布包使用 GitHub Release API 提供的 SHA-256 摘要校验。
- 不使用 `curl | bash` 下载并执行第三方脚本。
- 不上传 UUID、密码、Reality 密钥或配置。
