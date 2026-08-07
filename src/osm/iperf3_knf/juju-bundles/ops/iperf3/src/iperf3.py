# Copyright 2026 tomasagata
# See LICENSE file for licensing details.

"""Functions for building iperf3 command lines.

The intention is that this module could be used outside the context of a charm:
it has no dependency on `ops` and only knows how to turn a set of parameters into
an `iperf3` argv list (or reject them).
"""

import logging

logger = logging.getLogger(__name__)

DEFAULT_PORT = 5201
VALID_PROTOCOLS = ("tcp", "udp")


class ConfigurationError(Exception):
    """Raised when the parameters given for an iperf3 invocation are invalid."""


def validate_protocol(protocol: str) -> str:
    """Normalize and validate a transport protocol name.

    Raises:
        ConfigurationError: if the protocol is not "tcp" or "udp".
    """
    normalized = protocol.strip().lower()
    if normalized not in VALID_PROTOCOLS:
        raise ConfigurationError(
            f"invalid protocol {protocol!r}: must be one of {list(VALID_PROTOCOLS)}"
        )
    return normalized


def validate_port(port: int) -> int:
    """Validate a TCP/UDP port number.

    Raises:
        ConfigurationError: if the port is outside the valid 1-65535 range.
    """
    if not 1 <= port <= 65535:
        raise ConfigurationError(f"invalid port {port!r}: must be between 1 and 65535")
    return port


def build_server_command(
    port: int = DEFAULT_PORT,
    protocol: str = "tcp",
    one_off: bool = False,
) -> list[str]:
    """Build the argv for running iperf3 as a server.

    Raises:
        ConfigurationError: if the protocol or port are invalid.
    """
    protocol = validate_protocol(protocol)
    port = validate_port(port)

    command = ["iperf3", "-s", "-p", str(port)]
    if protocol == "udp":
        command.append("-u")
    if one_off:
        command.append("-1")
    return command


def build_client_command(
    target: str,
    port: int = DEFAULT_PORT,
    protocol: str = "tcp",
    duration: int | None = None,
    bandwidth: str | None = None,
    parallel: int | None = None,
    reverse: bool = False,
) -> list[str]:
    """Build the argv for running iperf3 as a client against `target`.

    Raises:
        ConfigurationError: if the target is empty or the parameters are invalid.
    """
    if not target or not target.strip():
        raise ConfigurationError("a target server address/hostname is required")
    protocol = validate_protocol(protocol)
    port = validate_port(port)

    command = ["iperf3", "-c", target.strip(), "-p", str(port)]
    if protocol == "udp":
        command.append("-u")
    if duration is not None:
        if duration <= 0:
            raise ConfigurationError(f"invalid duration {duration!r}: must be positive")
        command += ["-t", str(duration)]
    if bandwidth is not None:
        command += ["-b", str(bandwidth)]
    if parallel is not None:
        if parallel <= 0:
            raise ConfigurationError(
                f"invalid parallel stream count {parallel!r}: must be positive"
            )
        command += ["-P", str(parallel)]
    if reverse:
        command.append("-R")
    return command
