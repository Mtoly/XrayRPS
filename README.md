<div align="center">

# XrayRPS

**XrayRP 的安装与管理脚本**

Installation and management scripts for XrayRP, with systemd and OpenRC support.

[![Tests](https://github.com/Mtoly/XrayRPS/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/Mtoly/XrayRPS/actions/workflows/test.yml) [![License: MPL-2.0](https://img.shields.io/badge/License-MPL--2.0-blue.svg)](LICENSE)

[快速安装](#快速安装) · [Machine Mode](#xboard-machine-mode) · [Docker](#docker--docker-compose) · [运维文档](docs/operations.md)

</div>

XrayRPS 负责安装、升级、配置生成与本机服务管理。代理协议、面板适配及运行时由 [XrayRP](https://github.com/Mtoly/XrayRP) 核心程序提供。
安装后的二进制、服务与管理命令沿用 `XrayR` 名称。

## 功能特点

- 自动识别正在运行的 **systemd / OpenRC**，支持 Alpine Linux。
- 下载 XrayRP release，并通过对应的 `SHA256SUMS` 校验发布包。
- 提供启动、停止、重启、日志、状态和开机自启管理。
- 交互生成 Xboard `MachineConfig`；普通更新保留已有配置。
- 提供 Docker Compose 部署入口，支持 `latest` 和版本锁定。

## 快速安装

在 **root 终端**执行；主机必须实际运行 systemd 或 OpenRC。Alpine 先执行 `apk add --no-cache bash curl`。
完整运行条件与故障恢复见[运维文档](docs/operations.md)。

```bash
curl -fsSL --proto '=https' --tlsv1.2 -o install.sh \
  https://raw.githubusercontent.com/Mtoly/XrayRPS/main/install.sh
bash install.sh
```

默认安装最新版；指定版本可执行 `bash install.sh 0.9.5`。全新安装后，先编辑配置并准备所需证书，再启动：

```bash
vi /etc/XrayR/config.yml
XrayR start
XrayR status
XrayR log
```

配置目录为 `/etc/XrayR`，二进制为 `/usr/local/XrayR/XrayR`。
静态节点配置参考 [config/config.yml](config/config.yml)；请替换示例凭据与监听地址。

| 命令 | 用途 |
| --- | --- |
| `XrayR` | 打开管理菜单（主机部署） |
| `XrayR start` · `XrayR stop` · `XrayR restart` | 启动 / 停止 / 重启 |
| `XrayR status` · `XrayR log` · `XrayR version` | 状态 / 日志 / 版本 |
| `XrayR enable` · `XrayR disable` | 启用 / 取消开机自启 |
| `XrayR update 0.9.5` | 指定版本更新；省略版本则更新至最新版 |
| `XrayR config` | 使用 vi 编辑配置；保存后执行 `XrayR restart` |

## Xboard Machine Mode

先在 Xboard **创建或绑定机器**，取得面板 URL、Machine ID 和 Token。
安装器只生成配置并安装、启动服务，不在面板注册机器；支持 systemd 和 OpenRC。

在 root 交互终端执行，缺少的三项参数会依次询问，Token 输入不回显：

```bash
curl -fsSL --proto '=https' --tlsv1.2 -o install-machine.sh \
  https://raw.githubusercontent.com/Mtoly/XrayRPS/main/install-machine.sh
bash install-machine.sh
```

`MachineConfig` 与静态 `Nodes` 互斥。已有配置默认拒绝覆盖；
`--force` 会重建主配置，不是普通更新选项。日常升级使用 `XrayR update`。
参数、配置保留边界和诊断见 [Machine Mode 文档](docs/machine-mode.md)。

## Docker / Docker Compose

先安装 [Docker Engine 与 Compose 插件](https://docs.docker.com/engine/install/)，在 Linux 主机执行：

```bash
git clone https://github.com/Mtoly/XrayRPS.git
cd XrayRPS
vi config/config.yml
docker compose pull
docker compose up -d
docker compose ps
```

启动前配置节点、证书，并启用本地 Observability（监听 `127.0.0.1:10085`）以满足 Compose 健康检查。
默认镜像为 `ghcr.io/mtoly/xrayrp:latest`；运行中的容器不会自动升级。
版本锁定、升级、日志和单容器部署见 [Docker 文档](docs/docker.md)。主机 `XrayR` 菜单不管理容器。

## 文档与相关项目

- [主机运维](docs/operations.md)：systemd 故障恢复、OpenRC 管理、更新与回滚。
- [Machine Mode](docs/machine-mode.md)：前置条件、安装参数与凭据处理。
- [Docker 部署](docs/docker.md)：Compose、版本锁定与升级。
- [XrayRP](https://github.com/Mtoly/XrayRP)：核心程序、发布包与镜像。
- [贡献指南](CONTRIBUTING.md) · [变更记录](CHANGELOG.md) · [安全文档](SECURITY.md)

主机服务以 `root:root` 运行。部署前审阅脚本、固定生产版本并备份配置；
不要提交 Token、私钥或证书，也不要将本地状态接口暴露到公网。安全报告流程见 [SECURITY.md](SECURITY.md)。

## License

[MPL-2.0](LICENSE)
