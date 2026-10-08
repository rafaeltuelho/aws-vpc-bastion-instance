# AWS VPC Bastion for Redpanda and Kafka

Terraform that launches a small SSH bastion (Ubuntu 24.04) on AWS for working
with a Redpanda or Apache Kafka cluster from inside AWS networking. It comes
with [`rpk`](https://docs.redpanda.com/current/reference/rpk/) and
[`kcat`](https://github.com/edenhill/kcat) preinstalled.

You choose where the bastion lives, and optionally peer that VPC with the VPC
that hosts the cluster:

- **A new VPC** created for the bastion
- **An existing VPC** you name
- **The VPC of a [Redpanda BYOC](https://docs.redpanda.com/redpanda-cloud/get-started/cluster-types/byoc/) cluster**, found from the cluster ID

With peering, the plan also adds the routes in both directions. It can also
open the brokers' security groups to the bastion and make the cluster's private
DNS names (e.g. `redpanda-0.redpanda.internal`) resolve on the bastion.

## Contents

- [Common scenarios](#common-scenarios)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
- [Parameters](#parameters)
- [Finding the IDs you need](#finding-the-ids-you-need)
- [What gets created](#what-gets-created)
- [Validations](#validations)
- [Outputs](#outputs)
- [Troubleshooting](#troubleshooting)
- [Security notes](#security-notes)

## Common scenarios

Each scenario lists the parameters to set in addition to `key_name` and
`owner`, which are always required.

| Scenario | Parameters |
|---|---|
| Bastion inside a Redpanda BYOC cluster VPC | `redpanda_cluster_id` |
| Bastion inside any existing VPC (e.g. next to a cluster) | `vpc_id` |
| New VPC, peered with a self-managed Redpanda/Kafka VPC (e.g. EKS) | `create_vpc = true`, `peer_vpc_id`, usually `peer_security_group_ids` and `peer_private_zone_ids` |
| New VPC, peered with a Redpanda BYOC cluster VPC | `create_vpc = true`, `redpanda_cluster_id` |
| Existing VPC, peered with the cluster VPC | `vpc_id`, `peer_vpc_id` (plus the optional `peer_*` parameters) |
| Standalone bastion in a new VPC (cluster reachable over the internet) | `create_vpc = true` |

Example `terraform.tfvars` for a new VPC peered with a self-managed Redpanda
cluster on EKS that publishes broker names in a Route 53 private zone:

```hcl
key_name   = "my-key"
owner      = "jdoe"
aws_region = "us-east-2"

create_vpc = true
vpc_cidr   = "10.255.0.0/24"            # must not overlap the EKS VPC

peer_vpc_id             = "vpc-0123456789abcdef0"   # EKS VPC
peer_security_group_ids = ["sg-0123456789abcdef0"]  # broker / node security group
peer_private_zone_ids   = ["Z0123456789ABCDEFGHIJ"] # redpanda.internal.
```

## Prerequisites

- Terraform >= 1.9
- AWS credentials for the account and region of the bastion and of the peer
  VPC, e.g. `aws sso login` / `aws login` or `AWS_PROFILE=...`. Terraform uses
  the standard AWS credential chain. The region comes only from `aws_region`.
- Permission to manage EC2 (instances, security groups, VPCs, subnets, route
  tables, internet gateways, peering) and, with `peer_private_zone_ids`,
  Route 53 VPC associations
- An existing [EC2 key pair](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/create-key-pairs.html)
  in that region, and its private key
- When using an existing VPC (`vpc_id`, or the BYOC VPC): at least one public
  subnet (`map-public-ip-on-launch=true`) with a route to an internet gateway

## Usage

```bash
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init
terraform plan                                  # review what will change
terraform apply
```

Or pass parameters on the command line:

```bash
# Into a Redpanda BYOC cluster VPC
terraform apply -var redpanda_cluster_id=<id> -var key_name=<key> -var owner=<you>

# Into any existing VPC
terraform apply -var vpc_id=vpc-0123456789abcdef0 -var key_name=<key> -var owner=<you>

# New VPC peered with another VPC
terraform apply -var create_vpc=true -var peer_vpc_id=vpc-0123456789abcdef0 \
  -var key_name=<key> -var owner=<you>
```

List parameters on the command line use HCL syntax:
`-var 'peer_security_group_ids=["sg-0123456789abcdef0"]'`.

### Connect

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
rpk cluster info -X brokers=redpanda-0.redpanda.internal:9092
kcat -b redpanda-0.redpanda.internal:9092 -L
```

Add TLS/SASL flags as your cluster requires.

### Tear down

```bash
terraform destroy   # with the same variables used for apply
```

`destroy` removes everything the plan added, including routes and security
group rules in the peer VPC, and the private zone associations. It never
deletes the existing VPCs, route tables, security groups or zones themselves.

If a BYOC cluster (and its agent instance) is already gone, its VPC lookup
fails. Pass the IDs printed by `terraform output` instead:

```bash
terraform destroy -var vpc_id=vpc-...                           # bastion was in the BYOC VPC
terraform destroy -var create_vpc=true -var peer_vpc_id=vpc-... # new VPC peered with BYOC
```

## Parameters

### Required

| Name | Type | Default | Description |
|---|---|---|---|
| `key_name` | string | — | Name of an existing EC2 key pair in `aws_region`. You log in with its private key. |
| `owner` | string | — | Prefix for resource names, e.g. your username. Resources are named `<owner>-bastion[-<redpanda_cluster_id or vpc_id>]`. |
| `aws_region` | string | `us-east-2` | Region of the bastion and of the peer VPC. |

### Bastion VPC

Set **exactly one** source of the bastion VPC. `redpanda_cluster_id` can also be
combined with `create_vpc`, see below.

| Name | Type | Default | Description |
|---|---|---|---|
| `create_vpc` | bool | `false` | Create a new VPC for the bastion: one public subnet spanning `vpc_cidr`, an internet gateway and a route table. The availability zone is chosen automatically among those that offer `instance_type`. |
| `vpc_cidr` | string | `10.255.0.0/24` | CIDR of the new VPC (only with `create_vpc`). Between `/16` and `/28`. Must not overlap the peer VPC, including its secondary CIDRs. |
| `vpc_id` | string | `null` | Existing VPC to deploy into. No Redpanda cluster is needed. The bastion goes into its first public subnet (sorted by ID). |
| `redpanda_cluster_id` | string | `null` | Redpanda BYOC cluster ID, from the Redpanda Cloud console. **Alone**: the bastion goes into the cluster VPC, found from the BYOC agent instance (tag `Name=redpanda-<id>`). **With `create_vpc`**: the new VPC is peered with the cluster VPC, unless `peer_vpc_id` is set. Also used in resource names and in a `redpanda-cluster` tag. |

### Peering

Peering is enabled when `peer_vpc_id` is set, or when `create_vpc` is combined
with `redpanda_cluster_id`. Both VPCs must be in the same account and region.

Peering alone sets up the network path and the routes. Two more things are
usually needed before a client on the bastion works:

1. **Broker security groups** must accept the bastion: `peer_security_group_ids`.
2. **Broker DNS names** must resolve on the bastion: `peer_private_zone_ids`,
   if the names live in a Route 53 private zone.

| Name | Type | Default | Description |
|---|---|---|---|
| `peer_vpc_id` | string | `null` | VPC to peer with, typically the one hosting the Redpanda/Kafka cluster. The peering request is accepted automatically. Routes are added to **all** of the peer VPC's CIDR blocks, including secondary ones such as EKS pod ranges. |
| `peer_route_table_ids` | list(string) | `null` (all) | Peer VPC route tables that get a route back to the bastion subnet. **Leave unset** to update every route table in the peer VPC, which is what most setups need. Set it only to limit changes to specific route tables. |
| `peer_security_group_ids` | list(string) | `[]` | Security groups in the peer VPC (those attached to the brokers or EKS nodes) that should accept connections from the bastion. Each gets one inbound rule per port in `peer_ports`, from the bastion's private IP (`/32`) only. **Empty**: no security group is changed, so you must allow the bastion yourself (or the brokers already allow it). |
| `peer_ports` | list(number) | `[9092, 9644, 8081, 8082]` | TCP ports opened in `peer_security_group_ids`. The defaults are the Kafka API, Redpanda Admin API, Schema Registry and HTTP Proxy. Adjust for your listeners, e.g. `[9093]` for a TLS Kafka listener or the external NodePorts of a Kubernetes deployment. |
| `peer_private_zone_ids` | list(string) | `[]` | Route 53 **private** hosted zones (same account) to associate with the bastion VPC, so their records resolve on the bastion. Use it when broker names like `redpanda-0.redpanda.internal` come from a private zone, e.g. one managed by external-dns for a Redpanda cluster on EKS. Give the bare ID (`Z0...`), without `/hostedzone/`. |

Remote VPC DNS resolution is also enabled on the peering whenever both VPCs
have DNS support and DNS hostnames turned on. Peer instances' EC2 hostnames
(`ip-10-0-1-5.<region>.compute.internal`) then resolve to private IPs. This
needs no parameter.

### Bastion instance

| Name | Type | Default | Description |
|---|---|---|---|
| `instance_type` | string | `t3.medium` | Bastion instance type. Must be x86_64 (the AMI and rpk build are amd64). |
| `ssh_cidr` | string | your public IP `/32` | CIDR allowed to SSH in. By default it's detected via `checkip.amazonaws.com` at plan time. |
| `ami_name_pattern` | string | `ubuntu/images/hvm-ssd-gp3/ubuntu-*-24.04-amd64-server-*` | Ubuntu AMI name pattern (Canonical images). The newest match is used. |
| `apt_mirror` | string | `""` | Replacement apt mirror, e.g. `http://archive.ubuntu.com/ubuntu/`, if the regional EC2 mirror is failing. |
| `rpk_url` | string | latest `rpk-linux-amd64.zip` | Download URL of the rpk zip; pin a version here if needed. |

## Finding the IDs you need

```bash
export AWS_REGION=us-east-2

# VPCs (peer_vpc_id / vpc_id)
aws ec2 describe-vpcs \
  --query 'Vpcs[].[VpcId,CidrBlock,Tags[?Key==`Name`]|[0].Value]' --output table

# Security groups attached to instances in the cluster VPC (peer_security_group_ids).
# For EKS, pick the node / cluster security group used by the broker pods.
aws ec2 describe-instances --filters Name=vpc-id,Values=<peer-vpc-id> \
  --query 'Reservations[].Instances[].SecurityGroups[].[GroupId,GroupName]' --output text | sort -u

# Private hosted zones attached to the cluster VPC (peer_private_zone_ids)
aws route53 list-hosted-zones-by-vpc --vpc-id <peer-vpc-id> --vpc-region $AWS_REGION \
  --query 'HostedZoneSummaries[].[HostedZoneId,Name]' --output text

# CIDR blocks already used by the peer VPC (to choose a non-overlapping vpc_cidr)
aws ec2 describe-vpcs --vpc-ids <peer-vpc-id> \
  --query 'Vpcs[].CidrBlockAssociationSet[].CidrBlock' --output text
```

Route table IDs (`peer_route_table_ids`) are rarely needed. Leave it unset and
`terraform plan` lists the route tables it will update.

## What gets created

| Resource | When | Details |
|---|---|---|
| Security group `<name>-ssh` | always | SSH (22/tcp) from `ssh_cidr` only; all egress |
| EC2 instance `<name>` | always | Latest Ubuntu 24.04 x86_64, public IP, IMDSv2 required, encrypted gp3 root volume. Cloud-init installs `rpk` (with bash completion), `kcat`, `curl`, `jq`, `unzip`, `netcat-openbsd`. |
| VPC, public subnet, internet gateway, route table | `create_vpc` | DNS support and hostnames enabled |
| VPC peering connection | peering | Auto-accepted |
| Routes: bastion route table → each peer CIDR | peering | In the bastion subnet's route table (new VPC: its own table; existing VPC: the subnet's table, or the main table if the subnet has none) |
| Routes: peer route tables → bastion subnet CIDR | peering | In `peer_route_table_ids`, or all peer route tables |
| Inbound rules in peer security groups | `peer_security_group_ids` | `peer_ports` from the bastion private IP `/32` |
| Route 53 zone associations | `peer_private_zone_ids` | Zone ↔ bastion VPC |

All resources are tagged `Name=<name>`, plus `redpanda-cluster=<id>` when
`redpanda_cluster_id` is set.

## Validations

These are checked during `terraform plan`, before anything is created.

| Check | Error when |
|---|---|
| Bastion VPC source | None of `create_vpc`, `vpc_id`, `redpanda_cluster_id` is set, or `create_vpc` and `vpc_id` are both set |
| `vpc_cidr` | Not a valid IPv4 CIDR, or outside `/16`–`/28` |
| ID formats | `vpc_id`/`peer_vpc_id` aren't `vpc-…`, security groups aren't `sg-…`, route tables aren't `rtb-…`, zones aren't `Z…` |
| `peer_ports` | Empty, or a port outside 1–65535 |
| `peer_*` without peering | `peer_security_group_ids` or `peer_route_table_ids` set without `peer_vpc_id` (or `create_vpc` with `redpanda_cluster_id`) |
| Self-peering | The peer VPC is the bastion's own VPC |
| Peer VPC exists | `peer_vpc_id` not found in this account/region |
| CIDR overlap | Any CIDR block of the bastion VPC overlaps any CIDR block of the peer VPC (AWS can't peer them) |
| Security group location | A `peer_security_group_ids` entry isn't in the peer VPC |
| Private zone | A `peer_private_zone_ids` entry is a public zone |
| Public subnet | An existing bastion VPC has no subnet with auto-assign public IP |
| Instance type | No availability zone in the region offers `instance_type` (new VPC) |

Some failures are left to AWS to report at apply time: an existing peering
between the same two VPCs, a route table that already has a route for the same
CIDR, or a zone already associated with the bastion VPC.

## Outputs

| Name | Description |
|---|---|
| `public_ip` | Bastion public IP |
| `private_ip` | Bastion private IP, the source address the brokers see over peering |
| `ssh_command` | Ready-to-edit SSH command |
| `instance_id` | Bastion instance ID |
| `vpc_id` | Bastion VPC ID |
| `subnet_id` | Bastion subnet ID |
| `peer_vpc_id` | Peered VPC ID, or `null` (keep it for `destroy` if the BYOC cluster may go away) |
| `peering_connection_id` | VPC peering connection ID, or `null` |

## Troubleshooting

- **`no matching EC2 Instance found` (`data.aws_instance.agent`)**: wrong
  `redpanda_cluster_id`, `aws_region` or AWS account/profile, or the BYOC
  cluster is gone. Pass `vpc_id` (or `peer_vpc_id`) explicitly.
- **`no matching EC2 VPC found` (`data.aws_vpc.peer`)**: `peer_vpc_id` is
  wrong, or in another account/region.
- **`VPC CIDRs overlap`**: choose a `vpc_cidr` outside every CIDR listed in
  the error.
- **`No public subnet ...`**: the existing VPC has no subnet with auto-assign
  public IP. Use `create_vpc = true` instead.
- **`RouteAlreadyExists`**: a route table already has a route for that CIDR
  (e.g. via a Transit Gateway or an older peering). Remove it, or exclude that
  table with `peer_route_table_ids`.
- **Broker connection times out over peering**: the brokers' security groups
  don't allow the bastion. Set `peer_security_group_ids` (and `peer_ports` for
  your listener ports), or add the rule yourself for the `private_ip` output.
- **Broker names don't resolve**: associate the private zone with
  `peer_private_zone_ids`. Check with `dig redpanda-0.redpanda.internal` on
  the bastion. If the names only exist inside Kubernetes (CoreDNS), a zone
  association won't help; expose them through Route 53 (e.g. external-dns).
- **Brokers advertise addresses the bastion can't reach**: Kafka clients
  connect to the advertised listener addresses returned in metadata, not to the
  bootstrap address. They must resolve and route from the bastion VPC.
- **SSH times out**: your public IP changed since `apply` (VPN, new network).
  Run `terraform apply` again to refresh the rule, or set `ssh_cidr`.
- **`rpk: command not found`**: cloud-init is still running or failed. Check
  `/var/log/cloud-init-output.log`. If apt fails with 503s from the regional
  EC2 mirror, set `apt_mirror = "http://archive.ubuntu.com/ubuntu/"`. Changing
  user data replaces the instance.
- **Newer AMI available**: the AMI is ignored after creation so the bastion is
  not replaced. Use `terraform apply -replace=aws_instance.bastion` to rebuild it.

## Security notes

- SSH is the only inbound port on the bastion and is limited to `ssh_cidr`.
  Avoid `0.0.0.0/0`.
- Rules added to broker security groups allow only the bastion's private IP
  and only `peer_ports`. They are removed on `destroy`, and replaced if the
  bastion is replaced.
- Peering changes route tables in the peer VPC. For a Redpanda BYOC VPC, those
  are managed by Redpanda's infrastructure, so prefer a short-lived bastion and
  `destroy` it when done.
- With an existing `vpc_id` and no explicit subnet route table, peering routes
  go into the VPC's main route table, which other subnets may share.
- Terraform state includes IPs and resource IDs. It's kept locally and ignored
  by git; use a remote backend if several people share it.

## License

[Apache License 2.0](LICENSE)
