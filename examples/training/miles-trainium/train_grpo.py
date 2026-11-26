#!/usr/bin/env python3
"""GRPO-style post-training smoke test: SGLang-Neuron for rollout, CPU transformers for training.

Not miles, not TRL: a hand-rolled loop whose only job is to answer one question honestly --
does generation -> reward -> policy-gradient loss -> backward -> weight update close at least
once when rollout runs on a real trn2.3xlarge Neuron device through sgl-project/sglang-neuron,
the public-preview SGLang platform plugin for Trainium? See README.md for what is and is not
verified; this script is the evidence those claims are checked against.

Design, and why:
  - Rollout goes through the SAME SGLang-Neuron server a real deployment would use (its OpenAI-
    compatible /v1/completions route), not a direct model.generate() call -- the whole point is
    to exercise the actual rollout engine, not a substitute for it.
  - sglang-neuron's own docs state plainly that its weight-update and LoRA endpoints are refused
    (docs/model-recipes -- "What is refused"); there is no documented live-reload API, unlike
    upstream SGLang's /update_weights_from_disk. The only officially-supported way to pick up new
    weights is to restart the server pointing at a new checkpoint directory -- slow (the public
    third-party measurement cited in README.md put a comparable reload around 455-460 seconds), but it needs no
    patch, so this script uses exactly that, not an unofficial live-reload hack.
  - Training runs as plain CPU transformers (eager, variable-length batches, ordinary HF padding)
    specifically so it does NOT need torch-neuronx's fixed-shape compilation discipline at all:
    sglang-neuron's own tp-size=4 flag for Qwen3-0.6B already claims every NeuronCore the device
    plugin advertises for this node, so a second NeuronCore-bound process has nowhere to run. A 0.6B
    model's forward+backward for a handful of short sequences was expected to be cheap enough on CPU that this
    is a legitimate choice for a correctness smoke test, not a performance shortcut that hides a
    real blocker.

Prints lines prefixed with [HH:MM:SS] for the caller to grep (STEP_SUMMARY, DONE, FATAL).
"""
import os
import shutil
import signal
import subprocess
import sys
import time

import requests
import torch
from transformers import AutoModelForCausalLM, AutoTokenizer

BASE_MODEL_DIR = os.environ.get("BASE_MODEL_DIR", "/models/Qwen3-0.6B")
WORK_DIR = os.environ.get("WORK_DIR", "/models/_steps")
RUN_SERVER_SH = os.environ.get(
    "RUN_SERVER_SH", "/opt/sglang-neuron/examples/qwen3_0p6b/run_server.sh"
)
SERVER_PORT = int(os.environ.get("SERVER_PORT", "30000"))
SERVER_URL = f"http://127.0.0.1:{SERVER_PORT}"
STEPS = int(os.environ.get("STEPS", "2"))
GROUP_SIZE = int(os.environ.get("GROUP_SIZE", "4"))
MAX_NEW_TOKENS = int(os.environ.get("MAX_NEW_TOKENS", "24"))
LR = float(os.environ.get("LR", "1e-5"))
HEALTH_TIMEOUT_S = int(os.environ.get("HEALTH_TIMEOUT_S", "1800"))
PROMPTS = ["List two colors.", "Name one animal."]


def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def reward_fn(text: str) -> float:
    words = [w for w in text.strip().split() if w.isalpha()]
    return float(len(words))


def start_server(model_path: str) -> subprocess.Popen:
    env = os.environ.copy()
    env["MODEL_PATH"] = model_path
    log(f"starting sglang-neuron server: MODEL_PATH={model_path} via {RUN_SERVER_SH}")
    log_file = open("/tmp/sglang-neuron-server.log", "a")
    # --dtype bfloat16, not left at run_server.sh's "auto": sglang-neuron's own check_bf16_launch
    # (sglang_neuron/models/transformer/config.py, commit 4e2432622bfab2c6663d12286a6813ef1a40bfe6)
    # resolves "auto" from the checkpoint's own config.json torch_dtype, which this script's CPU
    # training copy saves as float32 (loaded with torch_dtype=torch.float32 for CPU training
    # stability, not for the inference server's benefit) -- refused with "launch with --dtype
    # bfloat16" on real hardware (README.md "What actually ran", the restart against the first
    # saved checkpoint). The base Qwen3-0.6B checkpoint downloaded from the Hub is already
    # bfloat16, so this was not hit on the first (unrestarted) launch; passing --dtype explicitly
    # makes both launches identical rather than depending on which checkpoint happens to already
    # match. Re-verified on the next real-machine attempt: the restart succeeded.
    proc = subprocess.Popen(
        ["bash", RUN_SERVER_SH, "--dtype", "bfloat16"], env=env, stdout=log_file, stderr=subprocess.STDOUT
    )
    return proc


def stop_server(proc: subprocess.Popen) -> None:
    if proc is None or proc.poll() is not None:
        return
    proc.send_signal(signal.SIGTERM)
    try:
        proc.wait(timeout=90)
    except subprocess.TimeoutExpired:
        log("server did not exit on SIGTERM within 90s, sending SIGKILL")
        proc.kill()
        proc.wait(timeout=30)


def _dump_server_log() -> None:
    # The earliest real-machine attempt that reached this far (see README.md "What actually ran",
    # session 1) lost the server's own reason for failing along with the container -- its log
    # stayed in a file (below) that kubectl logs never sees. Printing it to this script's own
    # stdout on failure means a future `kubectl logs` capture carries it even if the container is
    # gone by the time anyone looks. Confirmed working on the next real attempt that hit this path
    # (session 2): the dumped log carried the server's own ValueError verbatim.
    try:
        with open("/tmp/sglang-neuron-server.log") as f:
            tail = f.readlines()[-200:]
        log("=== /tmp/sglang-neuron-server.log (last 200 lines) ===")
        for line in tail:
            print(line, end="", flush=True)
        log("=== end of server log ===")
    except OSError as exc:
        log(f"could not read /tmp/sglang-neuron-server.log: {exc!r}")


def wait_health(proc: subprocess.Popen, timeout_s: int) -> bool:
    t0 = time.time()
    while time.time() - t0 < timeout_s:
        if proc.poll() is not None:
            log(f"FATAL: server process exited early with code {proc.returncode}")
            _dump_server_log()
            return False
        try:
            r = requests.get(f"{SERVER_URL}/health", timeout=5)
            if r.status_code == 200:
                log(f"server healthy after {time.time() - t0:.0f}s")
                return True
        except requests.exceptions.RequestException:
            pass
        time.sleep(10)
    log(f"FATAL: server did not become healthy within {timeout_s}s")
    _dump_server_log()
    return False


def generate_completions(prompt: str, n: int) -> list[str]:
    """OpenAI-compatible route (stable across SGLang versions), not the native /generate
    schema, which has changed shape between releases -- see README.md "Known limits" if this 404s."""
    resp = requests.post(
        f"{SERVER_URL}/v1/completions",
        json={
            "model": "default",
            "prompt": prompt,
            "max_tokens": MAX_NEW_TOKENS,
            "temperature": 1.0,
            "n": n,
        },
        timeout=180,
    )
    if resp.status_code >= 400:
        # Unverified fix, not yet exercised on real hardware: this check was added in the same
        # commit as the sampler fix it responds to (fd64395), so the real-machine attempt that
        # found the sampler-mode defect (README.md "On the two launch-configuration gaps this
        # found") ran before this check existed and only recovered the cause from
        # `requests.HTTPError`'s own exception message ("400 Client Error: Bad Request"), which
        # carries no response body -- the actual
        # cause (SGLANG_NEURON_SAMPLER defaulting to "greedy") was found by reading sglang-neuron's
        # source after the fact, not from anything this script itself captured that run.
        # sglang-neuron answers an admission refusal with a JSON body naming the setting at fault
        # (general_plugin.py's _validate_request -> HTTPException(detail=...)); logging it here
        # means a future admission refusal of this kind is diagnosed from this script's own
        # stdout directly. No later real-machine attempt has hit a >=400 response to re-verify it.
        log(f"FATAL: {SERVER_URL}/v1/completions returned {resp.status_code}: {resp.text[:2000]}")
    resp.raise_for_status()
    data = resp.json()
    return [c["text"] for c in data["choices"]]


def train_one_step(model, tok, device, prompt: str, completions: list[str], rewards: torch.Tensor):
    mean_r, std_r = rewards.mean(), rewards.std(unbiased=False) + 1e-4
    advantages = (rewards - mean_r) / std_r

    full_texts = [prompt + c for c in completions]
    enc = tok(full_texts, return_tensors="pt", padding=True)
    prompt_len = tok(prompt, return_tensors="pt")["input_ids"].shape[1]

    model.train()
    out = model(**{k: v.to(device) for k, v in enc.items()})
    logits = out.logits[:, prompt_len - 1 : -1, :]
    target = enc["input_ids"][:, prompt_len:].to(device)
    pad_mask = (enc["attention_mask"][:, prompt_len:] == 1).to(device)

    logp = torch.log_softmax(logits, dim=-1)
    tok_logp = torch.gather(logp, 2, target.unsqueeze(-1)).squeeze(-1)
    seq_logp = (tok_logp * pad_mask).sum(dim=1)

    loss = -(seq_logp * advantages.to(device)).mean()
    return loss, mean_r


def main() -> None:
    t0 = time.time()
    os.makedirs(WORK_DIR, exist_ok=True)
    device = torch.device("cpu")

    log(f"loading CPU training copy of {BASE_MODEL_DIR}")
    tok = AutoTokenizer.from_pretrained(BASE_MODEL_DIR)
    if tok.pad_token is None:
        tok.pad_token = tok.eos_token
    tok.padding_side = "right"
    model = AutoModelForCausalLM.from_pretrained(
        BASE_MODEL_DIR, torch_dtype=torch.float32, attn_implementation="eager"
    ).to(device)
    opt = torch.optim.AdamW(model.parameters(), lr=LR)

    current_model_path = BASE_MODEL_DIR
    server = start_server(current_model_path)
    if not wait_health(server, HEALTH_TIMEOUT_S):
        stop_server(server)
        sys.exit(2)

    for step in range(STEPS):
        step_rewards, step_losses = [], []
        for prompt in PROMPTS:
            t_gen = time.time()
            completions = generate_completions(prompt, GROUP_SIZE)
            log(f"step={step} prompt={prompt!r} completions={completions} "
                f"gen_time={time.time() - t_gen:.1f}s")
            rewards = torch.tensor([reward_fn(c) for c in completions], dtype=torch.float32)

            loss, mean_r = train_one_step(model, tok, device, prompt, completions, rewards)
            opt.zero_grad()
            loss.backward()
            opt.step()

            loss_val = loss.item()
            step_rewards.append(mean_r.item())
            step_losses.append(loss_val)
            log(f"step={step} prompt={prompt!r} loss={loss_val:.4f} "
                f"mean_reward={mean_r.item():.3f} rewards={rewards.tolist()}")

        log(
            f"STEP_SUMMARY step={step} "
            f"mean_reward={sum(step_rewards) / len(step_rewards):.4f} "
            f"mean_loss={sum(step_losses) / len(step_losses):.4f}"
        )

        if step < STEPS - 1:
            next_path = os.path.join(WORK_DIR, f"qwen3-0p6b-step{step}")
            log(f"saving updated weights to {next_path} and restarting the server "
                f"(no live-reload API -- see module docstring)")
            model.save_pretrained(next_path, safe_serialization=True)
            tok.save_pretrained(next_path)
            t_restart = time.time()
            stop_server(server)
            server = start_server(next_path)
            if not wait_health(server, HEALTH_TIMEOUT_S):
                stop_server(server)
                sys.exit(2)
            log(f"restart_time={time.time() - t_restart:.1f}s")
            if current_model_path != BASE_MODEL_DIR:
                shutil.rmtree(current_model_path, ignore_errors=True)
            current_model_path = next_path

    stop_server(server)
    log(f"DONE generation->reward->train->weight-update(restart) loop ran {STEPS} step(s) "
        f"in {time.time() - t0:.1f}s total")


if __name__ == "__main__":
    main()
