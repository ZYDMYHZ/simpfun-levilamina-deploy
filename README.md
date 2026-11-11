# 简幻欢 LeviLamina 一键部署

在**简幻欢** Bedrock 实例里，用**与官方镜像相同的流程**部署 LeviLamina 26.60（BDS 1.26.60）。

## 快速开始

1. 上传 `start.sh`、`console_fwd.py`、`proxy.conf` 到实例根目录（面板里的 `/`）
2. 复制 `server.env.example` 为 `server.env`，填服务器 IP
   ```ini
   PUBLIC_IP=1.2.3.4
   ```
3. 启动实例，等 15~25 分钟

看到这行就成功了：

```
Game version 1.26.60+41512d4 with LeviLamina-26.60.6
```

## 它会做什么

从零开始：装 Wine 11 → 装 VC++ / .NET 运行库 → 跑官方 lip → `lip install` LeviLamina → 写配置 → 启动。

所有东西直接铺在实例根目录（和社区整合包一个结构）：`bedrock_server_mod.exe`、`mods/`、`server.properties`、`.wine-official/`。

与官方镜像 `ghcr.io/liteldev/levilamina-server:latest-wine` 同一套流程，只是把 winetricks 换成了等价的微软官方安装包。

## 控制台

面板里可以直接输 `stop`、`list` 这类命令。

BDS 拿到的是**管道 stdin**（由 `console_fwd.py` 转发），不是 tty —— wine 给 tty 会在启动阶段卡死，给 `/dev/null` 又收不到命令。

## 两个关键点

| 项 | 为什么 |
|---|---|
| **自动关闭 `netherNetPatch`** | LL 的这个补丁会用 STUN 探到容器的错误出口地址并写进 NetherNet 信令，简幻欢直通端口下客户端必然报 **Door**。原生 BDS 不用 STUN |
| **自动写 `server-udp-ports`** | 显式声明真实入口 `入口IP:端口:端口`，玩家才能真正连上。`lip install` 会把这项重置成 `19132`，所以每次启动都重写 |

## 注意

- **只填一个 IP**：`server.env` 里只有 `PUBLIC_IP`。端口用面板注入的 `SERVER_PORT`，不用手填
- 简幻欢换了入口 IP 就要同步改 `server.env`，否则客户端报 Door
- `netherNetPatch` 在**启动前**和 **BDS 退出后**各修正一次。`Config.json` 由 LeviLamina 自己生成，所以第一次跑完才会被关掉，之后每次启动读到的都是 `false`

## 代理

默认直连，一般不需要。GitHub 受限时才改 `proxy.conf`：

```sh
USE_PROXY=yes
PROXY_URL=http://192.168.1.100:7890    # 必须是容器能访问到的地址
```

⚠️ 不能填 `127.0.0.1` —— 容器里的 `127.0.0.1` 是容器自己，那里没有代理。填错脚本会自动降级为直连。

## 详细文档

官方流程逐项对照、所有踩过的坑、下载源实测速度、重装方法 → **[DETAILS.md](DETAILS.md)**
