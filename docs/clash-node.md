# Clash Verge 节点与订阅

本部署额外提供两个独立节点能力，供 Clash Verge 使用：

- `clash-node`：Shadowsocks 直连节点，适合追求速度、UDP 和低额外封装开销的场景；需要公网端口可达。
- `vpn-ws-node`：VLESS/Trojan over WebSocket TLS 节点，经 Caddy 和 Cloudflare 443 暴露，适合不开 VPN 也要稳定连接、或作为静态住宅 IP 链式代理前置节点的场景。

## 服务端配置

生产服务器 `.env` 必须配置 Shadowsocks 密码：

```text
CLASH_NODE_PASSWORD=<strong-random-password>
```

可选项。`VPN_WS_*` 缺失时，部署脚本会自动生成默认值并写入服务器 `.env`；如需固定域名、路径或密钥，可以提前手动配置：

```text
CLASH_NODE_PORT=8388
CLASH_NODE_METHOD=aes-256-gcm
CLASH_NODE_BIND_HOST=0.0.0.0
CLASH_NODE_LOG_LEVEL=warn
CLASH_NODE_SERVER=api.zero007.chat
CLASH_SUBSCRIPTION_TOKEN=<private-random-token>
VPN_WS_ENABLED=true
VPN_WS_SERVER=vpn.zero007.chat
VPN_WS_UUID=<uuid>
VPN_WS_TROJAN_PASSWORD=<strong-random-password>
VPN_WS_VLESS_PATH=/vless
VPN_WS_TROJAN_PATH=/trojan
VPN_WS_LOG_LEVEL=warn
```

需要在云安全组和服务器防火墙放行同一个端口的 TCP/UDP，默认是 `8388/tcp` 和 `8388/udp`。

`vpn-ws-node` 不直接暴露公网端口，由 Caddy 在 `8080` 内部反向代理，再经 Cloudflare 以 HTTPS/WSS 方式访问。Cloudflare 侧需要：

- `vpn.zero007.chat` 指向服务器公网 IP，代理状态开启橙云。
- `Network` 中开启 `WebSockets`。
- `SSL/TLS` 使用 `Full` 或 `Full (strict)`，不要使用 `Flexible`。
- 保持 `api.zero007.chat` 现有解析不变。

## 订阅 URL

设置 `CLASH_SUBSCRIPTION_TOKEN` 后，Caddy 会在私密路径提供 Clash YAML 订阅：

```text
https://api.zero007.chat/clash/<CLASH_SUBSCRIPTION_TOKEN>.yaml
```

同时会生成手机端兼容订阅，配置更精简，不包含 `dns`、`fake-ip`、`mixed-port` 等部分移动端 Clash 客户端容易出现兼容差异的字段：

```text
https://api.zero007.chat/clash/<CLASH_SUBSCRIPTION_TOKEN>.mobile.yaml
```

在服务器上可用下面的命令查看完整订阅 URL：

```sh
sudo awk -F= '/^CLASH_SUBSCRIPTION_TOKEN=/{print "https://api.zero007.chat/clash/"$2".yaml"}' /opt/sub2api-deploy/.env
```

查看手机端兼容订阅 URL：

```sh
sudo awk -F= '/^CLASH_SUBSCRIPTION_TOKEN=/{print "https://api.zero007.chat/clash/"$2".mobile.yaml"}' /opt/sub2api-deploy/.env
```

不要把订阅 URL、真实 `CLASH_NODE_PASSWORD` 或 `CLASH_SUBSCRIPTION_TOKEN` 写入 Git、README、截图或公开对话日志。拿到订阅 URL 的人等同于拿到节点访问权限。

## 手动节点

如果不使用订阅，也可以手动添加 Shadowsocks 节点：

```yaml
proxies:
  - name: zero007-sub2api-ss
    type: ss
    server: api.zero007.chat
    port: 8388
    cipher: aes-256-gcm
    password: "<CLASH_NODE_PASSWORD>"
    udp: true
```

如果 Clash Verge 开启代理后解析域名存在回环或劫持问题，可以把 `CLASH_NODE_SERVER` 改成服务器公网 IP，再重新部署生成订阅。

VLESS/Trojan WS TLS 节点建议通过订阅导入，手动添加时参数如下：

```yaml
proxies:
  - name: zero007-vless-ws-cf
    type: vless
    server: vpn.zero007.chat
    port: 443
    uuid: "<VPN_WS_UUID>"
    network: ws
    tls: true
    udp: false
    servername: vpn.zero007.chat
    ws-opts:
      path: /vless
      headers:
        Host: vpn.zero007.chat

  - name: zero007-trojan-ws-cf
    type: trojan
    server: vpn.zero007.chat
    port: 443
    password: "<VPN_WS_TROJAN_PASSWORD>"
    network: ws
    tls: true
    udp: false
    sni: vpn.zero007.chat
    ws-opts:
      path: /trojan
      headers:
        Host: vpn.zero007.chat
```

推荐使用方式：

- 能直连服务器端口时，优先测试 `zero007-sub2api-ss`。
- 不开 VPN 也需要连通，或网络对裸 TCP/UDP 端口限制较多时，优先测试 `zero007-vless-ws-cf` 或 `zero007-trojan-ws-cf`。
- 作为静态住宅 IP 链式代理的前置节点时，优先选延迟稳定的 WS TLS 节点。

## 边界

- 这些节点都是服务器直连出口，不复用 Sub2API 内部代理池。
- 原有 `sing-box` sidecar 仍只用于 Sub2API 容器内部代理分发。
- `clash-node` 和 `vpn-ws-node` 使用独立容器和独立配置，避免影响现有账号代理链路。
- Cloudflare 普通橙云只代理 HTTP/HTTPS/WebSocket，不代理裸 Shadowsocks TCP/UDP；因此 SS 节点仍依赖服务器公网端口可达。
