"""Tests for worked-step helpers across calculus and arithmetic topics."""

from __future__ import annotations

import unittest

import sympy as sp

from mathkit import (
    diff_steps,
    expand_steps,
    factor_steps,
    frac_steps,
    gcd_lcm_steps,
    integrate_steps,
    long_division,
    prime_factors,
    solve_steps,
)


class DiffStepsTests(unittest.TestCase):
    def test_product_chain_story(self) -> None:
        x = sp.Symbol("x")
        s = diff_steps(sp.sin(x**2) * sp.exp(3 * x), x)
        self.assertTrue(s.verified)
        self.assertEqual(sp.simplify(s.result - sp.diff(sp.sin(x**2) * sp.exp(3 * x), x)), 0)
        plain = str(s)
        self.assertIn("Use the product rule on the whole expression", plain)
        self.assertIn("Part 1", plain)
        self.assertIn("Part 2", plain)
        self.assertIn("Assemble the product rule", plain)

    def test_quotient_rule_story(self) -> None:
        x = sp.Symbol("x")
        s = diff_steps((x**2 + 1) / (x - 3), x)
        self.assertTrue(s.verified)
        self.assertEqual(sp.simplify(s.result - sp.diff((x**2 + 1) / (x - 3), x)), 0)
        plain = str(s)
        self.assertIn("Use the quotient rule on the whole expression", plain)
        self.assertIn("Assemble the quotient rule", plain)

    def test_sqrt_story(self) -> None:
        x = sp.Symbol("x")
        s = diff_steps(sp.sqrt(1 - x**2), x)
        self.assertTrue(s.verified)
        self.assertEqual(sp.simplify(s.result - sp.diff(sp.sqrt(1 - x**2), x)), 0)
        self.assertIn("chain rule on a square root", str(s))

    def test_sum_rule_polynomial_story(self) -> None:
        x = sp.Symbol("x")
        s = diff_steps(5 * x**3 - 4 * x + 7, x)
        self.assertTrue(s.verified)
        self.assertEqual(sp.simplify(s.result - (15 * x**2 - 4)), 0)
        plain = str(s)
        self.assertIn("Use the sum rule on the whole expression", plain)
        self.assertIn("constant rule", plain)

    def test_atan_and_log_chain(self) -> None:
        x = sp.Symbol("x")
        atan_story = diff_steps(sp.atan(2 * x), x)
        log_story = diff_steps(sp.log(sp.sin(x)), x)
        self.assertTrue(atan_story.verified)
        self.assertTrue(log_story.verified)
        self.assertEqual(sp.simplify(atan_story.result - sp.diff(sp.atan(2 * x), x)), 0)
        self.assertEqual(sp.simplify(log_story.result - sp.diff(sp.log(sp.sin(x)), x)), 0)
        self.assertIn("chain rule on arctangent", str(atan_story))
        self.assertIn("chain rule on logarithm", str(log_story))

    def test_x_power_x_honest_fallback(self) -> None:
        x = sp.Symbol("x")
        s = diff_steps(x**x, x)
        self.assertTrue(s.verified)
        self.assertIn("use SymPy", str(s))


class IntegrateStepsTests(unittest.TestCase):
    def test_parts_story_x_exp_x(self) -> None:
        x = sp.Symbol("x")
        s = integrate_steps(x * sp.exp(x), x)
        self.assertTrue(s.verified)
        self.assertEqual(sp.simplify(sp.diff(s.result, x) - x * sp.exp(x)), 0)
        plain = str(s)
        self.assertIn("Choose u and dv", plain)
        self.assertIn("Use ∫u dv = uv − ∫v du", plain)
        self.assertIn("Combine the parts", plain)
        self.assertIn("Check by differentiating", plain)

    def test_parts_twice_x2_exp_x(self) -> None:
        x = sp.Symbol("x")
        s = integrate_steps(x**2 * sp.exp(x), x)
        self.assertTrue(s.verified)
        self.assertEqual(sp.simplify(sp.diff(s.result, x) - x**2 * sp.exp(x)), 0)
        self.assertGreaterEqual(str(s).count("Choose u and dv"), 2)

    def test_parts_log_and_x_sin(self) -> None:
        x = sp.Symbol("x")
        log_story = integrate_steps(sp.log(x), x)
        xsin_story = integrate_steps(x * sp.sin(x), x)
        self.assertTrue(log_story.verified)
        self.assertTrue(xsin_story.verified)
        self.assertEqual(sp.simplify(sp.diff(log_story.result, x) - sp.log(x)), 0)
        self.assertEqual(sp.simplify(sp.diff(xsin_story.result, x) - x * sp.sin(x)), 0)

    def test_substitution_stories(self) -> None:
        x = sp.Symbol("x")
        stories = [
            integrate_steps(2 * x * sp.cos(x**2), x),
            integrate_steps(x * sp.exp(x**2), x),
            integrate_steps(sp.sin(x) * sp.cos(x) ** 2, x),
        ]
        for story in stories:
            self.assertTrue(story.verified)
            plain = str(story)
            self.assertIn("Choose substitution", plain)
            self.assertIn("Rewrite using u", plain)
            self.assertIn("Solve the u-integral", plain)
            self.assertIn("Substitute back", plain)

    def test_rule_steps_show_integral_and_answer(self) -> None:
        x = sp.Symbol("x")
        cases = [sp.exp(x), x**3, sp.sin(x), sp.Integer(7), 1 / x]
        for expr in cases:
            s = integrate_steps(expr, x)
            self.assertTrue(s.verified)
            plain = str(s)
            self.assertIn("Write the antiderivative", plain)

    def test_definite_integrals_show_f_of_b_minus_f_of_a(self) -> None:
        x = sp.Symbol("x")
        square = integrate_steps(x**2, x, bounds=(0, 3))
        sine = integrate_steps(sp.sin(x), x, bounds=(0, sp.pi))
        reciprocal = integrate_steps(1 / x, x, bounds=(1, sp.E))
        self.assertTrue(square.verified)
        self.assertTrue(sine.verified)
        self.assertTrue(reciprocal.verified)
        self.assertEqual(sp.simplify(square.result - 9), 0)
        self.assertEqual(sp.simplify(sine.result - 2), 0)
        self.assertEqual(sp.simplify(reciprocal.result - 1), 0)
        self.assertIn("Apply the fundamental theorem", str(square))

    def test_dont_know_path(self) -> None:
        x = sp.Symbol("x")
        s = integrate_steps(sp.sqrt(x**4 + 1), x)
        self.assertTrue(s.verified)
        self.assertIn("No hand recipe found", str(s))


class SolveStepsTests(unittest.TestCase):
    def test_linear_equations(self) -> None:
        self.assertEqual(solve_steps("2x+3=11").result, [sp.Integer(4)])
        self.assertEqual(solve_steps("5-3x=17").result, [sp.Integer(-4)])
        self.assertEqual(solve_steps("x/2+1=4").result, [sp.Integer(6)])

    def test_quadratic_factoring_with_human_checks(self) -> None:
        x = sp.Symbol("x")
        s = solve_steps(sp.Eq(x**2 - 5 * x + 6, 0), x)
        self.assertTrue(s.verified)
        self.assertEqual(set(s.result), {sp.Integer(2), sp.Integer(3)})
        plain = str(s)
        self.assertIn("Check each solution", plain)
        self.assertIn("✓", plain)
        self.assertNotIn("[True", plain)
        self.assertIn(r"\checkmark", s._repr_markdown_())

    def test_quadratic_complex_no_duplicate_root_steps(self) -> None:
        s = solve_steps("x^2 + x + 1 = 0")
        self.assertTrue(s.verified)
        plain = str(s)
        self.assertEqual(plain.count("Use the quadratic formula"), 1)

    def test_linear_inequality_balance_with_sign_flip(self) -> None:
        s = solve_steps("5-3x>17")
        self.assertTrue(s.verified)
        plain = str(s)
        self.assertIn("flips the inequality sign", plain)
        self.assertIn("x < -4", plain)


class AlgebraAndArithmeticStepTests(unittest.TestCase):
    def test_factor_expand(self) -> None:
        fac = factor_steps("x^2 - 9")
        expd = expand_steps("(x+2)*(x+3)")
        self.assertTrue(fac.verified)
        self.assertTrue(expd.verified)
        self.assertEqual(sp.expand(fac.result), sp.expand(sp.sympify("x**2-9")))
        self.assertEqual(sp.expand(expd.result), sp.expand(sp.sympify("(x+2)*(x+3)")))

    def test_fraction_steps_rendering_cases(self) -> None:
        add = frac_steps("1/2 + 3/4")
        sub = frac_steps("7/12 - 1/4")
        mul = frac_steps("2/3 * 3/8")
        div = frac_steps("(3/4) / (9/16)")
        multi = frac_steps("1/2 + 1/3 + 1/6")
        simplify = frac_steps("5/10")
        already = frac_steps(sp.Rational(5, 4))

        self.assertEqual(add.result, sp.Rational(5, 4))
        self.assertEqual(sub.result, sp.Rational(1, 3))
        self.assertEqual(mul.result, sp.Rational(1, 4))
        self.assertEqual(div.result, sp.Rational(4, 3))
        self.assertEqual(multi.result, sp.Integer(1))
        self.assertEqual(simplify.result, sp.Rational(1, 2))
        self.assertEqual(already.result, sp.Rational(5, 4))

        add_plain = str(add)
        self.assertIn("Find a common denominator", add_plain)
        self.assertIn("Rewrite each fraction with that denominator", add_plain)
        self.assertIn("Add or subtract the numerators", add_plain)
        self.assertIn("5/4", add_plain)
        self.assertIn(r"\frac{1}{4}", add_plain)

        self.assertIn("Cancel common factors before multiplying", str(mul))
        self.assertIn("Turn division by a fraction into multiply by its reciprocal", str(div))
        self.assertIn("Simplify by gcd", str(simplify))
        self.assertIn("already evaluated", str(already))

    def test_prime_factors_display_exponents(self) -> None:
        s = prime_factors(360)
        self.assertTrue(s.verified)
        self.assertEqual(sp.expand(s.result), 360)
        plain = str(s)
        self.assertIn("Write with exponents", plain)
        self.assertIn("2", plain)
        self.assertIn("3", plain)
        self.assertIn("5", plain)

    def test_long_division(self) -> None:
        s = long_division(7835, 12)
        self.assertTrue(s.verified)
        self.assertEqual(s.result, (652, 11))

    def test_gcd_lcm_prime_power_display(self) -> None:
        s = gcd_lcm_steps(84, 30)
        self.assertTrue(s.verified)
        self.assertEqual(s.result, (6, 420))
        plain = str(s)
        self.assertIn("Prime factors of first number", plain)
        self.assertIn("Prime factors of second number", plain)
        self.assertIn("Build the least common multiple", plain)


class RenderingTests(unittest.TestCase):
    @staticmethod
    def _outside_math(markdown: str) -> str:
        parts = markdown.split("$$")
        return "\n".join(parts[::2])

    def test_markdown_and_plain_for_key_examples(self) -> None:
        x = sp.Symbol("x")
        stories = [
            (diff_steps(sp.sin(x**2) * sp.exp(3 * x), x), [r"\frac{d}{d x}"]),
            (diff_steps((x**2 + 1) / (x - 3), x), [r"\frac{d}{d x}"]),
            (integrate_steps(x * sp.exp(x), x), [r"\int"]),
            (integrate_steps(2 * x * sp.cos(x**2), x), [r"\int"]),
            (integrate_steps(x**2, x, bounds=(0, 3)), [r"\int", r"0", r"3"]),
            (solve_steps("x^2-5x+6=0"), [r"\checkmark"]),
            (solve_steps("2x+3=11"), [r"\checkmark"]),
            (solve_steps("x^2+x+1=0"), [r"\checkmark"]),
            (frac_steps("1/2 + 3/4"), [r"\frac"]),
            (prime_factors(360), [r"2^{3}"]),
            (factor_steps(x**2 - 9), [r"x^{2}"]),
            (expand_steps((x + 2) * (x + 3)), [r"x^{2}"]),
        ]

        banned = ["**", "Symbol(", "Mul(", "Pow(", "exp("]

        for story, expected_fragments in stories:
            with self.subTest(result=story.result):
                markdown = story._repr_markdown_()
                plain = str(story)

                self.assertGreaterEqual(markdown.count("$$"), 2)
                self.assertEqual(markdown.count("$$") % 2, 0)

                outside = self._outside_math(markdown)
                for bad in banned:
                    self.assertNotIn(bad, outside)

                for fragment in expected_fragments:
                    self.assertIn(fragment, markdown)

                self.assertNotIn("**", plain)
                self.assertNotIn("*", plain)


if __name__ == "__main__":
    unittest.main()
