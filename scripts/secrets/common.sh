#!/usr/bin/env bash
# Source only. Secret-bearing commands must never run with shell tracing.
set +x
set -euo pipefail
umask 077
SECRETS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SECRETS_SCRIPT_DIR}/../.." && pwd)"
KUBE_CONTEXT="${KUBE_CONTEXT:-kind-local-dind-cluster}"
if [[ "$KUBE_CONTEXT" != kind-local-dind-cluster ]]; then
  echo 'These helpers only operate on kind-local-dind-cluster.' >&2; exit 1
fi
SECRET_STATE_DIR="${SECRET_STATE_DIR:-${REPO_ROOT}/.local/secret-management/dev-cluster}"
export SECRET_STATE_DIR
# Reject symlinks before creating/chmodding directories; private state is never
# in either data-pool, because those are mounted into Kubernetes nodes.
python3 - <<'PY'
import os
import subprocess
from pathlib import Path
p = Path(os.environ['SECRET_STATE_DIR']).absolute()
if any(x.is_symlink() for x in (p, *p.parents)):
    raise SystemExit('Refusing symlink in private state path')
if any(x.name.startswith('data-pool-') for x in (p, *p.parents)):
    raise SystemExit('Recovery credentials must not be in a kind data pool')
missing = []
q = p
while not q.exists():
    missing.append(q)
    q = q.parent
p.mkdir(parents=True, exist_ok=True, mode=0o700)
for q in [p, *missing]:
    q.chmod(0o700)
for q in p.rglob('*'):
    if q.is_symlink():
        raise SystemExit('Refusing symlink inside private state directory')
    q.chmod(0o700 if q.is_dir() else 0o600)
inside = subprocess.run(['git', '-C', str(p), 'rev-parse', '--show-toplevel'], capture_output=True).returncode == 0
if inside and subprocess.run(['git', '-C', str(p), 'check-ignore', '-q', str(p / '.custody-probe')]).returncode != 0:
    raise SystemExit('Private state inside a Git repository must be gitignored')
PY
k() { kubectl --context "$KUBE_CONTEXT" "$@"; }
private_write() { python3 "${SECRETS_SCRIPT_DIR}/custody.py" write "$1"; }
ensure_namespace() { k create namespace "$1" --dry-run=client -o yaml | k apply --server-side --field-manager=secret-bootstrap -f - >/dev/null; }
