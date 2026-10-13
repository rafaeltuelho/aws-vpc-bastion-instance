# Peering module

Optional connectivity layer between a **client VPC** (e.g. the bastion VPC from
the [root module](../README.md)) and a **cluster VPC** hosting a Redpanda or
Kafka cluster. It's a separate Terraform root module with its own state, so the
bastion and the cluster project never reference each other; see
[Why peering is a separate module](../README.md#why-peering-is-a-separate-module).

It creates:

- a VPC peering connection, auto-accepted (same account and region)
- routes from the client VPC to every CIDR block of the cluster VPC, including
  secondary ones such as EKS pod ranges
- routes from the cluster VPC back to the client CIDRs
- remote VPC DNS resolution, when both VPCs have DNS support and hostnames on

and optionally:

- client CIDRs as entries in the cluster's **prefix lists**, or as rules in its
  **security groups**
- associations of the cluster's **Route 53 private zones** with the client VPC

## Contents

- [What it changes outside the client VPC](#what-it-changes-outside-the-client-vpc)
- [VPC peering or PrivateLink for Redpanda BYOC](#vpc-peering-or-privatelink-for-redpanda-byoc)
- [Prerequisites](#prerequisites)
- [Usage](#usage)
- [Parameters](#parameters)
- [Working with a cluster managed by another project](#working-with-a-cluster-managed-by-another-project)
- [Finding the IDs you need](#finding-the-ids-you-need)
- [Validations](#validations)
- [Outputs](#outputs)
- [Troubleshooting](#troubleshooting)

## What it changes outside the client VPC

> [!IMPORTANT]
> This module changes resources that usually belong to someone else. Review
> `terraform plan` before applying, and check that the cluster's own project
> won't revert these changes; see
> [Working with a cluster managed by another project](#working-with-a-cluster-managed-by-another-project).

| Change | Where | Controlled by | Avoidable? |
|---|---|---|---|
| Peering connection accepted | Cluster VPC | always | No, it's the peering itself |
| Route `<client CIDR> → peering` | Cluster VPC route tables | always; which tables: `cluster_route_table_ids`, which CIDRs: `client_cidrs` | No. The brokers need a route back, or replies never reach the clients |
| Entries with the client CIDRs | Cluster prefix lists | `cluster_prefix_list_ids` | Yes, leave it empty |
| Inbound rules from the client CIDRs | Cluster security groups | `cluster_security_group_ids` | Yes, leave it empty |
| Client VPC added to the zone's VPCs | Route 53 private zones | `private_zone_ids` | Yes, leave it empty |

Every one of these is removed by `terraform destroy`. Existing routes, rules,
entries or associations are never modified.

## VPC peering or PrivateLink for Redpanda BYOC

This module only sets up VPC peering. For a private Redpanda BYOC cluster on
AWS, Redpanda also supports
[AWS PrivateLink](https://docs.redpanda.com/cloud-data-platform/networking/configure-privatelink-in-cloud-ui/)
and [Transit Gateway](https://docs.redpanda.com/cloud-data-platform/networking/byoc/aws/transit-gateway/).
Neither is covered here; this section is only for choosing between them.

| | VPC peering (this module) | AWS PrivateLink |
|---|---|---|
| Direction | Both ways at the network level: either side can open connections, limited only by security groups. Redpanda recommends rejecting traffic initiated from the Redpanda network. | One way: only clients open connections, through an interface endpoint in their VPC. Redpanda can't reach your VPC. |
| CIDRs | Must not overlap the cluster VPC, or any other VPC peered with it | Can overlap |
| Scale | One peering connection per client VPC, each with routes on both sides. AWS allows 50 active peering connections per VPC by default, adjustable up to 125, which caps the number of peered VPCs, not TCP connections. | One endpoint per client VPC, with no peering quota. Client connections are limited only by your Redpanda usage tier. |
| Changes on the Redpanda side | Peering accepted, routes back to the clients in the Redpanda VPC's private route tables | None in its route tables. You enable the endpoint service in the Redpanda Cloud UI or API, with an allowlist of AWS principal ARNs that may connect. |
| Region | Same region | Same region, or [cross-region PrivateLink](https://docs.redpanda.com/cloud-data-platform/networking/configure-privatelink-in-cloud-ui/#cross-region-privatelink) |
| Client ports | Bootstrap 9092, brokers 30092, Schema Registry 30081, HTTP Proxy 30082, Console 443 | Bootstrap 30292, brokers 32000–32500, Schema Registry 30081, HTTP Proxy 30282 and 35000–35500, Console 443. The endpoint's security group must allow them from the clients. |
| DNS | No extra setup in Redpanda's peering guide | Cluster names resolve to the endpoint's private IPs, reachable only from the endpoint's VPC. Other VPCs and on-premises networks need Route 53 Resolver inbound and outbound endpoints and forwarding rules. |
| Client settings | None | `connections.max.idle.ms` below 350000 (350 s) |
| AWS cost | No charge for the peering itself; data crossing availability zones is billed | Hourly charge per endpoint per availability zone, plus a per-GB data processing charge |

**Choose PrivateLink** when:

- client VPC CIDRs overlap the cluster's, or you can't coordinate address
  ranges with the clients' owners
- many client VPCs or AWS accounts need access, and maintaining a peering and
  routes for each isn't practical
- security policy allows only client-initiated connections, with no network
  path from the Redpanda VPC into yours
- you don't want to change route tables in the Redpanda VPC
- clients run in another region

**Choose VPC peering** (this module) when:

- one or a few client VPCs in the same account and region, with
  non-overlapping CIDRs, need access, e.g. a test bastion like this repository's
- you want the simplest setup, with no endpoints, extra ports or DNS
  forwarding, and no hourly endpoint charges

**Consider Transit Gateway** when many VPCs or on-premises networks already
connect through a hub. Like peering, it needs non-overlapping CIDRs.

## Prerequisites

- Terraform >= 1.9, and AWS credentials for the account and region of both
  VPCs
- Permission to manage VPC peering, routes and, as used, prefix list entries,
  security group rules and Route 53 VPC associations
- CIDR blocks of the two VPCs that don't overlap (checked at plan time)

## Usage

```bash
cd peering
cp terraform.tfvars.example terraform.tfvars   # fill in your values
terraform init
terraform plan                                  # review every change in the cluster VPC
terraform apply
```

Or on the command line, with the bastion VPC from the root module:

```bash
terraform apply \
  -var client_vpc_id=$(terraform -chdir=.. output -raw vpc_id) \
  -var cluster_vpc_id=vpc-0123456789abcdef0
```

Then test from the bastion:

```bash
dig +short <broker-hostname>          # DNS: needs the private zone, if names are private
nc -zv <broker-hostname> <port>       # routes and firewall
rpk cluster info -X brokers=<broker-hostname>:<port>   # plus TLS/SASL settings
```

Destroy this module **before** destroying either VPC:

```bash
terraform destroy
```

## Parameters

### The two VPCs

| Name | Type | Default | Description |
|---|---|---|---|
| `aws_region` | string | `us-east-2` | Region of both VPCs. |
| `client_vpc_id` | string | — | VPC of the clients, e.g. the bastion VPC (`terraform output vpc_id` in the root module). Requester side of the peering. |
| `cluster_vpc_id` | string | — | VPC hosting the Redpanda/Kafka cluster. Accepter side of the peering. ⚠️ The peering is accepted and routes are added here. |
| `name` | string | `<client_vpc_id>-to-<cluster_vpc_id>` | `Name` tag for the peering connection and the other tagged resources; also the description of prefix list entries and security group rules. |
| `tags` | map(string) | `{}` | Extra tags for the resources that support tags. |

### Routes

| Name | Type | Default | Description |
|---|---|---|---|
| `client_cidrs` | list(string) | `null` (all client VPC CIDRs) | Client-side CIDRs the cluster side routes to and allows: the cluster route destinations, prefix list entries and security group rule sources. Must be inside the client VPC. Narrow it, e.g. to the bastion subnet (`["10.255.0.0/24"]`), to keep the cluster-side changes minimal. |
| `client_route_table_ids` | list(string) | `null` (all) | Client VPC route tables that get routes to the cluster VPC. Leave unset unless only some subnets should reach the cluster. |
| `cluster_route_table_ids` | list(string) | `null` (all) | Cluster VPC route tables that get routes back to `client_cidrs`. ⚠️ Changes the cluster VPC either way: unset doesn't mean "no routes", it means all route tables. Set it only to narrow the change, e.g. to the route tables of the broker subnets. |

### Firewall (optional)

> [!NOTE]
> **Not applicable to Redpanda BYOC clusters.** Leave `cluster_prefix_list_ids`,
> `cluster_security_group_ids` and `cluster_ports` unset. See
> [Redpanda BYOC clusters](#redpanda-byoc-clusters).

Peering only opens a network path. The brokers' security groups must also
accept the client CIDRs on the listener ports. Choose **one** of these, or
leave both empty and allow the clients in the cluster project yourself.

| Name | Type | Default | Description |
|---|---|---|---|
| `cluster_prefix_list_ids` | list(string) | `[]` | **Preferred.** Customer-managed prefix lists that the cluster's security group rules reference. Each `client_cidrs` entry is added to each list. The cluster project keeps owning its rules, and only the list's entries change. ⚠️ Changes the prefix lists. Requires the cluster project to set this up once; see [below](#working-with-a-cluster-managed-by-another-project). |
| `cluster_security_group_ids` | list(string) | `[]` | Security groups of the brokers or Kubernetes nodes in the cluster VPC. Each gets one inbound rule per `cluster_ports` × `client_cidrs`. ⚠️ Changes the cluster VPC. If the project that owns a group defines its rules inline (`ingress {}` blocks in `aws_security_group`), its next apply deletes these rules. |
| `cluster_ports` | list(number) | `[9092, 9644, 8081, 8082]` | TCP ports opened in `cluster_security_group_ids` (no effect without it). The defaults are the Kafka API, Redpanda Admin API, Schema Registry and HTTP Proxy. For Redpanda on Kubernetes with NodePort external access, use the NodePorts, e.g. `[31092, 31644, 30081, 30082]`. |

### DNS (optional)

> [!NOTE]
> **Not applicable to Redpanda BYOC clusters.** Leave `private_zone_ids` unset.
> See [Redpanda BYOC clusters](#redpanda-byoc-clusters).

| Name | Type | Default | Description |
|---|---|---|---|
| `private_zone_ids` | list(string) | `[]` | Route 53 **private** hosted zones (same account) to associate with the client VPC, so their records resolve there. Use it when broker names like `redpanda-0.redpanda.internal` live in a private zone, e.g. one managed by external-dns. Give the bare ID (`Z0...`), without `/hostedzone/`. ⚠️ Changes the zones. If the project that owns a zone lists its VPCs inline (`vpc {}` blocks in `aws_route53_zone`), its next apply removes this association. |

Remote VPC DNS resolution needs no parameter. It's turned on automatically when
both VPCs have DNS support and DNS hostnames enabled, so EC2 private hostnames
of instances in the other VPC resolve to private IPs. The
`remote_dns_resolution` output shows whether it was enabled.

### Redpanda BYOC clusters

> [!IMPORTANT]
> With a private Redpanda BYOC cluster, set only the VPCs and routes.
> `cluster_prefix_list_ids`, `cluster_security_group_ids`, `cluster_ports` and
> `private_zone_ids` don't apply. Leave them unset.

| Parameter | Why it doesn't apply to BYOC |
|---|---|
| `cluster_security_group_ids`, `cluster_ports` | The cluster's security groups already accept the private ranges `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16` and `100.64.0.0/10` on the client ports. The Redpanda agent manages these groups and can revoke rules it didn't create, and Redpanda doesn't support customer changes to data plane resources. |
| `cluster_prefix_list_ids` | BYOC security groups don't reference any customer-managed prefix list. |
| `private_zone_ids` | BYOC DNS zones (`<cluster-id>.byoc.prd.cloud.redpanda.com`) are **public** Route 53 zones whose records hold private IPs. They resolve from any VPC with no association, and the module rejects public zones anyway. |

The client VPC's CIDRs must fall in one of those private ranges, and must not
overlap the BYOC VPC's CIDR. The BYOC VPC is tagged
`Name=network-<network-id>`. Route only its private route tables (tag
`purpose=private`), as Redpanda's
[peering guide](https://docs.redpanda.com/cloud-data-platform/networking/byoc/aws/vpc-peering-aws/)
does. Left unset, `cluster_route_table_ids` also adds routes to the public
main route table.

```bash
aws ec2 describe-route-tables \
  --filters "Name=tag:Name,Values=network-<network-id>" "Name=tag:purpose,Values=private" \
  --query 'RouteTables[].RouteTableId'
```

```hcl
client_vpc_id           = "vpc-0123456789abcdef0" # bastion VPC
cluster_vpc_id          = "vpc-0fedcba9876543210" # BYOC VPC, Name=network-<network-id>
client_cidrs            = ["10.255.0.0/24"]       # optional: only the bastion subnet
cluster_route_table_ids = ["rtb-0123456789abcdef0", "rtb-0fedcba9876543210"] # purpose=private only
```

## Working with a cluster managed by another project

If the cluster VPC was created by another Terraform project, e.g. the one that
deployed your EKS cluster, decide for each shared resource which project owns
it. Two projects managing the same object keep undoing each other's changes on
every `apply`, without an error.

| Resource | Safe to use from this module when the cluster project… |
|---|---|
| Routes in the cluster route tables | …defines routes as separate `aws_route` resources, or through a module that does (e.g. `terraform-aws-modules/vpc`). Not when it uses inline `route {}` blocks in `aws_route_table`. |
| Prefix list entries (`cluster_prefix_list_ids`) | …defines the list without inline `entry {}` blocks, or with `lifecycle { ignore_changes = [entry] }`. |
| Security group rules (`cluster_security_group_ids`) | …defines the group's rules as separate resources (`aws_vpc_security_group_ingress_rule` or `aws_security_group_rule`), not inline. |
| Zone associations (`private_zone_ids`) | …defines the zone with `lifecycle { ignore_changes = [vpc] }`, keeping only its own VPC block. |

If the cluster project doesn't meet a condition, don't use that parameter here.
Either change the cluster project once as shown below, or add the client VPC
or CIDR to the cluster project's own config. In the latter case:
- Add it after creating the bastion, because its VPC ID only exists then.
- Remove it before destroying the bastion, or the cluster project keeps
  pointing at a deleted VPC and its next `apply` can fail.

### Recommended one-time changes in the cluster project

**1. Firewall through a prefix list.** The cluster's security group rules
reference a prefix list instead of listing client CIDRs. This module adds the
entries.

```hcl
# In the cluster project
resource "aws_ec2_managed_prefix_list" "kafka_clients" {
  name           = "kafka-clients"
  address_family = "IPv4"
  max_entries    = 20

  # No inline entry blocks: entries come from aws_ec2_managed_prefix_list_entry
  # resources, e.g. in the peering module.
}

resource "aws_vpc_security_group_ingress_rule" "kafka_from_clients" {
  for_each          = toset(["9092", "9644", "8081", "8082"]) # or the NodePorts
  security_group_id = aws_security_group.brokers.id
  prefix_list_id    = aws_ec2_managed_prefix_list.kafka_clients.id
  ip_protocol       = "tcp"
  from_port         = each.key
  to_port           = each.key
}

output "kafka_clients_prefix_list_id" {
  value = aws_ec2_managed_prefix_list.kafka_clients.id
}
```

Then pass that ID here: `cluster_prefix_list_ids = ["pl-..."]`. Each rule that
references a prefix list counts as `max_entries` rules against the security
group's rules quota, so keep `max_entries` modest.

**2. DNS zone that accepts outside associations.**

```hcl
# In the cluster project
resource "aws_route53_zone" "redpanda" {
  name = "redpanda.internal"

  vpc {
    vpc_id = module.vpc.vpc_id # the cluster's own VPC only
  }

  # Other VPCs are associated by aws_route53_zone_association resources,
  # e.g. in the peering module.
  lifecycle {
    ignore_changes = [vpc]
  }
}
```

Then pass the zone ID here: `private_zone_ids = ["Z..."]`.

After these two changes, adding or removing a client VPC only touches this
module. The cluster project doesn't need to know about clients.

## Finding the IDs you need

```bash
export AWS_REGION=us-east-2

# VPCs and their CIDR blocks (client_vpc_id, cluster_vpc_id; check for overlaps)
aws ec2 describe-vpcs \
  --query 'Vpcs[].[VpcId,Tags[?Key==`Name`]|[0].Value,join(`,`,CidrBlockAssociationSet[].CidrBlock)]' --output table

# Customer-managed prefix lists (cluster_prefix_list_ids)
aws ec2 describe-managed-prefix-lists --filters Name=owner-id,Values=$(aws sts get-caller-identity --query Account --output text) \
  --query 'PrefixLists[].[PrefixListId,PrefixListName,MaxEntries]' --output table

# Security groups in the cluster VPC and their inbound ports (cluster_security_group_ids)
aws ec2 describe-security-groups --filters Name=vpc-id,Values=<cluster-vpc-id> \
  --query 'SecurityGroups[].[GroupId,GroupName,join(`,`,IpPermissions[].to_string(ToPort))]' --output table

# Private hosted zones of the cluster VPC (private_zone_ids)
aws route53 list-hosted-zones-by-vpc --vpc-id <cluster-vpc-id> --vpc-region $AWS_REGION \
  --query 'HostedZoneSummaries[].[HostedZoneId,Name]' --output text
```

Route table IDs are rarely needed. Leave them unset, and `terraform plan` lists
the route tables it will update.

## Validations

Checked during `terraform plan`, before anything is created.

| Check | Error when |
|---|---|
| ID formats | VPCs aren't `vpc-…`, route tables `rtb-…`, prefix lists `pl-…`, security groups `sg-…`, zones `Z…` |
| Distinct VPCs | `client_vpc_id` equals `cluster_vpc_id` |
| VPCs exist | Either VPC isn't found in this account and region |
| CIDR overlap | Any CIDR block of the client VPC overlaps any CIDR block of the cluster VPC (AWS can't peer them) |
| `client_cidrs` | Empty or invalid, or not inside the client VPC's CIDR blocks |
| `cluster_ports` | Empty, or a port outside 1–65535 |
| Prefix lists | AWS-managed, not IPv4, or without room for the new entries (`max_entries`) |
| Security groups | Not in the cluster VPC |
| Zones | Public zones |

Some failures are left to AWS to report at apply time:
- a peering connection that already exists between the two VPCs
- a route table that already has a route for the same CIDR
- a prefix list that already has an entry with the same CIDR
- a zone already associated with the client VPC

## Outputs

| Name | Description |
|---|---|
| `peering_connection_id` | VPC peering connection ID |
| `remote_dns_resolution` | Whether remote VPC DNS resolution was enabled |
| `client_cidrs` | Client-side CIDRs routed and allowed on the cluster side |
| `cluster_vpc_cidrs` | Cluster VPC CIDRs routed from the client side |
| `client_route_table_ids` | Client VPC route tables that got routes |
| `cluster_route_table_ids` | Cluster VPC route tables that got routes |
| `prefix_list_entries` | Entries added to the cluster's prefix lists, as prefix list ID => CIDRs |
| `security_group_rule_ids` | Inbound rules added to the cluster's security groups, as `sg\|port\|cidr` => rule ID |
| `private_zone_associations` | Private hosted zones associated with the client VPC, as zone ID => zone name |

## Troubleshooting

Work through these in order from the bastion. Each step depends on the one
before.

1. **Name doesn't resolve** (`dig +short <broker>` is empty): the zone isn't
   associated with the client VPC. Use `private_zone_ids`, or add the client
   VPC to the cluster project's zone config. If the names only exist inside
   Kubernetes (CoreDNS), no zone association helps; expose them through Route
   53, e.g. with external-dns.
2. **Connection times out** (`nc -zv <broker> <port>`): the brokers' security
   groups don't allow the client CIDRs on that port. Use
   `cluster_prefix_list_ids` or `cluster_security_group_ids` with the right
   `cluster_ports`, or allow the CIDR in the cluster project. If that's in
   place, check that `cluster_route_table_ids` includes the route tables of
   the broker subnets.
3. **Bootstrap works, but produce/consume hangs**: Kafka clients connect to
   the advertised listener addresses from the metadata, not to the bootstrap
   address. These must resolve and be routable from the client VPC.
4. **Connection refused or TLS/auth errors**: the network path works, so
   configure the client's TLS and SASL settings.

Errors from Terraform:

- **`VPC CIDRs overlap`**: the VPCs can't be peered. With the bastion module,
  recreate the bastion VPC with a different `vpc_cidr`.
- **`RouteAlreadyExists`**: a route table already has a route for that CIDR,
  e.g. through a Transit Gateway or an older peering. Remove it, or exclude
  that table with `client_route_table_ids` / `cluster_route_table_ids`.
- **Changes disappear after the cluster project's next `apply`**: that project
  defines the resource inline. See
  [Working with a cluster managed by another project](#working-with-a-cluster-managed-by-another-project).
