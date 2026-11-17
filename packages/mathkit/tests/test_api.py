"""Tests for top-level exports and basic object representations."""

from __future__ import annotations

import unittest

import mathkit


class ApiTests(unittest.TestCase):
    def test_all_exports_exist(self) -> None:
        for name in mathkit.__all__:
            self.assertTrue(hasattr(mathkit, name), msg=f"missing export: {name}")

    def test_checkresult_text(self) -> None:
        result = mathkit.check("x+1", "x+2")
        self.assertIn("Not quite yet", str(result))
        self.assertTrue(result._repr_markdown_().strip())


if __name__ == "__main__":
    unittest.main()
