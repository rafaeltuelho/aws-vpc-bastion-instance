# AGENTS.md

Guidance for AI coding agents working in this repository.

## Purpose

A single Terraform root module that launches an SSH bastion, with `rpk` and
`kcat` installed by cloud-init, for reaching a Redpanda or Kafka cluster on
AWS. The bastion goes into a new VPC (`create_vpc`), an existing VPC
(`vpc_id`), or a Redpanda BYOC cluster VPC (`redpanda_cluster_id`), and can be
peered with the cluster VPC (`peer_vpc_id`). Keep it a single root module with
no child modules; same account and region only.

## Layout

- `main.tf`: providers, shared locals, BYOC agent lookup, subnet/AMI/IP
  lookups, bastion security group and instance
- `vpc.tf`: optional new VPC (`create_vpc`)
- `peering.tf`: optional peering, routes both ways, broker security group
  rules, Route 53 private zone associations, CIDR overlap check
- `variables.tf`: inputs and validations; `outputs.tf`: outputs
- `user-data.sh`: cloud-init script rendered with `templatefile()`
- `terraform.tfvars.example`: template for `terraform.tfvars` (git-ignored)

## Conventions

- `user-data.sh` is a Terraform template: `${name}` is interpolated by
  Terraform. Write a literal shell `${VAR}` as `$${VAR}`. Every new template
  variable must also be passed in `templatefile()` in `main.tf`.
- The AMI filter is x86_64 and `rpk_url` points at the amd64 build; keep them
  consistent if adding arm64 support.
- `ignore_changes = [ami]` keeps a running bastion from being replaced by a
  newer AMI; don't remove it. `user_data_replace_on_change` is intentional.
- Optional features use `count`/`for_each` on null or empty inputs. Read
  optional resources and data sources with `one(x[*].attr)`, `try()` or
  `for` over the whole list, never `x[0]` outside the resource's own block,
  so the disabled path still evaluates.
- `local.peering` (in `peering.tf`) is true when `peer_vpc_id` is set, or
  `create_vpc` and `redpanda_cluster_id` are both set. Use it, not
  `peer_vpc_id != null`, to decide whether peering resources exist.
- Validations: input-only checks go in `variable` `validation` blocks
  (cross-variable references need Terraform >= 1.9). Two variables'
  validations must not reference each other, or Terraform reports a cycle.
  Checks that need AWS data go in `lifecycle` `precondition`s. Document every
  new check in the README's Validations table.
- Changes in the peer VPC (routes, security group rules) must stay minimal:
  routes target only the bastion subnet CIDR, and security group rules only the
  bastion private IP `/32`.
- Give every variable and output a `description`, and document it in the
  README tables.
- Commit `.terraform.lock.hcl` when provider versions change (see below).

## Checks before committing

```bash
terraform fmt -check
terraform init -backend=false && terraform validate
shellcheck user-data.sh   # if available; ignore template-interpolation warnings
```

`terraform plan` needs AWS credentials and makes read-only lookups. Never run
`apply` or `destroy` without the user's explicit request.

## Never commit

State files, `terraform.tfvars`, plan files, private keys (`*.pem`), or real
account IDs, cluster IDs, VPC/subnet/security group/zone IDs, IPs, or key
names in examples. Use placeholders like `vpc-0123456789abcdef0`.

## Provider versions

`hashicorp/aws` is constrained to `>= 5.0, < 7.0`; the lock file pins the
exact version. To upgrade within the range, run `terraform init -upgrade`,
then regenerate hashes for all platforms:

```bash
terraform providers lock -platform=linux_amd64 -platform=linux_arm64 \
  -platform=darwin_amd64 -platform=darwin_arm64 -platform=windows_amd64
```

Before raising the upper bound to a new major version, review that version's
upgrade guide and run `terraform validate` against it.
