// SPDX-License-Identifier: MIT
import "./PublicRPCEvents.sol";
pragma solidity 0.8.37;
import "JourneyLootEscrow.sol";
import "ClanWarExtensionStorage.sol";
import "ClanHallLevels.sol";
import "ClanText.sol";
import "ClanCouncil.sol";
import {FinalClanAllocation} from "ClanFinalPool.sol";
import {ClanDepartureData} from "ClanDepartureData.sol";
import {LootAllocation} from "lootallocation.sol";
import "militarycontract.sol";
import "clanlossmath.sol";
contract ClanWarExtension is PublicRPCWriter, ClanWarExtensionStorage  {
    ClanLossMath internal immutable lossMath;
    ClanCouncil public immutable councilModule;
    constructor(address mapAddress, address landAddress, address clanAddress) ClanWarExtensionStorage(mapAddress,landAddress,clanAddress) {
        require(mapAddress.code.length>0 && landAddress.code.length>0 && clanAddress.code.length>0, "Invalid contracts");
        lossMath=new ClanLossMath();councilModule=new ClanCouncil(mapAddress,landAddress,clanAddress);
    }

    error NameTooLong();
    function validateClanName(string calldata name) external pure {
        bytes memory b=bytes(name);if(b.length>32)revert NameTooLong();
        bool nonSpace;for(uint256 i;i<b.length;i++)if(b[i]!=0x20)nonSpace=true;
        require(nonSpace,"Name empty");ClanText.validate(b);
        for(uint256 i;i<b.length;i++){uint8 c=uint8(b[i]);require((c>=65&&c<=90)||(c>=97&&c<=122)||(c>=48&&c<=57)||c==32||c==45||c==95,"Use A-Z, 0-9, spaces, - or _");}
    }
    function validateGameText(bytes calldata text) external pure {ClanText.validate(text);}
    function normalizeRealmName(string calldata raw) external pure returns(string memory){ClanText.validate(bytes(raw));return ClanText.normalize(raw);}

    function clanHallLevel(int32 x,int32 y) public view returns(uint8 level){if(!land.hasClanHallAtCoord(x,y))return 0;level=ClanHallLevels.data().level[x][y];return level==0?1:level;}
    function leadershipHallEligible(uint64 id,int32 x,int32 y) external view returns(bool){
        ICWClan.Info memory info=clans.getClanInfo(id);uint8 level=clanHallLevel(x,y);
        return info.exists&&clans.getTileClan(x,y)==id&&level>0&&level>=clanHallLevel(info.leaderX,info.leaderY);
    }
    function clanHallUpgradeState(int32 x,int32 y) external view returns(uint8 level,uint256[4] memory nextCost){level=clanHallLevel(x,y);if(level>0&&level<20)for(uint8 i;i<4;i++)nextCost[i]=30000*(uint256(level)+1);}
    function clanHallArmyLimit(uint64 id) external view returns(uint8){return ClanHallLevels.data().capacity[id];}
    function _syncClanHall(uint64 id,int32 x,int32 y) private {uint8 level=clanHallLevel(x,y);ClanHallLevels.State storage s=ClanHallLevels.data();if(level>s.capacity[id])s.capacity[id]=level;}
    function syncClanHallCapacity(uint64 id)  external {require(msg.sender==address(clans),"Clan only");ICWClan.Info memory info=clans.getClanInfo(id);require(info.exists,"Clan missing");_syncClanHall(id,info.leaderX,info.leaderY);}
    event ClanHallLevelChanged(int32 indexed x,int32 indexed y,uint8 level);
    event ClanMilitaryChanged(uint64 indexed clanId);
    function upgradeClanHall(int32 x,int32 y,uint8 expectedLevel) rpcIndexed external nonReentrant {_upgradeClanHall(msg.sender,x,y,expectedLevel);}
    function upgradeClanHallFromMilitary(address actor,int32 x,int32 y,uint8 expectedLevel) rpcIndexed external nonReentrant {require(msg.sender==IJLand(address(land)).military(),"Military only");_upgradeClanHall(actor,x,y,expectedLevel);}
    function _upgradeClanHall(address actor,int32 x,int32 y,uint8 expectedLevel) private {
        IJLand(address(land)).requireWorldActive();require(map.getTileOccupant(x,y)==actor,"Not realm owner");uint8 level=clanHallLevel(x,y);require(level>0&&level==expectedLevel&&level<20,"Upgrade level changed or maximum reached");
        uint256 cost=30000*(uint256(level)+1);for(uint8 i;i<4;i++)land.adjustTileResources(x,y,i+1,cost,false);ClanHallLevels.data().level[x][y]=level+1;
        uint64 id=clans.getTileClan(x,y);if(id!=0){ICWClan.Info memory info=clans.getClanInfo(id);if(info.leaderX==x&&info.leaderY==y){_syncClanHall(id,x,y);emit ClanMilitaryChanged(id);}}
        emit ClanHallLevelChanged(x,y,level+1);
    }
    function resetClanHallCapacity(int32 x,int32 y)  external {require(msg.sender==address(land),"Land only");delete ClanHallLevels.data().level[x][y];}

    function configurationHash() external view returns(bytes32){return keccak256(abi.encode(address(map),address(land),address(clans)));}



    function _leader(uint64 id) private view {
        ICWClan.Info memory info=clans.getClanInfo(id);
        require(info.exists && map.getTileOccupant(info.leaderX,info.leaderY)==msg.sender, "Only clan leader");
    }
    function getState(uint64 id) internal view returns(State memory result) {result=states[id];result.experience=ClanPower.data().earned[id];result.lastAttackExperience=ClanPower.data().lastAttack[id];}
    function getStateHash(uint64 id) internal view returns(bytes32) {
        address j=IJLand(address(land)).logistics();uint256[8] memory cargo;uint256[4] memory army;
        if(j!=address(0))(cargo,army)=IJLogistics(j).returnedAssets(0,0,id);
        return keccak256(abi.encode(states[id],clanCartStock[id],cargo,army,IJLand(address(land)).military()==address(0)?bytes32(0):Military(IJLand(address(land)).military()).clanHash(id)));
    }
    function cartStock(uint64 id) external view returns(uint256){return clanCartStock[id];}
    function adjustCarts(uint64 id,uint256 amount,bool adding)  external onlyLogistics {revert("Clan stores are retired");}
    function capacity(uint64 id) internal view returns(uint256) { return BASE_CAPACITY+states[id].silos*SILO_CAPACITY; }
    function siloCost(uint64 id) internal view returns(uint256[4] memory cost) {
        uint256 n=states[id].silos+1;
        return [5000*n,20000*n,20000*n,10000*n];
    }
    modifier onlyLogistics() { if(!(msg.sender==IJLand(address(land)).logistics()))revert LogisticsRequired(); _; }
    function resourceRoom(uint64 id) internal view returns(uint256[4] memory room) {
        for(uint8 i;i<4;i++)room[i]=capacity(id)-states[id].resources[i];
    }
    function receiveCargo(uint64 id,uint256[4] calldata supplies,uint256[4] calldata army) internal nonReentrant onlyLogistics {require(clans.getClanInfo(id).exists,"Clan missing");for(uint8 i;i<4;i++)require(supplies[i]==0,"Clan stores are retired");State storage s=states[id];s.offensive+=army[0];s.defensive+=army[1];s.mountedOffensive+=army[2];s.mountedDefensive+=army[3];}
    /// Cargo is removed once into Logistics escrow; only the fixed journey module may debit clan stores.
    error ClanFriendshipRequired();
    function requireFriendship(uint64 a,uint64 d) public view {
        (uint8 relation,,)=relationship(a,d);if(relation!=1)revert ClanFriendshipRequired();
    }
    function departSupplies(uint64 a,uint64 d,uint256[4] calldata amounts,uint256 foodCost)  external nonReentrant onlyLogistics {revert("Clan stores are retired");}
    function _ready(uint64 a,uint64 d,bool checkProtection) private view {
        if(!(a!=d && clans.getClanInfo(a).exists && clans.getClanInfo(d).exists))revert InvalidClanTarget();
        (uint8 ourStance,) = _memberStance(a,d);
        if (ourStance != 2) {
            (uint8 theirStance,) = _memberStance(d,a);
            if (theirStance != 2) revert EnemyClanRequired();
        }
        if (checkProtection && states[d].protectedUntil > block.timestamp) revert ClanProtected();
    }
    function depart(uint64 a,uint64 d,uint256[4] calldata army) internal nonReentrant onlyLogistics {_depart(a,d,army,0);}
    function departTyped(uint64 a,uint64 d,uint256[4] calldata army,uint256 extra) internal nonReentrant onlyLogistics {_depart(a,d,army,extra);}
    function _depart(uint64 a,uint64 d,uint256[4] memory army,uint256 extra) private {
        _ready(a,d,false); State storage s=states[a];uint256 size=extra;
        for(uint8 i;i<4;i++)size+=army[i];if(size<100)revert ClanArmyRequired();
        s.offensive-=army[0];s.defensive-=army[1];s.mountedOffensive-=army[2];s.mountedDefensive-=army[3];
        ICWClan.Info memory leader=clans.getClanInfo(a);for(uint8 i;i<4;i++)land.adjustTileResources(leader.leaderX,leader.leaderY,i+1,size*(4-i),false);
    }
    function buildSilo(uint64 id, uint256 expectedCount) internal nonReentrant {revert("Clan stores are retired");}
    /// @dev Only the sealed Land contract can supply a paid turn contribution.
    function recordTurnFee(int32 x,int32 y,uint16 turns) internal  nonReentrant {
        if(!(msg.sender==address(land)))revert LandRequired();
        uint64 id=clans.getTileClan(x,y); ICWClan.Info memory info=clans.getClanInfo(id);
        if(!(info.exists && turns>0))revert InvalidContribution();
        uint256 leaderFee=msg.value/2; uint256 clanFee=msg.value-leaderFee;
        states[id].feePool+=clanFee; totalFeePools+=clanFee;
        address leader=map.getTileOccupant(info.leaderX,info.leaderY);
        leaderClaims[leader]+=leaderFee; totalLeaderClaims+=leaderFee;
        emit TurnContribution(id,map.getTileOccupant(x,y),turns,clanFee,leaderFee);
    }

    function vote(uint64 id,int32 x,int32 y,uint64 target,uint8 choice,uint256 amount) rpcIndexed external nonReentrant {IJLand(address(land)).requireWorldActive();
        _member(id,x,y);require(id!=target&&clans.getClanInfo(target).exists,"Invalid clan target");require(choice<=2,"Invalid stance");
        uint64 key=_key(x,y);bytes32 identity=_identity(x,y);ClanPower.spend(id,key,identity,amount);
        ClanPower.Ballot storage v=ClanPower.data().diplomacy[id][target][key];if(v.identity!=identity){v.identity=identity;delete v.spent;}
        v.spent[choice]+=amount;v.lastChoice=choice;
        (uint8 previous,uint8 current)=ClanDiplomacyWeights.record(id,target,choice,amount);
        IActivityLand(address(land)).recordActivity(x,y,msg.sender);emit InfluenceSpent(id,msg.sender,amount);emit DiplomacyVoted(id,target,msg.sender,choice);
        if(previous!=current){emit DiplomacyChanged(id,target,previous,current);_notifyDiplomacy(id,target,current,true);_notifyDiplomacy(target,id,current,false);}
    }
    function _notifyDiplomacy(uint64 id,uint64 other,uint8 stanceValue,bool outgoing) private {
        ICWClan.Member[] memory members=clans.getClanMemberTiles(id);string memory name=clans.getClanInfo(other).name;
        for(uint256 i;i<members.length;i++){_recordRPCRecipient(map.getTileOccupant(members[i].x,members[i].y));emit ClanDiplomacyNotice(map.getTileOccupant(members[i].x,members[i].y),id,other,stanceValue,outgoing,name);}
    }
    function memberVote(uint64 id,uint64 target,int32 x,int32 y) external view returns(uint8) {ClanPower.Ballot storage v=ClanPower.data().diplomacy[id][target][_key(x,y)];return v.identity==_identity(x,y)?v.lastChoice:0;}
    function stance(uint64 id,uint64 target) public view returns(uint8 result,uint256[3] memory weights) {
        if(id==target||!clans.getClanInfo(id).exists||!clans.getClanInfo(target).exists)return(0,weights);
        return _memberStance(id,target);
    }
    function _memberStance(uint64 id,uint64 target) private view returns(uint8 result,uint256[3] memory weights) {
        weights=ClanDiplomacyWeights.data().weights[id][target];
        result=ClanDiplomacyWeights.result(weights);
    }
    function relationship(uint64 a,uint64 b) internal view returns(uint8 effective,uint8 fromA,uint8 fromB) {
        (fromA,)=stance(a,b); (fromB,)=stance(b,a);
        if(fromA==2 || fromB==2) effective=2;
        else if(fromA==1 && fromB==1) effective=1;
    }
    function attackStatus(uint64 a,uint64 b) internal view returns(uint256 turnsRemaining,uint256 attackerProtection,uint256 defenderProtection,uint8 relation) {
        State storage s=states[a];
        // Preserve the existing return shape; clan attacks no longer require new Influence.
        turnsRemaining=0;
        attackerProtection=s.protectedUntil>block.timestamp?s.protectedUntil-block.timestamp:0;
        defenderProtection=states[b].protectedUntil>block.timestamp?states[b].protectedUntil-block.timestamp:0;
        (relation,,)=relationship(a,b);
    }
    function _min(uint256 a,uint256 b) private pure returns(uint256) { return a<b?a:b; }
    function _percent(uint256 v) private pure returns(uint256) { return _min(v,90); }
    function _losses(Battle memory b,uint256 ap,uint256 dp,uint256 factor) private view {(b.attackerLosses,b.defenderLosses)=lossMath.losses(b.sent,b.defending,ap,dp,factor,b.won);}
    function resolveExpeditionForJourney(uint256 journeyId,uint64 a,uint64 d,uint256[4] calldata army) internal nonReentrant onlyLogistics returns(uint256[2] memory losses,uint256[4] memory loot) {
        _ready(a,d,true);
        State storage atk=states[a];State storage def=states[d];
        uint256 offensive=army[0]+army[2];uint256 defensive=army[1]+army[3];
        uint256 defendingOff=def.offensive+def.mountedOffensive;uint256 defendingDef=def.defensive+def.mountedDefensive;
        uint256 ap=offensive*2+defensive; uint256 dp=defendingOff+defendingDef*2;
        uint256 margin=ap>dp?ap-dp:dp-ap; uint256 factor=margin*100/(ap+dp);
        Battle memory b; b.attacker=a; b.defender=d; b.timestamp=block.timestamp; b.won=ap>dp;
        b.sent=[offensive,defensive]; b.defending=[defendingOff,defendingDef];
        _losses(b,ap,dp,factor);
        uint256 mountedOffLoss=defendingOff==0?0:b.defenderLosses[0]*def.mountedOffensive/defendingOff;
        uint256 mountedDefLoss=defendingDef==0?0:b.defenderLosses[1]*def.mountedDefensive/defendingDef;
        def.offensive-=b.defenderLosses[0]-mountedOffLoss;def.defensive-=b.defenderLosses[1]-mountedDefLoss;
        def.mountedOffensive-=mountedOffLoss;def.mountedDefensive-=mountedDefLoss;
        _finishBattle(journeyId,a,d,b,atk,def,factor,type(uint256).max);
        return(b.attackerLosses,b.loot);
    }
    function resolveTyped(uint256 journeyId,uint64 a,uint64 d,uint256[4] calldata army) rpcIndexed external nonReentrant onlyLogistics returns(uint256[4] memory losses,uint256[4] memory loot){ IJLand(address(land)).requireWorldActive(); 
        _ready(a,d,true);State storage atk=states[a];State storage def=states[d];Military m=Military(IJLand(address(land)).military());
        ICWClan.Info memory ac=clans.getClanInfo(a);ICWClan.Info memory dc=clans.getClanInfo(d);
        Military.Summary memory o=m.resolve(journeyId,ac.leaderX,ac.leaderY,dc.leaderX,dc.leaderY,d,army,[def.offensive,def.defensive,def.mountedOffensive,def.mountedDefensive]);
        Battle memory b;b.attacker=a;b.defender=d;b.timestamp=block.timestamp;b.won=o.attackPower>o.defensePower;
        b.sent[0]=o.sent;b.defending[0]=o.defenders;b.attackerLosses[0]=o.attackerLosses;b.defenderLosses[0]=o.defenderLosses;
        for(uint8 i;i<4;i++)losses[i]=o.attackLoss[i];def.offensive-=o.defenseLoss[0];def.defensive-=o.defenseLoss[1];def.mountedOffensive-=o.defenseLoss[2];def.mountedDefensive-=o.defenseLoss[3];
        uint256 factor=(b.won?o.attackPower-o.defensePower:o.defensePower-o.attackPower)*100/(o.attackPower+o.defensePower);
        _finishBattle(journeyId,a,d,b,atk,def,factor,o.capacity);return(losses,b.loot);
    }
    function _raidLoot(uint64 a,uint64 d,uint256 factor,uint256 carry) private returns(uint256[4] memory loot) {
        uint256 percent=_min(factor,35);if(percent<10)percent=10;
        uint256 cap=capacity(a);IJLogistics journeys=IJLogistics(IJLand(address(land)).logistics());
        (uint256[8] memory returned,)=journeys.returnedAssets(0,0,d);
        uint256[4] memory limits;
        for(uint8 i;i<4;i++) limits[i]=_min((states[d].resources[i]+returned[i])*percent/100,cap-states[a].resources[i]);
        loot=LootAllocation.allocate(limits,carry);
        for(uint8 i;i<4;i++) {
            uint256 total=states[d].resources[i]+returned[i];uint256 fromReturn=total==0?0:loot[i]*returned[i]/total;
            states[d].resources[i]-=loot[i]-fromReturn;
            if(fromReturn>0)journeys.seizeReturnedCargo(0,0,d,i+1,fromReturn);
        }
    }
    function _finishBattle(uint256 journeyId,uint64 a,uint64 d,Battle memory b,State storage atk,State storage def,uint256 factor,uint256 carry) private {
        if(b.won) {
            def.protectedUntil=block.timestamp+DEFEAT_PROTECTION;
            // Clan victories capture half the BNB pool, rounded down to wei; other assets are unchanged.
            JourneyLootEscrow.State storage escrow=JourneyLootEscrow.data();
            require(journeyId>0&&!escrow.entries[journeyId].recorded,"Loot already recorded");
            b.bnbLoot=def.feePool/2;def.feePool-=b.bnbLoot;totalFeePools-=b.bnbLoot;
            escrow.entries[journeyId]=JourneyLootEscrow.Entry(b.bnbLoot,0,0,a,true);escrow.total+=b.bnbLoot;
            // Captured BNB is not raidable or reward-eligible until home collection.
            // Pending loot is reserved separately, excluded from both clan pools and world-end rewards.
        }
        uint256 index=history.length; if(IJLand(address(land)).military()!=address(0))battleJourneys[index]=journeyId; history.push(b); clanBattles[a].push(index); clanBattles[d].push(index);
        emit ClanAttacked(index,a,d,b.won,b.bnbLoot);
        address readProjection=IActivityIndexSource(address(land)).readIndex();if(readProjection!=address(0)){int32[4] memory p=IJLogistics(IJLand(address(land)).logistics()).journeyBattleLocation(journeyId);IReadActivity(readProjection).activity(2,p[0],p[1],p[2],p[3],0);}
    }
    function getBattles(uint64 id,uint256 offset,uint256 limit) external view returns(Battle[] memory result,uint256 total) {
        if(!(limit>0 && limit<=25))revert BattlePageLimit(); total=clanBattles[id].length;
        if(offset>=total) return(new Battle[](0),total);
        uint256 length=_min(limit,total-offset); result=new Battle[](length);
        uint64 viewer=_viewerClan();for(uint256 i;i<length;i++) result[i]=_visibleBattle(history[clanBattles[id][total-1-offset-i]],viewer);
    }
    function getBattleJourneys(uint64 id,uint256 offset,uint256 limit) external view returns(uint256[] memory ids){
        require(limit>0&&limit<=25,"Page size");uint256 total=clanBattles[id].length;uint256 n=offset<total?total-offset:0;if(n>limit)n=limit;ids=new uint256[](n);for(uint256 i;i<n;i++)ids[i]=battleJourneys[clanBattles[id][total-1-offset-i]];
    }
    function getWorldBattleJourneys(uint256 fromTs,uint256 toTs,uint256 offset,uint256 limit) external view returns(uint256[] memory ids){
        require(limit>0&&limit<=25,"Page size");if(toTs==0)toTs=block.timestamp;require(fromTs<=toTs,"Date range");uint256 start=_battleBound(fromTs,false);uint256 end=_battleBound(toTs,true);uint256 total=end-start;uint256 n=offset<total?total-offset:0;if(n>limit)n=limit;ids=new uint256[](n);for(uint256 i;i<n;i++)ids[i]=battleJourneys[end-1-offset-i];
    }
    function getBattle(uint256 id) external view returns(Battle memory) { return _visibleBattle(history[id],_viewerClan()); }
    /// @notice Public, newest-first clan battles. Inclusive UTC timestamps; zero end means now.
    /// Binary bounds keep date filtering logarithmic; at most 25 records are returned.
    function getWorldBattlesPage(uint256 fromTs,uint256 toTs,uint256 offset,uint256 limit)
        external view returns(Battle[] memory battles,uint256 total) {
        if(!(limit>0 && limit<=25))revert BattlePageLimit();
        if(toTs==0) toTs=block.timestamp;
        if(!(fromTs<=toTs))revert InvalidBattleDates();
        uint256 start=_battleBound(fromTs,false); uint256 end=_battleBound(toTs,true);
        total=end-start;
        if(offset>=total) return(new Battle[](0),total);
        uint256 count=_min(limit,total-offset); end-=offset;
        battles=new Battle[](count);
        uint64 viewer=_viewerClan();for(uint256 i;i<count;i++) battles[i]=_visibleBattle(history[end-1-i],viewer);
    }
    function _viewerClan() private view returns(uint64){
        if(msg.sender==address(0))return 0;
        try map.getOccupiedTileByAddress(msg.sender) returns(int32[2] memory p){
            if(map.getTileOccupant(p[0],p[1])==msg.sender)return clans.getTileClan(p[0],p[1]);
        }catch{}return 0;
    }
    function _visibleBattle(Battle memory b,uint64 viewer) private pure returns(Battle memory summary){
        if(viewer!=0&&(viewer==b.attacker||viewer==b.defender))return b;
        summary.attacker=b.attacker;summary.defender=b.defender;summary.timestamp=b.timestamp;summary.won=b.won;
    }
    function _battleBound(uint256 timestamp,bool upper) private view returns(uint256 lo) {
        uint256 hi=history.length;
        while(lo<hi) {
            uint256 mid=lo+(hi-lo)/2; uint256 t=history[mid].timestamp;
            if(t<timestamp || (upper && t==timestamp)) lo=mid+1;
            else hi=mid;
        }
    }
    /// @notice Earned claims stay with the wallet even after leaving, selling or disbanding.
    function claim(address payable recipient,bool leaderFee,bool loot) internal nonReentrant {
        _claim(recipient,leaderFee,loot);
    }
    function nativePayouts(address member) internal view returns(uint256) { return leaderClaims[member]+lootClaims[member]; }
    function withdrawNativePayout(address payable recipient) internal nonReentrant { _claim(recipient,true,true); }
    function _claim(address payable recipient,bool leaderFee,bool loot) private {
        require(block.timestamp>=IJLand(address(land)).worldEndsAt(),"World still open");
        if(!(recipient!=address(0) && recipient!=address(this)))revert InvalidClaimRecipient();
        uint256 l=leaderFee?leaderClaims[msg.sender]:0; uint256 w=loot?lootClaims[msg.sender]:0;
        if(!(l+w>0))revert NoClanClaim();
        if(leaderFee) { leaderClaims[msg.sender]=0; totalLeaderClaims-=l; }
        if(loot) { lootClaims[msg.sender]=0; totalLootClaims-=w; }
        (bool ok,)=recipient.call{value:l+w}(""); if(!(ok))revert ClanClaimTransferFailed();
        emit Claimed(msg.sender,recipient,l,w);
    }
    /// @dev Disbanding forfeits donations; unclaimed personal entitlements survive.
    function onDisband(uint64 id) internal nonReentrant {
        if(!(msg.sender==address(clans)))revert ClanRequired();
        address j=IJLand(address(land)).logistics();if(!(j==address(0)||IJLogistics(j).clanOutgoing(id)==0))revert ClanExpeditionsOutstanding();
        uint256 amount=states[id].feePool;
        totalFeePools-=amount; delete states[id];delete clanCartStock[id];if(IJLand(address(land)).military()!=address(0))Military(IJLand(address(land)).military()).disband(id);
        if(amount>0) land.fundNativeRewards{value:amount}();
        emit ClanDisbanded(id,amount);
    }

    function _captureRecipients(uint256 journeyId,uint64 id) private {
        ICWClan.Member[] memory members = clans.getClanMemberTiles(id);
        ClanPower.Data storage power = ClanPower.data();
        Recipient[] memory selected=new Recipient[](members.length);uint256[] memory weights=new uint256[](members.length);uint256 count;
        for (uint256 i; i < members.length; ++i) {
            ICWClan.Member memory m = members[i];
            ClanPower.Member storage member = power.members[id][_key(m.x,m.y)];
            uint256 weight = member.reputation;
            if (weight == 0) continue;
            address account = map.getTileOccupant(m.x,m.y);
            bytes32 identity = keccak256(abi.encode(clans.membershipEpoch(m.x,m.y), account, map.ownershipEpoch(m.x,m.y)));
            if (member.identity != identity) continue;
            selected[count]=Recipient(m.x,m.y,account,identity);weights[count++]=weight;
        }
        if(count>=3){
            // Fixed-size immutable records preserve full-width Reputation and identities.
            // A leading STOP makes the data contract inert; no mutable admin or calls.
            bytes memory data=new bytes(1+count*96);
            for(uint256 i;i<count;i++){
                Recipient memory r=selected[i];uint256 packed=uint256(uint32(r.x))|(uint256(uint32(r.y))<<32)|(uint256(uint160(r.account))<<64);
                bytes32 identity=r.identity;uint256 weight=weights[i];
                assembly("memory-safe"){let dst:=add(add(data,33),mul(i,96)) mstore(dst,packed) mstore(add(dst,32),identity) mstore(add(dst,64),weight)}
            }
            ClanDepartureData.data().allocations[journeyId]=address(new FinalClanAllocation(ClanDepartureData.pack(data)));
            return;
        }
        Recipient[] storage recipients=expeditionRecipients[journeyId];
        for(uint256 i;i<count;i++){
            recipients.push(selected[i]);Recipient storage entry=recipients[recipients.length-1];uint256 weight=weights[i];
            // x, y and account occupy 28 bytes. The remaining four bytes were
            // zero on all legacy receipts. Zero selects their full-width mapping.
            if (weight <= type(uint32).max) {
                assembly ("memory-safe") { sstore(entry.slot, or(sload(entry.slot), shl(224, weight))) }
            } else {
                power.recipientWeight[journeyId][entry.identity] = weight;
            }
        }
    }
    function _departureWeight(uint256 id,Recipient storage entry) private view returns(uint256 weight) {
        assembly ("memory-safe") { weight := shr(224, sload(entry.slot)) }
        if (weight == 0) weight = ClanPower.data().recipientWeight[id][entry.identity];
    }
    function _departureSnapshot(uint256 id) private view returns(Recipient[] memory recipients,uint256[] memory weights){
        address pointer=ClanDepartureData.data().allocations[id];
        if(pointer==address(0)){
            recipients=expeditionRecipients[id];weights=new uint256[](recipients.length);
            for(uint256 i;i<recipients.length;i++)weights[i]=_departureWeight(id,expeditionRecipients[id][i]);
        }else{
            bytes memory data=ClanDepartureData.read(pointer);
            uint256 count=data.length/96;recipients=new Recipient[](count);weights=new uint256[](count);
            for(uint256 i;i<count;i++){
                uint256 packed;bytes32 identity;uint256 weight;
                assembly("memory-safe"){let src:=add(add(data,32),mul(i,96)) packed:=mload(src) identity:=mload(add(src,32)) weight:=mload(add(src,64))}
                recipients[i]=Recipient(int32(uint32(packed)),int32(uint32(packed>>32)),address(uint160(packed>>64)),identity);weights[i]=weight;
            }
        }
    }
    function getExpeditionRecipients(uint256 id) external view returns(Recipient[] memory recipients){(recipients,)=_departureSnapshot(id);}

    function canTransferRealm(int32 x,int32 y) external view returns(bool){
        uint64 id=clans.getTileClan(x,y);if(id==0)return true;ICWClan.Info memory info=clans.getClanInfo(id);
        return info.leaderX!=x||info.leaderY!=y;
    }





    /// Decision is consumed before the trusted Clan callback. onDisband owns the payment guard.



    event LocalSuppliesDonated(uint64 indexed clanId,int32 indexed x,int32 indexed y,uint256[4] amounts);
    function donateLocalResources(uint64 id,int32 x,int32 y,uint256[4] calldata amounts)  external nonReentrant onlyLogistics {revert("Clan stores are retired");}











    /// Unknown selectors are resolved by the immutable council module or revert.
    fallback() external payable {address target=address(councilModule);assembly("memory-safe"){let ptr:=mload(0x40) calldatacopy(ptr,0,calldatasize()) let ok:=delegatecall(gas(),target,ptr,calldatasize(),0,0) returndatacopy(ptr,0,returndatasize()) switch ok case 0 {revert(ptr,returndatasize())} default {return(ptr,returndatasize())}}}
}
