"""Read the private host inventory. This module does not import Fabric."""

REQUIRED = ("user", "host", "status")
ALLOWED = REQUIRED + ("note",)


class InventoryError(Exception):
    """The inventory text or file is not usable."""


class Host:
    """One inventory section."""

    def __init__(self, name, user, host, status, note):
        self.name = name
        self.user = user
        self.host = host
        self.status = status
        self.note = note


def _relative_host(host):
    if any(char.isspace() for char in host):
        return True
    if "/" in host:
        return True
    if host.startswith("."):
        return True
    return False


def parse_inventory(text):
    """Return Host rows. Raise InventoryError and name the section and key."""
    hosts = []
    seen = set()
    current = None
    fields = {}

    def finish():
        nonlocal current, fields
        if current is None:
            return
        for key in REQUIRED:
            if not fields.get(key):
                raise InventoryError(f"{current}: missing {key}")
        if fields["status"] not in ("in", "out"):
            raise InventoryError(f"{current}: status")
        if _relative_host(fields["host"]):
            raise InventoryError(f"{current}: host")
        if current in seen:
            raise InventoryError(f"duplicate section {current}")
        seen.add(current)
        hosts.append(
            Host(
                current,
                fields["user"],
                fields["host"],
                fields["status"],
                fields.get("note", ""),
            )
        )
        current = None
        fields = {}

    for raw in text.splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            finish()
            name = line[1:-1].strip()
            if not name:
                raise InventoryError("empty section")
            if name in seen:
                raise InventoryError(f"duplicate section {name}")
            current = name
            fields = {}
            continue
        if current is None:
            raise InventoryError(f"key outside a section: {line}")
        if "=" not in line:
            raise InventoryError(f"{current}: bad line")
        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()
        if key not in ALLOWED:
            raise InventoryError(f"{current}: unknown {key}")
        if key in fields:
            raise InventoryError(f"{current}: duplicate {key}")
        fields[key] = value
    finish()
    return hosts


def load_inventory(path):
    """Read path as UTF-8 inventory text."""
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except OSError as err:
        raise InventoryError(f"cannot read {path}") from err
    return parse_inventory(text)
