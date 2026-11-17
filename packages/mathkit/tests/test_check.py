"""Tests for friendly equivalence checking and non-leaky feedback."""

from __future__ import annotations

import unittest

import sympy as sp

from mathkit import CheckResult, check, same


class CheckTests(unittest.TestCase):
    def test_equivalent_strings(self) -> None:
        result = check("2x+3", "3+2*x")
        self.assertTrue(result.ok)
        self.assertTrue(result)

    def test_xor_power_parsing(self) -> None:
        self.assertTrue(same("x^2", "x*x"))

    def test_equation_relation_factor(self) -> None:
        x = sp.Symbol("x")
        self.assertTrue(same(sp.Eq(2 * x, 4), sp.Eq(x, 2)))

    def test_solution_collections(self) -> None:
        self.assertTrue(same({sp.Integer(2), sp.Integer(3)}, [sp.Integer(3), sp.Integer(2)]))
        self.assertFalse(same({sp.Integer(2), sp.Integer(4)}, [sp.Integer(3), sp.Integer(2)]))

    def test_matrix_comparison(self) -> None:
        left = sp.Matrix([[1, "x"], [sp.Rational(1, 2), 4]])
        right = sp.Matrix([[1, sp.Symbol("x")], [sp.Rational(1, 2), 4]])
        self.assertTrue(same(left, right))

    def test_sign_error_hint(self) -> None:
        result = check("-x^2", "x^2")
        self.assertFalse(result.ok)
        self.assertIn("sign error", result.hint.lower())

    def test_constant_offset_hint(self) -> None:
        result = check("x+2", "x+5")
        self.assertFalse(result.ok)
        self.assertIn("constant amount", result.hint.lower())

    def test_factor_hint(self) -> None:
        result = check("3*(x+1)", "2*(x+1)")
        self.assertFalse(result.ok)
        self.assertIn("constant factor", result.hint.lower())

    def test_counterexample_message_does_not_leak_answer(self) -> None:
        answer = sp.Symbol("x") + 7
        result = check("x+2", answer)
        self.assertFalse(result.ok)
        self.assertIn("yours gives", result.message)
        self.assertNotIn("x + 7", result.message)
        self.assertNotIn("x + 7", result.hint)

    def test_numeric_mismatch_does_not_reveal_answer(self) -> None:
        result = check(5, 7)
        self.assertFalse(result.ok)
        self.assertNotIn("7", result.message)
        self.assertNotIn("7", result.hint)

    def test_string_answer_not_revealed(self) -> None:
        result = check("x+2", "x+7")
        self.assertFalse(result.ok)
        self.assertNotIn("x + 7", result.message)
        self.assertNotIn("x + 7", result.hint)

    def test_bad_parse_is_gentle(self) -> None:
        result = check("x+(", "x+1")
        self.assertFalse(result.ok)
        self.assertIn("could not read", result.message.lower())

    def test_odd_pairs_never_raise(self) -> None:
        x = sp.Symbol("x")
        pairs = [
            (0, sp.Matrix([[1, 2], [3, 4]])),
            ([1, 2, 3], x + 1),
            ("??", "x+1"),
            (None, x),
            (sp.Eq(x, 2), 2),
            ({1, 2}, sp.Matrix([[1]])),
            (10**200, 10**200 + 1),
            (sp.oo, 1),
            (sp.nan, 0),
            (sp.zoo, 2),
        ]
        for mine, answer in pairs:
            with self.subTest(mine=mine, answer=answer):
                result = check(mine, answer)
                self.assertIsInstance(result, CheckResult)
                self.assertIn(result.ok, (True, False))

    def test_kind_mismatch_message_is_gentle(self) -> None:
        result = check(0, sp.Matrix([[1, 2], [3, 4]]))
        self.assertFalse(result.ok)
        self.assertIn("different kinds of things", result.message.lower())


if __name__ == "__main__":
    unittest.main()
