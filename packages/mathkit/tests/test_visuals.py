"""Tests for plotting helpers under a headless matplotlib backend."""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import matplotlib.figure
import sympy as sp

from mathkit import (
    compare_fractions,
    explore,
    explore_riemann,
    explore_tangent,
    explore_unit_circle,
    fraction_bar,
    numberline,
    plot,
    riemann,
    tangent,
    unit_circle,
)


class VisualTests(unittest.TestCase):
    def assert_figure(self, fig: object) -> None:
        self.assertIsInstance(fig, matplotlib.figure.Figure)

    def test_plot(self) -> None:
        fig = plot("sin(x)", "cos(x)", x=(-sp.pi, sp.pi))
        self.assert_figure(fig)

    def test_fraction_bars(self) -> None:
        self.assert_figure(fraction_bar(3, 5))
        self.assert_figure(compare_fractions((1, 2), (2, 3), sp.Rational(3, 4)))

    def test_numberline(self) -> None:
        fig = numberline(-2, sp.Rational(1, 2), (1, 3))
        self.assert_figure(fig)

    def test_tangent(self) -> None:
        fig = tangent("x^2", at=2)
        self.assert_figure(fig)

    def test_riemann(self) -> None:
        fig = riemann("x^2", 0, 3, n=12, kind="mid")
        self.assert_figure(fig)

    def test_unit_circle(self) -> None:
        fig = unit_circle(sp.pi / 6)
        self.assert_figure(fig)

    def test_explore_fallbacks_without_widgets(self) -> None:
        with patch("mathkit.visuals._load_widgets", return_value=(None, None, None)):
            self.assert_figure(explore_tangent("x^3", (-2, 2)))
            self.assert_figure(explore_riemann("x^2", 0, 1))
            self.assert_figure(explore_unit_circle())

            called = {}

            def fn(a: float, b: float) -> float:
                called["value"] = a * b
                return called["value"]

            value = explore(fn, a=(0, 10), b=(2, 6))
            self.assertEqual(value, 20.0)

    def test_every_visual_renders_to_nonempty_png(self) -> None:
        with patch("mathkit.visuals._load_widgets", return_value=(None, None, None)):
            figures = {
                "plot": plot("sin(x)", "cos(x)", x=(-sp.pi, sp.pi)),
                "fraction_bar": fraction_bar(3, 4),
                "compare_fractions": compare_fractions((1, 2), (2, 3), sp.Rational(3, 4)),
                "numberline": numberline(-2, sp.Rational(1, 2), (1, 3)),
                "tangent": tangent("x^2", at=1),
                "riemann": riemann("x^2", 0, 2, n=8, kind="mid"),
                "unit_circle": unit_circle(30),
                "explore_tangent": explore_tangent("x^2", (-2, 2)),
                "explore_riemann": explore_riemann("x^2", 0, 2),
                "explore_unit_circle": explore_unit_circle(),
                "explore": explore(lambda a, b: plot("x", x=(a, b)), a=(-2, -1), b=(1, 2)),
            }
            with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parent) as tmpdir:
                for name, fig in figures.items():
                    self.assert_figure(fig)
                    out = Path(tmpdir) / f"{name}.png"
                    fig.savefig(out)
                    self.assertTrue(out.exists(), msg=f"{name} did not render a file")
                    self.assertGreater(out.stat().st_size, 0, msg=f"{name} rendered an empty file")


if __name__ == "__main__":
    unittest.main()
