# Copyright 2026 tomasagata
# See LICENSE file for licensing details.

import pytest

import bmv2

# -- validate_thrift_port ------------------------------------------------------


def test_validate_thrift_port_accepts_valid_port():
    assert bmv2.validate_thrift_port(9090) == 9090


@pytest.mark.parametrize("port", [0, -1, 65536, 100000])
def test_validate_thrift_port_rejects_out_of_range(port):
    with pytest.raises(bmv2.ConfigurationError):
        bmv2.validate_thrift_port(port)


# -- parse_interfaces -----------------------------------------------------------


def test_parse_interfaces_empty_string_yields_no_interfaces():
    assert bmv2.parse_interfaces("") == []
    assert bmv2.parse_interfaces("   ") == []


def test_parse_interfaces_parses_single_and_multiple_entries():
    assert bmv2.parse_interfaces("0@veth0") == ["0@veth0"]
    assert bmv2.parse_interfaces("0@veth0,1@veth1, 2@veth2") == [
        "0@veth0",
        "1@veth1",
        "2@veth2",
    ]


@pytest.mark.parametrize("raw", ["veth0", "0-veth0", "0@", "@veth0", "0@veth0,garbage"])
def test_parse_interfaces_rejects_malformed_entries(raw):
    with pytest.raises(bmv2.ConfigurationError):
        bmv2.parse_interfaces(raw)


# -- build_p4c_command ----------------------------------------------------------


def test_build_p4c_command():
    assert bmv2.build_p4c_command("/tmp/a.p4", "/tmp/a.json") == [
        "p4c-bm2-ss",
        "--p4v",
        "16",
        "/tmp/a.p4",
        "-o",
        "/tmp/a.json",
    ]


# -- build_switch_command -------------------------------------------------------


def test_build_switch_command_without_interfaces():
    assert bmv2.build_switch_command("/config/switch.json", 9090, []) == [
        "simple_switch",
        "--thrift-port",
        "9090",
        "/config/switch.json",
    ]


def test_build_switch_command_with_interfaces():
    command = bmv2.build_switch_command("/config/switch.json", 9090, ["0@veth0", "1@veth1"])
    assert command == [
        "simple_switch",
        "--thrift-port",
        "9090",
        "-i",
        "0@veth0",
        "-i",
        "1@veth1",
        "/config/switch.json",
    ]


def test_build_switch_command_rejects_invalid_port():
    with pytest.raises(bmv2.ConfigurationError):
        bmv2.build_switch_command("/config/switch.json", 0, [])


# -- build_table_add_command -----------------------------------------------------


def test_build_table_add_command_basic():
    command = bmv2.build_table_add_command(
        table="ipv4_lpm",
        action="forward",
        match_keys=["10.0.0.0/24"],
        action_params=["1"],
    )
    assert command == "table_add ipv4_lpm forward 10.0.0.0/24 => 1"


def test_build_table_add_command_with_priority():
    command = bmv2.build_table_add_command(
        table="acl",
        action="drop",
        match_keys=["10.0.0.1&&&0xffffffff", "*"],
        action_params=[],
        priority=10,
    )
    assert command == "table_add acl drop 10.0.0.1&&&0xffffffff * => 10"


def test_build_table_add_command_without_action_params():
    command = bmv2.build_table_add_command(
        table="acl", action="drop", match_keys=["10.0.0.1"], action_params=[]
    )
    assert command == "table_add acl drop 10.0.0.1 =>"


def test_build_table_add_command_requires_table_and_action_and_match():
    with pytest.raises(bmv2.ConfigurationError):
        bmv2.build_table_add_command("", "forward", ["10.0.0.0/24"], ["1"])
    with pytest.raises(bmv2.ConfigurationError):
        bmv2.build_table_add_command("ipv4_lpm", " ", ["10.0.0.0/24"], ["1"])
    with pytest.raises(bmv2.ConfigurationError):
        bmv2.build_table_add_command("ipv4_lpm", "forward", [], ["1"])


# -- build_table_delete_command / build_table_clear_command -----------------------


def test_build_table_delete_command():
    assert bmv2.build_table_delete_command("ipv4_lpm", 3) == "table_delete ipv4_lpm 3"


def test_build_table_delete_command_requires_table():
    with pytest.raises(bmv2.ConfigurationError):
        bmv2.build_table_delete_command("", 3)


def test_build_table_clear_command():
    assert bmv2.build_table_clear_command("ipv4_lpm") == "table_clear ipv4_lpm"


def test_build_table_clear_command_requires_table():
    with pytest.raises(bmv2.ConfigurationError):
        bmv2.build_table_clear_command("")


# -- cli_output_indicates_error ---------------------------------------------------


@pytest.mark.parametrize(
    "output",
    [
        "Invalid table name\n",
        "Runtime error: table not found\n",
        "terminate called after throwing an instance of 'std::exception'\n",
        "Table 'foo' not found\n",
    ],
)
def test_cli_output_indicates_error_detects_failures(output):
    assert bmv2.cli_output_indicates_error(output)


@pytest.mark.parametrize(
    "output",
    [
        "Entry has been added with handle 0\n",
        "table_add ipv4_lpm forward 10.0.0.0/24 => 1\n",
    ],
)
def test_cli_output_indicates_error_ignores_success_output(output):
    assert not bmv2.cli_output_indicates_error(output)
