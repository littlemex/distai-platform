#!/usr/bin/env python3
"""Minimal, self-contained proof that generate -> reward -> train -> weight-update
runs one full cycle on a single Trainium2 NeuronCore, with a small model.

This is NOT miles, NOT SGLang-Neuron, NOT NxD Training. It is a from-scratch
GRPO-style (group-relative REINFORCE) loop written against plain
transformers + torch-neuronx (PyTorch/XLA), the smallest thing that can
honestly answer "do generation, reward, a training step and a weight update
all work on one trn2.3xlarge, for a 0.5B model". Every shape is fixed
(prompt + generation both padded to SEQ_LEN) so the whole run compiles at
most two XLA graphs (one no_grad forward for sampling, one grad forward for
the loss) instead of one graph per decode step.

Prints machine-readable lines prefixed "RESULT " for the caller to grep.
"""

import json
import os
import sys
import time

import torch
import torch.nn.functional as F

MODEL_NAME = os.environ.get("RL_PROBE_MODEL", "Qwen/Qwen2.5-0.5B-Instruct")
SEQ_LEN = int(os.environ.get("RL_PROBE_SEQ_LEN", "48"))
PROMPT_LEN = int(os.environ.get("RL_PROBE_PROMPT_LEN", "32"))  # generation budget = SEQ_LEN - PROMPT_LEN
SAMPLES_PER_PROMPT = int(os.environ.get("RL_PROBE_SAMPLES", "4"))
NUM_STEPS = int(os.environ.get("RL_PROBE_STEPS", "2"))
LR = float(os.environ.get("RL_PROBE_LR", "1e-5"))
TEMPERATURE = float(os.environ.get("RL_PROBE_TEMPERATURE", "0.8"))
SEED = int(os.environ.get("RL_PROBE_SEED", "0"))

GEN_LEN = SEQ_LEN - PROMPT_LEN
assert GEN_LEN > 0, "SEQ_LEN must exceed PROMPT_LEN"

# Four tiny, deterministically-gradable arithmetic prompts. Reward is 1.0 if the
# correct number appears anywhere in the generated text, else 0.0 -- no judge,
# no dataset download, no external service.
PROBLEMS = [
    ("What is 12 + 7? Reply with only the number.", "19"),
    ("What is 9 + 6? Reply with only the number.", "15"),
    ("What is 20 - 8? Reply with only the number.", "12"),
    ("What is 5 + 5? Reply with only the number.", "10"),
]


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def main() -> int:
    t0 = time.time()
    torch.manual_seed(SEED)

    log(f"importing torch_xla / torch_neuronx (model={MODEL_NAME}, seq_len={SEQ_LEN}, prompt_len={PROMPT_LEN})")
    import torch_xla.core.xla_model as xm  # noqa: E402  (import after seeding, matches the Neuron recipe)
    import torch_neuronx  # noqa: E402,F401  registers the neuron backend with torch_xla

    device = xm.xla_device()
    log(f"xla device resolved: {device}")

    from transformers import AutoModelForCausalLM, AutoTokenizer

    tok = AutoTokenizer.from_pretrained(MODEL_NAME)
    if tok.pad_token_id is None:
        tok.pad_token = tok.eos_token
    model = AutoModelForCausalLM.from_pretrained(MODEL_NAME, torch_dtype=torch.float32)
    model.to(device)
    model.train()
    optimizer = torch.optim.AdamW(model.parameters(), lr=LR)

    # A parameter to fingerprint before/after the optimizer step, to prove the
    # weight update really happened (not just that loss.backward() ran).
    probe_param_name, probe_param = next(iter(model.named_parameters()))
    before_fingerprint = probe_param.detach().to("cpu").flatten()[:8].clone()
    log(f"weight-update probe tensor: {probe_param_name}, first 8 values before = {before_fingerprint.tolist()}")

    results = []
    for step in range(NUM_STEPS):
        step_t0 = time.time()

        # ---- build the fixed-shape, left-aligned, padded batch ----
        prompt_ids_batch = []
        group_id_batch = []
        rewards_target = []
        for g, (question, answer) in enumerate(PROBLEMS):
            enc = tok(question, return_tensors="pt")["input_ids"][0]
            enc = enc[-PROMPT_LEN:]  # truncate from the left if too long
            pad_needed = PROMPT_LEN - enc.shape[0]
            if pad_needed > 0:
                enc = torch.cat([torch.full((pad_needed,), tok.pad_token_id, dtype=enc.dtype), enc])
            for _ in range(SAMPLES_PER_PROMPT):
                prompt_ids_batch.append(enc)
                group_id_batch.append(g)
                rewards_target.append(answer)

        batch = len(prompt_ids_batch)
        input_ids = torch.full((batch, SEQ_LEN), tok.pad_token_id, dtype=torch.long)
        attn_mask = torch.zeros((batch, SEQ_LEN), dtype=torch.long)
        for i, p in enumerate(prompt_ids_batch):
            input_ids[i, :PROMPT_LEN] = p
            attn_mask[i, :PROMPT_LEN] = (p != tok.pad_token_id).long()
        input_ids = input_ids.to(device)
        attn_mask = attn_mask.to(device)

        # ---- generation: fixed total shape every decode step, so only one
        # graph is compiled regardless of how many tokens have been filled in ----
        gen_t0 = time.time()
        with torch.no_grad():
            for pos in range(PROMPT_LEN, SEQ_LEN):
                # Left-padded prompts need explicit position_ids: the default
                # arange(seq_len) would give every pad token a real position and
                # shift the prompt's RoPE positions, which is wrong whenever two
                # rows in the batch pad by a different amount.
                position_ids = (attn_mask.cumsum(dim=-1) - 1).clamp(min=0)
                out = model(input_ids=input_ids, attention_mask=attn_mask, position_ids=position_ids)
                logits = out.logits[:, pos - 1, :]
                probs = F.softmax(logits / TEMPERATURE, dim=-1)
                next_tok = torch.multinomial(probs, num_samples=1).squeeze(-1)
                input_ids[:, pos] = next_tok
                attn_mask[:, pos] = 1
                xm.mark_step()
        gen_seconds = time.time() - gen_t0

        gen_text = tok.batch_decode(input_ids[:, PROMPT_LEN:].to("cpu"), skip_special_tokens=True)

        # ---- reward: exact-match on the arithmetic answer ----
        rewards = torch.tensor(
            [1.0 if ans in txt else 0.0 for txt, ans in zip(gen_text, rewards_target)],
            dtype=torch.float32,
        )
        group_ids = torch.tensor(group_id_batch)
        advantages = torch.zeros_like(rewards)
        for g in set(group_id_batch):
            mask = group_ids == g
            advantages[mask] = rewards[mask] - rewards[mask].mean()
        advantages = advantages.to(device)

        # ---- GRPO-style loss: -mean(advantage * sum(logprob(generated tokens))) ----
        train_t0 = time.time()
        optimizer.zero_grad()
        position_ids = (attn_mask.cumsum(dim=-1) - 1).clamp(min=0)
        out = model(input_ids=input_ids, attention_mask=attn_mask, position_ids=position_ids)
        logits = out.logits[:, PROMPT_LEN - 1 : SEQ_LEN - 1, :]
        logprobs = F.log_softmax(logits, dim=-1)
        gen_tokens = input_ids[:, PROMPT_LEN:SEQ_LEN]
        token_logprobs = torch.gather(logprobs, 2, gen_tokens.unsqueeze(-1)).squeeze(-1)
        gen_mask = attn_mask[:, PROMPT_LEN:SEQ_LEN].float()
        seq_logprob = (token_logprobs * gen_mask).sum(dim=-1)
        loss = -(advantages.detach() * seq_logprob).mean()
        loss.backward()
        xm.optimizer_step(optimizer)  # optimizer.step() + xm.mark_step(), the Neuron/XLA recipe
        train_seconds = time.time() - train_t0

        step_result = {
            "step": step,
            "reward_mean": float(rewards.mean()),
            "reward_values": [float(r) for r in rewards],
            "loss": float(loss.detach().to("cpu")),
            "gen_seconds": gen_seconds,
            "train_seconds": train_seconds,
            "step_seconds": time.time() - step_t0,
            "sample_texts": gen_text[:2],
        }
        results.append(step_result)
        log(f"RESULT step={step} reward_mean={step_result['reward_mean']:.3f} "
            f"loss={step_result['loss']:.6f} gen_s={gen_seconds:.1f} train_s={train_seconds:.1f}")

    after_fingerprint = probe_param.detach().to("cpu").flatten()[:8].clone()
    log(f"weight-update probe tensor: {probe_param_name}, first 8 values after  = {after_fingerprint.tolist()}")
    changed = not torch.allclose(before_fingerprint, after_fingerprint)
    log(f"RESULT weight_changed={changed}")

    all_finite = all(
        torch.isfinite(torch.tensor(r["loss"])) and torch.isfinite(torch.tensor(r["reward_mean"]))
        for r in results
    )
    log(f"RESULT all_finite={all_finite}")
    log(f"RESULT total_seconds={time.time() - t0:.1f}")

    summary = {
        "model": MODEL_NAME,
        "seq_len": SEQ_LEN,
        "prompt_len": PROMPT_LEN,
        "samples_per_prompt": SAMPLES_PER_PROMPT,
        "num_steps": NUM_STEPS,
        "weight_changed": changed,
        "all_finite": bool(all_finite),
        "steps": results,
        "probe_param_name": probe_param_name,
        "total_seconds": time.time() - t0,
    }
    out_path = os.environ.get("RL_PROBE_OUT", "/tmp/rl_probe_result.json")
    with open(out_path, "w") as f:
        json.dump(summary, f, indent=2)
    log(f"RESULT wrote {out_path}")

    ok = changed and all_finite and all(r["reward_mean"] >= 0.0 for r in results)
    log(f"RESULT overall_pass={ok}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
