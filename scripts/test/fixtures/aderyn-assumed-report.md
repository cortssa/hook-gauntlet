# Aderyn Analysis Report

This fixture is NOT a real Aderyn report: no Aderyn was on the machines scripts/static-triage.sh was written on. It is the
shape that script assumes (an Issue Summary table, then one `## H-<n>:` / `## L-<n>:` heading per issue), written by
hand so the selftest can run a fake `aderyn` that prints it. A real report of another shape is said "not read".

## Summary

### Files Summary

| Key | Value |
| --- | --- |
| .sol Files | 1 |
| Total nSLOC | 42 |

### Issue Summary

| Category | No. of Issues |
| --- | --- |
| High | 1 |
| Low | 2 |


# High Issues

## H-1: Arbitrary `from` passed to `transferFrom`

- Found in src/T.sol [Line: 12](src/T.sol#L12)

# Low Issues

## L-1: Centralization Risk for trusted owners

- Found in src/T.sol [Line: 5](src/T.sol#L5)

## L-2: Solidity pragma should be specific, not wide

- Found in src/T.sol [Line: 2](src/T.sol#L2)
