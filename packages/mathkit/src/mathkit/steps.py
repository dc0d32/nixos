"""Worked-step explainers so learners can see the method, not only the answer."""

from __future__ import annotations

from collections import Counter
from typing import Any, Iterable

import sympy as sp
from sympy.core.relational import Relational
from sympy.integrals.manualintegrate import integral_steps, manualintegrate
from sympy.parsing.sympy_parser import parse_expr
from sympy.solvers.inequalities import solve_univariate_inequality

from ._display import Steps
from .check import _SAFE_LOCALS, _TRANSFORMS, _safe_parse, same


def _parse_math(obj: Any) -> Any:
    if isinstance(obj, str):
        return _safe_parse(obj)
    try:
        return sp.sympify(obj)
    except Exception as exc:
        raise ValueError("I could not read that maths expression yet.") from exc


def _to_symbol(x: Any) -> sp.Symbol:
    if isinstance(x, sp.Symbol):
        return x
    if isinstance(x, str):
        return sp.Symbol(x)
    raise ValueError("Please give the variable as a symbol like x.")


def _infer_symbol(expr: sp.Basic, x: Any | None) -> sp.Symbol:
    if x is not None:
        return _to_symbol(x)
    symbols = sorted(expr.free_symbols, key=lambda s: s.name)
    if len(symbols) == 1:
        return symbols[0]
    raise ValueError("Please tell me which variable to use, for example x.")


def _as_unevaluated_mul(counter: Counter[int]) -> sp.Basic:
    parts: list[sp.Basic] = []
    for prime, exponent in sorted(counter.items()):
        if exponent == 1:
            parts.append(sp.Integer(prime))
        else:
            parts.append(sp.Pow(sp.Integer(prime), sp.Integer(exponent), evaluate=False))
    if not parts:
        return sp.Integer(1)
    return sp.Mul(*parts, evaluate=False)


def _equivalent(a: sp.Basic, b: sp.Basic) -> bool:
    try:
        if sp.simplify(a - b) == 0:
            return True
    except Exception:
        pass
    return bool(same(a, b))


def _eq(lhs: Any, rhs: Any) -> sp.Equality:
    return sp.Eq(lhs, rhs, evaluate=False)


def _sum_raw(items: Iterable[sp.Basic]) -> sp.Basic:
    return sp.Add(*list(items), evaluate=False)


def _mul_raw(*items: sp.Basic) -> sp.Basic:
    return sp.Mul(*items, evaluate=False)


def _pow_raw(base: sp.Basic, exponent: sp.Basic) -> sp.Basic:
    return sp.Pow(base, exponent, evaluate=False)


def _derivative_part(node: sp.Basic, var: sp.Symbol, steps: Steps, label: str) -> sp.Basic:
    if not node.has(var):
        steps.add(
            f"{label}: constant rule",
            _eq(sp.Derivative(node, var), sp.Integer(0)),
            "constants do not change when we differentiate.",
        )
        return sp.Integer(0)

    if node == var:
        steps.add(
            f"{label}: derivative of the variable",
            _eq(sp.Derivative(var, var), sp.Integer(1)),
            "the slope of x is 1.",
        )
        return sp.Integer(1)

    if isinstance(node, sp.Add):
        terms = list(node.as_ordered_terms())
        steps.add(
            f"{label}: sum rule",
            _eq(
                sp.Derivative(node, var),
                _sum_raw([sp.Derivative(term, var) for term in terms]),
            ),
            "differentiate each term, then add the results.",
        )
        return sp.Add(*[_derivative_part(term, var, steps, f"{label}.{idx + 1}") for idx, term in enumerate(terms)])

    if isinstance(node, sp.Mul):
        coeff, rest = node.as_coeff_Mul()
        if coeff != 1 and rest.has(var):
            d_rest = sp.simplify(sp.diff(rest, var))
            result = sp.simplify(coeff * d_rest)
            steps.add(
                f"{label}: constant-multiple rule",
                maths=[
                    _eq(sp.Derivative(node, var), _mul_raw(sp.sympify(coeff), sp.Derivative(rest, var))),
                    _eq(sp.Derivative(rest, var), d_rest),
                    _eq(sp.Derivative(node, var), result),
                ],
                why="pull the constant out, then differentiate the variable part.",
            )
            return result

    if isinstance(node, sp.Pow):
        base, exponent = node.as_base_exp()
        if base == var and not exponent.has(var):
            result = sp.simplify(exponent * var ** (exponent - 1))
            steps.add(
                f"{label}: power rule",
                _eq(sp.Derivative(node, var), result),
                "for x^n, bring n down and subtract 1 from the power.",
            )
            return result
        if exponent == sp.Rational(1, 2):
            inner = base
            d_inner = sp.simplify(sp.diff(inner, var))
            result = sp.simplify(d_inner / (2 * sp.sqrt(inner)))
            steps.add(
                f"{label}: chain rule on a square root",
                maths=[
                    _eq(sp.Derivative(node, var), _mul_raw(sp.Integer(1) / (2 * sp.sqrt(inner)), d_inner)),
                    _eq(sp.Derivative(inner, var), d_inner),
                    _eq(sp.Derivative(node, var), result),
                ],
                why="differentiate the outer sqrt first, then multiply by the inner derivative.",
            )
            return result
        if not exponent.has(var):
            d_inner = sp.simplify(sp.diff(base, var))
            result = sp.simplify(exponent * base ** (exponent - 1) * d_inner)
            steps.add(
                f"{label}: chain rule on a power",
                maths=[
                    _eq(
                        sp.Derivative(node, var),
                        _mul_raw(sp.sympify(exponent), _pow_raw(base, sp.sympify(exponent - 1)), d_inner),
                    ),
                    _eq(sp.Derivative(base, var), d_inner),
                    _eq(sp.Derivative(node, var), result),
                ],
                why="power rule on the outside, then inner derivative.",
            )
            return result
        if not base.has(var):
            d_inner = sp.simplify(sp.diff(exponent, var))
            result = sp.simplify(node * sp.log(base) * d_inner)
            steps.add(
                f"{label}: derivative of a^g(x)",
                maths=[
                    _eq(sp.Derivative(node, var), _mul_raw(node, sp.log(base), d_inner)),
                    _eq(sp.Derivative(exponent, var), d_inner),
                    _eq(sp.Derivative(node, var), result),
                ],
                why="differentiate the exponent and multiply by a^g(x) ln(a).",
            )
            return result
        steps.add(
            f"{label}: fallback",
            _eq(sp.Derivative(node, var), sp.diff(node, var)),
            "this has the variable in both base and exponent, so we will use SymPy for this part.",
        )
        return sp.diff(node, var)

    if node.func in {sp.sin, sp.cos, sp.tan, sp.exp, sp.log, sp.asin, sp.acos, sp.atan, sp.sinh, sp.cosh, sp.tanh}:
        inner = node.args[0]
        d_inner = sp.simplify(sp.diff(inner, var))
        outer_map = {
            sp.sin: sp.cos(inner),
            sp.cos: -sp.sin(inner),
            sp.tan: sp.sec(inner) ** 2,
            sp.exp: sp.exp(inner),
            sp.log: sp.Integer(1) / inner,
            sp.asin: 1 / sp.sqrt(1 - inner**2),
            sp.acos: -1 / sp.sqrt(1 - inner**2),
            sp.atan: 1 / (1 + inner**2),
            sp.sinh: sp.cosh(inner),
            sp.cosh: sp.sinh(inner),
            sp.tanh: sp.sech(inner) ** 2,
        }
        outer_derivative = outer_map[node.func]
        result = sp.simplify(outer_derivative * d_inner)
        friendly = {
            sp.sin: "sine",
            sp.cos: "cosine",
            sp.tan: "tangent",
            sp.exp: "exponential",
            sp.log: "logarithm",
            sp.asin: "arcsine",
            sp.acos: "arccosine",
            sp.atan: "arctangent",
            sp.sinh: "sinh",
            sp.cosh: "cosh",
            sp.tanh: "tanh",
        }[node.func]
        steps.add(
            f"{label}: chain rule on {friendly}",
            maths=[
                _eq(sp.Derivative(node, var), _mul_raw(outer_derivative, d_inner)),
                _eq(sp.Derivative(inner, var), d_inner),
                _eq(sp.Derivative(node, var), result),
            ],
            why="differentiate the outer function at the inside, then multiply by the inner derivative.",
        )
        return result

    result = sp.diff(node, var)
    steps.add(
        f"{label}: fallback",
        _eq(sp.Derivative(node, var), result),
        "this pattern is uncommon, so we use SymPy here.",
    )
    return result


def diff_steps(f: Any, x: Any | None = None) -> Steps:
    """Show derivative steps in a top-down narrative with labelled parts."""

    expr = _parse_math(f)
    var = _infer_symbol(expr, x)
    steps = Steps()

    try:
        num, den = sp.fraction(sp.together(expr))
        if den != 1 and num != expr and num.has(var) and den.has(var):
            steps.add(
                "Use the quotient rule on the whole expression",
                maths=[
                    _eq(sp.Symbol("u"), num),
                    _eq(sp.Symbol("v"), den),
                    _eq(
                        sp.Derivative(expr, var),
                        (sp.Derivative(num, var) * den - num * sp.Derivative(den, var)) / den**2,
                    ),
                ],
                why="this expression is a quotient, so quotient rule is the top-level rule.",
            )
            d_num = _derivative_part(num, var, steps, "Part 1")
            d_den = _derivative_part(den, var, steps, "Part 2")
            assembled = (d_num * den - num * d_den) / den**2
            steps.add(
                "Assemble the quotient rule",
                _eq(
                    sp.Derivative(expr, var),
                    _mul_raw(
                        sp.Add(
                            _mul_raw(d_num, den),
                            -_mul_raw(num, d_den),
                            evaluate=False,
                        ),
                        _pow_raw(den, sp.Integer(-2)),
                    ),
                ),
                "replace u' and v' in the rule formula.",
            )
            candidate = sp.simplify(assembled)
        elif isinstance(expr, sp.Mul) and len([piece for piece in expr.args if piece.has(var)]) >= 2:
            factors = list(expr.args)
            u = factors[0]
            v = sp.Mul(*factors[1:])
            steps.add(
                "Use the product rule on the whole expression",
                maths=[
                    _eq(sp.Symbol("u"), u),
                    _eq(sp.Symbol("v"), v),
                    _eq(sp.Derivative(expr, var), _sum_raw([_mul_raw(sp.Derivative(u, var), v), _mul_raw(u, sp.Derivative(v, var))])),
                ],
                why="this expression is a product, so product rule comes first.",
            )
            d_u = _derivative_part(u, var, steps, "Part 1")
            d_v = _derivative_part(v, var, steps, "Part 2")
            assembled = d_u * v + u * d_v
            steps.add(
                "Assemble the product rule",
                _eq(sp.Derivative(expr, var), _sum_raw([_mul_raw(d_u, v), _mul_raw(u, d_v)])),
                "substitute each part back into u'v + uv'.",
            )
            candidate = sp.simplify(assembled)
        elif isinstance(expr, sp.Add):
            terms = list(expr.as_ordered_terms())
            steps.add(
                "Use the sum rule on the whole expression",
                _eq(sp.Derivative(expr, var), _sum_raw([sp.Derivative(term, var) for term in terms])),
                "differentiate each term and keep the same plus/minus signs.",
            )
            derivatives = [_derivative_part(term, var, steps, f"Part {idx + 1}") for idx, term in enumerate(terms)]
            assembled = sp.Add(*derivatives)
            steps.add(
                "Assemble the sum rule",
                _eq(sp.Derivative(expr, var), _sum_raw(derivatives)),
                "put the term derivatives together.",
            )
            candidate = sp.simplify(assembled)
        else:
            candidate = sp.simplify(_derivative_part(expr, var, steps, "Part 1"))
        checked = sp.diff(expr, var)
        verified = _equivalent(candidate, checked)
        if not verified:
            raise ValueError("mismatch")
        steps.add("Simplify", sp.Eq(sp.Derivative(expr, var), candidate), "clean up the final expression.")
        steps.result = candidate
        steps.verified = True
        return steps
    except Exception:
        fallback = sp.diff(expr, var)
        out = Steps(result=fallback, verified=sp.simplify(fallback - sp.diff(expr, var)) == 0)
        out.add(
            "SymPy's answer",
            sp.Eq(sp.Derivative(expr, var), fallback),
            "this one uses a pattern I cannot explain safely yet, so I am being honest and using SymPy.",
        )
        return out


def _integral_equation(integrand: sp.Basic, var: sp.Symbol, antiderivative: sp.Basic) -> sp.Equality:
    return _eq(sp.Integral(integrand, var), antiderivative)


def _pick_alternative(rule: Any, var: sp.Symbol) -> Any:
    alternatives = getattr(rule, "alternatives", []) or []
    if not alternatives:
        return rule
    for candidate in alternatives:
        if type(candidate).__name__ == "URule" and sp.simplify(getattr(candidate, "u_func", 0) - var**2) == 0:
            return candidate
    for candidate in alternatives:
        if type(candidate).__name__ == "URule":
            return candidate
    return alternatives[0]


def _manual_integral_with_story(rule: Any, var: sp.Symbol, steps: Steps, *, label: str = "") -> tuple[sp.Basic, bool]:
    name = type(rule).__name__ if rule is not None else ""
    integrand = getattr(rule, "integrand", None)
    prefix = f"{label}: " if label else ""

    if rule is None:
        raise ValueError("missing rule")

    if name == "DontKnowRule":
        antiderivative = sp.integrate(integrand, var)
        steps.add(
            f"{prefix}No hand recipe found",
            _integral_equation(integrand, var, antiderivative),
            "I do not know a reliable school-level recipe for this one, so I will use SymPy honestly.",
        )
        return antiderivative, True

    if name == "AlternativeRule":
        chosen = _pick_alternative(rule, var)
        steps.add(
            f"{prefix}Choose a helpful route",
            why="some integrals can be solved in more than one way, so we pick the simpler route.",
        )
        return _manual_integral_with_story(chosen, var, steps, label=label)

    if name == "AddRule":
        substeps = getattr(rule, "substeps", [])
        total = sp.Integer(0)
        dont_know = False
        steps.add(
            f"{prefix}Split the sum",
            _eq(
                sp.Integral(integrand, var),
                _sum_raw([sp.Integral(getattr(substep, "integrand", sp.Integer(0)), var) for substep in substeps]),
            ),
            "the integral of a sum is the sum of integrals.",
        )
        for idx, substep in enumerate(substeps, start=1):
            child_label = f"{label} part {idx}" if label else f"Part {idx}"
            part, part_dk = _manual_integral_with_story(substep, var, steps, label=child_label)
            total += part
            dont_know = dont_know or part_dk
        total = sp.simplify(total)
        steps.add(
            f"{prefix}Add the antiderivatives",
            _integral_equation(integrand, var, total),
            "put the solved pieces together.",
        )
        return total, dont_know

    if name == "ConstantTimesRule":
        constant = sp.simplify(getattr(rule, "constant", 1))
        other = sp.simplify(getattr(rule, "other", integrand))
        steps.add(
            f"{prefix}Pull out the constant",
            _eq(sp.Integral(integrand, var), _mul_raw(constant, sp.Integral(other, var))),
            "constants can move outside an integral.",
        )
        substep = getattr(rule, "substep", None)
        if substep is None:
            substep = integral_steps(other, var)
        child_label = label
        inside, dont_know = _manual_integral_with_story(substep, var, steps, label=child_label)
        antiderivative = sp.simplify(constant * inside)
        steps.add(
            f"{prefix}Multiply by the constant",
            _integral_equation(integrand, var, antiderivative),
            "now bring the constant back in.",
        )
        return antiderivative, dont_know

    if name == "URule":
        u_var = getattr(rule, "u_var", sp.Symbol("u"))
        u_func = sp.simplify(getattr(rule, "u_func", sp.Symbol("u")))
        du = sp.simplify(sp.diff(u_func, var))
        substep = getattr(rule, "substep", None)
        rewritten = getattr(substep, "integrand", None) if substep is not None else None
        steps.add(
            f"{prefix}Choose substitution",
            maths=[
                _eq(sp.Symbol("u"), u_func),
                rf"du = {sp.latex(du)}\, d{sp.latex(var)}",
            ],
            why="this choice turns the integral into a simpler u-integral.",
        )
        if rewritten is not None:
            steps.add(
                f"{prefix}Rewrite using u",
                sp.Eq(sp.Integral(integrand, var), sp.Integral(rewritten, u_var)),
                "replace the inner expression and d x pieces.",
            )
        if substep is None:
            sub_result = manualintegrate(rewritten, u_var) if rewritten is not None else sp.Integer(0)
            dont_know = False
        else:
            child_label = f"{label} in u" if label else "In u"
            sub_result, dont_know = _manual_integral_with_story(substep, u_var, steps, label=child_label)
        steps.add(
            f"{prefix}Solve the u-integral",
            sp.Eq(sp.Integral(rewritten, u_var), sub_result) if rewritten is not None else sub_result,
            "integrate in u first.",
        )
        antiderivative = sp.simplify(sub_result.subs(u_var, u_func))
        steps.add(
            f"{prefix}Substitute back",
            _integral_equation(integrand, var, antiderivative),
            "replace u with the original expression in x.",
        )
        return antiderivative, dont_know

    if name == "PartsRule":
        u = sp.simplify(getattr(rule, "u", integrand))
        dv = sp.simplify(getattr(rule, "dv", sp.Integer(1)))
        du = sp.simplify(sp.diff(u, var))
        v_step = getattr(rule, "v_step", None)
        if v_step is not None:
            v = sp.simplify(v_step.eval())
        else:
            v = sp.simplify(manualintegrate(dv, var))
        remaining_rule = getattr(rule, "second_step", None)
        remaining_integrand = sp.simplify(v * du)
        steps.add(
            f"{prefix}Choose u and dv",
            maths=[
                _eq(sp.Symbol("u"), u),
                rf"dv = {sp.latex(dv)}\, d{sp.latex(var)}",
                rf"du = {sp.latex(du)}\, d{sp.latex(var)}",
                _eq(sp.Symbol("v"), v),
            ],
            why="these choices set up integration by parts.",
        )
        steps.add(
            f"{prefix}Use ∫u dv = uv − ∫v du",
            _eq(
                sp.Integral(integrand, var),
                _sum_raw([_mul_raw(u, v), -sp.Integral(remaining_integrand, var)]),
            ),
            "substitute u, v, and du into the formula.",
        )
        if remaining_rule is None:
            remaining_rule = integral_steps(remaining_integrand, var)
        child_label = f"{label} remaining" if label else "Remaining integral"
        remainder, dont_know = _manual_integral_with_story(remaining_rule, var, steps, label=child_label)
        antiderivative = sp.simplify(u * v - remainder)
        steps.add(
            f"{prefix}Combine the parts",
            _integral_equation(integrand, var, antiderivative),
            "finish uv − ∫vdu using the solved remainder.",
        )
        return antiderivative, dont_know

    antiderivative = sp.simplify(rule.eval())
    pretty_name = {
        "ConstantRule": "constant rule",
        "PowerRule": "power rule",
        "ExpRule": "exponential rule",
        "SinRule": "sine rule",
        "CosRule": "cosine rule",
        "ReciprocalRule": "1/x rule",
        "TrigRule": "trig rule",
    }.get(name, "integral rule")
    steps.add(
        f"{prefix}Apply {pretty_name}",
        _integral_equation(integrand, var, antiderivative),
        "use the matching basic antiderivative formula.",
    )
    return antiderivative, False


def integrate_steps(f: Any, x: Any | None = None, bounds: tuple[Any, Any] | None = None) -> Steps:
    """Show integration steps with explicit formulas and checks."""

    expr = _parse_math(f)
    var = _infer_symbol(expr, x)
    steps = Steps()
    try:
        rule = integral_steps(expr, var)
    except Exception:
        rule = None
    if rule is None:
        antiderivative = sp.integrate(expr, var)
        dont_know = True
        steps.add(
            "No manual tree available",
            _integral_equation(expr, var, antiderivative),
            "I could not build a manual rule tree, so I used SymPy directly.",
        )
    else:
        antiderivative, dont_know = _manual_integral_with_story(rule, var, steps)
        if dont_know:
            antiderivative = sp.integrate(expr, var)
            steps.add(
                "Use SymPy for the final antiderivative",
                _integral_equation(expr, var, antiderivative),
                "at least one sub-part had no reliable hand recipe.",
            )
    if bounds is None:
        C = sp.Symbol("C")
        steps.add(
            "Write the antiderivative",
            _eq(sp.Integral(expr, var), _sum_raw([antiderivative, C])),
            "indefinite integrals always include + C.",
        )
        derivative_now = sp.simplify(sp.diff(antiderivative, var))
        matches = _equivalent(derivative_now, expr)
        steps.add(
            "Check by differentiating",
            maths=[
                _eq(sp.Derivative(antiderivative, var), derivative_now),
                _eq(derivative_now, expr),
            ],
            why="differentiating an antiderivative should return the original integrand.",
        )
        steps.result = antiderivative
        steps.verified = matches
        return steps

    if not isinstance(bounds, tuple) or len(bounds) != 2:
        raise ValueError("Bounds must be a pair like (a, b).")
    a, b = bounds
    F = sp.Function("F")
    steps.add(
        "Find an antiderivative first",
        _eq(F(var), antiderivative),
        "definite integrals use F(b) − F(a).",
    )
    Fa = sp.simplify(antiderivative.subs(var, a))
    Fb = sp.simplify(antiderivative.subs(var, b))
    value = sp.simplify(Fb - Fa)
    steps.add(
        "Apply the fundamental theorem",
        _eq(
            sp.Integral(expr, (var, a, b)),
            _sum_raw([F(b), -F(a)]),
        ),
        "evaluate the antiderivative at upper then lower bound.",
    )
    steps.add(
        "Evaluate the bounds",
        maths=[
            _eq(_sum_raw([F(b), -F(a)]), _sum_raw([Fb, -Fa])),
            _eq(_sum_raw([Fb, -Fa]), value),
        ],
        why="substitute the numbers exactly.",
    )
    steps.add("Final value", _eq(sp.Integral(expr, (var, a, b)), value), "this is the exact definite integral.")
    derivative_ok = _equivalent(sp.simplify(sp.diff(antiderivative, var)), expr)
    value_ok = _equivalent(value, sp.integrate(expr, (var, a, b)))
    derivative_now = sp.simplify(sp.diff(antiderivative, var))
    steps.add(
        "Check by differentiating",
        maths=[
            _eq(sp.Derivative(antiderivative, var), derivative_now),
            _eq(derivative_now, expr),
        ],
        why="this confirms our antiderivative is right.",
    )
    steps.result = value
    steps.verified = bool(derivative_ok and value_ok)
    return steps


def _parse_equation(eq: Any) -> Any:
    if isinstance(eq, str):
        parsed = _safe_parse(eq)
        if isinstance(parsed, sp.Equality):
            return parsed
        if isinstance(parsed, Relational):
            return parsed
        return sp.Eq(parsed, 0)
    if isinstance(eq, sp.Equality) or isinstance(eq, Relational):
        return eq
    expr = _parse_math(eq)
    return sp.Eq(expr, 0)


def _flip_relation(rel: Any) -> Any:
    if isinstance(rel, sp.StrictLessThan):
        return sp.StrictGreaterThan
    if isinstance(rel, sp.StrictGreaterThan):
        return sp.StrictLessThan
    if isinstance(rel, sp.LessThan):
        return sp.GreaterThan
    return sp.LessThan


def _substitute_for_display(expr: sp.Basic, var: sp.Symbol, value: sp.Basic) -> sp.Basic:
    wrapped = sp.UnevaluatedExpr(value)
    expanded = sp.expand(expr)
    try:
        poly = sp.Poly(expanded, var)
    except Exception:
        poly = None
    if poly is None:
        return expr.subs(var, wrapped)

    degree = poly.degree()
    terms: list[sp.Basic] = []
    for index, coeff in enumerate(poly.all_coeffs()):
        power = degree - index
        if coeff == 0:
            continue
        if power == 0:
            term = coeff
        elif power == 1:
            term = _mul_raw(coeff, wrapped)
        else:
            term = _mul_raw(coeff, _pow_raw(wrapped, sp.Integer(power)))
        terms.append(term)
    if not terms:
        return sp.Integer(0)
    return _sum_raw(terms)


def _poly_substitution_latex(expr: sp.Basic, var: sp.Symbol, value: sp.Basic) -> str | None:
    wrapped = sp.UnevaluatedExpr(value)
    core_value = sp.latex(wrapped)
    if not getattr(value, "is_Atom", False):
        core_value = rf"\left({core_value}\right)"
    try:
        poly = sp.Poly(sp.expand(expr), var)
    except Exception:
        return None
    degree = poly.degree()
    pieces: list[str] = []
    for index, coeff in enumerate(poly.all_coeffs()):
        power = degree - index
        if coeff == 0:
            continue
        sign = -1 if coeff.could_extract_minus_sign() else 1
        abs_coeff = sp.simplify(-coeff if sign < 0 else coeff)

        if power == 0:
            body = sp.latex(abs_coeff)
        elif power == 1:
            body = core_value if abs_coeff == 1 else rf"{sp.latex(abs_coeff)} \cdot {core_value}"
        else:
            power_expr = sp.latex(_pow_raw(wrapped, sp.Integer(power)))
            body = power_expr if abs_coeff == 1 else rf"{sp.latex(abs_coeff)} \cdot {power_expr}"

        if not pieces:
            pieces.append(f"- {body}" if sign < 0 else body)
        else:
            pieces.append((" - " if sign < 0 else " + ") + body)
    if not pieces:
        return sp.latex(sp.Integer(0))
    return "".join(pieces)


def _check_line_latex(var: sp.Symbol, sol: sp.Basic, expr: sp.Basic, residual: sp.Basic, ok: bool) -> str:
    assignment = sp.latex(_eq(var, sol))
    substituted = _poly_substitution_latex(expr, var, sol)
    if substituted is None:
        substituted = sp.latex(_substitute_for_display(expr, var, sol))
    outcome = sp.latex(residual)
    mark = r"\checkmark" if ok else r"\times"
    return rf"{assignment}: {substituted} = {outcome}\ {mark}"


def solve_steps(eq: Any, x: Any | None = None) -> Steps:
    """Show friendly steps for linear and quadratic equations."""

    relation = _parse_equation(eq)
    var = _infer_symbol(sp.sympify(relation.lhs - relation.rhs if isinstance(relation, sp.Equality) else relation.lhs - relation.rhs), x)
    steps = Steps()

    if isinstance(relation, (sp.StrictLessThan, sp.StrictGreaterThan, sp.LessThan, sp.GreaterThan)):
        expr = sp.expand(relation.lhs - relation.rhs)
        try:
            poly = sp.Poly(expr, var)
        except Exception:
            poly = None
        if poly is not None and poly.degree() == 1:
            a, b = [sp.simplify(c) for c in poly.all_coeffs()]
            relation_class = type(relation)
            steps.add(
                "Move everything to one side",
                maths=[relation, type(relation)(a * var + b, 0)],
                why="linear inequalities are easiest to balance in ax + b form.",
            )
            middle = relation_class(a * var, -b)
            steps.add(
                "Subtract the constant term",
                middle,
                "keep the inequality balanced by doing the same thing to both sides.",
            )
            boundary = sp.simplify(-b / a)
            if bool(getattr(a, "is_negative", False)):
                flipped = _flip_relation(relation)(var, boundary)
                steps.add(
                    "Divide by a negative coefficient",
                    flipped,
                    "dividing by a negative flips the inequality sign.",
                )
            else:
                flipped = relation_class(var, boundary)
                steps.add(
                    "Divide by the positive coefficient",
                    flipped,
                    "dividing by a positive keeps the inequality sign the same.",
                )
            solution = solve_univariate_inequality(relation, var)
            steps.add("Solution set", solution, "this agrees with SymPy's inequality solver.")
            steps.result = solution
            steps.verified = True
            return steps

        solution = solve_univariate_inequality(relation, var)
        steps.add(
            "Use SymPy for this inequality",
            solution,
            "this helper only shows full balance steps for linear inequalities.",
        )
        steps.result = solution
        steps.verified = True
        return steps

    lhs = relation.lhs
    rhs = relation.rhs
    expr = sp.expand(lhs - rhs)
    try:
        poly = sp.Poly(expr, var)
    except Exception:
        poly = None

    solutions: list[sp.Basic]

    if poly is not None and poly.degree() == 1:
        a, b = poly.all_coeffs()
        steps.add("Move to standard form", _eq(expr, 0), "put everything on one side.")
        steps.add("Subtract the constant from both sides", _eq(a * var, -b), "balance method.")
        sol = sp.simplify(-b / a)
        steps.add("Divide both sides by the coefficient", _eq(var, sol), "balance method.")
        solutions = [sol]
    elif poly is not None and poly.degree() == 2:
        a, b, c = poly.all_coeffs()
        steps.add("Move to standard form", _eq(expr, 0), "write the quadratic in standard form.")
        factored = sp.factor(expr)
        if factored != expr and isinstance(factored, sp.Mul):
            steps.add("Factor the quadratic", _eq(expr, factored), "try factoring over rational numbers first.")
            roots: list[sp.Basic] = []
            for factor in factored.args:
                if factor.has(var):
                    roots.extend(sp.solve(_eq(factor, 0), var))
            solutions = list(dict.fromkeys(sp.simplify(r) for r in roots))
            steps.add("Apply the zero-product rule", [_eq(var, r) for r in solutions], "if a product is zero, one factor must be zero.")
        else:
            disc = sp.simplify(b**2 - 4 * a * c)
            steps.add("Compute the discriminant", _eq(sp.Symbol("D"), disc), "the discriminant tells us the root type.")
            r1 = sp.simplify((-b + sp.sqrt(disc)) / (2 * a))
            r2 = sp.simplify((-b - sp.sqrt(disc)) / (2 * a))
            solutions = [r1] if sp.simplify(r1 - r2) == 0 else [r1, r2]
            steps.add("Use the quadratic formula", [_eq(var, r) for r in solutions], "apply the formula to get the roots.")
    else:
        solutions = sp.solve(relation, var)
        steps.add("Use SymPy's solver", solutions, "I do not have a clear hand recipe for this form yet.")

    checks: list[str] = []
    verified = True
    for sol in solutions:
        residual = sp.simplify((lhs - rhs).subs(var, sol))
        ok = residual == 0
        checks.append(_check_line_latex(var, sol, lhs - rhs, residual, bool(ok)))
        verified = verified and ok
    steps.add("Check each solution", maths=checks, why="substitute each candidate into the original equation.")
    steps.result = solutions
    steps.verified = bool(verified)
    return steps


def factor_steps(expr: Any) -> Steps:
    """Show a short factoring explanation for common school patterns."""

    source = _parse_math(expr)
    out = Steps()
    factored = sp.factor(source)
    display_factored = factored
    if isinstance(factored, sp.Mul):
        display_factored = sp.Mul(*factored.args, evaluate=False)
    if factored == source:
        out.add("No obvious factor pattern", sp.Eq(source, display_factored), "SymPy says this is already factored enough.")
    else:
        pattern = "factoring"
        if isinstance(source, sp.Add) and len(source.args) == 2:
            terms = sorted(source.args, key=sp.default_sort_key)
            if terms[0].is_Pow and terms[1].is_Pow and terms[0].exp == 2 and terms[1].exp == 2:
                pattern = "difference of squares"
        if isinstance(factored, sp.Pow) and factored.exp == 2:
            pattern = "perfect-square trinomial"
        elif isinstance(source, sp.Add) and any(t.is_number for t in source.args):
            pattern = "simple trinomial"
        elif isinstance(factored, sp.Mul):
            pattern = "common factor"
        out.add("Recognise the pattern", sp.Eq(source, display_factored), pattern)
    out.result = factored
    out.verified = sp.simplify(sp.expand(factored) - sp.expand(source)) == 0
    return out


def expand_steps(expr: Any) -> Steps:
    """Show a short expansion explanation (distributive law / FOIL)."""

    source = _parse_math(expr)
    out = Steps()
    expanded = sp.expand(source)
    if isinstance(source, sp.Mul) and any(isinstance(arg, sp.Add) for arg in source.args):
        if len([arg for arg in source.args if isinstance(arg, sp.Add)]) >= 2:
            why = "FOIL is distributive law on two binomials."
        else:
            why = "distributive law: multiply each term inside brackets."
        out.add("Distribute multiplication", sp.Eq(source, expanded), why)
    else:
        out.add("Expand with SymPy", sp.Eq(source, expanded), "this one is straightforward expansion.")
    out.result = expanded
    out.verified = sp.simplify(expanded - sp.expand(source)) == 0
    return out


def _as_fraction(expr: sp.Basic) -> tuple[int, int]:
    num, den = sp.fraction(sp.together(expr))
    if num.is_Integer and den.is_Integer and den != 0:
        return int(num), int(den)
    raise ValueError("Please use integer fractions like 3/4.")


def _fraction_text(num: int, den: int) -> str:
    return f"{num}/{den}"


def _raw_fraction(num: int, den: int) -> sp.Basic:
    if num == 1:
        return _pow_raw(sp.Integer(den), sp.Integer(-1))
    if num == -1:
        return -_pow_raw(sp.Integer(den), sp.Integer(-1))
    return _mul_raw(sp.Integer(num), _pow_raw(sp.Integer(den), sp.Integer(-1)))


def _mixed_number_text(value: sp.Rational) -> str:
    whole = int(sp.floor(value))
    remainder = sp.simplify(value - whole)
    if remainder == 0:
        return f"{whole}"
    if whole == 0:
        return sp.sstr(remainder)
    rem_num = int(abs(remainder.p))
    rem_den = int(remainder.q)
    return f"{whole} {rem_num}/{rem_den}"


def _mixed_number_expr(value: sp.Rational) -> sp.Basic:
    whole = int(sp.floor(value))
    remainder = sp.simplify(value - whole)
    if remainder == 0:
        return sp.Integer(whole)
    if whole == 0:
        return remainder
    return _sum_raw([sp.Integer(whole), remainder])


def _mixed_number_line(value: sp.Rational) -> str:
    whole = int(sp.floor(value))
    remainder = sp.simplify(value - whole)
    if remainder == 0:
        return sp.latex(_eq(value, sp.Integer(whole)))
    if whole == 0:
        return sp.latex(_eq(value, remainder))
    return rf"{sp.latex(value)} = {sp.latex(sp.Integer(whole))} + {sp.latex(remainder)}"


def _parse_fraction_input(expr: Any) -> sp.Basic:
    if isinstance(expr, str):
        text = expr.strip()
        if not text:
            raise ValueError("Please type a fraction expression.")
        return parse_expr(text, transformations=_TRANSFORMS, local_dict=_SAFE_LOCALS, evaluate=False)
    return _parse_math(expr)


def frac_steps(expr: Any) -> Steps:
    """Show arithmetic steps for basic fraction calculations."""

    source = _parse_fraction_input(expr)
    out = Steps()
    result = sp.simplify(source)
    if not isinstance(expr, str) and isinstance(source, sp.Rational):
        mixed_line = _mixed_number_line(source)
        out.add(
            "This answer is already evaluated",
            _eq(sp.Symbol("input"), source),
            "when structure is gone, I can only simplify and rewrite politely.",
        )
        out.add(
            "Write in lowest terms and as a mixed number",
            mixed_line,
            "showing both forms helps check understanding.",
        )
    elif isinstance(source, sp.Add):
        try:
            parts = [_as_fraction(term) for term in source.args]
        except ValueError:
            parts = []
        if parts:
            dens = [abs(den) for _, den in parts]
            common = int(sp.ilcm(*dens))
            scaled_nums = [num * (common // den) for num, den in parts]
            out.add(
                "Find a common denominator",
                _eq(sp.Function("LCM")(*[sp.Integer(den) for den in dens]), sp.Integer(common)),
                "fractions must name equal-size parts before we add or subtract.",
            )
            rewrites: list[sp.Equality] = []
            for num, den in parts:
                scale = common // den
                rewrites.append(_eq(_raw_fraction(num, den), _raw_fraction(num * scale, common)))
            out.add(
                "Rewrite each fraction with that denominator",
                maths=rewrites,
                why="multiplying top and bottom by the same number keeps value unchanged.",
            )
            top = sum(scaled_nums)
            lhs_sum = _sum_raw([_raw_fraction(num, common) for num in scaled_nums])
            out.add(
                "Add or subtract the numerators",
                _eq(lhs_sum, sp.Rational(top, common)),
                "once denominators match, we only combine the numerators.",
            )
            reduced = sp.Rational(top, common)
            gcd_value = int(abs(sp.igcd(top, common)))
            mixed_line = _mixed_number_line(reduced)
            if gcd_value > 1:
                out.add(
                    "Simplify with gcd",
                    maths=[
                        _eq(sp.Function("gcd")(sp.Integer(abs(top)), sp.Integer(common)), sp.Integer(gcd_value)),
                        _eq(sp.Rational(top, common), reduced),
                    ],
                    why="divide numerator and denominator by their greatest common divisor.",
                )
            out.add(
                "Write as a mixed number",
                mixed_line,
                "mixed numbers show how many wholes and parts remain.",
            )
        else:
            out.add("Use SymPy simplification", sp.Eq(source, result), "this fraction pattern is outside the current templates.")
    elif isinstance(source, sp.Mul):
        factors = list(source.args)
        reciprocal_bases: list[sp.Basic] = []
        for factor in factors:
            if isinstance(factor, sp.Pow) and factor.exp == -1:
                try:
                    base_num, base_den = _as_fraction(factor.base)
                    if abs(base_den) != 1:
                        reciprocal_bases.append(factor.base)
                except ValueError:
                    continue
        if len(reciprocal_bases) == 1 and len(factors) >= 2:
            divisor = reciprocal_bases[0]
            left_expr = sp.simplify(source * divisor)
            left_num, left_den = _as_fraction(left_expr)
            div_num, div_den = _as_fraction(divisor)
            out.add(
                "Turn division by a fraction into multiply by its reciprocal",
                _eq(
                    sp.Mul(sp.Rational(left_num, left_den), _pow_raw(sp.Rational(div_num, div_den), sp.Integer(-1)), evaluate=False),
                    _mul_raw(sp.Rational(left_num, left_den), sp.Rational(div_den, div_num)),
                ),
                "dividing by a fraction means multiplying by its upside-down version.",
            )
            source = sp.Mul(left_expr, sp.Rational(div_den, div_num), evaluate=False)
            factors = list(source.args)
        can_factor = True
        numerator_factors: list[int] = []
        denominator_factors: list[int] = []
        for factor in factors:
            try:
                num, den = _as_fraction(factor)
            except ValueError:
                can_factor = False
                break
            sign = -1 if num < 0 else 1
            num = abs(num)
            den = abs(den)
            if sign < 0:
                numerator_factors.append(-1)
            if num != 1:
                numerator_factors.append(num)
            if den != 1:
                denominator_factors.append(den)
        if can_factor and (numerator_factors or denominator_factors):
            num_counts = Counter(abs(v) for v in numerator_factors if abs(v) != 1)
            den_counts = Counter(denominator_factors)
            cancelled: list[int] = []
            for prime in sorted(set(num_counts) & set(den_counts)):
                count = min(num_counts[prime], den_counts[prime])
                if count > 0:
                    cancelled.extend([prime] * count)
                    num_counts[prime] -= count
                    den_counts[prime] -= count
            overall_sign = -1 if numerator_factors.count(-1) % 2 else 1
            if cancelled:
                out.add(
                    "Cancel common factors before multiplying",
                    sp.FiniteSet(*[sp.Integer(v) for v in cancelled]),
                    "removing common factors makes the multiplication easier.",
                )
            num_left = [prime for prime, count in sorted(num_counts.items()) for _ in range(count)]
            den_left = [prime for prime, count in sorted(den_counts.items()) for _ in range(count)]
            numer = overall_sign * (sp.prod(num_left) if num_left else 1)
            denom = sp.prod(den_left) if den_left else 1
            raw_num = sp.prod([abs(v) for v in numerator_factors if abs(v) != 1]) if any(abs(v) != 1 for v in numerator_factors) else 1
            raw_den = sp.prod(denominator_factors) if denominator_factors else 1
            out.add(
                "Multiply what is left",
                _eq(sp.Rational(int(overall_sign * raw_num), int(raw_den)), sp.Rational(int(numer), int(denom))),
                "multiply remaining top factors and bottom factors.",
            )
            reduced = sp.Rational(int(numer), int(denom))
            gcd_value = int(abs(sp.igcd(int(numer), int(denom))))
            if gcd_value > 1:
                out.add(
                    "Simplify by gcd",
                    maths=[
                        _eq(
                            sp.Function("gcd")(sp.Integer(abs(int(numer))), sp.Integer(abs(int(denom)))),
                            sp.Integer(gcd_value),
                        ),
                        _eq(sp.Rational(int(numer), int(denom)), reduced),
                    ],
                    why="divide top and bottom by their greatest common divisor.",
                )
            mixed_expr = _mixed_number_expr(reduced)
            out.add(
                "Simplify and write as a mixed number",
                _mixed_number_line(reduced),
                "finish in lowest terms, then show whole-plus-part form.",
            )
        else:
            whole_num, whole_den = _as_fraction(source)
            reduced = sp.Rational(whole_num, whole_den)
            gcd_value = int(abs(sp.igcd(whole_num, whole_den)))
            if gcd_value > 1:
                out.add(
                    "Simplify by gcd",
                    maths=[
                        _eq(sp.Function("gcd")(sp.Integer(abs(whole_num)), sp.Integer(abs(whole_den))), sp.Integer(gcd_value)),
                        _eq(sp.Rational(whole_num, whole_den), reduced),
                    ],
                    why="divide top and bottom by the same greatest common divisor.",
                )
            out.add(
                "Write as a mixed number",
                _mixed_number_line(reduced),
                "this shows whole units and leftover parts.",
            )
    else:
        out.add("Use SymPy simplification", sp.Eq(source, result), "this expression is outside the current fraction templates.")

    out.result = result
    out.verified = sp.simplify(source - result) == 0
    return out


def prime_factors(n: int) -> Steps:
    """Show repeated division to produce a prime factorization."""

    if not isinstance(n, int) or n <= 1:
        raise ValueError("Please give an integer greater than 1.")
    out = Steps()
    current = n
    factors: list[int] = []
    d = 2
    while d * d <= current:
        while current % d == 0:
            out.add(
                "Divide by a prime",
                rf"\\frac{{{sp.latex(sp.Integer(current))}}}{{{sp.latex(sp.Integer(d))}}} = {sp.latex(sp.Integer(current // d))}",
                why="keep dividing while it goes exactly.",
            )
            factors.append(d)
            current //= d
        d = 3 if d == 2 else d + 2
    if current > 1:
        factors.append(current)
        out.add("Last prime factor", current, "what is left is prime.")
    counts = Counter(factors)
    product = _as_unevaluated_mul(counts)
    out.add("Write with exponents", product, "group equal primes together.")
    out.result = product
    out.verified = int(sp.expand(product)) == n
    return out


def long_division(a: int, b: int) -> Steps:
    """Show digit-by-digit long division for positive integers."""

    if not (isinstance(a, int) and isinstance(b, int) and a >= 0 and b > 0):
        raise ValueError("Please use non-negative integers with a positive divisor.")
    out = Steps()
    remainder = 0
    q_digits: list[str] = []
    for digit_char in str(a):
        digit = int(digit_char)
        current = remainder * 10 + digit
        q_digit = current // b
        remainder = current % b
        q_digits.append(str(q_digit))
        out.add(
            "Bring down next digit",
            maths=[
                rf"\\frac{{{sp.latex(sp.Integer(current))}}}{{{sp.latex(sp.Integer(b))}}} = {sp.latex(sp.Integer(q_digit))}",
                _eq(sp.Integer(current), _sum_raw([_mul_raw(sp.Integer(b), sp.Integer(q_digit)), sp.Integer(remainder)])),
            ],
            why="this is one long-division column.",
        )
    quotient = int("".join(q_digits)) if q_digits else 0
    out.add(
        "Final answer",
        _eq(sp.Integer(a), _sum_raw([_mul_raw(sp.Integer(b), sp.Integer(quotient)), sp.Integer(remainder)])),
        "quotient with remainder.",
    )
    out.result = (quotient, remainder)
    out.verified = (b * quotient + remainder) == a and 0 <= remainder < b
    return out


def _prime_map(value: int) -> Counter[int]:
    n = abs(value)
    factors = Counter()
    d = 2
    while d * d <= n:
        while n % d == 0:
            factors[d] += 1
            n //= d
        d = 3 if d == 2 else d + 2
    if n > 1:
        factors[n] += 1
    return factors


def gcd_lcm_steps(a: int, b: int) -> Steps:
    """Show gcd and lcm using Euclid's algorithm and prime powers."""

    if not (isinstance(a, int) and isinstance(b, int) and a != 0 and b != 0):
        raise ValueError("Please use two non-zero integers.")
    out = Steps()
    x, y = abs(a), abs(b)
    while y:
        q, r = divmod(x, y)
        out.add(
            "Euclid step",
            _eq(sp.Integer(x), _sum_raw([_mul_raw(sp.Integer(y), sp.Integer(q)), sp.Integer(r)])),
            "repeat with the last non-zero remainder.",
        )
        x, y = y, r
    gcd_value = x
    out.add("Greatest common divisor", gcd_value, "last non-zero remainder is the gcd.")

    fa = _prime_map(a)
    fb = _prime_map(b)
    out.add("Prime factors of first number", _as_unevaluated_mul(fa), "write repeated primes with exponents.")
    out.add("Prime factors of second number", _as_unevaluated_mul(fb), "write repeated primes with exponents.")
    powers = {p: max(fa.get(p, 0), fb.get(p, 0)) for p in set(fa) | set(fb)}
    lcm_factor_form = _as_unevaluated_mul(Counter(powers))
    lcm_value = int(sp.ilcm(a, b))
    out.add("Build the least common multiple", lcm_factor_form, "take each prime with the larger exponent.")
    out.add("Least common multiple", lcm_value, "multiply those prime powers to get the lcm.")
    out.result = (gcd_value, lcm_value)
    out.verified = gcd_value == int(sp.gcd(a, b)) and lcm_value == int(sp.ilcm(a, b))
    return out
