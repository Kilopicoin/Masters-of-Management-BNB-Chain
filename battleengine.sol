// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import "militarycatalog.sol";
import "scoutsnapshot.sol";
import "fortificationrules.sol";
contract BattleEngine {
 // Lossless archive encoding: preserve every uint256, compress only its leading zero bytes.
 function packReport(bytes calldata raw) external pure returns(bytes memory data){
  require(raw.length==3200,"Invalid report");data=new bytes(3300);
  // Exactly 100 words, each at most 33 encoded bytes. Preserve the existing
  // byte format while avoiding per-byte bounds checks and repeated copies.
  assembly("memory-safe"){
   let start:=add(data,32)let dst:=start
   for{let offset:=0}lt(offset,3200){offset:=add(offset,32)}{
    let value:=calldataload(add(raw.offset,offset))let size:=0
    for{let v:=value}v{v:=shr(8,v)}{size:=add(size,1)}
    mstore8(dst,size)dst:=add(dst,1)
    if size{mstore(dst,shl(mul(sub(32,size),8),value))dst:=add(dst,size)}
   }
   mstore(data,sub(dst,start))
  }
 }
 function unpackReport(bytes memory data) external pure returns(bytes memory raw){
  raw=new bytes(3200);uint256 n;for(uint256 i;i<100;i++){uint256 value;(value,n)=ScoutSnapshot.read(data,n);assembly("memory-safe"){mstore(add(add(raw,32),mul(i,32)),value)}}require(n==data.length,"Invalid report");
 }
 struct Modifiers {uint256 attackBps;uint256 defenseBps;uint256 towers;uint8[21] attackResearch;uint8[21] defenseResearch;}
 struct Cohort {uint256[24] army;uint8[21] levels;}
 struct Outcome {uint256 attackPower;uint256 defensePower;uint256[24] attackLoss;uint256[24] defenseLoss;uint256 capacity;}
 function stats(uint8 id) public pure returns(MilitaryCatalog.Unit memory u){
  if(id>=4)return MilitaryCatalog.unit(id-3);u.attack=id%2==0?200:100;u.defense=id%2==0?100:200;u.resilience=200;u.speed=id<2?100:200;u.flags=id<2?4:68;
 }
 function researchedStats(uint8 id,uint8[21] memory levels) public pure returns(MilitaryCatalog.Unit memory u){
  u=stats(id);if(id<4)return u;uint256 level=levels[id-4];require(level<=20,"Invalid upgrade level");uint256 boost=10000+500*level;
  u.attack=uint16(uint256(u.attack)*boost/10000);u.defense=uint16(uint256(u.defense)*boost/10000);
  u.resilience=uint16(uint256(u.resilience)*boost/10000);u.speed=uint16(uint256(u.speed)*(10000+200*level)/10000);
 }
 function count(uint256[24] memory a) public pure returns(uint256 n){assembly("memory-safe"){for{let o:=0}lt(o,768){o:=add(o,32)}{let sum:=add(n,mload(add(a,o)))if lt(sum,n){mstore(0,0x4e487b71)mstore(32,0x11)revert(28,36)}n:=sum}}}
 // Combat fields occupy 16 bits each: attack, defense, resilience, pace,
 // reserved zero, flags, counter and bonus. Generated from militarycatalog.sol.
 function _base() private pure returns(uint256[24] memory u){u=[uint256(0x40000006400c8006400c8),uint256(0x40000006400c800c80064),uint256(0x44000000c800c8006400c8),uint256(0x44000000c800c800c80064),uint256(0x9c4001000010000006e006e006400f0),uint256(0x9c400030014000000640104010400f0),uint256(0xdac004000920000006400be00d20096),uint256(0xdac004000820000005500be00e600a0),uint256(0xdac004800840000005500f000f00122),uint256(0x9c400010022000000640082008200dc),uint256(0x9c4000300220000005a00820096010e),uint256(0xbb8000c00220000005500a00096010e),uint256(0xdac004000320000007300aa00aa00be),uint256(0xbb8000c00140000005f00fa00e60118),uint256(0x9c4002000180000004b0154016800d2),uint256(0x9c40010000100000069005a0050015e),uint256(0x9c400200041000000c8008c00820136),uint256(0x9c400030054000000b40122012c0136),uint256(0x9c400200052000000d200be00be012c),uint256(0x9c40003005800000096015e015e0186),uint256(0x9c400800062000000d200a000a00104),uint256(0xdac00480072000000dc00be00c800fa),uint256(0xbb8000c0054000000aa010e01180154),uint256(0x9c4000300480000008201900190017c)];}
 function _field(uint256 u,uint256 i) private pure returns(uint256){return(u>>(16*i))&65535;}
 function _mask(uint256[24] memory army) private pure returns(uint256 mask){assembly("memory-safe"){for{let i:=0}lt(i,24){i:=add(i,1)}{if mload(add(army,mul(i,32))){mask:=or(mask,shl(i,1))}}}}
 // Fixed memory arrays store one word per entry. Hash the 20 troop levels (excluding carts) and active types. Each uncached stat set validates levels in _upgraded.
 function _key(uint8[21] memory levels,uint256 mask) private pure returns(uint256 k){assembly("memory-safe"){mstore(0,keccak256(levels,640))mstore(32,mask)k:=keccak256(0,64)}}
 function _upgraded(uint256[24] memory base,uint8[21] memory levels,uint256 mask) private pure returns(uint256[24] memory u){
  // Fixed arrays have 24/21 words. Only catalog fields and levels <=20 enter
  // multiplication (at most 65535 * 20000); preserve all non-stat bits exactly.
  assembly("memory-safe"){
   for{let i:=0}lt(i,24){i:=add(i,1)}{
    if and(mask,shl(i,1)){
     let offset:=mul(i,32)let value:=mload(add(base,offset))let level:=0
     if iszero(lt(i,4)){level:=mload(add(levels,sub(offset,128)))}
     if gt(level,20){let p:=mload(0x40)mstore(p,shl(224,0x08c379a0))mstore(add(p,4),32)mstore(add(p,36),21)mstore(add(p,68),"Invalid upgrade level")revert(p,100)}
     let result:=value
     if level{
      let boost:=add(10000,mul(500,level))
      result:=and(value,not(sub(shl(80,1),1)))
      for{let f:=0}lt(f,4){f:=add(f,1)}{
       let factor:=boost if eq(f,3){factor:=add(10000,mul(200,level))}
       let shift:=mul(f,16)result:=or(result,shl(shift,div(mul(and(shr(shift,value),65535),factor),10000)))
      }
     }
     mstore(add(u,offset),result)
    }
   }
  }
 }
 function _groups(uint256[24] memory d,uint256[24] memory units) private pure returns(uint256[9] memory groups){
  // Fixed-array pointers are bounded by their Solidity types; retain checked uint256 sums.
  assembly("memory-safe"){
   function plus(a,b)->r{r:=add(a,b)if lt(r,a){mstore(0,0x4e487b71)mstore(32,0x11)revert(28,36)}}
   function bump(g,k,n){let p:=add(g,mul(k,32))mstore(p,plus(mload(p),n))}
   for{let o:=0}lt(o,768){o:=add(o,32)}{
    let n:=mload(add(d,o))
    if n{let u:=mload(add(units,o))let f:=and(shr(80,u),65535)
     bump(groups,8,n)
     if and(f,16){bump(groups,0,n)}if and(f,3){bump(groups,1,n)}if and(f,64){bump(groups,2,n)}
     if eq(and(f,72),72){bump(groups,3,n)}if and(f,1){bump(groups,4,n)}if and(f,12){bump(groups,5,n)}
     if and(f,32){bump(groups,6,n)}if iszero(gt(and(shr(48,u),65535),90)){bump(groups,7,n)}
    }
   }
  }
 }
 function _cohortPower(uint256[24] memory a,uint256[9] memory groups,bool defending,uint256[24] memory units) private pure returns(uint256 p){
  assembly("memory-safe"){
   function panic(){mstore(0,0x4e487b71)mstore(32,0x11)revert(28,36)}
   function plus(x,y)->z{z:=add(x,y)if lt(z,x){panic()}}
   function times(x,y)->z{z:=mul(x,y)if and(gt(y,0),iszero(eq(div(z,y),x))){panic()}}
   let total:=mload(add(groups,256))
   for{let o:=0}lt(o,768){o:=add(o,32)}{
    let n:=mload(add(a,o))
    if n{
     let u:=mload(add(units,o))let counter:=and(shr(96,u),65535)let bonus:=0
     if and(gt(total,0),gt(counter,0)){
      let k:=7
      switch counter case 16{k:=0}case 3{k:=1}case 64{k:=2}case 72{k:=3}case 1{k:=4}case 12{k:=5}case 32{k:=6}
      bonus:=div(times(mload(add(groups,mul(k,32))),and(shr(112,u),65535)),total)
     }
     let stat:=and(shr(mul(defending,16),u),65535)
     p:=plus(p,div(times(times(n,stat),plus(10000,bonus)),10000))
    }
   }
  }
 }
 function _power(uint256[24] memory a,uint256[24] memory d,bool defending,uint8[21] memory levels) private pure returns(uint256){uint256[24] memory units=_base();return _cohortPower(a,_groups(d,units),defending,_upgraded(units,levels,_mask(a)));}
 function powerResearchedAgainst(uint256[24] memory a,uint256[24] memory d,bool defending,uint8[21] memory levels,uint8[21] memory enemyLevels) external pure returns(uint256){uint256[24] memory units=_base();return _cohortPower(a,_groups(d,_upgraded(units,enemyLevels,_mask(d))),defending,_upgraded(units,levels,_mask(a)));}
 function _losses(Cohort[] memory cohorts,uint256 percent,uint256 budget,uint256[24][] memory units) private pure returns(uint256[24][] memory result){
  result=new uint256[24][](cohorts.length);
  // Preserve cohort/type iteration and both rounding carries exactly. No aggregation of inventories.
  assembly("memory-safe"){
   function panic(){mstore(0,0x4e487b71)mstore(32,0x11)revert(28,36)}
   function plus(x,y)->z{z:=add(x,y)if lt(z,x){panic()}}
   function times(x,y)->z{z:=mul(x,y)if and(gt(y,0),iszero(eq(div(z,y),x))){panic()}}
   let groupCount:=mload(cohorts)let total:=0 let carry:=0 let numerator:=times(percent,200)
   for{let c:=0}lt(c,groupCount){c:=add(c,1)}{
    let at:=add(32,mul(c,32))
    let army:=mload(mload(add(cohorts,at)))let unitStats:=mload(add(units,at))let lost:=mload(add(result,at))
    for{let o:=0}lt(o,768){o:=add(o,32)}{
     let n:=mload(add(army,o))
     if n{
      let resilience:=and(shr(32,mload(add(unitStats,o))),65535)
      if iszero(resilience){mstore(0,0x4e487b71)mstore(32,0x12)revert(28,36)}
      let rate:=div(numerator,resilience)if gt(rate,90){rate:=90}
      let scaled:=plus(times(n,rate),carry)let loss:=div(scaled,100)
      carry:=mod(scaled,100)if gt(loss,n){loss:=n}
      mstore(add(lost,o),loss)total:=plus(total,loss)
     }
    }
   }
   if gt(total,budget){
    carry:=0
    for{let c:=0}lt(c,groupCount){c:=add(c,1)}{
     let lost:=mload(add(add(result,32),mul(c,32)))
     for{let o:=0}lt(o,768){o:=add(o,32)}{
      let p:=add(lost,o)let loss:=mload(p)
      // A zero loss leaves the carry unchanged (carry is always below total).
      if loss{let scaled:=plus(times(loss,budget),carry)mstore(p,div(scaled,total))carry:=mod(scaled,total)}
     }
    }
   }
  }
 }
 function _cohortUnits(Cohort[] memory cohorts,uint256[24] memory base) private pure returns(uint256[24][] memory units){
  units=new uint256[24][](cohorts.length);uint256[] memory keys=new uint256[](cohorts.length);
  for(uint256 c;c<cohorts.length;){uint256 mask=_mask(cohorts[c].army);uint256 k=_key(cohorts[c].levels,mask);uint256 previous;for(;previous<c;){if(keys[previous]==k)break;unchecked{++previous;}}
   units[c]=previous<c?units[previous]:_upgraded(base,cohorts[c].levels,mask);keys[c]=k;unchecked{++c;}}
 }
 function powerCohorts(Cohort[] memory cohorts,uint256[24] memory enemy,bool defending) public pure returns(uint256 value){
  require(cohorts.length<=33,"Too many defending cohorts");uint256[24] memory base=_base();uint256[24][] memory units=_cohortUnits(cohorts,base);uint256[9] memory groups=_groups(enemy,base);
  for(uint256 c;c<cohorts.length;){value+=_cohortPower(cohorts[c].army,groups,defending,units[c]);unchecked{++c;}}
 }
 function calculateCohorts(uint256[24] memory a,Cohort[] memory defenders,Modifiers memory mods) public pure returns(Outcome memory o,uint256[24][] memory defenderLosses){
  require(defenders.length>0&&defenders.length<=33,"Invalid defending cohorts");uint256 ac=count(a);require(ac>0,"Choose soldiers");uint256[24] memory d;
  uint256[24] memory base=_base();uint256[24] memory attackerUnits=_upgraded(base,mods.attackResearch,_mask(a));uint256[24][] memory defenderUnits=_cohortUnits(defenders,base);uint256 slow;
  for(uint256 c;c<defenders.length;){uint256[24] memory army=defenders[c].army;uint256[24] memory units=defenderUnits[c];for(uint256 i;i<24;){uint256 n=army[i];if(n>0){d[i]+=n;if(_field(units[i],3)<=90)slow+=n;}unchecked{++i;}}unchecked{++c;}}
  uint256[9] memory groups=_groups(a,attackerUnits);uint256[9] memory targets=_groups(d,base);targets[7]=slow;
  o.attackPower=_cohortPower(a,targets,false,attackerUnits)*mods.attackBps/10000;
  for(uint256 c;c<defenders.length;){o.defensePower+=_cohortPower(defenders[c].army,groups,true,defenderUnits[c]);unchecked{++c;}}
  o.defensePower=(o.defensePower+mods.towers*FortificationRules.DEFENSE_PER_TOWER)*mods.defenseBps/10000;
  uint256 dc=count(d)+mods.towers*FortificationRules.OPERATORS_PER_TOWER;bool won=o.attackPower>o.defensePower;
  uint256 margin=(won?o.attackPower-o.defensePower:o.defensePower-o.attackPower)*100/(o.attackPower+o.defensePower);uint256 ab=dc;uint256 db=ac;
  if(o.defensePower<o.attackPower)ab=dc*o.defensePower/o.attackPower;if(o.attackPower<o.defensePower)db=ac*o.attackPower/o.defensePower;
  Cohort[] memory attackers=new Cohort[](1);attackers[0]=Cohort(a,mods.attackResearch);uint256[24][] memory au=new uint256[24][](1);au[0]=attackerUnits;
  o.attackLoss=_losses(attackers,won?10+(100-margin)/4:50+margin,ab,au)[0];
  defenderLosses=_losses(defenders,won?50+margin:10+(100-margin)/4,db,defenderUnits);
  for(uint256 c;c<defenders.length;){uint256[24] memory lost=defenderLosses[c];for(uint256 i;i<24;){o.defenseLoss[i]+=lost[i];unchecked{++i;}}unchecked{++c;}}
 }
 function calculateResearched(uint256[24] memory a,uint256[24] memory d,Modifiers memory mods) public pure returns(Outcome memory o){Cohort[] memory defenders=new Cohort[](1);defenders[0]=Cohort(d,mods.defenseResearch);(o,)=calculateCohorts(a,defenders,mods);}
 function power(uint256[24] memory a,uint256[24] memory d,bool defending) external pure returns(uint256){uint8[21] memory levels;return _power(a,d,defending,levels);}
 function powerResearched(uint256[24] memory a,uint256[24] memory d,bool defending,uint8[21] memory levels) external pure returns(uint256){return _power(a,d,defending,levels);}
 function calculate(uint256[24] memory a,uint256[24] memory d,uint256 ab,uint256 db,uint256 towers) external pure returns(Outcome memory){uint8[21] memory levels;return calculateResearched(a,d,Modifiers(ab,db,towers,levels,levels));}
 function paceResearched(uint256[24] memory a,uint8[21] memory levels) public pure returns(uint256 speed){speed=type(uint256).max;for(uint8 i;i<24;i++)if(a[i]>0){uint256 n=researchedStats(i,levels).speed;if(n<speed)speed=n;}require(speed!=type(uint256).max,"Choose soldiers");}
 function pace(uint256[24] memory a) external pure returns(uint256){uint8[21] memory levels;return paceResearched(a,levels);}
}

