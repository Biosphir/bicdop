"""Shell profiles and independent pseudo-terminal sessions."""

from dataclasses import dataclass
import os
from pathlib import Path
import re
from threading import Thread


@dataclass(frozen=True)
class Profile:
    id: str
    label: str
    executable: Path


def shell_profiles():
    if os.name == "nt":
        system = Path(os.environ.get("SystemRoot", r"C:\Windows")) / "System32"
        profiles = [
            Profile("powershell", "PowerShell", system / "WindowsPowerShell/v1.0/powershell.exe"),
            Profile("cmd", "Command Prompt", system / "cmd.exe"),
        ]
    else:
        executable = Path("/bin/bash") if Path("/bin/bash").exists() else Path("/bin/sh")
        profiles = [Profile("shell", "Shell", executable)]
    return [profile for profile in profiles if profile.executable.is_file()]


def valid_size(cols, rows):
    return type(cols) is int and type(rows) is int and 1 <= cols <= 500 and 1 <= rows <= 300


class Session:
    def __init__(self, profile, cols, rows, cwd, on_data, on_exit):
        self.on_data = on_data
        self.on_exit = on_exit
        self.closing = False
        env = {**os.environ, "TERM": "xterm-256color", "COLORTERM": "truecolor"}
        dimensions = rows, cols
        if os.name == "nt":
            from winpty import PtyProcess

            self.process = PtyProcess.spawn([str(profile.executable)], cwd=str(cwd),
                                            env=env, dimensions=dimensions)
            self.read = self.process.read
            self.write = self.process.write
            self.eof = EOFError
        else:
            from pexpect import EOF, spawn

            self.process = spawn(str(profile.executable), cwd=cwd, env=env,
                                 dimensions=dimensions, encoding="utf-8", codec_errors="replace")
            self.read = lambda size: self.process.read_nonblocking(size, timeout=None)
            self.write = self.process.send
            self.eof = EOF

    def start(self):
        Thread(target=self._read_output, daemon=True).start()

    def _read_output(self):
        code = 1
        try:
            while not self.closing:
                try:
                    output = self.read(4096)
                except self.eof:
                    if not self.closing:
                        code = self.process.wait()
                    break
                if output and not self.closing:
                    self.on_data(output)
        except OSError as error:
            if not self.closing:
                self.on_data(f"\r\nTerminal error: {error}\r\n")
        finally:
            if not self.closing:
                self.on_exit(code if code is not None else 1)

    def resize(self, cols, rows):
        self.process.setwinsize(rows, cols)

    def close(self):
        self.closing = True
        self.process.close(force=True)


class TerminalSessions:
    def __init__(self, profiles, cwd, notify):
        self.profiles = {profile.id: profile for profile in profiles}
        self.cwd = cwd
        self.notify = notify
        self.sessions = {}

    def open(self, session_id, profile_id, cols, rows):
        if (not isinstance(session_id, str) or not re.fullmatch(r"[a-f0-9-]{36}", session_id)
                or profile_id not in self.profiles or not valid_size(cols, rows)
                or session_id in self.sessions or len(self.sessions) >= 24):
            raise ValueError("Invalid terminal session or session limit reached.")
        session = Session(
            self.profiles[profile_id], cols, rows, self.cwd,
            lambda data: self.notify({"id": session_id, "data": data}),
            lambda code: self.notify({"id": session_id, "exitCode": code}),
        )
        self.sessions[session_id] = session
        session.start()

    def write(self, session_id, data):
        if isinstance(data, str) and session_id in self.sessions:
            self.sessions[session_id].write(data)

    def resize(self, session_id, cols, rows):
        if valid_size(cols, rows) and session_id in self.sessions:
            self.sessions[session_id].resize(cols, rows)

    def close(self, session_id):
        session = self.sessions.pop(session_id, None)
        if session is not None:
            session.close()

    def close_all(self):
        for session_id in list(self.sessions):
            try:
                self.close(session_id)
            except OSError as error:
                print(f"Terminal cleanup failed: {error}")
