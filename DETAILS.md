# 详细文档

> 简介和快速开始见 [README.md](README.md)。

在 **简幻欢（simpfun）游戏面板** 的 Bedrock 实例里，用 **与官方镜像相同的流程** 部署 LeviLamina 26.60（BDS 1.26.60）。

脚本从**零**开始：装 Wine → 装运行库 → 跑官方 lip → lip install LeviLamina → 写配置 → 启动。

## 快速开始

1. 面板文件管理器上传 `start.sh`、`proxy.conf` 到实例根目录（`/home/container`）
2. 确认实例是 Bedrock 类型、Linux、Debian 系
3. 启动实例，等待 15~25 分钟（首次要下载 Wine 270MB + BDS 230MB）

完成后控制台会出现：

```
[ll] ===== 启动 LeviLamina =====
Game version 1.26.60+41512d4 with LeviLamina-26.60.6
```

## 代理开关（只作用于 GitHub）

**代理只用于 GitHub**：`lip.exe` 下载、`lip install` 拉取 BDS 和 LeviLamina。

**WineHQ、微软 dotnet CDN、VC++ 一律直连**，绝不套代理——它们国内可达，套代理反而更慢甚至失败。

默认不使用代理。容器内实测直连 GitHub 1.5~2.7 MB/s，一般够用。只有 GitHub 被限速或不可达时才打开，改 `proxy.conf`：

```
USE_PROXY=yes
PROXY_URL=http://192.168.1.100:7890     ← 必须是容器能访问到的地址
```

⚠️ **`PROXY_URL` 不能填 `127.0.0.1`**。简幻欢是远程容器，它里面的 `127.0.0.1` 指向容器自身，不是你的电脑，那里没有代理。填错时脚本会自动识别 loopback 并降级为直连，只打一条警告，不会把整个下载流程搞挂。

实现方式是按 URL 域名判断，不是设全局 `http_proxy`：

```sh
case "$url" in
  *github.com*|*githubusercontent.com*|*ghcr.io*) PAR="-x $GH_PROXY" ;;
esac
```

启动日志会打印当前状态：

```
[ll]   GitHub 代理：未启用（直连）
[ll]         如 GitHub 受限，在 /home/container/proxy.conf 写 USE_PROXY=yes 与 PROXY_URL=...
```

## 与官方镜像的对应关系

| 环节 | 官方镜像做法 | 本脚本 | 差异 |
|---|---|---|---|
| Wine | `wine-stable 11.0.0.0~bookworm-1` | 同版本（WineHQ deb） | 无 |
| VC++ | `winetricks -q vcrun2026` | 官方 `vc_redist` 静默安装 | 等价（同一安装包） |
| .NET | `winetricks -q dotnet10` | `dotnet-runtime-10.0.15` 静默安装 | **必须 10.0.15**，见下 |
| lip | `/opt/lip/lip.exe` | `lip 0.40.0 win-x64` | 无 |
| 安装 LL | `lip install github.com/LiteLDev/LeviLamina` | 同 | 无 |
| 启动 | `(cat \| wine bedrock_server_mod.exe)` | FIFO 转发 stdin 后前台运行 | 见「stop 后实例不退出」 |

## 两个必须知道的坑

### 1. netherNetPatch 必须关闭

这是**进不去游戏（Door）**的根因，且与官方流程不冲突——原生 BDS 根本不使用 STUN。

原生 BDS 只登录微软 NetherNet 信令服务（启动日志 `Signed in to signaling service successfully`），对外地址由信令侧处理，所以在普通 NAT/端口映射下正常。

但 **LeviLamina 的 `netherNetPatch`** 为了实现单端口，自己引入了 STUN 探测。在简幻欢的中转架构下，它探到的是**容器出口侧错误地址**（如 `198.51.100.20:随机端口`）并写进 NetherNet 信令，而玩家连的是 `入口IP:端口`，于是客户端报 Door。

脚本第 6 步会自动改：

```sh
sed -i '/"netherNetPatch"/,/}/ s/"enable": *true/"enable": false/' Config.json
```

并写入三段式端口声明：

```properties
server-port=19132
server-udp-ports=203.0.113.10:19132:19132
```

⚠️ `server-udp-ports` 里的**入口 IP 是硬编码的**。如果简幻欢给你换了入口 IP，必须同步改 `start.sh` 的 `PUBLIC_IP`，否则 Door 会回来。

⚠️ **每次重装 LL，lip 都会把 `netherNetPatch.enable` 重置为 `true`**，所以这步不能只做一次。

### 2. .NET 必须是 10.0.15，不能是 10.0.0

`winetricks` 的 `dotnet10` 配方写的是 `10.0.0`，但 lip 0.40.0 的 apphost 要求 **10.0.14+**。装 10.0.0 会在跑 lip 时报：

```
File name: 'C:\Program Files\dotnet\shared\Microsoft.NETCore.App\10.0.0\System.Runtime.dll'
wine: Unhandled exception 0xe0434352
```

随后 `WineDbg attached` 会接管进程，**堵死后续所有 wine 调用**（表现为卡在 `lip config set` 不动）。

脚本因此：
- 装 `10.0.15`
- 启动前先 `wineserver -k` + 杀 `winedbg`
- 禁用崩溃弹窗（`ShowCrashDialog=0`）
- 所有 lip 调用带超时

## 其他注意事项

**i386 运行库必须有**

Wine 的 32 位子系统（syswow64）依赖系统 `/lib/ld-linux.so.2`。缺失会导致 vcrun/dotnet 安装全部失败、lip 无法运行。脚本会检测并尝试 `apt-get install libc6:i386` 补齐；简幻欢镜像自带，一般无需处理。

**面板用 `sh`（dash）执行脚本，不是 bash**

脚本必须同时通过：

```sh
bash -n start.sh && dash -n start.sh
```

否则会出现 `寻找匹配的 " 时遇到了未预期的 EOF`。

**容器里没有可用的 `python3`**

它在 `/mise/shims/python3`，非交互 shell 的 PATH 里没有。所以配置改写一律用 POSIX `sed`，不要用 python heredoc（会静默失败）。

**stop 后实例停不下来**

`(cat | wine bedrock_server_mod.exe)` 里的 `cat` 会一直阻塞在 stdin 上，BDS 退出后脚本不结束，面板就一直显示运行中。脚本改用 FIFO 转发 stdin，BDS 一退出就 `wineserver -k` 并 `exit`。

**下载源实测结论（容器内，直连）**

| 源 | 速度 | 用在哪 |
|---|---|---|
| GitHub 直连 | 1.5~2.7 MB/s | lip、BDS、VC++ Release |
| gh-proxy.com | 62 KB/s | ❌ 不用（比直连慢） |
| ghproxy.net | 13 KB/s | ❌ 不用 |
| 清华 wine 镜像 | **403** | ❌ 容器网段被拒 |
| WineHQ 官方 | 3.7~5.4 MB/s | wine 三包 |
| 微软 dotnet CDN | 2.2 MB/s | .NET 10.0.15 |
| **微软 aka.ms（VC++）** | **48 KB/s** ⚠️ | ❌ 太慢，已镜像到 Release |

所以脚本**不用任何镜像站或加速站**，直连最快。唯一例外是 VC++ 运行库——微软在国内把它限速到 48 KB/s（18MB 要 9 分钟），所以镜像到本仓库的 Release，实测 2.7 MB/s，快 57 倍：

```
https://github.com/ZYDMYHZ/simpfun-levilamina-deploy/releases/tag/vc-runtime-2026
```

## 初始化重装

| 目标 | 删什么 | 耗时 |
|---|---|---|
| 完全从零 | `ll-server/` + `wine-stable11/` | 15~25 分钟 |
| 只重装 LL | `ll-server/` 里的 `bedrock_server_mod.exe`、`mods/`、`tooth_lock.json`、`.lip/` | 8~10 分钟 |
| 只重置配置 | `ll-server/server.properties`、`ll-server/mods/LeviLamina/config/Config.json` | 几秒 |
| 只重置运行库 | `ll-server/.wine-official/` | 5~8 分钟 |

⚠️ `ll-server/worlds/` 是地图存档，删之前先备份。

## 文件说明

| 文件 | 作用 |
|---|---|
| `start.sh` | 主脚本，六步幂等安装 + 启动 |
| `proxy.conf` | 代理开关配置 |
| `server.properties` | 服务端配置模板（端口、正版验证、白名单） |
| `Config.json` | LeviLamina 配置参考（已关闭 netherNetPatch） |
