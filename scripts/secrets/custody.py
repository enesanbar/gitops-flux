"""Small, dependency-free primitives for host-only recovery state. No secret logging."""
import json
import os
from pathlib import Path
import sys
import tempfile


def write_private(path, text):
    path = Path(path).absolute()
    for entry in (path, *path.parents):
        if entry.is_symlink():
            raise ValueError("Refusing symlink in private state path")
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    path.parent.chmod(0o700)
    fd, temporary = tempfile.mkstemp(prefix=".pending-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def merge_keys(existing, incoming):
    result = {}
    for key in [*existing, *incoming]:
        name = key["metadata"]["name"]
        data = key.get("data", {})
        if not data.get("tls.key") or not data.get("tls.crt"):
            raise ValueError("Refusing incomplete TLS key")
        if name in result and result[name]["data"] != data:
            raise ValueError("Refusing to replace a historical key with different data")
        result[name] = {
            "apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/tls",
            "metadata": {"name": name, "namespace": "sealed-secrets", "labels": {
                "sealedsecrets.bitnami.com/sealed-secrets-key": "active"}},
            "data": {"tls.key": data["tls.key"], "tls.crt": data["tls.crt"]},
        }
    return list(result.values())


if __name__ == "__main__":
    action, filename = sys.argv[1:3]
    if action == "write":
        write_private(filename, sys.stdin.read())
    elif action == "merge":
        path = Path(filename)
        old = json.loads(path.read_text())["items"] if path.exists() else []
        incoming = json.load(sys.stdin)
        items = incoming["items"] if incoming["kind"] in ("List", "SecretList") else [incoming]
        merged = merge_keys(old, items)
        if not merged:
            raise SystemExit("No sealing keys available; initialize explicitly first")
        write_private(path, json.dumps({"apiVersion": "v1", "kind": "List", "items": merged}, indent=2) + "\n")
    else:
        raise SystemExit("Unknown custody action")
