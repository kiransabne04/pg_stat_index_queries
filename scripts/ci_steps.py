#!/usr/bin/env python3
"""Print one CI job of .github/workflows/ci.yml as a bash script.

Used by scripts/ci-local.sh to run the workflow's own `run:` steps in a
container, so the local mirror can't drift from the workflow file.

    python3 scripts/ci_steps.py <workflow.yml> <job> <pg>

Supported subset (all that ci.yml uses): job-level `env`, a `matrix.pg`
value, `uses:` steps (skipped; checkout is done by the caller) and
`if: failure()` steps (run only after a failed step). Anything else is an
error, so a workflow change that needs more support fails loudly.
"""
import re
import shlex
import sys

import yaml


def subst(text, pg):
    def repl(m):
        expr = m.group(1).strip()
        if expr == "matrix.pg":
            return str(pg)
        sys.exit("ci_steps.py: unsupported expression ${{ %s }}" % expr)
    return re.sub(r"\$\{\{(.*?)\}\}", repl, text)


def main():
    path, job_name, pg = sys.argv[1], sys.argv[2], sys.argv[3]
    with open(path) as f:
        wf = yaml.safe_load(f)
    job = wf["jobs"][job_name]
    versions = [str(v) for v in job.get("strategy", {}).get("matrix", {}).get("pg", [])]
    if pg not in versions:
        sys.exit("ci_steps.py: job %s has no matrix entry pg=%s (has %s)"
                 % (job_name, pg, ", ".join(versions)))

    out = ["set -o pipefail", "failed=0"]
    for k, v in (job.get("env") or {}).items():
        out.append("export %s=%s" % (k, shlex.quote(subst(str(v), pg))))

    for step in job["steps"]:
        if "uses" in step:
            continue
        name = subst(step.get("name", "step"), pg)
        cond = step.get("if")
        if cond not in (None, "failure()"):
            sys.exit("ci_steps.py: unsupported if: %s" % cond)
        body = subst(step["run"], pg)
        # Same semantics as GitHub's default shell: bash -e -o pipefail.
        cmd = "bash --noprofile --norc -eo pipefail -c %s" % shlex.quote(body)
        if cond == "failure()":
            out.append('if [ "$failed" = 1 ]; then echo "::: %s"; %s; fi' % (name, cmd))
        else:
            out.append('if [ "$failed" = 0 ]; then echo "::: %s"; %s || { echo "::: FAILED: %s"; failed=1; }; fi'
                       % (name, cmd, name))
    out.append('exit "$failed"')
    print("\n".join(out))


if __name__ == "__main__":
    main()
