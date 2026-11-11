#!/usr/bin/env bash
# ==============================================================================
# 简幻欢 AIO · LeviLamina 一键部署脚本（幂等，可反复执行）
#
# 完整复刻官方镜像 ghcr.io/liteldev/levilamina-server:latest-wine 的流程：
#   wine-stable 11.0 → 全新 WINEPREFIX → vcrun2026 → .NET 10 → lip install → 启动
#
# 【必改两项】
#   PUBLIC_IP : 面板给你的入口 IP（把面板地址里的域名 dig 一下取 A 记录）
#   PORT      : 面板分配给你的端口号（若面板注入了 SERVER_PORT 环境变量则自动使用）
#
# 【为什么必须这两项】
# 简幻欢是中转架构：容器出站 UDP 的公网 IP ≠ 玩家入口 IP。
# 原生 BDS 不用 STUN（它只登录微软信令服务），所以官方镜像在普通 NAT 下没问题；
# 但 LeviLamina 的 netherNetPatch 为了实现单端口，自己引入了 STUN 探测对外地址，
# 在这种中转架构下探到的是出口侧的错误地址并写进 NetherNet 信令，
# 客户端照着打洞必然失败 → 报 Door。
# 因此必须关掉 netherNetPatch（回到原生逻辑），并用 server-udp-ports 三段式显式声明真实入口。
# ==============================================================================

# ================= 代理开关（仅用于 GitHub，启动前可手动选择）=================
# 重要：代理**只作用于 GitHub**（lip.exe 下载、lip install 拉取 BDS/LeviLamina）。
#      WineHQ、微软 dotnet CDN、VC++ 一律直连 —— 它们国内可达且套代理反而更慢或失败。
# 两种改法，任选其一：
#   A) 直接改下面两行默认值
#   B) 在本脚本同目录建 proxy.conf（优先级更高），内容例如：
#        USE_PROXY=yes
#        PROXY_URL=http://192.168.1.100:7890    ← 必须是容器能访问到的地址
#      ⚠️ 不能填 127.0.0.1：容器里的 127.0.0.1 指向容器自身，那里没有代理。
# 说明：容器内直连 GitHub 实测 1.5MB/s，通常无需代理；仅在 GitHub 被限速/不可达时才开。
USE_PROXY="${USE_PROXY:-no}"
PROXY_URL="${PROXY_URL:-}"   # 留空=不填；要填必须填「容器能访问到的」地址，不是本机的 127.0.0.1
_CONF="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/proxy.conf"
[ -f "$_CONF" ] && . "$_CONF"

# 实例入口信息：优先环境变量，其次同目录 server.env，都没有则留空（下方会提示）
_ENV="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/server.env"
[ -f "$_ENV" ] && . "$_ENV"
# ============ 入口参数 ============
# SERVER_PORT  端口，简幻欢面板自动注入（= 实例端口），不用手填
# PUBLIC_IP    唯一要填的：玩家连接用的外部入口 IP
PORT="${SERVER_PORT:-19132}"
PUBLIC_IP="${PUBLIC_IP:-}"
# 写进 server.properties 的三段式：外部IP:外部端口:内部端口（直通，外=内）
UDP_PORTS="${PUBLIC_IP}:${PORT}:${PORT}"

# ------------------------------------------------------------------ 内部变量
BASE_DIR="/home/container"
LL="$BASE_DIR"          # 直接在根目录部署，不套 ll-server 子目录
WS="$BASE_DIR/wine-stable11"
LOG="$BASE_DIR/ll-install.log"
export WINEPREFIX="$BASE_DIR/.wine-official"
export WINEARCH=win64
export WINEDEBUG=-all
# wine 是 dpkg -x 解包到自定义前缀的，二进制仍按编译期路径 /opt/wine-stable 找库，
# 不显式指定就会报 "could not load kernel32.dll, status c0000135"
export WINELOADER="$WS/opt/wine-stable/bin/wine"
export WINESERVER="$WS/opt/wine-stable/bin/wineserver"
export WINEDLLPATH="$WS/opt/wine-stable/lib/wine"
export WINEDATADIR="$WS/opt/wine-stable/share/wine"
# ⚠️ 绝对不要全局设置 WINEDLLOVERRIDES="mscoree,..."。
# lip.exe 是 .NET apphost（PE32+ x64、内嵌 hostfxr，CLR 头为 0），运行时要靠 mscoree
# 加载 System.Runtime.dll 等托管程序集。全局禁掉 mscoree 会让 lip 一启动就抛
#   System.IO.FileNotFoundException: Could not load file or assembly
#   '...\Microsoft.NETCore.App\10.0.15\System.Runtime.dll'
#   wine: Unhandled exception 0xe0434353 ... starting debugger...
# 官方镜像的 lip wrapper 只有一句 `wine /opt/lip/lip.exe "$@"`，从不设这个变量。
# 只在 wineboot 首次建 prefix 那一次用命令级 override（防 mono/gecko 弹窗挂死），见第 2 步。
WINEBOOT_OVERRIDES="mscoree,mshtml="
# 与简幻欢上跑得通的整合包一致：只禁这两个无关组件（wine 的菜单构建器与 explorer），
# 不碰 mscoree —— 碰了 lip 就起不来。
export WINEDLLOVERRIDES="winemenubuilder.exe=d,explorer.exe=d"
# 显式指明 Windows 侧 .NET 位置，避免 apphost 找不到 runtime
export DOTNET_ROOT='C:\Program Files\dotnet'
export DOTNET_ROOT_X64='C:\Program Files\dotnet'
export DOTNET_MULTILEVEL_LOOKUP=1
export EULA=TRUE
export VERSION=LATEST

WINE_BASE="${WINE_BASE:-https://dl.winehq.org/wine-builds/debian/pool/main/w/wine}"
WINE_BASE_FALLBACK="https://dl.winehq.org/wine-builds/debian/pool/main/w/wine"
WINE_VER="11.0.0.0~bookworm-1"
LIP_VER="0.40.0"
GH_MIRROR="${GH_MIRROR:-}"   # 留空=直连 GitHub（实测最快 1.5MB/s；加速站反而只有 60KB/s）
# VC++ 运行库：微软 aka.ms 在国内被限速到 ~48KB/s（18MB 要 9 分钟），
# 因此镜像到本仓库 Release（实测 2.7MB/s），失败再回退微软原始地址。
VC_REPO="https://github.com/ZYDMYHZ/simpfun-levilamina-deploy/releases/download/vc-runtime-2026"
VC_X86="${VC_X86:-${VC_REPO}/vc_redist.x86.exe}"
VC_X64="${VC_X64:-${VC_REPO}/vc_redist.x64.exe}"
VC_X86_FB="https://aka.ms/vc14/vc_redist.x86.exe"
VC_X64_FB="https://aka.ms/vc14/vc_redist.x64.exe"
# .NET 运行时：优先华为云镜像，失败回退官方 CDN
DN_MIRROR="${DN_MIRROR:-https://builds.dotnet.microsoft.com/dotnet}"   # 华为云无此路径(返回HTML)，用官方CDN
DN_OFFICIAL="https://builds.dotnet.microsoft.com/dotnet"
DN_X86="${DN_MIRROR}/Runtime/10.0.15/dotnet-runtime-10.0.15-win-x86.exe"
DN_X64="${DN_MIRROR}/Runtime/10.0.15/dotnet-runtime-10.0.15-win-x64.exe"
DN_X86_FB="${DN_OFFICIAL}/Runtime/10.0.15/dotnet-runtime-10.0.15-win-x86.exe"
DN_X64_FB="${DN_OFFICIAL}/Runtime/10.0.15/dotnet-runtime-10.0.15-win-x64.exe"

log(){ printf '[ll] %s\n' "$*"; printf '[ll] %s\n' "$*" >>"$LOG"; }

# 统一下载函数：带超时、重试、实时进度条（显示在面板控制台）
dl(){  # dl <url> <outfile> [min_bytes]
  local url="$1" out="$2" min="${3:-1024}" i total sz pct mon name
  name=$(basename "$out")
  # 已存在的文件也要满足最小体积，否则视为上次残留的坏文件
  if [ -s "$out" ] && [ "$(stat -c%s "$out" 2>/dev/null || echo 0)" -ge "$min" ]; then
    log "   已存在 $name ($(stat -c%s "$out") 字节)"; return 0
  fi
  [ -s "$out" ] && { log "   清理残留的坏文件 $name"; : > "$out"; }

  # 先取文件总大小，用于算百分比（取不到就退化成只显示已下载量）
  total=$(curl -fsIL --connect-timeout 15 --max-time 40 "$url" 2>/dev/null \
          | awk 'BEGIN{IGNORECASE=1}/^content-length:/{v=$2} END{gsub(/\r/,"",v); print v+0}')
  [ -z "$total" ] && total=0

  # 只有 GitHub 域名才套代理
  PAR=""
  case "$url" in
    *github.com*|*githubusercontent.com*|*ghcr.io*) [ -n "$GH_PROXY" ] && PAR="-x $GH_PROXY" ;;
  esac

  # 断点续传：失败后保留已下载部分，用 curl -C - 接着下。
  # 之前这里每次都 `: > "$out"` 清空，导致大文件（.NET 运行时 ~55MB）
  # 在 8~12MB 处被重置后永远从 0 重来，看起来像「反复中断」。
  for i in 1 2 3 4 5 6; do
    log "   下载 $name (第 $i 次)${total:+，共 $((total/1048576)) MB}"
    if [ "$i" -gt 1 ] && [ -s "$out" ]; then
      log "      续传：沿用已下载的 $(stat -c%s "$out" 2>/dev/null) 字节"
    fi
    # 后台监视文件增长，每 2 秒往控制台刷一次进度
    (
      tick=0
      while :; do
        sz=$(stat -c%s "$out" 2>/dev/null || echo 0)
        if [ -t 1 ]; then
          # 终端里用回车原地刷新
          if [ "$total" -gt 0 ]; then
            pct=$((sz * 100 / total))
            printf '\r[ll]   %s  %3d%%  %d/%d MB' "$name" "$pct" "$((sz/1048576))" "$((total/1048576))"
          else
            printf '\r[ll]   %s  %d MB' "$name" "$((sz/1048576))"
          fi
          sleep 2
        else
          # 非终端（写日志文件）每 15 秒打一行
          tick=$((tick + 1))
          if [ $((tick % 8)) -eq 0 ]; then
            if [ "$total" -gt 0 ]; then
              pct=$((sz * 100 / total))
              printf '[ll]   %s  %3d%%  %d/%d MB\n' "$name" "$pct" "$((sz/1048576))" "$((total/1048576))"
            else
              printf '[ll]   %s  %d MB\n' "$name" "$((sz/1048576))"
            fi
          fi
          sleep 2
        fi
      done
    ) &
    mon=$!
    local t0=$(date +%s)
    if curl -fL $PAR --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 1800 \
         -C - -o "$out" "$url" >>"$LOG" 2>&1; then
      kill "$mon" 2>/dev/null; wait "$mon" 2>/dev/null
      sz=$(stat -c%s "$out" 2>/dev/null || echo 0)
      # 内容校验：大小不足通常是镜像返回了 HTML 错误页
      if [ "$sz" -lt "$min" ]; then
        printf '\r[ll]   %s  内容异常：仅 %d 字节（期望 >=%d），判定为错误页\n' "$name" "$sz" "$min"
        log "   内容异常 $name ($sz < $min)，换源重试"
        : > "$out"; kill "$mon" 2>/dev/null
        continue
      fi
      # exe 必须是 MZ 头
      case "$out" in
        *.exe)
          if [ "$(head -c 2 "$out" | od -An -tx1 | tr -d ' \n')" != "4d5a" ]; then
            printf '\r[ll]   %s  非有效 exe（无 MZ 文件头），判定为错误页\n' "$name"
            log "   非有效 exe $name，换源重试"
            : > "$out"; kill "$mon" 2>/dev/null
            continue
          fi
          ;;
      esac
      local dt=$(( $(date +%s) - t0 )); [ "$dt" -lt 1 ] && dt=1
      printf '\r[ll]   %s  100%%  %d MB  完成（%d 秒，约 %d KB/s）\n' \
        "$name" "$((sz/1048576))" "$dt" "$((sz/1024/dt))"
      log "   完成 $name ($sz 字节, ${dt}s, $((sz/1024/dt)) KB/s)"
      return 0
    fi
    kill "$mon" 2>/dev/null; wait "$mon" 2>/dev/null
    sz=$(stat -c%s "$out" 2>/dev/null || echo 0)
    printf '\r[ll]   %s  第 %d 次中断（已存 %d MB）\n' "$name" "$i" "$((sz/1048576))"
    log "   第 $i 次失败（已存 $sz 字节），3 秒后续传"
    sleep 3
  done
  log "   !! 下载失败: $url"
  return 1
}

# 安装器执行：加超时，避免 wine 弹窗/挂起时无限等待
wr(){  # wr <exe> [args...]  静默安装器：带心跳，避免长静默
  local exe="$1"; shift
  local nm of
  nm=$(basename "$exe")
  of="/tmp/wr_$(printf '%s' "$nm" | tr -cd 'A-Za-z0-9._-' ).out"
  log "   安装 $nm（静默模式，每 5 秒报进度）"
  # runb 内部已带 </dev/null：wine 的 console 程序不等 stdin 才会正常退出
  runb "$nm" 1200 "$of" timeout 1220 xvfb-run -a wine "$exe" "$@"
  local rc=$?
  [ $rc -eq 124 ] && log "   !! 超时(1200s)被终止: $nm"
  return $rc
}

# 带心跳的后台执行器：解决「xvfb-run/wine 卡在退出、面板上长时间零输出」的问题。
# 每 5 秒打印一次已运行秒数与产出字节数，超时则强制结束（含 Xvfb / wineserver 清理）。
runb(){  # runb <描述> <超时秒> <输出文件> <命令...>
  local d="$1" t="$2" f="$3"; shift 3
  : > "$f"
  ( "$@" </dev/null >>"$f" 2>&1 ) &
  local p=$! e=0
  while kill -0 "$p" 2>/dev/null && [ "$e" -lt "$t" ]; do
    sleep 5; e=$((e + 5))
    if kill -0 "$p" 2>/dev/null; then
      log "   … $d 运行中 ${e}s（输出 $(wc -c < "$f" 2>/dev/null || echo 0) 字节）"
    fi
  done
  if kill -0 "$p" 2>/dev/null; then
    log "   !! $d 超过 ${t}s，强制结束"
    kill -TERM "$p" 2>/dev/null
    sleep 2
    kill -KILL "$p" 2>/dev/null
    wineserver -k 2>/dev/null || true
    pkill -f "Xvfb :" 2>/dev/null || true
  fi
  wait "$p" 2>/dev/null
  local rc=$?
  tr -d '\000' < "$f" | tail -8
  return $rc
}

# 带超时与面板反馈的 registry 操作（wine reg 每次都要拉起一个 wine 进程，无头下可能很慢）
regop(){  # regop <描述> <reg 子命令及参数...>
  local d="$1"; shift
  if timeout 90 xvfb-run -a wine reg "$@" </dev/null >>"$LOG" 2>&1; then
    log "      $d ✓"
  else
    log "      $d 失败（不中断，继续）"
  fi
}

mkdir -p "$LL"
cd "$LL" || { echo "无法进入 $LL"; exit 1; }
# 端口来源提示：简幻欢面板会注入 SERVER_PORT，正常无需手填
if [ -n "${SERVER_PORT:-}" ]; then
  _port_src="面板 SERVER_PORT"
elif [ "$PORT" = "19132" ]; then
  _port_src="!! 未收到 SERVER_PORT，退回默认 19132"
else
  _port_src="server.env"
fi
log "===== 启动 $(date '+%F %T') | 监听 ${PORT}（${_port_src}）| 外部入口 ${PUBLIC_IP:-未设置}:${PORT} ====="

# 代理只赋给 GH_PROXY，绝不写进全局 http_proxy（否则 WineHQ/dotnet 也会被套代理）
GH_PROXY=""
if [ "$USE_PROXY" = "yes" ]; then
  case "$PROXY_URL" in
    "")
      log "   !! USE_PROXY=yes 但 PROXY_URL 为空，已自动降级为直连"
      ;;
    *127.0.0.1*|*localhost*|*::1*)
      log "   !! PROXY_URL=$PROXY_URL 无效：容器里的 127.0.0.1 是容器自己，不是你的电脑"
      log "      请填容器能访问到的代理地址（例如局域网内代理机的 IP），已自动降级为直连"
      ;;
    *)
      GH_PROXY="$PROXY_URL"
      ;;
  esac
fi
if [ -n "$GH_PROXY" ]; then
  log "   GitHub 代理：已启用 $GH_PROXY（仅 GitHub；WineHQ/dotnet/vcrun 仍直连）"
else
  log "   GitHub 代理：未启用（直连）"
  log "         如 GitHub 受限，在 $BASE_DIR/proxy.conf 写 USE_PROXY=yes 与 PROXY_URL=..."
fi

# 清理上次异常退出残留的 wine 进程，否则 winedbg 会阻塞后续所有调用
"$WS/opt/wine-stable/bin/wineserver" -k 2>/dev/null || true
pkill -f winedbg 2>/dev/null || true
sleep 1

# ------------------------------------------------------------------ 1. wine
# 注意：amd64 与 i386 两个包缺一不可。缺 i386 会导致 syswow64 缺失，
#       进而 vcrun / dotnet 的所有安装器都以 exit 1 失败（历史上踩过这个坑）。
if [ ! -d "$WS/opt/wine-stable/lib/wine/i386-windows" ]; then
  log "1/6 安装 wine-stable ${WINE_VER}（amd64 + i386）"
  mkdir -p "$WS"
  dl "$WINE_BASE/wine-stable_${WINE_VER}_amd64.deb"       /tmp/ws.deb       1500000       || \
    dl "$WINE_BASE_FALLBACK/wine-stable_${WINE_VER}_amd64.deb"       /tmp/ws.deb 1500000
  dl "$WINE_BASE/wine-stable-amd64_${WINE_VER}_amd64.deb" /tmp/ws-amd64.deb 100000000 || \
    dl "$WINE_BASE_FALLBACK/wine-stable-amd64_${WINE_VER}_amd64.deb" /tmp/ws-amd64.deb 100000000
  dl "$WINE_BASE/wine-stable-i386_${WINE_VER}_i386.deb"   /tmp/ws-i386.deb   90000000   || \
    dl "$WINE_BASE_FALLBACK/wine-stable-i386_${WINE_VER}_i386.deb"   /tmp/ws-i386.deb 90000000
  for f in /tmp/ws.deb /tmp/ws-amd64.deb /tmp/ws-i386.deb; do
    if [ -f "$f" ]; then
      log "   解包 $(basename "$f") ($(du -h "$f" 2>/dev/null | cut -f1))"
      dpkg -x "$f" "$WS"
    fi
  done
  log "   解包完成"
  log "   i386-windows 文件数: $(ls "$WS/opt/wine-stable/lib/wine/i386-windows" 2>/dev/null | wc -l)"
fi
export PATH="$WS/opt/wine-stable/bin:$PATH"
log "   wine: $(wine --version 2>&1)"

# ------------------------------------------------------------------ 1.5 i386 运行库
# wine 的 syswow64 依赖系统 32 位动态链接器；缺它会导至 vcrun/dotnet 安装全部失败
if [ ! -f /lib/ld-linux.so.2 ] && [ ! -f /lib32/ld-linux.so.2 ]; then
  log "   !! 系统缺 i386 运行库（ld-linux.so.2），wine 32 位子系统无法初始化"
  log "      后果：vcrun/dotnet 安装失败 → lip 无法运行"
  if command -v dpkg >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    log "      尝试自动补齐 libc6:i386 ..."
    dpkg --add-architecture i386 >>"$LOG" 2>&1 || true
    apt-get update -qq >>"$LOG" 2>&1 || true
    if apt-get install -y -qq libc6:i386 >>"$LOG" 2>&1; then
      log "      补齐成功"
    else
      log "      补齐失败（若系统为只读，需由面板镜像自带 i386，简幻欢已自带）"
    fi
  fi
else
  log "   i386 运行库正常"
fi

# ------------------------------------------------------------------ 2. prefix
# 自检：wine 能否找到自己的 DLL（缺 WINEDLLPATH 时这里就会失败）
if [ ! -f "$WS/opt/wine-stable/lib/wine/x86_64-windows/kernel32.dll" ]; then
  log "   !! 找不到 wine 的 kernel32.dll，wine 安装不完整"
else
  log "   wine 库正常（x86_64-windows: $(ls "$WS/opt/wine-stable/lib/wine/x86_64-windows" 2>/dev/null | wc -l) 个文件）"
fi

if [ ! -f "$WINEPREFIX/drive_c/windows/syswow64/ntdll.dll" ] || [ ! -f "$WINEPREFIX/system.reg" ]; then
  log "2/6 创建全新 WINEPREFIX"
  if [ -d "$WINEPREFIX" ]; then
    mv "$WINEPREFIX" "${WINEPREFIX}.old-$(date +%H%M%S)"   # 不删除，改名保留
  fi
  # 首次初始化要复制 2000+ 个 DLL，容器里通常 1~5 分钟，必须带超时和进度
  log "   初始化 WINEPREFIX（首次 1~5 分钟，请耐心等待，不要以为卡死）"
  # 诊断 1：X server 是否可用
  log "   检查 X server（xvfb）"
  timeout 60 xvfb-run -a xdpyinfo </dev/null >/dev/null 2>&1 && log "   X server: 正常" || log "   X server: 异常"
  # 诊断 2：用最简单的命令触发 prefix 创建（比 wineboot 简单，能过说明基础环境 OK）
  log "   诊断：wine cmd /c exit"
  WINEDLLOVERRIDES="$WINEBOOT_OVERRIDES" runb "wine cmd /c exit" 180 /tmp/wcmd.out \
    timeout 200 xvfb-run -a wine cmd /c exit
  log "   诊断返回码 $?"
  log "   诊断：prefix 文件 system32/ntdll.dll $([ -f "$WINEPREFIX/drive_c/windows/system32/ntdll.dll" ] && echo 已生成 || echo 未生成) | syswow64/ntdll.dll $([ -f "$WINEPREFIX/drive_c/windows/syswow64/ntdll.dll" ] && echo 已生成 || echo 未生成)"
  # 正式初始化（带错误输出，便于定位卡在哪一步）
  log "   执行 wineboot -i（每 5 秒报一次进度）"
  WINEDLLOVERRIDES="$WINEBOOT_OVERRIDES" WINEDEBUG=+err,+warn runb "wineboot -i" 600 /tmp/wboot.out \
    timeout 620 xvfb-run -a --server-args="-screen 0 1024x768x24" wineboot -i
  log "   wineboot 结束"
  # 让 wineserver 立即退出并把 registry 落盘。
  # 用 -k（kill，退出前会 flush）而不是 -w（干等它自己退），实测 -w 会白等 1~3 分钟。
  log "   结束 wineserver 并落盘（-k 立即生效）"
  timeout 30 wineserver -k </dev/null 2>/dev/null || true
  sleep 1
  log "   wineserver 已退出，registry 已落盘"
  log "   prefix: system32/ntdll.dll $([ -f "$WINEPREFIX/drive_c/windows/system32/ntdll.dll" ] && echo 有 || echo 无) | syswow64/ntdll.dll $([ -f "$WINEPREFIX/drive_c/windows/syswow64/ntdll.dll" ] && echo 有 || echo 无)"
  # .NET 10 要求 Windows 10 及以上（winetricks 装 dotnet10 时同样会设）
  regop "设置 wine 版本 = win10" add "HKCU\\Software\\Wine" /v Version /d win10 /f
  # 关掉崩溃弹窗/调试器，否则崩溃后会挂起阻塞
  regop "关闭 WineDbg 崩溃弹窗" add "HKCU\\Software\\Wine\\WineDbg" /v ShowCrashDialog /t REG_DWORD /d 0 /f
fi
if [ -f "$WINEPREFIX/drive_c/windows/syswow64/ntdll.dll" ]; then
  log "   syswow64 正常"
else
  log "   !! syswow64 缺失，后续运行库安装会失败，请检查 i386 包"
fi
# 每次启动都清掉 mscoree/mshtml 的 DLL override 残留（不管 prefix 是新建还是复用）。
# 目的是与官方镜像保持一致：lip.exe 是 .NET apphost，必须能走 mscoree 加载托管程序集。
regop "清除 mscoree override" delete "HKCU\\Software\\Wine\\DllOverrides" /v mscoree /f
regop "清除 mshtml override"  delete "HKCU\\Software\\Wine\\DllOverrides" /v mshtml /f
DLLOVR=$(timeout 90 xvfb-run -a wine reg query "HKCU\\Software\\Wine\\DllOverrides" </dev/null 2>/dev/null | tr -d '\r' | grep -ciE "mscoree|mshtml" || true)
log "   DllOverrides 中 mscoree/mshtml 残留条目数: ${DLLOVR:-0}（应为 0，否则 lip 会起不来）"

# ------------------------------------------------------------------ 3. VC++ 2026
if [ ! -f "$WINEPREFIX/.done-vcrun2026" ]; then
  log "3/6 安装 VC++ 2026（对应官方 winetricks vcrun2026）"
  if dl "$VC_X64" /tmp/vc_x64.exe 10000000 || dl "$VC_X64_FB" /tmp/vc_x64.exe 10000000; then
    wr /tmp/vc_x64.exe /install /quiet /norestart; log "   x64 退出码 $?"
  fi
  if dl "$VC_X86" /tmp/vc_x86.exe 5000000 || dl "$VC_X86_FB" /tmp/vc_x86.exe 5000000; then
    wr /tmp/vc_x86.exe /install /quiet /norestart; log "   x86 退出码 $?"
  fi
  touch "$WINEPREFIX/.done-vcrun2026"
fi

# ------------------------------------------------------------------ 4. .NET 10
# lip.exe 是 x64 程序，默认只装 x64 即可；需要 32 位支持时把 X86_ALSO 置 1
X86_ALSO="${X86_ALSO:-0}"
# 判断是否已装有满足要求的 .NET（lip 需 10.0.14+）
DOTNET_SHARED="$WINEPREFIX/drive_c/Program Files/dotnet/shared/Microsoft.NETCore.App"
check_dotnet(){   # 返回 0 表示达标
  local v mj pt
  [ -d "$DOTNET_SHARED" ] || return 1
  for v in $(ls "$DOTNET_SHARED" 2>/dev/null); do
    mj=$(printf '%s' "$v" | cut -d. -f1)
    pt=$(printf '%s' "$v" | cut -d. -f3)
    case "$mj$pt" in ''|*[!0-9]*) continue ;; esac
    if [ "$mj" -ge 10 ] && [ "$pt" -ge 14 ]; then return 0; fi
  done
  return 1
}
DOTNET_OK=0
check_dotnet && DOTNET_OK=1
if [ "$DOTNET_OK" != "1" ]; then
  log "4/6 安装 .NET Runtime 10.0.15（x64；winetricks dotnet10 的 10.0.0 版本过低，lip 需 10.0.14+）"
  dl "$DN_X64" /tmp/dn1015_x64.exe 20000000 || dl "$DN_X64_FB" /tmp/dn1015_x64.exe 20000000
  if [ -s /tmp/dn1015_x64.exe ]; then
    wr /tmp/dn1015_x64.exe /install /quiet /norestart; log "   x64 退出码 $?"
  fi
  if [ "$X86_ALSO" = "1" ]; then
    log "   额外安装 x86 运行时"
    dl "$DN_X86" /tmp/dn1015_x86.exe 20000000 || dl "$DN_X86_FB" /tmp/dn1015_x86.exe 20000000
    if [ -s /tmp/dn1015_x86.exe ]; then
      wr /tmp/dn1015_x86.exe /install /quiet /norestart; log "   x86 退出码 $?"
    fi
  fi
  log "   dotnet 目录: $(ls "$WINEPREFIX/drive_c/Program Files/dotnet" 2>/dev/null | tr '\n' ' ')"
  log "   已装运行时: $(ls "$DOTNET_SHARED" 2>/dev/null | tr '\n' ' ')"
  # 安装完成后重新检测（之前沿用安装前的旧结果会误报）
  if check_dotnet; then
    log "   .NET 版本校验通过（>=10.0.14）"
  else
    log "   !! dotnet 仍未达到 10.0.14+，lip 将无法运行"
  fi
fi

# ------------------------------------------------------------------ 5. lip + LL
# lip 必须是 Windows 版并在 wine 里运行：这样平台自动识别为 win-x64，
# 且 bds 包的 .bdsdown.exe 等 Windows hook 才能正常执行。
# （用 Linux 原生 lip 会陷入「LL 无 linux-x64 变体」+「hook 无法执行」两个死结）
if [ ! -f "$LL/bin/lip.exe" ]; then
  log "5/6 获取 lip.exe ${LIP_VER}（Windows 版）"
  mkdir -p "$LL/bin"
  dl "${GH_MIRROR}https://github.com/LiteLDev/lip/releases/download/v${LIP_VER}/lip-${LIP_VER}-win-x64.zip" /tmp/lipwin.zip
  unzip -oq /tmp/lipwin.zip -d "$LL/bin" 2>>"$LOG"
fi
if [ ! -f bedrock_server_mod.exe ]; then
  # 官方 wrapper 就是这么调的：`wine /opt/lip/lip.exe "$@"`（无 xvfb-run、无 WINEDLLOVERRIDES）
  # 输出必须打到面板：之前重定向进日志，面板上只剩一行「设置 lip github_proxy =」，看着像卡死
  log "   设置 lip github_proxy = ${GH_MIRROR}"
  runb "lip config set" 120 /tmp/lipcfg.out \
    timeout 140 wine "$LL/bin/lip.exe" config set github_proxy "${GH_MIRROR}"
  _rc=$?
  log "   (设置代理返回码 $_rc)"
  log "   lip 自检：--version"
  runb "lip --version" 120 /tmp/lipver.out \
    timeout 140 wine "$LL/bin/lip.exe" --version
  _rc=$?
  log "   自检返回码 $_rc"
  if [ "$_rc" != "0" ]; then
    log "   !! lip 无法运行，.NET 运行时有问题，后续 install 必然失败，先停下"
  fi
  log "   执行 lip install github.com/LiteLDev/LeviLamina（下载 BDS 约 230MB，进度见下）"
  if [ -n "$GH_PROXY" ]; then
    yes | http_proxy="$GH_PROXY" https_proxy="$GH_PROXY" \
      timeout 3600 wine "$LL/bin/lip.exe" install github.com/LiteLDev/LeviLamina </dev/null
  else
    yes | timeout 3600 wine "$LL/bin/lip.exe" install github.com/LiteLDev/LeviLamina
  fi
  log "   lip 退出码 $? | 产物: $(ls | tr '\n' ' ')"
fi

# ------------------------------------------------------------------ 6. 配置
log "6/6 写入配置"
if [ -f server.properties ]; then
  sed -i "s/^server-port=.*/server-port=${PORT}/" server.properties
  # lip install 解压 bds 包时会把 server.properties 重置成默认的 server-udp-ports=19132，
  # 所以这里必须每次无条件写成三段式 外部IP:外部端口:内部端口，不能"留空就不动"。
  if [ -n "$PUBLIC_IP" ]; then
    if grep -q '^server-udp-ports=' server.properties; then
      sed -i "s|^server-udp-ports=.*|server-udp-ports=${UDP_PORTS}|" server.properties
    else
      printf 'server-udp-ports=%s\n' "$UDP_PORTS" >> server.properties
    fi
    log "   server-udp-ports = ${UDP_PORTS}"
  else
    # 没给 PUBLIC_IP 时，如果文件里已经是三段式就保留，避免把它改坏；否则必须喊出来
    _cur=$(grep '^server-udp-ports=' server.properties 2>/dev/null | cut -d= -f2-)
    case "$_cur" in
      *:*:*)
        log "   PUBLIC_IP 未设置 → 保留文件里已有的三段式: ${_cur}"
        ;;
      *)
        log "   !! PUBLIC_IP 未设置，且 server-udp-ports 当前是单端口值 '${_cur:-空}'"
        log "      玩家将连不上（客户端会报 Door）。请设置环境变量 PUBLIC_IP=<外部入口IP>"
        log "      填法：server.env 里写 PUBLIC_IP=1.2.3.4"
        ;;
    esac
  fi
  sed -i 's/^online-mode=.*/online-mode=false/; s/^allow-list=.*/allow-list=false/' server.properties
fi
CFG="mods/LeviLamina/config/Config.json"
# Config.json 由 LeviLamina 首次运行时才生成，那时本步骤已经跑完了 ——
# 于是第一次启动永远是 netherNetPatch=true，客户端必报 Door。
# 解决：文件不存在时先用 Config.default.json 预置一份（netherNetPatch 已经是 false），
# LL 启动时直接读它，第一次就不会开 STUN。
if [ ! -f "$CFG" ] && [ -f "$BASE_DIR/Config.default.json" ]; then
  mkdir -p "$(dirname "$CFG")"
  cp "$BASE_DIR/Config.default.json" "$CFG"
  log "   预置 $CFG（来自 Config.default.json，netherNetPatch 已为 false）"
fi
if [ -f "$CFG" ]; then
  # netherNetPatch 在 targeted 段下，且 JSON 是缩进的 —— 绝不能写行首锚点 ^"netherNetPatch"，
  # 那样永远匹配不到，会静默失效（LL 日志里会照旧打印「已为 NetherNet 配置 N 个 STUN 服务器」）。
  # 范围限定在 "netherNetPatch" 到本块结束的 } 之间，不碰 vulnerabilityFixes。
  sed -i '/"netherNetPatch"/,/}/ s/"enable": *true/"enable": false/' "$CFG"
  log "   netherNetPatch 当前值："
  grep -A2 '"netherNetPatch"' "$CFG" | head -4
else
  log "   !! 找不到 $CFG —— LeviLamina 首次运行后才会生成它，本次来不及改"
  log "      若启动日志出现「已为 NetherNet 配置 N 个 STUN 服务器」，说明 netherNetPatch 仍为开，Door 会复发"
  log "      下次重启本步骤就会自动把它改成 enable=false"
fi
log "   生效配置: server-port=$(grep '^server-port=' server.properties 2>/dev/null | cut -d= -f2)  server-udp-ports=$(grep '^server-udp-ports=' server.properties 2>/dev/null | cut -d= -f2)"

# ------------------------------------------------------------------ 启动
if [ -f bedrock_server_mod.exe ]; then
  log "===== 启动 LeviLamina ====="

  # (1) 不要用 xvfb-run：它每次换 display 号、且会包一层，wine 里外三层容易出怪事。
  #     社区整合包的做法是手动起一个固定的 Xvfb :0。
  export DISPLAY=:0
  if xdpyinfo -display :0 >/dev/null 2>&1; then
    log "   X: :0 已存在，直接复用"
  else
    log "   X: 启动 Xvfb :0（1280x1024x24）"
    Xvfb :0 -screen 0 1280x1024x24 >/dev/null 2>&1 &
    sleep 3
    xdpyinfo -display :0 >/dev/null 2>&1 && log "   X: :0 就绪" || log "   X: :0 起不来（wine 仍可能工作）"
  fi

  # (2) 终端宽度：不设这一项，面板里的输出会乱换行、把你的输入回显冲掉，
  #     看起来就像「打进去的字不显示」。社区整合包固定 cols 500。
  stty cols 500 2>/dev/null || true
  log "   终端宽度: $(stty size 2>/dev/null | awk '{print $2" 列"}' || echo 未设置)"

  # (3) 控制台输入：交给 python 转发器。
  #     BDS 拿到的是普通管道 stdin（不是 tty），wine 不会卡；
  #     容器 stdin 由转发器逐行写进那条管道，stop/list 等命令才能真正送达。
  PY=""
  for c in /mise/shims/python3 /usr/bin/python3 /usr/local/bin/python3 python3 python; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
  done
  if [ -n "$PY" ]; then
    log "   控制台: $PY console_fwd.py 转发 stdin（stop/list 可用）"
    "$PY" "$BASE_DIR/console_fwd.py" "wine bedrock_server_mod.exe"
    RC=$?
  else
    log "   !! 找不到 python，控制台输入无法转发，stop 将无效"
    xvfb-run -a wine bedrock_server_mod.exe </dev/null
    RC=$?
  fi
  log "===== BDS 已退出（返回码 $RC），清理 wine 进程 ====="
  "$WS/opt/wine-stable/bin/wineserver" -k 2>/dev/null || true
  exit "$RC"
else
  log "!! 仍未生成 bedrock_server_mod.exe —— lip install 失败，请看 $LOG"
  log "   （不在这里挂住，直接退出，方便你看到失败而不是又一个静默）"
  exit 1
fi
