// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
/// Deployment-only wallet privileges. Stored in the map, separately from legacy layout.
// Alpha Version Helpers
library FeeExemptions {
    bytes32 internal constant SLOT = keccak256("mom.fee.exemptions.v1");
    struct Data {mapping(address=>uint8) flags;mapping(address=>uint8) used;}
    function data() internal pure returns(Data storage d){bytes32 slot=SLOT;assembly{d.slot:=slot}}
}
