#!/usr/bin/env python3
"""Prepare a source tree for OpenMandriva GCC 14.

Rock's libstdc++ has no vector::append_range or insert_range, and GCC 14
has no #embed. pci.h on this distro is also missing extern "C".
"""

from __future__ import annotations

import pathlib
import re
import sys

SUFFIXES = {".c", ".cc", ".cpp", ".cxx", ".h", ".hpp"}


def sources(root: pathlib.Path):
    for path in root.rglob("*"):
        if path.suffix not in SUFFIXES:
            continue
        if "build" in path.parts:
            continue
        yield path


def walk_ident(text: str, j: int) -> tuple[str, int]:
    k = j
    while k > 0 and (text[k - 1].isalnum() or text[k - 1] in "._"):
        k -= 1
    return text[k:j], k


def take_parens(text: str, p: int) -> tuple[str, int]:
    depth = 1
    start = p
    while p < len(text) and depth:
        if text[p] == "(":
            depth += 1
        elif text[p] == ")":
            depth -= 1
        p += 1
    return text[start : p - 1], p


def rewrite_append(text: str) -> tuple[str, int]:
    key = ".append_range("
    out: list[str] = []
    i = 0
    n = 0
    while True:
        j = text.find(key, i)
        if j < 0:
            out.append(text[i:])
            break
        obj, k = walk_ident(text, j)
        arg, p = take_parens(text, j + len(key))
        out.append(text[i:k])
        out.append(
            "{ auto&& _hypr_r = ("
            + arg
            + f"); {obj}.insert({obj}.end(), std::ranges::begin(_hypr_r), std::ranges::end(_hypr_r)); }}"
        )
        n += 1
        if p < len(text) and text[p] == ";":
            p += 1
        i = p
    return "".join(out), n


def rewrite_insert(text: str) -> tuple[str, int]:
    key = ".insert_range("
    out: list[str] = []
    i = 0
    n = 0
    while True:
        j = text.find(key, i)
        if j < 0:
            out.append(text[i:])
            break
        obj, k = walk_ident(text, j)
        args, p = take_parens(text, j + len(key))
        depth = 0
        comma = -1
        for idx, ch in enumerate(args):
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
            elif ch == "," and depth == 0:
                comma = idx
                break
        if comma < 0:
            out.append(text[i:p])
            i = p
            continue
        pos = args[:comma].strip()
        rng = args[comma + 1 :].strip()
        out.append(text[i:k])
        out.append(
            "{ auto&& _hypr_r = ("
            + rng
            + f"); {obj}.insert({pos}, std::ranges::begin(_hypr_r), std::ranges::end(_hypr_r)); }}"
        )
        n += 1
        if p < len(text) and text[p] == ";":
            p += 1
        i = p
    return "".join(out), n


def rewrite_ranges(root: pathlib.Path) -> None:
    for path in sources(root):
        text = path.read_text(encoding="utf-8", errors="replace")
        if ".append_range(" not in text and ".insert_range(" not in text:
            continue
        new, n_append = rewrite_append(text)
        new, n_insert = rewrite_insert(new)
        if n_append + n_insert == 0:
            continue
        if "#include <ranges>" not in new:
            new = re.sub(
                r"((?:^#include[^\n]*\n)+)",
                r"\1#include <ranges>\n",
                new,
                count=1,
                flags=re.M,
            )
        path.write_text(new, encoding="utf-8")
        print(f"patched {n_append} append_range {n_insert} insert_range in {path}")


def rewrite_embed(root: pathlib.Path) -> None:
    embed = re.compile(r'^#embed\s+"([^"]+)"\s*$', re.M)
    for path in sources(root):
        text = path.read_text(encoding="utf-8", errors="replace")
        if "#embed" not in text:
            continue

        def repl(match: re.Match[str]) -> str:
            target = (path.parent / match.group(1)).resolve()
            if not target.is_file():
                raise SystemExit(f"#embed missing file {target} from {path}")
            return ", ".join(str(b) for b in target.read_bytes())

        new, n = embed.subn(repl, text)
        if n:
            path.write_text(new, encoding="utf-8")
            print(f"expanded {n} #embed in {path}")


def wrap_pci(root: pathlib.Path) -> None:
    for path in sources(root):
        text = path.read_text(encoding="utf-8", errors="replace")
        if "#include <pci/pci.h>" not in text or 'extern "C"' in text:
            continue
        new = text.replace(
            "#include <pci/pci.h>",
            'extern "C" {\n#include <pci/pci.h>\n}',
            1,
        )
        path.write_text(new, encoding="utf-8")
        print(f"wrapped pci.h in {path}")


def main() -> None:
    root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
    rewrite_ranges(root)
    rewrite_embed(root)
    wrap_pci(root)


if __name__ == "__main__":
    main()
