# MICFLOW

Dyktowanie głosowe dla macOS, działające **w pełni offline**. Przytrzymujesz
skrót, mówisz, a gotowy tekst pojawia się w miejscu kursora — w dowolnej
aplikacji. Nagranie nie opuszcza komputera.

Obsługuje polski i angielski, z automatycznym wykrywaniem języka.

## Jak to działa

```
mikrofon → whisper.cpp (Metal) → Bielik przez MLX → CGEvent → kursor
```

| Krok | Technologia |
|---|---|
| Nagrywanie | `AVAudioEngine`, 16 kHz mono |
| Transkrypcja | whisper.cpp, `large-v3-turbo-q5_0` + Silero VAD |
| Czyszczenie tekstu | Bielik 11B (MLX), lokalnie |
| Wstawianie | `CGEvent` z napisem Unicode |

Czyszczenie usuwa wypełniacze i poprawia interpunkcję, zachowując Twoje słowa —
nie przepisuje wypowiedzi własnym stylem.

## Wymagania

- **Mac z Apple Silicon** (M1 lub nowszy) — MLX i Metal nie działają na Intelu
- macOS 13 lub nowszy
- Xcode Command Line Tools (`xcode-select --install`)
- `python3`
- ~7 GB miejsca na modele

## Instalacja

```bash
git clone <adres-repozytorium> MICFLOW
cd MICFLOW
./scripts/setup.sh
```

Skrypt pobiera cmake, whisper.cpp i modele, buduje wszystko i instaluje
aplikację w `~/Applications`. Zajmuje kilkanaście minut, głównie na pobieranie.

Potem przeciągnij `~/Applications/MICFLOW.app` do Docka.

## Uprawnienia

Przy pierwszym uruchomieniu macOS poprosi o **mikrofon** i **Dostępność**.
Bez tego drugiego nie zadziała ani skrót, ani wpisywanie tekstu.

Jeśli używasz skrótu `fn`, ustaw **Ustawienia → Klawiatura → „Naciśnięcie
klawisza 🌐"** na **„Nie wykonuj nic"** — inaczej system przechwyci klawisz
na panel emoji.

> **Uwaga po każdej przebudowie:** aplikacja jest podpisana ad-hoc, więc zmiana
> kodu unieważnia zgodę na Dostępność. W Ustawieniach nadal wygląda na przyznaną.
> Trzeba usunąć wpis `[-]` i dodać `[+]` ponownie. `scripts/bundle.sh` o tym
> przypomina.

## Używanie

Domyślnie: **dwuklik `fn`** zaczyna nagrywanie, kolejne kliknięcie kończy.

Przy prawej krawędzi ekranu pojawia się granatowa pastylka z paskami
reagującymi na głos. Po zakończeniu mówienia przechodzi w stan przetwarzania
i znika, gdy tekst trafi na miejsce.

Tekst wpisuje się tam, gdzie stoi kursor. Jeśli nie ma gdzie pisać — bo
kliknąłeś w pulpit — zamiast tego pojawia się panel z podyktowanym tekstem
i przyciskiem kopiowania, który znika sam po 15 sekundach.

W menu paska można zmienić język, skrót, sposób nagrywania (dwuklik albo
przytrzymanie), dźwięki i autostart. **Diagnostyka…** pokazuje stan wszystkich
elementów — od niej zacznij, gdy coś nie działa.

## Gdzie co leży

| Co | Gdzie |
|---|---|
| Aplikacja | `~/Applications/MICFLOW.app` |
| Modele i środowisko Pythona | `~/Library/Application Support/MICFLOW/` |
| Model Bielik | `~/.cache/huggingface/` |

Katalog z kodem zawiera wyłącznie źródła — można go przenieść, przemianować
albo usunąć bez wpływu na działającą aplikację.

## Dokumentacja

[SPEC.md](SPEC.md) opisuje architekturę, pomiary wydajności i decyzje podjęte
przy budowie — razem z pułapkami, na które warto uważać przy zmianach.

## Licencja i pochodzenie

Zbudowane od zera. Inspirowane funkcjonalnie przez Wispr Flow, bez użycia jej
kodu. Korzysta z [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (MIT),
[MLX](https://github.com/ml-explore/mlx) (MIT) oraz modelu
[Bielik](https://huggingface.co/speakleash) od SpeakLeash.
