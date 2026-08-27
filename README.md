# MICFLOW

Dyktowanie głosowe dla macOS, działające **w pełni offline**. Przytrzymujesz
skrót, mówisz, a gotowy tekst pojawia się w miejscu kursora — w dowolnej
aplikacji. Nagranie nie opuszcza komputera.

Obsługuje polski i angielski, z automatycznym wykrywaniem języka.

## Zanim zainwestujesz czas

To narzędzie zbudowane **dla siebie** — po części z ciekawości, po części
żeby sprawdzić, jak daleko da się zajść bez chmury. Udostępnione na wypadek,
gdyby przydało się komuś jeszcze. Nie jest produktem i nie udaje nim być.

**Działa solidnie, ale wolniej niż rozwiązania komercyjne.** Po zakończeniu
mówienia trzeba odczekać kilka sekund, zanim tekst się pojawi. Lwia część tego
czasu to nie transkrypcja — ta jest szybka — tylko czyszczenie tekstu przez
model językowy. To cena za to, że wszystko dzieje się na Twoim komputerze:
tam, gdzie Wispr Flow czy Superwhisper wysyłają nagranie do serwerowni z kartami
za dziesiątki tysięcy dolarów, tutaj pracuje procesor laptopa.

Nie da się tego istotnie przyspieszyć bez ustępstw. Model działa już na 86%
teoretycznej przepustowości pamięci M3, a mniejszy wariant, który sprawdzałem,
potrafił zmieniać sens wypowiedzi — co przy dyktowaniu wiadomości jest
gorsze niż czekanie. Jeśli zależy Ci na natychmiastowym efekcie, komercyjne
narzędzia będą lepszym wyborem. Jeśli na tym, żeby Twój głos nigdy nie opuścił
komputera — to jest właśnie ten kompromis.

**Testowane na jednym komputerze** — MacBook Air M3, macOS 26, polski układ
klawiatury, jeden użytkownik. Nie wiem, jak zachowa się przy dwóch monitorach,
zewnętrznym mikrofonie czy innej konfiguracji.

**Wymagania są ostre:** Mac z Apple Silicon (na Intelu nie zadziała w ogóle),
~7 GB miejsca na modele, komfortowo od 16 GB RAM. Nie ma gotowej paczki —
budujesz ze źródeł.

**Aplikacja jest podpisana ad-hoc**, co ma jedną uciążliwą konsekwencję: każda
przebudowa unieważnia zgodę na Dostępność, a w Ustawieniach systemowych nadal
wygląda ona na przyznaną. Trzeba wtedy usunąć wpis i dodać go od nowa.
To najczęstsza przyczyna „przestało działać".

**Modele mają własne licencje**, odrębne od kodu — wszystkie permisywne:
Whisper i Silero VAD na MIT, Bielik na Apache 2.0. Użycie komercyjne
i redystrybucja są dozwolone. Szczegóły w [LICENSES-MODELI.md](LICENSES-MODELI.md).

Nie obiecuję wsparcia ani rozwoju. Kod jest na licencji MIT — rób z nim,
co chcesz.

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

Skrót `fn` działa dwojako i **sam rozpoznaje, o który tryb chodzi**:
przytrzymaj i mów, albo kliknij dwa razy, żeby nagrywać bez trzymania —
wtedy kolejne kliknięcie kończy.

Przy prawej krawędzi ekranu pojawia się granatowa pastylka z paskami
reagującymi na głos. Po zakończeniu mówienia przechodzi w stan przetwarzania
i znika, gdy tekst trafi na miejsce.

Tekst wpisuje się tam, gdzie stoi kursor. Jeśli nie ma gdzie pisać — bo
kliknąłeś w pulpit — zamiast tego pojawia się panel z podyktowanym tekstem
i przyciskiem kopiowania, który znika sam po 15 sekundach.

W menu paska można zmienić język, skrót, dźwięki i autostart. **Diagnostyka…** pokazuje stan wszystkich
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

**Wracasz do projektu po przerwie?** Zacznij od sekcji 9 w SPEC.md: od czego
zacząć, jak sprawdzić aplikację bez mikrofonu, co zostało otwarte i czego
nie ruszać bez powodu.

## Licencja i pochodzenie

Kod na licencji [MIT](LICENSE). Zbudowane od zera — inspirowane funkcjonalnie
przez Wispr Flow, bez użycia jej kodu.

Korzysta z [whisper.cpp](https://github.com/ggerganov/whisper.cpp) (MIT),
[MLX](https://github.com/ml-explore/mlx) (MIT), [Silero VAD](https://github.com/snakers4/silero-vad)
oraz modelu [Bielik](https://huggingface.co/speakleash) od SpeakLeash.

Pobierane modele mają własne licencje, niezależne od licencji tego kodu —
Whisper i Silero VAD na MIT, Bielik na Apache 2.0. Wszystkie permisywne.
