// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import "unitresearch.sol";
/// Immutable, stateless research calculations shared by the fixed Land module.
contract ResearchMath {
 function cost(uint8 id) external pure returns(uint256[4] memory){return UnitResearch.cost(id);}
 function migrate(uint8[17] calldata old) external pure returns(uint8[21] memory){return UnitResearch.migrate(old);}
}
