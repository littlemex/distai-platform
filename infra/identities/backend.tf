# Partial configuration: bucket, key and region are passed with
# `terraform init -backend-config=...` (see README.md). The state key is
# `distai-platform/<region>/<cluster_name>/identities`, the same shape
# infra/foundation/backend.tf uses for its own `.../foundation` key (the
# Region is part of the key so that a cluster name reused in another Region
# gets its own state), with `identities` in place of `foundation` so that
# this layer's own state never shares a key, and therefore never shares a
# plan or an apply, with the foundation layer's state for the same cluster
# (issue #8's own "adding or removing one entry plans and applies only
# infra/identities/" acceptance criterion).
terraform {
  backend "s3" {}
}
