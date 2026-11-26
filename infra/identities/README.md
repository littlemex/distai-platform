# Identities layer

`infra/identities` is the Terraform root that declares per-add-on AWS identities (issue [#8](https://github.com/littlemex/distai-platform/issues/8)): one scoped IAM role and one EKS Pod Identity association per declared entry of `platform_identities`, for a platform/admin add-on that needs AWS access from a Kubernetes ServiceAccount (the ALB controller, an image builder, OpenZFS, an MCP server, and so on). It has its own Terraform state, separate from `infra/foundation`'s, so that adding or removing one add-on's identity never plans the VPC, the EKS control plane or Karpenter.

| Creates | Does not create |
| --- | --- |
| One `aws_iam_role` per declared entry, trusted only by an EKS Pod Identity session for that entry's own `namespace`/`service_account` (the same three session-tag conditions `infra/foundation/karpenter.tf`'s own Karpenter controller role trust policy uses) | The EKS cluster, the `eks-pod-identity-agent` add-on (`infra/foundation`) |
| One scoped inline policy per entry that declares `s3` and/or `kms_key_arns`: `s3:GetObject`/`s3:ListBucket` on exactly the declared bucket(s) and prefix(es); `s3:PutObject`/`s3:DeleteObject` added only for a bucket with `write = true`; `kms:Decrypt` (and `kms:GenerateDataKey` only if some bucket has `write = true`) on exactly the declared key ARNs | Karpenter's own controller/node roles (unchanged, stay in `infra/foundation`) |
| Managed-policy attachments for every ARN an entry lists in `policy_arns` | A shared role used by more than one entry - every entry gets its own role, by design (see "Why one role per entry", below) |
| One `aws_eks_pod_identity_association` per entry, binding that entry's own role to that entry's own `namespace`/`service_account` and no other | A team's own per-workload AWS access (that is `#22` Decision 2's single, ABAC-scoped shared role - a different, deliberately non-interchangeable mechanism; see "Relationship to #22", below) |

## Why one role per entry

A single shared role's own identity policy is the union of everything every workload associated with it needs: there is no way for a shared role's policy document to grant one add-on read access and another write access, or to grant one add-on access to bucket A and deny it access to bucket B that a different add-on may touch. `infra/foundation/karpenter.tf` already does not use a shared role either - the Karpenter controller role and the Karpenter node role are two separate `aws_iam_role` resources, each with its own trust policy and its own scoped policies. This layer generalizes that same shape into one small, reusable module (the `for_each` over `var.platform_identities` in `identities.tf`) instead of a fifth hand-written copy of role-plus-trust-policy-plus-association.

An add-on with no entry in `platform_identities` gets no role and no association at all. A Pod Identity call from its ServiceAccount has nothing to assume; `AccessDenied` follows from there being no such role, not from a shared role's own policy happening to deny it.

## Relationship to #22 Decision 2 (per-team identity)

[#22](https://github.com/littlemex/distai-platform/issues/22) Decision 2 gives every *team* namespace one **shared**, ABAC-scoped IAM role: every team's Pod Identity association points at the same role, and the per-team distinction lives in the *resource's own* policy (an S3 bucket policy condition on `aws:PrincipalTag/kubernetes-namespace`, a tag EKS Pod Identity sets automatically). That shape works because the AWS APIs most teams need (S3) have a resource-based policy to put the condition on.

This layer is deliberately the opposite shape - one role **per entry**, scoped in the *role's own* policy - because most platform-add-on APIs (EC2, ELB, FSx, and so on) have no resource-based policy to attach a per-caller condition to; a shared role's own policy cannot express "this add-on gets read access, that one gets write access" at all. The two mechanisms solve the same class of problem (role sprawl, forgotten cleanup) for two different populations (platform add-ons vs. teams) and must not be merged: `platform_identities` is for cluster-admin-owned, platform/admin add-ons running in platform namespaces (`kube-system` and similar) - never for a team's own workload identity.

## Relationship to the team RBAC guard (PR #66)

`gitops/bootstrap/team-rbac-guard.yaml` (merged by PR #66) is a `ValidatingAdmissionPolicy` that governs `Role`/`RoleBinding` **Kubernetes** objects written into a namespace carrying the `distai.dev/team` label. `infra/identities` never creates a `Role`, a `RoleBinding`, or any other Kubernetes object at all - `aws_eks_pod_identity_association` is a pure AWS API resource (confirmed against the AWS provider's own resource schema); nothing it does ever reaches the Kubernetes API server, so the guard never evaluates anything this layer creates. The two stay unrelated as long as `platform_identities` entries target platform namespaces, not a namespace carrying `distai.dev/team` - this is an operational convention of this layer's own callers, not something Terraform itself can check (a namespace's own labels are a live cluster fact, not a static input this root can see), so it is stated here rather than enforced in code.

## Adopting an already-existing, hand-rolled identity

An add-on identity created by hand before this layer existed (exactly the shape issue #8's own Motivation describes) can be brought under Terraform without recreating it:

1. Add its entry to `platform_identities`, matching its real `namespace`/`service_account` and the access it actually needs (this is usually narrower than what the hand-rolled version grants - that narrowing is the point).
2. Import the existing role: `terraform import 'aws_iam_role.entry["<key>"]' <existing-role-name>` (the role name, not its ARN).
3. Run `terraform plan` and read it before applying: expect an in-place **update** of the role's trust policy and of its attached/inline policies, never a replacement (a replacement would mean the import target did not match, for example a role name typo). If the plan shows `-/+` (replace) for the role, stop and fix the entry before applying.
4. Apply. The role's ARN does not change, so no Pod Identity association recreation is needed; a workload already using this role through the hand-rolled path keeps working, now under this layer's own narrower policy.

## Pods created before the association need a restart

EKS Pod Identity injects credentials into a Pod at Pod creation time (through a mutating webhook that adds the credential-fetching environment variables and volume). A Pod that was already `Running` before its own `aws_eks_pod_identity_association` was created does not retroactively gain those credentials: it must be restarted (deleted and recreated, or rolled) after the association exists. This is a property of EKS Pod Identity itself (confirmed against the AWS documentation for the feature: "Amazon EKS Pod Identity associations" / "existing pods"), not something this layer's own resources control either way.

## Usage

Apply `infra/foundation` first (the cluster and the `eks-pod-identity-agent` add-on must already exist). Then, from the repository root:

```bash
export CLUSTER_NAME=example-cell
export AWS_REGION=us-east-1
export STATE_BUCKET=example-terraform-state-bucket
export STATE_REGION=us-east-1
export TF_VAR_cluster_name="$CLUSTER_NAME"
export TF_VAR_region="$AWS_REGION"
cd infra/identities
terraform init \
  -backend-config="bucket=${STATE_BUCKET}" \
  -backend-config="key=distai-platform/${AWS_REGION}/${CLUSTER_NAME}/identities" \
  -backend-config="region=${STATE_REGION}" \
  -backend-config="use_lockfile=true"
```

Declare one or more entries (a `terraform.tfvars.json` file, or `TF_VAR_platform_identities` as a JSON string), then apply:

```json
{
  "image-builder": {
    "namespace": "image-builder",
    "service_account": "image-builder",
    "s3": [{ "bucket": "example-cell-images", "prefixes": ["manifests/"] }]
  }
}
```

```bash
terraform apply
```

Point the add-on's own Helm chart at the entry's own role: no annotation on the `ServiceAccount` is needed (unlike IRSA) - the `aws_eks_pod_identity_association` alone is what binds the role to the namespace/service account pair; a `ServiceAccount` of that exact name just needs to exist in that exact namespace, and the add-on's own Pod spec just needs to use it.

## Why this layer, not IRSA or a community module

| Option | What it is | Why | Decision |
| --- | --- | --- | --- |
| IRSA (`iamserviceaccount`, OIDC federation) | The older mechanism: an OIDC identity provider plus a role trust policy matching `system:serviceaccount:<ns>:<sa>` in the OIDC token's `sub` claim | `infra/foundation` already uses EKS Pod Identity natively for Karpenter (no OIDC provider is even created by this repository); adding IRSA here would be a second, parallel identity mechanism with its own OIDC-provider lifecycle, for no capability Pod Identity lacks. awsome-distributed-ai's own examples (for example `examples/training/verl/hyperpod-eks/rlvr/setup/setup-irsa.sh`) still use IRSA - this repository does not follow that, consistent with AWS's own current guidance to prefer Pod Identity for new EKS clusters | Rejected |
| `terraform-aws-modules/terraform-aws-eks-pod-identity` (community module, Apache-2.0, ~106 stars, actively maintained) | A generic module: one role plus association per module call, with per-add-on boolean flags and ARN lists for a fixed catalog of well-known add-ons (EBS CSI, EFS CSI, Velero, Mountpoint S3 CSI, and others) | No generic, declarative `{ s3, kms_key_arns, policy_arns }` shape - each add-on it supports has its own bespoke variables. It has no entry at all for this repository's own `sharedfs` or for an admin-defined custom add-on (an MCP server, OpenZFS), so adopting it would still need custom `policy_statements` per entry, which keeps exactly the "write the policy by hand each time" cost issue #8 is trying to remove, while also adding an external module dependency this repository's foundation layer does not otherwise use (every resource in `infra/foundation` is hand-written, no `module "..." { source = "terraform-aws-modules/..." }` call exists anywhere in this repository today) | Rejected (for now; nothing here blocks calling it for a future well-known add-on it already has a built-in policy for, alongside this layer) |
| EKS Pod Identity, hand-written per entry (this layer) | One small, declarative module (`identities.tf`'s `for_each` over `var.platform_identities`), matching the exact shape issue #8 proposed and the shape `infra/foundation/karpenter.tf` already uses for Karpenter | Matches this repository's own existing convention (no external Terraform module dependency; every IAM resource hand-written and reviewed in place); the variable shape is exactly what issue #8's acceptance criteria need, no more and no less | **Adopt** |

## Static checks

No AWS credentials needed; see `tests/0.static.sh` (`terraform fmt`, `terraform validate`, `tflint`, `terraform test` against the mocked provider - input validation plus IAM-shape assertions such as "a write entry adds `kms:GenerateDataKey`", "an entry with only `policy_arns` gets no inline policy").

Checkov was considered for this layer specifically (IAM least-privilege scanning) and rejected for now: it is not installed on this repository's own EC2 test runner, and the `terraform test` mocked-provider assertions above already cover the exact shape this issue's acceptance criteria name (no wildcard action, no undeclared statement, resources scoped to the declared bucket/prefix) in the same style `infra/foundation/tests/variables.tftest.hcl` already uses - adding a second, differently-shaped tool for the same claim was not judged worth a new dependency on the runner. Revisit if a future add-on's required permissions grow complex enough that a generic IAM linter starts catching something the targeted `terraform test` assertions do not.

## End-to-end test

`tests/1.e2e.sh` applies `infra/foundation` (CPU-only, no Argo CD), then this layer on top, and needs real AWS credentials; see the script's own header comment for the full list of what it checks and the required environment variables.
