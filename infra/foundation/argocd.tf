# Optional EKS managed Argo CD capability, created only when var.argocd is set
# (hub cells). Users sign in through IAM Identity Center; each entry of
# var.argocd.role_mappings gives its Identity Center groups one Argo CD role
# (ADMIN, EDITOR or VIEWER). Per-team AppProjects, which turn that role into
# access to one team's applications rather than all of them, are the tenancy
# layer's.
#
# Issue #25 (the delivery layer) adds the one AWS-API call that closes the
# gap this comment used to describe: the capability's own access entry
# starts with only the two built-in Argo-CD-capability-management policies
# (AmazonEKSArgoCDClusterPolicy, AmazonEKSArgoCDPolicy -- letting the
# capability manage itself, confirmed on a real cluster), never
# AmazonEKSClusterAdminPolicy or anything else letting it create a
# Namespace/ClusterRole/CustomResourceDefinition for the things it is meant
# to deliver (an EKS access policy association below grants that), and
# gitops/bootstrap/bootstrap.sh (run once per cell, outside
# Terraform) still has to write the three in-cluster objects that let the
# capability discover its own cluster and have something to deliver. The
# "argo_cd.namespace" argument is set explicitly rather than left to default,
# so this layer's own output (argocd_namespace) never has to guess what the
# capability chose.

locals {
  # Matches every published AWS example of this capability (see
  # docs.aws.amazon.com/eks/latest/userguide/argocd-register-clusters.html);
  # set explicitly because the provider's "namespace" argument is Optional,
  # not Computed, so leaving it unset would make this layer's own
  # argocd_namespace output unable to read back what AWS actually used.
  argocd_namespace = "argocd"
}

data "aws_iam_policy_document" "argocd_assume" {
  count = var.argocd == null ? 0 : 1

  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["capabilities.eks.amazonaws.com"]
    }
  }
}

# No permission policies are attached: the capability reaches its own cluster
# through the access entry that EKS creates for it. Grant access to
# repositories or secrets in a later layer when a hub needs them.
resource "aws_iam_role" "argocd" {
  count = var.argocd == null ? 0 : 1

  name               = "${var.name}-argocd-capability"
  assume_role_policy = data.aws_iam_policy_document.argocd_assume[0].json
}

resource "aws_eks_capability" "argocd" {
  count = var.argocd == null ? 0 : 1

  cluster_name              = aws_eks_cluster.this.name
  capability_name           = "argocd"
  type                      = "ARGOCD"
  role_arn                  = aws_iam_role.argocd[0].arn
  delete_propagation_policy = "RETAIN"

  configuration {
    argo_cd {
      namespace = local.argocd_namespace

      aws_idc {
        idc_instance_arn = var.argocd.idc_instance_arn
        idc_region       = var.argocd.idc_region
      }

      dynamic "rbac_role_mapping" {
        for_each = { for m in var.argocd.role_mappings : m.role => m }

        content {
          role = rbac_role_mapping.value.role

          dynamic "identity" {
            for_each = toset(rbac_role_mapping.value.group_ids)

            content {
              id   = identity.value
              type = "SSO_GROUP"
            }
          }
        }
      }
    }
  }
}

# Issue #25 Decision 1: the access entry EKS creates for the capability role
# carries only the two built-in Argo-CD-capability-management policies by
# default (confirmed on a real cluster: AmazonEKSArgoCDClusterPolicy,
# AmazonEKSArgoCDPolicy -- these let the capability manage itself, not
# arbitrary cluster objects), never AmazonEKSClusterAdminPolicy. This
# association is itself a direct AWS API call (never a Kubernetes object), so it stays in
# Terraform, alongside the capability it grants access for, exactly like the
# admin_principal_arns association in eks.tf. Full cluster-admin is used
# because neither AmazonEKSEditPolicy nor AmazonEKSAdminPolicy can create a
# CustomResourceDefinition, ClusterRole/ClusterRoleBinding or Namespace, all
# of which gitops/bootstrap/bootstrap.sh and the add-ons it bootstraps
# (Karpenter, Kueue and later ones) create; the real tenant boundary is the
# tenancy layer's per-team AppProjects and admission bundle, not this role's
# own IAM-side permissions.
#
# Explicit depends_on on aws_eks_capability.argocd, even though neither
# argument above references it: the access entry this association targets
# is the one EKS creates as a side effect of the capability itself, which
# exists only once aws_eks_capability.argocd's own create has returned
# (the provider's waiter blocks until the capability reaches ACTIVE --
# confirmed against the provider source, internal/service/eks/capability.go,
# waitCapabilityCreated). With no dependency edge, this resource has no
# attribute pointing at aws_eks_capability.argocd, so Terraform's graph
# schedules the two concurrently; on a single from-scratch apply this lets
# AssociateAccessPolicy fire before EKS has created the access entry at
# all, failing with ResourceNotFoundException (reproduced on the runner:
# both resources logged "Creating..." in the same second, the association
# failed immediately while the capability itself took 6m41s to reach
# ACTIVE). A two-apply sequence (capability first, association added in a
# later, separate apply -- gitops/tests/1.e2e.sh's own before/after RBAC
# check) never races, since the capability is already long-ACTIVE by the
# second apply; this depends_on makes a single apply safe the same way,
# rather than relying on callers to always apply in two steps.
resource "aws_eks_access_policy_association" "argocd" {
  count = var.argocd == null ? 0 : 1

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = aws_iam_role.argocd[0].arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_capability.argocd]
}
