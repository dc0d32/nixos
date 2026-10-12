#!/usr/bin/env python3
"""Weekly read-only lock update and anonymous WezTerm request preparation."""
from wezterm_pipeline import cli

if __name__ == "__main__":
    cli(request_only=True)
