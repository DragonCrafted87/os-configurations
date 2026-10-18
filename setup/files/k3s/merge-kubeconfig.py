#!/usr/bin/env python3
"""Merge the k3s admin kubeconfig into a workstation or htpc file.

The server file is the admin credential k3s writes. This keeps every
other context, points the roost-drake cluster at the registration
address, and replaces that user with the server file's client
credential. It writes only when the result changed, and it prints
nothing from the credential.
"""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path

import yaml

CONTEXT = "roost-drake"


def _load(path: Path) -> dict:
    if not path.is_file() or path.stat().st_size == 0:
        return {}
    loaded = yaml.safe_load(path.read_text(encoding="utf-8"))
    if loaded is None:
        return {}
    if not isinstance(loaded, dict):
        raise SystemExit(f"error: {path} is not a kubeconfig mapping")
    return loaded


def _first_map(doc: dict, key: str, inner: str) -> dict:
    items = doc.get(key) or []
    if not items or not isinstance(items, list):
        raise SystemExit(f"error: server kubeconfig has no {key}")
    entry = items[0]
    if not isinstance(entry, dict) or not isinstance(entry.get(inner), dict):
        raise SystemExit(f"error: server kubeconfig has no {key}")
    return entry[inner]


def _upsert(items: list, name: str, body: dict) -> None:
    for entry in items:
        if isinstance(entry, dict) and entry.get("name") == name:
            entry.clear()
            entry.update(body)
            return
    items.append(body)


def merge(server: dict, dest: dict, server_url: str) -> dict:
    cluster = _first_map(server, "clusters", "cluster")
    user = _first_map(server, "users", "user")
    if not user.get("client-certificate-data") and not user.get("token"):
        raise SystemExit("error: server kubeconfig has no client credential")
    merged = {
        "apiVersion": dest.get("apiVersion") or "v1",
        "kind": dest.get("kind") or "Config",
        "clusters": list(dest.get("clusters") or []),
        "users": list(dest.get("users") or []),
        "contexts": list(dest.get("contexts") or []),
    }
    _upsert(
        merged["clusters"],
        CONTEXT,
        {
            "name": CONTEXT,
            "cluster": {
                "server": server_url,
                "certificate-authority-data": cluster.get("certificate-authority-data"),
            },
        },
    )
    _upsert(merged["users"], CONTEXT, {"name": CONTEXT, "user": dict(user)})
    _upsert(
        merged["contexts"],
        CONTEXT,
        {
            "name": CONTEXT,
            "context": {"cluster": CONTEXT, "user": CONTEXT},
        },
    )
    current = dest.get("current-context")
    merged["current-context"] = current or CONTEXT
    return merged


def _same(left: dict, right: dict) -> bool:
    return yaml.safe_dump(left, sort_keys=True) == yaml.safe_dump(right, sort_keys=True)


def write_if_changed(path: Path, doc: dict) -> None:
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    if path.is_file() and _same(_load(path), doc):
        os.chmod(path, 0o600)
        return
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".kube-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            yaml.safe_dump(doc, handle, sort_keys=False)
        os.chmod(tmp_name, 0o600)
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise
    os.chmod(path, 0o600)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--server", required=True, type=Path)
    parser.add_argument("--dest", required=True, type=Path)
    parser.add_argument("--server-url", required=True)
    args = parser.parse_args()
    merged = merge(_load(args.server), _load(args.dest), args.server_url)
    write_if_changed(args.dest, merged)
    return 0


if __name__ == "__main__":
    sys.exit(main())
