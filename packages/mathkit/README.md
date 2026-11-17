# mathkit

mathkit is a small helper library for learning maths with Python + SymPy.
It adds three things:

1. Friendly answer checking
2. Step-by-step “show the working”
3. Clear plots and visual tools

All plot functions return a **matplotlib Figure** (already closed internally), so in notebooks you can just put the returned figure on the last line to display it once.

## Public API

| Name | What it does | One-line example |
|---|---|---|
| `check(mine, answer, *, tol=1e-9)` | Checks if two answers match, with kind feedback | `check("2x+3", "3+2*x")` |
| `same(a, b)` | True/False version of `check` logic | `same("x^2", "x*x")` |
| `diff_steps(f, x=None)` | Derivative with labelled rule-first steps | `diff_steps("sin(x^2)*exp(3*x)")` |
| `integrate_steps(f, x=None, bounds=None)` | Integral steps (parts/substitution/rules + check) | `integrate_steps("2*x*cos(x^2)")` |
| `solve_steps(eq, x=None)` | Equation steps + simple linear inequality balance steps | `solve_steps("2x+3=11")` |
| `factor_steps(expr)` | Factoring steps | `factor_steps("x^2-9")` |
| `expand_steps(expr)` | Expanding steps | `expand_steps("(x+2)*(x+3)")` |
| `frac_steps(expr)` | Fraction arithmetic (common denominators, cancellation, mixed numbers) | `frac_steps("1/2 + 3/4")` |
| `prime_factors(n)` | Prime factorization steps | `prime_factors(360)` |
| `long_division(a, b)` | Digit-by-digit long division | `long_division(7835, 12)` |
| `gcd_lcm_steps(a, b)` | GCD and LCM steps | `gcd_lcm_steps(84, 30)` |
| `plot(*exprs, ...)` | Plot one or more functions | `plot("sin(x)", "cos(x)")` |
| `fraction_bar(a, b)` | Draw a fraction as a bar | `fraction_bar(3, 5)` |
| `compare_fractions(*fracs)` | Compare fractions with stacked bars | `compare_fractions((1,2), (2,3), (3,4))` |
| `numberline(*points, lo=None, hi=None)` | Number line with points/intervals | `numberline(-2, sp.Rational(1,2), (1,3))` |
| `tangent(f, at, x=None, *, window=2)` | Plot a curve and tangent at a point | `tangent("x^2", at=2)` |
| `explore_tangent(f, x_range)` | Slider version of tangent plot | `explore_tangent("x^3", (-3,3))` |
| `riemann(f, a, b, n=10, kind='left')` | Riemann sum picture + exact integral | `riemann("x^2", 0, 3, n=8, kind="mid")` |
| `explore_riemann(f, a, b)` | Slider version of Riemann sums | `explore_riemann("sin(x)", 0, sp.pi)` |
| `unit_circle(angle=None)` | Unit circle with sin/cos projection | `unit_circle(sp.pi/6)` |
| `explore_unit_circle()` | Slider version of unit circle | `explore_unit_circle()` |
| `explore(fn, **ranges)` | Tiny generic interact wrapper | `explore(lambda a,b: a*b, a=(0,10), b=(0,10))` |

## Rendering in notebooks and terminals

- `Steps` now renders in Jupyter/VS Code through `_repr_markdown_` (not `_repr_latex_`).
- Each maths line is shown in its own `$$ ... $$` block so long expressions wrap cleanly.
- Explanations (`title`, `why`) stay plain-English; maths is rendered from SymPy LaTeX.
- `steps.latex` still returns the LaTeX for the final result when you need it directly.
- `str(steps)` is plain-text friendly for terminals/Thonny (`^`, `·`, `e^(...)`, `√(...)`).

## Notes

- Python 3.11+.
- Required deps: `sympy`, `numpy`, `matplotlib`.
- Optional widgets: `ipywidgets` (falls back to static output if missing).
