"""Answer checking helpers that give kind feedback without leaking answers."""

from __future__ import annotations

from dataclasses import dataclass
from random import Random
from typing import Any

import sympy as sp
from sympy.matrices.matrixbase import MatrixBase
from sympy.parsing.sympy_parser import (
    convert_xor,
    implicit_multiplication_application,
    parse_expr,
    standard_transformations,
)

_TRANSFORMS = standard_transformations + (implicit_multiplication_application, convert_xor)
_POINTS = [
    sp.Integer(-3),
    sp.Integer(-2),
    sp.Integer(-1),
    sp.Rational(-1, 2),
    sp.Rational(1, 2),
    sp.Integer(1),
    sp.Integer(2),
    sp.Integer(3),
    sp.I,
    1 + sp.I,
    2 - sp.I,
]

_SAFE_LOCALS: dict[str, Any] = {
    name: sp.Symbol(name)
    for name in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"
}
_SAFE_LOCALS.update(
    {
        "pi": sp.pi,
        "e": sp.E,
        "E": sp.E,
        "I": sp.I,
        "sin": sp.sin,
        "cos": sp.cos,
        "tan": sp.tan,
        "asin": sp.asin,
        "acos": sp.acos,
        "atan": sp.atan,
        "sinh": sp.sinh,
        "cosh": sp.cosh,
        "tanh": sp.tanh,
        "exp": sp.exp,
        "sqrt": sp.sqrt,
        "log": sp.log,
        "ln": sp.log,
        "Abs": sp.Abs,
        "Rational": sp.Rational,
        "Matrix": sp.Matrix,
    }
)


@dataclass(slots=True)
class CheckResult:
    """Result object for answer checks with readable output."""

    ok: bool
    message: str
    hint: str = ""

    def __bool__(self) -> bool:
        return self.ok

    def __str__(self) -> str:
        if self.hint:
            return f"{self.message} Hint: {self.hint}"
        return self.message

    def _repr_markdown_(self) -> str:
        color = "#dff6dd" if self.ok else "#fff5d6"
        tone = "Correct!" if self.ok else "Not quite yet"
        hint = f"<br><em>Hint:</em> {self.hint}" if self.hint else ""
        return (
            f"<div style='padding:10px;border-radius:8px;background:{color};'>"
            f"<strong>{tone}</strong><br>{self.message}{hint}</div>"
        )

    def _repr_html_(self) -> str:
        color = "#dff6dd" if self.ok else "#fff5d6"
        border = "#2e7d32" if self.ok else "#a87800"
        hint = f"<div><em>Hint:</em> {self.hint}</div>" if self.hint else ""
        return (
            f"<div style='padding:10px;border-radius:8px;border:1px solid {border};"
            f"background:{color};'><strong>{self.message}</strong>{hint}</div>"
        )


def _safe_parse(text: str) -> sp.Basic:
    raw = text.strip()
    if not raw:
        raise ValueError("empty")
    if "=" in raw and all(op not in raw for op in ("<=", ">=", "<", ">")):
        left, right = raw.split("=", 1)
        if left.strip() and right.strip():
            lhs = parse_expr(left, transformations=_TRANSFORMS, local_dict=_SAFE_LOCALS, evaluate=True)
            rhs = parse_expr(right, transformations=_TRANSFORMS, local_dict=_SAFE_LOCALS, evaluate=True)
            return sp.Eq(lhs, rhs)
    return parse_expr(raw, transformations=_TRANSFORMS, local_dict=_SAFE_LOCALS, evaluate=True)


def _normalize(obj: Any) -> Any:
    if isinstance(obj, str):
        return _safe_parse(obj)
    if isinstance(obj, MatrixBase):
        return obj
    if isinstance(obj, sp.Equality):
        return obj
    if isinstance(obj, (list, tuple, set, frozenset)):
        return [_normalize(x) for x in obj]
    if isinstance(obj, (int, float, complex)):
        return sp.sympify(obj)
    if isinstance(obj, sp.Basic):
        return obj
    return sp.sympify(obj)


def _is_constant_nonzero(expr: sp.Basic) -> bool:
    return (not getattr(expr, "free_symbols", set())) and bool(expr.is_zero is False)


def _coerce_complex(value: Any) -> complex:
    return complex(sp.N(value, 30))


def _finite_complex(value: complex) -> bool:
    return (
        value.real == value.real
        and value.imag == value.imag
        and abs(value.real) != float("inf")
        and abs(value.imag) != float("inf")
    )


def _sample_pairs(a: sp.Basic, b: sp.Basic, *, tol: float) -> tuple[bool, dict[sp.Symbol, Any] | None, complex | None]:
    rng = Random(20261117)
    symbols = sorted((a.free_symbols | b.free_symbols), key=lambda s: s.name)
    if not symbols:
        av = _coerce_complex(a)
        bv = _coerce_complex(b)
        if not (_finite_complex(av) and _finite_complex(bv)):
            return False, None, None
        scale = max(1.0, abs(av), abs(bv))
        return abs(av - bv) <= tol * scale, None, av
    tried = 0
    valid = 0
    while tried < 90 and valid < 8:
        tried += 1
        subs = {s: rng.choice(_POINTS) for s in symbols}
        try:
            av = _coerce_complex(a.subs(subs))
            bv = _coerce_complex(b.subs(subs))
        except Exception:
            continue
        if not (_finite_complex(av) and _finite_complex(bv)):
            continue
        valid += 1
        scale = max(1.0, abs(av), abs(bv))
        if abs(av - bv) > tol * scale:
            return False, subs, av
    if valid == 0:
        return False, None, None
    return True, None, None


def _expr_same(a: sp.Basic, b: sp.Basic, *, tol: float) -> bool:
    try:
        if sp.simplify(a - b) == 0:
            return True
    except Exception:
        pass
    same_flag, _, _ = _sample_pairs(a, b, tol=tol)
    return same_flag


def _eq_same(a: sp.Equality, b: sp.Equality, *, tol: float) -> bool:
    ra = sp.simplify(a.lhs - a.rhs)
    rb = sp.simplify(b.lhs - b.rhs)
    if _expr_same(ra, rb, tol=tol):
        return True
    if _expr_same(ra, -rb, tol=tol):
        return True
    try:
        ratio = sp.simplify(ra / rb)
        if _is_constant_nonzero(ratio):
            return True
    except Exception:
        pass
    return False


def _matrix_same(a: MatrixBase, b: MatrixBase, *, tol: float) -> bool:
    if a.shape != b.shape:
        return False
    for row in range(a.rows):
        for col in range(a.cols):
            if not _same_obj(a[row, col], b[row, col], tol=tol):
                return False
    return True


def _collection_same(a: list[Any], b: list[Any], *, tol: float) -> bool:
    if len(a) != len(b):
        return False
    used = [False] * len(b)
    for left in a:
        matched = False
        for idx, right in enumerate(b):
            if used[idx]:
                continue
            if _same_obj(left, right, tol=tol):
                used[idx] = True
                matched = True
                break
        if not matched:
            return False
    return True


def _same_obj(a: Any, b: Any, *, tol: float) -> bool:
    if isinstance(a, MatrixBase) and isinstance(b, MatrixBase):
        return _matrix_same(a, b, tol=tol)
    if isinstance(a, sp.Equality) and isinstance(b, sp.Equality):
        return _eq_same(a, b, tol=tol)
    if isinstance(a, list) and isinstance(b, list):
        return _collection_same(a, b, tol=tol)
    try:
        sa = sp.sympify(a)
        sb = sp.sympify(b)
    except Exception:
        return False
    return _expr_same(sa, sb, tol=tol)


def _point_text(subs: dict[sp.Symbol, Any]) -> str:
    parts = [f"{symbol} = {sp.sstr(value)}" for symbol, value in sorted(subs.items(), key=lambda x: x[0].name)]
    return ", ".join(parts)


def _format_user_value(value: complex) -> str:
    if abs(value.imag) < 1e-12:
        rounded = round(value.real, 10)
        if abs(rounded - int(rounded)) < 1e-10:
            return str(int(rounded))
        return str(rounded)
    real = round(value.real, 6)
    imag = round(value.imag, 6)
    return f"{real} + {imag}i"


def _difference_hint(mine: sp.Basic, answer: sp.Basic) -> str:
    try:
        ratio = sp.simplify(mine / answer)
        if _is_constant_nonzero(ratio) and ratio != 1:
            if sp.simplify(ratio + 1) == 0:
                return "It looks like a sign error."
            return "It looks like the right shape but off by a constant factor."
    except Exception:
        pass
    try:
        delta = sp.simplify(mine - answer)
        if (not delta.free_symbols) and delta != 0:
            return "It looks like you are off by a constant amount."
    except Exception:
        pass
    return ""


def _kind_label(value: Any) -> str:
    if isinstance(value, MatrixBase):
        return "a table of numbers"
    if isinstance(value, sp.Equality):
        return "an equation"
    if isinstance(value, list):
        return "a list of answers"
    if isinstance(value, sp.Basic):
        return "a number or expression"
    return "a thing"


def _kind_mismatch_message(left: Any, right: Any) -> str | None:
    pairs = (
        (isinstance(left, MatrixBase), isinstance(right, MatrixBase)),
        (isinstance(left, sp.Equality), isinstance(right, sp.Equality)),
        (isinstance(left, list), isinstance(right, list)),
    )
    for lflag, rflag in pairs:
        if lflag != rflag:
            return (
                f"These two are different kinds of things ({_kind_label(left)} and {_kind_label(right)}), "
                "so they cannot match."
            )
    return None


def same(a: Any, b: Any) -> bool:
    """Return True if two maths objects are equivalent using check-like logic."""

    try:
        left = _normalize(a)
        right = _normalize(b)
    except Exception:
        return False
    return _same_obj(left, right, tol=1e-9)


def check(mine: Any, answer: Any, *, tol: float = 1e-9) -> CheckResult:
    """Check an answer and return a friendly, non-revealing message."""

    try:
        left = _normalize(mine)
        right = _normalize(answer)
    except Exception:
        return CheckResult(
            ok=False,
            message="I could not read one of those yet. Try maths input like 2*x + 3 or x^2.",
            hint="Use * for multiply when needed, and make sure brackets are balanced.",
        )
    mismatch = _kind_mismatch_message(left, right)
    if mismatch:
        return CheckResult(ok=False, message=mismatch)

    try:
        if _same_obj(left, right, tol=tol):
            return CheckResult(ok=True, message="Correct!")
    except Exception:
        return CheckResult(
            ok=False,
            message="I could not compare those yet.",
            hint="Try rewriting both answers in a simpler but equivalent form.",
        )

    hint = ""
    message = "Not quite yet."
    if isinstance(left, sp.Basic) and isinstance(right, sp.Basic):
        try:
            ok, bad_subs, bad_value = _sample_pairs(left, right, tol=tol)
            if (not ok) and bad_subs and bad_value is not None:
                where = _point_text(bad_subs)
                mine_val = _format_user_value(bad_value)
                message = (
                    f"Not quite yet. When {where}, yours gives {mine_val}, "
                    "so it needs a different value there."
                )
            hint = _difference_hint(left, right)
        except Exception:
            message = "Not quite yet."
            hint = ""
    elif isinstance(left, sp.Equality) and isinstance(right, sp.Equality):
        hint = "Try moving everything to one side and comparing the two forms."
    elif isinstance(left, list) and isinstance(right, list):
        hint = "Check that your solution set has exactly the same values."
    elif isinstance(left, MatrixBase) and isinstance(right, MatrixBase):
        hint = "Check each matrix entry one by one."

    return CheckResult(ok=False, message=message, hint=hint)
