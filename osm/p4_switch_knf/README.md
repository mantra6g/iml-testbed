# p4_switch_knf

Context notes for whoever (human or Claude) picks this KNF up next. This
documents what exists, why it was built this way, and what's still open.

## Two implementations, one KNF

This KNF currently has two independent deployment mechanisms sitting side by
side:

- `juju-bundles/` — a Juju charm (`ops/bmv2`) that drives *two* sidecar
  containers (a `p4c` compiler container and a separate `bmv2` container)
  over Pebble. It exposes actions (`reprogram`, `table-add`, `table-delete`,
  `table-clear`) for imperative, day-2 control. This is the original/legacy
  approach.
- `helm-charts/` — new, added in this session. A plain Helm chart with a
  single Deployment, driven declaratively by Helm values instead of actions.
  This is what the rest of this README describes.

`p4_switch_vnfd.yaml` currently has an uncommitted, in-progress edit
(`kdu[0].helm-chart: bundle.yaml`, changed from `juju-bundle: bundle.yaml`)
that still points at the Juju bundle, **not** at `helm-charts/`. Wiring the
VNFD's KDU to the new chart (and deciding whether to delete `juju-bundles/`
or keep both as alternative day-1 options) is unfinished — left for a
follow-up, not done in this session.

## What the Helm chart does

One container, image `p4lang/p4c` (pinned to tag `1.2.5.15` by default,
see `values.yaml` / `image.tag`). This image is `FROM
p4lang/behavioral-model`, so a single container ships both `p4c-bm2-ss`
(the compiler) and `simple_switch` / `simple_switch_CLI` (the BMv2 software
switch and its control CLI) — confirmed by reading the upstream Dockerfiles
on GitHub. That's why this chart uses one container instead of the two the
Juju charm needed.

All the real logic lives in a shell/Python entrypoint baked into a
ConfigMap (`templates/configmap-scripts.yaml`) and mounted at `/scripts`,
overriding the image's default command. On container start it:

1. Fails fast if `p4ProgramURL` is empty (`P4_PROGRAM_URL` env var).
2. Downloads the P4 source from `p4ProgramURL` with `curl`.
3. Compiles it: `p4c-bm2-ss --p4v 16 switch.p4 -o switch.json`.
4. Builds `-i <port>@<iface>` flags from `intfPairs` (see below).
5. If `tableEntriesURL` is set, spawns a background subshell that polls
   `simple_switch_CLI` until the Thrift port accepts connections, then
   downloads the JSON and feeds it through `load_table_entries.py`, which
   translates each entry into a `table_add` command line and pipes them all
   into one `simple_switch_CLI` invocation.
6. `exec`s `simple_switch` in the foreground as PID 1, so container
   logs/health reflect the switch process directly.

`curl` and `python3` are both present in the `p4lang/behavioral-model` base
image (verified against its Dockerfile), so no extra tooling was added to
the image.

## Chart values

| Value | Purpose |
|---|---|
| `image.repository` / `image.tag` | p4c/bmv2 image name and pinned tag. Default `p4lang/p4c:1.2.5.15` — the latest non-`latest` tag on Docker Hub as of 2026-07-28. |
| `p4ProgramURL` | URL to the P4_16 source to compile and run. Required — no default. |
| `intfPairs` | List of `"<port_number>,<iface_name>"` strings, e.g. `["0,net1", "1,net2"]`. Converted to `simple_switch -i port@iface` flags. |
| `tableEntriesURL` | URL to a JSON list of match-action table entries, loaded once the switch is up. Optional — switch boots with empty tables if unset. |
| `thriftPort` | Thrift RPC port for `simple_switch`/`simple_switch_CLI` (default `9090`). Also exposed via a `Service` when `service.enabled` is true. |

Generic passthroughs (`resources`, `nodeSelector`, `tolerations`,
`affinity`, `podAnnotations`) are included for operational flexibility but
weren't specifically requested.

### `tableEntriesURL` JSON shape

Deliberately mirrors the parameters the old Juju charm's `table-add` action
took (`bmv2.build_table_add_command` in
`juju-bundles/ops/bmv2/src/bmv2.py`), so existing table-entry data from that
workflow should translate directly:

```json
[
  {
    "table": "ipv4_lpm",
    "action": "ipv4_forward",
    "match": ["10.0.0.0/24"],
    "action_params": ["00:11:22:33:44:55", "1"],
    "priority": 10
  }
]
```

`priority` is optional (only meaningful for ternary/range-match tables).
Each entry becomes: `table_add <table> <action> <match...> => <action_params...> [priority]`.

## Assumptions and open questions (read before extending)

- **Interface provisioning is out of scope for this chart.** `intfPairs`
  only tells `simple_switch` which *already-present* netns interfaces to
  bind to — the chart does not attach them. The VNFD defines three external
  CPs (`mgmt-ext`, `ingress-ext`, `egress-ext`) mapped to k8s-cluster
  networks (`mgmtnet`, `ingressnet`, `egressnet`), which presumably need
  Multus (or whatever OSM's K8s VIM connector does for KDU network
  bindings) to actually land as extra interfaces in the pod. I did not
  implement this — I don't know whether OSM injects
  `k8s.v1.cni.cncf.io/networks` annotations automatically for native Helm
  KDUs the way it might for other KDU types, or whether this chart needs to
  do it itself via `podAnnotations`. **This needs to be resolved before the
  chart is usable end-to-end** — the interface names configured in
  `intfPairs` need to line up with whatever Multus (or equivalent) actually
  names the attached interfaces.
- **No liveness/readiness probes** were added. Could add a probe that shells
  out to `simple_switch_CLI ... help` once the chart's networking story is
  settled — held off since a failing probe during the compile step would
  just cause pointless restarts without more tuning.
- **No `reprogram`-equivalent day-2 operation.** Changing `p4ProgramURL` and
  running `helm upgrade` recreates the pod (new compile, table state reset)
  — analogous to the old charm's `reprogram` action, but there's no
  standalone way to reload just the tables without a full pod restart
  (the old `table-clear`/`table-delete` actions have no chart equivalent).
  If day-2 table/program management without a restart matters, an
  OSM day-1/day-2 config-primitive wired to `kubectl exec ... 
  simple_switch_CLI` (or reviving pieces of the charm's approach) would be
  the way to add it.
- **Single replica only**, hardcoded (not a value) — `simple_switch` keeps
  all table state in-process, so replicas wouldn't be interchangeable
  copies of the same switch.
- **Image tag pin** (`1.2.5.15`) was picked as "latest tagged release
  available on Docker Hub at write time" — no functional testing against
  this specific tag was done, only that the image exists.
- The chart was validated with `helm lint` and `helm template` (renders
  cleanly, `INTF_PAIRS` interpolation checked) — **not deployed to a real
  cluster**. Fetching a real P4 program, compiling it, and loading real
  table entries end-to-end is still untested.
- `_helpers.tpl` was placed under `templates/` (Helm only registers
  `define`d templates found under that directory); an empty placeholder had
  been created directly under `helm-charts/` before this session — that
  file did nothing there and was removed rather than left as dead weight.
