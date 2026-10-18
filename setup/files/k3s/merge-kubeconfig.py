#!/usr/bin/env python3
"""Merge the k3s admin kubeconfig into a workstation or htpc file.

The server file is the admin credential k3s writes. This keeps every
other context, points the roost-drake cluster at the registration
address, and replaces that user with the server file's client
credential. It writes only when the result changed, and it prints
nothing from the credential.

The parser is the standard library. An HTPC role run does not have
PyYAML installed.
"""

from __future__ import annotations

import argparse
import os
import sys
import tempfile
from pathlib import Path

CONTEXT = "roost-drake"


def _scalar(text: str):
    text = text.strip()
    if text in ("", "~", "null", "Null", "NULL"):
        return None
    if text == "{}":
        return {}
    if text == "[]":
        return []
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        return text[1:-1]
    return text


def _lines(text: str) -> list[tuple[int, str]]:
    parsed = []
    for raw in text.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(raw) - len(raw.lstrip(" "))
        parsed.append((indent, stripped))
    return parsed


class _Parser:
    def __init__(self, lines: list[tuple[int, str]]) -> None:
        self.lines = lines
        self.index = 0

    def peek(self) -> tuple[int, str] | None:
        if self.index >= len(self.lines):
            return None
        return self.lines[self.index]

    def parse(self):
        value = self.parse_next()
        if self.peek() is not None:
            raise SystemExit("error: kubeconfig has trailing data")
        return value if value is not None else {}

    def parse_next(self):
        peeked = self.peek()
        if peeked is None:
            return None
        if peeked[1].startswith("- "):
            return self.parse_list(peeked[0])
        return self.parse_dict(peeked[0])

    def parse_dict(self, indent: int) -> dict:
        result: dict = {}
        while True:
            peeked = self.peek()
            if peeked is None or peeked[0] != indent or peeked[1].startswith("- "):
                break
            self.index += 1
            key, rest = _split_key(peeked[1])
            if rest == "":
                result[key] = self.parse_next()
            else:
                result[key] = _scalar(rest)
        return result

    def parse_list(self, indent: int) -> list:
        result = []
        while True:
            peeked = self.peek()
            if peeked is None or peeked[0] != indent or not peeked[1].startswith("- "):
                break
            self.index += 1
            content = peeked[1][2:]
            if content == "":
                result.append(self.parse_next())
                continue
            if ":" not in content:
                result.append(_scalar(content))
                continue
            key, rest = _split_key(content)
            item: dict = {}
            if rest == "":
                item[key] = self.parse_next()
            else:
                item[key] = _scalar(rest)
            item.update(self.parse_dict(indent + 2))
            result.append(item)
        return result


def _split_key(text: str) -> tuple[str, str]:
    if ":" not in text:
        raise SystemExit("error: kubeconfig line has no key")
    key, _, rest = text.partition(":")
    return key.strip(), rest.strip()


def load_kubeconfig(text: str):
    if not text.strip():
        return {}
    loaded = _Parser(_lines(text)).parse()
    if not isinstance(loaded, dict):
        raise SystemExit("error: kubeconfig is not a mapping")
    return loaded


def dump_kubeconfig(obj, indent: int = 0) -> list[str]:
    pad = " " * indent
    lines: list[str] = []
    if isinstance(obj, dict):
        for key, value in obj.items():
            if isinstance(value, (dict, list)):
                lines.append(f"{pad}{key}:")
                lines.extend(dump_kubeconfig(value, indent + 2))
            elif value is None:
                lines.append(f"{pad}{key}:")
            else:
                lines.append(f"{pad}{key}: {value}")
        return lines
    if isinstance(obj, list):
        for item in obj:
            if not isinstance(item, dict) or not item:
                lines.append(f"{pad}- {item if item is not None else ''}")
                continue
            pairs = list(item.items())
            first_key, first_value = pairs[0]
            if isinstance(first_value, (dict, list)):
                lines.append(f"{pad}- {first_key}:")
                lines.extend(dump_kubeconfig(first_value, indent + 4))
            elif first_value is None:
                lines.append(f"{pad}- {first_key}:")
            else:
                lines.append(f"{pad}- {first_key}: {first_value}")
            for key, value in pairs[1:]:
                if isinstance(value, (dict, list)):
                    lines.append(f"{pad}  {key}:")
                    lines.extend(dump_kubeconfig(value, indent + 4))
                elif value is None:
                    lines.append(f"{pad}  {key}:")
                else:
                    lines.append(f"{pad}  {key}: {value}")
        return lines
    raise SystemExit("error: kubeconfig value cannot be written")


def _load(path: Path) -> dict:
    if not path.is_file() or path.stat().st_size == 0:
        return {}
    return load_kubeconfig(path.read_text(encoding="utf-8"))


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


def _canonical(doc: dict) -> str:
    return "\n".join(dump_kubeconfig(doc)) + "\n"


def write_if_changed(path: Path, doc: dict) -> None:
    path.parent.mkdir(parents=True, mode=0o700, exist_ok=True)
    rendered = _canonical(doc)
    if path.is_file() and _canonical(_load(path)) == rendered:
        os.chmod(path, 0o600)
        return
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".kube-")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(rendered)
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
