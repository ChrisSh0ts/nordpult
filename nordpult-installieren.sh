#!/bin/bash
# Nordpult (Einzelplatz) installieren oder aktualisieren – für das aktuelle macOS-Benutzerkonto.
# Alles liegt in ~/.nordpult, Administratorrechte sind nicht nötig.
#
#   Erstinstallation / Update (im entpackten Ordner):   bash nordpult-installieren.sh
#   Nur Einstellungen ändern:                             bash ~/.nordpult/nordpult-installieren.sh
set -e
cd "$(dirname "$0")"
DIR="$(pwd)"
CONF="$HOME/.nordpult"
APP="$CONF/app"
BIN="$APP/Nordpult"
LABEL="com.nordpult"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$CONF/log.txt"

echo ""
echo "== Nordpult einrichten =="
echo "Enter übernimmt jeweils den Vorschlag in [Klammern]."
echo ""

# Bisherige Einstellungen als Vorschläge lesen.
get_opt() {   # get_opt --name  → Wert aus dem bestehenden Autostart (erstes Vorkommen)
  [ -f "$PLIST" ] || return 0
  /usr/libexec/PlistBuddy -c "Print :ProgramArguments" "$PLIST" 2>/dev/null | sed -e 's/^ *//' |
    awk -v k="$1" 'f { print; exit } $0 == k { f = 1 }'
}
get_all() {   # get_all --calendar → alle Werte, mit Komma getrennt
  [ -f "$PLIST" ] || return 0
  /usr/libexec/PlistBuddy -c "Print :ProgramArguments" "$PLIST" 2>/dev/null | sed -e 's/^ *//' |
    awk -v k="$1" 'f { printf "%s%s", (n++ ? ", " : ""), $0; f = 0; next } $0 == k { f = 1 }'
}
ask() {       # ask "Frage" "Vorschlag" → Antwort
  local a
  read -r -p "$1 [$2]: " a
  echo "${a:-$2}"
}

D=$(get_opt --place); PLACE=$(ask "Ort fürs Wetter (Name)" "${D:-Köln}")
D=$(get_opt --lat); LAT=$(ask "Breitengrad" "${D:-50.94}")
D=$(get_opt --lon); LON=$(ask "Längengrad" "${D:-6.96}")
CALS=$(ask "Kalender, mit Komma getrennt (leer = alle)" "$(get_all --calendar)")
THEME=$(ask "Look: work, privat oder leer" "$(get_opt --theme)")

mkdir -p "$CONF"
if [ -s "$CONF/asana-token" ]; then
  read -r -p "Asana ist eingerichtet. Neues Token eingeben? (j/N): " yn
else
  read -r -p "Asana-Aufgaben anzeigen? (j/N): " yn
fi
if [ "$yn" = "j" ] || [ "$yn" = "J" ]; then
  read -r -s -p "Asana-Token einfügen (wird nicht angezeigt): " TOK; echo ""
  if [ -n "$TOK" ]; then printf '%s' "$TOK" > "$CONF/asana-token"; chmod 600 "$CONF/asana-token"; fi
  unset TOK
fi

# Optionen zusammenstellen.
OPTS=()
[ -n "$PLACE" ] && OPTS+=(--place "$PLACE")
[ -n "$LAT" ] && OPTS+=(--lat "$LAT")
[ -n "$LON" ] && OPTS+=(--lon "$LON")
if [ -n "$CALS" ]; then
  IFS=',' read -r -a CLIST <<< "$CALS"
  for c in "${CLIST[@]}"; do
    c="$(echo "$c" | sed -e 's/^ *//' -e 's/ *$//')"
    [ -n "$c" ] && OPTS+=(--calendar "$c")
  done
fi
[ -n "$THEME" ] && OPTS+=(--theme "$THEME")

# Bauen und installieren (nur aus dem entpackten Ordner).
if [ -f "$DIR/Package.swift" ]; then
  echo ""
  echo "Baue Nordpult (1–2 Minuten) …"
  swift build -c release
  mkdir -p "$APP"
  rm -rf "$APP/Nordpult_Nordpult.bundle"
  cp -R .build/release/Nordpult_Nordpult.bundle "$APP/"
  rm -f "$APP/Nordpult.new"
  cp .build/release/Nordpult "$APP/Nordpult.new"
  mv -f "$APP/Nordpult.new" "$BIN"
  cp nordpult-installieren.sh nordpult-entfernen.sh "$CONF/"
elif [ ! -x "$BIN" ]; then
  echo "⚠️  Nordpult ist noch nicht installiert. Bitte im entpackten Ordner ausführen."
  exit 1
fi

# Autostart schreiben und (neu) starten.
xml() { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
ARGS=""
for a in "${OPTS[@]}"; do ARGS="$ARGS<string>$(xml "$a")</string>"; done
mkdir -p "$HOME/Library/LaunchAgents"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -u "$(id -u)" -x Nordpult 2>/dev/null || true
sleep 2
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
  grep -q "#k=" "$LOG" 2>/dev/null && break
  sleep 1
done
if grep -q "#k=" "$LOG" 2>/dev/null; then
  echo ""
  echo "✅ Nordpult läuft und startet ab jetzt bei jeder Anmeldung automatisch."
  echo "   Diesen Link auf dem iPad in Safari öffnen:"
  grep -m1 "#k=" "$LOG"
  echo ""
  echo "   Einstellungen ändern:  bash ~/.nordpult/nordpult-installieren.sh"
  echo "   Link später anzeigen:  grep -m1 '#k=' ~/.nordpult/log.txt"
  echo "   Entfernen:             bash ~/.nordpult/nordpult-entfernen.sh"
else
  echo "⚠️  Nordpult ist nicht gestartet. Letzte Meldungen:"
  tail -n 20 "$LOG"
  exit 1
fi
