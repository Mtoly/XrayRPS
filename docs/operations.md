# 主机运维

[返回首页](../README.md) · [Machine Mode](machine-mode.md) · [Docker](docker.md)

以下安装与服务命令在 root 终端执行，适用于主机部署。容器使用 Docker / Compose 命令。

## 运行条件

三个入口 `install.sh`、`install-machine.sh` 和 `XrayR.sh` 使用相同的 init 识别规则：

| 管理器 | 必须满足的条件 |
| --- | --- |
| systemd | 存在 `/run/systemd/system`，可调用 `systemctl`，且 `systemctl show --property=Version --value` 成功 |
| OpenRC | `/run/openrc/softlevel` 非空，且存在 `rc-service`、`rc-update`、`supervise-daemon` |

两者同时满足时优先使用 systemd；均不满足时报告缺少的运行条件。不会仅按发行版名称选择管理器。
在 Alpine 上安装 `systemctl`，或手动创建 systemd 目录，都不能替代真正运行的 init 系统。
Alpine/OpenRC 主机先准备 `apk add --no-cache bash curl`。

## 配置、版本与更新

```bash
XrayR version
XrayR config
XrayR restart
XrayR update 0.9.5
XrayR status
```

`XrayR config` 使用 vi 编辑，保存后需手动重启。没有版本参数的 `XrayR update` 使用最新版。
`0.9.5` 与 `v0.9.5` 都解析为无前缀的 release tag `0.9.5`；该版本仍须提供可下载的发布包及 `SHA256SUMS`。
标准安装器也支持 `bash install.sh 0.9.5`。

普通更新保留已有 `/etc/XrayR/config.yml`，包括 Machine ID、Token、ApiHost。
更新前仍应单独备份整个配置目录、证书和部署版本；Machine 安装器的 `--force` 有不同语义，见 [Machine Mode](machine-mode.md)。

| 路径 | 用途 |
| --- | --- |
| `/usr/local/XrayR/XrayR` | 核心二进制 |
| `/etc/XrayR/config.yml` | 主配置 |
| `/etc/XrayR/` | 辅助配置与证书 |
| `/var/lib/xrayr/` | 服务可写数据目录 |
| `/usr/bin/XrayR`、`/usr/bin/xrayr` | 管理命令与别名 |
| `/etc/systemd/system/XrayR.service` | systemd unit |
| `/etc/init.d/XrayR` | OpenRC 服务脚本 |

配置示例见 [config/](../config/)，不要直接使用示例凭据。文件、证书与配置路径应与实际部署一致。

## systemd 故障恢复

当前 [XrayR.service](../XrayR.service) 使用 `root:root`，工作目录为 `/usr/local/XrayR/`，
执行 `/usr/local/XrayR/XrayR --config /etc/XrayR/config.yml`；异常退出等待 10 秒重启，保留 unit 中的沙箱限制。

早期专用 `xrayr` 账户部署可能出现 `status=217/USER`，或监听 TCP 80/443 时出现 `bind: permission denied`。
确认故障属于账户或文件权限问题后，可按以下步骤恢复。先备份配置及 unit；本操作会调整这些目录内的属主与权限。

```bash
sed -i -E \
  -e 's/^User=.*/User=root/' \
  -e 's/^Group=.*/Group=root/' \
  /etc/systemd/system/XrayR.service

install -d -o root -g root -m 0750 /etc/XrayR /var/lib/xrayr
chown -R root:root /usr/local/XrayR /etc/XrayR /var/lib/xrayr
find /usr/local/XrayR /etc/XrayR /var/lib/xrayr -type d -exec chmod 0750 {} +
find /usr/local/XrayR /etc/XrayR /var/lib/xrayr -type f -exec chmod 0640 {} +
chmod 0750 /usr/local/XrayR/XrayR

systemctl daemon-reload
systemctl reset-failed XrayR
systemctl restart XrayR
systemctl show XrayR -p User -p Group -p ActiveState -p SubState --no-pager
systemctl status XrayR --no-pager
journalctl -u XrayR -n 100 --no-pager
ss -ltnp | grep -E ':(80|443)([[:space:]]|$)'
```

安装与升级不依赖专用 `xrayr` 账户，也不会删除已有的该用户或用户组。其他故障需依据日志排查。

## OpenRC 进阶管理

原生 [XrayR.openrc](../XrayR.openrc) 使用 OpenRC 自带 `supervise-daemon`，以 `root:root` 运行相同命令与工作目录。
PID 文件为 `/run/XrayR.pid`；异常退出后等待 10 秒重新启动。
服务声明 `need net`、`use dns`、`after firewall`，实际开机顺序仍取决于主机的网络与 runlevel 配置。

```bash
XrayR start
XrayR stop
XrayR restart
XrayR status
XrayR enable
XrayR disable
XrayR log
```

对应原生命令：

```bash
rc-service XrayR start
rc-service XrayR stop
rc-service XrayR restart
rc-service XrayR status
rc-update add XrayR default
rc-update show default
```

`XrayR disable` 检查 `default` runlevel，重复取消自启视为成功。直接使用
`rc-update del XrayR default` 时，服务已经不在该 runlevel 可能返回失败。

stdout 和 stderr 分别写入 `/var/log/XrayR/output.log` 与 `/var/log/XrayR/error.log`；
日志目录权限为 0750，文件为 0640。`XrayR log` 持续追踪两份日志，日志轮转需由主机运维配置。
OpenRC 不提供与 systemd unit 等效的命名空间沙箱。

## 下载失败与回滚

- 404：检查 XrayRP release tag、架构发布包和对应校验文件是否存在；不要跳过校验。
- init 检测失败：检查真实运行的管理器及上述命令，单独安装客户端命令不能替换 init。
- 启动失败：查看 systemd journal 或 OpenRC 日志，核对配置、凭据、证书与端口占用。
- 安装失败：安装器尝试恢复旧二进制、配置、服务定义与先前运行/自启状态；Machine 安装器还保护管理入口。
  恢复未完成时会报告错误及保留的恢复目录。保留现场，检查恢复后的版本、配置、状态和日志，再决定后续操作。
- 成功后临时事务备份会被清理，不能将其当作长期备份。恢复目录可能含 Token 或证书，不应公开上传。

`XrayR uninstall` 会询问确认，并删除安装目录及 `/etc/XrayR`。卸载前先独立备份配置、证书和必要日志。
不要使用 `bash -x` 记录含凭据的安装过程，相关处理规则见 [SECURITY.md](../SECURITY.md)。

## 隔离验证的边界

仓库提供不连接真实面板的 Alpine/OpenRC fixture：

```bash
docker build -f tests/alpine.Dockerfile -t xrayrps-openrc-test .
docker run --rm xrayrps-openrc-test
```

该测试使用本地进程 fixture，覆盖 OpenRC 进程管理与安装/回滚路径。
它不是生产 VPS、真实 PID 1 开机、主机重启、网络依赖或 XrayRP 节点端到端验收。
