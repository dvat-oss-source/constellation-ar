import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import generate_narration as gn  # noqa: E402

SOURCES = [
    {"key": "wikipedia", "text": 'Antlia is a constellation in the Southern Celestial Hemisphere. Its name means "pump" in Latin and Greek.'},
    {"key": "allen", "text": "Antlia Pneumatica, the Air Pump,\n\nis La Caille's Machine Pneumatique, at first Latinized as\nMachina Pneumatica \u2014 which occurs in Burritt."},
    {"key": "aratus", "text": "Aslant beneath the fore-body of the Bull is set the great Orion. Let none who pass him spread out on high on a cloudless night imagine that, gazing on the heavens, one shall see other stars more fair."},
]


def card(**kw):
    base = {
        "summary": "Antlia is a small southern constellation representing an air pump.",
        "howToFind": "Look south of Hydra in April evenings.",
        "mythology": "It is a modern constellation introduced by Lacaille and has no classical myth.",
        "quotes": [],
    }
    base.update(kw)
    return base


class NormalizeTests(unittest.TestCase):
    def test_whitespace_quotes_dashes(self):
        self.assertEqual(gn.normalize("La\u00a0Caille\u2019s  \n Machine"), "La Caille's Machine")
        self.assertEqual(gn.normalize("\u201cpump\u201d"), '"pump"')
        self.assertEqual(gn.normalize("as \u2014 which"), gn.normalize("as - which"))
        self.assertEqual(gn.normalize("as\u2013which"), gn.normalize("as -- which"))
        self.assertEqual(gn.normalize("fore\u2011body"), "fore-body")

    def test_nfc(self):
        self.assertEqual(gn.normalize("Boo\u0308tes"), gn.normalize("Bo\u00f6tes"))

    def test_no_other_forgiveness(self):
        self.assertNotEqual(gn.normalize("Pump"), gn.normalize("pump"))
        self.assertNotEqual(gn.normalize("colour"), gn.normalize("color"))


class CheckerTests(unittest.TestCase):
    def test_clean_card_passes(self):
        self.assertEqual(gn.check_card(card(), SOURCES), [])

    def test_verbatim_quotes_pass_with_whitespace_and_typography_changes(self):
        c = card(quotes=[
            {"text": "is La Caille\u2019s Machine Pneumatique, at first Latinized as Machina Pneumatica - which occurs in Burritt.", "source": "allen"},
            {"text": "Aslant beneath the fore-body of the Bull is set the great Orion.", "source": "aratus"},
        ])
        self.assertEqual(gn.check_card(c, SOURCES), [])

    def test_altered_quote_rejected(self):
        c = card(quotes=[{"text": "Aslant beneath the forebody of the Bull is set great Orion.", "source": "aratus"}])
        problems = gn.check_card(c, SOURCES)
        self.assertEqual(len(problems), 1)
        self.assertIn("not found word for word", problems[0])

    def test_quote_attributed_to_wrong_source_rejected(self):
        c = card(quotes=[{"text": "Antlia Pneumatica, the Air Pump,", "source": "wikipedia"}])
        problems = gn.check_card(c, SOURCES)
        self.assertEqual(len(problems), 1)
        self.assertIn("does appear in allen", problems[0])

    def test_unknown_source_rejected(self):
        problems = gn.check_card(card(quotes=[{"text": "pump", "source": "hyginus"}]), SOURCES)
        self.assertIn("not one of", problems[0])

    def test_quoted_prose_must_be_in_sources(self):
        ok = card(summary='Its name means "pump" in Latin; Allen calls it \u201cthe Air Pump\u201d.')
        self.assertEqual(gn.check_card(ok, SOURCES), [])
        bad = card(mythology="Lacaille called it \u201cthe philosopher\u2019s bellows\u201d.")
        problems = gn.check_card(bad, SOURCES)
        self.assertEqual(len(problems), 1)
        self.assertIn("philosopher", problems[0])

    def test_single_curly_quotes_checked_but_apostrophes_ignored(self):
        self.assertEqual(gn.check_card(card(summary="Lacaille\u2019s pump is \u2018Machina Pneumatica\u2019."), SOURCES), [])
        self.assertTrue(gn.check_card(card(summary="It was \u2018the vacuum engine\u2019 once."), SOURCES))

    def test_magnitudes_and_distances_rejected(self):
        for text in ("Its brightest star is 366 light-years away.", "Alpha shines at magnitude 4.3.",
                     "It lies 112 parsecs off.", "A mag 4 star."):
            problems = gn.check_card(card(howToFind=text), SOURCES)
            self.assertTrue(any("magnitude or distance" in p for p in problems), text)

    def test_empty_field_rejected(self):
        self.assertIn("summary is empty", gn.check_card(card(summary=" "), SOURCES))


class ExtractionTests(unittest.TestCase):
    def test_allen_parser_drops_thayer_material(self):
        html = """<html><body><TABLE><TR><TD>header nav</TD></TR></TABLE>
        <A ID="p42"><SPAN CLASS="pagenum"> p42 </SPAN></A>
        <P CLASS="justify">Antlia Pneumatica, the Air Pump,<A CLASS="ref" HREF="#note:x">a</A> is La Caille's
        <SPAN CLASS="added_link">[<SPAN CLASS="small">XI</SPAN>.310]</SPAN> Machine&shy;Pneumatique.
        <P CLASS="justify">Second paragraph.
        <HR CLASS="endnotes"><P>Thayer's Notes: modern commentary</P></body></html>"""
        text = gn.allen_text(html)
        self.assertEqual(text, "Antlia Pneumatica, the Air Pump, is La Caille's MachinePneumatique.\nSecond paragraph.")
        self.assertNotIn("Thayer", text)
        self.assertNotIn("header nav", text)

    def test_aratus_blocks_and_glosses(self):
        html = """<h2>PHAENOMENA, TRANSLATED BY G. R. MAIR </h2>
        <p>[233] There is also another sign, fashioned near, below Andromeda, Deltoton [Triangulum], drawn
        with three sides.</p><p>[322] Aslant beneath the fore-body of the Bull is set the great Orion.</p><footer>x</footer>"""
        blocks = gn.aratus_blocks(html)
        self.assertEqual([b[0] for b in blocks], [233, 322])
        self.assertEqual(gn.aratus_text_for("Tri", blocks),
                         "There is also another sign, fashioned near, below Andromeda, Deltoton, drawn with three sides.")
        self.assertIn("great Orion", gn.aratus_text_for("Ori", blocks))
        self.assertEqual(gn.aratus_text_for("Ant", blocks), "")

    def test_xcconfig_and_redaction(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "Secrets.xcconfig"
            p.write_text("// comment = no\nVERTEX_API_KEY = abc123\nNARRATION_MODEL_ID = gemini-x\n")
            vals = gn.read_xcconfig(p)
        self.assertEqual(vals, {"VERTEX_API_KEY": "abc123", "NARRATION_MODEL_ID": "gemini-x"})
        self.assertEqual(gn.redact("bad key abc123 at ?key=abc123&x=1", "abc123"), "bad key <redacted> at ?key=<redacted>&x=1")

    def test_response_text_skips_thoughts(self):
        data = {"candidates": [{"content": {"parts": [{"text": "thinking", "thought": True}, {"text": '{"a":'}, {"text": "1}"}]}}]}
        self.assertEqual(gn.response_text(data), '{"a":1}')


class CatalogueFactTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        if not (gn.bc.DATA / "test" / "vi49_bounds.json").exists():
            raise unittest.SkipTest("catalogue not built")
        cls.cat = gn.Catalogue()

    def test_orion_brightest(self):
        stars = self.cat.brightest("Ori")
        self.assertEqual([s["name"] for s in stars[:2]], ["Rigel", "Betelgeuse"])
        self.assertEqual(stars[0]["vmag"], 0.18)
        self.assertTrue(700 < stars[0]["distanceLy"] < 900)

    def test_alpha_centauri_distance(self):
        rigil = self.cat.brightest("Cen")[0]
        self.assertEqual(rigil["hip"], 71683)
        self.assertAlmostEqual(rigil["distanceLy"], 4.4, delta=0.1)

    def test_neighbours_and_visibility(self):
        self.assertEqual(self.cat.neighbours["Cru"], ["Cen", "Mus"])
        self.assertEqual(self.cat.hints("Ant")["fullyVisibleBetweenLatitudes"], [-90, 50])
        self.assertEqual(self.cat.hints("Ori")["highestAt9pmAround"], "January")


if __name__ == "__main__":
    unittest.main()
