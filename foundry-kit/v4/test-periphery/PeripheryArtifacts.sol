// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// Compiled on its own so that `PositionManager` has an artifact for `vm.deployCode` (`PeripheryHarness._deployPeriphery`).
// The position manager needs the periphery's own compiler settings (the IR pipeline at 500 runs: `foundry.toml`, profile
// `periphery`), the pool manager ours (IR at 44 444 444 runs), and forge refuses one compilation unit that imports both
// ("Found incompatible settings restrictions"). So no test imports `PositionManager.sol`: they deploy this artifact.
import {PositionManager} from "v4-periphery/src/PositionManager.sol";
