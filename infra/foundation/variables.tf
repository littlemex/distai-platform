variable "name" {
  description = "Cell and cluster name. Used as the EKS cluster name, the Karpenter discovery tag value, the interruption queue name and the prefix of IAM role and policy names."
  type        = string

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", var.name))
    error_message = "name must be 3 to 32 characters of lowercase letters, digits and hyphens, start with a letter and not end with a hyphen."
  }
}

variable "region" {
  description = "AWS Region of the cell, for example us-east-1."
  type        = string

  validation {
    condition     = can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.region))
    error_message = "region must be an AWS Region code such as us-east-1."
  }
}

variable "kubernetes_version" {
  description = "Amazon EKS Kubernetes version. The managed add-on versions are pinned per Kubernetes version in eks.tf; a version without an entry there is rejected at plan time."
  type        = string
  default     = "1.37"

  validation {
    condition     = can(regex("^1\\.[0-9]+$", var.kubernetes_version))
    error_message = "kubernetes_version must look like 1.37."
  }
}

variable "vpc_cidr" {
  description = "IPv4 CIDR of the VPC. Each Availability Zone gets a private subnet of one eighth of the range and a small public subnet."
  type        = string
  default     = "10.0.0.0/16"

  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0)) && tonumber(try(split("/", var.vpc_cidr)[1], "0")) >= 16 && tonumber(try(split("/", var.vpc_cidr)[1], "0")) <= 20
    error_message = "vpc_cidr must be a valid IPv4 CIDR with a prefix length between /16 and /20."
  }
}

variable "single_nat_gateway" {
  description = "Create one NAT gateway for the whole VPC (cheaper, suited to test cells) instead of one per Availability Zone."
  type        = bool
  default     = true
}

variable "endpoint_public_access_cidrs" {
  description = "IPv4 CIDRs allowed to reach the public Kubernetes API endpoint. Required and non-empty; each entry must be a network address with prefix length /8 or longer, so 0.0.0.0/0 is rejected. Authentication still goes through IAM and EKS access entries."
  type        = list(string)

  validation {
    condition     = length(var.endpoint_public_access_cidrs) > 0
    error_message = "endpoint_public_access_cidrs must contain at least one CIDR (an empty list would open the endpoint to 0.0.0.0/0)."
  }

  validation {
    condition     = alltrue([for c in var.endpoint_public_access_cidrs : can(cidrhost(c, 0)) && !strcontains(c, ":")])
    error_message = "Every entry of endpoint_public_access_cidrs must be a valid IPv4 CIDR."
  }

  validation {
    condition = alltrue([
      for c in var.endpoint_public_access_cidrs :
      try(tonumber(split("/", c)[1]) >= 8 && cidrsubnet(c, 0, 0) == c, false)
    ])
    error_message = "Every entry of endpoint_public_access_cidrs must be a network address with a prefix length of /8 or longer (0.0.0.0/0 and other very wide ranges are rejected); list the networks that need the API."
  }
}

variable "admin_principal_arns" {
  description = "IAM role or user ARNs given cluster admin (AmazonEKSClusterAdminPolicy, cluster scope) through EKS access entries. The identity that runs Terraform is not given access implicitly; include it here to use kubectl."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for a in var.admin_principal_arns : can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:(role|user)/.+$", a))])
    error_message = "Every entry of admin_principal_arns must be an IAM role or user ARN (arn:aws:iam::<account>:role/<name>), not an STS assumed-role ARN."
  }

  validation {
    condition     = length(distinct(var.admin_principal_arns)) == length(var.admin_principal_arns)
    error_message = "admin_principal_arns must not contain duplicates."
  }
}

variable "system_node_group" {
  description = "System managed node group for controllers (Karpenter, CoreDNS and other critical add-ons). Nodes carry the taint CriticalAddonsOnly=true:NoSchedule. x86_64 instance types only (AMI type AL2023_x86_64_STANDARD)."
  type = object({
    instance_types = optional(list(string), ["m7i.large"])
    size           = optional(number, 2)
  })
  default  = {}
  nullable = false

  validation {
    condition     = length(var.system_node_group.instance_types) > 0
    error_message = "system_node_group.instance_types must contain at least one instance type."
  }

  # AWS instance type names follow <family letters><generation digits>
  # [processor/capability letters].<size> (EC2 User Guide, "Instance type
  # names"). When a processor letter is present it comes right after the
  # generation digits: "a" for AMD, "i" for Intel, "g" for AWS Graviton
  # (Arm64), optionally followed by other capability letters such as
  # d (local NVMe storage), n (network/EBS optimized), e (extra memory) -
  # for example c7gn, x2gd, im4gn, is4gen. A bare "g" with no digits before
  # it, as in g5 or g6e, is the Graphics-instance family letter, not the
  # processor letter, and must stay accepted (verified below). The one
  # Graviton family that predates this convention is a1 (Graviton1), which
  # carries no "g" at all and is matched as a separate literal.
  #
  # Verified with `terraform console` against a mix of real type names:
  # rejected (Graviton/Arm) - m7g.large, c7gn.xlarge, t4g.medium,
  #   x2gd.xlarge, im4gn.xlarge, is4gen.xlarge, r8g.xlarge, m6g.large,
  #   g5g.xlarge, a1.medium
  # accepted (x86_64) - m7i.large, g5.xlarge, g6e.xlarge, m6idn.large,
  #   c5a.large, c5ad.2xlarge, x2iedn.xlarge, trn1.2xlarge, inf2.xlarge,
  #   dl1.24xlarge
  validation {
    condition = alltrue([
      for t in var.system_node_group.instance_types :
      !can(regex("^(a1|[a-z]+[0-9]+g[a-z]*)\\.", t))
    ])
    error_message = "system_node_group.instance_types must be x86_64 (Intel or AMD) instance types; one or more entries look like an AWS Graviton (Arm64) instance type, which the AL2023_x86_64_STANDARD AMI type for this node group does not support."
  }

  validation {
    condition     = var.system_node_group.size >= 1 && floor(var.system_node_group.size) == var.system_node_group.size
    error_message = "system_node_group.size must be a whole number of at least 1."
  }
}

variable "argocd" {
  description = "Create the EKS managed Argo CD capability (hub cells only) when set. idc_instance_arn and idc_region identify the IAM Identity Center instance; role_mappings gives each listed Identity Center group one of the Argo CD roles (ADMIN, EDITOR or VIEWER) across all applications of the capability. Until the tenancy layer's per-team AppProjects ship (#22), the only AppProject is the admin-owned `platform` project (gitops/bootstrap/bootstrap.sh), so every role here, including EDITOR and VIEWER, can act on every object that AppProject allows (#63, filed as a private report \"SA1\"): ADMIN can deploy any add-on's own Kubernetes objects within that AppProject's scope, and Argo CD does not have a lower-privilege Edit/View split below the AppProject boundary itself. Map a group to EDITOR or VIEWER here only when that group should already have that access; do not treat either as a safe, read-mostly default for a wider audience until #22 ships."
  type = object({
    idc_instance_arn = string
    idc_region       = string
    role_mappings = list(object({
      role      = string
      group_ids = list(string)
    }))
  })
  default = null

  validation {
    condition     = var.argocd == null || can(regex("^arn:aws[a-z-]*:sso:::instance/(sso)?ins-[a-zA-Z0-9-.]{16}$", var.argocd.idc_instance_arn))
    error_message = "argocd.idc_instance_arn must be an IAM Identity Center instance ARN (arn:aws:sso:::instance/ssoins-...)."
  }

  validation {
    condition     = var.argocd == null || can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+$", var.argocd.idc_region))
    error_message = "argocd.idc_region must be an AWS Region code."
  }

  validation {
    condition     = var.argocd == null || length(var.argocd.role_mappings) > 0
    error_message = "argocd.role_mappings must contain at least one role mapping."
  }

  validation {
    condition     = var.argocd == null || alltrue([for m in var.argocd.role_mappings : contains(["ADMIN", "EDITOR", "VIEWER"], m.role)])
    error_message = "Every argocd.role_mappings[*].role must be one of ADMIN, EDITOR or VIEWER."
  }

  validation {
    condition     = var.argocd == null || alltrue([for m in var.argocd.role_mappings : length(m.group_ids) > 0])
    error_message = "Every argocd.role_mappings[*].group_ids must contain at least one Identity Center group ID."
  }

  validation {
    condition     = var.argocd == null || length(distinct([for m in var.argocd.role_mappings : m.role])) == length(var.argocd.role_mappings)
    error_message = "argocd.role_mappings must not map the same role twice; list every group for a role in that one entry's group_ids."
  }
}

variable "budget_limit_usd" {
  description = "Monthly AWS Budgets limit, in US dollars, for this cell's own tagged resources (cost_filter on the tag key distai-platform/cell, value var.name). Optional; null (the default) creates no aws_budgets_budget, Amazon SNS topic or Amazon SNS subscription at all, for example throwaway end-to-end test cells that never set it. When set, the cell's own Amazon SNS topic is notified at 80% and 100% of this limit (ACTUAL spend)."
  type        = number
  default     = null

  validation {
    condition     = var.budget_limit_usd == null || var.budget_limit_usd > 0
    error_message = "budget_limit_usd must be a positive number of US dollars, or null to create no budget."
  }
}

variable "budget_notification_emails" {
  description = "Email addresses subscribed to this cell's own Amazon SNS budget-alert topic. Each address needs its own AWS-sent confirmation click before it receives anything. Only used when budget_limit_usd is set; an empty list (the default) still creates the topic and the budget, with nobody subscribed yet."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for e in var.budget_notification_emails : can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", e))])
    error_message = "Every entry of budget_notification_emails must look like an email address."
  }

  validation {
    condition     = length(distinct(var.budget_notification_emails)) == length(var.budget_notification_emails)
    error_message = "budget_notification_emails must not contain duplicates."
  }
}

variable "tags" {
  description = "Tags applied to every resource this layer creates (through the provider's default_tags)."
  type        = map(string)
  default     = {}
  nullable    = false
}

variable "shared_fsx_lustre" {
  description = "Optional: create one shared FSx for Lustre file system for this cell (#18, #22 Decision 8): datasets, model weights and per-team checkpoint directories, delivered to tenants through the sharedfs controller (gitops/addon-catalog/sharedfs), never through Terraform's own state (gitops/README.md: Terraform's state graph never contains a Kubernetes object once a cell exists). null (the default) creates nothing -- fsx.tf's resources, the aws-fsx-csi-driver managed add-on and the sharedfs controller image's ECR repository all key off this being non-null, the same optional-capability shape as var.argocd. deployment_type SCRATCH_2 is this variable's own default: it is FSx's smallest real deployment type (no minimum capacity above 1200 GiB, no backup/replication machinery), chosen for this platform's own test cells (RFC #17/#22: 'the test cluster... may be destroyed and recreated'), not a production sizing recommendation -- a cell that needs PERSISTENT_1/PERSISTENT_2 (durability, higher baseline throughput) sets deployment_type explicitly. Lustre project quotas (sharedfs's own provision.quota) need Lustre 2.15; file_system_type_version below defaults to exactly that, for every deployment type, not only the one quotas need."
  type = object({
    deployment_type             = optional(string, "SCRATCH_2")
    storage_capacity_gib        = optional(number, 1200)
    per_unit_storage_throughput = optional(number)
    # 2.15 (AWS's CreateFileSystem API reference: "recommended for all
    # new file systems," supported on every Lustre deployment type) -
    # not FSx's own implicit default, which is 2.10 except for
    # PERSISTENT_2 (2.12, or 2.15 only with a metadata configuration
    # mode set). Pinned explicitly rather than left at that default:
    # this platform's own EKS worker nodes mount through the Lustre
    # 2.15 client the aws-fsx-csi-driver's own image ships, and nothing
    # here has confirmed a 2.15 client can mount a 2.10 server (FSx for
    # Lustre's own client/server version-skew guarantees are narrower
    # than "any client can mount any server") - not yet re-verified on
    # a real cluster after this fix, since no real-machine budget
    # remained once it was found (see this PR's own Test Results).
    file_system_type_version = optional(string, "2.15")
    # false (AWS's own CreateFileSystem default) unless set true: a
    # PERSISTENT_1/PERSISTENT_2 file system takes a final backup on
    # deletion unless this is set, and that is the safe default to keep
    # for any cell this variable's own default did not already describe
    # as disposable (this variable's own description above: SCRATCH_2,
    # "chosen for this platform's own test cells... not a production
    # sizing recommendation"). A cell whose own fixture is destroyed and
    # recreated on every real-machine run sets this true explicitly
    # (gitops/tests/.tmp-sharedfs-verify.sh's own terraform apply does -
    # there is no infra/foundation/tests fixture for shared_fsx_lustre
    # yet, a known gap this variable's own description does not claim is
    # closed); nothing here defaults every cell, including a future
    # PERSISTENT one, to the less-safe choice.
    skip_final_backup = optional(bool, false)
  })
  default  = null
  nullable = true

  validation {
    condition     = var.shared_fsx_lustre == null || contains(["SCRATCH_1", "SCRATCH_2", "PERSISTENT_1", "PERSISTENT_2"], var.shared_fsx_lustre.deployment_type)
    error_message = "shared_fsx_lustre.deployment_type must be one of SCRATCH_1, SCRATCH_2, PERSISTENT_1, PERSISTENT_2 (the FSx for Lustre deployment types the aws_fsx_lustre_file_system resource accepts)."
  }

  # FSx for Lustre's own minimum/increment (AWS's CreateFileSystem API
  # reference, StorageCapacity, fetched 2026-11-27 - an earlier version
  # of this validation got both branches wrong and was corrected before
  # being exercised against a storage_capacity_gib value that would have
  # caught it, twice over - the first fix (2026-11-27) misread "increments
  # of 3600" for SCRATCH_1 as continuing from the 2400 anchor already
  # named in the same sentence (6000, 9600, ...), rather than as its own
  # anchor (3600, 7200, ...); corrected against the FSx for Lustre User
  # Guide's own per-storage-server unit for Scratch 1 (3.6 TiB,
  # "Deployment and storage class options" page, IP addresses section),
  # which only a whole-multiple-of-3600 reading matches): "For SCRATCH_2,
  # PERSISTENT_2, and PERSISTENT_1 deployment types using SSD storage
  # type, the valid values are 1200 GiB, 2400 GiB, and increments of 2400
  # GiB" (this variable has no storage_type field at all - every file
  # system it creates uses FSx's own SSD default - so the HDD-specific
  # PERSISTENT_1 increments that same reference states do not apply
  # here); "For SCRATCH_1 deployment type, valid values are 1200 GiB,
  # 2400 GiB, and increments of 3600 GiB [i.e. 3600, 7200, ...]". This
  # validation states that constraint so a bad value fails `terraform
  # validate`/`plan`, not a 20-plus-minute `apply` against the real FSx
  # API (this platform's own real-machine budget is counted in attempts,
  # not retries of an avoidable input error).
  validation {
    condition = (
      var.shared_fsx_lustre == null ||
      (
        var.shared_fsx_lustre.deployment_type == "SCRATCH_1"
        ? (
          contains([1200, 2400], var.shared_fsx_lustre.storage_capacity_gib) ||
          (var.shared_fsx_lustre.storage_capacity_gib >= 3600 && var.shared_fsx_lustre.storage_capacity_gib % 3600 == 0)
        )
        : (
          var.shared_fsx_lustre.storage_capacity_gib == 1200 ||
          (var.shared_fsx_lustre.storage_capacity_gib >= 2400 && var.shared_fsx_lustre.storage_capacity_gib % 2400 == 0)
        )
      )
    )
    error_message = "shared_fsx_lustre.storage_capacity_gib must be 1200, 2400, or a multiple of 3600, for deployment_type SCRATCH_1; or 1200, or a multiple of 2400, for SCRATCH_2/PERSISTENT_1/PERSISTENT_2 (SSD - this variable has no storage_type field for the HDD-specific PERSISTENT_1 increments)."
  }

  # Per-deployment-type MB/s/TiB values (same AWS reference as above,
  # PerUnitStorageThroughput): PERSISTENT_1 SSD accepts 50/100/200 only;
  # PERSISTENT_2 SSD accepts 125/250/500/1000 only - an earlier version
  # of this validation accepted either set for both types (silently
  # wrong for a value like 125 on PERSISTENT_1, which InvalidPerUnit
  # StorageThroughput would reject at apply), corrected here to check
  # per type. Also required, not merely checked-if-set: the same AWS
  # reference states this argument is "Required with PERSISTENT_1 and
  # PERSISTENT_2 deployment types using an SSD or HDD storage class" -
  # an earlier version of this validation let a PERSISTENT cell plan
  # cleanly with this left null, deferring the real rejection
  # (MissingFileSystemConfiguration or similar) to `apply`.
  validation {
    condition = (
      var.shared_fsx_lustre == null ||
      (
        var.shared_fsx_lustre.deployment_type == "PERSISTENT_1"
        ? (var.shared_fsx_lustre.per_unit_storage_throughput != null && contains([50, 100, 200], var.shared_fsx_lustre.per_unit_storage_throughput))
        : var.shared_fsx_lustre.deployment_type == "PERSISTENT_2"
        ? (var.shared_fsx_lustre.per_unit_storage_throughput != null && contains([125, 250, 500, 1000], var.shared_fsx_lustre.per_unit_storage_throughput))
        : var.shared_fsx_lustre.per_unit_storage_throughput == null
      )
    )
    error_message = "shared_fsx_lustre.per_unit_storage_throughput is required and must be one of 50, 100, 200 for deployment_type PERSISTENT_1 (SSD), or required and one of 125, 250, 500, 1000 for PERSISTENT_2 (SSD); it must be left null for SCRATCH_1/SCRATCH_2, which do not take this argument."
  }
}

variable "test_invalid_karpenter_node_principal_arn" {
  type        = string
  default     = null
  description = "Test-only. When set, used as the access entry's principal_arn for the Karpenter node role instead of its real ARN. EKS rejects an access entry for a principal that does not exist, so terraform_data.teardown_guard (which depends_on aws_eks_access_entry.karpenter_node) cannot be created, even though the cluster and the system node group already exist, letting a test force that specific partial-apply state (see issue #26). Must stay null outside tests."
  validation {
    condition     = var.test_invalid_karpenter_node_principal_arn == null || length(var.test_invalid_karpenter_node_principal_arn) > 0
    error_message = "test_invalid_karpenter_node_principal_arn must not be an empty string; use null to disable."
  }
}

variable "test_invalid_coredns_version" {
  type        = string
  default     = null
  description = "Test-only. When set, used as the add-on version for the coredns add-on instead of the pinned version, letting a test force terraform apply to fail after the cluster and system node group already exist (see issue #26). Must stay null outside tests."
  validation {
    condition     = var.test_invalid_coredns_version == null || length(var.test_invalid_coredns_version) > 0
    error_message = "test_invalid_coredns_version must not be an empty string; use null to disable."
  }
}
