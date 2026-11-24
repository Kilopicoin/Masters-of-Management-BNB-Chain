// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import "militarycontract.sol";
library JourneyTypes {struct Journey {
        uint256 id;uint8 kind;uint8 state;
        address sender;int32 sx;int32 sy;int32 tx;int32 ty;
        uint64 sourceClan;uint64 targetClan;
        uint256 targetEpoch;
        uint256 startedAt;uint256 arrivesAt;uint256 returnStartedAt;uint256 returnsAt;
        uint256[8] cargo;uint256[4] army;uint256 carts;
    }}
interface IJourneyViewSource {
 function rawJourney(uint256 id) external view returns(JourneyTypes.Journey memory);
 function homeIds(int32 x,int32 y,uint64 clanId) external view returns(uint256[] memory);
 function activeId(uint256 i) external view returns(uint256);
 function activeCount() external view returns(uint256);
 function nextId() external view returns(uint256);
 function land() external view returns(IJLand);
}
contract JourneyViews {
 uint256 private constant ORDER_WAIT_SECONDS=96 hours;
 function _now() private view returns(uint256){uint256 end=IJourneyViewSource(msg.sender).land().worldEndsAt();return block.timestamp<end?block.timestamp:end;}
 IJMap immutable map;IJClan immutable clans;
 constructor(address m,address c){map=IJMap(m);clans=IJClan(c);}
    function _effective(JourneyTypes.Journey memory j) private view returns(JourneyTypes.Journey memory){
        if(j.state==1&&_now()>=j.arrivesAt+ORDER_WAIT_SECONDS){
            j.state=2;j.returnStartedAt=j.arrivesAt+ORDER_WAIT_SECONDS;
            j.returnsAt=j.returnStartedAt+j.arrivesAt-j.startedAt;
        }
        if(!(j.kind==4||j.kind==5))j.sender=map.getTileOccupant(j.sx,j.sy);
        else {IJClan.Info memory info=clans.getClanInfo(j.sourceClan);j.sender=map.getTileOccupant(info.leaderX,info.leaderY);}
        return j;
    }
    function _home(JourneyTypes.Journey memory j) private view returns(bool){
        return (j.state==2&&_now()>=j.returnsAt)||(j.state==1&&_now()>=j.arrivesAt+ORDER_WAIT_SECONDS+j.arrivesAt-j.startedAt);
    }
    function clanJourneysHome(uint64 id) external view returns(bool){IJourneyViewSource source=IJourneyViewSource(msg.sender);
        uint256[] memory ids=source.homeIds(0,0,id);
        for(uint256 i;i<ids.length;i++)if(!_home(source.rawJourney(ids[i])))return false;
        return true;
    }
    function canTransferRealm(int32 x,int32 y) external view returns(bool){IJourneyViewSource source=IJourneyViewSource(msg.sender);
        uint256[] memory ids=source.homeIds(x,y,0);
        for(uint256 i;i<ids.length;i++)if(!_home(source.rawJourney(ids[i])))return false;
        return true;
    }
    function getRealmSaleStateHash(int32 x,int32 y) external view returns(bytes32 value){IJourneyViewSource source=IJourneyViewSource(msg.sender);
        uint256[] memory ids=source.homeIds(x,y,0);
        for(uint256 i;i<ids.length;i++)value=keccak256(abi.encode(value,source.rawJourney(ids[i]),source.land().military()==address(0)?bytes32(0):keccak256(abi.encode(Military(source.land().military()).journeyArmy(ids[i])))));
    }
    function returnedAssets(int32 x,int32 y,uint64 clanId) external view returns(uint256[8] memory cargo,uint256[4] memory army){IJourneyViewSource source=IJourneyViewSource(msg.sender);
        uint256[] memory ids=clanId==0?source.homeIds(x,y,0):source.homeIds(0,0,clanId);
        for(uint256 n;n<ids.length;n++){JourneyTypes.Journey memory j=source.rawJourney(ids[n]);
            if((clanId==0&&(j.kind==4||j.kind==5))||!_home(j))continue;
            for(uint8 i;i<8;i++)cargo[i]+=j.cargo[i];for(uint8 i;i<4;i++)army[i]+=j.army[i];
        }
    }
    function getJourney(uint256 id) external view returns(JourneyTypes.Journey memory){IJourneyViewSource source=IJourneyViewSource(msg.sender);if(id==0||id>source.nextId())revert UnknownJourney();return _effective(source.rawJourney(id));}
    function getActivePage(uint256 offset,uint256 limit) external view returns(JourneyTypes.Journey[] memory rows,uint256 total,uint256 chainTime){IJourneyViewSource source=IJourneyViewSource(msg.sender);
        if(limit==0||limit>50)revert InvalidPageSize();total=source.activeCount();chainTime=_now();
        uint256 count=offset<total?total-offset:0;if(count>limit)count=limit;rows=new JourneyTypes.Journey[](count);
        for(uint256 i;i<count;i++)rows[i]=_effective(source.rawJourney(source.activeId(offset+i)));
    }
    function returnedArmyIds(int32 x,int32 y,uint64 clanId) external view returns(uint256[] memory ids){
        IJourneyViewSource source=IJourneyViewSource(msg.sender);ids=clanId==0?source.homeIds(x,y,0):source.homeIds(0,0,clanId);uint256 count;
        for(uint256 n;n<ids.length;n++){JourneyTypes.Journey memory j=source.rawJourney(ids[n]);if((clanId==0&&(j.kind==4||j.kind==5))||!_home(j))continue;ids[count++]=j.id;}
        assembly("memory-safe"){mstore(ids,count)}
    }
    function returnedTroops(int32 x,int32 y,uint64 clanId) external view returns(uint256[20] memory army){IJourneyViewSource source=IJourneyViewSource(msg.sender);
        if(source.land().military()==address(0))return army;uint256[] memory ids=clanId==0?source.homeIds(x,y,0):source.homeIds(0,0,clanId);
        for(uint256 n;n<ids.length;n++){JourneyTypes.Journey memory j=source.rawJourney(ids[n]);if((clanId==0&&(j.kind==4||j.kind==5))||!_home(j))continue;uint256[20] memory a=Military(source.land().military()).journeyArmy(j.id);for(uint8 i;i<20;i++)army[i]+=a[i];}
    }
error UnknownJourney();error InvalidPageSize();}
