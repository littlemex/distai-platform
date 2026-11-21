# run-board (toy, not production monitoring)

A small script that turns a hand-written schedule (`plan.yaml`: phases, lanes,
planned start/duration, dependencies) into one self-contained HTML page showing
what was planned next to what actually happened, for the kind of short-lived,
heavily time-boxed verification runs this project does inside a Capacity Block
or an ODCR window — "what's supposed to run when, on which node, and are we on
schedule right now?"

**This is an example, not part of the platform.** It lives under `examples/`,
not `infra/` or `gitops/`, on purpose: it is not maintained to the same bar as
the Terraform/GitOps layers, it is not deployed anywhere, and it is not a
monitoring system — it renders one static snapshot at a time, by hand, for a
human to glance at during a run. See [`../../../AGENTS.md`](../../../AGENTS.md)
for where the real platform layers live.

## Why this exists instead of an existing dashboard

Before writing any of this, the usual Kubernetes/GitOps visualization options
were checked against three requirements this use case actually has: a
pre-declared, multi-phase/multi-lane *time plan* as input, a *planned-vs-actual
overlay* (not just live state), and a *single dependency-free static HTML
file* (no server, works with no network access). None of KueueViz, Headlamp,
Kubernetes Dashboard, Argo Workflows UI, Argo CD UI, Grafana's state-timeline
panel, mermaid Gantt diagrams, or Lens/OpenLens combine all three — the full
comparison table is in the originating GitHub Issue, not duplicated here.
Closest conceptually is Argo Workflows' own per-step timing, but using it would
mean modeling the whole schedule as a live Argo Workflow object, which is a
bigger and stickier piece of infrastructure than this toy, and it still
wouldn't produce a portable static file.

## How it works

Three independent, separately-testable pieces:

1. **`plan.yaml`** — static, hand-written. A list of items, each with an `id`,
   a `name`, a `lane` (the node or shared resource it runs on), `planned_start`
   (`"T+HH:MM"`, an offset from the block's start), `planned_duration`
   (`"PT2H"` / `"PT45M"` / `"PT2H15M"`), `depends_on` (a list of other item
   ids, informational only — nothing here enforces or schedules anything),
   `stop_condition` (free text, informational only, never evaluated), and
   `status_source` saying how to find this item's real state:
   - `{kind: job, namespace: ..., name: ...}` — a Kubernetes Batch Job.
   - `{kind: kueue_workload, namespace: ..., name: ...}` — a Kueue `Workload`.
   - `{kind: manual, key: ...}` — anything not represented as a Kubernetes
     object at all (a bare-EC2 phase owned by someone else's own tooling, a
     human-reported milestone). Looked up by `key` in a small
     hand-maintained `manual-status.json`.

2. **`collect_status.py`** — the *only* script that touches a cluster, and it
   is read-only by construction (see `lib/readonly_exec.py`): every call is
   routed through one wrapper that allowlists `kubectl get` only, built as an
   argv list (never a shell string), so there is no command this tool can run
   that mutates anything. It reads only a small, fixed set of fields out of
   each object (see `lib/k8s_mapping.py`) — never the raw object — so account
   IDs, image URIs, node IPs, and free-text condition messages never reach
   disk. Output: `status.json` (`block_start`, `collected_at`, one raw
   lifecycle state per item — `unknown`/`pending`/`running`/`done`/`failed` —
   plus timestamps, and a list of any items that failed to collect). This tool
   does not collect anything from AWS directly; see "Not covered" below.

3. **`render_board.py`** — a pure function, `(plan.yaml, status.json) ->
   board.html`. No network, no cluster access, no clock reads except one
   small inline script that only adds a "this snapshot is stale" banner at
   *view* time — the chart itself is rendered once, deterministically, from
   `status.json`'s own `collected_at`. "Late", "overdue, not started", and
   "overrunning" are derived here (`lib/status_model.py`), not stored as a
   state, so there is exactly one place that decides what "on schedule" means.
   Output is one HTML file: inline CSS/SVG, a few lines of inline JS, no
   external `<script>`/`<link>`, a `Content-Security-Policy` meta tag that
   allows nothing but this page's own inline style/script, and every
   free-text field HTML-escaped. Hovering a bar shows its `stop_condition`,
   if one is set.

A collection error (a typo'd name, an expired credential, a deleted-by-TTL
Job) renders as **`unknown`**, visually distinct from "not started" — never
silently drawn as if the item simply hasn't begun — and is also called out in
a banner at the top of the page.

## Try it with the sample data

The sample plan is modeled on the shape of a real shared-24h-reservation
schedule this project has used (a bare-EC2 phase, a reservation handoff, a
device-plugin baseline, a pool-wide mode switch, a two-lane DRA phase, a joint
check, a serving benchmark, a fixed closing tail) with every real name,
account ID and timing replaced by a generic placeholder.

```bash
cd examples/tools/run-board
uv run -q --with PyYAML==6.0.2 python render_board.py sample/plan.yaml sample/status.sample.json -o /tmp/run-board-sample.html
open /tmp/run-board-sample.html
```

(`open` is macOS; use `xdg-open` on Linux.)

## Using it for real

Collecting live status needs a `kubectl` context pointed at your cluster — a
`get`/`list`-only `ClusterRole` is enough, see "Security" below. Re-run both
commands whenever you want a fresh snapshot; neither watches anything
continuously or refreshes itself.

```bash
cd examples/tools/run-board
uv run -q --with PyYAML==6.0.2 python collect_status.py my-plan.yaml --block-start 2026-11-20T11:00:00Z --manual-status my-manual-status.json -o out/status.json
uv run -q --with PyYAML==6.0.2 python render_board.py my-plan.yaml out/status.json -o out/board.html
```

Both scripts create `out/` themselves if it does not already exist. `out/` is
also gitignored by this directory — never commit a real `status.json` or
rendered board from a real cluster; only the sample fixtures under `sample/`
are meant to be committed.

## Security

- `collect_status.py` can only run `kubectl get ...`; any other argv raises
  before a subprocess is ever started (`tests/test_readonly_exec.py` proves
  this without needing a real cluster). The real guarantee is still your
  credentials: give it a `kubectl` context bound to a `get`/`list`-only
  `ClusterRole`, so that even a bug in this tool cannot mutate anything.
- Names and namespaces from `plan.yaml` are validated as plain DNS-1123 labels
  before they are ever spliced into an argv list (`lib/plan.py`), closing the
  one place a plan file could otherwise smuggle a flag or metacharacter into
  a subprocess call.
- `status.json` never carries raw `kubectl` output, only the few allowlisted
  fields in `lib/k8s_mapping.py` — so it is safe-ish to share for debugging,
  but still treat it and any rendered `board.html` from a real cluster as
  internal: write them to the gitignored `out/` directory, not into this repo.
- The rendered HTML's `Content-Security-Policy` meta tag allows nothing but
  this page's own inline style and script, and the page references no
  external URL (`tests/test_render_board.py` checks both), so it is safe to
  open the file directly with no network access.

## Not covered (by design, for a toy)

- No continuous refresh — it is a snapshot generator, run it again for a
  newer picture.
- No alerting, no history, no multi-run comparison.
- No AWS-side status source (for example a Capacity Reservation's own
  `AvailableInstanceCount`): only `job`, `kueue_workload` and `manual` exist
  today. A read-only `aws ec2 describe-capacity-reservations` collector is a
  natural follow-up, left out for now, to keep this tool small.
- `stop_condition` is free text shown as a hover tooltip for context only; it
  is never evaluated, and the board does not claim to know whether a stop
  condition was hit.
- Overlapping items in the same lane are drawn as separate rows, not packed
  into a single interval-scheduling layout — this is a simple per-item list
  grouped by lane, not a dense Gantt chart.
- A manual entry's own `updated_at` is shown next to its `[manual]` badge, but
  is not enforced as required and does not by itself make the board flag a
  stale hand report as late.
