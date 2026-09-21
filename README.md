# icloudctl

开 / 关 macOS 的 iCloud 同步。命令行控制，语义直白：**`on` 就是打开同步，`off` 就是关闭同步。**

## 为什么需要它

macOS 里的 iCloud 同步（`bird` / `cloudd` / `nsurlsessiond`）是个**用户不可干预的后台事务系统**。
Apple 官方没给暂停按钮：`brctl` 全部子命令都是只读诊断（`status`/`dump`/`monitor`/`quota`），
没有任何 pause / throttle / prioritize 的写操作接口。

系统设置里那个「关闭 iCloud 云盘」开关**不是暂停键**，它是解除绑定 ——
点了会弹「从 Mac 中移除 / 保留副本」的对话框，风险很高。

本工具用 `SIGSTOP` / `SIGCONT` 冻结 / 解冻同步引擎的进程，实现真正的可逆开关。

## 为什么不用 Clash / pf 限速

两条路都验证过，都不行：

| 方案 | 问题 |
|---|---|
| Clash 拦截 iCloud 域名 | Clash 一退出就失效，依赖一个不稳定组件 |
| pf + dummynet 限速 | **macOS 26 已在内核层失效**：`net.inet.ip.dummynet.searches` 恒为 0，规则被接受但内核不路由包 |
| ALTQ | 已被内核移除（`No ALTQ support in kernel`） |

`SIGSTOP` 不依赖网络层、不依赖代理、不依赖是否联网 —— 内核级冻结，进程冻住就是真冻住。

## 用法

```bash
icloudctl on     # 打开 iCloud 同步（恢复正常上传/下载）
icloudctl off    # 关闭 iCloud 同步（一直关着，直到手动 on）
```

辅助命令：

```bash
icloudctl status                  # 查看当前状态
icloudctl stat                    # 采样 3 秒流量，验证是否真的停了
icloudctl doctor                  # 环境自检
icloudctl off --with-fileprovider # 关闭时连 fileproviderd 一起停（谨慎，见下）
```

### 典型场景

```bash
# 我要传大文件到别处，先腾出带宽
icloudctl off
# ... 传完了 ...
icloudctl on
```

## 设计取舍

### 默认不动 `fileproviderd`

`fileproviderd` 不只服务 iCloud —— **微信、照片（Photos）也用 FileProvider**。
冻住它可能让微信传文件、照片同步出现异常。

所以默认目标只有 4 个纯粹的 iCloud 进程：

```
bird            iCloud Drive 主体
cloudd          CloudKit（照片、备忘录等）
nsurlsessiond   后台传输
itunescloudd    Apple Music / iTunes Match
```

需要时显式加：`icloudctl off --with-fileprovider`

### 关闭就是关闭，不会自己打开

`icloudctl off` 之后**会一直保持关闭**，除非你手动执行 `icloudctl on`。

没有计时器、没有后台守护、没有"忘了会怎样" —— 冻结是纯内核状态（`SIGSTOP`），
不依赖任何常驻进程。你关掉终端、关掉 Clash、休眠唤醒，都不影响它保持关闭。

这是刻意的设计：**开关就该是开关。**

如果你某次确实想要一道保险丝，可以显式开：

```bash
ICLOUDCTL_AUTO_RESUME_SECS=1800 icloudctl off   # 30 分钟后自动恢复
```

默认值是 `0`，即不启用。

### 幂等

重复 `off` 会提示已经是关闭状态，重复 `on` 会提示本来就是开启状态，都不会报错、不会重复操作。

### 状态丢失也能恢复

`on` 除了读状态文件，还会**兜底扫描所有目标进程**，凡是处于 `T`（停止）状态的都恢复一遍。
即使状态文件被删、机器重启过，`on` 依然有效。

## 安装

```bash
git clone https://github.com/JackAIStudio/icloudctl.git
cd icloudctl
./install.sh
```

默认装到 `~/.local/bin`。也可以用 Homebrew 风格的直接下载：

```bash
curl -fsSL https://raw.githubusercontent.com/JackAIStudio/icloudctl/main/icloudctl \
  -o ~/.local/bin/icloudctl && chmod +x ~/.local/bin/icloudctl
```

卸载就是删掉那个文件，加上 `rm -rf ~/.local/state/icloudctl` 清掉状态。

## 验证结果（本机实测）

```
off 前:  nsurlsessiond  out +1014479116  → 活动中
off 后:  nsurlsessiond  out +0           → 静止
on  后:  nsurlsessiond  out +345240555   → 活动中
```

内核层面 `ps` 状态在 `T`（停止）和 `S`（运行）之间干净切换。

## 已知限制

- **不是限速器**，是开关。没有"只允许 1MB/s"这种能力。
- **管不了第三方上传**。它只停 iCloud 的进程；你的 `git push`、微信、Chrome 上传不受影响。
- **root 的 `cloudd --system` 停不了**（权限不足），但它与个人 iCloud 传输无关，不影响效果。
- **上传和下载同时停**。引擎被冻住，两个方向都不会动 —— 这是特性不是缺陷。
- **关闭多久，就不同步多久**。iCloud 会积压这段时间的变更；
  重新 `on` 之后 `bird` 需要追平，可能引发一次集中上传。这是预期行为，不是故障。
- **重启后会自动恢复同步**。`SIGSTOP` 是进程状态，机器重启后进程重建，同步自然回来。
  也就是说它是"本次开机内有效"的开关。
- **需要 macOS 11+**（FileProvider 架构）。在 macOS 26 上实测通过。

## 文件位置

```
icloudctl                                  主程序（单文件 bash，无依赖）
install.sh                                 安装脚本
~/.local/state/icloudctl/frozen.state      关闭状态记录
~/.local/state/icloudctl/icloudctl.log     操作日志
~/.local/state/icloudctl/                  可用 ICLOUDCTL_STATE_DIR 覆盖
```

## 安全说明

这个工具用 `SIGSTOP` 信号冻结进程，**不需要 sudo、不修改系统文件、不装内核扩展、
不碰网络配置**。所有状态只写在 `~/.local/state/icloudctl/`。

冻结是发送标准 Unix 信号给**你自己拥有的**进程，随时 `on` 即可完整恢复。

## 致谢

核心思路参考 [viktor-svirsky/hotspot-mode](https://github.com/viktor-svirsky/hotspot-mode)（MIT）。
本项目在其基础上改为**面向日常的手动开关**（而非热点模式自动触发），并增加了
纯内核态保持（无定时器、无守护进程）、幂等处理、流量验证和 `fileproviderd` 隔离。

## License

[MIT](LICENSE)
