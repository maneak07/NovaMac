#!/usr/bin/env python3
"""NovaMac USB bridge.

Connects the Parallels VM serial port (a Unix socket) to the real USB sending card on the Mac
(/dev/cu.usbserial-140), so NovaLCT in Windows talks to the MCTRL300 through a plain COM port
(no CP210x driver needed in the VM). Every byte in both directions is logged to
usb-capture.log next to this script, for NovaMac to rebuild the register sequence.

Usage:  python3 nova_bridge.py [serial-port] [socket-path] [baud] [--client]
        defaults: /dev/cu.usbserial-140  /tmp/novabridge  115200
        Default: this script creates the socket (Parallels serial port Mode = Client).
        --client: Parallels creates it (Mode = Server) and this script connects.
Stop with Ctrl+C. No extra packages needed.
"""
import os, sys, socket, termios, select, time

ARGS = [a for a in sys.argv[1:] if not a.startswith("--")]
CLIENT = "--client" in sys.argv
SERIAL = ARGS[0] if len(ARGS) > 0 else "/dev/cu.usbserial-140"
SOCK = ARGS[1] if len(ARGS) > 1 else "/tmp/novabridge"
BAUD = int(ARGS[2]) if len(ARGS) > 2 else 115200
LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "usb-capture.log")
SPEEDS = {57600: termios.B57600, 115200: termios.B115200, 230400: termios.B230400}


def open_serial(path, baud):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    import fcntl
    fcntl.ioctl(fd, termios.TIOCEXCL)          # exclusive: NovaMac cannot open the port while the bridge runs
    iflag, oflag, cflag, lflag, ispeed, ospeed, cc = termios.tcgetattr(fd)
    iflag = 0
    oflag = 0
    lflag = 0
    cflag = termios.CS8 | termios.CREAD | termios.CLOCAL      # 8N1, no flow control
    speed = SPEEDS[baud]
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 0
    termios.tcsetattr(fd, termios.TCSANOW, [iflag, oflag, cflag, lflag, speed, speed, cc])
    termios.tcflush(fd, termios.TCIOFLUSH)
    return fd


LISTENER = None


def connect(path):
    global LISTENER
    if not CLIENT:
        if LISTENER is None:
            if os.path.exists(path):
                os.remove(path)
            LISTENER = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            LISTENER.bind(path)
            LISTENER.listen(1)
        print(f"Socket {path} is ready. Start the VM (or reconnect its serial port) now...")
        s, _ = LISTENER.accept()
        print("Parallels connected.")
        return s
    print(f"Waiting for the Parallels serial socket {path} (start the VM)...")
    while True:
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.connect(path)
            return s
        except OSError:
            s.close()
            time.sleep(1)


def main():
    port = open_serial(SERIAL, BAUD)
    print(f"Opened {SERIAL} at {BAUD} 8N1")
    sock = connect(SOCK)
    print(f"Connected to {SOCK}. Logging to {LOG}. Ctrl+C to stop.")
    t0 = time.time()
    total = {">": 0, "<": 0}
    with open(LOG, "a") as log:
        log.write(f"# session {time.strftime('%Y-%m-%d %H:%M:%S')} {SERIAL} {BAUD}\n")
        try:
            while True:
                ready, _, _ = select.select([sock, port], [], [], 1.0)
                for r in ready:
                    if r is sock:
                        data = sock.recv(4096)
                        if not data:
                            print("VM closed the serial port; reconnecting.")
                            sock.close()
                            sock = connect(SOCK)
                            continue
                        view = memoryview(data)
                        while view:
                            try:
                                n = os.write(port, view)
                                view = view[n:]
                            except BlockingIOError:
                                select.select([], [port], [], 1.0)
                        d = ">"   # PC (NovaLCT) -> card
                    else:
                        try:
                            data = os.read(port, 4096)
                        except BlockingIOError:
                            continue
                        if not data:
                            continue
                        sock.sendall(data)
                        d = "<"   # card -> PC
                    total[d] += len(data)
                    log.write(f"{time.time() - t0:10.4f} {d} {data.hex()}\n")
                    log.flush()
                    print(f"\rPC->card {total['>']} B, card->PC {total['<']} B", end="", flush=True)
        except KeyboardInterrupt:
            print("\nStopped.")


if __name__ == "__main__":
    main()
