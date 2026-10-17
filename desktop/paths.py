"""Where files live. From source everything stays in the project folder; a packaged app keeps user data
(config, timetable DB, state) in the per-user application-data folder so the app bundle can be read-only."""
import os, shutil, sys

FROZEN = bool(getattr(sys, "frozen", False)) or "RESOURCEPATH" in os.environ  # PyInstaller / py2app
if getattr(sys, "frozen", False) and hasattr(sys, "_MEIPASS"):
    BUNDLE = sys._MEIPASS
elif "RESOURCEPATH" in os.environ:
    BUNDLE = os.environ["RESOURCEPATH"]
else:
    BUNDLE = os.path.dirname(os.path.abspath(__file__))

if not FROZEN:
    USER = BUNDLE
elif sys.platform == "win32":
    USER = os.path.join(os.environ.get("APPDATA", os.path.expanduser("~")), "NextTrain")
else:
    USER = os.path.join(os.path.expanduser("~/Library/Application Support"), "NextTrain")

DATA = os.path.join(USER, "data")
DB = os.path.join(DATA, "rail.db")
STATE = os.path.join(DATA, "state.json")
CONFIG = os.path.join(USER, "config.json")
os.makedirs(DATA, exist_ok=True)

if not os.path.exists(CONFIG):
    shutil.copy(os.path.join(BUNDLE, "config.example.json"), CONFIG)
