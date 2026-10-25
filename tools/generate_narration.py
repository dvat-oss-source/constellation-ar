#!/usr/bin/env python3
"""Generates Data/narration.json: one card per constellation, prose by Gemini (Vertex AI express mode),
facts (brightest stars, magnitudes, distances) inserted from the catalogue by code.

Usage (from the repo root, after tools/build_catalog.py):
    .venv/bin/python tools/generate_narration.py --fetch              # download + pin source texts only
    .venv/bin/python tools/generate_narration.py --dry-run --ids Ori  # build prompts, no API call
    .venv/bin/python tools/generate_narration.py --ids Ori,Ant        # generate a subset, merged into narration.json
    .venv/bin/python tools/generate_narration.py                      # all 88

Reads VERTEX_API_KEY from Config/Secrets.xcconfig and NARRATION_MODEL_ID from Config/Config.xcconfig.
Source texts are cached in tools/.cache/narration_sources/ and pinned in tools/narration_sources.json;
raw model responses are cached in tools/.cache/narration_raw/ keyed by request hash, so reruns don't re-bill.
"""

import argparse
import datetime
import hashlib
import html
import json
import math
import re
import sys
import time
import unicodedata
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import quote

import numpy as np
import requests

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_catalog as bc  # noqa: E402

ROOT = bc.ROOT
CONFIG_DIR = ROOT / "Config"
NARRATION_MANIFEST = bc.TOOLS / "narration_sources.json"
SRC_DIR = "narration_sources"
RAW_DIR = bc.CACHE / "narration_raw"
PROMPT_DIR = bc.CACHE / "narration_prompts"
OUTPUT = bc.DATA / "narration.json"
ENDPOINT = "https://aiplatform.googleapis.com/v1/publishers/google/models/{model}:generateContent"

MAX_RETRIES = 3
BRIGHTEST_COUNT = 5
MAX_PARALLAX_REL_ERROR = 1 / 3
ALLEN_MAX_CHARS = 60000
ARATUS_MAX_CHARS = 9000
LY_PER_PC = 3.26156

WIKIPEDIA_LICENCE = "CC BY-SA 4.0"
ALLEN_URL = "https://penelope.uchicago.edu/Thayer/E/Gazetteer/Topics/astronomy/_Texts/secondary/ALLSTA/{page}*.html"
ALLEN_TITLE = "Richard Hinckley Allen, Star-Names and Their Meanings (1899)"
ALLEN_LICENCE = "Public domain (1899 text; LacusCurtius transcription by Bill Thayer of the 1963 Dover reprint)"
ARATUS_URL = "https://www.theoi.com/Text/AratusPhaenomena.html"
ARATUS_TITLE = "Aratus, Phaenomena, translated by G. R. Mair (Loeb Classical Library, 1921)"
ARATUS_LICENCE = "Public domain (1921 translation; transcription via Theoi Classical Texts Library)"

ALLEN_PAGES = {
    "And": "Andromeda", "Ant": "Antlia_Pneumatica", "Aps": "Apus", "Aqr": "Aquarius", "Aql": "Aquila",
    "Ara": "Ara", "Ari": "Aries", "Aur": "Auriga", "Boo": "Bootes", "Cae": "Caelum", "Cam": "Camelopardalis",
    "Cnc": "Cancer", "CVn": "Canes_Venatici", "CMa": "Canis_Major", "CMi": "Canis_Minor", "Cap": "Capricornus",
    "Car": "Argo_Navis", "Cas": "Cassiopeia", "Cen": "Centaurus", "Cep": "Cepheus", "Cet": "Cetus",
    "Cha": "Chamaeleon", "Cir": "Circinus", "Col": "Columba_Noae", "Com": "Coma_Berenices",
    "CrA": "Corona_Australis", "CrB": "Corona_Borealis", "Crv": "Corvus", "Crt": "Crater", "Cru": "Crux",
    "Cyg": "Cygnus", "Del": "Delphinus", "Dor": "Dorado", "Dra": "Draco", "Equ": "Equuleus", "Eri": "Eridanus",
    "For": "Fornax", "Gem": "Gemini", "Gru": "Grus", "Her": "Hercules", "Hor": "Horologium", "Hya": "Hydra",
    "Hyi": "Hydrus", "Ind": "Indus", "Lac": "Lacerta", "Leo": "Leo", "LMi": "Leo_Minor", "Lep": "Lepus",
    "Lib": "Libra", "Lup": "Lupus", "Lyn": "Lynx", "Lyr": "Lyra", "Men": "Mons_Mensae", "Mic": "Microscopium",
    "Mon": "Monoceros", "Mus": "Musca_Australis", "Nor": "Norma_et_Regula", "Oct": "Octans", "Oph": "Ophiuchus",
    "Ori": "Orion", "Pav": "Pavo", "Peg": "Pegasus", "Per": "Perseus", "Phe": "Phoenix", "Pic": "Equuleus_Pictoris",
    "Psc": "Pisces", "PsA": "Piscis_Australis", "Pup": "Argo_Navis", "Pyx": "Pyxis", "Ret": "Reticulum",
    "Sge": "Sagitta", "Sgr": "Sagittarius", "Sco": "Scorpio", "Scl": "Sculptor", "Sct": "Scutum_Sobiescianum",
    "Ser": "Serpens", "Sex": "Sextans", "Tau": "Taurus", "Tel": "Telescopium", "Tri": "Triangulum",
    "TrA": "Triangulum_Australe", "Tuc": "Tucana", "UMa": "Ursa_Major", "UMi": "Ursa_Minor", "Vel": "Argo_Navis",
    "Vir": "Virgo", "Vol": "Piscis_Volans", "Vul": "Vulpecula",
}

# Mair's names (and Theoi's bracketed glosses) for the figures Aratus names; the others are post-classical or unnamed in Aratus.
ARATUS_TERMS = {
    "And": ["Andromeda"], "Aqr": ["Water-pourer", "Hydrochoüs", "Aquarius"], "Aql": ["Eagle", "Aquila"], "Ara": ["Altar", "Ara"],
    "Ari": ["Ram", "Aries"], "Aur": ["Charioteer", "Auriga", "Capella", "Kids"], "Boo": ["Bootes", "Arctophylax", "Arcturus"],
    "Cnc": ["Crab", "Cancer", "Manger", "Asses"], "CMa": ["Dog", "Sirius", "Canis Major"], "CMi": ["Procyon"],
    "Cap": ["Goat-horned", "Aegoceros", "Capricorn"], "Car": ["Argo"], "Cas": ["Cassiepeia", "Cassiopeia"], "Cen": ["Centaur", "Centaurus"],
    "Cep": ["Cepheus"], "Cet": ["Monster", "Cetus"], "CrB": ["Crown", "Corona"],
    "Crv": ["Raven", "Corvus"], "Crt": ["Crater"], "Cyg": ["Bird", "Cygnus"], "Del": ["Dolphin", "Delphinus"],
    "Dra": ["Dragon", "Draco"], "Eri": ["River", "Eridanus"], "Gem": ["Twins", "Gemini"],
    "Her": ["Engonasin", "Kneeler", "On his Knees", "Phantom"], "Hya": ["Hydra"], "Leo": ["Lion", "Leo"],
    "Lep": ["Hare", "Lepus"], "Lib": ["Claws", "Libra"], "Lup": ["Beast", "Fera"], "Lyr": ["Lyre", "Lyra"],
    "Oph": ["Serpent-holder", "Ophiuchus"], "Ori": ["Orion"], "Peg": ["Horse", "Pegasus"], "Per": ["Perseus"],
    "Psc": ["Fishes", "Pisces"], "PsA": ["Southern Fish", "Piscis Australis"], "Pup": ["Argo"], "Sge": ["Arrow", "Sagitta"],
    "Sgr": ["Archer", "Bowman", "Bow", "Saggitarius"], "Sco": ["Scorpion", "Scorpio"], "Ser": ["Serpent"],
    "Tau": ["Bull", "Taurus", "Pleiades", "Hyades"], "Tri": ["Deltoton", "Triangulum"],
    "UMa": ["Bears", "Helice", "Ursa Major and Minor"], "UMi": ["Cynosura", "Bears", "Ursa Major and Minor"],
    "Vel": ["Argo"], "Vir": ["Maiden", "Virgo", "Spica", "Vindemiator"],
}

SOURCE_KEYS = ("wikipedia", "allen", "aratus")


# ---------------------------------------------------------------------------
# Config / secrets


def read_xcconfig(path):
    values = {}
    if not path.exists():
        return values
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$", line)
        if m and not line.lstrip().startswith("//"):
            values[m.group(1)] = m.group(2)
    return values


def load_settings():
    cfg = read_xcconfig(CONFIG_DIR / "Config.xcconfig")
    secrets = read_xcconfig(CONFIG_DIR / "Secrets.xcconfig")
    model = secrets.get("NARRATION_MODEL_ID") or cfg.get("NARRATION_MODEL_ID") or ""
    return model.strip(), secrets.get("VERTEX_API_KEY", "").strip()


def redact(text, key):
    if key:
        text = text.replace(key, "<redacted>")
    return re.sub(r"(?i)(key=)[^&\s\"']+", r"\1<redacted>", text)


# ---------------------------------------------------------------------------
# Source text extraction


class _AllenParser(HTMLParser):
    """Keeps Allen's body text; drops Thayer's links/notes, page numbers and everything after the endnotes rule."""

    SKIP_CLASSES = {"pagenum", "added_link", "ref"}
    BLOCKS = {"p", "br", "tr", "div", "table", "h1", "h2", "h3", "h4"}

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.out = []
        self.started = False
        self.done = False
        self.skip_stack = []
        self.stack = []

    def handle_starttag(self, tag, attrs):
        if self.done:
            return
        a = dict(attrs)
        classes = set((a.get("class") or "").split())
        if tag == "hr" and "endnotes" in classes:
            self.done = True
            return
        if not self.started and "pagenum" in classes:
            self.started = True
        if tag in ("br", "hr", "img", "meta", "link", "input"):
            if tag == "br":
                self.out.append("\n")
            return
        skip = bool(classes & self.SKIP_CLASSES) or tag in ("script", "style")
        self.stack.append(tag)
        self.skip_stack.append(skip)
        if tag in self.BLOCKS:
            self.out.append("\n")

    def handle_endtag(self, tag):
        if self.done or tag not in self.stack:
            return
        while self.stack:
            t = self.stack.pop()
            self.skip_stack.pop()
            if t == tag:
                break
        if tag in self.BLOCKS:
            self.out.append("\n")

    def handle_data(self, data):
        if self.done or not self.started or any(self.skip_stack):
            return
        self.out.append(re.sub(r"\s+", " ", data))


def clean_text(text):
    text = text.replace("\u00ad", "").replace("\u2060", "").replace("\u200b", "").replace("\u00a0", " ")
    text = unicodedata.normalize("NFC", text)
    lines = [re.sub(r"[ \t]+", " ", ln).strip() for ln in text.splitlines()]
    text = "\n".join(lines)
    return re.sub(r"\n{3,}", "\n\n", text).strip()


def allen_text(raw_html):
    p = _AllenParser()
    p.feed(raw_html)
    return clean_text("".join(p.out))


def aratus_blocks(raw_html):
    """-> [(firstLine, textWithTheoiGlosses)] for the translation paragraphs."""
    start = raw_html.find("PHAENOMENA, TRANSLATED BY G. R. MAIR")
    end = raw_html.find("<footer", start)
    body = raw_html[start:end]
    blocks = []
    for para in re.findall(r"<p[^>]*>(.*?)</p>", body, flags=re.S | re.I):
        text = clean_text(re.sub(r"\s+", " ", html.unescape(re.sub(r"<[^>]+>", "", para))))
        m = re.match(r"\[(\d+)\]\s*", text)
        if m:
            blocks.append([int(m.group(1)), text[m.end():]])
        elif blocks and text:
            blocks[-1][1] += "\n\n" + text
    return [(n, t) for n, t in blocks]


def strip_glosses(text):
    return re.sub(r"\s*\[[^\]\d][^\]]*\]", "", text)


def aratus_text_for(cid, blocks):
    terms = ARATUS_TERMS.get(cid)
    if not terms:
        return ""
    pattern = re.compile(r"(?<![A-Za-z])(" + "|".join(re.escape(t) for t in terms) + r")(?![a-z])")
    chosen, total = [], 0
    for _, text in blocks:
        if pattern.search(text):
            clean = strip_glosses(text)
            if total + len(clean) > ARATUS_MAX_CHARS:
                break
            chosen.append(clean)
            total += len(clean)
    return "\n\n".join(chosen)


# ---------------------------------------------------------------------------
# Catalogue facts


class Catalogue:
    def __init__(self):
        self.cons = json.loads((bc.DATA / "constellations.json").read_text(encoding="utf-8"))
        self.ids = [c["id"] for c in self.cons]
        self.by_id = {c["id"]: c for c in self.cons}
        lines = json.loads((bc.DATA / "lines.json").read_text(encoding="utf-8"))
        self.figure = {c["id"]: {h for s in c["segments"] for h in s} for c in lines["constellations"]}
        self.names = {n["hip"]: n["name"] for n in json.loads((bc.DATA / "names.json").read_text(encoding="utf-8"))["stars"]}
        self.roman = json.loads((bc.DATA / "roman1875.json").read_text(encoding="utf-8"))["rows"]
        self.bounds = json.loads((bc.DATA / "test" / "vi49_bounds.json").read_text(encoding="utf-8"))
        stars = bc.read_stars_bin(bc.DATA / "stars.bin")["records"]
        self.stars = {r[0]: r for r in stars}
        xyz = np.array([r[1:4] for r in stars], dtype=float)
        ra = np.degrees(np.arctan2(xyz[:, 1], xyz[:, 0])) % 360
        dec = np.degrees(np.arcsin(np.clip(xyz[:, 2], -1, 1)))
        self.radec = {r[0]: (a, d) for r, a, d in zip(stars, ra, dec)}
        ra75, dec75 = bc.to_b1875(ra, dec)
        self.region = {}
        for r, a, d in zip(stars, ra75, dec75):
            self.region.setdefault(bc.roman_lookup(self.roman, a, d), set()).add(r[0])
        self.e_plx = {}
        hip_path = bc.CACHE / "hip_main.dat"
        if hip_path.exists():
            hip = bc.parse_hipparcos(hip_path)
            self.e_plx = dict(zip(hip["hip"].tolist(), hip["e_plx"].tolist()))
        self.neighbours = self._neighbours()

    def _neighbours(self):
        adj = {i: set() for i in self.ids}
        for c in self.bounds["constellations"]:
            for poly in c["polygons"]:
                v = poly["vertices"]
                for (r1, d1), (r2, d2) in zip(v, v[1:]):
                    if d1 == d2:
                        w = (r2 - r1 + 12.0) % 24.0 - 12.0
                        mid = ((r1 + w / 2) % 24.0, d1)
                        probes = [(mid[0], d1 + 0.01), (mid[0], d1 - 0.01)]
                    else:
                        mid = (r1, (d1 + d2) / 2)
                        probes = [((r1 + 0.001) % 24.0, mid[1]), ((r1 - 0.001) % 24.0, mid[1])]
                    for a, d in probes:
                        if -90 < d < 90:
                            other = bc.roman_lookup(self.roman, a, d)
                            if other and other != c["id"]:
                                adj[c["id"]].add(other)
        return {k: sorted(v) for k, v in adj.items()}

    def distance_ly(self, hip):
        plx = self.stars[hip][6]
        if not plx > 0:
            return None
        err = self.e_plx.get(hip)
        if err is not None and not math.isnan(err) and err / plx > MAX_PARALLAX_REL_ERROR:
            return None
        ly = 1000.0 / plx * LY_PER_PC
        return round(ly, 1) if ly < 100 else int(round(ly))

    def brightest(self, cid):
        members = self.figure[cid] | self.region.get(cid, set())
        ranked = sorted(members, key=lambda h: (self.stars[h][4], h))[:BRIGHTEST_COUNT]
        return [{"hip": h, "name": self.names.get(h), "vmag": round(self.stars[h][4], 2), "distanceLy": self.distance_ly(h)}
                for h in ranked]

    def hints(self, cid):
        verts = [v for p in next(c for c in self.bounds["constellations"] if c["id"] == cid)["polygons"] for v in p["vertices"]]
        decs = [d for _, d in verts]
        pole = any(p["enclosesPole"] for c in self.bounds["constellations"] if c["id"] == cid for p in c["polygons"])
        dmin, dmax = min(decs), max(decs)
        if pole and dmax > 0:
            dmax = 90.0
        if pole and dmin < 0:
            dmin = -90.0
        north_limit = 90 + dmin
        south_limit = dmax - 90
        region = [self.radec[h] for h in self.region.get(cid, ())] or [self.radec[h] for h in self.figure[cid]]
        vec = np.sum([[math.cos(math.radians(d)) * math.cos(math.radians(a)), math.cos(math.radians(d)) * math.sin(math.radians(a)),
                       math.sin(math.radians(d))] for a, d in region], axis=0)
        ra_c = math.degrees(math.atan2(vec[1], vec[0])) % 360
        dec_c = math.degrees(math.atan2(vec[2], math.hypot(vec[0], vec[1])))
        # Highest at about 9 pm local time when the Sun's RA is 9h less than the constellation's.
        sun_ra_h = (ra_c / 15.0 - 9.0) % 24.0
        day = datetime.date(2026, 3, 20) + datetime.timedelta(days=sun_ra_h / 24.0 * 365.25)
        return {
            "centreRaHours": round(ra_c / 15.0, 1), "centreDecDeg": round(dec_c, 0),
            "fullyVisibleBetweenLatitudes": [round(max(-90.0, south_limit)), round(min(90.0, north_limit))],
            "highestAt9pmAround": day.strftime("%B"),
            "neighbours": [self.by_id[n]["name"] for n in self.neighbours[cid]],
            "figureStars": sorted({self.names[h] for h in self.figure[cid] if h in self.names}),
        }


# ---------------------------------------------------------------------------
# Source bundle


def fetch_sources(cat, ids, offline=False):
    src = bc.Sources(offline=offline, manifest=NARRATION_MANIFEST)
    table = {t[0]: t for t in bc.parse_constellation_table(bc.Sources(offline=True).get("iau_constellations_wiki"))}
    try:
        aratus_path = src.get("aratus", url=ARATUS_URL, version="Theoi Classical Texts Library page (Mair 1921 translation)",
                              path=f"{SRC_DIR}/aratus/theoi_AratusPhaenomena.html")
        blocks = aratus_blocks(aratus_path.read_text(encoding="utf-8"))
        bundles = {}
        for cid in ids:
            title = table[cid][3]
            wkey = title.replace(" ", "_")
            wpath = src.get(f"wikipedia:{wkey}", url="https://en.wikipedia.org/api/rest_v1/page/summary/" + quote(wkey, safe="()_,"),
                            version="Wikipedia REST page summary (revision recorded in the cached JSON)",
                            path=f"{SRC_DIR}/wikipedia/{wkey}.json")
            wiki = json.loads(wpath.read_text(encoding="utf-8"))
            page = ALLEN_PAGES[cid]
            apath = src.get(f"allen:{page}", url=ALLEN_URL.format(page=page), version="LacusCurtius ALLSTA transcription",
                            path=f"{SRC_DIR}/allen/{page}.html")
            allen = allen_text(apath.read_text(encoding="utf-8", errors="replace"))[:ALLEN_MAX_CHARS]
            aratus = aratus_text_for(cid, blocks)
            sources = [{
                "key": "wikipedia", "title": f"Wikipedia: {wiki['title']}",
                "url": f"https://en.wikipedia.org/w/index.php?title={quote(wkey, safe='()_,')}&oldid={wiki['revision']}",
                "licence": WIKIPEDIA_LICENCE, "text": clean_text(wiki["extract"]),
            }, {
                "key": "allen", "title": f"{ALLEN_TITLE}: {page.replace('_', ' ')}", "url": ALLEN_URL.format(page=page),
                "licence": ALLEN_LICENCE, "text": allen,
            }]
            if aratus:
                sources.append({"key": "aratus", "title": ARATUS_TITLE, "url": ARATUS_URL, "licence": ARATUS_LICENCE, "text": aratus})
            bundles[cid] = sources
            out = bc.CACHE / SRC_DIR / "bundles" / f"{cid}.json"
            out.parent.mkdir(parents=True, exist_ok=True)
            out.write_text(json.dumps({"id": cid, "sources": sources}, ensure_ascii=False, indent=1), encoding="utf-8")
    finally:
        src.save()
    return bundles


# ---------------------------------------------------------------------------
# Prompt and model call


SYSTEM_PROMPT = """You write short constellation cards for a personal stargazing app.

Rules:
- Use only information found in the SOURCES and FACTS below. Never invent names, myths, dates or history.
- Write plain prose (no markdown, no lists). Fields:
  summary: 2-3 sentences on what the constellation is and represents, and its origin.
  howToFind: 2-4 sentences for a naked-eye observer, using the FACTS (neighbouring constellations, named stars in the figure, season, latitudes) and any pattern descriptions in the sources.
  mythology: 2-5 sentences retelling the lore found in the sources. If the sources contain no myth for this figure (for example a constellation invented in the 17th-18th century), say so plainly and say who introduced it if the sources state it. Do not borrow myths from other constellations.
- Never write star magnitudes, brightness numbers, or distances; the app inserts those from its catalogue.
- Text inside double quotation marks in summary, howToFind or mythology must be copied exactly, word for word, from one source. Do not use quotation marks (single or double) for anything else: no scare quotes, no quoted nicknames.
- quotes: 0 to 3 short excerpts (at most 40 words each) copied character for character from ONE source each, as contiguous text, giving that source's key. Prefer Allen or Aratus passages about the figure's lore. Do not join separate passages, do not add or drop words, do not modernise spelling.
"""


def response_schema(keys):
    return {
        "type": "OBJECT",
        "properties": {
            "summary": {"type": "STRING"},
            "howToFind": {"type": "STRING"},
            "mythology": {"type": "STRING"},
            "quotes": {
                "type": "ARRAY",
                "items": {
                    "type": "OBJECT",
                    "properties": {"text": {"type": "STRING"}, "source": {"type": "STRING", "enum": list(keys)}},
                    "required": ["text", "source"],
                },
            },
        },
        "required": ["summary", "howToFind", "mythology", "quotes"],
        "propertyOrdering": ["summary", "howToFind", "mythology", "quotes"],
    }


def build_prompt(cid, cat, sources):
    c = cat.by_id[cid]
    facts = cat.hints(cid)
    facts["brightestStarNames"] = [s["name"] for s in cat.brightest(cid) if s["name"]]
    parts = [
        f"CONSTELLATION: {c['name']} (IAU abbreviation {cid}, genitive {c['genitive']})",
        "FACTS (computed from the star catalogue):\n" + json.dumps(facts, ensure_ascii=False, indent=1),
        "SOURCES:",
    ]
    for s in sources:
        parts.append(f"=== SOURCE key={s['key']} | {s['title']} ===\n{s['text']}\n=== END SOURCE {s['key']} ===")
    return "\n\n".join(parts)


def request_body(prompt, keys, history):
    contents = [{"role": "user", "parts": [{"text": prompt}]}]
    for answer, feedback in history:
        contents.append({"role": "model", "parts": [{"text": answer}]})
        contents.append({"role": "user", "parts": [{"text": feedback}]})
    return {
        "systemInstruction": {"parts": [{"text": SYSTEM_PROMPT}]},
        "contents": contents,
        "generationConfig": {
            "temperature": 0.4,
            # default thinking spent ~60k thought tokens / ~4 min per card; "low" is plenty for copy-from-sources prose
            "thinkingConfig": {"thinkingLevel": "low"},
            "responseMimeType": "application/json",
            "responseSchema": response_schema(keys),
        },
    }


class ApiError(Exception):
    pass


def call_model(model, key, body, cid):
    payload = json.dumps(body, sort_keys=True, ensure_ascii=False)
    digest = hashlib.sha256((model + "\n" + payload).encode("utf-8")).hexdigest()[:16]
    cache = RAW_DIR / cid / f"{digest}.json"
    if cache.exists():
        return json.loads(cache.read_text(encoding="utf-8"))["response"], True
    for backoff in (10, 30, 60, 120, 0):
        try:
            r = requests.post(ENDPOINT.format(model=model), data=payload.encode("utf-8"), timeout=300,
                              headers={"x-goog-api-key": key, "Content-Type": "application/json; charset=utf-8"})
        except requests.RequestException as e:
            raise ApiError(redact(f"request failed: {e}", key)) from None
        if r.status_code not in (429, 503) or not backoff:
            break
        print(f"  {cid}: HTTP {r.status_code}, retrying in {backoff}s", flush=True)
        time.sleep(backoff)
    if r.status_code != 200:
        raise ApiError(redact(f"HTTP {r.status_code}: {r.text[:2000]}", key))
    data = r.json()
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(json.dumps({"model": model, "request_sha": digest, "response": data}, ensure_ascii=False, indent=1),
                     encoding="utf-8")
    return data, False


def response_text(data):
    cands = data.get("candidates") or []
    if not cands:
        raise ValueError(f"no candidates (promptFeedback={data.get('promptFeedback')})")
    parts = cands[0].get("content", {}).get("parts", [])
    text = "".join(p.get("text", "") for p in parts if not p.get("thought"))
    if not text:
        raise ValueError(f"empty response (finishReason={cands[0].get('finishReason')})")
    return text


# ---------------------------------------------------------------------------
# Checker


_QUOTE_MAP = str.maketrans({
    "\u2018": "'", "\u2019": "'", "\u201a": "'", "\u201b": "'", "\u2032": "'", "\u00b4": "'",
    "\u201c": '"', "\u201d": '"', "\u201e": '"', "\u201f": '"', "\u2033": '"', "\u00ab": '"', "\u00bb": '"',
    "\u2010": "-", "\u2011": "-", "\u2012": "-", "\u2013": "-", "\u2014": "-", "\u2015": "-", "\u2212": "-",
})


def normalize(text):
    """Only whitespace, quote-style and dash-style differences are forgiven (plus Unicode NFC canonical form)."""
    text = unicodedata.normalize("NFC", text).translate(_QUOTE_MAP)
    text = re.sub(r"\s*-\s*-\s*", " - ", text)
    text = re.sub(r"\s+", " ", text)
    text = re.sub(r" ?- ?", "-", text)
    return text.strip()


def quoted_spans(text):
    spans = re.findall(r"[\"\u201c\u201e]([^\"\u201c\u201d\u201e]+)[\"\u201d]", text)
    spans += re.findall(r"(?<![A-Za-z])\u2018(.+?)\u2019(?![A-Za-z])", text)
    return [s.strip() for s in spans if s.strip()]


_NUMERIC_FACT = re.compile(
    r"(\d[\d,.]*\s*(?:-\s*)?(?:light[- ]?years?|ly\b|parsecs?\b|pc\b))|(\bmagnitudes?\s*(?:of\s*)?[-\u2212+]?\d)|(\bmag\.?\s*[-\u2212+]?\d)",
    re.I,
)


def check_card(card, sources):
    """-> list of human-readable problems; empty means the card passes."""
    problems = []
    by_key = {s["key"]: normalize(s["text"]) for s in sources}
    everything = "\n".join(by_key.values())
    for field in ("summary", "howToFind", "mythology"):
        value = card.get(field)
        if not isinstance(value, str) or not value.strip():
            problems.append(f"{field} is empty")
            continue
        for span in quoted_spans(value):
            if normalize(span) not in everything:
                problems.append(f'{field} puts "{span}" in quotation marks but that text is not word for word in any source')
        m = _NUMERIC_FACT.search(value)
        if m:
            problems.append(f'{field} states a magnitude or distance ("{m.group(0)}"); remove it, the app inserts those')
    quotes = card.get("quotes")
    if not isinstance(quotes, list):
        problems.append("quotes must be a list")
        quotes = []
    for q in quotes:
        text, key = (q or {}).get("text", ""), (q or {}).get("source")
        if key not in by_key:
            problems.append(f"quote source {key!r} is not one of {sorted(by_key)}")
            continue
        n = normalize(text)
        if not n:
            problems.append("empty quote")
        elif n not in by_key[key]:
            elsewhere = [k for k, t in by_key.items() if n in t]
            hint = f" (it does appear in {elsewhere[0]})" if elsewhere else ""
            problems.append(f'quote not found word for word in source {key}{hint}: "{text}"')
    return problems


def feedback_message(problems):
    return ("Your answer was rejected by an automatic check:\n- " + "\n- ".join(problems) +
            "\nReturn the full JSON again. Copy quoted text character for character from a single source, "
            "or remove the quotation marks / the quote.")


# ---------------------------------------------------------------------------


def generate_card(cid, cat, sources, model, key, log):
    keys = [s["key"] for s in sources]
    prompt = build_prompt(cid, cat, sources)
    history = []
    problems = []
    for attempt in range(MAX_RETRIES + 1):
        data, cached = call_model(model, key, request_body(prompt, keys, history), cid)
        try:
            answer = response_text(data)
            card = json.loads(answer)
            problems = check_card(card, sources)
        except (ValueError, json.JSONDecodeError) as e:
            answer, card, problems = "{}", None, [f"response was not valid JSON for the schema: {e}"]
        log(f"  {cid} attempt {attempt + 1}{' (cached)' if cached else ''}: {'ok' if not problems else '; '.join(problems)[:300]}")
        if not problems:
            title = {s["key"]: s["title"] for s in sources}
            return {
                "id": cid, "name": cat.by_id[cid]["name"],
                "summary": card["summary"].strip(), "howToFind": card["howToFind"].strip(), "mythology": card["mythology"].strip(),
                "quotes": [{"text": q["text"].strip(), "source": title[q["source"]]} for q in card["quotes"]],
                "brightestStars": cat.brightest(cid),
                "sources": [{"title": s["title"], "url": s["url"], "licence": s["licence"]} for s in sources],
            }, attempt + 1, []
        history.append((answer, feedback_message(problems)))
    return None, MAX_RETRIES + 1, problems


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--ids", help="comma-separated IAU abbreviations (default: all 88)")
    ap.add_argument("--fetch", action="store_true", help="only download and pin the source texts")
    ap.add_argument("--dry-run", action="store_true", help="build prompts into tools/.cache/narration_prompts/, no API call")
    ap.add_argument("--offline", action="store_true", help="use cached source texts only")
    args = ap.parse_args()

    cat = Catalogue()
    ids = cat.ids if not args.ids else [i.strip() for i in args.ids.split(",") if i.strip()]
    unknown = [i for i in ids if i not in cat.by_id]
    if unknown:
        raise SystemExit(f"unknown ids: {unknown}")
    bundles = fetch_sources(cat, ids, offline=args.offline)
    if args.fetch:
        for cid in ids:
            print(cid, {s["key"]: len(s["text"]) for s in bundles[cid]})
        return

    model, key = load_settings()
    if args.dry_run or not key or not model:
        PROMPT_DIR.mkdir(parents=True, exist_ok=True)
        for cid in ids:
            body = request_body(build_prompt(cid, cat, bundles[cid]), [s["key"] for s in bundles[cid]], [])
            (PROMPT_DIR / f"{cid}.json").write_text(json.dumps(body, ensure_ascii=False, indent=1), encoding="utf-8")
            chars = sum(len(p["text"]) for p in body["contents"][0]["parts"])
            print(f"{cid}: prompt {chars} chars, sources {[s['key'] for s in bundles[cid]]}, brightest {[s['name'] or s['hip'] for s in cat.brightest(cid)]}")
        if not args.dry_run:
            missing = [n for n, v in (("VERTEX_API_KEY in Config/Secrets.xcconfig", key), ("NARRATION_MODEL_ID in Config/Config.xcconfig", model)) if not v]
            print(f"waiting on key/model ID: {', '.join(missing)} not set; prompts written to {PROMPT_DIR}")
        return

    existing = {}
    if OUTPUT.exists():
        existing = {c["id"]: c for c in json.loads(OUTPUT.read_text(encoding="utf-8"))["cards"]}
    failures, attempts = {}, {}
    try:
        for cid in ids:
            card, n, problems = generate_card(cid, cat, bundles[cid], model, key, print)
            attempts[cid] = n
            if card:
                existing[cid] = card
            else:
                failures[cid] = problems
                existing.pop(cid, None)
    except ApiError as e:
        print(f"API error (model {model}): {e}")
        failures["_api"] = [str(e)]
    finally:
        cards = [existing[i] for i in cat.ids if i in existing]
        bc.write_json(OUTPUT, {
            "version": 1, "model": model,
            "generated": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
            "cards": cards,
        })
        report = {"model": model, "cards": len(cards), "attempts": attempts, "failures": failures}
        (bc.CACHE / "narration_report.json").write_text(json.dumps(report, indent=1, ensure_ascii=False), encoding="utf-8")
        print(json.dumps({"cardsInFile": len(cards), "failures": failures}, indent=1, ensure_ascii=False))


if __name__ == "__main__":
    main()
