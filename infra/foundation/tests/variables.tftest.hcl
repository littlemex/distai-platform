# Input validation tests. They run `terraform plan` against a mocked AWS
# provider, so they need no credentials and create nothing:
#   terraform -chdir=infra/foundation test

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names    = ["us-east-1a", "us-east-1b", "us-east-1c"]
      zone_ids = ["use1-az1", "use1-az2", "use1-az4"]
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "111122223333"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }
}

variables {
  name                         = "example-cell"
  region                       = "us-east-1"
  endpoint_public_access_cidrs = ["203.0.113.0/24"]
}

run "argocd_accepts_all_three_roles" {
  command = plan

  variables {
    argocd = {
      idc_instance_arn = "arn:aws:sso:::instance/ssoins-0123456789abcdef"
      idc_region       = "us-east-1"
      role_mappings = [
        { role = "ADMIN", group_ids = ["admins"] },
        { role = "EDITOR", group_ids = ["team-a"] },
        { role = "VIEWER", group_ids = ["team-b", "team-c"] },
      ]
    }
  }
}

run "argocd_rejects_unknown_role" {
  command = plan

  variables {
    argocd = {
      idc_instance_arn = "arn:aws:sso:::instance/ssoins-0123456789abcdef"
      idc_region       = "us-east-1"
      role_mappings    = [{ role = "OWNER", group_ids = ["admins"] }]
    }
  }

  expect_failures = [var.argocd]
}

run "argocd_rejects_empty_group_ids" {
  command = plan

  variables {
    argocd = {
      idc_instance_arn = "arn:aws:sso:::instance/ssoins-0123456789abcdef"
      idc_region       = "us-east-1"
      role_mappings    = [{ role = "ADMIN", group_ids = [] }]
    }
  }

  expect_failures = [var.argocd]
}

run "argocd_rejects_duplicate_role" {
  command = plan

  variables {
    argocd = {
      idc_instance_arn = "arn:aws:sso:::instance/ssoins-0123456789abcdef"
      idc_region       = "us-east-1"
      role_mappings = [
        { role = "ADMIN", group_ids = ["admins"] },
        { role = "ADMIN", group_ids = ["more-admins"] },
      ]
    }
  }

  expect_failures = [var.argocd]
}

run "argocd_rejects_no_role_mappings" {
  command = plan

  variables {
    argocd = {
      idc_instance_arn = "arn:aws:sso:::instance/ssoins-0123456789abcdef"
      idc_region       = "us-east-1"
      role_mappings    = []
    }
  }

  expect_failures = [var.argocd]
}

run "endpoint_rejects_wide_cidrs" {
  command = plan

  variables {
    endpoint_public_access_cidrs = ["0.0.0.0/1", "128.0.0.0/1"]
  }

  expect_failures = [var.endpoint_public_access_cidrs]
}

run "endpoint_rejects_empty_list" {
  command = plan

  variables {
    endpoint_public_access_cidrs = []
  }

  expect_failures = [var.endpoint_public_access_cidrs]
}
