#!/usr/bin/env python3
"""Builds Data/passages.json: the full pinned source texts split into passages with stable IDs, for grounded Q&A.

Usage (from the repo root):
    .venv/bin/python tools/build_passages.py [--offline] [--ids Ori,Ant]

Sources per constellation (all pinned by sha256):
  wiki   full Wikipedia article at the revision pinned in the narration summary (tools/sources.json, key
         wikipedia_full:<title>, fetched as rendered HTML for that oldid)
  allen  Allen, Star-Names and Their Meanings (1899), LacusCurtius chapter (tools/narration_sources.json)
  aratus Aratus, Phaenomena, tr. Mair (1921), the paragraphs that name the figure (same selection as narration, uncapped)
Passage IDs are "<constellation>-<wiki|allen|aratus>-<n>", n counting from 0 in document order.
"""

import argparse
import html
import json
import re
import sys
import time
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import quote

sys.path.insert(0, str(Path(__file__).resolve().parent))
import build_catalog as bc  # noqa: E402
import generate_narration as gn  # noqa: E402

OUTPUT = bc.DATA / "passages.json"
WIKI_BASE = "https://en.wikipedia.org/w/index.php?title={title}&oldid={rev}&action=render"
TARGET_WORDS = 100
MAX_WORDS = 180
SPLIT_WORDS = 150
STOP_HEADINGS = {"see also", "references", "notes", "explanatory notes", "citations", "external links", "further reading",
                 "bibliography", "sources", "footnotes"}
SKIP_CLASSES = {"infobox", "navbox", "vertical-navbox", "sidebar", "metadata", "mw-editsection", "reflist", "references",
                "hatnote", "thumb", "mw-references-wrap", "noprint", "navbox-styles", "toc", "mw-ref", "reference", "shortdescription"}
SKIP_TAGS = {"style", "script", "link", "meta", "figure", "math"}
BLOCK_TAGS = {"p", "li", "tr", "h2", "h3", "h4", "h5", "dd", "dt", "caption"}


class WikiParser(HTMLParser):
    """Rendered (Parsoid) Wikipedia HTML -> [(heading, paragraph)], dropping infoboxes, navboxes, references and figures."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.sections = []
        self.heading = "Introduction"
        self.buf = []
        self.stack = []
        self.skip = 0
        self.in_heading = None
        self.stopped = False
        self.cells = []

    def _skippable(self, tag, attrs):
        a = dict(attrs)
        classes = set((a.get("class") or "").split())
        return tag in SKIP_TAGS or bool(classes & SKIP_CLASSES) or "mw-references" in (a.get("typeof") or "") \
            or "mw:Extension/references" in (a.get("typeof") or "")

    def handle_starttag(self, tag, attrs):
        if tag in ("br", "hr", "img", "meta", "link", "input", "wbr"):
            if tag == "br" and not self.skip:
                self.buf.append(" ")
            return
        skip = self._skippable(tag, attrs)
        self.stack.append((tag, skip))
        if skip:
            self.skip += 1
            return
        if self.skip or self.stopped:
            return
        if tag in ("td", "th"):
            self._flush_cell_start()
        if tag in BLOCK_TAGS or tag == "table":
            self._flush()
        if tag in ("h2", "h3", "h4", "h5"):
            self.in_heading = tag

    def handle_endtag(self, tag):
        idx = next((i for i in range(len(self.stack) - 1, -1, -1) if self.stack[i][0] == tag), None)
        if idx is None:
            return
        popped = self.stack[idx:]
        del self.stack[idx:]
        was_skip = any(s for _, s in popped)
        for _, s in popped:
            if s:
                self.skip -= 1
        if was_skip or self.skip or self.stopped:
            return
        if tag in ("td", "th"):
            self.cells.append(self._take())
        elif tag == "tr":
            row = [c for c in self.cells if c]
            self.cells = []
            if row:
                self._emit(" | ".join(row))
        elif tag in ("h2", "h3", "h4", "h5") and self.in_heading == tag:
            title = re.sub(r"\s+", " ", "".join(self.buf)).strip()
            self.buf = []
            self.in_heading = None
            if title.lower() in STOP_HEADINGS:
                self.stopped = True
            elif title and title.lower() != "contents":
                self.heading = title
        elif tag in BLOCK_TAGS:
            self._flush()

    def handle_data(self, data):
        if self.skip or self.stopped:
            return
        self.buf.append(data)

    def _take(self):
        text = re.sub(r"\s+", " ", "".join(self.buf)).strip()
        self.buf = []
        return text

    def _flush_cell_start(self):
        self.buf = []

    def _emit(self, text):
        text = bc_clean(text)
        if text:
            self.sections.append((self.heading, text))

    def _flush(self):
        if self.in_heading:
            return
        if self.stack and any(t in ("td", "th") for t, _ in self.stack):
            return
        text = self._take()
        if text:
            self._emit(text)


def bc_clean(text):
    return gn.clean_text(re.sub(r"\s+([,.;:!?)])", r"\1", re.sub(r"([(])\s+", r"\1", text)))


def wiki_paragraphs(raw_html):
    p = WikiParser()
    p.feed(raw_html)
    p._flush()
    return p.sections


SENTENCE = re.compile(r"(?<=[.!?])\s+(?=[A-Z\"\u201c\u2018(])")


def split_long(text, limit=SPLIT_WORDS):
    if len(text.split()) <= limit:
        return [text]
    out, cur, count = [], [], 0
    for sentence in SENTENCE.split(text):
        n = len(sentence.split())
        if cur and count + n > limit:
            out.append(" ".join(cur))
            cur, count = [], 0
        cur.append(sentence)
        count += n
    if cur:
        out.append(" ".join(cur))
    return out


def chunk(blocks):
    """[(heading, paragraph)] -> [(heading, text)]: paragraphs under one heading are merged up to MAX_WORDS, flushing at
    TARGET_WORDS; a paragraph longer than SPLIT_WORDS is cut at sentence boundaries."""
    out, cur, heading, count = [], [], None, 0

    def flush():
        nonlocal cur, count
        if cur:
            out.append((heading, "\n".join(cur)))
        cur, count = [], 0

    for h, para in blocks:
        if h != heading:
            flush()
            heading = h
        for piece in split_long(para):
            n = len(piece.split())
            if cur and count + n > MAX_WORDS:
                flush()
            cur.append(piece)
            count += n
            if count >= TARGET_WORDS:
                flush()
    flush()
    return out


def allen_blocks(text):
    return [("Allen", ln) for ln in text.split("\n") if ln.strip()]


def aratus_blocks_for(cid, blocks):
    terms = gn.ARATUS_TERMS.get(cid)
    if not terms:
        return []
    pattern = re.compile(r"(?<![A-Za-z])(" + "|".join(re.escape(t) for t in terms) + r")(?![a-z])")
    out = []
    for line, text in blocks:
        if pattern.search(text):
            out.append((f"Phaenomena, line {line}", gn.strip_glosses(text)))
    return out


def fetch_wikipedia(src, title, summary_revision):
    key = title.replace(" ", "_")
    url = WIKI_BASE.format(title=quote(key, safe="()_,"), rev=summary_revision)
    path = src.get(f"wikipedia_full:{key}", url=url,
                   version=f"Wikipedia '{title}' revision {summary_revision}, rendered HTML (action=render&oldid)",
                   path=f"wikipedia_full/{key}.html")
    return path.read_text(encoding="utf-8")


def build(ids=None, offline=False):
    src = bc.Sources(offline=offline)
    nsrc = bc.Sources(offline=True, manifest=gn.NARRATION_MANIFEST)
    table = {t[0]: t for t in bc.parse_constellation_table(bc.Sources(offline=True).get("iau_constellations_wiki"))}
    aratus_all = gn.aratus_blocks(nsrc.get("aratus").read_text(encoding="utf-8"))
    sources, passages, stats = {}, {}, {}
    try:
        for cid in table:
            if ids and cid not in ids:
                continue
            title = table[cid][3]
            wkey = title.replace(" ", "_")
            summary = json.loads(nsrc.get(f"wikipedia:{wkey}").read_text(encoding="utf-8"))
            rev = summary["revision"]
            wiki_html = fetch_wikipedia(src, title, rev)
            page = gn.ALLEN_PAGES[cid]
            allen = gn.allen_text(nsrc.get(f"allen:{page}").read_text(encoding="utf-8", errors="replace"))
            groups = [("wiki", chunk(wiki_paragraphs(wiki_html))), ("allen", chunk(allen_blocks(allen))),
                      ("aratus", chunk(aratus_blocks_for(cid, aratus_all)))]
            sources[cid] = [
                {"key": "wiki", "title": f"Wikipedia: {summary['title']}", "revision": rev,
                 "url": f"https://en.wikipedia.org/w/index.php?title={quote(wkey, safe='()_,')}&oldid={rev}",
                 "licence": gn.WIKIPEDIA_LICENCE},
                {"key": "allen", "title": f"{gn.ALLEN_TITLE}: {page.replace('_', ' ')}", "url": gn.ALLEN_URL.format(page=page),
                 "licence": gn.ALLEN_LICENCE},
            ]
            if groups[2][1]:
                sources[cid].append({"key": "aratus", "title": gn.ARATUS_TITLE, "url": gn.ARATUS_URL, "licence": gn.ARATUS_LICENCE})
            passages[cid] = [{"id": f"{cid}-{k}-{n}", "s": k, "h": h, "t": t}
                             for k, items in groups for n, (h, t) in enumerate(items)]
            stats[cid] = {k: len(items) for k, items in groups}
    finally:
        src.save()
    return sources, passages, stats


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--offline", action="store_true")
    ap.add_argument("--ids")
    args = ap.parse_args()
    ids = set(args.ids.split(",")) if args.ids else None
    sources, passages, stats = build(ids, args.offline)
    if ids:
        for cid in sorted(passages):
            print(cid, stats[cid], sum(len(p["t"].split()) for p in passages[cid]), "words")
        return
    bc.write_json(OUTPUT, {
        "version": 1,
        "format": (
            "sources: {constellationId: [{key: wiki|allen|aratus, title, url, licence, revision?}]}; "
            "passages: {constellationId: [{id: '<cst>-<key>-<n>', s: key, h: heading, t: text}]}. Paragraphs of one "
            f"heading are merged up to {MAX_WORDS} words; paragraphs are separated by newlines inside t. Quotations are checked "
            "against t after whitespace/quote-style/dash normalisation only."
        ),
        "sources": sources,
        "passages": passages,
    }, compact=True)
    words = sum(len(p["t"].split()) for ps in passages.values() for p in ps)
    count = sum(len(ps) for ps in passages.values())
    by_src = {k: sum(v[k] for v in stats.values()) for k in ("wiki", "allen", "aratus")}
    print(json.dumps({"constellations": len(passages), "passages": count, "bySource": by_src, "words": words,
                      "bytes": OUTPUT.stat().st_size}))


if __name__ == "__main__":
    main()
