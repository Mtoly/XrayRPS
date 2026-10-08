# Xboard Machine Mode

[返回首页](../README.md) · [主机运维](operations.md)

## 前置条件与交互安装

在 Xboard 创建或绑定机器，取得面板 API Host、数字 Machine ID 及 Token。
安装器不创建或注册面板机器；安装时通过 `POST /api/v2/server/machine/nodes` 校验凭据。
主机必须运行 systemd 或 OpenRC，并提供 root 终端；Alpine 先安装 Bash 和 curl，详见[运行条件](operations.md#运行条件)。

```bash
curl -fsSL --proto '=https' --tlsv1.2 -o install-machine.sh \
  https://raw.githubusercontent.com/Mtoly/XrayRPS/main/install-machine.sh
bash install-machine.sh
```

有可用交互终端时，依次询问缺少的 API Host、Machine ID、Token；已提供的参数不会重复询问，Token 输入不回显。
缺少必填参数且没有可用终端时，参数校验失败，不会等待输入。
安装器生成 `/etc/XrayR/config.yml`，安装并启动 `XrayR` 服务。
写入阶段配置权限为 0600；启动前统一设置为 `root:root`、0640，配置目录权限为 0750。

## 命令行与预览

查看脚本支持的参数：

```bash
bash install-machine.sh --help
```

无人值守示例使用占位 URL、Token 和数字 ID，请替换为对应机器的值：

```bash
bash install-machine.sh \
  --api-host https://panel.example.com \
  --machine-id 1 \
  --token TOKEN \
  --panel-type NewV2board \
  --version 0.9.5 \
  --enable-ws
```

Token 放在命令行可能进入 shell 历史或进程参数；手工安装优先使用交互输入。
不要使用真实 Token 做文档测试，也不要将安装输出、配置或 `bash -x` trace 公开。

只校验参数并预览操作：

```bash
bash install-machine.sh \
  --api-host https://panel.example.com \
  --machine-id 1 --token TOKEN --dry-run
```

`--dry-run` 不写入文件、不操作服务、不请求面板，Token 显示为脱敏值。
它没有执行真实 init 检测，服务文件展示仍可能是默认 systemd 路径；不能据此判断 OpenRC 实际安装结果。

## 参数与默认值

| 参数 | 默认值 / 用途 |
| --- | --- |
| `--api-host`、`--machine-id`、`--token` | 必填；交互终端可补齐，ID 为数字 |
| `--panel-type` | `NewV2board` |
| `--version` | `latest`；也可指定存在的 release |
| `--timeout` | 30 秒，API 请求超时 |
| `--discovery-interval` | 60 秒，节点发现间隔 |
| `--listen-ip`、`--send-ip` | `0.0.0.0` |
| `--enable-ws`、`--disable-ws` | WebSocket 默认开启 |
| `--ws-endpoint` | 可选 WebSocket endpoint |
| `--heartbeat-interval` | 30 秒 |
| `--reconnect-backoff` | 5 秒 |
| `--resync-on-reconnect` | `true`；接受 `true` 或 `false` |
| `--force` | 显式覆盖已有主配置 |
| `--dry-run`、`--help` | 预览 / 帮助 |

## 配置保留与更新

`MachineConfig` 与静态 `Nodes` 互斥；生成的 Machine 配置不包含 `Nodes`。

- 已有 `/etc/XrayR/config.yml` 时，默认拒绝覆盖。
- `--force` 重建主配置，只保留已有且有效的 Observability `Enable`、`Listen`、`ReadinessStaleAfter`；
  其他主配置定制不保证保留。使用前独立备份并审阅生成结果。
- 日常二进制升级使用 `XrayR update` 或 `XrayR update 0.9.5`，保留原配置及 Machine 凭据。

生成器默认开启 Observability，监听 `127.0.0.1:10085`，`ReadinessStaleAfter` 为 180 秒。
状态接口由 XrayRP 核心实现；避免将其暴露到公网。

```bash
XrayR status
XrayR log
```

服务管理、失败恢复与卸载前备份见[主机运维](operations.md)。
