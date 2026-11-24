// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
/// Generated from docs/military-catalog.json; stable IDs, bounded quantities.
library MilitaryCatalog {
 // baseUnit is reserved for ABI compatibility; conversion is retired and always zero.
 struct Unit {uint16 attack;uint16 defense;uint16 resilience;uint16 speed;uint16 capacity; // Reserved zero; retained for existing ABI/report decoding.
uint8 level;uint8 baseUnit;uint8 flags;uint8 counter;uint16 bonus;uint8[5] recipe;}
 function unit(uint8 id) internal pure returns(Unit memory u){
 if(id==1)return Unit(240,100,110,110,0,1,0,1,16,2500,[uint8(1),0,0,0,0]);
 if(id==2)return Unit(240,260,260,100,0,5,0,20,3,2500,[uint8(2),11,13,0,0]);
 if(id==3)return Unit(150,210,190,100,0,1,0,146,64,3500,[uint8(3),11,12,0,0]);
 if(id==4)return Unit(160,230,190,85,0,8,0,130,64,3500,[uint8(4),12,0,0,0]);
 if(id==5)return Unit(290,240,240,85,0,20,0,132,72,3500,[uint8(5),13,0,0,0]);
 if(id==6)return Unit(220,130,130,100,0,1,0,34,1,2500,[uint8(6),12,0,0,0]);
 if(id==7)return Unit(270,150,130,90,0,10,0,34,3,2500,[uint8(7),12,0,0,0]);
 if(id==8)return Unit(270,150,160,85,0,12,0,34,12,3000,[uint8(8),12,0,0,0]);
 if(id==9)return Unit(190,170,170,115,0,6,0,50,64,3500,[uint8(9),11,12,0,0]);
 if(id==10)return Unit(280,230,250,95,0,12,0,20,12,3000,[uint8(10),11,13,0,0]);
 if(id==11)return Unit(210,360,340,75,0,22,0,24,32,2500,[uint8(2),11,14,0,0]);
 if(id==12)return Unit(350,80,90,105,0,18,0,1,16,2500,[uint8(1),1,0,0,0]);
 if(id==13)return Unit(310,130,140,200,0,6,0,65,32,2500,[uint8(1),0,0,0,0]);
 if(id==14)return Unit(310,300,290,180,0,10,0,84,3,2500,[uint8(2),11,13,0,0]);
 if(id==15)return Unit(300,190,190,210,0,10,0,82,32,2500,[uint8(4),11,12,0,0]);
 if(id==16)return Unit(390,350,350,150,0,25,0,88,3,2500,[uint8(4),2,11,14,0]);
 if(id==17)return Unit(260,160,160,210,0,14,0,98,128,2500,[uint8(6),12,0,0,0]);
 if(id==18)return Unit(250,200,190,220,0,14,0,114,72,3500,[uint8(9),11,12,0,0]);
 if(id==19)return Unit(340,280,270,170,0,18,0,84,12,3000,[uint8(10),11,13,0,0]);
 if(id==20)return Unit(380,400,400,130,0,32,0,72,3,2500,[uint8(4),14,15,0,0]);
 revert("Unknown unit");
 }
 function gearCost(uint8 id) internal pure returns(uint256[4] memory){
 if(id==1)return [uint256(60),120,15,150];
 if(id==2)return [uint256(80),60,20,220];
 if(id==3)return [uint256(45),160,10,90];
 if(id==4)return [uint256(70),240,20,140];
 if(id==5)return [uint256(100),180,30,300];
 if(id==6)return [uint256(50),230,10,45];
 if(id==7)return [uint256(90),380,20,70];
 if(id==8)return [uint256(120),280,40,260];
 if(id==9)return [uint256(60),180,15,100];
 if(id==10)return [uint256(80),80,40,240];
 if(id==11)return [uint256(70),220,30,110];
 if(id==12)return [uint256(120),60,20,40];
 if(id==13)return [uint256(120),90,50,300];
 if(id==14)return [uint256(200),120,80,620];
 if(id==15)return [uint256(280),140,100,820];
 revert("Unknown equipment");
 }
}
