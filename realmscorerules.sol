// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
/// Permanent training points: ceil(undiscounted training + recipe + horse resources / 10).
/// Production discounts and research never change these fixed weights.
library RealmScoreRules {
 function trainingPoints(uint8 unit) internal pure returns(uint256){
  require(unit>=1&&unit<=20,"Unknown unit");
  uint256 values=unit<=16?0x16f00fb011200ac007800ea00c2009a00910083006d00a8007a009500bc0056:0x1a4011800f000c3;
  return (values>>(16*(unit<=16?unit-1:unit-17)))&0xffff;
 }
}
