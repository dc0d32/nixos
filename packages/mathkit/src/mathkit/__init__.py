"""Public API for mathkit so kids can import short, memorable names."""

from ._display import Step, Steps
from .check import CheckResult, check, same
from .steps import (
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
from .visuals import (
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

__all__ = [
    "CheckResult",
    "Step",
    "Steps",
    "check",
    "same",
    "diff_steps",
    "integrate_steps",
    "solve_steps",
    "factor_steps",
    "expand_steps",
    "frac_steps",
    "prime_factors",
    "long_division",
    "gcd_lcm_steps",
    "plot",
    "fraction_bar",
    "compare_fractions",
    "numberline",
    "tangent",
    "explore_tangent",
    "riemann",
    "explore_riemann",
    "unit_circle",
    "explore_unit_circle",
    "explore",
]
