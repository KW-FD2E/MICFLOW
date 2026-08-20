#!/bin/bash
# Buduje whisper.cpp z akceleracją Metal. Uruchom raz po sklonowaniu projektu
# (albo po aktualizacji vendor/whisper.cpp).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WHISPER="$ROOT/vendor/whisper.cpp"
CMAKE="$ROOT/vendor/cmake/CMake.app/Contents/bin/cmake"

if [ ! -x "$CMAKE" ]; then
    # Na tym Macu nie ma Homebrew, więc cmake trzymamy lokalnie w vendor/.
    CMAKE="$(command -v cmake || true)"
    if [ -z "$CMAKE" ]; then
        echo "BŁĄD: brak cmake. Pobierz go do vendor/cmake albo zainstaluj systemowo." >&2
        exit 1
    fi
fi

cd "$WHISPER"
"$CMAKE" -B build \
    -DCMAKE_BUILD_TYPE=Release \
    -DGGML_METAL=ON \
    -DWHISPER_BUILD_TESTS=OFF \
    -DWHISPER_BUILD_SERVER=OFF
"$CMAKE" --build build --config Release -j "$(sysctl -n hw.ncpu)"

echo "whisper.cpp gotowy: $WHISPER/build/bin"
