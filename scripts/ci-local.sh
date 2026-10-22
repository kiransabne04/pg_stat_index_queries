#!/usr/bin/env bash
# Run the GitHub Actions CI jobs locally in Docker, without GitHub or act.
#
#   scripts/ci-local.sh                 # every job x every PG version
#   scripts/ci-local.sh native 17       # one job, one version
#   CI_PLATFORM=linux/arm64 scripts/ci-local.sh   # native arch (faster on Apple Silicon)
#   CI_WORKTREE=1 scripts/ci-local.sh native 18    # include uncommitted changes
#
# Each run starts from a clean ubuntu:24.04 container (the runner image the
# workflow uses), clones the committed HEAD (like actions/checkout, so
# uncommitted changes are NOT tested unless CI_WORKTREE=1), and executes the workflow's own `run:`
# steps as a non-root user with passwordless sudo, like a GitHub runner.
# Steps come from .github/workflows/ci.yml via scripts/ci_steps.py.
#
# Default platform is linux/amd64 to match GitHub's runners; on Apple Silicon
# that runs under emulation and is several times slower.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
platform=${CI_PLATFORM:-linux/amd64}
logdir=${CI_LOG_DIR:-$repo/ci-local-logs}
mkdir -p "$logdir"

if [ $# -ge 1 ]; then
	runs=("$1:${2:?usage: ci-local.sh [job pg]}")
else
	runs=(native:15 native:16 native:17 native:18 sql-edition:16 sql-edition:17 sql-edition:18)
fi

# Runner-like base image: ubuntu:24.04 plus the tools a GitHub runner already has.
image=pgsiq-ci-runner:${platform//\//-}
docker build -q --platform "$platform" -t "$image" - >/dev/null <<'EOF'
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      sudo git ca-certificates curl gnupg lsb-release build-essential python3 python3-yaml \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m runner && echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner
ENV DEBIAN_FRONTEND=noninteractive
USER runner
EOF

status=0
for run in "${runs[@]}"; do
	job=${run%%:*}
	pg=${run##*:}
	log=$logdir/$job-pg$pg.log
	start=$(date +%s)
	if docker run --rm --platform "$platform" -v "$repo":/repo:ro "$image" bash -c '
			set -e
			git config --global --add safe.directory "*"
			git clone -q /repo "$HOME/work" && cd "$HOME/work"
			echo "::: checkout $(git rev-parse --short HEAD)"
			if [ "$3" = 1 ]; then
				echo "::: overlaying working tree (CI_WORKTREE=1)"
				(cd /repo && git ls-files -co --exclude-standard -z | tar --null -cf - -T -) | tar -xf -
			fi
			python3 /repo/scripts/ci_steps.py .github/workflows/ci.yml "$1" "$2" > /tmp/steps.sh
			bash /tmp/steps.sh' _ "$job" "$pg" "${CI_WORKTREE:-0}" >"$log" 2>&1; then
		result=PASS
	else
		result=FAIL
		status=1
	fi
	printf '%-12s PG %-3s %s  (%ss, log: %s)\n' "$job" "$pg" "$result" $(( $(date +%s) - start )) "$log"
done
exit $status
