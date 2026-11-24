// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

library LootAllocation {
    /// @dev Equal shares among available resources, redistributing unused shares.
    /// Four resources bound the work; rounding can favor a type by at most one unit.
    function allocate(uint256[4] memory limits, uint256 capacity) internal pure returns (uint256[4] memory loot) {
        for (uint8 pass; pass < 4 && capacity > 0; ++pass) {
            uint256 count;
            for (uint8 i; i < 4; ++i) if (loot[i] < limits[i]) ++count;
            if (count == 0) break;
            uint256 share = capacity / count;
            if (share == 0) share = 1;
            for (uint8 i; i < 4 && capacity > 0; ++i) {
                uint256 amount = limits[i] - loot[i];
                if (amount > share) amount = share;
                if (amount > capacity) amount = capacity;
                loot[i] += amount;
                capacity -= amount;
            }
        }
    }
}
