# AGENTS.md

Guidance for AI coding agents working in this repository.

## Purpose

Two independent Terraform root modules, each with its own state:

- **Bastion** (repository root): an SSH bastion, with `rpk` and `kcat`
  installed by cloud-init, for reaching a Redpanda or Kafka cluster on AWS. It
  goes into a new VPC (`create_vpc`), an existing VPC (`vpc_id`), or a Redpanda
  BYOC cluster VPC (`redpanda_cluster_id`). It must never change anything
  outside its own resources.
- **Peering** (`peering/`): the connectivity layer between a client VPC (e.g.
  the bastion's) and a cluster VPC: peering, routes both ways, and optional
  prefix list entries, security group rules and Route 53 zone associations on
  the cluster side.

Keep them decoupled. The bastion doesn't know about peering, neither module
reads the other's state (no `terraform_remote_state`), and the peering module
takes both VPC IDs as plain inputs. Same account and region only. No child
modules.

## Layout

- `main.tf`: providers, locals, BYOC agent lookup, subnet/AMI/IP/key pair
  lookups, bastion security group and instance
- `vpc.tf`: optional new VPC (`create_vpc`)
- `variables.tf`, `outputs.tf`, `user-data.sh` (cloud-init, rendered with
  `templatefile()`), `terraform.tfvars.example`
- `peering/main.tf`: peering, routes, CIDR checks, prefix list entries,
  security group rules, zone associations
- `peering/variables.tf`, `peering/outputs.tf`, `peering/terraform.tfvars.example`
- `README.md`: overview, layout choice, bastion docs, order of operations;
  `peering/README.md`: peering docs, including how to hand cluster-side
  resources over from another project

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
- Validations: input-only checks go in `variable` `validation` blocks
  (cross-variable references need Terraform >= 1.9). Two variables'
  validations must not reference each other, or Terraform reports a cycle.
  Checks that need AWS data go in `lifecycle` `precondition`s. Document every
  new check in the matching README's Validations table.
- Peering: everything it changes on the cluster side must be removable by
  `destroy` and must never modify existing objects (only add routes, entries,
  rules, associations). Mark every parameter that changes the cluster side with
  ⚠️ in `peering/README.md` and "CHANGES ..." in its description.
- Give every variable and output a `description`, and document it in the
  README tables.
- Each root module has its own `.terraform.lock.hcl`; commit both when
  provider versions change (see below).

## Checks before committing

Run in both the repository root and `peering/`:

```bash
terraform fmt -check
terraform init -backend=false && terraform validate
```

Also `shellcheck user-data.sh` if available (ignore template-interpolation
warnings).

`terraform plan` needs AWS credentials and makes read-only lookups. A local
`terraform.tfvars` is loaded automatically and can skew tests; run plans from a
copy without it. Never run `apply` or `destroy` without the user's explicit
request.

## Never commit

State files, `terraform.tfvars`, plan files, private keys (`*.pem`), or real
account IDs, cluster IDs, VPC/subnet/security group/prefix list/zone IDs, IPs,
or key names, including in `*.tfvars.example` files. Use placeholders like
`vpc-0123456789abcdef0`.

## Provider versions

`hashicorp/aws` is constrained to `>= 5.0, < 7.0` in both modules; each lock
file pins the exact version. To upgrade within the range, run
`terraform init -upgrade` in the module, then regenerate hashes for all
platforms:

```bash
terraform providers lock -platform=linux_amd64 -platform=linux_arm64 \
  -platform=darwin_amd64 -platform=darwin_arm64 -platform=windows_amd64
```

Before raising the upper bound to a new major version, review that version's
upgrade guide and run `terraform validate` against it.
