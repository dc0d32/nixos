"""Notebook structure and execution tests."""

from __future__ import annotations

import json
import os
import unittest
from pathlib import Path


EXPECTED_NOTEBOOKS = [
    "00-start-here.ipynb",
    "01-numbers-and-fractions.ipynb",
    "02-algebra.ipynb",
    "03-geometry-and-trig.ipynb",
    "04-calculus.ipynb",
    "05-linear-algebra.ipynb",
    "06-data-and-probability.ipynb",
]

EXPECTED_KERNELSPEC = {
    "name": "mathpython",
    "display_name": "Maths (Python + SymPy)",
    "language": "python",
}


class NotebookTests(unittest.TestCase):
    def setUp(self) -> None:
        self.notebooks_dir = Path(__file__).resolve().parent.parent / "notebooks"
        os.environ["MPLBACKEND"] = "Agg"

    def test_notebook_files_match_expected(self) -> None:
        self.assertTrue(self.notebooks_dir.exists(), msg=f"missing notebooks dir: {self.notebooks_dir}")
        names = sorted(p.name for p in self.notebooks_dir.iterdir() if p.is_file())
        self.assertEqual(names, EXPECTED_NOTEBOOKS)

    def test_notebooks_metadata_outputs_and_execution(self) -> None:
        try:
            from IPython.display import display
        except Exception:
            display = print

        for name in EXPECTED_NOTEBOOKS:
            nb_path = self.notebooks_dir / name
            self.assertTrue(nb_path.exists(), msg=f"missing notebook: {name}")
            data = json.loads(nb_path.read_text(encoding="utf-8"))

            self.assertEqual(data.get("nbformat"), 4, msg=f"{name}: nbformat must be 4")
            self.assertEqual(data.get("nbformat_minor"), 5, msg=f"{name}: nbformat_minor must be 5")

            metadata = data.get("metadata", {})
            self.assertEqual(metadata.get("kernelspec"), EXPECTED_KERNELSPEC, msg=f"{name}: kernelspec mismatch")
            self.assertEqual(metadata.get("language_info", {}).get("name"), "python", msg=f"{name}: language_info.name mismatch")

            cells = data.get("cells", [])
            self.assertTrue(any(c.get("cell_type") == "markdown" for c in cells), msg=f"{name}: needs markdown cell")
            self.assertTrue(any(c.get("cell_type") == "code" for c in cells), msg=f"{name}: needs code cell")

            namespace = {"__name__": "__notebook__", "display": display}

            for idx, cell in enumerate(cells):
                if cell.get("cell_type") != "code":
                    continue

                outputs = cell.get("outputs", [])
                self.assertEqual(outputs, [], msg=f"{name}: code cell {idx} has stored outputs")

                source = cell.get("source", "")
                if isinstance(source, list):
                    source = "".join(source)

                filtered_lines = []
                for line in source.splitlines():
                    stripped = line.lstrip()
                    if stripped.startswith("%") or stripped.startswith("!"):
                        continue
                    filtered_lines.append(line)
                runnable = "\n".join(filtered_lines)
                if not runnable.strip():
                    continue

                try:
                    exec(compile(runnable, f"{name}#cell{idx}", "exec"), namespace, namespace)
                except Exception as exc:  # pragma: no cover - failure path carries message
                    self.fail(f"{name}: code cell {idx} failed with {type(exc).__name__}: {exc}")

            text = "\n".join(
                "".join(c.get("source", "")) if isinstance(c.get("source", ""), list) else c.get("source", "")
                for c in cells
            )
            self.assertNotIn("mk.plot(", text, msg=f"{name}: use plot(...) directly")
            self.assertNotIn("import mathkit as mk", text, msg=f"{name}: remove mk alias import")

            first_code = next((c for c in cells if c.get("cell_type") == "code"), None)
            self.assertIsNotNone(first_code, msg=f"{name}: no code cells found")
            source = first_code.get("source", "")
            if isinstance(source, list):
                source = "".join(source)
            sym_idx = source.find("from sympy import *")
            mk_idx = source.find("from mathkit import *")
            self.assertNotEqual(sym_idx, -1, msg=f"{name}: missing 'from sympy import *' in first code cell")
            self.assertNotEqual(mk_idx, -1, msg=f"{name}: missing 'from mathkit import *' in first code cell")
            self.assertLess(sym_idx, mk_idx, msg=f"{name}: import SymPy before mathkit")


if __name__ == "__main__":
    unittest.main()
