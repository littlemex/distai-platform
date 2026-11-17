# Partial configuration: bucket, key and region are passed with
# `terraform init -backend-config=...` (see README.md). The state key is
# `distai-platform/<name>/foundation`.
terraform {
  backend "s3" {}
}
