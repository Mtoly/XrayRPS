# XRayR
A Xray backend framework that can easily support many panels.

一个基于Xray的后端框架，支持V2ay,Trojan,Shadowsocks协议，极易扩展，支持多面板对接

Find the source code here: [Mtoly/XrayRP](https://github.com/Mtoly/XrayRP)

# 详细使用教程

[教程](https://Mtoly.github.io/XrayR-doc/)

# 一键安装

```
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 -o install.sh https://raw.githubusercontent.com/Mtoly/XrayRPS/main/install.sh
bash install.sh
rm -f install.sh
```

# Xboard Machine Mode 一键安装

此安装脚本只生成 XrayRP `MachineConfig` 并安装/启动 XrayR 服务，不会在 Xboard 中创建或注册机器。请先在 Xboard 创建/绑定机器，并复制对应的 `MachineID` 和 `Token`。

`MachineConfig` 与静态 `Nodes` 配置互斥。启用机器模式时，`/etc/XrayR/config.yml` 不会生成静态 `Nodes`。

安装示例：

```
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 -o install-machine.sh https://raw.githubusercontent.com/Mtoly/XrayRPS/main/install-machine.sh
bash install-machine.sh \
  --api-host https://panel.example.com \
  --machine-id 1 \
  --token "machine-token" \
  --panel-type NewV2board \
  --enable-ws
```

如果 `/etc/XrayR/config.yml` 已存在，脚本默认不会覆盖；确认要覆盖时添加 `--force`。

状态与日志：

```
systemctl status XrayR
journalctl -u XrayR -f
XrayR log
```

卸载：

```
XrayR uninstall
```
# Docker 安装

```
docker pull ghcr.io/mtoly/xrayr:0.9.1-alpha-6
docker run --detach --restart=unless-stopped --name xrayr --read-only --tmpfs /tmp:rw,noexec,nosuid,nodev --security-opt no-new-privileges:true --cap-drop=ALL --volume "${PATH_TO_CONFIG}/config.yml:/etc/XrayR/config.yml:ro" --network=host ghcr.io/mtoly/xrayr:0.9.1-alpha-6
```

# Docker compose 安装
0. 安装docker-compose: 
```
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 -o get-docker.sh https://get.docker.com
sh get-docker.sh
rm -f get-docker.sh
# Prefer the Docker Compose plugin supplied by the distribution.
```
1. `git clone https://github.com/Mtoly/XrayRPS`
2. `cd XrayRPS`
3. 编辑config。
配置文件基本格式如下，Nodes下可以同时添加多个面板，多个节点配置信息，只需添加相同格式的Nodes item即可。
4. 启动docker：`docker compose up -d`
```
Log:
  Level: none # Log level: none, error, warning, info, debug 
  AccessPath: # /etc/XrayR/access.Log
  ErrorPath: # /etc/XrayR/error.log
DnsConfigPath: # /etc/XrayR/dns.json Path to dns config
ConnetionConfig:
  Handshake: 4 # Handshake time limit, Second
  ConnIdle: 10 # Connection idle time limit, Second
  UplinkOnly: 2 # Time limit when the connection downstream is closed, Second
  DownlinkOnly: 4 # Time limit when the connection is closed after the uplink is closed, Second
  BufferSize: 64 # The internal cache size of each connection, kB 
Nodes:
  -
    PanelType: "SSpanel" # Panel type: SSpanel, V2board, PMpanel
    ApiConfig:
      ApiHost: "http://127.0.0.1:667"
      ApiKey: "YOUR_API_KEY"
      NodeID: 41
      NodeType: V2ray # Node type: V2ray, Shadowsocks, Trojan
      Timeout: 30 # Timeout for the api request
      EnableVless: false # Enable Vless for V2ray Type
      EnableXTLS: false # Enable XTLS for V2ray and Trojan
      SpeedLimit: 0 # Mbps, Local settings will replace remote settings, 0 means disable
      DeviceLimit: 0 # Local settings will replace remote settings, 0 means disable
      RuleListPath: # /etc/XrayR/rulelist Path to local rulelist file
    ControllerConfig:
      ListenIP: 0.0.0.0 # IP address you want to listen
      SendIP: 0.0.0.0 # IP address you want to send pacakage
      UpdatePeriodic: 60 # Time to update the nodeinfo, how many sec.
      EnableDNS: false # Use custom DNS config, Please ensure that you set the dns.json well
      DNSType: AsIs # AsIs, UseIP, UseIPv4, UseIPv6, DNS strategy
      EnableProxyProtocol: false # Only works for WebSocket and TCP
      EnableFallback: false # Only support for Trojan and Vless
      FallBackConfigs:  # Support multiple fallbacks
        -
          SNI: # TLS SNI(Server Name Indication), Empty for any
          Path: # HTTP PATH, Empty for any
          Dest: 80 # Required, Destination of fallback, check https://xtls.github.io/config/fallback/ for details.
          ProxyProtocolVer: 0 # Send PROXY protocol version, 0 for dsable
      CertConfig:
        CertMode: dns # Option about how to get certificate: none, file, http, dns. Choose "none" will forcedly disable the tls config.
        CertDomain: "node1.test.com" # Domain to cert
        CertFile: /etc/XrayR/cert/node1.test.com.cert # Provided if the CertMode is file
        KeyFile: /etc/XrayR/cert/node1.test.com.key
        Provider: alidns # DNS cert provider, Get the full support list here: https://go-acme.github.io/lego/dns/
        Email: test@me.com
        DNSEnv: # DNS ENV option used by DNS provider
          ALICLOUD_ACCESS_KEY: YOUR_ACCESS_KEY
          ALICLOUD_SECRET_KEY: YOUR_SECRET_KEY
  # -
  #   PanelType: "V2board" # Panel type: SSpanel, V2board
  #   ApiConfig:
  #     ApiHost: "http://127.0.0.1:668"
  #     ApiKey: "YOUR_API_KEY"
  #     NodeID: 4
  #     NodeType: Shadowsocks # Node type: V2ray, Shadowsocks, Trojan
  #     Timeout: 30 # Timeout for the api request
  #     EnableVless: false # Enable Vless for V2ray Type
  #     EnableXTLS: false # Enable XTLS for V2ray and Trojan
  #     SpeedLimit: 0 # Mbps, Local settings will replace remote settings
  #     DeviceLimit: 0 # Local settings will replace remote settings
  #   ControllerConfig:
  #     ListenIP: 0.0.0.0 # IP address you want to listen
  #     UpdatePeriodic: 10 # Time to update the nodeinfo, how many sec.
  #     EnableDNS: false # Use custom DNS config, Please ensure that you set the dns.json well
  #     CertConfig:
  #       CertMode: dns # Option about how to get certificate: none, file, http, dns
  #       CertDomain: "node1.test.com" # Domain to cert
  #       CertFile: /etc/XrayR/cert/node1.test.com.cert # Provided if the CertMode is file
  #       KeyFile: /etc/XrayR/cert/node1.test.com.pem
  #       Provider: alidns # DNS cert provider, Get the full support list here: https://go-acme.github.io/lego/dns/
  #       Email: test@me.com
  #       DNSEnv: # DNS ENV option used by DNS provider
  #         ALICLOUD_ACCESS_KEY: YOUR_ACCESS_KEY
  #         ALICLOUD_SECRET_KEY: YOUR_SECRET_KEY
```

## Docker compose升级
在 `docker-compose.yml` 所在目录执行。升级前先 review 目标标签，并确认配置已备份：

```
docker compose config
docker compose pull
docker compose up -d --remove-orphans
docker compose ps
```

## 安全基线与恢复

- 生产环境固定发布版本并保存对应的 `SHA256SUMS` 与部署记录。
- systemd 部署使用专用 `xrayr` 服务账号；容器部署使用只读配置挂载、只读根文件系统和能力收敛。
- `config/custom_inbound.json` 仅作为本地示例，启用前必须替换凭据并确认监听地址。
- 更新失败时保留上一版本目录和配置备份；先停止服务，再恢复上一版本并检查 `systemctl status XrayR` 或 `docker compose ps`。
- 漏洞报告与敏感信息处理流程见 [`SECURITY.md`](SECURITY.md)。