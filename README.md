# icloudctl

开 / 关 macOS 的 iCloud 同步。命令行控制，语义直白：**`on` 就是打开同步，`off` 就是关闭同步。**

## 为什么需要它

macOS 里的 iCloud 同步（`bird` / `cloudd` / `nsurlsessiond`）是个**用户不可干预的后台事务系统**。
Apple 官方没给暂停按钮：`brctl` 全部子命令都是只读诊断（`status`/`dump`/`monitor`/`quota`），
没有任何 pause / throttle / prioritize 的写操作接口。

系统设置里那个「关闭 iCloud 云盘」开关**不是暂停键**，它是解除绑定 ——
点了会弹「从 Mac 中移除 / 保留副本」的对话框，风险很高。

本工具用 `SIGSTOP` / `SIGCONT` 冻结 / 解冻**负责搬数据的传输进程**（`nsurlsessiond` 等），
实现真正的可逆开关，同时不碰会让你卡在打开 / 保存对话框里的同步引擎 —— 细节见
[为什么默认不冻 `bird`](#为什么默认不冻-bird)。

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
icloudctl probe [次数]            # 实测界面是否被冻住（打开 / 保存对话框卡不卡）
icloudctl doctor                  # 环境自检
icloudctl off --deep              # 连 bird 一起冻（极限停同步，界面会卡）
icloudctl off --with-fileprovider # 关闭时连 fileproviderd 一起停（谨慎，见下）
```

### 典型场景

```bash
# 我要传大文件到别处，先腾出带宽
icloudctl off
icloudctl probe        # 顺手确认一下界面没被卡住
# ... 传完了 ...
icloudctl on
```

## 设计取舍

### 默认冻结集

```
cloudd          CloudKit（照片、备忘录等）
nsurlsessiond   后台传输 —— 真正搬字节的就是它
itunescloudd    Apple Music / iTunes Match
```

**刻意不含 `bird`**：它是同步引擎，冻它会让打开 / 保存对话框卡死（见下文
「为什么默认不冻 `bird`」）。传输照样停，因为数据走 `nsurlsessiond`。

### 默认不动 `fileproviderd`

`fileproviderd` 不只服务 iCloud —— **微信、照片（Photos）也用 FileProvider**。
冻住它可能让微信传文件、照片同步出现异常。

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

`on` 除了读状态文件，还会**兜底扫描所有已知守护进程**，凡是处于 `T`（停止）状态的都恢复一遍。
即使状态文件被删、机器重启过、上次 `--deep` 留下的残留，`on` 依然有效。

反向也做了防护：`off` 在动手之前会先扫一遍「处于 `T` 但不在本次目标集里」的进程，
把它们恢复掉，避免上次异常退出留下的僵尸冻结一直卡着界面。`doctor` 能查这份残留清单。

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

## 验证结果（macOS 26.5.1 本机实测）

```
off 前:  nsurlsessiond  out +1014479116  → 活动中
off 后:  nsurlsessiond  out +0           → 静止
on  后:  nsurlsessiond  out +345240555   → 活动中
```

v2 的关键验收（`bird` 不冻）：

```
icloudctl off
  已停止: cloudd nsurlsessiond itunescloudd
  bird 保持运行 —— 界面不会卡

icloudctl stat     → nsurlsessiond 静止  out +0
icloudctl probe 5  → 5 次全部 0.001~0.002s，无卡死
```

内核层面 `ps` 状态在 `T`（停止）和 `S`（运行）之间干净切换。

## 已知限制

- **不是限速器**，是开关。没有"只允许 1MB/s"这种能力。
- **管不了第三方上传**。它只停 iCloud 的进程；你的 `git push`、微信、Chrome 上传不受影响。
- **root 的 `cloudd --system` 停不了**（权限不足），但它与个人 iCloud 传输无关，不影响效果。
- **上传和下载同时停**。传输引擎只有一个，两个方向无法分开停 —— 这是特性不是缺陷。
  做不到「只上传、只下载」是 Apple 没给这个能力（见下节），不是本项目偷懒。
- **关闭多久，就不同步多久**。iCloud 会积压这段时间的变更；
  重新 `on` 之后 `bird` 需要追平，可能引发一次集中上传。这是预期行为，不是故障。
- **重启后会自动恢复同步**。`SIGSTOP` 是进程状态，机器重启后进程重建，同步自然回来。
  也就是说它是"本次开机内有效"的开关。
- **`nsurlsessiond` 是系统共享的**。冻住它可能连带暂停其他 App 的后台下载（App Store 等）。
  这是「停 iCloud 传输」必须付的代价 —— 因为数据就是这一个进程在搬。
- **需要 macOS 11+**（FileProvider 架构）。在 macOS 26 上实测通过。

## 为什么默认不冻 `bird`

这是本项目最重要的一条设计决定，也是 v1 的一个真实 bug。

`bird` 是 iCloud Drive 的**同步引擎**，但它**自己不联网**（`lsof` 看不到任何连接），
真正搬字节的是 `nsurlsessiond`。而 `bird` 还负责回答系统的一个同步查询：

```
-[NSFileManager ubiquityIdentityToken]
  → BRAccount currentCachedLoggedInAccount
    → __NSXPCCONNECTION_IS_WAITING_FOR_A_SYNCHRONOUS_REPLY__
```

**打开 / 保存对话框、Chromium / Electron 系 App（Steam、GeForce NOW）启动时都会调它。**
`bird` 一旦被 `SIGSTOP`，这个同步等待永远不会返回，整个 App 主线程卡死 —— 表现为
「点文件、弹出窗口、然后整个卡住」，直到你把 iCloud 开回来。

在 macOS 26.5.1 上实测（探测 `ubiquityIdentityToken`，超时 3 秒）：

| 单独冻结 | 平均延迟 | 结果 |
|---|---|---|
| `fileproviderd` | 0.000s | 无影响 |
| `cloudd` | 0.000s | 无影响 |
| `nsurlsessiond` | 0.000s | 无影响 |
| `itunescloudd` | 0.000s | 无影响 |
| **`bird`** | **1.66s（最坏 9.98s）** | **卡死** |

所以 v2 把 `bird` 从默认冻结集里拿掉了。`icloudctl off` 现在冻
`cloudd nsurlsessiond itunescloudd`，传输照样停住（因为字节走 `nsurlsessiond`），
界面不再卡。同一个实测：

```
off（默认）          传输 out +0（完全静止）     probe 最慢 0.002s
off --deep（v1 行为） 传输 out +0               probe 5/5 次卡死
```

`bird` 留在 `--deep` 里，给「宁可卡也要一滴不漏地停住同步」的场景用，并会在 `status`
和 `probe` 里明确警告。

## 关于「只上传 / 只下载」

**做不到，而且不是本项目的限制，是 macOS 没这个能力。** 查证结论：

1. **没有公开 API**。`brctl` 在 macOS 26 上只剩只读诊断
   （`status` / `dump` / `monitor` / `quota` / `accounts` / `diagnose` / `log`），
   `download` / `evict` 早在 macOS 14 就被 Apple 删了，且从未有过方向开关。
2. **`bird` 是单一双向引擎**。`com.apple.bird` 和 `com.apple.CloudDocs` 的偏好域里
   没有任何 upload / download / direction / pause 相关的键。
3. **网络层也切不开**。上传和下载走的是同一批主机、同一批 TLS 连接；
   走代理时（如 Clash 的 `127.0.0.1:7897`）pf 只能看到「到代理的连接」，
   连是不是 iCloud 都分不出，更别说方向。
4. **限速这条路也堵死**。`pf + dummynet` 在 macOS 26 已在内核层失效
   （`net.inet.ip.dummynet.searches` 恒为 0，规则被接受但内核不路由包），
   ALTQ 更早就移除了（`No ALTQ support in kernel`）。

如果你要的是「控制哪些文件同步」，那是**另一个问题**，用文件级工具更合适
（`icloud-tools` 的 pin/evict、`.nosync` 后缀等），本项目只做全局开关。

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

「冻 `bird` 会让 App 卡死」这个坑的排查，受益于
[ekremus/shycloud](https://github.com/ekremus/shycloud)（GPL-3.0）的记录与实测数据 ——
它用「每 2 秒放行 0.2 秒」的呼吸法缓解同一问题；本项目选择了另一条路
（干脆不冻 `bird`，只冻真正搬数据的 `nsurlsessiond`）。

## License

[MIT](LICENSE)
