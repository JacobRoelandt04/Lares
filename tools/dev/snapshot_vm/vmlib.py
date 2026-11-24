"""The VM harness of the rescue (stdlib only): start a QEMU guest, talk to its serial console, run commands over ssh.

Everything lives under the work dir (default ~/.cache/claude-orch/snapshots/vm). The guest runs nice 10, at most 6 vCPUs and 4 GB, and
only the pid this module started is ever killed.
"""
import os, re, shlex, signal, socket, subprocess, sys, threading, time

VM_ROOT = os.environ.get("SNAPVM_ROOT", os.path.expanduser("~/.cache/claude-orch/snapshots/vm"))
QEMU = os.path.join(VM_ROOT, "qemu/root/usr")
OVMF_CODE = os.path.join(QEMU, "share/edk2/x64/OVMF_CODE.4m.fd")
OVMF_VARS = os.path.join(QEMU, "share/edk2/x64/OVMF_VARS.4m.fd")
DISKS = os.path.join(VM_ROOT, "disks")
WORK = os.path.join(VM_ROOT, "work")
SSH_KEY = os.path.join(VM_ROOT, "id_vm")


def log(*a):
    print(time.strftime("%H:%M:%S"), *a, file=sys.stderr, flush=True)


def qemu_img(*args):
    env = dict(os.environ, LD_LIBRARY_PATH=os.path.join(QEMU, "lib"))
    return subprocess.run([os.path.join(QEMU, "bin/qemu-img"), *args], env=env, check=True, capture_output=True, text=True).stdout


class VM:
    """One guest. `disk` is a qcow2 path; with `boot_iso` the Arch ISO's kernel is started directly (the installer)."""

    def __init__(self, name, disk, ssh_port=2222, boot_iso=False, mem=4096, cpus=6, extra=None, graphics=True, drive_opts="", vga_dev=None):
        self.name, self.disk, self.ssh_port = name, disk, ssh_port
        self.boot_iso, self.mem, self.cpus, self.extra = boot_iso, mem, cpus, extra or []
        self.dir = os.path.join(WORK, "run-" + name)
        os.makedirs(self.dir, exist_ok=True)
        self.sock_path = os.path.join(self.dir, "serial.sock")
        self.mon_path = os.path.join(self.dir, "monitor.sock")
        self.serial_log = os.path.join(self.dir, "serial.log")
        self.vars = os.path.join(self.dir, "vars.fd")
        self.proc = None
        self.lock = threading.Lock()
        self.buf = ""
        self.sock = None
        self.graphics = graphics
        self.drive_opts = drive_opts
        self.vga_dev = vga_dev

    # -- process
    def start(self):
        for p in (self.sock_path, self.mon_path):
            if os.path.exists(p):
                os.unlink(p)
        if not os.path.exists(self.vars):
            subprocess.run(["cp", OVMF_VARS, self.vars], check=True)
        cmd = ["nice", "-n", "10", os.path.join(QEMU, "bin/qemu-system-x86_64"),
               "-machine", "q35,accel=kvm", "-cpu", "host", "-smp", str(self.cpus), "-m", str(self.mem),
               "-display", "none", *(["-vga", "none", "-device", self.vga_dev] if self.vga_dev else ["-vga", "std" if self.graphics else "none"]),
               "-serial", f"unix:{self.sock_path},server=on,wait=off",
               "-monitor", f"unix:{self.mon_path},server=on,wait=off",
               "-drive", f"if=pflash,format=raw,unit=0,readonly=on,file={OVMF_CODE}",
               "-drive", f"if=pflash,format=raw,unit=1,file={self.vars}",
               "-drive", f"file={self.disk},if=virtio,format=qcow2,cache=writeback" + self.drive_opts,
               "-nic", f"user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:{self.ssh_port}-:22",
               "-L", os.path.join(QEMU, "share/qemu"), "-device", "qemu-xhci", "-device", "usb-kbd"]
        if self.boot_iso:
            iso = os.path.join(VM_ROOT, "iso")
            cmd += ["-cdrom", os.path.join(iso, "arch.iso"), "-kernel", os.path.join(iso, "vmlinuz-linux"),
                    "-initrd", os.path.join(iso, "initramfs-linux.img"),
                    "-append", "archisobasedir=arch archisodevice=/dev/sr0 console=ttyS0,115200 copytoram=y"]
        cmd += self.extra
        env = dict(os.environ, LD_LIBRARY_PATH=os.path.join(QEMU, "lib"))
        open(self.serial_log, "w").close()
        self.proc = subprocess.Popen(cmd, env=env, stdout=subprocess.DEVNULL, stderr=open(os.path.join(self.dir, "qemu.err"), "w"))
        for _ in range(100):
            if os.path.exists(self.sock_path):
                break
            time.sleep(0.1)
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.connect(self.sock_path)
        threading.Thread(target=self._reader, daemon=True).start()
        import atexit; atexit.register(self.kill)
        log(f"vm {self.name}: started pid {self.proc.pid}")

    def _reader(self):
        f = open(self.serial_log, "ab")
        while True:
            try:
                d = self.sock.recv(65536)
            except OSError:
                return
            if not d:
                return
            f.write(d); f.flush()
            with self.lock:
                self.buf += d.decode("utf-8", "replace")

    def alive(self):
        return self.proc is not None and self.proc.poll() is None

    def kill(self):
        """The power cut: SIGKILL, nothing flushed by the guest."""
        if self.alive():
            self.proc.kill()
            self.proc.wait()

    def monitor(self, line):
        s = socket.socket(socket.AF_UNIX)
        s.connect(self.mon_path)
        s.settimeout(3)
        try:
            s.recv(4096)
            s.sendall((line + "\n").encode())
            time.sleep(0.5)
            return s.recv(65536).decode("utf-8", "replace")
        except OSError:
            return ""
        finally:
            s.close()

    def poweroff_wait(self, timeout=60):
        if not self.alive():
            return
        try:
            self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            self.kill()

    # -- serial
    def mark(self):
        with self.lock:
            return len(self.buf)

    def send(self, text):
        self.sock.sendall(text.encode())

    def expect(self, pattern, timeout=60, since=0):
        """Wait for a regex in the console output after offset `since`; returns the match."""
        rx = re.compile(pattern)
        end = time.time() + timeout
        while time.time() < end:
            with self.lock:
                m = rx.search(self.buf, since)
            if m:
                return m
            if not self.alive():
                with self.lock:
                    m = rx.search(self.buf, since)
                if m:
                    return m
                raise RuntimeError(f"vm {self.name} died waiting for {pattern!r}")
            time.sleep(0.1)
        with self.lock:
            tail = self.buf[-1500:]
        raise TimeoutError(f"timeout waiting for {pattern!r}; console tail:\n{tail}")

    def text_since(self, since):
        with self.lock:
            return self.buf[since:]

    def sh(self, cmd, timeout=120, check=True):
        """Run a command on the serial shell (a root prompt is already there); returns (status, output)."""
        m0 = self.mark()
        self.send(cmd + '; echo "@@END"$?\n')
        m = self.expect(r"@@END(\d+)\r?\n", timeout, since=m0)
        out = self.text_since(m0)[: m.start() - m0]
        out = out.split("\n", 1)[1] if "\n" in out else out
        st = int(m.group(1))
        if check and st != 0:
            raise RuntimeError(f"serial command failed ({st}): {cmd}\n{out[-2000:]}")
        return st, out.replace("\r", "")

    def put_text(self, path, text):
        """Write a file through the serial shell (base64 in short lines: the tty's line limit, and no heredoc terminators to fool)."""
        import base64
        b = base64.b64encode(text.encode()).decode()
        self.sh(f": > {path}.b64")
        for i in range(0, len(b), 900):
            self.sh(f"echo -n {b[i:i+900]} >> {path}.b64")
        self.sh(f"base64 -d {path}.b64 > {path}; rm -f {path}.b64")

    # -- ssh
    def ssh_args(self):
        return ["ssh", "-i", SSH_KEY, "-p", str(self.ssh_port), "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=5", "-o", "BatchMode=yes", "vmuser@127.0.0.1"]

    def wait_ssh(self, timeout=240):
        end = time.time() + timeout
        while time.time() < end:
            if not self.alive():
                raise RuntimeError("vm died before ssh came up")
            r = subprocess.run(self.ssh_args() + ["true"], capture_output=True)
            if r.returncode == 0:
                return
            time.sleep(2)
        raise TimeoutError("ssh did not come up")

    def ssh(self, cmd, timeout=600, check=True, root=True):
        full = ("sudo -n bash -c " + shlex.quote(cmd)) if root else cmd
        r = subprocess.run(self.ssh_args() + [full], capture_output=True, text=True, timeout=timeout)
        if check and r.returncode != 0:
            raise RuntimeError(f"ssh command failed ({r.returncode}): {cmd}\n{r.stdout[-1500:]}\n{r.stderr[-1500:]}")
        return r.returncode, r.stdout + r.stderr

    def put(self, local, remote, mode="0644"):
        data = open(local, "rb").read()
        r = subprocess.run(self.ssh_args() + [f"sudo -n sh -c 'cat > {shlex.quote(remote)} && chmod {mode} {shlex.quote(remote)}'"],
                           input=data, capture_output=True, timeout=300)
        if r.returncode != 0:
            raise RuntimeError(f"put {remote} failed: {r.stderr!r}")

    def put_dir(self, local, remote):
        """tar of a local directory unpacked at `remote` (as root)."""
        tar = subprocess.run(["tar", "-C", local, "-c", "."], capture_output=True, check=True).stdout
        r = subprocess.run(self.ssh_args() + [f"sudo -n sh -c 'rm -rf {shlex.quote(remote)}; mkdir -p {shlex.quote(remote)} && tar -x -C {shlex.quote(remote)}'"],
                           input=tar, capture_output=True, timeout=300)
        if r.returncode != 0:
            raise RuntimeError(f"put_dir {remote} failed: {r.stderr!r}")

    def screendump(self, path):
        self.monitor(f"screendump {path}")


def new_overlay(base, name):
    """A throwaway qcow2 on top of `base`; the caller deletes it."""
    path = os.path.join(DISKS, f"overlay-{name}.qcow2")
    if os.path.exists(path):
        os.unlink(path)
    qemu_img("create", "-f", "qcow2", "-F", "qcow2", "-b", base, path)
    return path


def stop_leftovers():
    """Kill the guests a crashed earlier run of THIS harness left (their command line holds our work dir); nobody else's."""
    me = os.getpid()
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            comm = open(f"/proc/{pid}/comm").read().strip()
            cmd = open(f"/proc/{pid}/cmdline", "rb").read().decode(errors="replace")
        except OSError:
            continue
        if comm.startswith("qemu-system") and WORK + "/run-" in cmd and int(pid) != me:
            os.kill(int(pid), signal.SIGKILL)
            log("stopped a leftover guest", pid)


if __name__ == "__main__" and "--stop" in sys.argv:
    stop_leftovers()
