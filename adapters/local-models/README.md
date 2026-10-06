# adapters/local-models - the kit run by a small model on your own GPU (measured once)

One run, one model, one harness: **Ternary-Bonsai-2-27B** (the `PQ2_0` GGUF, about 1.7 bits a weight) served by
PrismML's fork of llama.cpp on one 24 GB GPU (WSL), driven by the **Hermes** agent (0.17), walking this kit's route on a
small v4 hook with planted defects (2026-09-29 and 30). It is a measurement, not a supported path: nothing here says a
local model can do the route. What follows is what ran, what was measured, and what the run showed. A second run, the
same harness driving a hosted model, is at the end: what it showed about Hermes, which holds for a local model too.

## The server that ran

```sh
llama-server -m Ternary-Bonsai-2-27B-PQ2_0.gguf -ngl 99 -fa on --jinja --fit off \
  -np 2 --kv-unified -c 393216 -ctk q4_0 -ctv q4_0 --kv-mean-center <bias>.gguf \
  --temp 1.0 --top-p 0.95 --top-k 20 --min-p 0.05 \
  --reasoning-format deepseek --reasoning-budget 16384 -s 42 \
  --ctx-checkpoints 16 --cache-ram 0 --host 127.0.0.1 --port 8080
```

- **PrismML's fork** (branch `prism`), built from source: the `PQ2_0` format is not in upstream llama.cpp.
- **Two slots on one shared KV pool** (`-np 2 --kv-unified`, 393 216 tokens in all, each slot capped at the model's
  262 144): one for the agent, one for a sub-agent or the compressor.
- **KV cache in q4_0 with the mean-centering bias**: the bias file is made by the fork's `llama-kv-mean-center` over a
  sample of the text the model will read (this kit's doctrine and Solidity were used); it needs `-fa on`.
- **`--ctx-checkpoints 16`** keeps a long conversation's prefix reusable; **`--cache-ram 0`**: with a RAM prompt cache
  (4096 MiB) a second turn stalled about 105 s copying an idle slot's 166k-token state to RAM, and the RAM grew 3.6 GB.
- **Sampling and reasoning: PrismML's agent profile** (the four sampling flags, `--reasoning-format deepseek`), with
  `--reasoning-budget 16384`.

## The Hermes configuration that ran

The parts that mattered (`$HERMES_HOME/config.yaml`; a Hermes home of its own, not the user's):

```yaml
model: { provider: custom, base_url: http://127.0.0.1:8080/v1, context_length: 262144, max_tokens: 32768 }
compression: { enabled: true, threshold: 0.8, target_ratio: 0.2, protect_last_n: 20, protect_first_n: 3 }
auxiliary:
  compression:                      # the summary on the LOCAL endpoint only - no "auto" fallback to a hosted provider
    provider: custom
    base_url: http://127.0.0.1:8080/v1
    timeout: 1800                   # the default 120 s timed out: the model thinks before it summarises
    extra_body: { chat_template_kwargs: { enable_thinking: false } }   # no thinking for the summary
memory: { memory_enabled: false, user_profile_enabled: false }
delegation: { max_concurrent_children: 1, max_async_children: 1, max_spawn_depth: 1 }
approvals: { mode: manual, timeout: 900 }
skills: { external_dirs: [<project>/.agents/skills] }   # Hermes 0.17 reads no project directory of its own
```

With Hermes's compression defaults the first run broke: the summary timed out twice on the local model, the "auto"
fallback tried hosted providers (no keys: nothing was sent), and the conversation was then cut without a summary. Install
the skills with `scripts/install-skills.sh --harness hermes` and start with `hermes chat -s hook-gauntlet`: the entry
skill is then in the system prompt, which the compressor keeps. Hermes 0.17's `delegate_task` is always asynchronous: in
`hermes chat -q` the process ends before a child returns; in an interactive session the child's result came back.

## What was measured (the server and the harness, before the route)

- **Memory:** 16.1 GB of VRAM for two conversations of 156k and 166k tokens at once; with `--cache-ram 0` the machine's
  RAM stayed flat.
- **Prefix reuse:** a second turn on a 156k conversation re-read about 30 tokens and answered in 1.3 s; a word planted at
  the start of each long conversation was found in both.
- **Speed:** prompt reading about 1500-1950 tokens/s alone (550 each with two at once); writing 25-51 tokens/s.
- **Tool calls:** 10 of 10 well formed (a direct test against the server); Hermes's terminal, file and sub-agent tools
  worked; the skills were seen only through `skills.external_dirs`.
- **Compression:** 30 messages (about 75k tokens) summarised to about 47k in 22 s, with the configuration above.

## What the route run showed (the first walk, stopped by the operator at 2 h 19 min, mid phase 3)

- **Discipline:** the kit's selftest was run first and passed. Then the state file was never filled (it stayed the
  kit's example); `scripts/next.sh` was run twice on that example, answered a row that made no sense for it, and was not
  used again. The v4 harness was inherited from the first test, but the libraries were copied into the project by hand
  (about 17 minutes; `scripts/setup-deps.sh` exists since). Four reasoning calls hit the 16 384 budget (6.5 min each).
- **Findings:** 2 of the 4 planted defects found, both only REASONED (the one pending test did not compile and, fixed,
  passed on the planted code); the other two were dismissed on misreadings of v4, one of them masked by the harness's
  clock at timestamp 1. 17 of 27 tests failed, all of them bugs of the test bench, not of the hook.
- **The record was invented:** `DECISIONS.md` cited five pending tests and a fork test that never existed, and test
  headers said GREEN over a suite never green.
- **Cost:** 191 model calls, 21.7 M tokens read (98.5 % from the cache), 305k written; the model was 95 % of the
  wall-clock. The same route, same hook, by a frontier model with the same skills: 52 minutes, 4 of 4, a dossier.

## The same harness on a hosted model (one run, 2026-10-01)

One hosted 120B-class model through OpenRouter, 2026-10-01, driven by Hermes 0.17 configured as above (the summary
on the same hosted model), with `context_length: 131072`, `max_tokens: 32768`, compression at `threshold: 0.75`
(`protect_last_n: 20`), reasoning effort medium and `agent.api_max_retries: 8`; the same route on the same kind of hook.
Stopped by the operator at 112 minutes: its test never compiled. What it showed about the harness:

- **Hermes's compression can switch itself off for the rest of a session - a known gap, no remedy measured.** Hermes
  0.17's anti-thrash guard (`context_compressor.py`) compares the REAL prompt tokens before a compression with a rough
  ESTIMATE after it. Both compressions of the run halved the real input (76 699 -> 37 808 and 83 262 -> 40 712 tokens);
  measured against the estimate (86 728 and 108 776) they counted as savings of -13 % and -31 %, "ineffective", and
  after two ineffective compressions Hermes does not compress again in that session (its warning is silenced in quiet
  mode). The input stayed above the threshold - (131 072 - 32 768) x 0.75 = 73 728 tokens - from the 76th call to the
  end, past the configured context (133 215 and 134 875 tokens; the provider accepted them). `protect_last_n` was not
  the cause. What to watch for: a session whose input only grows after its second compression.
- **`agent.api_max_retries: 8` was enough on a paid endpoint:** 6 rate limits (429), 1 idle timeout and 4 dropped
  streams, all recovered.
- **A model that rewrites a file whole fills its context fast.** The one test file was written whole 19 times and never
  patched (about 10 KB of arguments each where the calls were kept, 2.7-5.5k tokens of output each). Prefer a harness
  with an edit or patch tool, and a prompt that says to use it.
- **Cost:** 104 model calls in 112 minutes, about 0.62 USD at about 0.08 USD per million input tokens (the provider's
  usage counter, read before and after the run; not measured again).

## Not measured

A second run of the local model; the route past phase 3; any other local model, quantisation, context size or harness
(the hosted run above is one more, once); a remedy for Hermes's compression guard; whether the changes made to the
kit after these runs change the result.
