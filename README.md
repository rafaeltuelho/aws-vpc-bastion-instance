# AWS VPC Bastion for Redpanda and Kafka

Terraform for a small SSH bastion (Ubuntu 24.04) on AWS for working with a
Redpanda or Apache Kafka cluster from inside AWS networking. It comes with
[`rpk`](https://docs.redpanda.com/current/reference/rpk/) and
[`kcat`](https://github.com/edenhill/kcat) preinstalled.

The repository has two independent Terraform root modules, each with its own
state:

| Module | Directory | What it does |
|---|---|---|
| **Bastion** | `.` (repository root) | Launches the bastion in a new VPC, an existing VPC, or a Redpanda BYOC cluster VPC. It never changes anything outside its own resources. |
| **Peering** | [`peering/`](peering/README.md) | Optional connectivity layer: VPC peering between a client VPC (e.g. the bastion's) and a cluster VPC, routes in both directions, and optionally firewall and private DNS access. |

## Contents

- [Choosing a layout](#choosing-a-layout)
- [Why peering is a separate module](#why-peering-is-a-separate-module)
- [Bastion module](#bastion-module)
  - [Prerequisites](#prerequisites)
  - [Usage](#usage)
  - [Parameters](#parameters)
  - [What gets created](#what-gets-created)
  - [Validations](#validations)
  - [Outputs](#outputs)
  - [Troubleshooting](#troubleshooting)
- [Order of operations](#order-of-operations)
- [Security notes](#security-notes)

## Choosing a layout

| Your situation | What to deploy |
|---|---|
| The cluster VPC has a public subnet, and the cluster already allows its own VPC | **Bastion only**, with `vpc_id` set to the cluster VPC (or `redpanda_cluster_id` for Redpanda BYOC). No peering, no changes to the cluster's network. This is the simplest option. |
| The cluster is reachable over the internet | **Bastion only**, anywhere (e.g. `create_vpc = true`). |
| You want the bastion in its own VPC, e.g. to mimic a customer's client network | **Bastion** with `create_vpc = true`, then the **[peering module](peering/README.md)** between the bastion VPC and the cluster VPC. |

## Why peering is a separate module

Peering always changes the cluster VPC: it needs the accepted peering
connection and a route back to the clients in the cluster's route tables.
Reaching the brokers usually also means changing who the cluster's firewall
allows, and which VPCs its private DNS zone serves.

Those resources usually belong to the cluster's own project, e.g. the Terraform
that created an EKS cluster. If two projects manage the same objects, each one
reverts the other's changes on its next `apply`, without an error. A zone's VPC
list, or a security group whose rules are defined inline, are typical cases.

Keeping peering in its own module, with its own state, gives each resource a
single owner:

| Resource | Owner |
|---|---|
| Bastion VPC and instance | Bastion module |
| Peering connection, routes in both VPCs | Peering module |
| Cluster, its security groups, private DNS zone | Cluster project |
| Who the cluster allows (prefix list entries, zone associations) | Cluster project, or the peering module when the cluster project hands it over (see [Working with a cluster managed by another project](peering/README.md#working-with-a-cluster-managed-by-another-project)) |

Neither the bastion nor the cluster project references the other. Only the
peering module knows both VPC IDs, as plain inputs.

## Bastion module

### Prerequisites

- Terraform >= 1.9
- AWS credentials for the target account and region, e.g. `aws sso login` /
  `aws login` or `AWS_PROFILE=...`. Terraform uses the standard AWS credential
  chain. The region comes only from `aws_region`.
- Permission to manage EC2 instances and security groups and, with
  `create_vpc`, VPCs, subnets, route tables and internet gateways
- An existing [EC2 key pair](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/create-key-pairs.html)
  in that region, and its private key. List them with
  `aws ec2 describe-key-pairs --query 'KeyPairs[].KeyName'`. To use a private
  key you already have, import its public key:

  ```bash
  aws ec2 import-key-pair --key-name my-key \
    --public-key-material fileb://<(ssh-keygen -y -f ~/.ssh/my-key.pem)
  ```

- With an existing VPC (`vpc_id` or `redpanda_cluster_id`): at least one public
  subnet (`map-public-ip-on-launch=true`) with a route to an internet gateway

### Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init
terraform plan                                  # review what will change
terraform apply
```

Or pass parameters on the command line:

```bash
# New VPC
terraform apply -var create_vpc=true -var key_name=<key> -var owner=<you>

# Existing VPC, e.g. the cluster's
terraform apply -var vpc_id=vpc-0123456789abcdef0 -var key_name=<key> -var owner=<you>

# Redpanda BYOC cluster VPC
terraform apply -var redpanda_cluster_id=<id> -var key_name=<key> -var owner=<you>
```

#### Connect

```bash
ssh -i ~/.ssh/<key>.pem ubuntu@$(terraform output -raw public_ip)
```

Cloud-init needs a minute or two after boot. Check progress with
`tail -f /var/log/cloud-init-output.log`, or wait with
`cloud-init status --wait`.

Then, from the bastion:

```bash
# Redpanda Cloud (BYOC)
rpk cloud login
rpk cloud cluster select

# Self-managed Redpanda or Kafka
rpk cluster info -X brokers=<broker>:<port>
kcat -b <broker>:<port> -L
```

Add TLS and SASL settings as your listener requires, e.g. an rpk profile:

```bash
rpk profile create my-cluster \
  -X brokers=<broker>:<port> \
  -X tls.enabled=true -X tls.ca=$HOME/ca.crt \
  -X user=<user> -X pass='<password>' -X sasl.mechanism=SCRAM-SHA-256
```

#### Tear down

```bash
terraform destroy   # with the same variables used for apply
```

If the bastion VPC is peered, destroy the peering module first; see
[Order of operations](#order-of-operations). If a Redpanda BYOC cluster is
already gone, its VPC lookup fails. Pass the VPC ID printed by
`terraform output vpc_id` instead:
`terraform destroy -var vpc_id=vpc-...`.

### Parameters

#### Required

| Name | Type | Default | Description |
|---|---|---|---|
| `key_name` | string | — | Name of an existing EC2 key pair in `aws_region`. You log in with its private key. |
| `owner` | string | — | Prefix for resource names, e.g. your username. Letters, digits, `-` and `_` only (1–32 characters). Resources are named `<owner>-bastion[-<redpanda_cluster_id or vpc_id>]`. |
| `aws_region` | string | `us-east-2` | Region of the bastion. |

#### Bastion VPC: set exactly one

| Name | Type | Default | Description |
|---|---|---|---|
| `create_vpc` | bool | `false` | Create a new VPC for the bastion: one public subnet spanning `vpc_cidr`, an internet gateway and a route table, with DNS support and hostnames enabled. The availability zone is chosen automatically among those that offer `instance_type`. |
| `vpc_cidr` | string | `10.255.0.0/24` | CIDR of the new VPC (only with `create_vpc`). Between `/16` and `/28`. If you plan to peer it with a cluster VPC, pick a range that overlaps none of that VPC's CIDR blocks, including secondary ones. |
| `vpc_id` | string | `null` | Existing VPC to deploy into, with or without a cluster in it. The bastion goes into its first public subnet (sorted by ID). |
| `redpanda_cluster_id` | string | `null` | Redpanda BYOC cluster ID, from the Redpanda Cloud console. The bastion goes into the cluster VPC, found from the BYOC agent instance (tag `Name=redpanda-<id>`). Also used in resource names and in a `redpanda-cluster` tag. |

#### Bastion instance

| Name | Type | Default | Description |
|---|---|---|---|
| `instance_type` | string | `t3.medium` | Bastion instance type. Must be x86_64 (the AMI and rpk build are amd64). |
| `ssh_cidr` | string | your public IP `/32` | CIDR allowed to SSH in. By default it's detected via `checkip.amazonaws.com` at plan time. |
| `ami_name_pattern` | string | `ubuntu/images/hvm-ssd-gp3/ubuntu-*-24.04-amd64-server-*` | Ubuntu AMI name pattern (Canonical images). The newest match is used. |
| `apt_mirror` | string | `""` | Replacement apt mirror, e.g. `http://archive.ubuntu.com/ubuntu/`, if the regional EC2 mirror is failing. |
| `rpk_url` | string | latest `rpk-linux-amd64.zip` | Download URL of the rpk zip; pin a version here if needed. |

### What gets created

| Resource | When | Details |
|---|---|---|
| Security group `<name>-ssh` | always | SSH (22/tcp) from `ssh_cidr` only; all egress |
| EC2 instance `<name>` | always | Latest Ubuntu 24.04 x86_64, public IP, IMDSv2 required, encrypted gp3 root volume. Cloud-init installs `rpk` (with bash completion), `kcat`, `curl`, `jq`, `unzip`, `netcat-openbsd`. |
| VPC, public subnet, internet gateway, route table | `create_vpc` | DNS support and hostnames enabled |

All resources are tagged `Name=<name>`, plus `redpanda-cluster=<id>` when
`redpanda_cluster_id` is set.

### Validations

These are checked during `terraform plan`, before anything is created.

| Check | Error when |
|---|---|
| Bastion VPC source | Not exactly one of `create_vpc`, `vpc_id`, `redpanda_cluster_id` is set |
| `owner` | Empty, longer than 32 characters, or contains characters other than letters, digits, `-`, `_` (e.g. a leftover `<your-name>` placeholder) |
| Key pair | `key_name` doesn't exist in `aws_region` |
| `vpc_cidr` | Not a valid IPv4 CIDR, or outside `/16`–`/28` |
| `vpc_id` format | Not `vpc-…` |
| `ssh_cidr` | Not a valid CIDR |
| Public subnet | An existing VPC has no subnet with auto-assign public IP |
| Instance type | No availability zone in the region offers `instance_type` (new VPC) |

### Outputs

| Name | Description |
|---|---|
| `public_ip` | Bastion public IP |
| `private_ip` | Bastion private IP, the source address the brokers see |
| `ssh_command` | Ready-to-edit SSH command |
| `instance_id` | Bastion instance ID |
| `vpc_id` | Bastion VPC ID; pass it to the peering module as `client_vpc_id` |
| `subnet_id` | Bastion subnet ID |

### Troubleshooting

- **`no matching EC2 Key Pair found`**: `key_name` doesn't exist in
  `aws_region` (key pairs are per region).
- **`no matching EC2 Instance found` (`data.aws_instance.agent`)**: wrong
  `redpanda_cluster_id`, `aws_region` or AWS account/profile, or the BYOC
  cluster is gone. Pass `vpc_id` instead.
- **`No public subnet ...`**: the existing VPC has no subnet with auto-assign
  public IP. Use `create_vpc = true` (and the peering module), or another VPC.
- **`Value for undeclared variable`** warnings: your `terraform.tfvars` still
  has settings from an older version, e.g. `peer_vpc_id`. Remove them; peering
  now lives in `peering/`.
- **SSH times out**: your public IP changed since `apply` (VPN, new network).
  Run `terraform apply` again to refresh the rule, or set `ssh_cidr`.
- **`rpk: command not found`**: cloud-init is still running or failed. Check
  `/var/log/cloud-init-output.log`. If apt fails with 503s from the regional
  EC2 mirror, set `apt_mirror = "http://archive.ubuntu.com/ubuntu/"`. Changing
  user data replaces the instance.
- **Newer AMI available**: the AMI is ignored after creation so the bastion is
  not replaced. Use `terraform apply -replace=aws_instance.bastion` to rebuild it.
- **Can't reach the brokers**: see the
  [peering module's troubleshooting](peering/README.md#troubleshooting).

## Order of operations

Each module has its own state and is applied separately.

**Create:** cluster → bastion → peering

```bash
terraform apply                                     # bastion, in the repository root
VPC=$(terraform output -raw vpc_id)
cd peering && terraform apply -var client_vpc_id=$VPC -var cluster_vpc_id=<cluster-vpc>
```

If the cluster project owns who may connect (its allowlist or zone VPC list),
add the bastion VPC there now, after the bastion exists and before testing.

**Destroy:** in reverse, peering → bastion (→ cluster)

```bash
cd peering && terraform destroy
cd .. && terraform destroy
```

Destroying the peering module first removes everything it added to the cluster
VPC while the cluster still exists. If you added the bastion VPC to the cluster
project's own lists, remove it there before destroying the bastion, so that
project doesn't keep pointing at a deleted VPC.

## Security notes

- SSH is the only inbound port on the bastion and is limited to `ssh_cidr`.
  Avoid `0.0.0.0/0`.
- The bastion module only creates resources of its own. Changes to a cluster
  VPC happen only through the peering module, and `plan` lists each one.
- Terraform state includes IPs and resource IDs. It's kept locally and ignored
  by git; use a remote backend if several people share it.
- Destroy the bastion when you no longer need it.

## License

[Apache License 2.0](LICENSE)
