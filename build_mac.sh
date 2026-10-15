#!/bin/bash
# Builds dist/NextTrain.dmg (macOS). Run from the project folder: ./build_mac.sh
set -euo pipefail
cd "$(dirname "$0")"
PY=.venv/bin/python
$PY -m pip install -q py2app tzdata -r requirements.txt
rm -rf build dist
$PY setup.py py2app
codesign --force --deep -s - "dist/Next Train.app"   # ad-hoc signature; not notarised

STAGE=$(mktemp -d)
cp -R "dist/Next Train.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Next Train" -srcfolder "$STAGE" -ov -format UDZO dist/NextTrain.dmg
rm -rf "$STAGE"
echo "Built dist/NextTrain.dmg"
