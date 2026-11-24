// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// Append-only namespace: existing ClanWar payment and delegate storage is untouched.
library ClanFinalPool {
    bytes32 private constant SLOT=keccak256("ravengard.clan.final.pool.v1");
    struct Snapshot {address allocation;uint32 claimed;}
    struct Data {mapping(uint64=>Snapshot) clans;}
    function data() internal pure returns(Data storage d){bytes32 slot=SLOT;assembly("memory-safe"){d.slot:=slot}}
}

/// Immutable, STOP-prefixed allocation data. No executable functions or destruction path.
/// Creating compact code avoids thirty separate, expensive claim-credit storage writes.
contract FinalClanAllocation {
    constructor(bytes memory data){assembly("memory-safe"){return(add(data,32),mload(data))}}
}
