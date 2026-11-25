#!/usr/bin/env python3
"""Unit tests for check_tool_attribution.py. Run from inside .github/scripts/:

    python3 -m unittest test_check_tool_attribution -v

No network access and no AWS resource is used; this only exercises the
checker's own matching logic against temporary files.
"""
import importlib.util
import pathlib
import tempfile
import unittest

_MODULE_PATH = pathlib.Path(__file__).resolve().with_name("check_tool_attribution.py")
_spec = importlib.util.spec_from_file_location("check_tool_attribution", _MODULE_PATH)
check_tool_attribution = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(check_tool_attribution)


def _write_tmp(suffix: str, content: str) -> str:
    f = tempfile.NamedTemporaryFile("w", suffix=suffix, delete=False, encoding="utf-8")
    f.write(content)
    f.close()
    return f.name


class LoadDenylistTests(unittest.TestCase):
    def test_skips_blank_and_comment_lines(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write("# a comment\n\nAlpha\n\n# another\nBeta Two\n")
            path = f.name
        self.assertEqual(check_tool_attribution.load_denylist(path), ["Alpha", "Beta Two"])

    def test_empty_denylist_raises(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write("# only comments\n\n")
            path = f.name
        with self.assertRaises(SystemExit):
            check_tool_attribution.load_denylist(path)


class NormalizeTests(unittest.TestCase):
    """Each case puts the break/space/zero-width character INSIDE the two-word
    phrase "independent model" (or inside the word "Fable"), with a control
    assertion that the un-normalized text does NOT already contain the
    phrase/word on its own -- so a no-op normalize(), or one missing the
    specific fix under test, fails here rather than passing vacuously."""

    def test_collapses_line_break_inside_the_phrase(self):
        text = "a tool called independent\nmodel was used"
        self.assertNotIn("independent model", text.lower())
        self.assertIn("independent model", check_tool_attribution.normalize(text).lower())

    def test_collapses_crlf_inside_the_phrase(self):
        text = "a tool called independent\r\nmodel was used"
        self.assertNotIn("independent model", text.lower())
        self.assertIn("independent model", check_tool_attribution.normalize(text).lower())

    def test_collapses_double_space_inside_the_phrase(self):
        text = "a tool called independent  model was used"
        self.assertNotIn("independent model", text.lower())
        self.assertIn("independent model", check_tool_attribution.normalize(text).lower())

    def test_collapses_non_breaking_space_inside_the_phrase(self):
        text = "a tool called independent model was used"
        self.assertNotIn("independent model", text.lower())
        self.assertIn("independent model", check_tool_attribution.normalize(text).lower())

    def test_strips_zero_width_character_inside_a_word(self):
        text = "Fa​ble was used"
        self.assertNotIn("fable", text.lower())
        self.assertIn("fable", check_tool_attribution.normalize(text).lower())

    def test_full_pipeline_matches_a_term_split_by_crlf(self):
        # End to end through main(), not just normalize() in isolation: a
        # denylisted multi-word term split by a CRLF across what would be
        # two commit-message lines must still be caught.
        denylist = _write_tmp(".txt", "independent model\n")
        dirty = _write_tmp(".txt", "a tool called independent\r\nmodel helped here")
        self.assertEqual(
            check_tool_attribution.main(["--denylist", denylist, "--label", "crlf", dirty]), 1
        )


class MatchingBehaviourTests(unittest.TestCase):
    def _denylist(self, terms):
        f = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False)
        f.write("\n".join(terms) + "\n")
        f.close()
        return f.name

    def _textfile(self, text):
        f = tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False)
        f.write(text)
        f.close()
        return f.name

    def test_case_insensitive_match(self):
        denylist = self._denylist(["Alpha"])
        clean = self._textfile("nothing to see here")
        dirty = self._textfile("used aLPHA for this")
        self.assertEqual(
            check_tool_attribution.main(["--denylist", denylist, "--label", "clean", clean]), 0
        )
        self.assertEqual(
            check_tool_attribution.main(["--denylist", denylist, "--label", "dirty", dirty]), 1
        )

    def test_checks_every_file_given(self):
        denylist = self._denylist(["Alpha"])
        clean = self._textfile("nothing here")
        dirty = self._textfile("has Alpha in it")
        self.assertEqual(
            check_tool_attribution.main(
                ["--denylist", denylist, "--label", "multi", clean, dirty]
            ),
            1,
        )

    def test_term_is_a_literal_substring_not_a_regex(self):
        denylist = self._denylist(["a.b"])
        literal = self._textfile("contains a.b literally")
        regex_like = self._textfile("contains axb which should not match")
        self.assertEqual(
            check_tool_attribution.main(["--denylist", denylist, "--label", "literal", literal]),
            1,
        )
        self.assertEqual(
            check_tool_attribution.main(
                ["--denylist", denylist, "--label", "regex-like", regex_like]
            ),
            0,
        )


if __name__ == "__main__":
    unittest.main()
