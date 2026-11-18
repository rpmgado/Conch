#!/usr/bin/env python3
"""模拟一台接在串口上的网络设备，给 Conch 的串口会话做测试。

用伪终端（pty）代替真的 USB 转串口线：Conch 打开从端（/dev/ttysNNN），这个脚本在主端扮演设备的 Console：
回显输入，回车给出 "Switch>" 提示符，支持：
  show version   设备信息
  show line      Conch 设置的串口参数（从从端的 termios 读出来：波特率、数据位、校验、停止位、流控）
  gbk            用 GBK 编码输出一段中文
用法：scripts/mock-serial.py <把从端路径写到这个文件>
"""
import os
import sys
import termios


def line_settings(fd):
    iflag, _oflag, cflag, _lflag, ispeed, ospeed, _cc = termios.tcgetattr(fd)
    size = {termios.CS5: 5, termios.CS6: 6, termios.CS7: 7, termios.CS8: 8}[cflag & termios.CSIZE]
    parity = "none" if not cflag & termios.PARENB else ("odd" if cflag & termios.PARODD else "even")
    stop = 2 if cflag & termios.CSTOPB else 1
    crtscts = getattr(termios, "CRTSCTS", 0)
    if crtscts and cflag & crtscts == crtscts:
        flow = "hardware"
    elif iflag & termios.IXON:
        flow = "software"
    else:
        flow = "none"
    return f"speed={ospeed} bits={size} parity={parity} stop={stop} flow={flow}"


def main():
    master, slave = os.openpty()
    # 从端一直开着：没人打开从端时读主端会出错
    with open(sys.argv[1], "w") as f:
        f.write(os.ttyname(slave))
    line = b""
    while True:
        try:
            data = os.read(master, 1024)
        except OSError:
            return
        if not data:
            return
        out = b""
        for byte in data:
            if byte in (13, 10):
                command = line.decode(errors="replace").strip()
                line = b""
                out += b"\r\n"
                if command == "show version":
                    out += b"Mock Switch Software, Version 1.0\r\n"
                elif command == "show line":
                    out += line_settings(slave).encode() + b"\r\n"
                elif command == "gbk":
                    out += "编码测试：中文GBK\r\n".encode("gbk")
                elif command:
                    out += f"% Invalid input: {command}\r\n".encode()
                out += b"Switch> "
            elif byte in (8, 127):
                if line:
                    line = line[:-1]
                    out += b"\x08 \x08"
            else:
                line += bytes([byte])
                out += bytes([byte])
        os.write(master, out)


if __name__ == "__main__":
    main()
