"""Offline, stdlib-only contracts for the coordinator's workflow trust boundaries.

The helpers read only the workflows' deliberately narrow block-style YAML.
They are not a general YAML parser; unsupported shapes fail closed.
"""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]
CHECKOUT = "actions/checkout@fbc6f3992d24b796d5a048ff273f7fcc4a7b6c09"
INSTALLER = "DeterminateSystems/nix-installer-action@c5a866b6ab867e88becbed4467b93592bce69f8a"
GUARD_REPO = "github.repository == 'dc0d32/nixos'"
GUARD_REF = "github.ref == format('refs/heads/{0}', github.event.repository.default_branch)"
UNSET = "unset GITHUB_TOKEN GH_TOKEN NIX_CONFIG NIX_USER_CONF_FILES"
PURE_CHECK = "nix flake check --print-build-logs"
SCRIPT = "python3 -B scripts/promote-wezterm.py "
RUN_URL = (
    "https://github.com/dc0d32/nixos/actions/runs/"
    "${{ github.run_id }}/attempts/${{ github.run_attempt }}"
)


def fields(text, indent):
    """Split a block mapping at its immediate keys, retaining nested text."""
    result = {}
    key = None
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        depth = len(line) - len(line.lstrip(" "))
        if depth == indent:
            match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_-]*):(?: (.*))?", line[indent:])
            if not match or match[1] in result:
                raise ValueError("unsupported or duplicate mapping key: " + line)
            key = match[1]
            result[key] = (match[2] or "") + "\n"
        elif depth > indent and key is not None:
            result[key] += line + "\n"
        else:
            raise ValueError("unsupported mapping indentation: " + line)
    return result


def scalar(value):
    return value.strip().split(" #", 1)[0].strip().strip("\"'")


def expression(value):
    return " ".join(value.strip().removeprefix(">-").split())


def steps(text):
    chunks = []
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        if line.startswith("      - "):
            chunks.append("        " + line[8:] + "\n")
        elif line.startswith("        ") and chunks:
            chunks[-1] += line + "\n"
        else:
            raise ValueError("unsupported step syntax: " + line)
    return [fields(chunk, 8) for chunk in chunks]


def commands(step):
    value = step.get("run", "").strip()
    if value.startswith("|"):
        return "\n".join(line.strip() for line in value.splitlines()[1:])
    return value


def needs(job):
    value = scalar(job.get("needs", ""))
    if value.startswith("[") and value.endswith("]"):
        return {item.strip() for item in value[1:-1].split(",")}
    return {value} if value else set()


class Workflow:
    def __init__(self, filename):
        self.text = (ROOT / ".github/workflows" / filename).read_text()
        self.header = fields(self.text, 0)
        self.jobs = {
            name: fields(body, 4)
            for name, body in fields(self.header["jobs"], 2).items()
        }
        self.steps = {name: steps(job["steps"]) for name, job in self.jobs.items()}

    def permissions(self, name):
        block = self.jobs[name].get("permissions", self.header["permissions"])
        indent = 6 if "permissions" in self.jobs[name] else 2
        return {key: scalar(value) for key, value in fields(block, indent).items()}

    def step_with_command(self, name, command):
        matches = [step for step in self.steps[name] if command in commands(step)]
        if len(matches) != 1:
            raise ValueError(f"{name}: expected one step containing {command!r}")
        return matches[0]


class WeztermWorkflowContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.weekly = Workflow("update-flake-lock.yml")
        cls.promote = Workflow("promote-wezterm.yml")
        cls.workflows = (cls.weekly, cls.promote)

    def test_narrow_helpers_reject_duplicate_or_unsupported_yaml(self):
        for text in ("a: x\na: y\n", "a: x\nbad\n", "a: x\n - item\n"):
            with self.subTest(text=text):
                # Sequences at mapping indentation, tabs and flow keys are not
                # accepted; a nested sequence is retained for its own helper.
                if " - item" in text:
                    with self.assertRaises(ValueError):
                        steps(text)
                else:
                    with self.assertRaises(ValueError):
                        fields(text, 0)

    def test_only_schedule_and_manual_default_branch_entries(self):
        for workflow, cron in zip(self.workflows, ("0 6 * * 6", "43 * * * *")):
            self.assertEqual(set(workflow.header), {
                "name", "on", "concurrency", "permissions", "jobs",
            })
            triggers = fields(workflow.header["on"], 2)
            self.assertEqual(set(triggers), {"schedule", "workflow_dispatch"})
            self.assertEqual(triggers["workflow_dispatch"].strip(), "")
            self.assertEqual(triggers["schedule"].strip(), f'- cron: "{cron}"')
            for name, job in workflow.jobs.items():
                with self.subTest(job=name):
                    condition = expression(job["if"])
                    self.assertIn(GUARD_REPO, condition)
                    self.assertIn(GUARD_REF, condition)
                    self.assertNotIn("||", condition)
                    self.assertEqual(scalar(job["runs-on"]), "ubuntu-latest")

    def test_shared_non_cancelling_workflow_concurrency_preserves_pending_runs(self):
        for workflow in self.workflows:
            block = fields(workflow.header["concurrency"], 2)
            self.assertEqual({key: scalar(value) for key, value in block.items()}, {
                "group": "wezterm-update-flake-lock", "queue": "max",
                "cancel-in-progress": "false",
            })
            self.assertTrue(all("concurrency" not in job for job in workflow.jobs.values()))
            self.assertEqual(
                fields(workflow.header["permissions"], 2), {"contents": "read\n"},
            )

    def test_all_actions_are_allowlisted_exact_pins_and_credentials_never_persist(self):
        for workflow in self.workflows:
            for name, job_steps in workflow.steps.items():
                for step in job_steps:
                    if "uses" not in step:
                        continue
                    action = scalar(step["uses"])
                    with self.subTest(job=name, action=action):
                        self.assertIn(action, {CHECKOUT, INSTALLER})
                        if action == CHECKOUT:
                            self.assertTrue(step["uses"].strip().endswith("# v5"))
                            settings = fields(step["with"], 10)
                            self.assertEqual(scalar(settings["persist-credentials"]), "false")
                            self.assertIn("ref", settings)
                            self.assertNotIn("token", settings)
                            self.assertLessEqual(set(settings), {"ref", "path", "persist-credentials"})

    def test_installer_uses_existing_caches_and_rejects_flake_configuration(self):
        existing = (ROOT / ".github/workflows/flake-check.yml").read_text()
        cache_lines = re.findall(r"^\s*(extra-(?:substituters|trusted-public-keys) = .+)$",
                                 existing, re.MULTILINE)
        self.assertEqual(len(cache_lines), 2)
        for workflow in self.workflows:
            for job_steps in workflow.steps.values():
                for step in job_steps:
                    if scalar(step.get("uses", "")) == INSTALLER:
                        settings = fields(step["with"], 10)
                        self.assertEqual(set(settings), {"extra-conf", "github-token"})
                        self.assertEqual(scalar(settings["github-token"]), "")
                        config = settings["extra-conf"]
                        for line in cache_lines:
                            self.assertIn(line, config)
                        self.assertIn("accept-flake-config = false", config)

    def test_writable_jobs_have_only_trusted_checkouts_and_no_nix_or_candidate(self):
        expected = (
            (self.weekly, "seed", {"publish-weekly", "status-pending", "report"}),
            (self.promote, "inspect", {
                "pending", "report-precheck", "publish", "pending-final", "report-final",
            }),
        )
        for workflow, discovery, writers in expected:
            actual = {
                name for name in workflow.jobs
                if "write" in workflow.permissions(name).values()
            }
            self.assertEqual(actual, writers)
            for name in writers:
                with self.subTest(job=name):
                    job = workflow.jobs[name]
                    self.assertIn(discovery, needs(job))
                    checkouts = [
                        step for step in workflow.steps[name]
                        if scalar(step.get("uses", "")) == CHECKOUT
                    ]
                    self.assertEqual(len(checkouts), 1)
                    settings = fields(checkouts[0]["with"], 10)
                    self.assertEqual(
                        scalar(settings["ref"]),
                        "${{ needs." + discovery + ".outputs.default_sha }}",
                    )
                    self.assertNotIn("path", settings)
                    self.assertNotIn(INSTALLER, job["steps"])
                    self.assertNotIn("candidate", job["steps"])
                    for step in workflow.steps[name]:
                        self.assertNotRegex(commands(step), r"\bnix\b")
                        self.assertNotIn("working-directory", step)
                    if name.startswith(("report", "pending", "status")):
                        self.assertEqual(workflow.permissions(name), {
                            "contents": "read", "statuses": "write",
                        })
                    elif name == "publish-weekly":
                        self.assertEqual(workflow.permissions(name), {
                            "contents": "write", "pull-requests": "write",
                        })
                    else:
                        self.assertEqual(workflow.permissions(name), {"contents": "write"})

    def test_tokens_are_step_scoped_and_only_trusted_own_repository_commands(self):
        for workflow in self.workflows:
            self.assertNotIn("env", workflow.header)
            self.assertNotIn("secrets.", workflow.text)
            self.assertNotIn("GH_TOKEN:", workflow.text)
            for name, job in workflow.jobs.items():
                self.assertNotIn("env", job)
                for step in workflow.steps[name]:
                    run = commands(step)
                    self.assertNotIn("${{", run)
                    if "python3" in run:
                        self.assertRegex(run, r"python3 -B scripts/(promote-wezterm|wezterm-request)\.py ")
                        self.assertNotIn("candidate/scripts", run)
                    environment = fields(step.get("env", ""), 10)
                    if "GITHUB_TOKEN" in environment:
                        self.assertEqual(scalar(environment["GITHUB_TOKEN"]), "${{ github.token }}")
                        self.assertRegex(run, r"^python3 -B scripts/promote-wezterm\.py "
                                         r"(seed|inspect|publish-weekly|publish|status)\b|^state=failure\n")
                        if run.startswith("state="):
                            self.assertIn(SCRIPT + "status ", run)
                        self.assertNotIn(UNSET, run)
                    elif run:
                        self.assertNotRegex(run, r"\b(seed|inspect|publish-weekly|publish|status) --")

    def test_discovery_captures_event_sha_and_exposes_only_documented_outputs(self):
        for workflow, name, outputs in (
            (self.weekly, "seed", {"head", "default_sha"}),
            (self.promote, "inspect", {"eligible", "head", "default_sha", "request", "plan"}),
        ):
            self.assertEqual(workflow.permissions(name), {"contents": "read"})
            self.assertFalse(needs(workflow.jobs[name]))
            checkout, discover = workflow.steps[name]
            self.assertEqual(scalar(fields(checkout["with"], 10)["ref"]), "${{ github.sha }}")
            self.assertEqual(commands(discover), SCRIPT + name + ' --output "$GITHUB_OUTPUT"')
            metadata = fields(workflow.jobs[name]["outputs"], 6)
            self.assertEqual(set(metadata), outputs)
            for key, value in metadata.items():
                self.assertEqual(scalar(value), "${{ steps." + name + ".outputs." + key + " }}")

    def test_preparation_is_token_free_and_separate_from_candidate_builds(self):
        for workflow, discovery in ((self.weekly, "seed"), (self.promote, "inspect")):
            job = workflow.jobs["prepare"]
            self.assertEqual(needs(job), {discovery})
            self.assertEqual(workflow.permissions("prepare"), {"contents": "read"})
            self.assertGreaterEqual(int(scalar(job["timeout-minutes"])), 180)
            self.assertEqual(fields(job["outputs"], 6), {
                "proposal": "${{ steps.prepare.outputs.proposal }}\n",
            })
            checkouts = workflow.steps["prepare"][:2]
            self.assertEqual(
                scalar(fields(checkouts[0]["with"], 10)["ref"]),
                "${{ needs." + discovery + ".outputs.default_sha }}",
            )
            candidate = fields(checkouts[1]["with"], 10)
            self.assertEqual(scalar(candidate["path"]), "candidate")
            self.assertEqual(scalar(candidate["ref"]), "${{ needs." + discovery + ".outputs.head }}")
            run = commands(workflow.step_with_command("prepare", "--output"))
            self.assertTrue(run.startswith(UNSET + "\n"))
            self.assertNotIn(PURE_CHECK, run)
            if discovery == "seed":
                self.assertEqual(run.splitlines()[1],
                                 'python3 -B scripts/wezterm-request.py weekly '
                                 '--workdir candidate --output "$GITHUB_OUTPUT"')
            else:
                self.assertEqual(run.splitlines()[1], SCRIPT + "prepare --candidate candidate "
                                 '--plan-b64 "$PLAN_B64" --output "$GITHUB_OUTPUT"')
                self.assertNotRegex(run, r"\bnix\b")
                self.assertNotIn("working-directory", workflow.steps["prepare"][-1])

    def test_all_native_checks_are_exact_pure_token_free_and_read_only(self):
        checks = (
            (self.weekly, {"check": "publish-weekly"}),
            (self.promote, {
                "precheck": "inspect", "proposal-check": "inspect", "final-check": "publish",
            }),
        )
        for workflow, jobs in checks:
            actual = {
                name for name, job_steps in workflow.steps.items()
                if any("nix flake check" in commands(step) for step in job_steps)
            }
            self.assertEqual(actual, set(jobs))
            for name, source in jobs.items():
                with self.subTest(job=name):
                    job = workflow.jobs[name]
                    self.assertEqual(workflow.permissions(name), {"contents": "read"})
                    self.assertNotIn("outputs", job)
                    self.assertGreaterEqual(int(scalar(job["timeout-minutes"])), 180)
                    check = workflow.step_with_command(name, "nix flake check")
                    self.assertEqual(commands(check), UNSET + "\n" + PURE_CHECK)
                    self.assertEqual(scalar(check["working-directory"]), "candidate")
                    self.assertNotIn("env", check)
                    self.assertIn("/opt/hostedtoolcache /usr/local/lib/android "
                                  "/usr/share/dotnet /usr/local/.ghcup", job["steps"])
                    candidates = [
                        fields(step["with"], 10)
                        for step in workflow.steps[name]
                        if scalar(step.get("uses", "")) == CHECKOUT
                        and "path" in fields(step["with"], 10)
                    ]
                    self.assertEqual(len(candidates), 1)
                    self.assertEqual(scalar(candidates[0]["path"]), "candidate")
                    self.assertEqual(scalar(candidates[0]["ref"]),
                                     "${{ needs." + source + ".outputs.head }}")
                    self.assertNotIn("continue-on-error", job["steps"])
                    unchanged = workflow.step_with_command(name, "diff ")
                    base = "" if name == "proposal-check" else "HEAD "
                    self.assertEqual(commands(unchanged), UNSET + "\n"
                                     "git -c core.hooksPath=/dev/null -C candidate diff "
                                     + base + "--exit-code -- flake.nix flake.lock overlays/wezterm-pin.nix")
                    self.assertGreater(workflow.steps[name].index(unchanged),
                                       workflow.steps[name].index(check))
            self.assertNotIn("--impure", workflow.text)
            self.assertNotIn("NIXOS_ALLOW_PLACEHOLDER", workflow.text)

    def test_materialization_uses_isolated_output_and_never_exports_build_metadata(self):
        job = self.promote.jobs["proposal-check"]
        materialize = self.promote.step_with_command("proposal-check", "materialize --")
        self.assertEqual(fields(materialize["env"], 10), {
            "PROPOSAL_B64": "${{ needs.prepare.outputs.proposal }}\n",
        })
        self.assertEqual(commands(materialize).splitlines(), [
            UNSET,
            SCRIPT + 'materialize --candidate candidate --proposal-b64 "$PROPOSAL_B64"',
            "git -c core.hooksPath=/dev/null -C candidate add "
            "overlays/wezterm-pin.nix flake.nix flake.lock",
        ])
        self.assertNotIn("--output", commands(materialize))
        self.assertNotIn("GITHUB_OUTPUT", job["steps"])
        self.assertNotIn("outputs", job)
        job_steps = self.promote.steps["proposal-check"]
        self.assertLess(job_steps.index(materialize),
                        job_steps.index(self.promote.step_with_command("proposal-check", PURE_CHECK)))
        for workflow in self.workflows:
            self.assertNotRegex(workflow.text, r"\bgit (?:commit|push)\b|\bmktemp\b|/tmp/")

    def test_publishers_consume_only_isolated_preparation_and_inspection_metadata(self):
        for workflow, name, discovery in (
            (self.weekly, "publish-weekly", "seed"),
            (self.promote, "publish", "inspect"),
        ):
            publish = workflow.step_with_command(name, SCRIPT + name + " ")
            environment = fields(publish["env"], 10)
            self.assertEqual(scalar(environment["PROPOSAL_B64"]), "${{ needs.prepare.outputs.proposal }}")
            if name == "publish":
                self.assertEqual(scalar(environment["PLAN_B64"]), "${{ needs.inspect.outputs.plan }}")
                expected = SCRIPT + 'publish --plan-b64 "$PLAN_B64" --proposal-b64 "$PROPOSAL_B64"'
            else:
                expected = SCRIPT + 'publish-weekly --proposal-b64 "$PROPOSAL_B64"'
            self.assertEqual(commands(publish), expected + ' --output "$GITHUB_OUTPUT"')
            self.assertEqual(fields(workflow.jobs[name]["outputs"], 6), {
                "head": "${{ steps.publish.outputs.head }}\n",
            })
            for key, value in environment.items():
                if key != "GITHUB_TOKEN":
                    self.assertRegex(value, r"^\$\{\{ needs\.(prepare|inspect)\.outputs\.")
            self.assertIn(discovery, needs(workflow.jobs[name]))

    def test_pending_status_precedes_each_exact_head_check(self):
        for workflow, pending, check, source in (
            (self.weekly, "status-pending", "check", "publish-weekly"),
            (self.promote, "pending", "precheck", "inspect"),
            (self.promote, "pending-final", "final-check", "publish"),
        ):
            self.assertIn(pending, needs(workflow.jobs[check]))
            self.assertIn(source, needs(workflow.jobs[pending]))
            self.assertNotIn("always()", expression(workflow.jobs[check]["if"]))
            status = workflow.step_with_command(pending, "status --")
            environment = fields(status["env"], 10)
            self.assertEqual(scalar(environment["HEAD"]), "${{ needs." + source + ".outputs.head }}")
            self.assertEqual(scalar(environment["RUN_URL"]), RUN_URL)
            self.assertIn('--head "$HEAD" --state pending', commands(status))
            self.assertNotIn("success", commands(status))

    def test_reports_always_report_known_head_and_only_its_actual_check_result(self):
        for workflow, report, check, source in (
            (self.weekly, "report", "check", "publish-weekly"),
            (self.promote, "report-precheck", "precheck", "inspect"),
            (self.promote, "report-final", "final-check", "publish"),
        ):
            job = workflow.jobs[report]
            condition = expression(job["if"])
            self.assertTrue(condition.startswith("always() &&"))
            self.assertIn("needs." + source + ".outputs.head != ''", condition)
            self.assertIn(check, needs(job))
            status = workflow.step_with_command(report, "status --")
            environment = fields(status["env"], 10)
            self.assertEqual(scalar(environment["HEAD"]), "${{ needs." + source + ".outputs.head }}")
            self.assertEqual(scalar(environment["CHECK_RESULT"]), "${{ needs." + check + ".result }}")
            self.assertEqual(scalar(environment["RUN_URL"]), RUN_URL)
            self.assertEqual(commands(status).splitlines()[:2], [
                "state=failure",
                'if [ "$CHECK_RESULT" = success ]; then state=success; fi',
            ])
            self.assertIn('--state "$state"', commands(status))
            self.assertNotIn("proposal-check", job["steps"])

    def test_dependency_graph_and_both_checks_gate_promotion(self):
        for workflow in self.workflows:
            for name, job in workflow.jobs.items():
                self.assertLessEqual(needs(job), set(workflow.jobs))
                self.assertNotIn(name, needs(job))
                for referenced in re.findall(r"needs\.([a-z-]+)\.", job["steps"] + job.get("if", "")):
                    self.assertIn(referenced, needs(job))
        self.assertEqual(needs(self.weekly.jobs["publish-weekly"]), {"seed", "prepare"})
        self.assertEqual(needs(self.weekly.jobs["check"]), {"publish-weekly", "status-pending"})
        self.assertEqual(needs(self.promote.jobs["proposal-check"]), {
            "inspect", "prepare", "precheck", "report-precheck",
        })
        publish = self.promote.jobs["publish"]
        self.assertEqual(needs(publish), {
            "inspect", "prepare", "precheck", "proposal-check", "report-precheck",
        })
        condition = expression(publish["if"])
        self.assertNotIn("always()", condition)
        self.assertIn("needs.precheck.result == 'success'", condition)
        self.assertIn("needs.proposal-check.result == 'success'", condition)
        for name in ("prepare", "pending", "precheck", "proposal-check", "publish"):
            self.assertIn("needs.inspect.outputs.eligible == 'true'",
                          expression(self.promote.jobs[name]["if"]))
        self.assertEqual(needs(self.promote.jobs["final-check"]), {"publish", "pending-final"})


if __name__ == "__main__":
    unittest.main()
