#!/usr/bin/env python3
"""Walk saved machine roles over SSH.

The Fabric package is imported only by connection_class(), and only after
this file's directory is off sys.path. A plain import would load this
script again, because the script is also named fabric.py.
"""

import argparse
import importlib
import importlib.util
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

CHECKOUTS = "~/.config/dot-files/checkouts"
VENV = Path.home() / ".local" / "share" / "machine-setup" / "control-venv"


def _inventory_module():
    path = Path(__file__).resolve().parent / "inventory.py"
    spec = importlib.util.spec_from_file_location("control_inventory", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


INVENTORY = _inventory_module()


class WalkError(Exception):
    """The walk cannot continue. The message names the section or path."""


class CheckoutFacts:
    """What one remote git checkout looked like. No command is run here."""

    def __init__(self, path, missing=False, work_tree=True, detached=False, porcelain=""):
        self.path = path
        self.missing = missing
        self.work_tree = work_tree
        self.detached = detached
        self.porcelain = porcelain


class Probe:
    """Facts collected for one host before any pull or role command."""

    def __init__(self, error, dot, setup, role_missing):
        self.error = error
        self.dot = dot
        self.setup = setup
        self.role_missing = role_missing


class Actions:
    """Lines to print, commands to run, and a stopping error."""

    def __init__(self, preview, commands, error):
        self.preview = preview
        self.commands = commands
        self.error = error


def short_name(value):
    return value.strip().split(".", 1)[0].lower()


def local_short_name():
    import socket

    return short_name(socket.gethostname())


def is_local(record, local_short):
    return short_name(record.name) == local_short or short_name(record.host) == local_short


def hosts_for_walk(records, requested, local_short, include_self):
    """Hosts this command will contact. Local hosts are omitted."""
    by_name = {}
    for record in records:
        by_name[record.name] = record
    if requested:
        chosen = []
        for name in requested:
            record = by_name.get(name)
            if record is None:
                raise WalkError(f"unknown section {name}")
            if record.status != "in":
                raise WalkError(f"{name}: status is out")
            if is_local(record, local_short) and not include_self:
                raise WalkError(f"{name}: local host")
            chosen.append(record)
        return chosen
    chosen = []
    for record in records:
        if record.status != "in":
            continue
        if is_local(record, local_short) and not include_self:
            continue
        chosen.append(record)
    return chosen


def pull_command(path):
    return f"git -C {shlex.quote(path)} pull --ff-only"


def role_script(setup_path):
    return f"{setup_path}/setup/role.sh"


def checkout_error(facts):
    if facts.missing:
        return f"missing {facts.path}"
    if not facts.work_tree:
        return f"not a git work tree {facts.path}"
    if facts.detached:
        return f"detached HEAD {facts.path}"
    if facts.porcelain.strip():
        return f"dirty {facts.path}"
    return None


def plan_actions(mode, probe):
    """Build the remote steps. This function does not run them."""
    if probe.error:
        return Actions([], [], probe.error)
    for facts in (probe.dot, probe.setup):
        error = checkout_error(facts)
        if error:
            return Actions([], [], error)
    script = role_script(probe.setup.path)
    if probe.role_missing:
        return Actions([], [], f"missing {script}")
    quoted = shlex.quote(script)
    preview = [pull_command(probe.dot.path), pull_command(probe.setup.path)]
    if mode == "dry-run":
        return Actions(preview, [f"{quoted} --dry-run"], None)
    if mode == "apply":
        return Actions([], preview + [quoted], None)
    raise WalkError(f"unknown command {mode}")


def parse_checkouts(text):
    found = {}
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if "=" not in line:
            raise WalkError(f"bad line in {CHECKOUTS}")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if key not in ("dot-files", "machine-setup"):
            raise WalkError(f"unknown key {key} in {CHECKOUTS}")
        if not value.startswith("/"):
            raise WalkError(f"relative path in {CHECKOUTS}: {key}")
        found[key] = value
    if "dot-files" not in found or "machine-setup" not in found:
        raise WalkError(f"missing dot-files or machine-setup in {CHECKOUTS}")
    return found["dot-files"], found["machine-setup"]


def _run(conn, command):
    return conn.run(command, pty=False, warn=True, hide=True)


def probe_checkout(conn, path):
    quoted = shlex.quote(path)
    exists = _run(conn, f"test -d {quoted}")
    if exists.exited != 0:
        return CheckoutFacts(path, missing=True, work_tree=False)
    work = _run(conn, f"git -C {quoted} rev-parse --is-inside-work-tree")
    if work.exited != 0 or (work.stdout or "").strip() != "true":
        return CheckoutFacts(path, work_tree=False)
    head = _run(conn, f"git -C {quoted} symbolic-ref -q HEAD")
    status = _run(conn, f"git -C {quoted} status --porcelain")
    if status.exited != 0:
        return CheckoutFacts(path, work_tree=False)
    return CheckoutFacts(
        path,
        detached=head.exited != 0,
        porcelain=status.stdout or "",
    )


def collect_probe(conn):
    listed = _run(conn, f"cat {CHECKOUTS}")
    if listed.exited != 0:
        return Probe(f"missing {CHECKOUTS}", None, None, True)
    try:
        dot_path, setup_path = parse_checkouts(listed.stdout or "")
    except WalkError as err:
        return Probe(str(err), None, None, True)
    role = _run(conn, f"test -f {shlex.quote(role_script(setup_path))}")
    return Probe(
        None,
        probe_checkout(conn, dot_path),
        probe_checkout(conn, setup_path),
        role.exited != 0,
    )


def connection_class():
    script_dir = str(Path(__file__).resolve().parent)
    removed = []
    kept = []
    for entry in sys.path:
        if entry in ("", script_dir):
            removed.append(entry)
            continue
        kept.append(entry)
    sys.path[:] = kept
    try:
        module = importlib.import_module("fabric")
    finally:
        sys.path[:0] = removed
    if not hasattr(module, "Connection"):
        raise WalkError("the installed fabric package has no Connection")
    return module.Connection


def run_host(conn, record, command):
    actions = plan_actions(command, collect_probe(conn))
    if actions.error:
        print(actions.error, file=sys.stderr)
        print(f"{record.name} {command} exit 1")
        return 1
    for line in actions.preview:
        print(line)
    for remote in actions.commands:
        result = conn.run(remote, pty=False, warn=True)
        if result.exited != 0:
            print(f"{record.name} {command} exit {result.exited}")
            return result.exited
    print(f"{record.name} {command} exit 0")
    return 0


def walk(records, command):
    connect = connection_class()
    for record in records:
        try:
            conn = connect(
                host=record.host,
                user=record.user,
                connect_timeout=20,
            )
        except Exception as err:
            print(f"{record.name}: {err}", file=sys.stderr)
            print(f"{record.name} {command} exit 1")
            return 1
        code = run_host(conn, record, command)
        if code != 0:
            return code
    return 0


def create_venv():
    """Create the control venv. This Python often has no ensurepip module."""
    VENV.parent.mkdir(parents=True, exist_ok=True)
    if VENV.exists() and not (VENV / "bin" / "python").is_file():
        shutil.rmtree(VENV)
    if (VENV / "bin" / "python").is_file() and (VENV / "bin" / "pip").is_file():
        return
    if VENV.exists():
        shutil.rmtree(VENV)
    if importlib.util.find_spec("ensurepip") is not None:
        created = subprocess.run(
            [sys.executable, "-m", "venv", str(VENV)],
            check=False,
        )
        if created.returncode == 0 and (VENV / "bin" / "pip").is_file():
            return
        if VENV.exists():
            shutil.rmtree(VENV)
    virtualenv = shutil.which("virtualenv")
    if not virtualenv:
        raise WalkError(
            "python -m venv could not install pip, and virtualenv is not on PATH"
        )
    subprocess.check_call([virtualenv, str(VENV)])


def ensure_runtime():
    """Re-exec inside the control venv once fabric==3.2.3 is installed."""
    if Path(sys.prefix).resolve() == VENV.resolve():
        return
    requirements = Path(__file__).resolve().parent / "requirements.txt"
    create_venv()
    python = VENV / "bin" / "python"
    installed = list(VENV.glob("lib/python*/site-packages/fabric-3.2.3.dist-info"))
    if not installed:
        subprocess.check_call(
            [str(python), "-m", "pip", "install", "-r", str(requirements)]
        )
    os.execv(str(python), [str(python), str(Path(__file__).resolve()), *sys.argv[1:]])


def print_list(records):
    for record in records:
        print(f"{record.name} {record.status}")


def main(argv=None):
    parser = argparse.ArgumentParser(prog="fabric.py")
    parser.add_argument("--inventory", required=True)
    parser.add_argument("--include-self", action="store_true")
    parser.add_argument("--host", action="append", default=[])
    parser.add_argument("command", choices=("list", "dry-run", "apply"))
    args = parser.parse_args(argv)
    try:
        records = INVENTORY.load_inventory(args.inventory)
    except INVENTORY.InventoryError as err:
        print(str(err), file=sys.stderr)
        return 1
    if args.command == "list" and not args.host:
        print_list(records)
        return 0
    try:
        chosen = hosts_for_walk(
            records,
            args.host,
            local_short_name(),
            args.include_self,
        )
    except WalkError as err:
        print(str(err), file=sys.stderr)
        return 1
    if args.command == "list":
        print_list(records)
        return 0
    ensure_runtime()
    return walk(chosen, args.command)


if __name__ == "__main__":
    sys.exit(main())
