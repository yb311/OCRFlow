#!/usr/bin/env python3
"""Extract a PaddleOCR character dictionary from a model's inference.yml.

PaddleOCR ships each recogniser's charset inside inference.yml; OCRFlow reads a
plain one-character-per-line file. Parsed by hand rather than with PyYAML, which
is not part of the stock macOS Python.

Entries that YAML would otherwise read as numbers or punctuation are quoted in
the file, so the quoting has to be undone -- otherwise digits are decoded as
"'1'" instead of "1".

Usage: ppocr_dict.py < inference.yml > dict.txt
"""
import sys

SINGLE = "'"
DOUBLE = '"'


def unquote(token):
    if len(token) >= 2 and token[0] == token[-1] == SINGLE:
        return token[1:-1].replace(SINGLE * 2, SINGLE)
    if len(token) >= 2 and token[0] == token[-1] == DOUBLE:
        return token[1:-1].encode().decode("unicode_escape")
    return token


def main():
    characters = []
    inside = False
    for line in sys.stdin.read().split("\n"):
        if not inside:
            # The key is nested under PostProcess, so it carries indentation.
            inside = line.strip() == "character_dict:"
            continue
        stripped = line.lstrip()
        if stripped.startswith("- "):
            # Keep the entry exactly as written: a space is a valid character,
            # and so is the ideographic space that opens the PP-OCRv5 charset.
            characters.append(unquote(line[line.index("- ") + 2:]))
        elif stripped:
            break

    if not characters:
        sys.exit("could not read character_dict from inference.yml")
    sys.stdout.write("\n".join(characters) + "\n")


if __name__ == "__main__":
    main()
