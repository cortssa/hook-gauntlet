# fixtures/

This directory holds the runtime bytecode of contracts that already exist on a chain, so the suite can be
run against **them** rather than against a source build of something with the same name.

It is empty in the repository, on purpose. `PoolManager` is BUSL-1.1 and compiled code carries its licence
with it, so nothing fetched here is ever committed: `.gitignore` drops `*.hex` and `*.json`.

Fill it with:

```sh
export RPC_URL='https://<a public, keyless endpoint is fine for eth_getCode>'
../../scripts/fetch-bytecode.sh <manager address> fixtures/PoolManager.hex
```

which writes two files:

| file | what it is |
| --- | --- |
| `PoolManager.hex` | the runtime code, `0x`-prefixed, one line |
| `PoolManager.json` | `{ address, chainId, codeSize, codeHash }` |

Both are needed. The harness etches the code **at the address in the json**, because v4's `NoDelegateCall`
bakes its own address into the code: a manager etched anywhere else refuses every call that reaches it.

Then:

```sh
V4_MANAGER=fixture ../../scripts/battery.sh .
```

Through the script, not a bare `forge test`: the script gives each manager its own fuzz corpus
(`corpus/invariant-fixture`). A corpus recorded against the source manager and replayed against this one produces a
counterexample that is not one - measured, "the hook thinks it is in the future", red four times in four. If you do
call forge yourself, set `FOUNDRY_INVARIANT_CORPUS_DIR=corpus/invariant-fixture` next to `V4_MANAGER=fixture`.

Then read the `V4 MANAGER:` line in the output. If the files are missing, the suite **skips**; it does not
quietly fall back to the source manager.

This file is committed so that the directory exists, and so that `managerPlanFor` has something real to be
tested against: it is a file with no `.json` sibling, which is exactly the half-installed fixture the
harness has to refuse.
