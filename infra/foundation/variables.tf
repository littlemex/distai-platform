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

  validation {
    condition     = var.system_node_group.size >= 1 && floor(var.system_node_group.size) == var.system_node_group.size
    error_message = "system_node_group.size must be a whole number of at least 1."
  }
}

variable "argocd" {
  description = "Create the EKS managed Argo CD capability (hub cells only) when set. idc_instance_arn and idc_region identify the IAM Identity Center instance; role_mappings gives each Identity Center group one of the Argo CD roles (ADMIN, EDITOR or VIEWER) so that a team can be given read or edit access without being a cluster admin."
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

variable "tags" {
  description = "Tags applied to every resource this layer creates (through the provider's default_tags)."
  type        = map(string)
  default     = {}
  nullable    = false
}
