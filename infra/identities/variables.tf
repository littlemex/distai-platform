variable "cluster_name" {
  description = "Name of the already-existing EKS cluster (infra/foundation's var.name for the same cell) that every entry's Pod Identity association targets. This layer never creates the cluster; apply infra/foundation first."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.cluster_name))
    error_message = "cluster_name must be 3 to 32 characters of lowercase letters, digits and hyphens, start with a letter and not end with a hyphen (the same shape infra/foundation's var.name requires, since it must match an existing cluster's own name)."
  }
}

variable "region" {
  description = "AWS Region of the cell (infra/foundation's var.region for the same cell)."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.region))
    error_message = "region must be an AWS Region code such as us-east-1."
  }
}

variable "platform_identities" {
  description = <<-EOT
    Declarative per-add-on AWS identities (issue #8). One entry per
    platform/admin add-on that needs AWS access from a Kubernetes
    ServiceAccount (the ALB controller, an image builder, OpenZFS, an MCP
    server, and so on) - never a team workload identity: that population is
    #22 Decision 2's single shared, ABAC-scoped role, a deliberately
    different mechanism (see README.md).

    Each map key is a short, stable, logical name for the add-on (by
    default also becomes part of its IAM role's name - see role_name);
    each value declares:
      namespace       - Kubernetes namespace of the add-on's ServiceAccount.
      service_account  - name of that ServiceAccount.
      role_name       - optional. The entry's own IAM role is named
                         "<cluster_name>-identity-<key>" by default; set
                         role_name to adopt an already-existing role under
                         its own real name instead (for example when
                         importing a role created by hand before this
                         mechanism existed - see README.md "Adopting an
                         already-existing, hand-rolled identity"). IAM role
                         names cannot be changed in place, so a map key
                         that happens not to match an existing role's real
                         name must not force a replacement; this field is
                         the escape hatch for that mismatch.
      s3              - list of { bucket, prefixes, write }. Every bucket
                         grants s3:GetObject/s3:ListBucket scoped to exactly
                         the listed key prefixes; write = true additionally
                         grants s3:PutObject/s3:DeleteObject on the same
                         prefixes. prefixes has no default - list "" to grant
                         the whole bucket, explicitly.
      kms_key_arns    - KMS key ARNs the role may use to decrypt (and, if any
                         s3 entry has write = true, also encrypt) objects
                         under the buckets above. Empty by default: no KMS
                         statement at all unless declared.
      policy_arns     - AWS managed or customer managed policy ARNs attached
                         to the entry's own role as-is, for access this
                         module's s3/kms_key_arns shape cannot express.

    Every entry gets its own aws_iam_role, scoped to only that entry's own
    declared permissions, and its own aws_eks_pod_identity_association bound
    to only that entry's own namespace/service_account - never a role or
    association shared with another entry. An add-on with no entry here gets
    neither, so a Pod Identity call from its ServiceAccount has no role to
    assume and AccessDenied, by construction (no undeclared role exists for
    it to be denied from using, rather than a shared role's own policy
    happening to deny it).
  EOT
  type = map(object({
    namespace       = string
    service_account = string
    role_name       = optional(string, null)
    s3 = optional(list(object({
      bucket   = string
      prefixes = list(string)
      write    = optional(bool, false)
    })), [])
    kms_key_arns = optional(list(string), [])
    policy_arns  = optional(list(string), [])
  }))
  default  = {}
  nullable = false

  validation {
    condition     = alltrue([for k in keys(var.platform_identities) : can(regex("^[a-z][a-z0-9-]{0,38}$", k))])
    error_message = "Every key of platform_identities must be 2 to 39 characters of lowercase letters, digits and hyphens, starting with a letter (it becomes part of an IAM role name)."
  }

  validation {
    condition = alltrue([
      for k, v in var.platform_identities :
      v.role_name != null || length("${var.cluster_name}-identity-${k}") <= 64
    ])
    error_message = "cluster_name plus every platform_identities key must fit IAM's 64-character role-name limit as \"<cluster_name>-identity-<key>\" unless that entry sets its own role_name; shorten cluster_name or the key, or set role_name explicitly."
  }

  validation {
    condition = alltrue([
      for v in values(var.platform_identities) :
      v.role_name == null || can(regex("^[\\w+=,.@-]{1,64}$", v.role_name))
    ])
    error_message = "Every entry's role_name, when set, must be 1 to 64 characters and match IAM's own role-name character set (letters, digits, and + = , . @ _ -)."
  }

  validation {
    condition = alltrue([
      for k, v in var.platform_identities :
      length([
        for k2, v2 in var.platform_identities :
        k2 if k2 != k && coalesce(v2.role_name, "${var.cluster_name}-identity-${k2}") == coalesce(v.role_name, "${var.cluster_name}-identity-${k}")
      ]) == 0
    ])
    error_message = "Two entries of platform_identities resolve to the same IAM role name (either the same explicit role_name, or the derived \"<cluster_name>-identity-<key>\" name colliding with another entry's role_name); every entry must have a distinct role name."
  }

  validation {
    condition = alltrue([
      for k, v in var.platform_identities :
      length(v.s3) > 0 || length(v.kms_key_arns) > 0 || length(v.policy_arns) > 0
    ])
    error_message = "Every entry of platform_identities must declare at least one of s3, kms_key_arns or policy_arns; an entry with none of the three would create a Pod Identity association to a role that can do nothing, which is never useful and is rejected rather than silently created."
  }

  validation {
    condition = alltrue(flatten([
      for v in values(var.platform_identities) : [
        can(regex("^[a-z0-9]([a-z0-9.-]{1,61}[a-z0-9])?$", v.namespace)) ? true : false,
      ]
    ]))
    error_message = "Every entry's namespace must be a valid Kubernetes name (lowercase alphanumeric, '-' or '.', 1 to 63 characters)."
  }

  validation {
    condition = alltrue(flatten([
      for v in values(var.platform_identities) : [
        can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", v.service_account)) ? true : false,
      ]
    ]))
    error_message = "Every entry's service_account must be a valid Kubernetes name (lowercase alphanumeric or '-', 1 to 63 characters)."
  }

  validation {
    condition = alltrue(flatten([
      for v in values(var.platform_identities) : [
        for b in v.s3 : can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", b.bucket))
      ]
    ]))
    error_message = "Every s3[*].bucket must be a valid S3 bucket name (lowercase alphanumeric, '.' or '-', 3 to 63 characters)."
  }

  validation {
    condition = alltrue(flatten([
      for v in values(var.platform_identities) : [
        for b in v.s3 : length(b.prefixes) > 0
      ]
    ]))
    error_message = "Every s3[*].prefixes must list at least one prefix; list \"\" explicitly to grant the whole bucket - there is no default that would grant it implicitly."
  }

  validation {
    condition = alltrue(flatten([
      for v in values(var.platform_identities) : [
        for arn in v.kms_key_arns : can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/[a-fA-F0-9-]+$", arn))
      ]
    ]))
    error_message = "Every kms_key_arns entry must be a KMS key ARN of the form arn:aws:kms:<region>:<account>:key/<id> (a key alias ARN is not accepted: alias ARNs can be repointed at a different key without changing the ARN string, which would silently change what this scoped role can decrypt)."
  }

  validation {
    condition = alltrue(flatten([
      for v in values(var.platform_identities) : [
        for arn in v.policy_arns : can(regex("^arn:aws[a-z-]*:iam::(aws|[0-9]{12}):policy/.+$", arn))
      ]
    ]))
    error_message = "Every policy_arns entry must be an IAM managed policy ARN (arn:aws:iam::aws:policy/<name> or arn:aws:iam::<account>:policy/<path><name>)."
  }
}

variable "tags" {
  description = "Tags applied to every resource this layer creates (through the provider's default_tags)."
  type        = map(string)
  default     = {}
  nullable    = false
}
