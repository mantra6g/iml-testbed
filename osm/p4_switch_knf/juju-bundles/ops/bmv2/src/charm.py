#!/usr/bin/env python3
# Copyright 2026 tomasagata
# See LICENSE file for licensing details.

"""Charm that drives a BMv2 (behavioral model v2) P4-programmable switch.

Two sidecar containers are involved:
  * ``p4c``  - a compiler container used to translate a P4_16 program's source
    into the JSON configuration BMv2 understands.
  * ``bmv2`` - runs ``simple_switch`` against that JSON, and is queried/updated
    at runtime via ``simple_switch_CLI`` to manage match-action table entries.
"""

import logging
from typing import Optional

import ops

# A standalone module for workload-specific logic (no charming concerns):
import bmv2

logger = logging.getLogger(__name__)

P4C_CONTAINER = "p4c"
BMV2_CONTAINER = "bmv2"
SWITCH_SERVICE = "simple-switch"

# Path the P4 source is pushed to, and the compiled JSON pulled from, inside
# the p4c container.
P4_SOURCE_PATH = "/tmp/switch.p4"
COMPILED_JSON_PATH = "/tmp/switch.json"

# Path the compiled JSON is pushed to inside the bmv2 container.
RUNTIME_JSON_PATH = "/config/switch.json"


class Bmv2Charm(ops.CharmBase):
    """Charm that compiles and runs P4 programs on a BMv2 software switch."""

    def __init__(self, framework: ops.Framework):
        super().__init__(framework)
        self.p4c_container = self.unit.get_container(P4C_CONTAINER)
        self.bmv2_container = self.unit.get_container(BMV2_CONTAINER)

        framework.observe(self.on[P4C_CONTAINER].pebble_ready, self._on_pebble_ready)
        framework.observe(self.on[BMV2_CONTAINER].pebble_ready, self._on_pebble_ready)
        framework.observe(self.on["reprogram"].action, self._on_reprogram_action)
        framework.observe(self.on["table-add"].action, self._on_table_add_action)
        framework.observe(self.on["table-delete"].action, self._on_table_delete_action)
        framework.observe(self.on["table-clear"].action, self._on_table_clear_action)

    # -- Lifecycle -------------------------------------------------------------

    def _on_pebble_ready(self, event: ops.PebbleReadyEvent):
        """Refresh unit status whenever either sidecar container becomes ready."""
        self._update_status()

    def _update_status(self) -> None:
        """Derive unit status entirely from the current container/Pebble state."""
        if not self.p4c_container.can_connect() or not self.bmv2_container.can_connect():
            self.unit.status = ops.MaintenanceStatus("waiting for containers to start")
            return
        if not self._is_program_loaded():
            self.unit.status = ops.BlockedStatus("no P4 program loaded; run the reprogram action")
            return
        if self._is_switch_running():
            self.unit.status = ops.ActiveStatus("switch running")
        else:
            self.unit.status = ops.BlockedStatus(
                "P4 program loaded but simple_switch is not running"
            )

    def _is_program_loaded(self) -> bool:
        """Return whether a switch service layer has been configured at all."""
        return SWITCH_SERVICE in self.bmv2_container.get_plan().services

    def _is_switch_running(self) -> bool:
        """Return whether the simple_switch Pebble service is currently active."""
        info = self.bmv2_container.get_services().get(SWITCH_SERVICE)
        return info is not None and info.is_running()

    # -- reprogram ---------------------------------------------------------------

    def _on_reprogram_action(self, event: ops.ActionEvent):
        """Compile a new P4 program and load it, replacing the running one.

        Restarting simple_switch to apply the new program is what drops every
        table entry that belonged to the previous one: BMv2 keeps table state
        only in the running process's memory, never on disk.
        """
        source = str(event.params.get("p4-source", ""))
        if not source.strip():
            event.fail("the 'p4-source' parameter is required and must not be empty")
            return
        if not self.p4c_container.can_connect():
            event.fail("the p4c container is not ready yet")
            return
        if not self.bmv2_container.can_connect():
            event.fail("the bmv2 container is not ready yet")
            return

        try:
            thrift_port = bmv2.validate_thrift_port(
                int(self.config.get("thrift-port", bmv2.DEFAULT_THRIFT_PORT))
            )
            interfaces = bmv2.parse_interfaces(str(self.config.get("interfaces", "")))
        except bmv2.ConfigurationError as err:
            event.fail(f"invalid charm configuration: {err}")
            return

        # 1. Push the P4 source into the compiler container and compile it. If
        #    this fails, the currently-running switch and its table entries are
        #    left completely untouched.
        self.p4c_container.push(P4_SOURCE_PATH, source, make_dirs=True)
        compile_command = bmv2.build_p4c_command(P4_SOURCE_PATH, COMPILED_JSON_PATH)
        process = self.p4c_container.exec(compile_command, working_dir="/tmp")
        try:
            compiler_stdout, _ = process.wait_output()
        except ops.pebble.ExecError as err:
            details = err.stderr or err.stdout or str(err)
            event.fail(f"p4c compilation failed:\n{details}")
            return

        # 2. Pull the compiled JSON out of the compiler container...
        compiled_json = self.p4c_container.pull(COMPILED_JSON_PATH, encoding=None).read()

        # 3. ...and push it into the switch container.
        self.bmv2_container.push(RUNTIME_JSON_PATH, compiled_json, make_dirs=True)

        # 4. (Re)start simple_switch with the new program.
        switch_command = bmv2.build_switch_command(RUNTIME_JSON_PATH, thrift_port, interfaces)
        service: ops.pebble.ServiceDict = {
            "override": "replace",
            "summary": "BMv2 simple_switch",
            "startup": "enabled",
            "command": " ".join(switch_command),
        }
        layer = ops.pebble.Layer({"services": {SWITCH_SERVICE: service}})
        if self._is_switch_running():
            self.bmv2_container.stop(SWITCH_SERVICE)
        self.bmv2_container.add_layer(BMV2_CONTAINER, layer, combine=True)
        self.bmv2_container.replan()

        self._update_status()
        event.set_results(
            {
                "result": "switch reprogrammed",
                "compiler-output": compiler_stdout.strip(),
                "note": "the previous program's table entries were cleared by the restart",
            }
        )

    # -- table-add / table-delete / table-clear -----------------------------------

    def _on_table_add_action(self, event: ops.ActionEvent):
        """Add a match-action table entry to the currently running program."""
        if not self._require_running_switch(event):
            return

        action_params = str(event.params.get("action-params", ""))
        try:
            cli_command = bmv2.build_table_add_command(
                table=str(event.params.get("table", "")),
                action=str(event.params.get("action", "")),
                match_keys=str(event.params.get("match", "")).split(),
                action_params=action_params.split() if action_params.strip() else [],
                priority=event.params.get("priority"),
            )
        except bmv2.ConfigurationError as err:
            event.fail(str(err))
            return

        output = self._run_cli_command(event, cli_command)
        if output is None:
            return
        event.set_results({"result": output.strip(), "command": cli_command})

    def _on_table_delete_action(self, event: ops.ActionEvent):
        """Delete a single table entry by its handle."""
        if not self._require_running_switch(event):
            return

        try:
            cli_command = bmv2.build_table_delete_command(
                table=str(event.params.get("table", "")),
                handle=int(event.params.get("handle", 0)),
            )
        except bmv2.ConfigurationError as err:
            event.fail(str(err))
            return

        output = self._run_cli_command(event, cli_command)
        if output is None:
            return
        event.set_results({"result": output.strip(), "command": cli_command})

    def _on_table_clear_action(self, event: ops.ActionEvent):
        """Clear every entry from a single table.

        Note that reprogramming the switch already clears every table
        implicitly; this action is for resetting one table without reloading
        the whole program.
        """
        if not self._require_running_switch(event):
            return

        try:
            cli_command = bmv2.build_table_clear_command(str(event.params.get("table", "")))
        except bmv2.ConfigurationError as err:
            event.fail(str(err))
            return

        output = self._run_cli_command(event, cli_command)
        if output is None:
            return
        event.set_results({"result": output.strip(), "command": cli_command})

    # -- Helpers -------------------------------------------------------------------

    def _require_running_switch(self, event: ops.ActionEvent) -> bool:
        """Fail the action and return False unless a program is loaded and running."""
        if not self.bmv2_container.can_connect():
            event.fail("the bmv2 container is not ready yet")
            return False
        if not self._is_program_loaded() or not self._is_switch_running():
            event.fail("no P4 program is currently running; run the reprogram action first")
            return False
        return True

    def _run_cli_command(self, event: ops.ActionEvent, cli_command: str) -> Optional[str]:
        """Run a single command through simple_switch_CLI, failing `event` on error."""
        try:
            thrift_port = bmv2.validate_thrift_port(
                int(self.config.get("thrift-port", bmv2.DEFAULT_THRIFT_PORT))
            )
        except bmv2.ConfigurationError as err:
            event.fail(f"invalid charm configuration: {err}")
            return None

        process = self.bmv2_container.exec(
            [bmv2.CLI_COMMAND, "--thrift-port", str(thrift_port)],
            stdin=cli_command + "\n",
        )
        try:
            stdout, _ = process.wait_output()
        except ops.pebble.ExecError as err:
            details = err.stderr or err.stdout or str(err)
            event.fail(f"simple_switch_CLI failed:\n{details}")
            return None

        if bmv2.cli_output_indicates_error(stdout):
            event.fail(f"simple_switch_CLI rejected the command:\n{stdout.strip()}")
            return None
        return stdout


if __name__ == "__main__":  # pragma: nocover
    ops.main(Bmv2Charm)
