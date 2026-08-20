#!/bin/bash
# Instaluje aplikację w /Applications, żeby dało się ją uruchamiać z Launchpada,
# Spotlighta i Docka — bez terminala.
#
# Katalog build/ jest kasowany przy każdej przebudowie, więc nie nadaje się
# na docelowe miejsce dla ikony w Docku.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/build/Dyktowanie.app"
# Konto uzytkownika nie musi nalezec do grupy admin, a /Applications tego wymaga.
# ~/Applications dziala tak samo dla Launchpada, Spotlighta i Docka.
APPS="${APPS_DIR:-$HOME/Applications}"
TARGET="$APPS/Dyktowanie.app"
mkdir -p "$APPS"

if [ ! -d "$SOURCE" ]; then
    echo "BŁĄD: brak $SOURCE. Uruchom najpierw scripts/bundle.sh" >&2
    exit 1
fi

# Działającą aplikację trzeba zamknąć, inaczej podmiana pliku ją wywróci.
if pgrep -f "Dyktowanie.app/Contents/MacOS" >/dev/null 2>&1; then
    echo "==> Zamykam działającą aplikację"
    pkill -f "Dyktowanie.app/Contents/MacOS" || true
    sleep 1
fi

echo "==> Instaluję w $APPS"
rm -rf "$TARGET"
cp -R "$SOURCE" "$TARGET"

# Podpis trzeba odnowić po kopiowaniu, bo cp gubi część atrybutów.
for lib in "$TARGET/Contents/Frameworks"/*.dylib; do
    [ -e "$lib" ] && codesign --force --sign - "$lib" 2>/dev/null
done
codesign --force --sign - --identifier local.dyktowanie.app "$TARGET"

echo "Zainstalowano: $TARGET"
echo
echo "UWAGA: to nowa lokalizacja, więc uprawnienie Accessibility trzeba"
echo "przyznać dla niej od nowa:"
echo "  Ustawienia → Prywatność i ochrona → Dostępność"
echo "  usuń stary wpis [-], dodaj [+] i wskaż: $TARGET"
