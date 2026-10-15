"""Small cross-platform helpers: notifications, sound, opening files."""
import os, subprocess, sys

IS_MAC = sys.platform == "darwin"
IS_WIN = sys.platform == "win32"

_toast = None  # Windows: set by the tray app so notifications use the tray icon


def notify(title, msg):
    if IS_MAC:
        msg, title = msg.replace('"', "'"), title.replace('"', "'")
        subprocess.run(["osascript", "-e", f'display notification "{msg}" with title "{title}"'])
    elif _toast:
        _toast(title, msg)


def play_wav(path):
    if IS_MAC:
        subprocess.Popen(["afplay", path])
    elif IS_WIN:
        import winsound
        winsound.PlaySound(path, winsound.SND_FILENAME | winsound.SND_ASYNC)


def open_file(path):
    if IS_MAC:
        subprocess.run(["open", "-t", path])
    elif IS_WIN:
        os.startfile(path)
    else:
        subprocess.run(["xdg-open", path])
