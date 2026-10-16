"""py2app build script (macOS): python setup.py py2app"""
from setuptools import setup

setup(
    name="Next Train",
    app=["app.py"],
    data_files=["config.example.json"],
    options={"py2app": {
        "argv_emulation": False,
        "plist": {
            "CFBundleName": "Next Train",
            "CFBundleDisplayName": "Next Train",
            "CFBundleIdentifier": "com.simonclur.nexttrain",
            "CFBundleShortVersionString": "1.0",
            "LSUIElement": True,  # menu-bar only, no Dock icon
            "NSLocationWhenInUseUsageDescription": "Next Train uses your location to find the nearest station.",
        },
        "packages": ["rumps", "tzdata"],
        "includes": ["google.protobuf", "google.transit.gtfs_realtime_pb2", "menubar", "engine", "core", "osutil", "paths", "sound", "build_data"],
        "excludes": ["tkinter", "pystray", "PIL"],
    }},
    setup_requires=["py2app"],
)
