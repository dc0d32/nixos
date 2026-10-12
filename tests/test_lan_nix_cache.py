#!/usr/bin/env python3
"""Credential-free tests of the actual, natively built cache client scripts."""
import os
from pathlib import Path
import subprocess
import unittest


ROOT = "/nix/store/" + "0" * 32 + "-native-mac"
SECOND = "/nix/store/" + "1" * 32 + "-dependency"
ID = "a" * 32
MOCKS = r'''
realpath() {
  printf 'CALL realpath %s\n' "$*" >&2
  [[ "$FAIL" != resolve ]] || return 11
  case "$*" in *bad*) printf '%s\n' "$BAD_ROOT";; *) printf '%s\n' "$ROOT";; esac
}
curl() {
  printf 'CALL curl %s\n' "$*" >&2
  [[ "$FAIL" != lan ]] || return 12
}
openssl() { printf '%s\n' "$ID"; }
nix-store() {
  printf 'CALL nix-store %s\n' "$*" >&2
  case "$1" in
    --check-validity) [[ "$FAIL" != validity ]] || return 13;;
    --query)
      [[ "$FAIL" != query ]] || return 14
      printf '%s\n' "$SECOND" "$ROOT";;
    --export)
      [[ "$FAIL" != export ]] || return 15
      printf 'exported selected closure';;
  esac
}
ssh() {
  printf 'CALL ssh %s\n' "$*" >&2
  case "$*" in
    *'test -x'*) [[ "$FAIL" != preflight ]] || return 16;;
    *'nix-cache-stage '*)
      [[ "$FAIL" != stage ]] || return 17
      local nar
      nar="$(cat)"
      [[ "$nar" == 'exported selected closure' ]] || return 18;;
    *'nix-cache-publish '*)
      [[ "$FAIL" != publish ]] || return 19;;
    *'rm -f'*)
      [[ "$FAIL" != cleanup ]] || return 20;;
  esac
}
nix() {
  printf 'CALL nix %s\n' "$*" >&2
  [[ "$FAIL" != build ]] || return 21
  [[ "$FAIL" != empty ]] || return 0
  printf '%s\n' "$ROOT" "$SECOND"
}
nix-cache-upload() {
  printf 'CALL upload %s\n' "$*" >&2
  [[ "$FAIL" != upload ]] || return 22
}
'''


class CacheClientTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.scripts = {}
        for name in ("nix-cache-upload", "nix-cache-build"):
            result = subprocess.run(
                [
                    "nix", "eval", "--raw",
                    ".#homeConfigurations.p@pb-mb.config.home.packages",
                    "--apply",
                    f'ps: (builtins.head (builtins.filter (p: p.name == "{name}") ps)).outPath',
                ],
                check=True, capture_output=True, text=True,
            )
            path = Path(result.stdout) / "bin" / name
            if not path.exists():
                raise RuntimeError("Build p@pb-mb.activationPackage before running these tests")
            cls.scripts[name] = path.read_text()
        cls.bash = cls.scripts["nix-cache-upload"].splitlines()[0][2:]

    def run_script(self, name, *arguments, fail="", bad_root="/etc/passwd"):
        environment = dict(os.environ)
        environment.update(
            FAIL=fail, BAD_ROOT=bad_root, ROOT=ROOT, SECOND=SECOND, ID=ID,
        )
        return subprocess.run(
            [self.bash, "-c", MOCKS + "\n" + self.scripts[name], name, *arguments],
            env=environment, text=True, capture_output=True,
        )

    def upload(self, *arguments, **kwargs):
        return self.run_script("nix-cache-upload", *arguments, **kwargs)

    def test_exports_selected_closure_then_interactive_publish(self):
        result = self.upload("result")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(f"CALL nix-store --query --requisites {ROOT}", result.stderr)
        self.assertIn(f"CALL nix-store --export {SECOND} {ROOT}", result.stderr)
        self.assertIn("CALL ssh -t -o BatchMode=yes", result.stderr)
        self.assertIn("-o StrictHostKeyChecking=yes", result.stderr)
        self.assertIn(f"nix-cache-publish {ID} {ROOT}", result.stderr)
        self.assertIn(f"rm -f -- .local/state/nix-cache-upload/{ID}.nar", result.stderr)
        self.assertIn("publicly readable", result.stderr)

    def test_profile_selects_only_hm_profile(self):
        result = self.upload("--profile")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("/nix/profiles/home-manager", result.stderr)
        self.assertNotIn("--all", result.stderr)

    def test_lan_gate_has_short_timeout_and_no_http_proxy(self):
        result = self.upload("result")
        self.assertIn("--noproxy *", result.stderr)
        self.assertIn("--connect-timeout 3 --max-time 8", result.stderr)
        self.assertIn("http://nix-cache.lan:8080/nix/nix-cache-info", result.stderr)

    def test_invalid_roots_never_reach_network(self):
        for root in (
            "/etc/passwd", ROOT + "/bin", ROOT + ";id", ROOT + "\ninjected",
            "/nix/store/" + "e" * 32 + "-invalid-hash",
        ):
            with self.subTest(root=root):
                result = self.upload("bad", bad_root=root)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("CALL ssh", result.stderr)
                self.assertNotIn("CALL curl", result.stderr)

    def test_failures_before_export_never_publish(self):
        for failure in ("resolve", "validity", "lan", "preflight", "query"):
            with self.subTest(failure=failure):
                result = self.upload("result", fail=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn(f"p@nix-cache.lan nix-cache-stage {ID}", result.stderr)
                self.assertNotIn("sudo /run/current-system/sw/bin/nix-cache-publish", result.stderr)

    def test_failed_transfer_never_publishes_and_cleans_stage(self):
        for failure in ("export", "stage"):
            with self.subTest(failure=failure):
                result = self.upload("result", fail=failure)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("sudo /run/current-system/sw/bin/nix-cache-publish", result.stderr)
                self.assertIn(f"rm -f -- .local/state/nix-cache-upload/{ID}.nar", result.stderr)

    def test_publish_failure_is_not_hidden_by_cleanup(self):
        result = self.upload("result", fail="publish")
        self.assertEqual(result.returncode, 19)
        self.assertIn(f"rm -f -- .local/state/nix-cache-upload/{ID}.nar", result.stderr)

    def test_cleanup_failure_is_reported(self):
        result = self.upload("result", fail="cleanup")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Could not clean remote stage", result.stderr)

    def test_help_and_missing_arguments_do_not_use_network(self):
        for arguments, status in (((), 2), (("--help",), 0)):
            result = self.upload(*arguments)
            self.assertEqual(result.returncode, status)
            self.assertNotIn("CALL ssh", result.stderr)

    def test_build_preserves_arguments_and_uploads_only_outputs(self):
        result = self.run_script("nix-cache-build", ".#example", "--keep-going")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("CALL nix build --print-out-paths .#example --keep-going", result.stderr)
        self.assertIn(f"CALL upload {ROOT} {SECOND}", result.stderr)

    def test_failed_or_empty_build_never_uploads(self):
        for failure in ("build", "empty"):
            result = self.run_script("nix-cache-build", ".#example", fail=failure)
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn("CALL upload", result.stderr)

    def test_build_reports_upload_failure(self):
        result = self.run_script("nix-cache-build", ".#example", fail="upload")
        self.assertEqual(result.returncode, 22)


if __name__ == "__main__":
    unittest.main()
