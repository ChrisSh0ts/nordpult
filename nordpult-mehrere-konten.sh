#!/bin/bash
# Nordpult für MEHRERE macOS-Konten auf einem Mac (wechselt beim Kontowechsel automatisch mit).
# Für einen Mac mit nur einem Konto reicht nordpult-installieren.sh.
#
# Mehrere Konten: Das Programm liegt gemeinsam unter /Users/Shared/Nordpult. Jedes Konto, das Nordpult
# nutzen soll, führt dieses Skript einmal aus. Es läuft dann nur in dem Konto, das gerade vorne am
# Bildschirm ist, und wechselt beim Kontowechsel automatisch mit. Der Link fürs iPad bleibt gleich.
#
#   Im Download-Ordner (baut neu und aktualisiert das gemeinsame Programm, fragt bei Bedarf nach dem Passwort):
#       bash nordpult-mehrere-konten.sh
#   In jedem weiteren Konto (ohne eigenen Download):
#       bash /Users/Shared/Nordpult/nordpult-mehrere-konten.sh
#
# Ohne Optionen werden die bisherigen Einstellungen dieses Kontos übernommen (auch vom alten „oldphonedeck“).
# Optionen ersetzen sie, z. B.:  --lat 63.43 --lon 10.40 --place Trondheim --calendar "Bootshaus" --theme work
set -e
cd "$(dirname "$0")"
DIR="$(pwd)"
SHARED="/Users/Shared/Nordpult"
OLD_SHARED="/Users/Shared/oldphonedeck"
LABEL="com.nordpult"
OLD_LABEL="com.oldphonedeck"
AGENTS="$HOME/Library/LaunchAgents"
PLIST="$AGENTS/$LABEL.plist"
OLD_PLIST="$AGENTS/$OLD_LABEL.plist"
CONF="$HOME/.nordpult"
LOG="$CONF/log.txt"
BIN="$SHARED/app/Nordpult"

# 1. Programm bauen und ins gemeinsame Verzeichnis kopieren (nur im Download-Ordner).
if [ -f "$DIR/Package.swift" ]; then
  echo "Baue Nordpult …"
  swift build -c release
  SUDO=""
  if ! mkdir -p "$SHARED/app" 2>/dev/null || [ ! -w "$SHARED/app" ]; then
    echo "Das gemeinsame Verzeichnis braucht Administratorrechte – bitte Mac-Passwort eingeben:"
    SUDO="sudo"
    sudo mkdir -p "$SHARED/app"
  fi
  $SUDO rm -rf "$SHARED/app/Nordpult_Nordpult.bundle"
  $SUDO cp -R .build/release/Nordpult_Nordpult.bundle "$SHARED/app/"
  $SUDO rm -f "$SHARED/app/Nordpult.new"
  $SUDO cp .build/release/Nordpult "$SHARED/app/Nordpult.new"
  $SUDO mv -f "$SHARED/app/Nordpult.new" "$BIN"
  $SUDO cp nordpult-mehrere-konten.sh nordpult-entfernen.sh "$SHARED/"
  # Zugangscode fürs iPad: den bisherigen übernehmen, damit das Lesezeichen weiter passt.
  if [ ! -s "$SHARED/token" ]; then
    if [ -s "$OLD_SHARED/token" ]; then
      $SUDO cp "$OLD_SHARED/token" "$SHARED/token"
    elif [ -s "$HOME/.oldphonedeck/token" ]; then
      $SUDO cp "$HOME/.oldphonedeck/token" "$SHARED/token"
    else
      LC_ALL=C tr -dc 'abcdefghjkmnpqrstuvwxyz23456789' </dev/urandom | head -c 12 > /tmp/nordpult-token
      $SUDO cp /tmp/nordpult-token "$SHARED/token"; rm -f /tmp/nordpult-token
    fi
  fi
  $SUDO chmod -R a+rX "$SHARED"
  [ -n "$SUDO" ] && $SUDO chmod a+r "$SHARED/token"
elif [ ! -x "$BIN" ]; then
  echo "⚠️  Nordpult ist noch nicht unter $SHARED installiert."
  echo "   Zuerst im Download-Ordner bash nordpult-mehrere-konten.sh ausführen."
  exit 1
fi

# 2. Optionen: übergebene nehmen, sonst die bisherigen dieses Kontos (neuer oder alter Autostart).
args_from() {   # druckt die Programm-Optionen (ohne den Programmpfad) aus einer LaunchAgent-Datei, eine pro Zeile
  /usr/libexec/PlistBuddy -c "Print :ProgramArguments" "$1" 2>/dev/null | sed -e '1d' -e '$d' -e '2d' -e 's/^ *//'
}
OPTS=()
if [ $# -gt 0 ]; then
  OPTS=("$@")
else
  SRC=""
  [ -f "$PLIST" ] && SRC="$PLIST"
  [ -z "$SRC" ] && [ -f "$OLD_PLIST" ] && SRC="$OLD_PLIST"
  if [ -n "$SRC" ]; then
    while IFS= read -r line; do [ -n "$line" ] && OPTS+=("$line"); done < <(args_from "$SRC")
  fi
fi
[ ${#OPTS[@]} -gt 0 ] && echo "Einstellungen: ${OPTS[*]}"

# 3. Einstellungen vom alten Namen übernehmen (App-Tasten, Asana-Token).
if [ ! -d "$CONF" ] && [ -d "$HOME/.oldphonedeck" ]; then
  cp -R "$HOME/.oldphonedeck" "$CONF"
  rm -f "$CONF/log.txt"
  echo "Einstellungen aus ~/.oldphonedeck übernommen."
fi
mkdir -p "$AGENTS" "$CONF"

# 4. Alten Autostart (oldphonedeck) und laufende Versionen dieses Kontos beenden.
launchctl bootout "gui/$(id -u)/$OLD_LABEL" 2>/dev/null || true
rm -f "$OLD_PLIST"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -u "$(id -u)" -x oldphonedeck 2>/dev/null || true
pkill -u "$(id -u)" -x Nordpult 2>/dev/null || true
sleep 2

# 5. Neuen Autostart schreiben und starten.
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
ARGS=""
for a in "${OPTS[@]}"; do ARGS="$ARGS<string>$(xml "$a")</string>"; done
cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$BIN</string>$ARGS</array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
EOF
: > "$LOG"
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo "Warte auf den Start …"
for i in $(seq 1 30); do
  if grep -q "#k=" "$LOG" 2>/dev/null; then break; fi
  sleep 1
done

if grep -q "#k=" "$LOG" 2>/dev/null; then
  echo ""
  echo "✅ Nordpult läuft in diesem Konto und startet ab jetzt bei jeder Anmeldung automatisch."
  echo "   Link fürs iPad (gleich für alle Konten):"
  grep -m1 "#k=" "$LOG"
  echo ""
  echo "   Weiteres Konto einrichten oder umstellen: dort ausführen"
  echo "       bash $SHARED/nordpult-mehrere-konten.sh"
  echo "   Link später anzeigen:   grep -m1 '#k=' ~/.nordpult/log.txt"
  echo "   Autostart entfernen:    $SHARED/nordpult-entfernen.sh"
else
  echo "⚠️  Nordpult ist nicht gestartet. Letzte Meldungen:"
  tail -n 20 "$LOG"
  exit 1
fi
