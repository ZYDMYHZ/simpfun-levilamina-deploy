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
PUBLIC_IP="${PUBLIC_IP:-}"
PORT="${SERVER_PORT:-19132}"

# ------------------------------------------------------------------ 内部变量
BASE_DIR="/home/container"
LL="$BASE_DIR/ll-server"
WS="$BASE_DIR/wine-stable11"
LOG="$BASE_DIR/ll-install.log"
export WINEPREFIX="$LL/.wine-official"
export WINEARCH=win64
export WINEDEBUG=-all
# wine 是 dpkg -x 解包到自定义前缀的，二进制仍按编译期路径 /opt/wine-stable 找库，
# 不显式指定就会报 "could not load kernel32.dll, status c0000135"
export WINELOADER="$WS/opt/wine-stable/bin/wine"
export WINESERVER="$WS/opt/wine-stable/bin/wineserver"
export WINEDLLPATH="$WS/opt/wine-stable/lib/wine"
export WINEDATADIR="$WS/opt/wine-stable/share/wine"
# 禁用 wine-mono 与 wine-gecko 的自动安装。
# 不加这个，wineboot 首次初始化会弹窗要求安装 mono/gecko，无头容器里永远等不到确认。
# 注意：我们装的是微软官方 .NET Runtime（不是 wine-mono），所以禁用 mscoree 不影响 lip。
export WINEDLLOVERRIDES="mscoree,mshtml="
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

  for i in 1 2 3; do
    log "   下载 $name (第 $i 次)${total:+，共 $((total/1048576)) MB}"
    : > "$out"
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
    if curl -fL $PAR --retry 2 --retry-delay 3 --connect-timeout 20 --max-time 900 \
         -o "$out" "$url" >>"$LOG" 2>&1; then
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
    printf '\r[ll]   %s  第 %d 次中断\n' "$name" "$i"
    log "   第 $i 次失败，5 秒后重试"
    sleep 5
  done
  log "   !! 下载失败: $url"
  return 1
}

# 安装器执行：加超时，避免 wine 弹窗/挂起时无限等待
wr(){  # wr <exe> [args...]
  local exe="$1"; shift
  printf '[ll]   运行 %s（最长 1200 秒，静默安装中...）\n' "$(basename "$exe")"
  timeout 1200 xvfb-run -a wine "$exe" "$@"
  local rc=$?
  [ $rc -eq 124 ] && log "   !! 超时(1200s)被终止: $(basename "$exe")"
  return $rc
}

mkdir -p "$LL"
cd "$LL" || { echo "无法进入 $LL"; exit 1; }
log "===== 启动 $(date '+%F %T') | 入口 ${PUBLIC_IP}:${PORT} ====="

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
    [ -f "$f" ] && dpkg -x "$f" "$WS"
  done
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

if [ ! -f "$WINEPREFIX/drive_c/windows/syswow64/ntdll.dll" ]; then
  log "2/6 创建全新 WINEPREFIX"
  if [ -d "$WINEPREFIX" ]; then
    mv "$WINEPREFIX" "${WINEPREFIX}.old-$(date +%H%M%S)"   # 不删除，改名保留
  fi
  # 首次初始化要复制 2000+ 个 DLL，容器里通常 1~5 分钟，必须带超时和进度
  log "   初始化 WINEPREFIX（首次 1~5 分钟，请耐心等待，不要以为卡死）"
  # WINEDLLOVERRIDES 已在顶部设为 mscoree,mshtml —— 阻止 wineboot 弹窗要求安装 mono/gecko
  timeout 900 xvfb-run -a --server-args="-screen 0 1024x768x24" wineboot -i 2>&1 | tail -8
  log "   wineboot 结束"
  # 等 wineserver 把所有文件落盘后再继续，否则后续 wine 调用会读到半成品 prefix
  timeout 180 wineserver -w 2>/dev/null || true
  log "   prefix: system32/ntdll.dll $([ -f "$WINEPREFIX/drive_c/windows/system32/ntdll.dll" ] && echo 有 || echo 无) | syswow64/ntdll.dll $([ -f "$WINEPREFIX/drive_c/windows/syswow64/ntdll.dll" ] && echo 有 || echo 无)"
  # .NET 10 要求 Windows 10 及以上（winetricks 装 dotnet10 时同样会设）
  xvfb-run -a wine reg add "HKCU\\Software\\Wine" /v Version /d win10 /f >>"$LOG" 2>&1 || true
  log "   wine Windows 版本已设为 win10"
  # 关掉崩溃弹窗/调试器，否则崩溃后会挂起阻塞
  xvfb-run -a wine reg add "HKCU\\Software\\Wine\\WineDbg" /v ShowCrashDialog /t REG_DWORD /d 0 /f >>"$LOG" 2>&1 || true
fi
if [ -f "$WINEPREFIX/drive_c/windows/syswow64/ntdll.dll" ]; then
  log "   syswow64 正常"
else
  log "   !! syswow64 缺失，后续运行库安装会失败，请检查 i386 包"
fi

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
  # lip 默认直连 GitHub，BDS 本体约 230MB；设置 github_proxy 走加速镜像
  log "   设置 lip github_proxy = ${GH_MIRROR}"
  timeout 600 xvfb-run -a wine "$LL/bin/lip.exe" config set github_proxy "${GH_MIRROR}" >>"$LOG" 2>&1
  log "   (设置代理返回码 $?)"
  log "   lip 自检：--version"
  timeout 600 xvfb-run -a wine "$LL/bin/lip.exe" --version 2>&1 | tr -d '\000' | tail -3
  log "   自检返回码 $?"
  log "   执行 lip install github.com/LiteLDev/LeviLamina"
  if [ -n "$GH_PROXY" ]; then
    yes | http_proxy="$GH_PROXY" https_proxy="$GH_PROXY" \
      timeout 3600 xvfb-run -a wine "$LL/bin/lip.exe" install github.com/LiteLDev/LeviLamina
  else
    yes | timeout 3600 xvfb-run -a wine "$LL/bin/lip.exe" install github.com/LiteLDev/LeviLamina
  fi
  log "   lip 退出码 $? | 产物: $(ls | tr '\n' ' ')"
fi

# ------------------------------------------------------------------ 6. 配置
log "6/6 写入配置"
if [ -f server.properties ]; then
  sed -i "s/^server-port=.*/server-port=${PORT}/" server.properties
  if grep -q '^server-udp-ports=' server.properties; then
    sed -i "s|^server-udp-ports=.*|server-udp-ports=${PUBLIC_IP}:${PORT}:${PORT}|" server.properties
  else
    printf 'server-udp-ports=%s:%s:%s\n' "$PUBLIC_IP" "$PORT" "$PORT" >> server.properties
  fi
  sed -i 's/^online-mode=.*/online-mode=false/; s/^allow-list=.*/allow-list=false/' server.properties
fi
CFG="mods/LeviLamina/config/Config.json"
if [ -f "$CFG" ]; then
  # 只改 netherNetPatch 块内的 enable，不动 vulnerabilityFixes 等其他项
  sed -i '/"netherNetPatch"/,/}/ s/"enable": *true/"enable": false/' "$CFG"
  log "   netherNetPatch 当前值："
  grep -A2 '"netherNetPatch"' "$CFG" | head -4
fi
log "   server-port=${PORT}  server-udp-ports=${PUBLIC_IP}:${PORT}:${PORT}"

# ------------------------------------------------------------------ 启动
if [ -f bedrock_server_mod.exe ]; then
  log "===== 启动 LeviLamina ====="
  # 用 FIFO 转发 stdin：既能接收面板控制台命令（如 stop），
  # 又能在 BDS 退出后让脚本继续往下走并结束进程，
  # 否则 "cat |" 里的 cat 会一直阻塞在 stdin 上，导致实例停不下来。
  FIFO="/tmp/bds_stdin_$$"
  mkfifo "$FIFO" 2>/dev/null
  cat > "$FIFO" 2>/dev/null &
  CAT_PID=$!
  xvfb-run -a wine bedrock_server_mod.exe < "$FIFO"
  RC=$?
  kill "$CAT_PID" 2>/dev/null
  wait "$CAT_PID" 2>/dev/null
  mv -f "$FIFO" "/tmp/bds_stdin_done_$$" 2>/dev/null || true
  log "===== BDS 已退出（返回码 $RC），清理 wine 进程 ====="
  "$WS/opt/wine-stable/bin/wineserver" -k 2>/dev/null || true
  exit "$RC"
else
  log "!! 仍未生成 bedrock_server_mod.exe，请查看 $LOG"
  sleep infinity
fi
