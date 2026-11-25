# Partial configuration: bucket, key and region are passed with
# `terraform init -backend-config=...` (see README.md). The state key is
# `distai-platform/<region>/<name>/foundation`: the Region is part of the key so
# that a cell name reused in another Region gets its own state instead of
# taking over the first cell's state.
terraform {
  backend "s3" {}
}
