# Clash Verge 节点与订阅

本部署额外提供一个独立 `clash-node` 服务，用 `sing-box` 暴露 Shadowsocks 入站，供 Clash Verge 使用。

## 服务端配置

生产服务器 `.env` 必须配置：

```text
CLASH_NODE_PASSWORD=<strong-random-password>
```

可选项：

```text
CLASH_NODE_PORT=8388
CLASH_NODE_METHOD=aes-256-gcm
CLASH_NODE_BIND_HOST=0.0.0.0
CLASH_NODE_LOG_LEVEL=warn
CLASH_NODE_SERVER=api.zero007.chat
CLASH_SUBSCRIPTION_TOKEN=<private-random-token>
```

需要在云安全组和服务器防火墙放行同一个端口的 TCP/UDP，默认是 `8388/tcp` 和 `8388/udp`。

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

## 边界

- 该节点是服务器直连出口，不复用 Sub2API 内部代理池。
- 原有 `sing-box` sidecar 仍只用于 Sub2API 容器内部代理分发。
- `clash-node` 使用独立容器和独立配置，避免影响现有账号代理链路。
