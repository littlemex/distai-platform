# Throwaway: miles-on-Trainium investigation scratch

Not part of distai-platform. Not delivered through gitops/Argo CD. Exists only
so the EC2 runner's fresh clone of this branch (`exp/miles-trainium`) can
`kubectl apply` it against a real trn2.3xlarge node, as part of a one-off
investigation into how much effort it would take to add a Trainium backend to
`miles` (radixark/miles, the GRPO post-training framework already referenced
in `awslabs/awsome-distributed-ai`'s `examples/training/miles`).

This branch is never merged. `gitops/cells/dp-miles-trn-r1/` is the one real
gitops addition: a cell parameter pair (capacity-pool + smoke queue) copied
from `gitops/cells/dp-a19-trn-r3/`, needed so Argo CD stands up a Trainium
NodePool with the platform's own `accel-neuron-device-plugin` method label
when this cell is bootstrapped with `--revision exp/miles-trainium`.

`train_grpo_smoke.py` / `job.yaml` are a hand-rolled GRPO-style smoke test
(not miles, not TRL's GRPOTrainer) chosen deliberately over trying to port
miles itself or install TRL's in-progress native-Neuron GRPOTrainer (see the
investigation report) for one real-machine attempt within a 4-attempt,
4-Trainium-instance-hour budget.
