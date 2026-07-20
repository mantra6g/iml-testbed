<!--
Avoid using this README file for information that is maintained or published elsewhere, e.g.:

* charmcraft.yaml > published on Charmhub
* documentation > published on (or linked to from) Charmhub
* detailed contribution guide > documentation or CONTRIBUTING.md

Use links instead.
-->

# bmv2

Charmhub package name: bmv2
More information: https://charmhub.io/bmv2

Operates a BMv2 (behavioral model v2) software switch that can be reprogrammed
with a new P4_16 program at runtime, and whose match-action tables can be
managed live. It drives two sidecar containers: `p4c` (compiles P4 source into
the JSON BMv2 runs) and `bmv2` (runs `simple_switch`, queried at runtime via
`simple_switch_CLI`).

Actions:

- `reprogram`: compile a new P4 program and load it, replacing whatever is
  currently running. This always restarts `simple_switch`, which clears every
  table entry that belonged to the previous program (BMv2 only keeps table
  state in the running process's memory).
- `table-add`, `table-delete`, `table-clear`: manage match-action table entries
  on the currently running program.

This charm is intentionally minimal, meant for quick P4/BMv2 experiments in a
testbed rather than production use.

## Other resources

<!-- If your charm is documented somewhere else other than Charmhub, provide a link separately. -->

- [Read more](https://example.com)

- [Contributing](CONTRIBUTING.md) <!-- or link to other contribution documentation -->

- See the [Juju documentation](https://documentation.ubuntu.com/juju/3.6/howto/manage-charms/) for more information about developing and improving charms.
