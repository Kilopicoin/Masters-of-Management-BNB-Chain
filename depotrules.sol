// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
/// Shared space, not a separate allowance for each product. Deployed equipment is consumed.
library DepotRules {
 uint256 internal constant ARSENAL_BASE=200;
 uint256 internal constant ARSENAL_PER_BUILDING=1000;
 uint256 internal constant LOGISTICS_BASE=20;
 uint256 internal constant LOGISTICS_PER_BUILDING=100;
 uint256 internal constant CART_SPACE=4;
 function weight(uint8 kind) internal pure returns(uint256){
  if(kind==11)return 1;if(kind==12)return CART_SPACE;
  if(kind>=101&&kind<=110)return 1;
  if(kind==111||kind==113)return 2;
  if(kind==112)return 1;
  if(kind==114||kind==115)return 3;
  return 0;
 }
}
