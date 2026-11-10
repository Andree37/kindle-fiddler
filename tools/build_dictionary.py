#!/usr/bin/env python3
"""Builds a noface dictionary file from a Wiktionary extract.

Usage: build_dictionary.py <kaikki.org-dictionary-LANG.jsonl.gz> <out file>

The extract comes from https://kaikki.org (Wiktionary, CC BY-SA 4.0 and GFDL).
Definitions are in English, so the Portuguese extract gives Portuguese words with
English meanings. The output format is described in src/model/dictionary.zig.

Each word keeps at most 3 parts of speech with 3 senses each, every sense cut to
about 200 characters. Obsolete, archaic and rare senses come after the rest.
Inflected forms keep their own short gloss ("simple past of run") and a "=run" line,
so noface shows the base word's meaning too. Forms Wiktionary only lists inside the
base word's entry (most Portuguese plurals and verb forms) are added the same way,
when they have no entry of their own.
"""
import gzip
import json
import struct
import sys

MAGIC = b"NFDICT1\n"
MAX_POS = 3
MAX_SENSES = 3
MAX_GLOSS = 200
MAX_WORD = 40

# Must match search.fold in src/model/search.zig: Latin-1 and Latin Extended-A
# letters to their plain letter, '*' where there isn't one.
PLAIN = ("aaaaaa*ceeeeiiii*nooooo**uuuuy**aaaaaa*ceeeeiiii*nooooo**uuuuy*yaaaaaaccccccccdd**"
         "eeeeeeeeeegggggggghh**iiiiiiiii***jjkk*llllll****nnnnnn***oooooo**rrrrrrsssssssstttt**"
         "uuuuuuuuuuuuwwyyyzzzzzz*")

POS_NAMES = {
    "noun": "noun", "verb": "verb", "adj": "adjective", "adv": "adverb",
    "name": "proper noun", "pron": "pronoun", "prep": "preposition",
    "conj": "conjunction", "intj": "interjection", "num": "numeral",
    "det": "determiner", "article": "article", "particle": "particle",
    "phrase": "phrase", "prep_phrase": "phrase", "contraction": "contraction",
    "abbrev": "abbreviation", "prefix": "prefix", "suffix": "suffix",
}

LATE_TAGS = {"obsolete", "archaic", "rare", "dated"}


def fold(word):
    out = []
    for ch in word:
        cp = ord(ch)
        if cp == 0x2019:
            cp = ord("'")
        if ord("A") <= cp <= ord("Z"):
            cp += 32
        elif 0xC0 <= cp <= 0x17F and PLAIN[cp - 0xC0] != "*":
            cp = ord(PLAIN[cp - 0xC0])
        out.append(chr(cp))
    return "".join(out)


def clip(text):
    text = " ".join(text.split())
    if len(text) <= MAX_GLOSS:
        return text
    cut = text.rfind(" ", 0, MAX_GLOSS)
    return text[: cut if cut > 0 else MAX_GLOSS] + "…"


def senses_of(entry):
    """(gloss, base word or None) for each usable sense, the late ones last."""
    good, late = [], []
    for s in entry.get("senses", []):
        glosses = s.get("glosses")
        if not glosses:
            continue
        base = None
        if s.get("form_of"):
            base = s["form_of"][0].get("word")
        item = (clip(glosses[-1]), base)
        (late if LATE_TAGS & set(s.get("tags", [])) else good).append(item)
    return good + late


SKIP_FORM_TAGS = {"table-tags", "inflection-template", "class", "romanization"}


def listed_forms(entry):
    """(form, description) for each inflected form listed inside an entry."""
    word = entry.get("word", "")
    for f in entry.get("forms", []):
        form = f.get("form", "")
        tags = [t for t in f.get("tags", []) if t not in SKIP_FORM_TAGS]
        if not form or form == word or " " in form or not tags or SKIP_FORM_TAGS & set(f.get("tags", [])):
            continue
        yield form, " ".join(tags).replace("-", " ") + " of " + word


def main(src, dst):
    words = {}  # key -> {"word": str, "pos": {name: [glosses]}, "base": str or None}
    forms = {}  # key -> (form, gloss, base), for forms without an entry of their own
    with gzip.open(src, "rt", encoding="utf-8") as f:
        for line in f:
            e = json.loads(line)
            word = e.get("word", "")
            if not word or " " in word or len(word) > MAX_WORD or not any(c.isalpha() for c in word):
                continue
            senses = senses_of(e)
            if not senses:
                continue
            for form, gloss in listed_forms(e):
                fk = fold(form)
                if len(fk.encode()) <= 64 and fk not in forms:
                    forms[fk] = (form, clip(gloss), word)
            key = fold(word)
            if len(key.encode()) > 64:
                continue
            w = words.setdefault(key, {"word": word, "pos": {}, "base": None})
            # Prefer the lowercase spelling as the headword: "polish" over "Polish"
            if word == key and w["word"] != key:
                w["word"] = word
            pos = POS_NAMES.get(e.get("pos", ""), e.get("pos", ""))
            if pos not in w["pos"] and len(w["pos"]) >= MAX_POS:
                continue
            glosses = w["pos"].setdefault(pos, [])
            for gloss, base in senses:
                if len(glosses) >= MAX_SENSES:
                    break
                if gloss not in glosses:
                    glosses.append(gloss)
                if base and not w["base"] and fold(base) != key:
                    w["base"] = base

    added = 0
    for fk, (form, gloss, base) in forms.items():
        if fk in words:
            continue
        words[fk] = {"word": form, "pos": {"form": [gloss]}, "base": base}
        added += 1
    print(f"{added} forms added from inside other entries")

    keys = sorted(words, key=lambda k: k.encode())
    body = bytearray()
    offsets = []
    for key in keys:
        w = words[key]
        lines = []
        for pos, glosses in w["pos"].items():
            lines.append(pos)
            lines.extend(f"{i} {g}" for i, g in enumerate(glosses, 1))
        if w["base"]:
            lines.append("=" + w["base"])
        offsets.append(len(body))
        body += key.encode() + b"\0" + w["word"].encode() + b"\0" + "\n".join(lines).encode()
    offsets.append(len(body))
    with open(dst, "wb") as out:
        out.write(MAGIC)
        out.write(struct.pack("<I", len(keys)))
        out.write(struct.pack(f"<{len(offsets)}I", *offsets))
        out.write(body)
    print(f"{dst}: {len(keys)} words, {len(body) // (1 << 20)} MB of definitions")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
