#!/usr/bin/env python3
"""Naprawia nagłówek WAV, gdy nagrywanie zostało przerwane zabiciem procesu.

AVAudioFile wpisuje poprawne rozmiary chunków dopiero przy zamknięciu pliku.
Po SIGKILL zostają wartości z momentu utworzenia, przez co plik jest nie do
odczytania mimo że dane audio są w całości na dysku.

Użycie: python3 scripts/repair_wav.py plik.wav [...]
"""
import struct
import sys


def repair(path: str) -> bool:
    with open(path, "r+b") as f:
        data = f.read(4096)
        if data[:4] != b"RIFF" or data[8:12] != b"WAVE":
            print(f"{path}: to nie jest plik WAV")
            return False

        f.seek(0, 2)
        size = f.tell()

        # Przejdź po chunkach, żeby znaleźć 'data' — układ nie jest stały,
        # AVAudioFile wstawia wyrównujące chunki JUNK/FLLR.
        offset = 12
        while offset + 8 <= len(data):
            chunk_id = data[offset:offset + 4]
            chunk_size = struct.unpack("<I", data[offset + 4:offset + 8])[0]
            if chunk_id == b"data":
                data_offset = offset + 8
                actual = size - data_offset
                if chunk_size == actual:
                    print(f"{path}: nagłówek poprawny, pomijam")
                    return False

                f.seek(4)
                f.write(struct.pack("<I", size - 8))
                f.seek(offset + 4)
                f.write(struct.pack("<I", actual))

                seconds = actual / (16000 * 2)
                print(f"{path}: naprawiono {chunk_size} → {actual} B ({seconds:.1f} s)")
                return True
            offset += 8 + chunk_size + (chunk_size & 1)

        print(f"{path}: nie znaleziono chunku 'data'")
        return False


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)
    for arg in sys.argv[1:]:
        repair(arg)
