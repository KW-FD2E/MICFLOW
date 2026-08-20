#!/bin/bash
# Buduje Dyktowanie.app — pakiet .app jest konieczny, żeby macOS w ogóle
# pokazał prompt o mikrofon i zapamiętał przyznane uprawnienia (TCC).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/build/Dyktowanie.app"

cd "$ROOT"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/DyktowanieApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"

cp "$BIN" "$APP/Contents/MacOS/DyktowanieApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"

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
codesign --force --sign - --identifier local.dyktowanie.app "$APP"

echo "Zbudowano: $APP"
