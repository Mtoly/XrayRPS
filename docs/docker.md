# Docker 部署

[返回首页](../README.md) · [Machine Mode](machine-mode.md)

## Compose 部署

先在 Linux 主机安装 [Docker Engine 与 Compose 插件](https://docs.docker.com/engine/install/)。
本仓库使用 [docker-compose.yml](../docker-compose.yml) 消费 XrayRP 镜像，不构建或发布镜像。

```bash
git clone https://github.com/Mtoly/XrayRPS.git
cd XrayRPS
vi config/config.yml
docker compose config
docker compose pull
docker compose up -d
docker compose ps
docker compose logs --tail=100 -f xrayr
```

启动前完成以下配置：

- 以 [config/config.yml](../config/config.yml) 为静态节点起点，替换面板、节点、凭据与监听地址。
- Machine 部署使用相应的 `MachineConfig`，不同时保留静态 `Nodes`；主机安装器不是容器管理入口。
- 将需要的辅助配置和证书准备在挂载的 `config/` 目录内，使用容器路径 `/etc/XrayR/...`。
- 当前静态示例没有 Observability 段。为 Compose 健康检查，在实际配置中添加以下段落。
  健康检查请求核心提供的 `/livez`；未启用接口时会显示 unhealthy。

```yaml
Observability:
  Enable: true
  Listen: "127.0.0.1:10085"
```

Compose 使用 host 网络、只读根文件系统、只读 `./config:/etc/XrayR` 挂载，
`/tmp` 与 `/run` tmpfs、`no-new-privileges` 和 `cap_drop: ALL`。
资源限制为 512 MB 内存与 1 CPU，重启策略为 `unless-stopped`。部署前确认核心需要的写入路径、证书及端口与这些约束兼容。
`docker compose config` 会展开配置；若配置包含敏感值，不要公开其输出。

## 默认 latest 与版本锁定

默认镜像为 `ghcr.io/mtoly/xrayrp:latest`，无需创建 `.env`。
`pull_policy: always` 在再次运行 Compose 时检查 registry；运行中的容器不会自动拉取或重建。

在 Compose 同目录的 `.env` 写入以下内容可固定版本（部署前确认该镜像 tag 存在）：

```dotenv
XRAYRP_TAG=0.9.5
```

也可临时指定；必须同时作用于 pull 和 up：

```bash
XRAYRP_TAG=0.9.5 docker compose pull
XRAYRP_TAG=0.9.5 docker compose up -d
```

环境变量优先于 `.env`。恢复 latest 时，将 `.env` 中的值改为 `latest`，同时检查 shell 是否仍设置了 `XRAYRP_TAG`。
版本变化后仍需重新执行 pull 和 up。

## 升级与回退

在 `docker-compose.yml` 所在目录执行。先备份配置、证书，记录当前明确的 tag 或镜像 digest，
并审阅目标版本；`latest` 本身不是可靠的历史恢复标识。

```bash
docker compose config
docker compose pull
docker compose up -d --remove-orphans
docker compose ps
docker compose logs --tail=100 xrayr
```

固定版本只有在修改 `XRAYRP_TAG` 后才切换；latest 会在以上步骤中重新解析。
回退时恢复记录的旧版本标识及兼容配置，再执行 pull、up、ps 和日志检查。
这些 Docker 操作没有主机安装器的事务回滚机制；旧镜像可用性与配置备份需要独立保证。

## 单容器部署

准备完整配置目录，并将 `PATH_TO_CONFIG` 替换为真实绝对路径；`XRAYRP_TAG` 可设置为已确认可用的版本。
以下方式不使用 Compose 的资源限制和健康检查，需要自行配置：

```bash
PATH_TO_CONFIG=/absolute/path/to/config
XRAYRP_TAG=latest
docker pull "ghcr.io/mtoly/xrayrp:${XRAYRP_TAG}"
docker run --detach --restart=unless-stopped --name xrayr \
  --read-only \
  --tmpfs /tmp:rw,noexec,nosuid,nodev \
  --tmpfs /run:rw,noexec,nosuid,nodev \
  --security-opt no-new-privileges:true --cap-drop=ALL \
  --volume "${PATH_TO_CONFIG}:/etc/XrayR:ro" --network=host \
  "ghcr.io/mtoly/xrayrp:${XRAYRP_TAG}"
docker logs --tail=100 -f xrayr
```

不要使用主机 `XrayR` 菜单启停、更新或卸载容器。安全与凭据处理规则见 [SECURITY.md](../SECURITY.md)。
