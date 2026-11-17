# Security Policy

## Reporting a Vulnerability

Please report security vulnerabilities privately through
[GitHub private vulnerability reporting](https://github.com/littlemex/distai-platform/security/advisories/new).
Do **not** open a public issue, pull request or discussion for a vulnerability.

Include, as far as you can:

- The affected file, resource or component, and the commit or tag.
- The impact: what an attacker can read, change or reach.
- Steps to reproduce, with credentials, account IDs and other sensitive values redacted.

If the vulnerability is in an AWS service rather than in this repository, report it to AWS through the [AWS vulnerability reporting page](https://aws.amazon.com/security/vulnerability-reporting/).

## Scope

This repository provisions infrastructure in your AWS account. Findings in scope include, for example, IAM permissions broader than a component needs, resources reachable from the internet without an explicit opt-in, credentials or sensitive values written to logs, outputs or state, and unpinned dependencies or workflows that can be used to inject code.

## Supported Versions

Security fixes are made on `main` and released in the next tag.
