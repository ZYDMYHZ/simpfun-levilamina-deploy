#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
控制台输入转发器。

为什么需要它：
  BDS 是 Windows 程序，用 ReadConsole(Input) 读控制台。在 wine 下如果直接把 tty
  交给它，wine 会在初始化 console 时卡死（实测 2 分钟零输出）；而如果直接把 stdin
  接到 /dev/null 或 FIFO，命令又进不去。
  正确做法是给它一个「普通管道」当 stdin（wine 不会去初始化 tty），再由本程序把
  容器的 stdin 原样转发到那条管道里。简幻欢上能用的整合包就是这么做的。

另外 subprocess 的 stdin=PIPE 让子进程拿到的不是终端，BDS 不会做 tty 相关初始化，
退出时 p.wait() 也能正常返回，不会出现「BDS 停了但脚本还挂着」。
"""
import subprocess
import sys
import threading


def forward(src, dst, child):
    """把容器 stdin 逐行塞进子进程 stdin。"""
    try:
        while True:
            if child.poll() is not None:
                break
            line = src.readline()
            if not line:
                break
            try:
                dst.write(line)
                dst.flush()
            except (BrokenPipeError, OSError, ValueError):
                break
    except Exception:
        pass


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "wine bedrock_server_mod.exe"
    child = subprocess.Popen(
        cmd,
        stdin=subprocess.PIPE,
        stdout=None,          # 直接继承，日志照常打到面板
        stderr=None,
        shell=True,
    )
    t = threading.Thread(target=forward, args=(sys.stdin.buffer, child.stdin, child))
    t.daemon = True
    t.start()
    rc = child.wait()
    try:
        child.stdin.close()
    except Exception:
        pass
    sys.exit(rc)


if __name__ == "__main__":
    main()
