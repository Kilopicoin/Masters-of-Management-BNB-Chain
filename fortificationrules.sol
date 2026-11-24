// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// Shared defensive fortification rules (a Castle counts as three Towers) for combat, overview and compatibility paths.
library FortificationRules {
    uint256 internal constant DEFENSE_PER_TOWER = 25_000;
    uint256 internal constant OPERATORS_PER_TOWER = 25;
    // Virtual operators bound casualties; they are not soldiers or a guaranteed kill count.
}
