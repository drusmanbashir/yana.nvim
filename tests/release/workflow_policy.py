#!/usr/bin/env python3
import json
import pathlib
import re
import sys


def fail(message: str) -> None:
    raise SystemExit(f"WORKFLOW POLICY FAIL: {message}")


root = pathlib.Path(sys.argv[1]).resolve()
ci = json.loads((root / ".github/workflows/ci.yml").read_text())
release = json.loads((root / ".github/workflows/release.yml").read_text())

if ci.get("permissions") != {"contents": "read"}:
    fail("CI permissions must be contents: read only")
if set(ci.get("on", {})) != {"pull_request", "push"}:
    fail("CI must run only on pull_request and push")
if release.get("permissions") != {"contents": "write"}:
    fail("release permissions must be contents: write only")
release_events = release.get("on", {})
if set(release_events) != {"push"} or not release_events["push"].get("tags"):
    fail("release workflow must be tag-push bound")


# Any spelling of the secrets context: dotted, indexed, or passed to a
# function such as toJSON. `secrets.`-only matching missed the last two.
SECRETS_CONTEXT = re.compile(r"\bsecrets\b", re.IGNORECASE)


def inspect_steps(workflow: dict, name: str) -> None:
    for job_name, job in workflow.get("jobs", {}).items():
        # Authority may live only at workflow level: a job that carries its
        # own permissions, secrets, or a reusable-workflow reference escapes
        # the top-level policy checked above.
        for forbidden_key in ("uses", "secrets", "permissions"):
            if forbidden_key in job:
                fail(f"{name}/{job_name} declares job-level {forbidden_key}")
        for step in job.get("steps", []):
            use = step.get("uses")
            if use:
                match = re.fullmatch(r"actions/checkout@([0-9a-f]{40})", use)
                if not match:
                    fail(f"{name}/{job_name} has unpinned or unapproved action: {use}")
        if SECRETS_CONTEXT.search(json.dumps(job)):
            fail(f"{name}/{job_name} references the secrets context")


inspect_steps(ci, "ci")
inspect_steps(release, "release")
release_text = json.dumps(release)
if "--prerelease" not in release_text or "GITHUB_REF_NAME == *-*" not in release_text:
    fail("release workflow does not distinguish prerelease tags from stable tags")
# The classification must be the exact affirmative conditional: a negated test
# (rc released as stable and stable as prerelease) still contains both
# substrings above, so pin the canonical line and reject any negation of it.
if "if [[ $GITHUB_REF_NAME == *-* ]]; then status+=(--prerelease); fi" not in release_text:
    fail("release workflow prerelease classification is not the canonical affirmative conditional")
if "! [[ $GITHUB_REF_NAME == *-* ]]" in release_text or "!= *-*" in release_text:
    fail("release workflow prerelease classification is negated")
print("WORKFLOW POLICY PASS")
