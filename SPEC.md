# Specyfikacja projektu: lokalna aplikacja do dyktowania (macOS)

**Cel:** natywna aplikacja macOS działająca w tle (tray/menu bar), która po naciśnięciu globalnego skrótu klawiszowego nagrywa mowę, transkrybuje ją lokalnie, czyści tekst za pomocą lokalnego LLM-a i wstawia gotowy tekst w miejscu kursora — w pełni offline, bez żadnego API w chmurze.

Inspirowana funkcjonalnie przez Wispr Flow, ale zbudowana od zera, z innym stackiem technologicznym (w pełni lokalnym) i bez użycia jakiegokolwiek kodu źródłowego oryginalnej aplikacji.

---

## 1. Środowisko docelowe

- **System:** macOS (Apple Silicon)
- **Procesor testowy:** Apple M3
- **Wymagane uprawnienia systemowe:**
  - Microphone (nagrywanie audio)
  - Accessibility / Input Monitoring (globalny skrót klawiszowy + symulacja wpisywania tekstu)

---

## 2. Architektura — komponenty

| # | Komponent | Technologia | Rola |
|---|---|---|---|
| 1 | Warstwa UI/systemowa | Swift, `NSStatusItem`, `NSEvent` (global monitor) | ikona w tray, obsługa skrótu klawiszowego, ustawienia |
| 2 | Nagrywanie audio | `AVAudioEngine` | przechwytywanie mikrofonu do bufora/pliku WAV |
| 3 | Transkrypcja (STT) | **whisper.cpp**, model `medium`, akceleracja Metal/Core ML | zamiana audio → surowy tekst, lokalnie |
| 4 | Czyszczenie tekstu (LLM) | **MLX** + model **Qwen 2.5 7B Instruct** (skwantyzowany) | usuwanie wypełniaczy, poprawa interpunkcji/stylu, zachowanie intencji |
| 5 | Wstrzykiwanie tekstu | `CGEvent` (symulacja klawiatury), fallback: schowek + `Cmd+V` | wpisanie gotowego tekstu w aktywnym polu tekstowym |
| 6 | Orkiestracja | Swift jako proces główny, wywołujący whisper.cpp i MLX jako subprocesy lub przez lekki lokalny bridge (Python/FFI) | spina wszystkie kroki w jeden pipeline |

---

## 3. Przepływ działania (pipeline)

1. Użytkownik trzyma/przełącza globalny skrót klawiszowy.
2. `AVAudioEngine` nagrywa audio do momentu puszczenia skrótu (lub wykrycia ciszy — do ustalenia w trakcie implementacji).
3. Nagranie trafia do **whisper.cpp** → surowa transkrypcja tekstu.
4. Surowy tekst trafia do lokalnego **Qwen 2.5 7B** przez MLX z promptem systemowym typu:
   > "Popraw poniższy surowy zapis mowy: usuń wypełniacze i powtórzenia, popraw interpunkcję i gramatykę, zachowaj pierwotną intencję i znaczenie, nie dodawaj nowych treści. Zwróć wyłącznie poprawiony tekst."
5. Wynikowy tekst trafia do aktywnego pola tekstowego przez `CGEvent` (symulacja wpisywania) lub przez schowek.

---

## 4. Wymagane modele i biblioteki

- **whisper.cpp** — https://github.com/ggerganov/whisper.cpp (model `ggml-medium.bin`, ~1.5 GB)
- **MLX** — framework Apple do uruchamiania LLM na Apple Silicon (https://github.com/ml-explore/mlx)
- **mlx-lm** — narzędzia do ładowania modeli LLM w MLX
- **Qwen 2.5 7B Instruct** w formacie MLX (skwantyzowany, np. 4-bit, ~4–5 GB) — dostępny na Hugging Face w repozytoriach społeczności MLX

---

## 5. Etapy budowy (proponowana kolejność)

1. **Szkielet aplikacji menu bar** — pusta apka Swift z ikoną w tray, bez logiki
2. **Nagrywanie audio** — obsługa skrótu klawiszowego + zapis do pliku WAV, weryfikacja że nagranie działa
3. **Integracja whisper.cpp** — kompilacja/dołączenie whisper.cpp, wywołanie na nagranym pliku, wypisanie surowej transkrypcji do logów/konsoli
4. **Integracja MLX + Qwen** — pobranie modelu, wywołanie cleanup na przykładowym tekście, weryfikacja jakości promptu
5. **Wstrzykiwanie tekstu** — implementacja `CGEvent`, test wpisywania w różnych aplikacjach (Notatki, przeglądarka, terminal)
6. **Spięcie całego pipeline'u end-to-end**
7. **Uprawnienia systemowe i pierwsze uruchomienie** — obsługa promptów o Microphone/Accessibility, komunikaty dla użytkownika
8. **Dopracowanie UX** — wskaźnik nagrywania, ustawienia skrótu, ewentualny wybór modelu

---

## 6. Znane ograniczenia i kompromisy

- Lokalny model 7B nie dorówna jakością cleanup modelom chmurowym (GPT/Claude), ale powinien sobie radzić z podstawowym czyszczeniem wypełniaczy i stylu.
- Całkowity czas przetwarzania (transkrypcja + cleanup) będzie rzędu kilku sekund na M3, wolniej niż chmurowe rozwiązania.
- `CGEvent` może działać niespójnie w niektórych aplikacjach z niestandardową obsługą pól tekstowych — warto mieć fallback do schowka.

---

## 6a. Odstępstwa od pierwotnej specyfikacji (decyzje z implementacji)

Zapisane, żeby dokumentacja nie rozjechała się z kodem.

| Obszar | Pierwotnie | Faktycznie | Powód |
|---|---|---|---|
| Model STT | `ggml-medium.bin` (~1,5 GB) | `ggml-large-v3-turbo-q5_0.bin` (547 MB) | Lepszy dla polskiego, 3× mniejszy i szybszy jednocześnie. Istotne przy 16 GB RAM współdzielonym z Qwenem. |
| Wywołanie whisper | subprocess | C API w procesie (`libwhisper.dylib`) | Model ładuje się raz zamiast przy każdym dyktowaniu (~300 ms/wywołanie oszczędności), brak parsowania stdout. |
| Wykrywanie mowy | brak | Silero VAD (`ggml-silero-v5.1.2.bin`, 864 KB) | Bez tego turbo halucynuje na ciszy („Dzięki za oglądanie"). Efekt uboczny: 13× → 100× realtime. |
| Skrót push-to-talk | nieokreślony | prawy ⌘ | Prawy Alt odpada — na polskim układzie to AltGr do ą/ć/ę. |
| Format audio | WAV → whisper | próbki float32 w pamięci | Pomija zapis i odczyt pliku. WAV powstaje równolegle, ale służy już tylko do debugowania. |
| Model LLM | Qwen 2.5 7B Instruct | **Bielik** 4,5B i 11B (do wyboru w menu) | Bielik jest natywnie polski (SpeakLeash), Qwen tylko wielojęzyczny. Przy czyszczeniu polskiej mowy to zasadnicza różnica. |

### Etap 4 — czyszczenie tekstu

Prompt ze specyfikacji („usuń wypełniacze, popraw interpunkcję, zachowaj intencję")
okazał się **za słaby**: model przepisywał tekst zamiast go czyścić — zamieniał słowa
na synonimy, podnosił rejestr na urzędowy i dopisywał treść, której nie było.
Naprawione przez prompt zakazujący wprost każdej z tych rzeczy plus trzy przykłady
pokazujące oczekiwaną skalę ingerencji.

Statyczna część promptu (~500 tokenów) jest buforowana jako stan KV i kopiowana
pod każde zapytanie — bez tego samo jej przeliczanie kosztowało ~5 s za każdym razem.

Wyjście modelu przechodzi jeszcze przez `strip_commentary()`, bo mniejszy Bielik
mimo zakazu potrafi dokleić linijkę w stylu `(Uwaga: "Halo" jest standardowym
pozdrowieniem...)`, która trafiłaby prosto do pola tekstowego.

| | Bielik 4,5B | Bielik 11B |
|---|---|---|
| Czas / wypowiedź | 1,4–2,1 s | 5–10,5 s |
| Prędkość | ~26 tok/s | 13,6 tok/s |
| RAM | 2,7 GB | 6,3 GB |
| Wierność | średnia — potrafi zmienić sens („niech potwierdzi" → „potwierdź") | wysoka |

Oba modele są dostępne, przełącznik jest w menu, wybór zapisuje się w `UserDefaults`.
W pamięci nigdy nie siedzą oba naraz — zmiana modelu restartuje proces Pythona.

11B pracuje na 86% teoretycznego sufitu przepustowości pamięci M3 (~100 GB/s przy
modelu 6,3 GB daje ~15,8 tok/s) — szybciej się z niego nie da.

### Zmierzone na M3 (16 GB)

- Ładowanie modelu: 8,4 s na zimno, 0,5 s z cache dyskowego — dlatego model wczytuje się w tle przy starcie
- Transkrypcja: ~100× realtime z VAD (266 s audio → 2,7 s)

### Etap 5 — wstawianie tekstu

Dwie metody, przełączane w menu (**Wstawianie tekstu**):

- **Wpisywanie** (domyślne) — `CGEvent` z ustawionym napisem Unicode, porcjami po
  20 jednostek UTF-16. Polskie znaki działają niezależnie od układu klawiatury,
  bo nie mapujemy kodów klawiszy. Nie rusza schowka.
- **Wklejanie** — podmiana schowka i `Cmd+V`, potem przywrócenie poprzedniej
  zawartości po 400 ms. Szybsze przy długim tekście.

Szczegóły, które okazały się istotne:
- flagi zdarzeń są zerowane — bez tego wpisywanie dziedziczy modyfikatory
  trzymane akurat przez użytkownika i zamiast tekstu idą skróty klawiszowe
- porcje nie mogą rozcinać par zastępczych UTF-16 (emoji)
- wstawianie idzie poza głównym wątkiem, bo przerwy między porcjami
  zablokowałyby menu
- gdy wstawianie zawiedzie, tekst ląduje w schowku — użytkownik go nie traci

### Znane drobiazgi

- Ostrzeżenie linkera o `macOS-13.0` vs `26.0` — biblioteki whisper.cpp są budowane pod SDK hosta. Nieszkodliwe lokalnie; przy dystrybucji ustawić `CMAKE_OSX_DEPLOYMENT_TARGET`.
- Zabicie procesu w trakcie nagrywania zostawia WAV z niesfinalizowanym nagłówkiem. Naprawa: `scripts/repair_wav.py`.

---

## 7. Poza zakresem (na start)

- Tryb "always listening" z VAD (na start: przytrzymaj-i-puść)
- Command Mode (edycja głosowa zaznaczonego tekstu)
- Personalizacja słownika użytkownika
- Wersje na Windows/iOS
