# AWS VPC Bastion for Redpanda and Kafka

Terraform for a small SSH bastion (Ubuntu 24.04) on AWS for working with a
private Redpanda or Apache Kafka cluster, such as a private Redpanda BYOC
cluster or a self-managed cluster on EKS. It comes with
[`rpk`](https://docs.redpanda.com/current/reference/rpk/) and
[`kcat`](https://github.com/edenhill/kcat) preinstalled.

The bastion always runs in its own client VPC, never in the cluster's VPC, and
reaches the brokers through VPC peering. That mirrors a typical client network
and leaves the cluster VPC to its owner; Redpanda, for one, doesn't support
customer changes to a BYOC cluster's data plane resources.

The repository has two independent Terraform root modules, each with its own
state:

| Module | Directory | What it does |
|---|---|---|
| **Bastion** | `.` (repository root) | Launches the bastion in a new VPC or an existing client VPC, separate from the cluster's. It never changes anything outside its own resources. |
| **Peering** | [`peering/`](peering/README.md) | Connectivity layer: VPC peering between a client VPC (e.g. the bastion's) and a cluster VPC, routes in both directions, and optionally firewall and private DNS access. |

## Contents

- [How it fits together](#how-it-fits-together)
- [Why peering is a separate module](#why-peering-is-a-separate-module)
- [Bastion module](#bastion-module)
  - [Prerequisites](#prerequisites)
  - [Usage](#usage)
  - [Connect to a Redpanda BYOC cluster](#connect-to-a-redpanda-byoc-cluster)
  - [Parameters](#parameters)
  - [What gets created](#what-gets-created)
  - [Validations](#validations)
  - [Outputs](#outputs)
  - [Troubleshooting](#troubleshooting)
- [Order of operations](#order-of-operations)
- [Security notes](#security-notes)

## How it fits together

```
 bastion VPC (create_vpc or vpc_id)          cluster VPC (private cluster)
 ┌──────────────────────────────┐  peering   ┌──────────────────────────────┐
 │ bastion: rpk, kcat           │◄──────────►│ brokers                      │
 └──────────────────────────────┘            └──────────────────────────────┘
   bastion module (repo root)     peering/       cluster's own project
```

1. Deploy the **bastion** with `create_vpc = true`, or into an existing client
   VPC with `vpc_id`. Its CIDR must not overlap the cluster VPC's.
2. Connect it with the **[peering module](peering/README.md)**.

Same AWS account and region as the cluster.

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

- With an existing VPC (`vpc_id`): a client VPC, not the cluster's, with at
  least one public subnet (`map-public-ip-on-launch=true`) routed to an
  internet gateway

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

# Existing client VPC (not the cluster's)
terraform apply -var vpc_id=vpc-0123456789abcdef0 -var key_name=<key> -var owner=<you>
```

Then connect it to the cluster with the [peering module](peering/README.md).

#### Connect

```bash
ssh -i ~/.ssh/<key>.pem ubuntu@$(terraform output -raw public_ip)
```

Cloud-init needs a minute or two after boot. Check progress with
`tail -f /var/log/cloud-init-output.log`, or wait with
`cloud-init status --wait`.

Then, once the [peering module](peering/README.md) is applied, connect from
the bastion. For a Redpanda BYOC cluster, follow
[Connect to a Redpanda BYOC cluster](#connect-to-a-redpanda-byoc-cluster).
For self-managed Redpanda or Kafka:

```bash
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

Destroy the peering module first; see [Order of operations](#order-of-operations).

### Connect to a Redpanda BYOC cluster

This needs a BYOC cluster with private networking, the bastion, and the
[peering module](peering/README.md#redpanda-byoc-clusters) applied with the
cluster's `purpose=private` route tables. Run every step on the bastion.

The endpoints are on the cluster's overview page in Redpanda Cloud, under
**How to connect**:

| Endpoint | Port | Used for |
|---|---|---|
| `seed-<hash>.<cluster-id>.byoc.prd.cloud.redpanda.com` | 9092 | Kafka bootstrap. Clients then connect to each broker on 30092. |
| `api-<hash>.<cluster-id>.byoc.prd.cloud.redpanda.com` | 443 | Data Plane API (users, ACLs, topics, connectors) and Redpanda Console |
| `schema-registry-<hash>.<cluster-id>.byoc.prd.cloud.redpanda.com` | 30081 | Schema Registry |
| `pandaproxy-<hash>.<cluster-id>.byoc.prd.cloud.redpanda.com` | 30082 | HTTP Proxy |

The Admin API (9644) isn't exposed in Redpanda Cloud, so commands that need
it, such as `rpk cluster config`, `rpk cluster health` and `rpk redpanda`,
don't work. Change cluster properties in the Cloud UI or with the Control
Plane API instead.

#### 1. Check the network path

```bash
SEED=seed-<hash>.<cluster-id>.byoc.prd.cloud.redpanda.com
API=https://api-<hash>.<cluster-id>.byoc.prd.cloud.redpanda.com

dig +short "$SEED"         # private IPs in the cluster VPC
nc -zv "$SEED" 9092
nc -zv "${API#https://}" 443
```

If these time out, see the
[peering module's troubleshooting](peering/README.md#troubleshooting).

#### 2. Log in to Redpanda Cloud

The bastion has no browser, so `rpk` prints a sign-in URL. Open it on your
own machine:

```bash
rpk cloud login --no-browser --no-profile
```

For automation, use a service account instead (Organization IAM in the Cloud
UI). `--save` stores the credentials in `rpk.yaml` so `rpk` can refresh the
token:

```bash
rpk cloud login --client-id <client-id> --client-secret <client-secret> --save --no-profile
```

#### 3. Create an rpk profile for the cluster

```bash
rpk cloud cluster select <cluster-name> --profile <cluster-name>
```

This fills in the brokers and enables TLS. BYOC certificates are publicly
trusted, so you don't need `tls.ca`.

#### 4. Create the first SASL user and its ACLs

Kafka commands need a SASL user with ACLs, so the first user has to be
created outside the Kafka API. Use either option.

**Redpanda Console**: in the cluster's **Security** page, create a user under
**Users**, then open it and add ACLs (**Allow all operations** for a lab only).
With API gateway access set to Private, the Console loads only from inside
the peered network: tunnel your browser through the bastion, e.g.
`sshuttle -r ubuntu@<bastion-ip> <cluster-vpc-cidr>` or `ssh -D 1080` with a
SOCKS5 proxy, or switch API gateway access to Public in the cluster's
Dataplane settings.

**Data Plane API**, from the bastion, with the token saved by `rpk cloud login`:

```bash
TOKEN=$(awk '/auth_token:/ {print $2; exit}' ~/.config/rpk/rpk.yaml)
RP_USER=admin
read -rsp 'Password: ' RP_PASS; echo

dp() {  # dp <path>: POST JSON from stdin to the Data Plane API
  curl -fsS -X POST "$API$1" -H "Authorization: Bearer $TOKEN" \
    -H 'content-type: application/json' -d @-
}

jq -n --arg u "$RP_USER" --arg p "$RP_PASS" \
  '{name: $u, password: $p, mechanism: "SASL_MECHANISM_SCRAM_SHA_256"}' | dp /v1/users

# Full access on topics, consumer groups and the cluster (narrow it for production)
for r in TOPIC:'*' GROUP:'*' CLUSTER:kafka-cluster; do
  jq -n --arg u "User:$RP_USER" --arg t "RESOURCE_TYPE_${r%%:*}" --arg n "${r#*:}" \
    '{principal: $u, host: "*", resource_type: $t, resource_name: $n,
      resource_pattern_type: "RESOURCE_PATTERN_TYPE_LITERAL",
      operation: "OPERATION_ALL", permission_type: "PERMISSION_TYPE_ALLOW"}' | dp /v1/acls
done
```

#### 5. Add the credentials to the profile and test

```bash
rpk profile set user="$RP_USER" pass="$RP_PASS" sasl.mechanism=SCRAM-SHA-256

rpk cluster info
rpk topic create test
echo hello | rpk topic produce test
rpk topic consume test -n 1
```

`rpk` stores the password in plain text in `~/.config/rpk/rpk.yaml`.

With kcat:

```bash
kcat -b "$SEED:9092" -X security.protocol=SASL_SSL \
  -X sasl.mechanisms=SCRAM-SHA-256 -X sasl.username="$RP_USER" -X sasl.password="$RP_PASS" \
  -X ssl.ca.location=/etc/ssl/certs/ca-certificates.crt -L
```

#### 6. More users and ACLs

With the admin user in the profile, manage the rest with `rpk`:

```bash
rpk security user create app1 -p '<password>' --mechanism SCRAM-SHA-256
rpk security acl create --allow-principal User:app1 \
  --operation read,describe --topic 'logs-' --resource-pattern-type prefixed
rpk security acl create --allow-principal User:app1 --operation read --group app1
```

If `rpk security user create` fails on your `rpk` version, create the user
with the Data Plane API call from step 4.

### Parameters

#### Required

| Name | Type | Default | Description |
|---|---|---|---|
| `key_name` | string | — | Name of an existing EC2 key pair in `aws_region`. You log in with its private key. |
| `owner` | string | — | Prefix for resource names, e.g. your username. Letters, digits, `-` and `_` only (1–32 characters). Resources are named `<owner>-bastion[-<vpc_id>]`. |
| `aws_region` | string | `us-east-2` | Region of the bastion. |

#### Bastion VPC: set exactly one

| Name | Type | Default | Description |
|---|---|---|---|
| `create_vpc` | bool | `false` | Create a new VPC for the bastion: one public subnet spanning `vpc_cidr`, an internet gateway and a route table, with DNS support and hostnames enabled. The availability zone is chosen automatically among those that offer `instance_type`. |
| `vpc_cidr` | string | `10.255.0.0/24` | CIDR of the new VPC (only with `create_vpc`). Between `/16` and `/28`. If you plan to peer it with a cluster VPC, pick a range that overlaps none of that VPC's CIDR blocks, including secondary ones. |
| `vpc_id` | string | `null` | Existing client VPC to deploy into. Never the cluster's VPC: a Redpanda BYOC VPC (tag `redpanda-managed=true` or `Name=network-<id>`) is rejected. The bastion goes into its first public subnet (sorted by ID). |

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

All resources are tagged `Name=<name>`.

### Validations

These are checked during `terraform plan`, before anything is created.

| Check | Error when |
|---|---|
| Bastion VPC source | Not exactly one of `create_vpc`, `vpc_id` is set |
| `owner` | Empty, longer than 32 characters, or contains characters other than letters, digits, `-`, `_` (e.g. a leftover `<your-name>` placeholder) |
| Key pair | `key_name` doesn't exist in `aws_region` |
| `vpc_cidr` | Not a valid IPv4 CIDR, or outside `/16`–`/28` |
| `vpc_id` format | Not `vpc-…` |
| Not a BYOC VPC | `vpc_id` is a Redpanda BYOC cluster VPC (tag `redpanda-managed=true` or `Name=network-<20-character id>`) |
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
| `vpc_cidr` | Bastion VPC primary CIDR block |
| `subnet_id` | Bastion subnet ID |

### Troubleshooting

- **`no matching EC2 Key Pair found`**: `key_name` doesn't exist in
  `aws_region` (key pairs are per region).
- **`No public subnet ...`**: the existing VPC has no subnet with auto-assign
  public IP. Use `create_vpc = true`, or another VPC.
- **`Value for undeclared variable`** warnings: your `terraform.tfvars` still
  has settings from an older version, e.g. `peer_vpc_id` or
  `redpanda_cluster_id`. Remove them; peering now lives in `peering/`, and the
  bastion no longer deploys into a cluster VPC.
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
