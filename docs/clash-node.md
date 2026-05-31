# Clash Verge 节点

本部署额外提供一个独立 `clash-node` 服务，用 `sing-box` 暴露 Shadowsocks 入站，供 Clash Verge 手动添加节点使用。

## 服务端

生产服务器 `.env` 必须设置：

```text
CLASH_NODE_PASSWORD=<strong-random-password>
```

可选项：

```text
CLASH_NODE_PORT=8388
CLASH_NODE_METHOD=aes-256-gcm
CLASH_NODE_BIND_HOST=0.0.0.0
CLASH_NODE_LOG_LEVEL=warn
```

需要在云安全组和服务器防火墙放行同一个端口的 TCP/UDP，默认是 `8388/tcp` 和 `8388/udp`。

## Clash Verge

手动添加 Shadowsocks 节点：

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

不要把真实 `CLASH_NODE_PASSWORD` 写入 Git、README、截图或对话日志。

## 边界

- 该节点是服务器直连出口，不复用 Sub2API 内部代理池。
- 原有 `sing-box` sidecar 仍只用于 Sub2API 容器内部代理分发。
- `clash-node` 使用独立容器和独立配置，避免影响现有账号代理链路。
