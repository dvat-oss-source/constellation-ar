#!/usr/bin/env python3
"""Writes Data/test/qa_eval.json, the grounded Q&A evaluation set: 30 questions over Ori, UMa, Cas, Sco and Ant.

Usage (from the repo root, after tools/build_passages.py):
    .venv/bin/python tools/make_qa_eval.py

For each constellation, 5 questions whose answers are in the passages (expected keywords + supporting passage ids,
each keyword checked against the supporting passages here) and 1 the sources do not cover (expected "not in sources",
each absent term checked against every passage of the constellation).
"""

import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_catalog as bc  # noqa: E402

OUTPUT = bc.DATA / "test" / "qa_eval.json"
NOT_IN_SOURCES = "not in sources"

ANSWERABLE = {
    "Ori": [
        ("Which star marks Orion's left shoulder?", ["Bellatrix"], ["Ori-wiki-7"]),
        ("What does the name Alnilam mean?", ["string of pearls"], ["Ori-wiki-8"]),
        ("Which meteor shower peaks around 20 October, and what is its parent body?", ["Orionid", "Halley"], ["Ori-wiki-17"]),
        ("Which star of Orion's Belt is the easternmost?", ["Alnitak"], ["Ori-wiki-9"]),
        ("How far away is the nebula M78 in Orion?", ["1600"], ["Ori-wiki-19"]),
    ],
    "UMa": [
        ("What is the Big Dipper called in the United Kingdom?", ["Plough"], ["UMa-wiki-3"]),
        ("What is the name of Mizar's optical companion?", ["Alcor"], ["UMa-wiki-5"]),
        ("Which two stars are known as the pointer stars?", ["Merak", "Dubhe"], ["UMa-wiki-6"]),
        ("What is the apparent magnitude of Dubhe?", ["1.79"], ["UMa-wiki-4"]),
        ("What did the Norse pagans call the Big Dipper?", ["Woden's wagon"], ["UMa-wiki-28"]),
    ],
    "Cas": [
        ("What does the name Caph mean?", ["hand"], ["Cas-wiki-11"]),
        ("What shape do the five brightest stars of Cassiopeia form?", ["W-shaped"], ["Cas-wiki-9"]),
        ("What does the name Ruchbah, for Delta Cassiopeiae, mean?", ["knee"], ["Cas-wiki-13"]),
        ("Who observed the supernova of 1572 in Cassiopeia?", ["Tycho Brahe"], ["Cas-wiki-21"]),
        ("What is the parent body of the December Phi Cassiopeiids meteor shower?", ["Biela"], ["Cas-wiki-24"]),
    ],
    "Sco": [
        ("What does the name Antares mean?", ["rival"], ["Sco-wiki-1"]),
        ("For how many days is the Sun inside the IAU boundaries of Scorpius?", ["six days"], ["Sco-wiki-13"]),
        ("Which star in Scorpius flared from magnitude 2.3 to 1.9 in July 2000?", ["Dschubba"], ["Sco-wiki-1", "Sco-wiki-2"]),
        ("What does the Babylonian name MUL.GIR.TAB mean?", ["burning sting"], ["Sco-wiki-10"]),
        ("What region of Brazil does Scorpius represent on the Brazilian flag?", ["Northeast"], ["Sco-wiki-12"]),
    ],
    "Ant": [
        ("Who established the constellation Antlia?", ["Lacaille"], ["Ant-wiki-0"]),
        ("What object does Antlia represent?", ["air pump"], ["Ant-wiki-0"]),
        ("What is the brightest star in Antlia?", ["Alpha Antliae"], ["Ant-wiki-1"]),
        ("Which galaxy is the brightest in Antlia, and at what magnitude?", ["NGC 2997", "10.6"], ["Ant-wiki-14"]),
        ("Where does Antlia rank by area among the 88 constellations?", ["62nd"], ["Ant-wiki-5"]),
    ],
}

UNANSWERABLE = {
    "Ori": ("How many exoplanets orbit Betelgeuse?", ["exoplanet", "planets orbit"]),
    "UMa": ("What is the radius of Alioth in solar radii?", ["solar radii", "solar radius"]),
    "Cas": ("What is the rotation period of Schedar?", ["rotation period", "rotational period"]),
    "Sco": ("What is the surface temperature of Antares in kelvin?", ["surface temperature", "kelvin"]),
    "Ant": ("What is the radius of Alpha Antliae in kilometres?", ["kilometre", "radius"]),
}


def build():
    passages = json.loads((bc.DATA / "passages.json").read_text(encoding="utf-8"))["passages"]
    by_id = {p["id"]: p for ps in passages.values() for p in ps}
    questions, problems = [], []
    for cid, items in ANSWERABLE.items():
        for n, (question, keywords, support) in enumerate(items, 1):
            missing = [i for i in support if i not in by_id]
            text = " ".join(by_id[i]["t"] for i in support if i in by_id).lower()
            problems += [f"{cid} Q{n}: unknown passage {i}" for i in missing]
            problems += [f"{cid} Q{n}: keyword {k!r} not in {support}" for k in keywords if k.lower() not in text]
            questions.append({"id": f"{cid}-{n}", "constellation": cid, "question": question, "answerable": True,
                              "keywords": keywords, "supportingPassages": support, "expected": None, "absentTerms": []})
        question, absent = UNANSWERABLE[cid]
        everything = " ".join(p["t"] for p in passages[cid]).lower()
        problems += [f"{cid} unanswerable: {t!r} occurs in the passages" for t in absent if t.lower() in everything]
        questions.append({"id": f"{cid}-6", "constellation": cid, "question": question, "answerable": False,
                          "keywords": [], "supportingPassages": [], "expected": NOT_IN_SOURCES, "absentTerms": absent})
    return questions, problems


def main():
    questions, problems = build()
    if problems:
        raise SystemExit("\n".join(problems))
    bc.write_json(OUTPUT, {
        "version": 1,
        "format": "questions[]: {id, constellation, question, answerable, keywords (answerable: case-insensitive, each occurs "
                  "in the supporting passages), supportingPassages (ids in passages.json), expected ('not in sources' when "
                  "not answerable), absentTerms (none occurs in any passage of the constellation)}.",
        "constellations": list(ANSWERABLE),
        "questions": questions,
    })
    print(f"wrote {OUTPUT.relative_to(bc.ROOT)}: {len(questions)} questions, "
          f"{sum(q['answerable'] for q in questions)} answerable")


if __name__ == "__main__":
    main()
