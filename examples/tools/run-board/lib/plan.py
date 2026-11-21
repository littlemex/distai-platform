"""Load and validate a run-board plan.yaml.

A plan is a static, hand-written description of a schedule: a list of items, each
with an id, a display name, a lane (the node or shared resource it runs on), a
planned start offset from the block's start, a planned duration, the ids of items
it depends on, an informational stop condition, and a `status_source` that says how
`collect_status.py` should find this item's real-world state.

This module has no side effects: it only parses and validates. It is imported by
both `collect_status.py` (to know what to look for) and `render_board.py` (to know
what to draw).
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import timedelta

import yaml

_ID_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
# DNS-1123-ish: this is also the regex used to validate any name/namespace that
# `collect_status.py` will later splice into a kubectl argv list.
_DNS1123_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")

_OFFSET_RE = re.compile(r"^T\+(\d+):(\d{2})$")
# A tiny ISO-8601 duration subset: PT<h>H<m>M, PT<h>H, PT<m>M. Good enough for a
# schedule expressed in hours/minutes; we deliberately do not pull in a full
# ISO-8601 library for this toy.
_DURATION_RE = re.compile(r"^PT(?:(\d+)H)?(?:(\d+)M)?$")

VALID_STATUS_KINDS = {"job", "kueue_workload", "manual"}


class PlanError(ValueError):
    """The plan.yaml is malformed or fails validation."""


def parse_offset(text: str) -> timedelta:
    """Parse a 'T+HH:MM' offset-from-block-start into a timedelta."""
    if not isinstance(text, str):
        # A plan author writing `planned_start: 6` (no quotes) gets a clear PlanError
        # here instead of an AttributeError from calling .strip() on an int.
        raise PlanError(f"planned_start must be a string like 'T+HH:MM', got {text!r}")
    m = _OFFSET_RE.fullmatch(text.strip())
    if not m:
        raise PlanError(f"planned_start must look like 'T+HH:MM', got {text!r}")
    hours, minutes = int(m.group(1)), int(m.group(2))
    return timedelta(hours=hours, minutes=minutes)


def parse_duration(text: str) -> timedelta:
    """Parse a small ISO-8601 duration subset: PT<h>H<m>M / PT<h>H / PT<m>M."""
    if not isinstance(text, str):
        raise PlanError(f"planned_duration must be a string like 'PT2H', got {text!r}")
    m = _DURATION_RE.fullmatch(text.strip())
    if not m or (m.group(1) is None and m.group(2) is None):
        raise PlanError(
            f"planned_duration must look like 'PT2H', 'PT30M' or 'PT1H30M', got {text!r}"
        )
    hours = int(m.group(1) or 0)
    minutes = int(m.group(2) or 0)
    return timedelta(hours=hours, minutes=minutes)


def validate_name_component(value: str, field_name: str) -> str:
    """Validate a value that will be used as a Kubernetes resource name or namespace.

    This is the one guard that matters for injection safety: `collect_status.py`
    builds argv lists like ["kubectl", "get", "job", name, "-n", namespace, ...],
    and `name`/`namespace` come straight from this file. Rejecting anything that
    is not a plain lowercase-alnum-and-hyphen token closes the one place a plan
    author (or a compromised plan.yaml) could otherwise smuggle a flag or a shell
    metacharacter into a subprocess argv.

    The 253-character ceiling matches a Kubernetes object `name` (a DNS-1123
    subdomain). A real namespace is actually capped at 63 (a DNS-1123 *label*,
    the stricter of the two) — this function does not distinguish the two
    fields and uses the more permissive limit for both, so an over-long
    namespace value is still rejected by `kubectl` itself at call time, just
    not by this check. That is a usability gap, not a safety one: neither
    field can contain a flag or metacharacter regardless of length.
    """
    if not isinstance(value, str) or not _DNS1123_RE.fullmatch(value) or len(value) > 253:
        raise PlanError(
            f"{field_name}={value!r} must be a plain lowercase-alnum-and-hyphen token, "
            "up to 253 characters, not starting/ending with '-'"
        )
    return value


@dataclass(frozen=True)
class StatusSource:
    kind: str  # one of VALID_STATUS_KINDS
    # for kind=job / kueue_workload:
    namespace: str | None = None
    name: str | None = None
    # for kind=manual:
    key: str | None = None


@dataclass(frozen=True)
class PlanItem:
    id: str
    name: str
    lane: str
    planned_start: timedelta
    planned_duration: timedelta
    depends_on: tuple[str, ...]
    stop_condition: str
    status_source: StatusSource


@dataclass(frozen=True)
class Plan:
    grace_minutes: int
    items: tuple[PlanItem, ...] = field(default_factory=tuple)

    def by_id(self) -> dict[str, PlanItem]:
        return {item.id: item for item in self.items}


def _parse_status_source(raw: dict, item_id: str) -> StatusSource:
    if not isinstance(raw, dict) or "kind" not in raw:
        raise PlanError(f"item {item_id!r}: status_source must be a mapping with a 'kind'")
    kind = raw["kind"]
    if kind not in VALID_STATUS_KINDS:
        raise PlanError(
            f"item {item_id!r}: status_source.kind={kind!r} must be one of {sorted(VALID_STATUS_KINDS)}"
        )
    if kind in ("job", "kueue_workload"):
        namespace = validate_name_component(raw.get("namespace", ""), f"{item_id}.status_source.namespace")
        name = validate_name_component(raw.get("name", ""), f"{item_id}.status_source.name")
        return StatusSource(kind=kind, namespace=namespace, name=name)
    # kind == "manual": the key just has to be a safe identifier too, since it is
    # used as a lookup key and echoed back into the rendered HTML.
    key = raw.get("key")
    if not isinstance(key, str) or not _ID_RE.fullmatch(key):
        raise PlanError(f"item {item_id!r}: status_source.key must be a plain id, got {key!r}")
    return StatusSource(kind=kind, key=key)


def load_plan(path: str) -> Plan:
    with open(path, "r", encoding="utf-8") as f:
        try:
            raw = yaml.safe_load(f)  # safe_load: a plan.yaml is data, never executable.
        except yaml.YAMLError as e:
            # A syntax-level error (bad indentation, a stray tab, ...) must reach the
            # same labelled "except PlanError" path as every other plan problem, not
            # escape as an unlabelled yaml.YAMLError.
            raise PlanError(f"plan.yaml is not valid YAML: {e}") from e
    if not isinstance(raw, dict):
        raise PlanError("plan.yaml must be a mapping at the top level")

    grace_minutes = raw.get("grace_minutes", 15)
    if not isinstance(grace_minutes, int) or grace_minutes < 0:
        raise PlanError(f"grace_minutes must be a non-negative integer, got {grace_minutes!r}")

    raw_items = raw.get("items")
    if not isinstance(raw_items, list) or not raw_items:
        raise PlanError("plan.yaml must have a non-empty 'items' list")

    items: list[PlanItem] = []
    seen_ids: set[str] = set()
    for raw_item in raw_items:
        if not isinstance(raw_item, dict):
            raise PlanError(f"each item must be a mapping, got {raw_item!r}")
        item_id = raw_item.get("id")
        if not isinstance(item_id, str) or not _ID_RE.fullmatch(item_id):
            raise PlanError(f"item id must be a plain id (lowercase, '-'), got {item_id!r}")
        if item_id in seen_ids:
            raise PlanError(f"duplicate item id {item_id!r}")
        seen_ids.add(item_id)

        name = raw_item.get("name")
        if not isinstance(name, str) or not name.strip():
            raise PlanError(f"item {item_id!r}: 'name' must be a non-empty string")

        lane = raw_item.get("lane")
        if not isinstance(lane, str) or not lane.strip():
            raise PlanError(f"item {item_id!r}: 'lane' must be a non-empty string")

        planned_start = parse_offset(raw_item.get("planned_start", ""))
        planned_duration = parse_duration(raw_item.get("planned_duration", ""))

        depends_on_raw = raw_item.get("depends_on", [])
        if not isinstance(depends_on_raw, list) or not all(isinstance(d, str) for d in depends_on_raw):
            raise PlanError(f"item {item_id!r}: 'depends_on' must be a list of ids")

        stop_condition = raw_item.get("stop_condition", "")
        if not isinstance(stop_condition, str):
            raise PlanError(f"item {item_id!r}: 'stop_condition' must be a string")

        status_source = _parse_status_source(raw_item.get("status_source", {}), item_id)

        items.append(
            PlanItem(
                id=item_id,
                name=name,
                lane=lane,
                planned_start=planned_start,
                planned_duration=planned_duration,
                depends_on=tuple(depends_on_raw),
                stop_condition=stop_condition,
                status_source=status_source,
            )
        )

    ids = {item.id for item in items}
    for item in items:
        for dep in item.depends_on:
            if dep not in ids:
                raise PlanError(f"item {item.id!r} depends_on unknown id {dep!r}")
            if dep == item.id:
                raise PlanError(f"item {item.id!r} depends on itself")

    return Plan(grace_minutes=grace_minutes, items=tuple(items))
