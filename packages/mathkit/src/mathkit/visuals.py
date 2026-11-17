"""Plot and interaction helpers that make maths ideas visible for learners."""

from __future__ import annotations

from typing import Any, Callable

import matplotlib.pyplot as plt
import numpy as np
import sympy as sp

from .check import _safe_parse

_STYLE = {
    "font.size": 13,
    "axes.titlesize": 14,
    "axes.labelsize": 13,
    "legend.fontsize": 11,
    "axes.facecolor": "#fcfcff",
    "grid.alpha": 0.35,
    "grid.linestyle": "--",
    "axes.edgecolor": "#333333",
}


def _figure() -> tuple[plt.Figure, plt.Axes]:
    with plt.rc_context(_STYLE):
        fig, ax = plt.subplots(figsize=(8, 5), dpi=120)
    return fig, ax


def _close_and_return(fig: plt.Figure) -> plt.Figure:
    plt.close(fig)
    return fig


def _to_expr(value: Any) -> sp.Basic:
    if isinstance(value, str):
        parsed = _safe_parse(value)
        if isinstance(parsed, sp.Equality):
            raise ValueError("Please give an expression, not an equation, for plotting.")
        return sp.sympify(parsed)
    return sp.sympify(value)


def _infer_symbol(expr: sp.Basic, x: Any | None) -> sp.Symbol:
    if x is not None:
        return sp.Symbol(str(x)) if not isinstance(x, sp.Symbol) else x
    symbols = sorted(expr.free_symbols, key=lambda s: s.name)
    if len(symbols) == 1:
        return symbols[0]
    return sp.Symbol("x")


def _to_callable(obj: Any, var: sp.Symbol) -> Callable[[np.ndarray], np.ndarray]:
    if callable(obj):
        return lambda xs: np.asarray([obj(float(xv)) for xv in xs], dtype=float)
    expr = _to_expr(obj)
    fn = sp.lambdify(var, expr, modules=["numpy"])

    def wrapped(xs: np.ndarray) -> np.ndarray:
        try:
            values = np.asarray(fn(xs), dtype=np.complex128)
        except Exception:
            values = np.asarray([fn(float(xv)) for xv in xs], dtype=np.complex128)
        if values.shape == ():
            values = np.full(xs.shape, complex(values), dtype=np.complex128)
        values = np.real_if_close(values, tol=1000)
        values = values.astype(float, copy=False)
        values[~np.isfinite(values)] = np.nan
        if values.size > 1:
            jumps = np.abs(np.diff(values))
            scale = np.nanmedian(jumps) if np.isfinite(np.nanmedian(jumps)) else 1.0
            if scale <= 0:
                scale = 1.0
            values[1:][jumps > 35 * scale] = np.nan
        values[np.abs(values) > 1e5] = np.nan
        return values

    return wrapped


def _to_rational_pair(item: Any) -> tuple[int, int]:
    if isinstance(item, tuple) and len(item) == 2:
        a, b = item
        rat = sp.Rational(a, b)
    else:
        rat = sp.Rational(item)
    return int(rat.p), int(rat.q)


def _load_widgets() -> tuple[Any, Any, Any]:
    try:
        import ipywidgets as widgets
        from IPython import get_ipython
        from IPython.display import display
    except Exception:
        return None, None, None
    shell = get_ipython()
    if shell is None or shell.__class__.__name__ not in {"ZMQInteractiveShell", "Shell"}:
        return None, None, None
    return widgets, shell, display


def plot(*exprs: Any, x: tuple[float, float] = (-10, 10), y: tuple[float, float] | None = None, labels: list[str] | None = None, points: list[tuple[float, float]] | None = None) -> plt.Figure:
    """Plot one or more expressions/callables with axes through the origin."""

    if not exprs:
        raise ValueError("Please give at least one expression to plot.")
    lo_raw, hi_raw = x
    lo, hi = float(sp.N(lo_raw)), float(sp.N(hi_raw))
    xs = np.linspace(lo, hi, 900)
    fig, ax = _figure()
    var = sp.Symbol("x")
    for idx, expr in enumerate(exprs):
        fn = _to_callable(expr, var)
        ys = fn(xs)
        label = labels[idx] if labels and idx < len(labels) else _default_label(expr, idx)
        ax.plot(xs, ys, linewidth=2.0, label=label)
    if points:
        px, py = zip(*points)
        ax.scatter(px, py, s=45, color="#d62728", zorder=4, label="points")
    ax.axhline(0, color="#444444", linewidth=1)
    ax.axvline(0, color="#444444", linewidth=1)
    ax.grid(True)
    ax.set_xlim(lo, hi)
    if y is not None:
        ax.set_ylim(*y)
    ax.legend(loc="best")
    return _close_and_return(fig)


def _default_label(expr: Any, idx: int) -> str:
    if callable(expr) and not isinstance(expr, sp.Basic):
        return getattr(expr, "__name__", f"f{idx + 1}")
    try:
        parsed = _to_expr(expr)
        return f"$y = {sp.latex(parsed)}$"
    except Exception:
        return f"f{idx + 1}(x)"


def fraction_bar(a: Any, b: Any | None = None, *, width: float = 8) -> plt.Figure:
    """Draw one fraction as a shaded bar split into equal parts."""

    if b is None:
        num, den = _to_rational_pair(a)
    else:
        num, den = _to_rational_pair((a, b))
    fig, ax = _figure()
    ax.set_xlim(0, den)
    ax.set_ylim(0, 1)
    for i in range(den):
        color = "#4c78a8" if i < num else "#ffffff"
        ax.add_patch(plt.Rectangle((i, 0.15), 1, 0.7, facecolor=color, edgecolor="#222222", linewidth=1.2))
    ax.set_title(f"{num}/{den}")
    ax.axis("off")
    return _close_and_return(fig)


def compare_fractions(*fracs: Any) -> plt.Figure:
    """Draw stacked fraction bars to compare several fractions."""

    if not fracs:
        raise ValueError("Give at least one fraction to compare.")
    pairs = [_to_rational_pair(frac) for frac in fracs]
    fig, ax = _figure()
    for row, (num, den) in enumerate(pairs):
        y0 = len(pairs) - row - 1
        part = 1 / den
        for i in range(den):
            color = "#59a14f" if i < num else "#ffffff"
            ax.add_patch(plt.Rectangle((i * part, y0), part, 0.8, facecolor=color, edgecolor="#222222", linewidth=0.9))
        ax.text(1.04, y0 + 0.4, f"{num}/{den}", va="center")
    ax.set_xlim(0, 1.25)
    ax.set_ylim(-0.2, len(pairs) + 0.6)
    ax.set_title("Compare fractions: every bar is one whole")
    ax.axis("off")
    return _close_and_return(fig)


def numberline(*points: Any, lo: float | None = None, hi: float | None = None) -> plt.Figure:
    """Draw points and simple intervals on a number line."""

    parsed_points: list[float] = []
    intervals: list[tuple[float, float]] = []
    for item in points:
        if isinstance(item, tuple) and len(item) == 2:
            a, b = float(sp.N(item[0])), float(sp.N(item[1]))
            intervals.append((a, b))
            parsed_points.extend([a, b])
        else:
            val = float(sp.N(item))
            parsed_points.append(val)
    if not parsed_points:
        parsed_points = [0.0]
    lo = min(parsed_points) - 1 if lo is None else lo
    hi = max(parsed_points) + 1 if hi is None else hi
    fig, ax = _figure()
    ax.hlines(0, lo, hi, color="#333333", linewidth=2)
    for val in [p for p in points if not (isinstance(p, tuple) and len(p) == 2)]:
        x = float(sp.N(val))
        ax.plot([x], [0], "o", color="#d62728")
        ax.text(x, 0.07, sp.sstr(sp.nsimplify(val)), ha="center")
    for a, b in intervals:
        left, right = sorted((a, b))
        ax.hlines(0, left, right, color="#4c78a8", linewidth=6, alpha=0.45)
        ax.plot([left, right], [0, 0], "o", color="#4c78a8")
    ax.set_xlim(lo, hi)
    ax.set_ylim(-0.2, 0.4)
    ax.set_yticks([])
    ax.grid(True, axis="x")
    ax.set_title("Number line")
    return _close_and_return(fig)


def tangent(f: Any, at: Any, x: Any | None = None, *, window: float = 2) -> plt.Figure:
    """Plot a curve with its tangent line at one point."""

    expr = _to_expr(f)
    var = _infer_symbol(expr, x)
    at_value = sp.sympify(at)
    slope = sp.simplify(sp.diff(expr, var).subs(var, at_value))
    y0 = sp.simplify(expr.subs(var, at_value))
    tangent_expr = y0 + slope * (var - at_value)
    lo = float(sp.N(at_value - window))
    hi = float(sp.N(at_value + window))
    xs = np.linspace(lo, hi, 700)
    f_fn = sp.lambdify(var, expr, modules=["numpy"])
    t_fn = sp.lambdify(var, tangent_expr, modules=["numpy"])
    fig, ax = _figure()
    curve_y = np.asarray(f_fn(xs), dtype=float)
    tan_y = np.asarray(t_fn(xs), dtype=float)
    if curve_y.shape == ():
        curve_y = np.full(xs.shape, float(curve_y), dtype=float)
    if tan_y.shape == ():
        tan_y = np.full(xs.shape, float(tan_y), dtype=float)
    ax.plot(xs, curve_y, label="curve", linewidth=2.2)
    ax.plot(xs, tan_y, label="tangent", linewidth=2.0, linestyle="--")
    ax.scatter([float(sp.N(at_value))], [float(sp.N(y0))], s=55, color="#d62728", zorder=5)
    ax.axhline(0, color="#444444", linewidth=1)
    ax.axvline(0, color="#444444", linewidth=1)
    ax.grid(True)
    ax.legend(loc="best")
    ax.set_title(f"Tangent slope = {sp.sstr(sp.nsimplify(slope))}")
    return _close_and_return(fig)


def explore_tangent(f: Any, x_range: tuple[float, float]) -> Any:
    """Interactive tangent explorer with a slider, or a safe static fallback."""

    lo, hi = map(float, x_range)
    mid = (lo + hi) / 2
    widgets, _, display = _load_widgets()
    if widgets is None:
        return tangent(f, mid)
    slider = widgets.FloatSlider(value=mid, min=lo, max=hi, step=max((hi - lo) / 200, 0.01), description="x")

    def _draw(at: float) -> None:
        display(tangent(f, at))

    widgets.interact(_draw, at=slider)
    return None


def riemann(f: Any, a: Any, b: Any, n: int = 10, kind: str = "left", x: Any | None = None) -> plt.Figure:
    """Visualise a Riemann sum and compare with the exact integral."""

    expr = _to_expr(f)
    var = _infer_symbol(expr, x)
    a_val = float(sp.N(a))
    b_val = float(sp.N(b))
    if n <= 0:
        raise ValueError("n must be a positive integer.")
    xs = np.linspace(a_val, b_val, 800)
    f_fn = sp.lambdify(var, expr, modules=["numpy"])
    ys = np.asarray(f_fn(xs), dtype=float)
    fig, ax = _figure()
    ax.plot(xs, ys, linewidth=2.2, label="f(x)")
    width = (b_val - a_val) / n
    grid = np.linspace(a_val, b_val, n + 1)
    approx = 0.0
    kind = kind.lower()
    if kind not in {"left", "right", "mid", "trap"}:
        raise ValueError("kind must be 'left', 'right', 'mid', or 'trap'.")
    for i in range(n):
        x0, x1 = grid[i], grid[i + 1]
        if kind == "left":
            sample = x0
            h = float(sp.N(expr.subs(var, sample)))
            approx += h * width
            ax.add_patch(plt.Rectangle((x0, 0), width, h, alpha=0.25, facecolor="#4c78a8", edgecolor="#1f3d7a"))
        elif kind == "right":
            sample = x1
            h = float(sp.N(expr.subs(var, sample)))
            approx += h * width
            ax.add_patch(plt.Rectangle((x0, 0), width, h, alpha=0.25, facecolor="#4c78a8", edgecolor="#1f3d7a"))
        elif kind == "mid":
            sample = 0.5 * (x0 + x1)
            h = float(sp.N(expr.subs(var, sample)))
            approx += h * width
            ax.add_patch(plt.Rectangle((x0, 0), width, h, alpha=0.25, facecolor="#4c78a8", edgecolor="#1f3d7a"))
        else:
            h0 = float(sp.N(expr.subs(var, x0)))
            h1 = float(sp.N(expr.subs(var, x1)))
            approx += 0.5 * (h0 + h1) * width
            ax.fill([x0, x0, x1, x1], [0, h0, h1, 0], alpha=0.22, facecolor="#4c78a8", edgecolor="#1f3d7a")
    exact = sp.integrate(expr, (var, a, b))
    ax.axhline(0, color="#444444", linewidth=1)
    ax.axvline(0, color="#444444", linewidth=1)
    ax.grid(True)
    ax.set_title(f"{kind} sum ≈ {approx:.6g}, exact = {sp.sstr(sp.simplify(exact))}")
    ax.legend(loc="best")
    return _close_and_return(fig)


def explore_riemann(f: Any, a: Any, b: Any) -> Any:
    """Interactive Riemann explorer, or a static fallback if widgets are missing."""

    widgets, _, display = _load_widgets()
    if widgets is None:
        return riemann(f, a, b, n=10, kind="left")
    n_slider = widgets.IntSlider(value=10, min=2, max=80, step=1, description="n")
    kind_dropdown = widgets.Dropdown(options=["left", "right", "mid", "trap"], value="left", description="kind")

    def _draw(n: int, kind: str) -> None:
        display(riemann(f, a, b, n=n, kind=kind))

    widgets.interact(_draw, n=n_slider, kind=kind_dropdown)
    return None


def _angle_to_radians(angle: Any | None) -> sp.Basic:
    if angle is None:
        return sp.pi / 6
    val = sp.sympify(angle)
    if val.free_symbols:
        return val
    numeric = float(sp.N(val))
    if abs(numeric) > 2 * np.pi + 1e-9:
        return sp.pi * val / 180
    return val


def unit_circle(angle: Any | None = None) -> plt.Figure:
    """Draw the unit circle with one highlighted angle and its projections."""

    theta = _angle_to_radians(angle)
    theta_f = float(sp.N(theta))
    x = np.cos(theta_f)
    y = np.sin(theta_f)
    exact_cos = sp.simplify(sp.cos(theta))
    exact_sin = sp.simplify(sp.sin(theta))
    fig, ax = _figure()
    t = np.linspace(0, 2 * np.pi, 600)
    ax.plot(np.cos(t), np.sin(t), color="#2f4b7c", linewidth=2.0)
    ax.plot([0, x], [0, y], color="#d62728", linewidth=2.2)
    ax.plot([x, x], [0, y], "--", color="#666666")
    ax.plot([0, x], [y, y], "--", color="#666666")
    ax.scatter([x], [y], color="#d62728", zorder=5)
    ax.set_xlabel(f"$(\\cos,\\ \\sin) = ({sp.latex(exact_cos)},\\ {sp.latex(exact_sin)})$", fontsize=14)
    ax.axhline(0, color="#444444", linewidth=1)
    ax.axvline(0, color="#444444", linewidth=1)
    ax.set_aspect("equal", adjustable="box")
    ax.set_xlim(-1.2, 1.2)
    ax.set_ylim(-1.2, 1.2)
    ax.grid(True)
    degrees = float(sp.N(theta * 180 / sp.pi))
    ax.set_title(f"Unit circle: {degrees:g}° = ${sp.latex(sp.nsimplify(theta / sp.pi) * sp.pi)}$ rad")
    return _close_and_return(fig)


def explore_unit_circle() -> Any:
    """Interactive unit-circle angle slider, or a static fallback."""

    widgets, _, display = _load_widgets()
    if widgets is None:
        return unit_circle(sp.pi / 4)
    slider = widgets.FloatSlider(value=45.0, min=0.0, max=360.0, step=1.0, description="degrees")

    def _draw(degrees: float) -> None:
        display(unit_circle(degrees))

    widgets.interact(_draw, degrees=slider)
    return None


def explore(fn: Callable[..., Any], **ranges: tuple[float, float] | tuple[float, float, float]) -> Any:
    """Tiny generic wrapper around ipywidgets.interact with a static fallback."""

    if not callable(fn):
        raise TypeError("explore expects a callable function.")
    widgets, _, _ = _load_widgets()
    if widgets is None:
        kwargs = {}
        for name, spec in ranges.items():
            if len(spec) not in {2, 3}:
                raise ValueError("Each range must be (lo, hi) or (lo, hi, step).")
            lo, hi = float(spec[0]), float(spec[1])
            kwargs[name] = (lo + hi) / 2
        return fn(**kwargs)
    controls: dict[str, Any] = {}
    for name, spec in ranges.items():
        if len(spec) not in {2, 3}:
            raise ValueError("Each range must be (lo, hi) or (lo, hi, step).")
        lo, hi = float(spec[0]), float(spec[1])
        step = float(spec[2]) if len(spec) == 3 else max((hi - lo) / 100, 0.01)
        controls[name] = widgets.FloatSlider(value=(lo + hi) / 2, min=lo, max=hi, step=step, description=name)
    widgets.interact(fn, **controls)
    return None
