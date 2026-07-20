# Copyright 2026 tomasagata
# See LICENSE file for licensing details.
#
# The integration tests use the Jubilant library and the pytest-jubilant plugin.
# See https://documentation.ubuntu.com/ops/latest/howto/write-integration-tests-for-a-charm/
#
# pytest-jubilant provides a module-scoped `juju` fixture that creates a temporary Juju model.
# The `charm` fixture is defined in conftest.py.

import logging
import pathlib

import jubilant
import pytest
import yaml

logger = logging.getLogger(__name__)

METADATA = yaml.safe_load(pathlib.Path("charmcraft.yaml").read_text())

APP_NAME = "bmv2"

# A minimal P4_16 program with a single table, used to exercise reprogram/table
# actions end to end against real p4c/simple_switch binaries.
SAMPLE_P4_PROGRAM = """
#include <core.p4>
#include <v1model.p4>

header ethernet_t {
    bit<48> dstAddr;
    bit<48> srcAddr;
    bit<16> etherType;
}

struct headers_t { ethernet_t ethernet; }
struct metadata_t { }

parser MyParser(packet_in packet, out headers_t hdr, inout metadata_t meta,
                inout standard_metadata_t standard_metadata) {
    state start {
        packet.extract(hdr.ethernet);
        transition accept;
    }
}

control MyVerifyChecksum(inout headers_t hdr, inout metadata_t meta) { apply { } }

control MyIngress(inout headers_t hdr, inout metadata_t meta,
                   inout standard_metadata_t standard_metadata) {
    action forward(bit<9> port) { standard_metadata.egress_spec = port; }
    action drop_pkt() { mark_to_drop(standard_metadata); }

    table dmac {
        key = { hdr.ethernet.dstAddr: exact; }
        actions = { forward; drop_pkt; }
        default_action = drop_pkt();
    }

    apply { dmac.apply(); }
}

control MyEgress(inout headers_t hdr, inout metadata_t meta,
                  inout standard_metadata_t standard_metadata) { apply { } }
control MyComputeChecksum(inout headers_t hdr, inout metadata_t meta) { apply { } }
control MyDeparser(packet_out packet, in headers_t hdr) { apply { packet.emit(hdr.ethernet); } }

V1Switch(MyParser(), MyVerifyChecksum(), MyIngress(), MyEgress(),
         MyComputeChecksum(), MyDeparser()) main;
"""


@pytest.mark.juju_setup
def test_deploy(charm: pathlib.Path, juju: jubilant.Juju):
    """Deploy the charm under test with its two sidecar containers."""
    resources = {
        "p4c-image": METADATA["resources"]["p4c-image"]["upstream-source"],
        "bmv2-image": METADATA["resources"]["bmv2-image"]["upstream-source"],
    }
    juju.deploy(charm, app=APP_NAME, resources=resources)
    # No P4 program is loaded yet, so the unit is expected to be Blocked, not Active.
    juju.wait(lambda status: jubilant.all_blocked(status, APP_NAME))


def test_reprogram_loads_a_program_and_switch_becomes_active(juju: jubilant.Juju):
    """The reprogram action should compile and load a program, making the unit Active."""
    result = juju.run(f"{APP_NAME}/0", "reprogram", {"p4-source": SAMPLE_P4_PROGRAM})
    assert result.results.get("result") == "switch reprogrammed"
    juju.wait(jubilant.all_active)


def test_table_add_then_reprogram_clears_the_entry(juju: jubilant.Juju):
    """A table entry added before a reprogram must not survive it.

    This is the key edge case this charm needs to get right: BMv2 only keeps
    table state in the running simple_switch process's memory, so reloading a
    program (even the same one) always starts a fresh process with empty
    tables.
    """
    add_result = juju.run(
        f"{APP_NAME}/0",
        "table-add",
        {
            "table": "MyIngress.dmac",
            "action": "MyIngress.forward",
            "match": "00:00:00:00:00:01",
            "action-params": "1",
        },
    )
    assert "handle" in add_result.results.get("result", "").lower()

    reprogram_result = juju.run(f"{APP_NAME}/0", "reprogram", {"p4-source": SAMPLE_P4_PROGRAM})
    assert "cleared" in reprogram_result.results.get("note", "").lower()
    juju.wait(jubilant.all_active)

    # The table is back to empty: deleting the (now nonexistent) old handle fails.
    with pytest.raises(jubilant.TaskError):
        juju.run(f"{APP_NAME}/0", "table-delete", {"table": "MyIngress.dmac", "handle": 0})
