# Contributing Guidelines

Thank you for your interest in contributing to this project. Whether it's a bug report, new feature, correction, or additional documentation, we greatly value feedback and contributions from our community.

Please read through this document before submitting any issues or pull requests to ensure we have all the necessary information to effectively respond to your bug report or contribution. AI-assisted contributions also follow [AGENTS.md](./AGENTS.md).

## Reporting Bugs/Feature Requests

We welcome you to use the GitHub issue tracker to report bugs or suggest features.

When filing an issue, please check existing open, or recently closed, issues to make sure somebody else hasn't already reported the issue. Please try to include as much information as you can. Details like these are incredibly useful:

* A reproducible test case or series of steps
* The commit or tag of this repository being used
* Any modifications you've made relevant to the bug
* Anything unusual about your environment or deployment

Please redact credentials, account IDs, cluster names and IP addresses from anything you paste.

## Contributing via Pull Requests

Contributions via pull requests are much appreciated. Before sending us a pull request, please ensure that:

1. You are working against the latest source on the *main* branch.
2. You check existing open, and recently merged, pull requests to make sure someone else hasn't addressed the problem already.
3. You open an issue to discuss the work first. Every pull request links an issue, and `main` accepts changes only through pull requests.

To send us a pull request, please:

1. Fork the repository.
2. Modify the source; please focus on the specific change you are contributing. If you also reformat all the code, it will be hard for us to focus on your change.
3. Ensure local checks pass and verify the change on a real cluster (see [AGENTS.md](./AGENTS.md#accountability)).
4. Commit to your fork using clear commit messages.
5. Send us a pull request, answering the questions in the pull request template.
6. Pay attention to any automated CI failures reported in the pull request, and stay involved in the conversation.

GitHub provides additional document on [forking a repository](https://help.github.com/articles/fork-a-repo/) and [creating a pull request](https://help.github.com/articles/creating-a-pull-request/).

## Contributions format

Regardless of their nature, components of this repository must:

* Be self contained with documentation and scripts. If they depend on external software (charts, providers, container images, libraries), fix the versions via a version, tag, digest or commit ID to ensure reproducibility and do not use a `latest` tag.
* Have a README file in markdown format with the prerequisites, instructions on deploying or running the component and notes for known edge cases or common issues.
* Number scripts that are run by hand in sequence in their usage order, starting by 0. Example: `0.preprocessing.sh`, `1.processing.sh`, `2.post-processing.sh`.
* Be contributed through pull requests, without exception.
* Follow a KISS principle, **K**eep **I**t **S**imple and **S**tupid. Users should expect to copy paste commands, reproduce tests as is and have some guidance on what to modify if they need to.
* Stick to Terraform for infrastructure and Helm for Kubernetes packaging.
* Be verified on the scale they claim. If a document says two p5en nodes, test on two p5en nodes.

Documentation lives under `docs/`. The workshop (`docs/workshop/`) and the deep dives (`docs/deep-dives/`) are written in English and Japanese, with a language switch on every page.

## Finding contributions to work on

Looking at the existing issues is a great way to find something to contribute on. Issues labeled `status: ready` and `help wanted` are a great place to start.

The repository uses the default GitHub labels plus the following:

| Label | Meaning |
| --- | --- |
| `RFC` | Proposal for a significant change |
| `ci-failure` | A CI workflow is failing |
| `security` | Security hardening or exposure |
| `stale` | No activity; set by the stale workflow |
| `area: infra`, `area: docs`, `area: workshop`, `area: ci` | The part of the repository the issue is about |
| `status: ready`, `status: in progress`, `status: in review`, `status: verifying` | Hand-off state, see [AGENTS.md](./AGENTS.md#2-roles-and-hand-offs) |

## Code of Conduct

See [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md).

## Security issue notifications

If you discover a potential security issue in this project we ask that you report it privately as described in [SECURITY.md](./SECURITY.md). Please do **not** create a public GitHub issue.

## Licensing

See the [LICENSE](LICENSE) file for our project's licensing. By submitting a pull request, you agree that your contribution is licensed under the same Apache-2.0 License.
