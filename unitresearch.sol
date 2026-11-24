// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import "militarycatalog.sol";
library UnitResearch {
 function cost(uint8 id) internal pure returns(uint256[4] memory result){
  require(id>=1&&id<=21,"Unknown military upgrade");if(id==21)return [uint256(100),800,100,300];
  MilitaryCatalog.Unit memory u=MilitaryCatalog.unit(id);result=[uint256(id>=13?400:240),120,90,id>=13?100:60];
  for(uint8 k;k<5;k++)if(u.recipe[k]>0){uint256[4] memory gear=MilitaryCatalog.gearCost(u.recipe[k]);for(uint8 i;i<4;i++)result[i]+=gear[i];}
  if(id>=13){result[0]+=400;result[1]+=120;result[2]+=60;result[3]+=80;}
 }
 // Preserve prior investment: each troop inherits its highest applicable old product level.
 // All troop types then progress independently; traded equipment never carries levels.
 function migrate(uint8[17] memory old) internal pure returns(uint8[21] memory levels){
  for(uint8 i;i<20;i++){MilitaryCatalog.Unit memory u=MilitaryCatalog.unit(i+1);uint8 level=i>=12?old[15]:0;
   for(uint8 k;k<5;k++)if(u.recipe[k]>0&&old[u.recipe[k]-1]>level)level=old[u.recipe[k]-1];levels[i]=level;
  }levels[20]=old[16];
 }
}
