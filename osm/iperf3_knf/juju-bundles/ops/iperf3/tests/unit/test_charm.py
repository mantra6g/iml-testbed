# Copyright 2026 tomasagata
# See LICENSE file for licensing details.
#
# To learn more about testing, see https://documentation.ubuntu.com/ops/latest/explanation/testing/

import ops
import pytest
from ops import testing

from charm import CLIENT_SERVICE, CONTAINER_NAME, SERVER_SERVICE, Iperf3Charm

IDLE_STATUS = "idle (not running as client or server)"


def get_service_plan(container: testing.Container, service_name: str) -> dict:
    """Return the plan dict for a single Pebble service, for asserting on its fields."""
    services = container.plan.to_dict().get("services") or {}
    return dict(services.get(service_name) or {})


def get_container_from_state(state, name: str) -> testing.Container:
    """Fetch a container from a (possibly None) post-action State, for assertions."""
    assert state is not None
    return state.get_container(name)


def make_container(
    *,
    can_connect: bool = True,
    server_running: bool = False,
    client_running: bool = False,
) -> testing.Container:
    """Build a mock iperf3 Container in the given running state."""
    service_statuses = {}
    layers = {}
    if server_running:
        service_statuses[SERVER_SERVICE] = ops.pebble.ServiceStatus.ACTIVE
        layers["iperf3"] = ops.pebble.Layer(
            {
                "services": {
                    SERVER_SERVICE: {
                        "override": "replace",
                        "command": "iperf3 -s -p 5201",
                        "startup": "enabled",
                    }
                }
            }
        )
    if client_running:
        service_statuses[CLIENT_SERVICE] = ops.pebble.ServiceStatus.ACTIVE
        layers["iperf3"] = ops.pebble.Layer(
            {
                "services": {
                    CLIENT_SERVICE: {
                        "override": "replace",
                        "command": "iperf3 -c 10.0.0.1 -p 5201",
                        "startup": "enabled",
                    }
                }
            }
        )
    return testing.Container(
        CONTAINER_NAME,
        can_connect=can_connect,
        service_statuses=service_statuses,
        layers=layers,
    )


# -- Lifecycle -----------------------------------------------------------------


def test_pebble_ready_sets_idle_status():
    """The unit should be Active/idle once Pebble is ready, without starting a role."""
    ctx = testing.Context(Iperf3Charm)
    container_in = make_container()
    state_in = testing.State(containers={container_in})

    state_out = ctx.run(ctx.on.pebble_ready(container_in), state_in)

    assert state_out.unit_status == testing.ActiveStatus(IDLE_STATUS)
    container_out = state_out.get_container(CONTAINER_NAME)
    assert not container_out.service_statuses


def test_config_changed_blocks_on_invalid_protocol():
    """An invalid 'protocol' config value should block the unit."""
    ctx = testing.Context(Iperf3Charm)
    state_in = testing.State(
        containers={make_container()},
        config={"protocol": "sctp", "server-address": "", "port": 5201},
    )

    state_out = ctx.run(ctx.on.config_changed(), state_in)

    assert isinstance(state_out.unit_status, testing.BlockedStatus)
    assert "sctp" in state_out.unit_status.message


def test_config_changed_clears_block_on_valid_protocol():
    """A previously blocked unit should return to Active once config is fixed."""
    ctx = testing.Context(Iperf3Charm)
    state_in = testing.State(
        containers={make_container()},
        config={"protocol": "udp", "server-address": "", "port": 5201},
        unit_status=testing.BlockedStatus("invalid protocol 'sctp'"),
    )

    state_out = ctx.run(ctx.on.config_changed(), state_in)

    assert state_out.unit_status == testing.ActiveStatus(IDLE_STATUS)


# -- start-server ----------------------------------------------------------------


def test_start_server_issues_expected_command():
    """start-server should build the correct TCP command and start the service."""
    ctx = testing.Context(Iperf3Charm)
    container_in = make_container()
    state_in = testing.State(
        containers={container_in}, config={"protocol": "tcp", "server-address": "", "port": 5201}
    )

    state_out = ctx.run(ctx.on.action("start-server"), state_in)

    assert ctx.action_results == {"command": "iperf3 -s -p 5201"}
    container_out = state_out.get_container(CONTAINER_NAME)
    assert container_out.service_statuses[SERVER_SERVICE] == ops.pebble.ServiceStatus.ACTIVE
    service = get_service_plan(container_out, SERVER_SERVICE)
    assert service.get("command") == "iperf3 -s -p 5201"
    assert service.get("startup") == "enabled"
    assert isinstance(state_out.unit_status, testing.ActiveStatus)


def test_start_server_udp_and_one_off_and_port_override():
    """UDP protocol, a custom port and one-off should all be reflected in the command."""
    ctx = testing.Context(Iperf3Charm)
    container_in = make_container()
    state_in = testing.State(
        containers={container_in}, config={"protocol": "udp", "server-address": "", "port": 5201}
    )

    ctx.run(ctx.on.action("start-server", params={"port": 6000, "one-off": True}), state_in)

    assert ctx.action_results == {"command": "iperf3 -s -p 6000 -u -1"}


def test_start_server_fails_when_container_not_ready():
    """start-server should fail cleanly if the workload container can't be reached."""
    ctx = testing.Context(Iperf3Charm)
    container_in = make_container(can_connect=False)
    state_in = testing.State(
        containers={container_in}, config={"protocol": "tcp", "server-address": "", "port": 5201}
    )

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(ctx.on.action("start-server"), state_in)

    assert "not ready" in exc_info.value.message


def test_start_server_fails_with_invalid_protocol_config():
    """start-server should refuse to run with a misconfigured protocol."""
    ctx = testing.Context(Iperf3Charm)
    container_in = make_container()
    state_in = testing.State(
        containers={container_in}, config={"protocol": "sctp", "server-address": "", "port": 5201}
    )

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(ctx.on.action("start-server"), state_in)

    assert "invalid charm configuration" in exc_info.value.message


def test_start_server_conflicts_with_running_client():
    """start-server must refuse to run while iperf3 is already a client (key conflict scenario)."""
    ctx = testing.Context(Iperf3Charm)
    container_in = make_container(client_running=True)
    state_in = testing.State(
        containers={container_in}, config={"protocol": "tcp", "server-address": "", "port": 5201}
    )

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(ctx.on.action("start-server"), state_in)

    assert "already running as a client" in exc_info.value.message
    # The client service must be left untouched.
    container_out = get_container_from_state(exc_info.value.state, CONTAINER_NAME)
    assert container_out.service_statuses[CLIENT_SERVICE] == ops.pebble.ServiceStatus.ACTIVE


def test_start_server_restarts_existing_server_with_new_params():
    """Re-running start-server while already a server should just apply the new params."""
    ctx = testing.Context(Iperf3Charm)
    container_in = make_container(server_running=True)
    state_in = testing.State(
        containers={container_in}, config={"protocol": "tcp", "server-address": "", "port": 5201}
    )

    state_out = ctx.run(ctx.on.action("start-server", params={"port": 7000}), state_in)

    container_out = state_out.get_container(CONTAINER_NAME)
    assert container_out.service_statuses[SERVER_SERVICE] == ops.pebble.ServiceStatus.ACTIVE
    assert get_service_plan(container_out, SERVER_SERVICE).get("command") == "iperf3 -s -p 7000"


# -- stop-server -------------------------------------------------------------------


def test_stop_server_stops_running_service():
    """stop-server should stop the service and disable it."""
    ctx = testing.Context(Iperf3Charm)
    container_in = make_container(server_running=True)
    state_in = testing.State(containers={container_in})

    state_out = ctx.run(ctx.on.action("stop-server"), state_in)

    container_out = state_out.get_container(CONTAINER_NAME)
    assert container_out.service_statuses[SERVER_SERVICE] == ops.pebble.ServiceStatus.INACTIVE
    assert get_service_plan(container_out, SERVER_SERVICE).get("startup") == "disabled"
    assert state_out.unit_status == testing.ActiveStatus(IDLE_STATUS)


def test_stop_server_fails_when_not_running():
    """stop-server should fail with a clear message when there is nothing to stop."""
    ctx = testing.Context(Iperf3Charm)
    container_in = make_container()
    state_in = testing.State(containers={container_in})

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(ctx.on.action("stop-server"), state_in)

    assert "not currently running as a server" in exc_info.value.message


# -- start-client ------------------------------------------------------------------


def test_start_client_issues_expected_command_from_config():
    """start-client should use the configured server-address as the default target."""
    ctx = testing.Context(Iperf3Charm)
    container_in = make_container()
    state_in = testing.State(
        containers={container_in},
        config={"protocol": "tcp", "server-address": "10.20.30.40", "port": 5201},
    )

    ctx.run(ctx.on.action("start-client"), state_in)

    assert ctx.action_results == {"command": "iperf3 -c 10.20.30.40 -p 5201"}


def test_start_client_target_param_overrides_config():
    """An explicit 'target' action param should take priority over the config default."""
    ctx = testing.Context(Iperf3Charm)
    container_in = make_container()
    state_in = testing.State(
        containers={container_in},
        config={"protocol": "udp", "server-address": "10.20.30.40", "port": 5201},
    )

    ctx.run(
        ctx.on.action(
            "start-client",
            params={
                "target": "server.example.com",
                "duration": 10,
                "parallel": 4,
                "reverse": True,
            },
        ),
        state_in,
    )

    assert ctx.action_results == {
        "command": "iperf3 -c server.example.com -p 5201 -u -t 10 -P 4 -R"
    }


def test_start_client_fails_without_target_configured():
    """start-client must fail clearly when there is no server address configured."""
    ctx = testing.Context(Iperf3Charm)
    container_in = make_container()
    state_in = testing.State(
        containers={container_in}, config={"protocol": "tcp", "server-address": "", "port": 5201}
    )

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(ctx.on.action("start-client"), state_in)

    assert "no target server configured" in exc_info.value.message


def test_start_client_conflicts_with_running_server():
    """start-client must refuse to run while iperf3 is already a server (key conflict scenario)."""
    ctx = testing.Context(Iperf3Charm)
    container_in = make_container(server_running=True)
    state_in = testing.State(
        containers={container_in},
        config={"protocol": "tcp", "server-address": "10.0.0.1", "port": 5201},
    )

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(ctx.on.action("start-client"), state_in)

    assert "already running as a server" in exc_info.value.message
    container_out = get_container_from_state(exc_info.value.state, CONTAINER_NAME)
    assert container_out.service_statuses[SERVER_SERVICE] == ops.pebble.ServiceStatus.ACTIVE


def test_start_client_fails_with_invalid_protocol_config():
    """start-client should refuse to run with a misconfigured protocol."""
    ctx = testing.Context(Iperf3Charm)
    container_in = make_container()
    state_in = testing.State(
        containers={container_in},
        config={"protocol": "sctp", "server-address": "10.0.0.1", "port": 5201},
    )

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(ctx.on.action("start-client"), state_in)

    assert "invalid charm configuration" in exc_info.value.message


# -- stop-client -------------------------------------------------------------------


def test_stop_client_stops_running_service():
    """stop-client should stop the service and disable it."""
    ctx = testing.Context(Iperf3Charm)
    container_in = make_container(client_running=True)
    state_in = testing.State(containers={container_in})

    state_out = ctx.run(ctx.on.action("stop-client"), state_in)

    container_out = state_out.get_container(CONTAINER_NAME)
    assert container_out.service_statuses[CLIENT_SERVICE] == ops.pebble.ServiceStatus.INACTIVE
    assert get_service_plan(container_out, CLIENT_SERVICE).get("startup") == "disabled"
    assert state_out.unit_status == testing.ActiveStatus(IDLE_STATUS)


def test_stop_client_fails_when_not_running():
    """stop-client should fail with a clear message when there is nothing to stop."""
    ctx = testing.Context(Iperf3Charm)
    container_in = make_container()
    state_in = testing.State(containers={container_in})

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(ctx.on.action("stop-client"), state_in)

    assert "not currently running as a client" in exc_info.value.message


def test_start_client_fails_when_container_not_ready():
    """start-client should fail cleanly if the workload container can't be reached."""
    ctx = testing.Context(Iperf3Charm)
    container_in = make_container(can_connect=False)
    state_in = testing.State(
        containers={container_in},
        config={"protocol": "tcp", "server-address": "10.0.0.1", "port": 5201},
    )

    with pytest.raises(testing.ActionFailed) as exc_info:
        ctx.run(ctx.on.action("start-client"), state_in)

    assert "not ready" in exc_info.value.message
