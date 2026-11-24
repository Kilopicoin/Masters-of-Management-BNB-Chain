// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {LootAllocation} from "lootallocation.sol";
contract ClanLossMath {function _percent(uint256 v) private pure returns(uint256){return v>90?90:v;}
    function _limit(uint256[2] memory losses,uint256 enemySize,uint256 enemyPower,uint256 ownPower) private pure returns(uint256[2] memory) {
        uint256 budget=enemySize; if(enemyPower<ownPower) budget=budget*enemyPower/ownPower;
        uint256 sum=losses[0]+losses[1]; if(sum>budget) { losses[0]=losses[0]*budget/sum; losses[1]=budget-losses[0]; }
        return losses;
    }
    function losses(uint256[2] memory sent,uint256[2] memory defending,uint256 ap,uint256 dp,uint256 factor,bool won) external pure returns(uint256[2] memory attackLoss,uint256[2] memory defenseLoss){
        if(won) {
            attackLoss=[sent[0]*_percent(25+(100-factor)/2)/100,sent[1]*_percent(10+(100-factor)/4)/100];
            defenseLoss=[defending[0]*_percent(50+factor)/100,defending[1]*_percent(50+factor)/100];
        } else {
            attackLoss=[sent[0]*_percent(50+factor)/100,sent[1]*_percent(25+factor/2)/100];
            defenseLoss=[defending[0]*_percent(15+(100-factor)/4)/100,defending[1]*_percent(10+(100-factor)/4)/100];
        }
        attackLoss=_limit(attackLoss,defending[0]+defending[1],dp,ap);
        defenseLoss=_limit(defenseLoss,sent[0]+sent[1],ap,dp);
    }

    /// Reuse the combat math module for the legacy four-slot battle path.
    function raidShares(uint256[4] calldata home,uint256[4] calldata target,uint256[8] calldata returned,
        uint256 capacity,uint256 margin,uint256 carry) external pure returns(uint256[4] memory loot,uint256[4] memory fromReturn) {
        uint256 percent = margin < 10 ? 10 : margin > 35 ? 35 : margin;
        uint256[4] memory limits;
        for (uint256 i; i < 4; ++i) {
            uint256 raidable = (target[i] + returned[i]) * percent / 100;
            uint256 free = capacity - home[i];
            limits[i] = raidable < free ? raidable : free;
        }
        loot = LootAllocation.allocate(limits,carry);
        for (uint256 i; i < 4; ++i) {
            uint256 available = target[i] + returned[i];
            if (available != 0) fromReturn[i] = loot[i] * returned[i] / available;
        }
    }
}
