# Licencje pobieranych składników

Licencja [MIT](LICENSE) obejmuje **wyłącznie kod tego projektu**.

Składniki pobierane przez `scripts/setup.sh` mają własne licencje — wszystkie
permisywne, dopuszczające użycie komercyjne i redystrybucję:

| Składnik | Licencja | Źródło |
|---|---|---|
| whisper.cpp i model Whisper | MIT | https://github.com/ggerganov/whisper.cpp |
| Silero VAD | MIT | https://github.com/snakers4/silero-vad |
| MLX | MIT | https://github.com/ml-explore/mlx |
| Bielik 11B v3.0 Instruct | Apache 2.0 | https://huggingface.co/speakleash |

Apache 2.0 wymaga zachowania informacji o autorstwie i udokumentowania zmian
wprowadzonych w modelu. Ten projekt modelu nie modyfikuje — pobiera go
i uruchamia bez zmian.

Stan sprawdzony w sierpniu 2026. Warunki modeli potrafią się różnić między
wersjami, więc przy poważniejszym zastosowaniu zweryfikuj je u źródła.
