#!/usr/bin/env python3
# Copyright 2026 tomasagata
# See LICENSE file for licensing details.

"""Charm that drives an iperf3 workload container as either a server or a client."""

import logging
from typing import Optional

import ops

# A standalone module for workload-specific logic (no charming concerns):
import iperf3

logger = logging.getLogger(__name__)

CONTAINER_NAME = "iperf3"
SERVER_SERVICE = "iperf3-server"
CLIENT_SERVICE = "iperf3-client"

# Placeholder command used to keep a disabled service's Pebble layer valid
# (Pebble requires every service to have a non-empty command).
IDLE_COMMAND = ["iperf3", "-v"]


class Iperf3Charm(ops.CharmBase):
    """Charm that runs iperf3 as a server or a client, never both at once."""

    def __init__(self, framework: ops.Framework):
        super().__init__(framework)
        self.container = self.unit.get_container(CONTAINER_NAME)

        framework.observe(self.on[CONTAINER_NAME].pebble_ready, self._on_pebble_ready)
        framework.observe(self.on.config_changed, self._on_config_changed)
        framework.observe(self.on["start-server"].action, self._on_start_server_action)
        framework.observe(self.on["stop-server"].action, self._on_stop_server_action)
        framework.observe(self.on["start-client"].action, self._on_start_client_action)
        framework.observe(self.on["stop-client"].action, self._on_stop_client_action)

    # -- Lifecycle events --------------------------------------------------

    def _on_pebble_ready(self, event: ops.PebbleReadyEvent):
        """Handle pebble-ready event by marking the unit idle (no role started yet)."""
        self.unit.status = ops.ActiveStatus("idle (not running as client or server)")

    def _on_config_changed(self, event: ops.ConfigChangedEvent):
        """Validate the protocol configuration and reflect problems in the unit status."""
        try:
            iperf3.validate_protocol(str(self.config.get("protocol", "tcp")))
        except iperf3.ConfigurationError as err:
            self.unit.status = ops.BlockedStatus(str(err))
            return
        if isinstance(self.unit.status, ops.BlockedStatus):
            self.unit.status = ops.ActiveStatus("idle (not running as client or server)")

    # -- Actions: server -----------------------------------------------------

    def _on_start_server_action(self, event: ops.ActionEvent):
        """Start iperf3 as a server, refusing if it is currently running as a client."""
        if not self.container.can_connect():
            event.fail("workload container is not ready yet")
            return
        if self._is_running(CLIENT_SERVICE):
            event.fail(
                "cannot start iperf3 as a server: it is already running as a client. "
                "Run the stop-client action first."
            )
            return

        try:
            protocol, port = self._resolve_protocol_and_port(event)
            one_off = bool(event.params.get("one-off", False))
            command = iperf3.build_server_command(port=port, protocol=protocol, one_off=one_off)
        except iperf3.ConfigurationError as err:
            event.fail(str(err))
            return

        self._replace_service(SERVER_SERVICE, command)
        self.unit.status = ops.ActiveStatus(f"running iperf3 server on port {port}/{protocol}")
        event.set_results({"command": " ".join(command)})

    def _on_stop_server_action(self, event: ops.ActionEvent):
        """Stop the running iperf3 server, failing if it isn't running."""
        if not self.container.can_connect():
            event.fail("workload container is not ready yet")
            return
        if not self._is_running(SERVER_SERVICE):
            event.fail("iperf3 is not currently running as a server")
            return
        self._disable_service(SERVER_SERVICE)
        self.unit.status = ops.ActiveStatus("idle (not running as client or server)")
        event.set_results({"result": "iperf3 server stopped"})

    # -- Actions: client -----------------------------------------------------

    def _on_start_client_action(self, event: ops.ActionEvent):
        """Start iperf3 as a client, refusing if it is currently running as a server."""
        if not self.container.can_connect():
            event.fail("workload container is not ready yet")
            return
        if self._is_running(SERVER_SERVICE):
            event.fail(
                "cannot start iperf3 as a client: it is already running as a server. "
                "Run the stop-server action first."
            )
            return

        target = event.params.get("target") or self.config.get("server-address")
        if not target or not str(target).strip():
            event.fail(
                "no target server configured: set the 'server-address' config option "
                "or pass a 'target' parameter to this action"
            )
            return

        try:
            protocol, port = self._resolve_protocol_and_port(event)
            command = iperf3.build_client_command(
                target=str(target),
                port=port,
                protocol=protocol,
                duration=event.params.get("duration"),
                bandwidth=event.params.get("bandwidth"),
                parallel=event.params.get("parallel"),
                reverse=bool(event.params.get("reverse", False)),
            )
        except iperf3.ConfigurationError as err:
            event.fail(str(err))
            return

        self._replace_service(CLIENT_SERVICE, command)
        self.unit.status = ops.ActiveStatus(f"running iperf3 client against {target}")
        event.set_results({"command": " ".join(command)})

    def _on_stop_client_action(self, event: ops.ActionEvent):
        """Stop the running iperf3 client, failing if it isn't running."""
        if not self.container.can_connect():
            event.fail("workload container is not ready yet")
            return
        if not self._is_running(CLIENT_SERVICE):
            event.fail("iperf3 is not currently running as a client")
            return
        self._disable_service(CLIENT_SERVICE)
        self.unit.status = ops.ActiveStatus("idle (not running as client or server)")
        event.set_results({"result": "iperf3 client stopped"})

    # -- Helpers --------------------------------------------------------------

    def _resolve_protocol_and_port(self, event: ops.ActionEvent) -> tuple[str, int]:
        """Resolve the protocol/port to use for an action, from params or charm config.

        Raises:
            iperf3.ConfigurationError: if the configured protocol or port are invalid.
        """
        try:
            protocol = iperf3.validate_protocol(str(self.config.get("protocol", "tcp")))
        except iperf3.ConfigurationError as err:
            raise iperf3.ConfigurationError(f"invalid charm configuration: {err}") from err

        raw_port = event.params.get("port")
        if raw_port is None:
            raw_port = self.config.get("port", iperf3.DEFAULT_PORT)
        try:
            port = int(raw_port)
        except (TypeError, ValueError) as err:
            raise iperf3.ConfigurationError(
                f"invalid port {raw_port!r}: must be an integer"
            ) from err

        return protocol, port

    def _is_running(self, service_name: str) -> bool:
        """Return whether the given Pebble service is currently running."""
        info = self.container.get_services().get(service_name)
        return info is not None and info.is_running()

    def _replace_service(self, service_name: str, command: list[str]) -> None:
        """(Re)start `service_name` with `command`, stopping the other role first."""
        other = CLIENT_SERVICE if service_name == SERVER_SERVICE else SERVER_SERVICE
        if self._is_running(other):
            self.container.stop(other)
        self._set_service_layer(other, command=None, enabled=False)

        if self._is_running(service_name):
            self.container.stop(service_name)
        self._set_service_layer(service_name, command=command, enabled=True)
        self.container.start(service_name)

    def _disable_service(self, service_name: str) -> None:
        """Stop `service_name` and mark it disabled so it won't auto-restart."""
        self.container.stop(service_name)
        self._set_service_layer(service_name, command=None, enabled=False)

    def _set_service_layer(
        self, service_name: str, command: Optional[list[str]], enabled: bool
    ) -> None:
        """Add/replace a single-service Pebble layer for `service_name`."""
        service: ops.pebble.ServiceDict = {
            "override": "replace",
            "summary": f"iperf3 ({service_name})",
            "startup": "enabled" if enabled else "disabled",
            "command": " ".join(command if command is not None else IDLE_COMMAND),
        }
        layer = ops.pebble.Layer({"services": {service_name: service}})
        self.container.add_layer(CONTAINER_NAME, layer, combine=True)


if __name__ == "__main__":  # pragma: nocover
    ops.main(Iperf3Charm)
