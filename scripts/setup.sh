#!/bin/bash
# Odtwarza zależności, których nie trzymamy w repozytorium (~900 MB):
# cmake, źródła whisper.cpp oraz modele Whisper i VAD.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CMAKE_VERSION="4.4.2"
WHISPER_MODEL="ggml-large-v3-turbo-q5_0.bin"
VAD_MODEL="ggml-silero-v5.1.2.bin"

# Modele i srodowisko Pythona trzymamy poza katalogiem projektu, zeby jego
# przeniesienie nie psulo zainstalowanej aplikacji.
RUNTIME="$HOME/Library/Application Support/MICFLOW"
mkdir -p "$ROOT/vendor" "$RUNTIME/models"

# cmake — na tym Macu nie ma Homebrew, więc trzymamy go lokalnie.
if [ ! -x "$ROOT/vendor/cmake/CMake.app/Contents/bin/cmake" ] && ! command -v cmake >/dev/null; then
    echo "==> Pobieram cmake $CMAKE_VERSION"
    curl -L --progress-bar -o "$ROOT/vendor/cmake.tar.gz" \
        "https://github.com/Kitware/CMake/releases/download/v$CMAKE_VERSION/cmake-$CMAKE_VERSION-macos-universal.tar.gz"
    tar xzf "$ROOT/vendor/cmake.tar.gz" -C "$ROOT/vendor"
    rm "$ROOT/vendor/cmake.tar.gz"
    mv "$ROOT/vendor/cmake-$CMAKE_VERSION-macos-universal" "$ROOT/vendor/cmake"
fi

if [ ! -d "$ROOT/vendor/whisper.cpp" ]; then
    echo "==> Klonuję whisper.cpp"
    git clone --depth 1 https://github.com/ggerganov/whisper.cpp.git "$ROOT/vendor/whisper.cpp"
fi

if [ ! -f "$RUNTIME/models/$WHISPER_MODEL" ]; then
    echo "==> Pobieram model Whisper (547 MB)"
    curl -L --progress-bar -o "$RUNTIME/models/$WHISPER_MODEL" \
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/$WHISPER_MODEL"
fi

if [ ! -f "$RUNTIME/models/$VAD_MODEL" ]; then
    echo "==> Pobieram model VAD (864 KB)"
    curl -L --progress-bar -o "$RUNTIME/models/$VAD_MODEL" \
        "https://huggingface.co/ggml-org/whisper-vad/resolve/main/$VAD_MODEL"
fi

if [ ! -x "$RUNTIME/venv/bin/python" ]; then
    echo "==> Tworzę środowisko Pythona dla MLX"
    python3 -m venv "$RUNTIME/venv"
    # "python -m pip", nie "pip" — skrypt pip ma wpisaną ścieżkę bezwzględną
    # i przestaje działać, gdyby katalog kiedykolwiek się przeniósł.
    "$RUNTIME/venv/bin/python" -m pip install --quiet --upgrade pip
    "$RUNTIME/venv/bin/python" -m pip install --quiet mlx-lm huggingface_hub
fi

# Modele LLM trafiają do wspólnego cache Hugging Face, nie do katalogu projektu.
echo "==> Pobieram model Bielik (6,3 GB)"
"$RUNTIME/venv/bin/python" - <<'PY'
from huggingface_hub import snapshot_download
snapshot_download("speakleash/Bielik-11B-v3.0-Instruct-MLX-4bit")
PY

echo "==> Buduję whisper.cpp"
"$ROOT/scripts/build_whisper.sh"

echo "==> Buduję aplikację"
"$ROOT/scripts/bundle.sh"

echo
echo "==> Instaluję w ~/Applications"
"$ROOT/scripts/install.sh"
