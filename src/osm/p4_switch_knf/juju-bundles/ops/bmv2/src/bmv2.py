# Copyright 2026 tomasagata
# See LICENSE file for licensing details.

"""Functions for building p4c/BMv2 commands.

The intention is that this module could be used outside the context of a charm: it
has no dependency on `ops` and only knows how to turn a set of parameters into
argv lists / simple_switch_CLI command lines (or reject them). All actual process
execution and file transfer between containers is the charm's job.
"""

import logging
import re

logger = logging.getLogger(__name__)

DEFAULT_THRIFT_PORT = 9090

P4C_COMMAND = "p4c-bm2-ss"
SWITCH_COMMAND = "simple_switch"
CLI_COMMAND = "simple_switch_CLI"

# Strings simple_switch_CLI prints on invalid commands. It's a REPL that exits 0
# even when a command was rejected, so we have to scan its stdout for these.
CLI_ERROR_MARKERS = ("invalid", "error", "exception", "not found")

_INTERFACE_RE = re.compile(r"^\d+@\S+$")


class ConfigurationError(Exception):
    """Raised when the parameters given for a p4c/BMv2 invocation are invalid."""


def validate_thrift_port(port: int) -> int:
    """Validate the Thrift RPC port simple_switch exposes.

    Raises:
        ConfigurationError: if the port is outside the valid 1-65535 range.
    """
    if not 1 <= port <= 65535:
        raise ConfigurationError(f"invalid thrift-port {port!r}: must be between 1 and 65535")
    return port


def parse_interfaces(raw: str) -> list[str]:
    """Parse a comma-separated "<port>@<iface>" list into a list of tokens.

    An empty (or blank) string is valid and yields an empty list, meaning the
    switch is started with no data-plane interfaces attached.

    Raises:
        ConfigurationError: if any entry isn't in "<port>@<iface>" form.
    """
    raw = raw.strip()
    if not raw:
        return []

    interfaces = []
    for token in raw.split(","):
        token = token.strip()
        if not _INTERFACE_RE.match(token):
            raise ConfigurationError(
                f"invalid interface {token!r}: expected '<port-number>@<iface-name>'"
            )
        interfaces.append(token)
    return interfaces


def build_p4c_command(source_path: str, output_path: str) -> list[str]:
    """Build the argv for compiling a P4_16 program into a BMv2 JSON config."""
    return [P4C_COMMAND, "--p4v", "16", source_path, "-o", output_path]


def build_switch_command(json_path: str, thrift_port: int, interfaces: list[str]) -> list[str]:
    """Build the argv for running simple_switch against a compiled JSON config.

    Raises:
        ConfigurationError: if the thrift port is invalid.
    """
    thrift_port = validate_thrift_port(thrift_port)

    command = [SWITCH_COMMAND, "--thrift-port", str(thrift_port)]
    for interface in interfaces:
        command += ["-i", interface]
    command.append(json_path)
    return command


def build_table_add_command(
    table: str,
    action: str,
    match_keys: list[str],
    action_params: list[str],
    priority: int | None = None,
) -> str:
    """Build a `table_add` simple_switch_CLI command line.

    Raises:
        ConfigurationError: if the table or action name is empty, or no match
            keys were given.
    """
    table = _require_name(table, "table")
    action = _require_name(action, "action")
    if not match_keys:
        raise ConfigurationError("at least one match key is required")

    parts = ["table_add", table, action, *match_keys, "=>", *action_params]
    if priority is not None:
        parts.append(str(priority))
    return " ".join(parts)


def build_table_delete_command(table: str, handle: int) -> str:
    """Build a `table_delete` simple_switch_CLI command line.

    Raises:
        ConfigurationError: if the table name is empty.
    """
    table = _require_name(table, "table")
    return f"table_delete {table} {handle}"


def build_table_clear_command(table: str) -> str:
    """Build a `table_clear` simple_switch_CLI command line.

    Raises:
        ConfigurationError: if the table name is empty.
    """
    table = _require_name(table, "table")
    return f"table_clear {table}"


def cli_output_indicates_error(output: str) -> bool:
    """Best-effort check for whether simple_switch_CLI rejected a command.

    simple_switch_CLI is an interactive REPL that always exits 0, even when a
    command was invalid, so the only signal available is its printed output.
    """
    lowered = output.lower()
    return any(marker in lowered for marker in CLI_ERROR_MARKERS)


def _require_name(value: str, label: str) -> str:
    value = value.strip()
    if not value:
        raise ConfigurationError(f"a {label} name is required")
    return value
