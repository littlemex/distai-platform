## Purpose

<!-- Link related issues using "Fixes #123" or "Relates to #123" -->

## Changes

<!-- Summarize the changes made in this PR -->

-

## Test Plan

<!-- Describe how you tested these changes -->

**Environment:**

- AWS Service:
- Instance type:
- Number of nodes:

**Test commands:**

```bash

```

## Test Results

<!--
REQUIRED for functional changes: paste evidence of an end-to-end run on a
real AWS environment (job output, benchmark numbers, relevant logs).

For changes with no functional impact, replace this section's content with
the single word: docs-only
-->

## Directory Structure

<!-- If adding or updating an example, ensure it follows the expected layout below. -->

```text
infra/
└── eks/                        # Terraform root of the platform
    ├── *.tf                    # One file per concern
    ├── charts/<name>/          # Helm charts, each with its own README
    ├── scripts/                # Scripts run by hand, numbered in usage order
    └── docs/                   # Design records (ADRs)
docs/
├── workshop/                   # Hands-on chapters, English / Japanese
└── deep-dives/
    └── NNNNN-<slug>.html       # Self-contained explainer, English / Japanese
```

- `infra/eks/` holds the platform; a new concern extends an existing file
  before adding a new one (see [AGENTS.md](https://github.com/littlemex/distai-platform/blob/main/AGENTS.md) for placement rules).
- `docs/workshop/` holds the hands-on chapters and `docs/deep-dives/` the
  long-form explainers; both provide English and Japanese.
- Not all directories are touched by every change — include only the ones relevant to your change.

## Checklist

- [ ] I have read the [contributing guidelines](https://github.com/littlemex/distai-platform/blob/main/CONTRIBUTING.md).
- [ ] I am working against the latest `main` branch.
- [ ] I have searched existing open and recently merged PRs to confirm this is not a duplicate.
- [ ] The contribution is self-contained with documentation and scripts.
- [ ] External dependencies are pinned to a specific version or tag (no `latest`).
- [ ] A README is included or updated with prerequisites, instructions, and known issues.
- [ ] New test cases follow the [expected directory structure](#directory-structure).
- [ ] Test Results above contain e2e evidence from a real AWS run (or this PR is marked `docs-only`).
