"""Bicdop's Python desktop host."""

from pathlib import Path
import sys

from PySide6.QtCore import QObject, QSettings, QUrl, Qt, Signal, Slot
from PySide6.QtWebChannel import QWebChannel
from PySide6.QtWebEngineCore import QWebEnginePage
from PySide6.QtWebEngineWidgets import QWebEngineView
from PySide6.QtWidgets import QApplication, QMainWindow

from sessions import TerminalSessions, shell_profiles


class TerminalBridge(QObject):
    event = Signal("QVariantMap")
    _pty_event = Signal(dict)

    def __init__(self, clipboard, parent):
        super().__init__(parent)
        self.clipboard = clipboard
        self.settings = QSettings()
        self.manager = TerminalSessions(shell_profiles(), Path.home(), self._pty_event.emit)
        self._pty_event.connect(self.deliver, Qt.ConnectionType.QueuedConnection)
        self.actions = {
            "profiles": self.profiles,
            "setDefault": self.set_default,
            "open": self.manager.open,
            "write": self.manager.write,
            "resize": self.manager.resize,
            "close": self.manager.close,
            "readClipboard": self.clipboard.text,
            "writeClipboard": self.clipboard.setText,
        }

    @Slot(dict)
    def deliver(self, payload):
        session_id = payload["id"]
        if session_id not in self.manager.sessions:
            return
        self.event.emit(payload)
        if "exitCode" in payload:
            self.manager.close(session_id)

    def profiles(self):
        profiles = self.manager.profiles
        default = self.settings.value("terminal/defaultProfile", "", type=str)
        return {
            "profiles": [{"id": profile.id, "label": profile.label} for profile in profiles.values()],
            "defaultProfile": default if default in profiles else next(iter(profiles), ""),
        }

    def set_default(self, profile_id):
        if profile_id not in self.manager.profiles:
            raise ValueError("Unknown shell profile.")
        self.settings.setValue("terminal/defaultProfile", profile_id)

    @Slot(str, "QVariantList", result="QVariantMap")
    def request(self, action, args):
        try:
            return {"value": self.actions[action](*args)}
        except (KeyError, TypeError, ValueError, OSError, RuntimeError) as error:
            return {"error": str(error)}


class TerminalPage(QWebEnginePage):
    def __init__(self, start_url, parent):
        super().__init__(parent)
        self.start_url = start_url

    def acceptNavigationRequest(self, url, navigation_type, is_main_frame):
        return is_main_frame and url == self.start_url


class TerminalWindow(QMainWindow):
    def __init__(self, clipboard):
        super().__init__()
        self.setWindowTitle("Bicdop")
        self.resize(1080, 720)
        self.setMinimumSize(520, 330)

        url = QUrl.fromLocalFile(str(Path(__file__).resolve().with_name("index.html")))
        self.view = QWebEngineView(self)
        self.page = TerminalPage(url, self.view)
        self.view.setPage(self.page)
        self.setCentralWidget(self.view)
        self.bridge = TerminalBridge(clipboard, self)
        self.channel = QWebChannel(self.page)
        self.channel.registerObject("terminal", self.bridge)
        self.page.setWebChannel(self.channel)
        self.page.renderProcessTerminated.connect(lambda *_: self.bridge.manager.close_all())
        self.view.load(url)

    def closeEvent(self, event):
        self.bridge.manager.close_all()
        super().closeEvent(event)


def main():
    app = QApplication(sys.argv)
    app.setOrganizationName("BIOSPHIR")
    app.setApplicationName("Bicdop Desktop")
    window = TerminalWindow(app.clipboard())
    window.show()
    return app.exec()


if __name__ == "__main__":
    raise SystemExit(main())
