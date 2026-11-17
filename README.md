# distai-platform

An Amazon EKS platform for distributed training and inference, built with Terraform and Karpenter. It provisions the VPC, the cluster, accelerator node pools (NVIDIA GPU, AWS Trainium and Inferentia, EFA, EC2 Capacity Blocks for ML), shared storage, observability and job scheduling.

This is not an official AWS project. Its contribution workflow follows the conventions of [awslabs/awsome-distributed-ai](https://github.com/awslabs/awsome-distributed-ai).

## Repository layout

| Path | Contents |
| --- | --- |
| `infra/eks/` | Terraform root, Helm charts and scripts for the platform ([#2](https://github.com/littlemex/distai-platform/issues/2)) |
| `docs/workshop/` | Hands-on workshop, English and Japanese (planned, [#3](https://github.com/littlemex/distai-platform/issues/3)) |
| `docs/deep-dives/` | Explainer pages with figures and demos, English and Japanese (planned, [#4](https://github.com/littlemex/distai-platform/issues/4)) |

The full layout is defined in [AGENTS.md](./AGENTS.md#3-repository-layout--where-things-go).

## Getting started

Start with `infra/eks/README.md` for the platform itself. The workshop will live in `docs/workshop/`.

## Contributing

Every change starts from an issue and lands through a pull request. See [CONTRIBUTING.md](./CONTRIBUTING.md) and, for AI-assisted work, [AGENTS.md](./AGENTS.md).

## Security

See [SECURITY.md](./SECURITY.md) for how to report a vulnerability.

## License

This project is licensed under the Apache-2.0 License. See [LICENSE](./LICENSE).
