#!/bin/bash
# Buduje MICFLOW.app — pakiet .app jest konieczny, żeby macOS w ogóle
# pokazał prompt o mikrofon i zapamiętał przyznane uprawnienia (TCC).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/build/MICFLOW.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Micflow"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN" "$APP/Contents/MacOS/Micflow"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

# Ikona pakietu. Generowana ze zrodla przez scripts/make_icon.py.
if [ -f "$ROOT/Resources/MICFLOW.icns" ]; then
    cp "$ROOT/Resources/MICFLOW.icns" "$APP/Contents/Resources/MICFLOW.icns"
else
    echo "UWAGA: brak Resources/MICFLOW.icns — pakiet dostanie ikone domyslna." >&2
fi

# Zapisujemy katalog projektu w Info.plist, żeby aplikacja znalazła modele
# i .venv także wtedy, gdy sam pakiet zostanie przeniesiony (np. do /Applications).
/usr/libexec/PlistBuddy -c "Add :MicflowProjectRoot string $ROOT" "$APP/Contents/Info.plist" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Set :MicflowProjectRoot $ROOT" "$APP/Contents/Info.plist"

# Biblioteki whisper.cpp/ggml. Binarka ma rpath @executable_path/../Frameworks,
# a same dylib-y odwołują się do siebie przez @rpath, więc rozwiążą się tutaj.
WHISPER_LIBS="$ROOT/vendor/whisper.cpp/build/bin"
if [ ! -f "$WHISPER_LIBS/libwhisper.dylib" ]; then
    echo "BŁĄD: brak bibliotek whisper.cpp. Uruchom najpierw scripts/build_whisper.sh" >&2
    exit 1
fi
cp "$WHISPER_LIBS"/libwhisper*.dylib "$WHISPER_LIBS"/libggml*.dylib "$APP/Contents/Frameworks/"

# Zagnieżdżone biblioteki podpisujemy przed pakietem — inaczej podpis
# aplikacji obejmie niepodpisaną zawartość i macOS odmówi uruchomienia.
for lib in "$APP/Contents/Frameworks"/*.dylib; do
    codesign --force --sign - "$lib" 2>/dev/null
done

# Stabilny identyfikator podpisu, żeby uprawnienia nie resetowały się
# przy każdej przebudowie.
codesign --force --sign - --identifier local.micflow.app "$APP"

echo "Zbudowano: $APP"

# macOS wiąże uprawnienie Accessibility z podpisem kodu. Przy podpisie ad-hoc
# każda zmiana kodu zmienia cdhash i uprawnienie przestaje obowiązywać —
# przy czym w Ustawieniach aplikacja nadal wygląda na zaznaczoną.
HASH_FILE="$ROOT/build/.last-cdhash"
CURRENT_HASH="$(codesign -d --verbose=4 "$APP" 2>&1 | awk -F'=' '/^CDHash=/{print $2}')"
PREVIOUS_HASH="$(cat "$HASH_FILE" 2>/dev/null || true)"
echo "$CURRENT_HASH" > "$HASH_FILE"

if [ -n "$PREVIOUS_HASH" ] && [ "$CURRENT_HASH" != "$PREVIOUS_HASH" ]; then
    echo
    echo "UWAGA: podpis się zmienił — uprawnienie Accessibility wygasło."
    echo "Ustawienia → Prywatność i ochrona → Dostępność:"
    echo "  usuń MICFLOW przyciskiem [-], dodaj ponownie [+], wskaż:"
    echo "  $APP"
fi
