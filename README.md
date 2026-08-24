# iml-testbed

Terraform + Ansible automation for standing up the OSM/IML testbed and running experiments against it.

## Prerequisites

- [Terraform](https://developer.hashicorp.com/terraform/install)
- [Ansible](https://docs.ansible.com/ansible/latest/installation_guide/index.html) (the complete package, not just `ansible-core`)
- SSH access to the `OSM_HOST` configured below

## Setup

Before everything, make sure to load your environment variables by

```bash
cp .env.example .env
```

and then modify `.env` to fit your needs and infra (host, SSH user, etc.). `testbed.sh` sources this file before running any command, so it must exist and be filled in first.

## Usage

All commands are run through `./testbed.sh <command>`:

```bash
./testbed.sh init
./testbed.sh package
./testbed.sh run-experiment-2
./testbed.sh run-experiment-3
./testbed.sh destroy
```

| Command | Description |
| --- | --- |
| `init` | Downloads dependencies and initializes the testbed (`terraform init`, then `terraform apply`, which also runs Ansible to configure the testbed). Requires Terraform, Ansible, and SSH access to `OSM_HOST`. |
| `package` | Packages and uploads the OSM kNFs and NFs. |
| `run-experiment-2` | Runs experiment 2. |
| `run-experiment-3` | Runs experiment 3. |
| `destroy` | Tears down the testbed. |

Typical flow:

1. `./testbed.sh init`
2. `./testbed.sh package`
3. `./testbed.sh run-experiment-2` or `./testbed.sh run-experiment-3`
4. `./testbed.sh destroy` once you're done

## Project structure

Each subcommand maps to a `main.sh` entrypoint under [scripts/](scripts/):

```
scripts/
├── init/main.sh              # ./testbed.sh init
├── destroy/main.sh           # ./testbed.sh destroy
├── package/main.sh           # ./testbed.sh package
├── experiment-2/main.sh      # ./testbed.sh run-experiment-2
└── experiment-3/main.sh      # ./testbed.sh run-experiment-3
```

`testbed.sh` loads `.env` and dispatches to the matching `main.sh`, forwarding any extra arguments.
