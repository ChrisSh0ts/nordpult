#!/bin/bash
# Stoppt Nordpult und entfernt den Autostart für dieses Benutzerkonto.
launchctl bootout "gui/$(id -u)/com.nordpult" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/com.nordpult.plist"
pkill -u "$(id -u)" -x Nordpult 2>/dev/null || true
echo "Nordpult ist gestoppt und startet nicht mehr automatisch."
echo "Einstellungen und Programm löschen (optional):  rm -rf ~/.nordpult"
