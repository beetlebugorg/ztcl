# Tests the interactive shell of the runner in a pseudo-terminal.
#
#   python3 -I tools/shell-pty.py [runner]
#
# The default runner is zig-out/bin/ztcl. Each case starts the runner in a
# new pseudo-terminal with TERM=xterm, HOME in a new folder, and no file,
# so the runner starts the shell. The case sends keys, reads the screen
# bytes, and checks the text with the escape sequences removed. A case
# that runs two sessions checks that the history file is shared. The exit
# code is 1 when a case fails. Unix only: Windows has no pty module.
# SPDX-License-Identifier: BSD-2-Clause
import fcntl, os, pty, re, select, shutil, signal, struct, sys, tempfile, termios, time

here = os.path.dirname(os.path.abspath(__file__))
runner = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "zig-out", "bin", "ztcl"))
escape = re.compile(rb"\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b[()][0-9A-Za-z]|\r")


class Session:
    def __init__(self, home, env=None, cwd=None, args=()):
        self.pid, self.fd = pty.fork()
        if self.pid == 0:
            e = {"TERM": "xterm", "HOME": home, "PATH": "/usr/bin:/bin"}
            e.update(env or {})
            if cwd:
                os.chdir(cwd)
            os.execve(runner, [runner, *args], e)
        self.resize(24, 80)
        self.raw = b""
        self.read(0.5)

    def read(self, t=0.4):
        end = time.time() + t
        got = b""
        while time.time() < end:
            r, _, _ = select.select([self.fd], [], [], 0.05)
            if r:
                try:
                    chunk = os.read(self.fd, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                got += chunk
        self.raw += got
        return got

    def resize(self, rows, cols):
        fcntl.ioctl(self.fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        if self.pid:
            try:
                os.kill(self.pid, signal.SIGWINCH)
            except ProcessLookupError:
                pass

    def send(self, keys, t=0.4):
        os.write(self.fd, keys)
        return self.read(t)

    def text(self):
        return escape.sub(b"", self.raw).decode("utf-8", "replace")

    def close(self):
        try:
            # Ctrl-C drops the line, so Ctrl-D ends the shell.
            os.write(self.fd, b"\x03\x04")
        except OSError:
            pass
        self.read(0.3)
        try:
            os.waitpid(self.pid, 0)
        except ChildProcessError:
            pass


failed = 0


def check(name, ok, detail=""):
    global failed
    print(("ok   " if ok else "FAIL ") + name + ("" if ok else ": " + detail[-300:]))
    if not ok:
        failed += 1


home = tempfile.mkdtemp(prefix="ztcl-shell-")
try:
    s = Session(home)
    s.send(b"set x 4\r")
    check("a result prints", "\n4\n" in s.text().replace("\n\n", "\n"), s.text())
    s.send(b"proc f {a b} {\r")
    s.send(b"expr {$a + $b}\r")
    check("an open brace continues the command", "> " in s.text(), s.text())
    s.send(b"}\r")
    s.raw = b""
    s.send(b"f 2 ")
    check("the parameters of a proc show under the command", "f a b" in s.text(), s.text())
    s.send(b"3\r")
    check("the proc runs", "\n5" in s.text(), s.text())
    s.raw = b""
    s.send(b"\x1b[A")
    check("Up recalls the last command", "f 2 3" in s.text(), s.text())
    s.send(b"\x15")
    s.raw = b""
    s.send(b"lappe\t")
    check("Tab completes a command name", "lappend" in s.text(), s.text())
    s.send(b"\x15")
    s.raw = b""
    s.send(b"string to\t")
    check("Tab lists the subcommands of an ensemble", "tolower" in s.text() and "toupper" in s.text(), s.text())
    s.send(b"\x15")
    s.raw = b""
    s.send(b"set longname_var 1\r")
    s.raw = b""
    s.send(b"puts $longn\t")
    check("Tab completes a variable after $", "$longname_var" in s.text(), s.text())
    s.send(b"\x15")
    s.raw = b""
    s.send(b"nosuch\r")
    check("an error prints its message", 'invalid command name "nosuch"' in s.text(), s.text())
    s.send(b"proc g {} {error deep}; g\r")
    s.raw = b""
    s.send(b"\x1bt")
    check("Alt-T shows the whole errorInfo", 'invoked from within' in s.text() or '(procedure "g"' in s.text(), s.text())
    s.raw = b""
    s.send(b"\x12f 2\x1b")
    s.send(b"\r")
    check("Ctrl-R finds a command of the history", "\n5" in s.text(), s.text())
    s.raw = b""
    s.send(b"\x1b[200~set p 1\rset q 22\x1b[201~")
    s.send(b"\r")
    check("a paste of two lines runs as one command", "\n22" in s.text(), s.text())
    s.send(b"shell mode vi\r")
    s.raw = b""
    s.send(b"puts hello\x1b")
    check("vim mode: the prompt shows the normal mode", b"\x1b[1;33m%" in s.raw, repr(s.raw[-200:]))
    s.send(b"bcwbye\x1b")
    s.send(b"\r")
    check("vim mode: cw changes a word", "\nbye" in s.text(), s.text())
    s.raw = b""
    s.send(b"\x1b[A")
    s.send(b"\x1b")
    s.send(b"0dw")
    s.send(b"\r")
    check("vim mode: dw and Up", "invalid command name \"bye\"" in s.text(), s.text())
    s.close()

    # A second session sees the commands of the first in the history file.
    t = Session(home)
    t.send(b"\x1b[A")
    check("the history file is shared between sessions", "bye" in t.text() or "puts" in t.text(), t.text())
    t.close()
    with open(os.path.join(home, ".ztcl_history")) as f:
        lines = f.read().splitlines()
    check("each command is in the file once in a row", "set x 4" in lines and lines.count("set x 4") == 1, repr(lines))

    # NO_COLOR: no color codes.
    u = Session(home, {"NO_COLOR": "1"})
    u.send(b"set z {a b}\r")
    check("NO_COLOR gives no colors", re.search(rb"\x1b\[[0-9;]*m", u.raw.split(b"set z", 1)[-1]) is None, repr(u.raw[-200:]))
    u.close()

    # Ctrl-X Ctrl-E opens the command in the editor of VISUAL.
    ed = os.path.join(home, "ed.sh")
    with open(ed, "w") as f:
        f.write("#!/bin/sh\nprintf 'puts edited' > \"$1\"\n")
    os.chmod(ed, 0o755)
    v = Session(home, {"VISUAL": ed})
    v.send(b"old\x18\x05", 1.0)
    v.send(b"\r")
    check("Ctrl-X Ctrl-E edits the command in VISUAL", "\nedited" in v.text(), v.text())
    v.close()

    # With `file`, Tab completes a file name, and a folder ends with a slash.
    work = os.path.join(home, "work")
    os.makedirs(os.path.join(work, "subdir"))
    open(os.path.join(work, "notes_one.txt"), "w").close()
    f = Session(home, cwd=work, args=("--allow", "file", "--root", "."))
    f.send(b"source note\t")
    check("Tab completes a file name", "notes_one.txt" in f.text(), f.text())
    f.send(b"\x15")
    f.raw = b""
    f.send(b"cd subd\t")
    check("Tab completes a folder with a slash", "subdir/" in f.text(), f.text())
    f.close()

    # Tab lists the methods of a TclOO object.
    o = Session(home)
    o.send(b"oo::class create Pt {method moveX {} {}; method moveY {} {}}\r")
    o.send(b"Pt create p1\r")
    o.raw = b""
    o.send(b"p1 mov\t")
    check("Tab lists the methods of an object", "moveX" in o.text() and "moveY" in o.text(), o.text())
    o.send(b"\x15")

    # A resize redraws a long command at the new width, and the shell goes on.
    o.send(b"set w " + b"x" * 70)
    o.raw = b""
    o.resize(24, 40)
    o.read(0.5)
    o.send(b"\r")
    check("a resize keeps the command", "x" * 70 in o.text().replace("\n", ""), o.text())
    o.raw = b""
    o.send(b"expr {6 * 7}\r")
    check("the shell runs commands after a resize", "\n42" in o.text(), o.text())
    o.close()

    # An rc file sets the prompt.
    with open(os.path.join(home, ".ztclrc"), "w") as f:
        f.write("proc myprompt {} {return {ztcl> }}\nshell prompt myprompt\n")
    w = Session(home)
    check("the rc file sets the prompt", "ztcl> " in w.text(), w.text())
    w.close()
finally:
    shutil.rmtree(home, ignore_errors=True)

print("failed: %d" % failed)
sys.exit(1 if failed else 0)
