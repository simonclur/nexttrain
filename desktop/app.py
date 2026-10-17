"""Entry point: picks the menu-bar app on macOS and the tray app on Windows."""
import sys

if __name__ == "__main__":
    if sys.platform == "darwin":
        from menubar import App
        App().run()
    elif sys.platform == "win32":
        from tray_win import TrayApp
        TrayApp().run()
    else:
        sys.exit("Supported platforms: macOS and Windows")
