"""Toy PyTorch DDP training loop with S3 checkpoint and resume.

Started by torchrun, one process per GPU. Every rank trains the same small
model on random data (the numbers are meaningless; the point is that the
collective, the checkpoint and the resume all happen for real). Every
CHECKPOINT_EVERY steps, rank 0 writes the model and optimizer state to
s3://CHECKPOINT_BUCKET/CHECKPOINT_PREFIX/step-<n>.pt. On start, every rank
lists that prefix and loads the highest-numbered checkpoint, so a restarted
JobSet continues from the last checkpoint instead of step 0.

Environment (set by the chart's JobSet template):
  CHECKPOINT_BUCKET, CHECKPOINT_PREFIX, AWS_REGION  where checkpoints live
  TOTAL_STEPS          steps to train in total, across restarts
  CHECKPOINT_EVERY     write a checkpoint every this many steps
  STEP_SLEEP_SECONDS   pause after each step, so a run lasts long enough
                       to interrupt by hand
  LOCAL_RANK, RANK, WORLD_SIZE  set by torchrun

Log lines starting with "[resume]", "[checkpoint]" and "[done]" are stable
and meant to be grepped by a test.
"""
import io
import os
import re
import sys
import time

import boto3
import torch
import torch.distributed as dist
import torch.nn as nn
from torch.nn.parallel import DistributedDataParallel as DDP

STEP_KEY = re.compile(r"/step-(\d+)\.pt$")
FEATURES = 1024


def log(rank, msg):
    if rank == 0:
        print(msg, flush=True)


def required_env(name):
    value = os.environ.get(name, "")
    if not value:
        print(f"{name} is not set", file=sys.stderr, flush=True)
        sys.exit(1)
    return value


def latest_checkpoint(s3, bucket, prefix):
    """(step, key) of the highest-numbered step-<n>.pt directly under
    prefix, or (0, None) if there is none."""
    best_step, best_key = 0, None
    pages = s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix=prefix + "/")
    for page in pages:
        for obj in page.get("Contents", []):
            key = obj["Key"]
            match = STEP_KEY.search(key)
            # Only keys directly under the prefix: a nested "prefix/x/step-9.pt"
            # belongs to some other run.
            if match and key == f"{prefix}/step-{match.group(1)}.pt":
                step = int(match.group(1))
                if step > best_step:
                    best_step, best_key = step, key
    return best_step, best_key


def main():
    bucket = required_env("CHECKPOINT_BUCKET")
    prefix = required_env("CHECKPOINT_PREFIX").strip("/")
    region = required_env("AWS_REGION")
    total_steps = int(required_env("TOTAL_STEPS"))
    every = int(required_env("CHECKPOINT_EVERY"))
    step_sleep = float(os.environ.get("STEP_SLEEP_SECONDS", "0"))

    dist.init_process_group(backend="nccl")
    rank = dist.get_rank()
    world = dist.get_world_size()
    local_rank = int(os.environ["LOCAL_RANK"])
    torch.cuda.set_device(local_rank)
    device = torch.device("cuda", local_rank)
    log(rank, f"[init] world_size={world} backend={dist.get_backend()} torch={torch.__version__}")

    torch.manual_seed(0)
    model = nn.Sequential(nn.Linear(FEATURES, FEATURES), nn.ReLU(), nn.Linear(FEATURES, 1)).to(device)
    optimizer = torch.optim.SGD(model.parameters(), lr=1e-3)

    s3 = boto3.client("s3", region_name=region)
    uri = f"s3://{bucket}/{prefix}"
    start_step, key = latest_checkpoint(s3, bucket, prefix)
    if key is None:
        log(rank, f"[resume] no checkpoint under {uri}/, starting from step 0")
    else:
        body = s3.get_object(Bucket=bucket, Key=key)["Body"].read()
        state = torch.load(io.BytesIO(body), map_location=device, weights_only=True)
        model.load_state_dict(state["model"])
        optimizer.load_state_dict(state["optimizer"])
        start_step = int(state["step"])
        log(rank, f"[resume] loaded s3://{bucket}/{key}, resuming from step {start_step}")
    # Every rank lists the same S3 prefix and loads independently -- there
    # is no broadcast of rank 0's own start_step to the others, a known
    # simplification for this toy example (a real training script would
    # broadcast it, not re-derive it per rank). The barrier below only
    # synchronizes timing (every rank waits for every other rank to reach
    # it); it does not compare each rank's own start_step value, so a race
    # that gave two ranks two different answers (for example an S3 listing
    # that caught a late write from a previous attempt mid-upload) would
    # pass this barrier silently, not hang on it.
    dist.barrier()

    if start_step >= total_steps:
        log(rank, f"[done] already at step {start_step} of {total_steps}, nothing to do")
        dist.destroy_process_group()
        return

    ddp = DDP(model, device_ids=[local_rank])
    loss_fn = nn.MSELoss()
    for step in range(start_step + 1, total_steps + 1):
        generator = torch.Generator(device=device).manual_seed(step * world + rank)
        x = torch.randn(64, FEATURES, device=device, generator=generator)
        y = x.sum(dim=1, keepdim=True) * 0.01
        optimizer.zero_grad(set_to_none=True)
        loss = loss_fn(ddp(x), y)
        loss.backward()
        optimizer.step()
        log(rank, f"[train] step {step}/{total_steps} loss {loss.item():.6f}")

        if step % every == 0 or step == total_steps:
            if rank == 0:
                buf = io.BytesIO()
                torch.save({"step": step, "model": model.state_dict(), "optimizer": optimizer.state_dict()}, buf)
                key = f"{prefix}/step-{step}.pt"
                s3.put_object(Bucket=bucket, Key=key, Body=buf.getvalue())
                log(rank, f"[checkpoint] wrote s3://{bucket}/{key}")
            dist.barrier()

        if step_sleep > 0:
            time.sleep(step_sleep)

    log(rank, f"[done] trained to step {total_steps}")
    dist.destroy_process_group()


if __name__ == "__main__":
    main()
