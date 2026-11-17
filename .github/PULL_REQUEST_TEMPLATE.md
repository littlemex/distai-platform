## Purpose

<!-- Link related issues using "Fixes #123" or "Relates to #123". Every pull request starts from an issue. -->

## Changes

<!-- Summarize the changes made in this PR -->

-

## Test Plan

<!-- Describe how you tested these changes. Commands must be copy-pasteable: set environment values with export at the top and refer to them as variables. -->

**Environment:**

- AWS Region:
- Amazon EKS version:
- Node pool and instance type:
- Number of nodes:

**Test commands:**

```bash

```

## Test Results

<!--
REQUIRED for functional changes: paste evidence of an end-to-end run on a
real AWS environment (apply output, workload output, metrics, relevant logs).
Validate, plan, unit tests and mocks are supporting checks, not a real run.
Redact account IDs, ARNs, cluster names, endpoints and IP addresses.

Until the verifier has run, keep the pull request a draft and write:
pending verification

For changes with no functional impact, replace this section's content with
the single word: docs-only
-->

## Layout

<!-- If adding a component or a document, ensure it follows the layout below. -->

```text
infra/
└── eks/                        # Terraform root, Helm charts, scripts
    ├── *.tf                    # One file per concern
    ├── charts/<name>/          # Helm charts, each with its own README
    ├── scripts/                # Numbered in usage order when run by hand
    └── docs/                   # Design records (ADRs) for the platform
docs/
├── workshop/                   # Hands-on chapters, English / Japanese
└── deep-dives/
    └── NNNNN-<slug>.html       # Self-contained explainer, English / Japanese
```

## Checklist

- [ ] I have read the [contributing guidelines](https://github.com/littlemex/distai-platform/blob/main/CONTRIBUTING.md) and [AGENTS.md](https://github.com/littlemex/distai-platform/blob/main/AGENTS.md).
- [ ] I am working against the latest `main` branch.
- [ ] I have searched existing open and recently merged PRs to confirm this is not a duplicate.
- [ ] The change is self-contained with documentation and scripts.
- [ ] External dependencies are pinned to a specific version, tag or digest (no `latest`).
- [ ] No credentials or environment-specific values (account IDs, cluster names, endpoints, IP addresses, resource IDs) are committed or pasted, including in Test Results.
- [ ] New IAM permissions, network exposure or disabled safeguards are called out and justified in this description.
- [ ] A README is included or updated with prerequisites, instructions, and known issues.
- [ ] Test Results above contain e2e evidence from a real AWS run (or this PR is marked `docs-only`).
