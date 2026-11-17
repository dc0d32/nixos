"""Display helpers so worked steps look clear in terminals and notebooks."""

from __future__ import annotations

from dataclasses import dataclass
from shutil import get_terminal_size
from textwrap import fill
from typing import Any, Iterable, Iterator, Sequence

import sympy as sp
from sympy.core.relational import Relational
from sympy.matrices.matrixbase import MatrixBase


@dataclass(slots=True)
class Step:
    """One human-readable maths step."""

    title: str
    math: Any | None = None
    why: str | None = None
    maths: Sequence[Any] | None = None


def _is_fragment_sequence(obj: Any) -> bool:
    return isinstance(obj, (list, tuple))


def _iter_math_fragments(step: Step) -> list[Any]:
    fragments: list[Any] = []
    if step.math is not None:
        if _is_fragment_sequence(step.math):
            fragments.extend(step.math)
        else:
            fragments.append(step.math)
    if step.maths:
        fragments.extend(step.maths)
    return fragments


def _latex_math(obj: Any) -> str:
    if obj is None:
        return ""
    if isinstance(obj, str):
        return obj.replace("✓", r"\checkmark").replace("✗", r"\times")
    if isinstance(obj, bool):
        return r"\text{True}" if obj else r"\text{False}"
    try:
        return sp.latex(obj)
    except Exception:
        return str(obj)


def _needs_parentheses(expr: sp.Basic) -> bool:
    return isinstance(expr, (sp.Add, Relational))


def _implicit_mul(left: sp.Basic, right: sp.Basic) -> bool:
    if left.is_Number and (right.is_Symbol or right == sp.E or right == sp.pi):
        return True
    if left.is_Number and isinstance(right, sp.Pow) and right.base.is_Symbol and right.exp.is_Integer:
        return True
    if (left.is_Symbol or left == sp.E or left == sp.pi) and (right.is_Symbol or right == sp.E or right == sp.pi):
        return True
    return False


def _plain_expr(expr: sp.Basic) -> str:
    if isinstance(expr, sp.UnevaluatedExpr):
        return _plain_expr(expr.args[0])

    if isinstance(expr, MatrixBase):
        return sp.pretty(expr, use_unicode=True)

    if isinstance(expr, sp.Equality):
        return f"{_plain_expr(expr.lhs)} = {_plain_expr(expr.rhs)}"

    if isinstance(expr, Relational):
        return f"{_plain_expr(expr.lhs)} {expr.rel_op} {_plain_expr(expr.rhs)}"

    if isinstance(expr, sp.Derivative):
        vars_text = ", ".join(_plain_expr(v) for v in expr.variables)
        return f"d/d{vars_text}({_plain_expr(expr.expr)})"

    if isinstance(expr, sp.Integral):
        integrand = _plain_expr(expr.function)
        if len(expr.limits) == 1:
            lim = expr.limits[0]
            if len(lim) == 1:
                return f"∫ {_plain_expr(expr.function)} d{_plain_expr(lim[0])}"
            var, lo, hi = lim
            return f"∫[{_plain_expr(lo)}, {_plain_expr(hi)}] {integrand} d{_plain_expr(var)}"
        return f"∫ {integrand}"

    if expr == sp.E:
        return "e"
    if expr == sp.pi:
        return "π"
    if expr == sp.oo:
        return "∞"
    if expr == -sp.oo:
        return "-∞"
    if expr == sp.zoo:
        return "zoo"
    if expr == sp.nan:
        return "nan"

    if isinstance(expr, sp.Symbol):
        return expr.name

    if isinstance(expr, sp.Integer):
        return str(int(expr))

    if isinstance(expr, sp.Rational) and expr.q != 1:
        sign = "-" if expr.p < 0 else ""
        return f"{sign}{abs(int(expr.p))}/{int(expr.q)}"

    if isinstance(expr, sp.Float):
        return str(expr)

    if isinstance(expr, sp.Add):
        pieces: list[str] = []
        for idx, term in enumerate(expr.as_ordered_terms()):
            negative = bool(term.could_extract_minus_sign())
            shown = -term if negative else term
            text = _plain_expr(shown)
            if idx == 0:
                pieces.append(f"-{text}" if negative else text)
            else:
                pieces.append((" - " if negative else " + ") + text)
        return "".join(pieces)

    if isinstance(expr, sp.Mul):
        if expr.could_extract_minus_sign():
            return f"-{_plain_expr(-expr)}"
        num, den = sp.fraction(expr)
        if den != 1:
            top = _plain_expr(num)
            bot = _plain_expr(den)
            return f"{top}/{bot}"
        factors = list(sp.Mul.make_args(expr))
        text = ""
        for idx, factor in enumerate(factors):
            part = _plain_expr(factor)
            if idx == 0:
                text = part
                continue
            prev = factors[idx - 1]
            text += ("" if _implicit_mul(prev, factor) else "·") + part
        return text

    if isinstance(expr, sp.Pow):
        base, exponent = expr.as_base_exp()
        if exponent == sp.Rational(1, 2):
            return f"√({_plain_expr(base)})"
        if base == sp.E:
            return f"e^({_plain_expr(exponent)})"
        base_text = _plain_expr(base)
        exp_text = _plain_expr(exponent)
        if _needs_parentheses(base):
            base_text = f"({base_text})"
        if _needs_parentheses(exponent) or isinstance(exponent, sp.Rational) and exponent.q != 1:
            exp_text = f"({exp_text})"
        return f"{base_text}^{exp_text}"

    if isinstance(expr, sp.Function):
        if expr.func == sp.sqrt and len(expr.args) == 1:
            return f"√({_plain_expr(expr.args[0])})"
        if expr.func == sp.exp and len(expr.args) == 1:
            return f"e^({_plain_expr(expr.args[0])})"
        name_map = {sp.log: "ln"}
        name = name_map.get(expr.func, expr.func.__name__)
        return f"{name}({', '.join(_plain_expr(arg) for arg in expr.args)})"

    return str(expr)


def _plain(obj: Any) -> str:
    if obj is None:
        return ""
    if isinstance(obj, str):
        return (
            obj.replace(r"\checkmark", "✓")
            .replace(r"\times", "✗")
            .replace("**", "^")
            .replace("*", "·")
        )
    if isinstance(obj, bool):
        return "True" if obj else "False"
    if isinstance(obj, (list, tuple)):
        opener, closer = ("[", "]") if isinstance(obj, list) else ("(", ")")
        return opener + ", ".join(_plain(item) for item in obj) + closer
    if isinstance(obj, (set, frozenset)):
        return "{" + ", ".join(sorted(_plain(item) for item in obj)) + "}"
    try:
        expr = sp.sympify(obj)
    except Exception:
        return str(obj).replace("**", "^").replace("*", "·")
    return _plain_expr(expr)


class Steps(Sequence[Step]):
    """A list-like container of maths steps plus a final checked result."""

    def __init__(
        self,
        steps: Iterable[Step] | None = None,
        *,
        result: Any | None = None,
        verified: bool = False,
    ) -> None:
        self._steps = list(steps or [])
        self.result = result
        self.verified = verified

    def add(
        self,
        title: str,
        math: Any | None = None,
        why: str | None = None,
        *,
        maths: Sequence[Any] | None = None,
    ) -> None:
        self._steps.append(Step(title=title, math=math, why=why, maths=maths))

    def __len__(self) -> int:
        return len(self._steps)

    def __iter__(self) -> Iterator[Step]:
        return iter(self._steps)

    def __getitem__(self, item: int) -> Step:
        return self._steps[item]

    @property
    def latex(self) -> str:
        if self.result is None:
            return ""
        return _latex_math(self.result)

    def __str__(self) -> str:
        width = max(70, get_terminal_size((88, 24)).columns - 2)
        lines: list[str] = []
        for index, step in enumerate(self._steps, start=1):
            lines.append(fill(f"{index}. {step.title}", width=width, break_long_words=False))
            for fragment in _iter_math_fragments(step):
                math_text = _plain(fragment)
                for math_line in math_text.splitlines() or [""]:
                    lines.append(fill(f"   {math_line}", width=width, break_long_words=False))
            if step.why:
                lines.append(fill(f"   why: {step.why}", width=width, break_long_words=False))
        if self.result is not None:
            lines.append("Result:")
            for result_line in _plain(self.result).splitlines() or [""]:
                lines.append(fill(f"  {result_line}", width=width, break_long_words=False))
        lines.append(f"Verified: {'yes' if self.verified else 'no'}")
        return "\n".join(lines).strip()

    def _repr_markdown_(self) -> str:
        # Blank lines between every block: Markdown otherwise folds a step title
        # into the previous paragraph and the numbering is lost.
        blocks: list[str] = []
        for index, step in enumerate(self._steps, start=1):
            blocks.append(f"__{index}. {step.title}__")
            for fragment in _iter_math_fragments(step):
                blocks.append(f"$$\n{_latex_math(fragment)}\n$$")
            if step.why:
                blocks.append(f"*{step.why}*")
        if self.result is not None:
            blocks.append("__Result__")
            blocks.append(f"$$\n{_latex_math(self.result)}\n$$")
        blocks.append(f"Verified: {'yes' if self.verified else 'no'}")
        return "\n\n".join(blocks)
