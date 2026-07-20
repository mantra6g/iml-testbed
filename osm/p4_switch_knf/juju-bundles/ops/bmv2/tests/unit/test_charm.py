# Copyright 2026 tomasagata
# See LICENSE file for licensing details.
#
# To learn more about testing, see https://documentation.ubuntu.com/ops/latest/explanation/testing/
#
# These tests exercise the charm against two mocked sidecar containers (p4c and
# bmv2). Since neither container runs real p4c/simple_switch binaries in this
# environment, `testing.Exec` mocks stand in for the compiler and
# `simple_switch_CLI` calls, while each container's filesystem is backed by a
# real temp directory (via `testing.Mount`) so that the charm's push()/pull()
# calls can be verified by reading the files they actually wrote.

import pathlib

import ops
import pytest
from ops import testing

import bmv2
from charm import (
    BMV2_CONTAINER,
    COMPILED_JSON_PATH,
    P4_SOURCE_PATH,
    P4C_CONTAINER,
    RUNTIME_JSON_PATH,
    SWITCH_SERVICE,
    Bmv2Charm,
)

SAMPLE_P4_SOURCE = "// a fake P4_16 program; contents don't matter for these tests\n"
DEFAULT_CONFIG = {"thrift-port": 9090, "interfaces": ""}


def make_p4c_container(
    tmp_path: pathlib.Path,
    *,
    can_connect: bool = True,
    compiled_json: bytes | None = b'{"program": "v1"}',
    compile_ok: bool = True,
    compiler_stdout: str = "compilation succeeded\n",
    compiler_stderr: str = "",
) -> tuple[testing.Container, pathlib.Path]:
    """Build a mock p4c Container, with /tmp backed by a real temp directory."""
    mount_source = tmp_path / "p4c-tmp"
    mount_source.mkdir()
    if compiled_json is not None:
        (mount_source / "switch.json").write_bytes(compiled_json)

    execs = {
        testing.Exec(
            bmv2.build_p4c_command(P4_SOURCE_PATH, COMPILED_JSON_PATH),
            return_code=0 if compile_ok else 1,
            stdout=compiler_stdout if compile_ok else "",
            stderr="" if compile_ok else compiler_stderr,
        )
    }
    container = testing.Container(
        P4C_CONTAINER,
        can_connect=can_connect,
        mounts={"tmp": testing.Mount(location="/tmp", source=mount_source)},
        execs=execs,
    )
    return container, mount_source


def make_bmv2_container(
    tmp_path: pathlib.Path,
    *,
    can_connect: bool = True,
    switch_running: bool = False,
    existing_program: bytes | None = None,
    thrift_port: int = 9090,
    cli_execs: "set[testing.Exec] | None" = None,
) -> tuple[testing.Container, pathlib.Path]:
    """Build a mock bmv2 Container, with /config backed by a real temp directory."""
    mount_source = tmp_path / "bmv2-config"
    mount_source.mkdir()

    layers = {}
    service_statuses = {}
    if existing_program is not None:
        (mount_source / "switch.json").write_bytes(existing_program)
        command = " ".join(bmv2.build_switch_command(RUNTIME_JSON_PATH, thrift_port, []))
        layers["bmv2"] = ops.pebble.Layer(
            {
                "services": {
                    SWITCH_SERVICE: {
                        "override": "replace",
                        "summary": "BMv2 simple_switch",
                        "command": command,
                        "startup": "enabled",
                    }
                }
            }
        )
        if switch_running:
            service_statuses[SWITCH_SERVICE] = ops.pebble.ServiceStatus.ACTIVE

    container = testing.Container(
        BMV2_CONTAINER,
        can_connect=can_connect,
        mounts={"config": testing.Mount(location="/config", source=mount_source)},
        layers=layers,
        service_statuses=service_statuses,
        execs=cli_execs or set(),
    )
    return container, mount_source


def get_container_from_state(state, name: str) -> testing.Container:
    """Fetch a container from a (possibly None) post-action State, for assertions."""
    assert state is not None
    return state.get_container(name)


def get_switch_plan_command(container: testing.Container) -> str:
    services = container.plan.to_dict().get("services") or {}
    service = dict(services.get(SWITCH_SERVICE) or {})
    return str(service.get("command", ""))


def get_action_results(ctx: testing.Context) -> dict:
    """Fetch the action results dict, for assertions (fails loudly if unset)."""
    assert ctx.action_results is not None
    return ctx.action_results


# -- Lifecycle -----------------------------------------------------------------


def test_pebble_ready_blocks_when_no_program_is_loaded(tmp_path):
    """Both sidecars up but no program loaded yet should block, not error."""
    ctx = testing.Context(Bmv2Charm)
    p4c_container, _ = make_p4c_container(tmp_path)
    bmv2_container, _ = make_bmv2_container(tmp_path)
    state_in = testing.State(containers={p4c_container, bmv2_container}, config=DEFAULT_CONFIG)

    state_out = ctx.run(ctx.on.pebble_ready(bmv2_container), state_in)

    assert isinstance(state_out.unit_status, testing.BlockedStatus)
    assert "no P4 program loaded" in state_out.unit_status.message


def test_pebble_ready_waits_when_a_container_is_not_ready(tmp_path):
    """If either sidecar can't be reached yet, status should be Maintenance."""
    ctx = testing.Context(Bmv2Charm)
    p4c_container, _ = make_p4c_container(tmp_path, can_connect=False)
    bmv2_container, _ = make_bmv2_container(tmp_path)
    state_in = testing.State(containers={p4c_container, bmv2_container}, config=DEFAULT_CONFIG)

    state_out = ctx.run(ctx.on.pebble_ready(bmv2_container), state_in)

    assert isinstance(state_out.unit_status, testing.MaintenanceStatus)


def test_pebble_ready_active_when_program_already_running(tmp_path):
    """A program loaded and running should report Active."""
    ctx = testing.Context(Bmv2Charm)
    p4c_container, _ = make_p4c_container(tmp_path)
    bmv2_container, _ = make_bmv2_container(
        tmp_path, existing_program=b'{"program": "v1"}', switch_running=True
    )
    state_in = testing.State(containers={p4c_container, bmv2_container}, config=DEFAULT_CONFIG)

    state_out = ctx.run(ctx.on.pebble_ready(bmv2_container), state_in)

    assert state_out.unit_status == testing.ActiveStatus("switch running")


# -- reprogram: happy path -------------------------------------------------------


def test_reprogram_compiles_pushes_and_starts_the_switch(tmp_path):
    """Reprogram should push the source, compile it, and load the result."""
    ctx = testing.Context(Bmv2Charm)
    compiled_json = b'{"program": "brand-new"}'
    p4c_container, p4c_root = make_p4c_container(tmp_path, compiled_json=compiled_json)
    bmv2_container, bmv2_root = make_bmv2_container(tmp_path)
    state_in = testing.State(
        containers={p4c_container, bmv2_container},
        config={"thrift-port": 9090, "interfaces": "0@veth0,1@veth1"},
    )

    state_out = ctx.run(
        ctx.on.action("reprogram", params={"p4-source": SAMPLE_P4_SOURCE}), state_in
    )

    # The P4 source was pushed to the p4c container at the expected path.
    assert (p4c_root / "switch.p4").read_text() == SAMPLE_P4_SOURCE
    # The compiled JSON was pulled from p4c and pushed into the bmv2 container.
    assert (bmv2_root / "switch.json").read_bytes() == compiled_json

    bmv2_out = get_container_from_state(state_out, BMV2_CONTAINER)
    expected_command = " ".join(
        bmv2.build_switch_command(RUNTIME_JSON_PATH, 9090, ["0@veth0", "1@veth1"])
    )
    assert get_switch_plan_command(bmv2_out) == expected_command
    assert bmv2_out.service_statuses[SWITCH_SERVICE] == ops.pebble.ServiceStatus.ACTIVE
    assert state_out.unit_status == testing.ActiveStatus("switch running")

    assert get_action_results(ctx)["result"] == "switch reprogrammed"
    assert get_action_results(ctx)["compiler-output"] == "compilation succeeded"
    assert "cleared" in get_action_results(ctx)["note"]


# -- reprogram: guard clauses -----------------------------------------------------


def test_reprogram_fails_with_empty_source(tmp_path):
    ctx = testing.Context(Bmv2Charm)
    p4c_container, _ = make_p4c_container(tmp_path)
    bmv2_container, _ = make_bmv2_container(tmp_path)
    state_in = testing.State(containers={p4c_container, bmv2_container}, config=DEFAULT_CONFIG)

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(ctx.on.action("reprogram", params={"p4-source": "   "}), state_in)

    assert "p4-source" in exc_info.value.message


def test_reprogram_fails_when_p4c_container_not_ready(tmp_path):
    ctx = testing.Context(Bmv2Charm)
    p4c_container, _ = make_p4c_container(tmp_path, can_connect=False)
    bmv2_container, _ = make_bmv2_container(tmp_path)
    state_in = testing.State(containers={p4c_container, bmv2_container}, config=DEFAULT_CONFIG)

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(ctx.on.action("reprogram", params={"p4-source": SAMPLE_P4_SOURCE}), state_in)

    assert "p4c container is not ready" in exc_info.value.message


def test_reprogram_fails_when_bmv2_container_not_ready(tmp_path):
    ctx = testing.Context(Bmv2Charm)
    p4c_container, _ = make_p4c_container(tmp_path)
    bmv2_container, _ = make_bmv2_container(tmp_path, can_connect=False)
    state_in = testing.State(containers={p4c_container, bmv2_container}, config=DEFAULT_CONFIG)

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(ctx.on.action("reprogram", params={"p4-source": SAMPLE_P4_SOURCE}), state_in)

    assert "bmv2 container is not ready" in exc_info.value.message


@pytest.mark.parametrize(
    "config",
    [
        {"thrift-port": 0, "interfaces": ""},
        {"thrift-port": 70000, "interfaces": ""},
        {"thrift-port": 9090, "interfaces": "not-a-valid-interface"},
    ],
)
def test_reprogram_fails_with_invalid_configuration(tmp_path, config):
    ctx = testing.Context(Bmv2Charm)
    p4c_container, _ = make_p4c_container(tmp_path)
    bmv2_container, _ = make_bmv2_container(tmp_path)
    state_in = testing.State(containers={p4c_container, bmv2_container}, config=config)

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(ctx.on.action("reprogram", params={"p4-source": SAMPLE_P4_SOURCE}), state_in)

    assert "invalid charm configuration" in exc_info.value.message


# -- reprogram: compile failure must not disturb the running switch ----------------


def test_reprogram_compile_failure_leaves_old_program_and_entries_untouched(tmp_path):
    """A failed compile must not stop or replace the currently running switch."""
    ctx = testing.Context(Bmv2Charm)
    p4c_container, _ = make_p4c_container(
        tmp_path,
        compile_ok=False,
        compiler_stderr="switch.p4(3): error: syntax error\n",
    )
    old_program = b'{"program": "old-and-working"}'
    bmv2_container, bmv2_root = make_bmv2_container(
        tmp_path, existing_program=old_program, switch_running=True
    )
    state_in = testing.State(containers={p4c_container, bmv2_container}, config=DEFAULT_CONFIG)

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(ctx.on.action("reprogram", params={"p4-source": "totally broken p4"}), state_in)

    assert "p4c compilation failed" in exc_info.value.message
    assert "syntax error" in exc_info.value.message

    # The old program's JSON, on disk in the bmv2 container, must be unchanged.
    assert (bmv2_root / "switch.json").read_bytes() == old_program
    # The old, still-running service must not have been touched.
    bmv2_out = get_container_from_state(exc_info.value.state, BMV2_CONTAINER)
    assert bmv2_out.service_statuses[SWITCH_SERVICE] == ops.pebble.ServiceStatus.ACTIVE
    assert get_switch_plan_command(bmv2_out) == " ".join(
        bmv2.build_switch_command(RUNTIME_JSON_PATH, 9090, [])
    )


# -- reprogram: edge scenario - replacing a running program clears its state -------


def test_reprogram_replaces_a_running_program_and_wipes_its_table_state(tmp_path):
    """Reprogramming an already-running switch must fully replace the old program.

    BMv2 only keeps table entries in the running simple_switch process's memory,
    so the charm always stops the service and starts a fresh one against the new
    JSON rather than trying to patch the existing process. This test checks that
    mechanism: the old program's file content and layer are completely replaced,
    not merged with the new one, and the service ends up running again (freshly
    started, with none of the old program's table state carried over).
    """
    ctx = testing.Context(Bmv2Charm)
    new_program = b'{"program": "v2-replacement"}'
    p4c_container, _ = make_p4c_container(tmp_path, compiled_json=new_program)
    old_program = b'{"program": "v1-original"}'
    bmv2_container, bmv2_root = make_bmv2_container(
        tmp_path, existing_program=old_program, switch_running=True
    )
    state_in = testing.State(containers={p4c_container, bmv2_container}, config=DEFAULT_CONFIG)

    state_out = ctx.run(
        ctx.on.action("reprogram", params={"p4-source": SAMPLE_P4_SOURCE}), state_in
    )

    # The old program's bytes are gone; only the new program remains on disk.
    assert (bmv2_root / "switch.json").read_bytes() == new_program
    bmv2_out = get_container_from_state(state_out, BMV2_CONTAINER)
    # The switch was restarted (still active), against the new program.
    assert bmv2_out.service_statuses[SWITCH_SERVICE] == ops.pebble.ServiceStatus.ACTIVE
    assert get_switch_plan_command(bmv2_out) == " ".join(
        bmv2.build_switch_command(RUNTIME_JSON_PATH, 9090, [])
    )
    assert "cleared" in get_action_results(ctx)["note"]


# -- table-add / table-delete / table-clear: guard clauses ------------------------


def test_table_add_fails_when_no_program_is_loaded(tmp_path):
    ctx = testing.Context(Bmv2Charm)
    bmv2_container, _ = make_bmv2_container(tmp_path)
    state_in = testing.State(containers={bmv2_container}, config=DEFAULT_CONFIG)

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(
            ctx.on.action(
                "table-add",
                params={"table": "ipv4_lpm", "action": "forward", "match": "10.0.0.0/24"},
            ),
            state_in,
        )

    assert "no P4 program is currently running" in exc_info.value.message


def test_table_add_fails_when_bmv2_container_not_ready(tmp_path):
    ctx = testing.Context(Bmv2Charm)
    bmv2_container, _ = make_bmv2_container(tmp_path, can_connect=False)
    state_in = testing.State(containers={bmv2_container}, config=DEFAULT_CONFIG)

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(
            ctx.on.action(
                "table-add",
                params={"table": "ipv4_lpm", "action": "forward", "match": "10.0.0.0/24"},
            ),
            state_in,
        )

    assert "bmv2 container is not ready" in exc_info.value.message


def test_table_add_fails_with_no_match_keys(tmp_path):
    """An empty 'match' param should be rejected before ever touching the CLI."""
    ctx = testing.Context(Bmv2Charm)
    bmv2_container, _ = make_bmv2_container(
        tmp_path, existing_program=b'{"program": "v1"}', switch_running=True
    )
    state_in = testing.State(containers={bmv2_container}, config=DEFAULT_CONFIG)

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(
            ctx.on.action(
                "table-add",
                params={"table": "ipv4_lpm", "action": "forward", "match": ""},
            ),
            state_in,
        )

    assert "at least one match key is required" in exc_info.value.message


# -- table-add / table-delete / table-clear: happy paths --------------------------


def test_table_add_issues_the_expected_simple_switch_cli_command(tmp_path):
    ctx = testing.Context(Bmv2Charm)
    cli_execs = {
        testing.Exec(
            [bmv2.CLI_COMMAND, "--thrift-port", "9090"],
            return_code=0,
            stdout="Entry has been added with handle 0\n",
        )
    }
    bmv2_container, _ = make_bmv2_container(
        tmp_path,
        existing_program=b'{"program": "v1"}',
        switch_running=True,
        cli_execs=cli_execs,
    )
    state_in = testing.State(containers={bmv2_container}, config=DEFAULT_CONFIG)

    ctx.run(
        ctx.on.action(
            "table-add",
            params={
                "table": "ipv4_lpm",
                "action": "forward",
                "match": "10.0.0.0/24",
                "action-params": "1",
            },
        ),
        state_in,
    )

    expected_command = bmv2.build_table_add_command(
        table="ipv4_lpm", action="forward", match_keys=["10.0.0.0/24"], action_params=["1"]
    )
    assert get_action_results(ctx)["command"] == expected_command
    assert get_action_results(ctx)["result"] == "Entry has been added with handle 0"


def test_table_add_fails_when_cli_rejects_the_command(tmp_path):
    """Cover the REPL-style rejection path.

    simple_switch_CLI is a REPL that exits 0 even on bad commands, so the
    charm must detect the rejection from its printed output.
    """
    ctx = testing.Context(Bmv2Charm)
    cli_execs = {
        testing.Exec(
            [bmv2.CLI_COMMAND, "--thrift-port", "9090"],
            return_code=0,
            stdout="Invalid table name\n",
        )
    }
    bmv2_container, _ = make_bmv2_container(
        tmp_path,
        existing_program=b'{"program": "v1"}',
        switch_running=True,
        cli_execs=cli_execs,
    )
    state_in = testing.State(containers={bmv2_container}, config=DEFAULT_CONFIG)

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(
            ctx.on.action(
                "table-add",
                params={"table": "no_such_table", "action": "forward", "match": "10.0.0.0/24"},
            ),
            state_in,
        )

    assert "rejected the command" in exc_info.value.message
    assert "Invalid table name" in exc_info.value.message


def test_table_delete_issues_the_expected_command(tmp_path):
    ctx = testing.Context(Bmv2Charm)
    cli_execs = {
        testing.Exec(
            [bmv2.CLI_COMMAND, "--thrift-port", "9090"],
            return_code=0,
            stdout="Entry has been deleted.\n",
        )
    }
    bmv2_container, _ = make_bmv2_container(
        tmp_path,
        existing_program=b'{"program": "v1"}',
        switch_running=True,
        cli_execs=cli_execs,
    )
    state_in = testing.State(containers={bmv2_container}, config=DEFAULT_CONFIG)

    ctx.run(ctx.on.action("table-delete", params={"table": "ipv4_lpm", "handle": 0}), state_in)

    assert get_action_results(ctx)["command"] == "table_delete ipv4_lpm 0"
    assert get_action_results(ctx)["result"] == "Entry has been deleted."


def test_table_clear_issues_the_expected_command(tmp_path):
    ctx = testing.Context(Bmv2Charm)
    cli_execs = {
        testing.Exec(
            [bmv2.CLI_COMMAND, "--thrift-port", "9090"],
            return_code=0,
            stdout="Table has been cleared.\n",
        )
    }
    bmv2_container, _ = make_bmv2_container(
        tmp_path,
        existing_program=b'{"program": "v1"}',
        switch_running=True,
        cli_execs=cli_execs,
    )
    state_in = testing.State(containers={bmv2_container}, config=DEFAULT_CONFIG)

    ctx.run(ctx.on.action("table-clear", params={"table": "ipv4_lpm"}), state_in)

    assert get_action_results(ctx)["command"] == "table_clear ipv4_lpm"
    assert get_action_results(ctx)["result"] == "Table has been cleared."


def test_table_clear_uses_the_configured_thrift_port(tmp_path):
    """Table actions must honor the 'thrift-port' config, not just the default."""
    ctx = testing.Context(Bmv2Charm)
    cli_execs = {
        testing.Exec(
            [bmv2.CLI_COMMAND, "--thrift-port", "9091"],
            return_code=0,
            stdout="Table has been cleared.\n",
        )
    }
    bmv2_container, _ = make_bmv2_container(
        tmp_path,
        existing_program=b'{"program": "v1"}',
        switch_running=True,
        thrift_port=9091,
        cli_execs=cli_execs,
    )
    state_in = testing.State(
        containers={bmv2_container}, config={"thrift-port": 9091, "interfaces": ""}
    )

    ctx.run(ctx.on.action("table-clear", params={"table": "ipv4_lpm"}), state_in)

    assert get_action_results(ctx)["result"] == "Table has been cleared."


# -- Additional edge cases --------------------------------------------------------


def test_pebble_ready_blocked_when_program_loaded_but_switch_stopped(tmp_path):
    """A loaded-but-stopped switch is a distinct, reportable state from 'no program'."""
    ctx = testing.Context(Bmv2Charm)
    p4c_container, _ = make_p4c_container(tmp_path)
    bmv2_container, _ = make_bmv2_container(
        tmp_path, existing_program=b'{"program": "v1"}', switch_running=False
    )
    state_in = testing.State(containers={p4c_container, bmv2_container}, config=DEFAULT_CONFIG)

    state_out = ctx.run(ctx.on.pebble_ready(bmv2_container), state_in)

    assert isinstance(state_out.unit_status, testing.BlockedStatus)
    assert "not running" in state_out.unit_status.message


def test_table_delete_fails_with_empty_table_name(tmp_path):
    """Table-delete should reject an empty table name before touching the CLI."""
    ctx = testing.Context(Bmv2Charm)
    bmv2_container, _ = make_bmv2_container(
        tmp_path, existing_program=b'{"program": "v1"}', switch_running=True
    )
    state_in = testing.State(containers={bmv2_container}, config=DEFAULT_CONFIG)

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(ctx.on.action("table-delete", params={"table": "  ", "handle": 0}), state_in)

    assert "a table name is required" in exc_info.value.message


def test_table_clear_fails_with_empty_table_name(tmp_path):
    """Table-clear should reject an empty table name before touching the CLI."""
    ctx = testing.Context(Bmv2Charm)
    bmv2_container, _ = make_bmv2_container(
        tmp_path, existing_program=b'{"program": "v1"}', switch_running=True
    )
    state_in = testing.State(containers={bmv2_container}, config=DEFAULT_CONFIG)

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(ctx.on.action("table-clear", params={"table": ""}), state_in)

    assert "a table name is required" in exc_info.value.message


def test_table_add_fails_with_invalid_thrift_port_config(tmp_path):
    """The table actions must validate 'thrift-port' too, not just reprogram."""
    ctx = testing.Context(Bmv2Charm)
    bmv2_container, _ = make_bmv2_container(
        tmp_path, existing_program=b'{"program": "v1"}', switch_running=True
    )
    state_in = testing.State(
        containers={bmv2_container}, config={"thrift-port": 99999, "interfaces": ""}
    )

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(
            ctx.on.action(
                "table-add",
                params={"table": "ipv4_lpm", "action": "forward", "match": "10.0.0.0/24"},
            ),
            state_in,
        )

    assert "invalid charm configuration" in exc_info.value.message


def test_table_clear_fails_when_simple_switch_cli_process_errors(tmp_path):
    """A non-zero simple_switch_CLI exit (e.g. it crashed) must fail the action."""
    ctx = testing.Context(Bmv2Charm)
    cli_execs = {
        testing.Exec(
            [bmv2.CLI_COMMAND, "--thrift-port", "9090"],
            return_code=1,
            stderr="thrift: connection refused\n",
        )
    }
    bmv2_container, _ = make_bmv2_container(
        tmp_path,
        existing_program=b'{"program": "v1"}',
        switch_running=True,
        cli_execs=cli_execs,
    )
    state_in = testing.State(containers={bmv2_container}, config=DEFAULT_CONFIG)

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(ctx.on.action("table-clear", params={"table": "ipv4_lpm"}), state_in)

    assert "simple_switch_CLI failed" in exc_info.value.message
    assert "connection refused" in exc_info.value.message
