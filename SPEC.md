# MICFLOW — lokalna aplikacja do dyktowania (macOS)

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

### Etap 8 — dopracowanie

- **Skrót**: domyślnie `fn`, przełączalny w menu (fn / prawy ⌘ / prawy ⌥).
  Wymaga ustawienia systemowego „Naciśnięcie klawisza 🌐" na „Nie wykonuj nic",
  inaczej macOS przechwytuje klawisz na panel emoji (`AppleFnUsageType`).
- **Uruchamianie przy starcie**: `SMAppService.mainApp` (macOS 13+).
- **Dźwięki**: syntezowane, nie systemowe — dwa dźwięki E5↔B5 z miękkim atakiem
  (8 ms) i wykładniczym wybrzmieniem, plus cicha oktawa dla ciepła barwy.
  Start rośnie, koniec opada.
- **Diagnostyka** pokazuje licznik zadziałań skrótu i ostatni kod klawisza,
  co pozwala odróżnić „system nie przepuszcza zdarzeń" od błędu w aplikacji.

### Pułapka: uprawnienie Accessibility a podpis kodu

macOS wiąże zgodę Accessibility z podpisem kodu. Przy podpisie ad-hoc **każda
zmiana kodu zmienia cdhash i unieważnia zgodę**, przy czym aplikacja nadal
figuruje jako zaznaczona w Ustawieniach. Trzeba ją usunąć `[-]` i dodać `[+]`
ponownie. `scripts/bundle.sh` wykrywa zmianę cdhash i o tym przypomina.

### Tryby nagrywania i wskaźnik

- **Sposób nagrywania** (menu): „Przytrzymanie" albo „Dwuklik włącza, klik wyłącza"
  (domyślny). W trybie dwukliku okno czasowe to 450 ms; gdy nagranie trwa,
  pojedyncze kliknięcie je kończy.
- **Wskaźnik**: pływająca plakietka `NSPanel` przy kursorze tekstowym —
  niebieska „Słucham…" z pulsującą kropką, potem indygo „Przetwarzam…".
  Pozycja z Accessibility API (`kAXBoundsForRangeParameterizedAttribute`),
  a gdy aplikacja jej nie udostępnia — przy wskaźniku myszy. Panel jest
  `nonactivating` i `ignoresMouseEvents`, żeby nie odebrał fokusu polu tekstowemu.
- **Nagrania WAV**: na dysku zostaje tylko ostatnie. Poprzednie kasuje się
  w chwili rozpoczęcia nowego.

### Ścieżka projektu wyliczana w czasie działania

`ModelLocator.projectRoot` brał się z `#filePath`, czyli ze ścieżki z chwili
kompilacji — przeniesienie folderu projektu psuło wyszukiwanie modeli i `.venv`.
Teraz liczy się od położenia pakietu `.app` (`<projekt>/build/Dyktowanie.app`),
z weryfikacją po obecności `Package.swift`.

### Instalacja i uruchamianie bez terminala

`scripts/install.sh` kopiuje pakiet do `~/Applications` — nie do `/Applications`,
bo to wymaga przynależności do grupy `admin`, której konto mieć nie musi.
Z `~/Applications` aplikacja jest widoczna w Launchpadzie, Spotlighcie i można
ją przeciągnąć do Docka.

Katalog `build/` nie nadaje się na docelową lokalizację, bo `bundle.sh` kasuje
go przy każdej przebudowie.

Ponieważ zainstalowany pakiet stoi poza katalogiem projektu, `bundle.sh` wpisuje
ścieżkę projektu do `Info.plist` pod kluczem `DyktowanieProjectRoot`.
`ModelLocator` czyta ją w pierwszej kolejności — bez tego zainstalowana kopia
nie znalazłaby modeli ani `.venv`.

### Praca bez internetu

Cały pipeline jest lokalny — sieć była potrzebna wyłącznie do pobrania modeli.
Sprawdzone przy ruchu skierowanym w nieosiągalne proxy: transkrypcja i czyszczenie
działają normalnie.

`TextCleaner` ustawia procesowi Pythona `HF_HUB_OFFLINE=1` i `TRANSFORMERS_OFFLINE=1`.
Bez tego `huggingface_hub` przy każdym starcie odpytuje Hub o nowszą wersję modelu:
przy całkowitym braku sieci odbija się od razu, ale przy połączeniu zerwanym
(portal logowania) czekałby na timeout. Efekt uboczny wymuszenia trybu offline —
start modelu skrócił się z 7,4 s do 5,1 s.


### Uproszczenia interfejsu

Z menu i z kodu usunięte, żeby aplikacja była zrozumiała dla kogoś, kto jej nie budował:

| Usunięte | Powód |
|---|---|
| Bielik 4,5B („szybki") | Potrafił zmieniać sens („niech potwierdzi" → „potwierdź"). Zostaje wyłącznie 11B. |
| Prawy ⌥ jako skrót | Na polskim układzie to AltGr do ą, ć, ę — dyktowanie zjadałoby diakrytyki. |
| Wklejanie ze schowka | Szybsze przy długim tekście, ale na ułamek sekundy podmieniało schowek użytkownika. Zostaje wpisywanie przez `CGEvent`. |
| Podmenu „Czyszczenie tekstu" i „Wstawianie tekstu" | Wymagały wiedzy o wnętrzu aplikacji; teraz oba działają w jednym, sprawdzonym trybie. |

W menu zostały: nagrywanie ręczne, kopiowanie transkrypcji, podgląd nagrania,
skrót, sposób nagrywania, dźwięki, autostart i diagnostyka.

### Języki

Menu **Języki**: Polski (domyślny), English, Automatycznie.

Zmiana obejmuje dwa niezależne miejsca — samo przestawienie Whispera nie wystarcza:

- **Whisper** dostaje kod języka przy każdym wywołaniu, więc przełączenie działa
  natychmiast, bez przeładowania modelu. `"auto"` włącza wykrywanie z audio.
- **Bielik** dostaje osobny prompt systemowy i własne przykłady dla każdego języka.
  Polski prompt na angielskim tekście powoduje **tłumaczenie**, nie redakcję:
  `"we should ship this feature next week"` → „Powinniśmy wypuścić tę funkcję…".

W trybie automatycznym język wykryty przez Whispera (`whisper_full_lang_id`)
jest przekazywany dalej do Bielika, żeby dobrał właściwy prompt.

Prefiksy promptów są buforowane osobno dla każdego języka — koszt jednorazowy
przy starcie, potem zero.

Zmierzone na próbce angielskiej (jfk.wav) w trybie automatycznym: wykryto `en`,
transkrypcja poprawna, Bielik nie przetłumaczył. Jakość redakcji angielskiej
jest dobra — zachowuje potoczne formy („gonna" zostaje „gonna").

**Domyślny pozostaje Polski**, bo przy bardzo krótkich wypowiedziach automatyczne
wykrywanie bywa zawodne (kilka polskich słów potrafi zostać uznane za czeskie).

### Ikona

`scripts/make_icon.py` robi `Resources/MICFLOW.icns` z obrazka źródłowego:
przycina białe tło, nakłada maskę zaokrąglonego kwadratu (inaczej w Docku widać
białe narożniki) i generuje wszystkie rozmiary dla `iconutil`.

Maska jest o ~1,2% mniejsza od kadru — źródło ma wokół kształtu delikatny cień,
który bez tego zostawał w narożnikach jako ciemne zadziory. Zawartość zajmuje
824 z 1024 px, zgodnie z proporcją, jakiej macOS używa dla ikon aplikacji.

### Pułapka: ścieżki bezwzględne zapamiętane w narzędziach

Przeniesienie katalogu projektu psuje trzy rzeczy naraz, każdą po cichu:

| Co | Objaw | Naprawa |
|---|---|---|
| `.venv/bin/pip` | `bad interpreter: no such file` | odtworzyć `.venv` |
| Cache cmake | „CMakeCache.txt directory is different" | `build_whisper.sh` sam czyści |
| `.build` SwiftPM | „module cache path" | `rm -rf .build` |

Sama aplikacja jest odporna — `ModelLocator` liczy ścieżkę w czasie działania,
a pakiet `.app` ma własny rpath i biblioteki w `Contents/Frameworks`.


### Rozdzielenie kodu od danych działania

Katalog projektu przenoszony był trzy razy i **za każdym razem psuł zainstalowaną
aplikację** — bo trzymała w `Info.plist` ścieżkę do modeli i `.venv`.

Teraz wszystko, czego aplikacja potrzebuje w czasie działania, leży w
`~/Library/Application Support/MICFLOW/`:

| Co | Gdzie |
|---|---|
| Modele Whisper i VAD | `~/Library/Application Support/MICFLOW/models/` |
| Środowisko Pythona (MLX) | `~/Library/Application Support/MICFLOW/venv/` |
| `cleanup.py` | wewnątrz pakietu `.app` — zawsze zgodny z binarką |
| Model Bielik | cache Hugging Face (`~/.cache/huggingface`) |

W katalogu projektu zostaje sam kod. Sprawdzone: przy całkowicie usuniętym
katalogu projektu pełny pipeline nadal działa.

`.venv` jest **odtwarzany**, nie kopiowany — jego skrypty mają wpisane ścieżki
bezwzględne, więc przeniesienie by go zepsuło. Z tego samego powodu `setup.sh`
używa `python -m pip` zamiast `pip`.

### Przekazanie aplikacji na inny komputer

Skopiowanie samego pakietu `.app` **nie zadziała**:

- poza pakietem leży ~6,9 GB danych (modele Whispera, Bielik, środowisko Pythona)
- podpis jest ad-hoc, bez Team ID — Gatekeeper zablokuje plik przyniesiony z innego Maca
- `.venv` zawiera ścieżki z nazwą użytkownika i nie zadziała na innym koncie

Działa natomiast przekazanie **repozytorium** i uruchomienie `scripts/setup.sh`,
który pobiera zależności, buduje i instaluje. Wymagania: Mac z Apple Silicon
(MLX i Metal), Xcode Command Line Tools, `python3`, ~7 GB do pobrania.
Aplikacja zbudowana lokalnie nie podlega kwarantannie Gatekeepera.


## 8. Wskaźnik, panel i wpisywanie — stan po dopracowaniu

### Pastylka przy krawędzi

Wskaźnik wzorowany na Wispr Flow, z pomiarów zdjętych z nagrania ekranu:
30×72 px przy szerokości ekranu 1920, 6 px od krawędzi, wyśrodkowany pionowo,
12 poziomych pasków. Odwzorowany w granacie ikony (#304364) zamiast czerni.

Szerokość pasków napędza **RMS**, nie szczyt — szczyt skakał od stuknięcia
w klawiaturę. Mikrofon oddaje bufory ~11 razy na sekundę, a rysujemy 60, więc
między odczytami wygładzamy; bez tego ruch był skokowy.

Stan przetwarzania: kropki u góry, obracający się wskaźnik u dołu.

Rysowanie idzie w domyślnym układzie AppKit, nie w `isFlipped`. Dzięki temu
podgląd offscreen (`--test-indicator`) daje **ten sam** wynik co ekran —
przy `isFlipped` podgląd kłamał i przepuścił odwrócony gradient.

### Panel z tekstem

Pokazywany, gdy nie ma gdzie wpisać tekstu. Ten sam granat, przyciski
kopiowania i zamknięcia w prawym górnym rogu, samoczynne znikanie po 15 s.
W odróżnieniu od pastylki **przyjmuje kliknięcia**, ale nie przejmuje fokusu.

### Gdzie trafia tekst — dwie pułapki

**Electron nie udostępnia drzewa Accessibility**, dopóki program pomocniczy
wprost o to nie poprosi przez `AXManualAccessibility`. Bez tego pytanie
o element z fokusem nie zwracało niczego i MICFLOW pokazywał panel zamiast
wpisać tekst w Claude, Slacku czy VS Code.

Dlatego punktem wyjścia jest **aktywna aplikacja**, nie drzewo Accessibility:
jeśli cokolwiek jest na wierzchu, użytkownik tam pisze. Panel zostaje na dwa
przypadki — Finder na wierzchu (kliknięcie w pulpit) i fokus na przycisku,
gdzie wpisywanie byłoby groźne, bo spacja wciska przycisk.

Zapytania Accessibility mają limit **0,4 s**. Idą przez IPC do obcej aplikacji,
a wołamy je przy starcie nagrania — zawieszona aplikacja zjadłaby pierwsze słowa.

### Znaki nowej linii wysyłały wiadomość

`CGEvent` wpisuje znak nowej linii jako **Enter**, a w oknie czatu Enter wysyła
wiadomość. Podyktowany tekst z łamaniem linii szedł więc jako przedwcześnie
wysłana wypowiedź. `singleLine()` zwija wszystkie białe znaki do pojedynczych
spacji. Świadomie tracimy wielolinijkowość — mowa rzadko jej wymaga, a
przypadkowe wysłanie jest znacznie kosztowniejsze.

### Ikona paska menu

`scripts/make_menubar_icon.py` wycina mikrofon z `Resources/icon-source.png`.
Tło jest wyraźnie niebieskie (B ≫ R), a mikrofon czarny lub szary (R≈G≈B),
więc rozdziela je kryterium barwy, nie jasności. Krawędź zaokrąglonego kwadratu
odpada przez zawężenie obszaru i odsianie plam mniejszych niż 300 px.

Wynik jest obrazkiem szablonowym, więc macOS sam odwraca go w trybie ciemnym
i jasnym. Ikona **nie zmienia** koloru przy nagrywaniu — o stanie informuje
pastylka.

### Tryby podglądu

`--test-indicator`, `--test-panel` i `--test-focus` renderują interfejs do PNG
albo wypisują decyzję o miejscu wpisania, bez uruchamiania aplikacji
i bez mikrofonu. Wyłapały już odwrócony gradient i wskaźnik przetwarzania
po złej stronie pastylki.


### Rozpoznawanie gestu skrótu

Nie ma już przełącznika trybu w menu — monitor sam rozstrzyga, czy klawisz
został przytrzymany, czy kliknięty dwa razy.

Sedno trudności: **w chwili puszczenia klawisza nie wiadomo jeszcze**, czy było
to krótkie przytrzymanie, czy pierwsze z dwóch kliknięć. Dlatego nagrywanie
rusza natychmiast przy wciśnięciu — inaczej przytrzymanie gubiłoby pierwsze
słowa — a rozstrzygnięcie zapada przy puszczeniu:

| Gest | Rozpoznanie |
|---|---|
| Puszczenie po ≥ 0,35 s | przytrzymanie → koniec nagrania |
| Puszczenie < 0,35 s | czekamy 0,40 s na drugie kliknięcie |
| Drugie kliknięcie w oknie | tryb bez trzymania, nagrywa dalej |
| Drugie kliknięcie nie przyszło | krótki klik → koniec nagrania |
| Kliknięcie w trybie bez trzymania | koniec nagrania |

Stan resetuje się, gdy nagranie skończyło się poza skrótem (limit czasu,
przycisk w menu) — bez tego kolejne kliknięcie próbowałoby zatrzymać
nieistniejące nagranie.

Logika jest sprawdzana przez `--test-gestures` na prawdziwym `HotkeyMonitor`,
czterema scenariuszami. Przy tylu stanach sprawdzenie „na oko" byłoby
nieodpowiedzialne.
