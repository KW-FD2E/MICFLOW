#!/usr/bin/env python3
"""Czyszczenie surowej transkrypcji mowy lokalnym modelem Bielik przez MLX.

Tryby:
  --text "..."     jednorazowe czyszczenie podanego tekstu
  --serve          tryb serwera: czyta linie z stdin, pisze wynik na stdout
  --benchmark      przepuszcza wbudowane przykłady i mierzy czas

W trybie --serve model zostaje w pamięci, więc aplikacja Swift płaci za
załadowanie wag tylko raz, a nie przy każdym dyktowaniu.
"""
import argparse
import os
import json
import sys
import time

MODEL = os.environ.get("BIELIK_MODEL", "speakleash/Bielik-11B-v3.0-Instruct-MLX-4bit")

SYSTEM_PROMPT = """Czyścisz zapis mowy z dyktowania. Działasz MINIMALNIE.

WOLNO CI wyłącznie:
- usunąć wypełniacze: "yyy", "eee", "no", "wiesz", "znaczy", "jakby", "tego"
- usunąć powtórzenia i jąkanie ("że że" → "że")
- poprawić interpunkcję i wielkie litery
- poprawić ewidentne błędy gramatyczne (zła końcówka, zły przypadek)

ZABRONIONE:
- zmienianie słów na synonimy ("ciekawy" MUSI zostać "ciekawy", nie "interesujący")
- zmienianie rejestru na bardziej oficjalny
- dopisywanie czegokolwiek, czego nie ma w oryginale
- skracanie, streszczanie, przestawianie zdań
- odpowiadanie na pytania z tekstu — masz go tylko poprawić

Zasada: jeśli słowo nie jest wypełniaczem ani błędem, MUSI zostać dokładnie takie samo.

Odpowiadasz WYŁĄCZNIE poprawionym tekstem. Żadnych uwag, wyjaśnień, komentarzy
w nawiasach ani oceny tekstu. Jeśli nie ma czego poprawiać, przepisz tekst bez zmian."""

# Kilka przykładów działa tu lepiej niż same instrukcje — pokazują skalę
# ingerencji, której oczekujemy, a nie tylko ją opisują.
FEW_SHOT = [
    (
        "yyy no bo ja myślę że to jest dosyć spoko rozwiązanie znaczy wiesz no",
        "Bo ja myślę, że to jest dosyć spoko rozwiązanie.",
    ),
    (
        "trzeba by eee zrobić to do piątku bo bo inaczej nie zdążymy",
        "Trzeba by zrobić to do piątku, bo inaczej nie zdążymy.",
    ),
    # Ten przykład pilnuje najczęstszego błędu: modele lubią zamieniać
    # polecenia na uprzejme formy urzędowe i gubić drobne słowa.
    (
        "zadzwoń proszę do ani i powiedz jej yyy że no że materiały wyślemy jutro "
        "i niech da znać czy to jej pasuje",
        "Zadzwoń proszę do Ani i powiedz jej, że materiały wyślemy jutro "
        "i niech da znać, czy to jej pasuje.",
    ),
]

SAMPLES = [
    "Halo, halo. Jeszcze raz. Co ta aplikacja miała mi zrobić? I co powinienem "
    "otrzymać w tym drugim zapytaniu? Dostałem odpowiedź, że OK, wykryto sygnał. "
    "I później co powinienem się zwrócić? I potwierdzić, czy działa? Halo, halo, halo.",

    "yyy no więc chciałem powiedzieć że eee ten projekt no jest w sumie dosyć "
    "ciekawy znaczy wiesz no bo można go zrobić lokalnie i yyy nie trzeba płacić "
    "za żadne API no i to jest chyba najważniejsze",

    "napisz proszę do marka że spotkanie przekładamy na czwartek na czternastą "
    "bo w środę mam yyy no kolizję z innym terminem i eee niech potwierdzi czy mu pasuje",
]


def strip_commentary(text: str) -> str:
    """Usuwa meta-komentarze, które model potrafi dokleić mimo zakazu w prompcie.

    Mniejszy Bielik lubi kończyć wypowiedź linijką w stylu
    '(Uwaga: "Halo" jest standardowym pozdrowieniem...)'. Taki tekst trafiłby
    prosto do pola tekstowego użytkownika, więc odcinamy go tutaj, a nie
    liczymy wyłącznie na posłuszeństwo modelu.
    """
    lines = [line for line in text.split("\n")]

    while len(lines) > 1:
        last = lines[-1].strip()
        if not last:
            lines.pop()
            continue
        # Samodzielna linia w nawiasach to komentarz, nie dyktowana treść.
        if last.startswith("(") and last.endswith(")"):
            lines.pop()
            continue
        break

    return "\n".join(lines).strip()


def static_messages() -> list:
    """Część promptu identyczna przy każdym wywołaniu — nadaje się do zbuforowania."""
    messages = [{"role": "system", "content": SYSTEM_PROMPT}]
    for example_in, example_out in FEW_SHOT:
        messages.append({"role": "user", "content": example_in})
        messages.append({"role": "assistant", "content": example_out})
    return messages


def build_prompt(tokenizer, raw: str):
    messages = static_messages() + [{"role": "user", "content": raw}]
    return tokenizer.apply_chat_template(messages, add_generation_prompt=True)


def make_generator():
    import copy

    import mlx.core as mx
    from mlx_lm import load, generate
    from mlx_lm.models.cache import make_prompt_cache
    from mlx_lm.sample_utils import make_sampler

    model, tokenizer = load(MODEL)
    sampler = make_sampler(temp=0.0)   # cleanup ma być deterministyczny

    # Prompt systemowy z przykładami to ~500 tokenów, które model przy każdym
    # dyktowaniu przeliczałby od nowa (~5 s). Przetwarzamy je raz i trzymamy
    # gotowy stan KV, kopiując go pod każde kolejne zapytanie.
    prefix_ids = tokenizer.apply_chat_template(
        static_messages(), add_generation_prompt=False, tokenize=True
    )

    base_cache = make_prompt_cache(model)
    model(mx.array(prefix_ids)[None], cache=base_cache)
    mx.eval([layer.state for layer in base_cache])

    def run(raw: str, max_tokens: int = 512) -> str:
        full_ids = tokenizer.apply_chat_template(
            static_messages() + [{"role": "user", "content": raw}],
            add_generation_prompt=True,
            tokenize=True,
        )

        # Gdyby szablon czatu nie zaczynał się tym samym prefiksem, liczymy
        # wszystko od zera — lepiej wolniej niż z niespójnym stanem.
        if list(full_ids[:len(prefix_ids)]) == list(prefix_ids):
            prompt_ids = list(full_ids[len(prefix_ids):])
            cache = copy.deepcopy(base_cache)
        else:
            prompt_ids = list(full_ids)
            cache = make_prompt_cache(model)

        result = generate(
            model, tokenizer,
            prompt=prompt_ids,
            max_tokens=max_tokens,
            sampler=sampler,
            prompt_cache=cache,
            verbose=False,
        )
        return strip_commentary(result)

    return run


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--text")
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--benchmark", action="store_true")
    args = parser.parse_args()

    started = time.time()
    run = make_generator()
    load_seconds = time.time() - started

    if args.benchmark:
        print(f"Model wczytany w {load_seconds:.1f}s\n", file=sys.stderr)
        for index, sample in enumerate(SAMPLES, 1):
            started = time.time()
            result = run(sample)
            elapsed = time.time() - started
            # Przybliżenie tokenów przez słowa wystarczy, żeby zobaczyć rząd wielkości.
            tokens = len(result.split()) * 1.6
            print(f"--- PRZYKŁAD {index} ({elapsed:.1f}s, ~{tokens / elapsed:.1f} tok/s) ---")
            print(f"PRZED: {sample}")
            print(f"PO:    {result}\n")
        return 0

    if args.serve:
        # Protokół: jedna linia JSON na wejściu, jedna linia JSON na wyjściu.
        print(json.dumps({"ready": True, "load_seconds": round(load_seconds, 2)}), flush=True)
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                raw = json.loads(line).get("text", "")
                print(json.dumps({"text": run(raw)}), flush=True)
            except Exception as error:
                print(json.dumps({"error": str(error)}), flush=True)
        return 0

    if args.text:
        print(run(args.text))
        return 0

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
