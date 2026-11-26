#!/usr/bin/env python3
"""Minimal GRPO-style post-training smoke test for a single trn2.3xlarge NeuronCore.

Not miles, not TRL: a hand-rolled loop written to answer one narrow question --
does generation -> reward -> policy-gradient loss -> backward -> optimizer.step()
close at least once on real Trainium hardware for a small (0.5-1.5B) causal LM.

Design choices made specifically because this runs on real, budget-limited
Trainium time (see investigation report for the primary source):
  - huggingface/trl issue #7658 (TRL on AWS Trainium) reports GRPOTrainer works
    on trn2 main-branch but each NEW prompt-length bucket costs ~12 minutes to
    recompile. This script therefore uses exactly one fixed sequence shape
    (PROMPT_LEN + GEN_LEN) for every forward call, generation and training
    alike, so torch-neuronx's XLA graph cache only ever has to compile once
    (eval-mode) or twice (eval + train, if dropout/RNG ops differ the graph).
  - Manual, non-cached autoregressive decoding (no model.generate(), no KV
    cache): every decode step re-runs the full fixed-length sequence through
    the model with a causal + padding attention mask and only reads out the
    logits at the current position. This trades FLOPs for shape stability,
    which is the right trade on a device where a shape change is a ~12-minute
    event and correctness of "did the loop close" matters more than speed.
  - attn_implementation="eager" avoids relying on a fused SDPA kernel lowering
    through XLA; eager attention decomposes into matmul/softmax/matmul, which
    is the well-trodden path for training transformers on Trainium.

Reward is a deterministic, free rule (count of alphabetic words in the
completion) -- the number itself is not interesting, only that it varies
across the GROUP_SIZE samples (giving GRPO's group-relative advantage
something to normalize) and that it is read by the training step.
"""
import os
import sys
import time

import torch

try:
    import torch_neuronx  # noqa: F401  (registers the XLA/Neuron backend)
    import torch_xla.core.xla_model as xm
except Exception as exc:  # pragma: no cover - this IS the failure we want to see on real hw
    print(f"[FATAL] could not import torch_neuronx / torch_xla: {exc!r}", flush=True)
    sys.exit(2)

from transformers import AutoModelForCausalLM, AutoTokenizer

MODEL_ID = os.environ.get("MODEL_ID", "Qwen/Qwen2.5-0.5B-Instruct")
STEPS = int(os.environ.get("STEPS", "2"))
GROUP_SIZE = int(os.environ.get("GROUP_SIZE", "4"))
PROMPT_LEN = int(os.environ.get("PROMPT_LEN", "8"))
GEN_LEN = int(os.environ.get("GEN_LEN", "6"))
SEQ_LEN = PROMPT_LEN + GEN_LEN
LR = float(os.environ.get("LR", "1e-5"))
PROMPTS = ["List two colors.", "Name one animal."]


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def reward_fn(text: str) -> float:
    words = [w for w in text.strip().split() if w.isalpha()]
    return float(len(words))


def build_fixed_batch(tok, prompt: str, group: int, device):
    enc = tok(prompt, return_tensors="pt")
    ids = enc["input_ids"][0]
    if ids.shape[0] > PROMPT_LEN:
        ids = ids[-PROMPT_LEN:]
    pad_id = tok.pad_token_id if tok.pad_token_id is not None else tok.eos_token_id
    pad_len = PROMPT_LEN - ids.shape[0]
    padded = torch.cat([torch.full((pad_len,), pad_id, dtype=ids.dtype), ids])
    buf = torch.full((group, SEQ_LEN), pad_id, dtype=torch.long)
    buf[:, :PROMPT_LEN] = padded.unsqueeze(0).expand(group, -1)
    attn = torch.zeros((group, SEQ_LEN), dtype=torch.long)
    attn[:, pad_len:PROMPT_LEN] = 1
    return buf.to(device), attn.to(device)


def main() -> None:
    t0 = time.time()
    device = xm.xla_device()
    log(f"xla device={device} model={MODEL_ID} seq_len={SEQ_LEN} "
        f"(prompt={PROMPT_LEN}+gen={GEN_LEN}) group_size={GROUP_SIZE} steps={STEPS}")

    tok = AutoTokenizer.from_pretrained(MODEL_ID)
    model = AutoModelForCausalLM.from_pretrained(
        MODEL_ID, torch_dtype=torch.float32, attn_implementation="eager"
    )
    model.config.attention_dropout = 0.0
    model.to(device)
    opt = torch.optim.AdamW(model.parameters(), lr=LR)
    log(f"model loaded and moved to device in {time.time() - t0:.1f}s")

    for step in range(STEPS):
        step_rewards, step_losses = [], []
        for prompt in PROMPTS:
            t_step = time.time()
            model.eval()
            ids, attn = build_fixed_batch(tok, prompt, GROUP_SIZE, device)
            with torch.no_grad():
                for pos in range(PROMPT_LEN, SEQ_LEN):
                    out = model(input_ids=ids, attention_mask=attn)
                    logits = out.logits[:, pos - 1, :]
                    probs = torch.softmax(logits, dim=-1)
                    next_tok = torch.multinomial(probs, num_samples=1).squeeze(-1)
                    ids[:, pos] = next_tok
                    attn[:, pos] = 1
                    xm.mark_step()
            gen_ids = ids.to("cpu")
            completions = [
                tok.decode(gen_ids[i, PROMPT_LEN:], skip_special_tokens=True)
                for i in range(GROUP_SIZE)
            ]
            rewards = torch.tensor([reward_fn(c) for c in completions], dtype=torch.float32)
            mean_r = rewards.mean()
            std_r = rewards.std(unbiased=False) + 1e-4
            advantages = ((rewards - mean_r) / std_r).to(device)
            log(f"step={step} prompt={prompt!r} completions={completions} "
                f"rewards={rewards.tolist()} gen_time={time.time() - t_step:.1f}s")

            model.train()
            out = model(input_ids=ids, attention_mask=attn)
            logits = out.logits[:, PROMPT_LEN - 1 : SEQ_LEN - 1, :]
            target = ids[:, PROMPT_LEN:SEQ_LEN]
            logp = torch.log_softmax(logits, dim=-1)
            tok_logp = torch.gather(logp, 2, target.unsqueeze(-1)).squeeze(-1)
            seq_logp = tok_logp.sum(dim=1)
            loss = -(seq_logp * advantages).mean()

            opt.zero_grad()
            loss.backward()
            xm.optimizer_step(opt)
            loss_val = loss.to("cpu").item()

            step_rewards.append(mean_r.item())
            step_losses.append(loss_val)
            log(f"step={step} prompt={prompt!r} loss={loss_val:.4f} "
                f"mean_reward={mean_r.item():.3f} total_time={time.time() - t_step:.1f}s")

        log(
            f"STEP_SUMMARY step={step} "
            f"mean_reward={sum(step_rewards) / len(step_rewards):.4f} "
            f"mean_loss={sum(step_losses) / len(step_losses):.4f}"
        )

    log(f"DONE generation->reward->train->weight-update loop ran {STEPS} step(s) "
        f"in {time.time() - t0:.1f}s total")


if __name__ == "__main__":
    main()
