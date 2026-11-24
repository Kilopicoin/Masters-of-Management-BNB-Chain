// SPDX-License-Identifier: MIT
import "./PublicRPCEvents.sol";
import {WalletClaimStatus} from "./WalletClaimStatus.sol";
pragma solidity 0.8.37;
import "JourneyLootEscrow.sol";
import {ClanFinalPool,FinalClanAllocation} from "ClanFinalPool.sol";
import {ClanDepartureData} from "ClanDepartureData.sol";
interface IReadActivity {function activity(uint8,int32,int32,int32,int32,uint256) external;}
interface IActivityIndexSource {function readIndex() external view returns(address);}

import {ClanTreasurySettlement} from "clantreasurysettlement.sol";
import {ClanPower,ClanDiplomacyWeights} from "clanpower.sol";
import {LootAllocation} from "lootallocation.sol";
import {ClanWarExtension} from "clanwarextension.sol";
import "journeyinterfaces.sol";
import "militarycontract.sol";
import "clanlossmath.sol";

interface ICWMap {
    function getTileOccupant(int32 x, int32 y) external view returns (address);
    function ownershipEpoch(int32 x, int32 y) external view returns (uint256);
    function getOccupiedTileByAddress(address account) external view returns(int32[2] memory);
}
interface ICWLand {
    function adjustTileResources(int32 x, int32 y, uint8 resourceType, uint256 amount, bool adding) external;
    function fundNativeRewards() external payable;
    function hasClanHallAtCoord(int32 x,int32 y) external view returns(bool);
}
interface ICWClan {
    struct Info { string name; int32 leaderX; int32 leaderY; uint8 memberCount; bool exists; }
    struct Member { int32 x; int32 y; uint64 clanId; uint256 flagId; }
    function getClanInfo(uint64 id) external view returns (Info memory);
    function getTileClan(int32 x, int32 y) external view returns (uint64);
    function getClanMemberTiles(uint64 id) external view returns (Member[] memory);
    function membershipEpoch(int32 x, int32 y) external view returns (uint256);
    function applyCouncil(uint64 id,uint8 kind,int32 x,int32 y) external payable;
    function REMOVE_MEMBER_COST() external view returns(uint256);
}

/// @notice Permanent clan donations, contribution-weighted diplomacy and clan-only combat.
interface IActivityLand {function recordActivity(int32 x,int32 y,address actor) external;}

/// No administrator, token, withdrawal of donations, or arbitrary realm attack entry point.
interface ILogisticsSequence {function nextId() external view returns(uint256);}
contract ClanWar  is PublicRPCEvents {
    error ClanActionInProgress();
    error ClanArmyRequired();
    error InvalidClaimRecipient();
    error NoClanClaim();
    error ClanClaimTransferFailed();
    error ClanMemberRequired();
    error RealmOwnerRequired();
    error LogisticsRequired();
    error ClanMissing();
    error InvalidClanTarget();
    error ClanProtected();
    error LandRequired();
    error InvalidContribution();
    error InvalidStance();
    error BattlePageLimit();
    error InvalidBattleDates();
    error ClanRequired();
    error ClanStorageFull();
    error EnemyClanRequired();
    error ClanContributionRequired();
    error ExpeditionSuppliesRequired();
    error ClanSuppliesRequired();
    error VotingContributionRequired();
    error ClanExpeditionsOutstanding();
    error CouncilProposalOpen();
    error InvalidCouncilDecision();
    error InvalidCouncilNominee();
    error InvalidRemovalTarget();
    error CouncilProposalUnavailable();
    error OriginalElectorateRequired();
    error CouncilOutsideReviewWindow();
    error CouncilMajorityRequired();
    error IncorrectCouncilPayment();
    error CouncilJourneysOutstanding();
    ICWMap public immutable map;
    ICWLand public immutable land;
    ICWClan public immutable clans;
    uint256 public constant BASE_CAPACITY = 40000;
    uint256 public constant SILO_CAPACITY = 20000;
    uint256 public constant ATTACK_TURNS = 0;
    uint256 public constant DEFEAT_PROTECTION = 72 hours;
    struct State {
        uint256 offensive;
        uint256 defensive;
        uint256[4] resources;
        uint256 silos;
        uint256 feePool;
        uint256 experience;
        uint256 lastAttackExperience;
        uint256 protectedUntil;
        uint256 mountedOffensive;
        uint256 mountedDefensive;
    }
    struct Contribution { bytes32 identity; uint256 experience; }
    struct Vote { bytes32 identity; uint8 stance; }
    // 0 neutral, 1 friendly, 2 enemy. Ties resolve to neutral.
    mapping(uint64 => State) private states;
    mapping(uint64 => mapping(uint64 => Contribution)) private contributions;
    mapping(uint64 => mapping(uint64 => mapping(uint64 => Vote))) private votes;
    mapping(address => uint256) public leaderClaims;
    mapping(address => uint256) public lootClaims;
    uint256 public totalFeePools;
    uint256 public totalLeaderClaims;
    uint256 public totalLootClaims;
    uint256 private guard = 1;
    struct Battle {
        uint64 attacker;
        uint64 defender;
        uint256 timestamp;
        bool won;
        uint256[2] sent;
        uint256[2] defending;
        uint256[2] attackerLosses;
        uint256[2] defenderLosses;
        uint256[4] loot;
        uint256 bnbLoot;
        uint256 share;
        uint256 recipients;
    }
    Battle[] private history;
    mapping(uint64 => uint256[]) private clanBattles;
    event ArmyDonated(uint64 indexed clanId, address indexed member, uint256 offensive, uint256 defensive);
    event SuppliesDonated(uint64 indexed clanId, address indexed member, uint256[4] amounts);
    event SiloBuilt(uint64 indexed clanId, uint256 count);
    event TurnContribution(uint64 indexed clanId, address indexed member, uint256 turns, uint256 clanFee, uint256 leaderFee);
    event DiplomacyVoted(uint64 indexed clanId, uint64 indexed target, address indexed member, uint8 stance);
    event ClanDiplomacyNotice(address indexed recipient,uint64 indexed clanId,uint64 indexed otherClan,uint8 stance,bool outgoing,string otherName);
    event DiplomacyChanged(uint64 indexed clanId, uint64 indexed target, uint8 previousStance, uint8 stance);
    event ClanAttackNotice(address indexed recipient,uint64 indexed defender,uint64 indexed attacker,bool won,string attackerName);
    event ClanAttacked(uint256 indexed battleId, uint64 indexed attacker, uint64 indexed defender, bool won, uint256 bnbLoot);
    event Claimed(address indexed member, address indexed recipient, uint256 leaderFee, uint256 loot);
    event ClanDisbanded(uint64 indexed clanId, uint256 poolReturnedToRewards);
    modifier nonReentrant() { if(!(guard != 2))revert ClanActionInProgress(); guard=2; _; guard=1; }

    ClanTreasurySettlement public immutable treasurySettlement;
    event FinalClanPoolAllocated(uint64 indexed clanId,uint256 amount);
    event NativePayoutAccrued(address indexed account,uint256 amount);
    ClanLossMath public immutable lossMath;
    constructor(address mapAddress, address landAddress, address clanAddress,address extensionAddress) {
        require(extensionAddress.code.length>0,"Clan module required");extension=ClanWarExtension(payable(extensionAddress));
        require(extension.configurationHash()==keccak256(abi.encode(mapAddress,landAddress,clanAddress)),"Clan module mismatch");
        require(mapAddress.code.length>0 && landAddress.code.length>0 && clanAddress.code.length>0, "Invalid contracts");
        treasurySettlement=new ClanTreasurySettlement(address(this),mapAddress,landAddress,clanAddress);
        lossMath=new ClanLossMath();map=ICWMap(mapAddress); land=ICWLand(landAddress); clans=ICWClan(clanAddress);
    }
    function _key(int32 x,int32 y) private pure returns(uint64) { return uint64(uint32(x))<<32 | uint64(uint32(y)); }
    function _identity(int32 x,int32 y) private view returns(bytes32) {
        return keccak256(abi.encode(clans.membershipEpoch(x,y),map.getTileOccupant(x,y),map.ownershipEpoch(x,y)));
    }
    function _member(uint64 id,int32 x,int32 y) private view {
        if(!(id!=0 && clans.getTileClan(x,y)==id && clans.getClanInfo(id).exists))revert ClanMemberRequired();
        if(!(map.getTileOccupant(x,y)==msg.sender))revert RealmOwnerRequired();
    }
    function _leader(uint64 id) private view {
        ICWClan.Info memory info=clans.getClanInfo(id);
        require(info.exists && map.getTileOccupant(info.leaderX,info.leaderY)==msg.sender, "Only clan leader");
    }
    function getState(uint64 id) external view returns(State memory result) {result=states[id];result.experience=ClanPower.data().earned[id];result.lastAttackExperience=ClanPower.data().lastAttack[id];}
    function getStateHash(uint64 id) external view returns(bytes32) {
        address j=IJLand(address(land)).logistics();uint256[8] memory cargo;uint256[4] memory army;
        if(j!=address(0))(cargo,army)=IJLogistics(j).returnedAssets(0,0,id);
        return keccak256(abi.encode(states[id],clanCartStock[id],cargo,army,IJLand(address(land)).military()==address(0)?bytes32(0):Military(IJLand(address(land)).military()).clanHash(id)));
    }
    function capacity(uint64 id) public view returns(uint256) { return BASE_CAPACITY+states[id].silos*SILO_CAPACITY; }
    function siloCost(uint64 id) public view returns(uint256[4] memory cost) {
        uint256 n=states[id].silos+1;
        return [5000*n,20000*n,20000*n,10000*n];
    }
    modifier onlyLogistics() { if(!(msg.sender==IJLand(address(land)).logistics()))revert LogisticsRequired(); _; }
    function resourceRoom(uint64 id) external view returns(uint256[4] memory room) {
        for(uint8 i;i<4;i++)room[i]=capacity(id)-states[id].resources[i];
    }
    function receiveCargo(uint64 id,uint256[4] calldata supplies,uint256[4] calldata army)  external nonReentrant onlyLogistics {require(clans.getClanInfo(id).exists,"Clan missing");for(uint8 i;i<4;i++)require(supplies[i]==0,"Clan stores are retired");State storage s=states[id];s.offensive+=army[0];s.defensive+=army[1];s.mountedOffensive+=army[2];s.mountedDefensive+=army[3];}
    function _ready(uint64 a,uint64 d,bool checkProtection) private view {
        if(!(a!=d && clans.getClanInfo(a).exists && clans.getClanInfo(d).exists))revert InvalidClanTarget();
        (,,uint256 shield,uint8 relation)=attackStatus(a,d);
        if(!(relation==2))revert EnemyClanRequired();
        if(checkProtection && shield!=0)revert ClanProtected();
    }
    function depart(uint64 a,uint64 d,uint256[4] calldata army)  external nonReentrant onlyLogistics { IJLand(address(land)).requireWorldActive(); _depart(a,d,army,0);}
    function departTyped(uint64 a,uint64 d,uint256[4] calldata army,uint256 extra)  external nonReentrant onlyLogistics { IJLand(address(land)).requireWorldActive(); _depart(a,d,army,extra);}
    function _depart(uint64 a,uint64 d,uint256[4] memory army,uint256 extra) private {
        _ready(a,d,false); State storage s=states[a];uint256 size=extra;
        for(uint8 i;i<4;i++)size+=army[i];if(size<100)revert ClanArmyRequired();
        s.offensive-=army[0];s.defensive-=army[1];s.mountedOffensive-=army[2];s.mountedDefensive-=army[3];
        ICWClan.Info memory leader=clans.getClanInfo(a);for(uint8 i;i<4;i++)land.adjustTileResources(leader.leaderX,leader.leaderY,i+1,size*(4-i),false);
    }
    function buildSilo(uint64 id, uint256 expectedCount)  external nonReentrant {revert("Clan stores are retired");}
    /// @dev Only the sealed Land contract can supply a paid turn contribution.
    event ClanFeesFunded(uint64 indexed clanId,uint256 amount);
    /// Only Clan can route a paid banner fee into the raidable collective pool.
    function fundClanFees(uint64 id) rpcIndexed external payable nonReentrant {
        IJLand(address(land)).requireWorldActive();
        if(msg.sender!=address(clans)) revert ClanRequired();
        if(!clans.getClanInfo(id).exists || msg.value==0) revert InvalidContribution();
        states[id].feePool+=msg.value; totalFeePools+=msg.value;
        emit ClanFeesFunded(id,msg.value);
    }
    function recordTurnFee(int32 x,int32 y,uint16 turns) rpcIndexed external payable nonReentrant { IJLand(address(land)).requireWorldActive(); 
        if(!(msg.sender==address(land)))revert LandRequired();
        uint64 id=clans.getTileClan(x,y); ICWClan.Info memory info=clans.getClanInfo(id);
        if(!(info.exists && turns>0))revert InvalidContribution();
        uint256 leaderFee=msg.value/2; uint256 clanFee=msg.value-leaderFee;
        states[id].feePool+=clanFee; totalFeePools+=clanFee;
        address leader=map.getTileOccupant(info.leaderX,info.leaderY);
        leaderClaims[leader]+=leaderFee; totalLeaderClaims+=leaderFee;
        emit TurnContribution(id,map.getTileOccupant(x,y),turns,clanFee,leaderFee);
    }
    function contribution(uint64 id,int32 x,int32 y) public view returns(uint256) {if(id==0||clans.getTileClan(x,y)!=id)return 0;ClanPower.Member storage m=ClanPower.data().members[id][_key(x,y)];return m.identity==_identity(x,y)?m.influence:0;}
    function vote(uint64 id,int32 x,int32 y,uint64 target,uint8 choice,uint256 amount) internal nonReentrant {IJLand(address(land)).requireWorldActive();
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
    function memberVote(uint64 id,uint64 target,int32 x,int32 y) internal view returns(uint8) {ClanPower.Ballot storage v=ClanPower.data().diplomacy[id][target][_key(x,y)];return v.identity==_identity(x,y)?v.lastChoice:0;}
    function relationship(uint64 a,uint64 b) public view returns(uint8 effective,uint8 fromA,uint8 fromB) {
        (fromA,)=ClanWarExtension(payable(address(this))).stance(a,b); (fromB,)=ClanWarExtension(payable(address(this))).stance(b,a);
        if(fromA==2 || fromB==2) effective=2;
        else if(fromA==1 && fromB==1) effective=1;
    }
    function attackStatus(uint64 a,uint64 b) public view returns(uint256 turnsRemaining,uint256 attackerProtection,uint256 defenderProtection,uint8 relation) {
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
    function resolveExpeditionForJourney(uint256 journeyId,uint64 a,uint64 d,uint256[4] calldata army) rpcIndexed external nonReentrant onlyLogistics returns(uint256[2] memory losses,uint256[4] memory loot) { IJLand(address(land)).requireWorldActive(); 
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
    function resolveTyped(uint256 journeyId,uint64 a,uint64 d,uint256[4] calldata army) internal nonReentrant onlyLogistics returns(uint256[4] memory losses,uint256[4] memory loot){
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
        IJLogistics journeys = IJLogistics(IJLand(address(land)).logistics());
        (uint256[8] memory returned,) = journeys.returnedAssets(0,0,d);
        uint256[4] memory fromReturn;
        (loot,fromReturn) = lossMath.raidShares(states[a].resources,states[d].resources,returned,capacity(a),factor,carry);
        for (uint8 i; i < 4; ++i) {
            uint256 fromStock = loot[i] - fromReturn[i];
            if (fromStock != 0) states[d].resources[i] -= fromStock;
            if (fromReturn[i] != 0) journeys.seizeReturnedCargo(0,0,d,i+1,fromReturn[i]);
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
        {ICWClan.Info memory defending=clans.getClanInfo(d);{_recordRPCRecipient(map.getTileOccupant(defending.leaderX,defending.leaderY));emit ClanAttackNotice(map.getTileOccupant(defending.leaderX,defending.leaderY),d,a,b.won,clans.getClanInfo(a).name);}}
        address readProjection=IActivityIndexSource(address(land)).readIndex();if(readProjection!=address(0)){int32[4] memory p=IJLogistics(IJLand(address(land)).logistics()).journeyBattleLocation(journeyId);IReadActivity(readProjection).activity(2,p[0],p[1],p[2],p[3],0);}
    }
    function getBattles(uint64 id,uint256 offset,uint256 limit) internal view returns(Battle[] memory result,uint256 total) {
        if(!(limit>0 && limit<=25))revert BattlePageLimit(); total=clanBattles[id].length;
        if(offset>=total) return(new Battle[](0),total);
        uint256 length=_min(limit,total-offset); result=new Battle[](length);
        uint64 viewer=_viewerClan();for(uint256 i;i<length;i++) result[i]=_visibleBattle(history[clanBattles[id][total-1-offset-i]],viewer);
    }
    function getBattle(uint256 id) internal view returns(Battle memory) { return _visibleBattle(history[id],_viewerClan()); }
    /// @notice Public, newest-first clan battles. Inclusive UTC timestamps; zero end means now.
    /// Binary bounds keep date filtering logarithmic; at most 25 records are returned.
    function getWorldBattlesPage(uint256 fromTs,uint256 toTs,uint256 offset,uint256 limit)
        internal view returns(Battle[] memory battles,uint256 total) {
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
    function journeyLoot(uint256 id) external view returns(uint256){return JourneyLootEscrow.data().entries[id].amount;}
    function pendingJourneyBNB() external view returns(uint256){return JourneyLootEscrow.data().total;}
    event JourneyBNBCollected(uint64 indexed clanId,uint256 indexed id,uint256 amount);
    function collectJourneyLoot(uint256 id,int32,int32,uint64 clanId) rpcIndexed external nonReentrant {
        IJLand(address(land)).requireWorldActive();require(msg.sender==IJLand(address(land)).logistics(),"Logistics only");
        JourneyLootEscrow.State storage s=JourneyLootEscrow.data();JourneyLootEscrow.Entry storage e=s.entries[id];
        uint256 amount=e.amount;if(amount==0)return;
        require(e.clanId==clanId&&clans.getClanInfo(clanId).exists,"Wrong loot destination");
        e.amount=0;s.total-=amount;states[clanId].feePool+=amount;totalFeePools+=amount;
        emit JourneyBNBCollected(clanId,id,amount);
    }
    function claim(address payable recipient,bool leaderFee,bool loot)  external nonReentrant {
        _claim(recipient,leaderFee,loot);
    }
    function walletWithdrawalStatus(address account) external view returns(uint256){return WalletClaimStatus.status(account);}
    function finalClanSnapshot(uint64 id) external view returns(address allocation,uint32 claimed){ClanFinalPool.Snapshot storage s=ClanFinalPool.data().clans[id];return(s.allocation,s.claimed);}
    function nativePayouts(address member) external view returns(uint256) { return leaderClaims[member]+lootClaims[member]+treasurySettlement.pending(member); }
    function withdrawNativePayout(address payable recipient)  external nonReentrant { _claim(recipient,true,true); }
    function _claim(address payable recipient,bool leaderFee,bool loot) private {
        (bool ok,bytes memory result)=address(treasurySettlement).delegatecall(abi.encodeCall(ClanTreasurySettlement.claim,(recipient,leaderFee,loot)));
        if(!ok)assembly("memory-safe"){revert(add(result,32),mload(result))}
    }
    /// @dev Disbanding forfeits donations; unclaimed personal entitlements survive.
    function onDisband(uint64 id) rpcIndexed external nonReentrant { IJLand(address(land)).requireWorldActive(); 
        if(!(msg.sender==address(clans)))revert ClanRequired();
        address j=IJLand(address(land)).logistics();if(!(j==address(0)||IJLogistics(j).clanOutgoing(id)==0))revert ClanExpeditionsOutstanding();
        uint256 amount=states[id].feePool;
        totalFeePools-=amount; delete states[id];delete clanCartStock[id];if(IJLand(address(land)).military()!=address(0))Military(IJLand(address(land)).military()).disband(id);
        if(amount>0) land.fundNativeRewards{value:amount}();
        emit ClanDisbanded(id,amount);
    }

    struct Recipient {int32 x;int32 y;address account;bytes32 identity;}
    mapping(uint256=>Recipient[]) private expeditionRecipients;
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
    function getExpeditionRecipients(uint256 id) internal view returns(Recipient[] memory){return expeditionRecipients[id];}
    function _eligible(uint64 id,Recipient memory r) private view returns(bool){return clans.getTileClan(r.x,r.y)==id&&_identity(r.x,r.y)==r.identity;}
    struct Council {uint8 kind;int32 x;int32 y;uint256 createdAt;uint256 nonce;bool active;}
    mapping(uint64=>Council) public councils;
    mapping(uint64=>Recipient[]) private electorate;
    mapping(uint64=>mapping(uint256=>mapping(bytes32=>uint8))) private ballots;
    mapping(uint64=>bytes32) private councilTargetIdentity;
    mapping(uint256=>uint256) private battleJourneys;
    mapping(uint64=>uint256) private clanCartStock;
    event InfluenceEarned(uint64 indexed clanId,address indexed member,uint256 amount);
    event InfluenceSpent(uint64 indexed clanId,address indexed member,uint256 amount);
    event CouncilProposed(uint64 indexed clanId,uint256 nonce,uint8 kind,int32 x,int32 y);
    event CouncilVoted(uint64 indexed clanId,uint256 nonce,address voter,bool approve);
    event CouncilExecuted(uint64 indexed clanId,uint256 nonce,uint8 kind);
    function canTransferRealm(int32 x,int32 y) internal view returns(bool){
        uint64 id=clans.getTileClan(x,y);if(id==0)return true;ICWClan.Info memory info=clans.getClanInfo(id);
        return info.leaderX!=x||info.leaderY!=y;
    }
    function _councilMember(uint64 id) private view returns(int32 x,int32 y){
        int32[2] memory tile=map.getOccupiedTileByAddress(msg.sender);x=tile[0];y=tile[1];_member(id,x,y);
    }
    
    
    function _targetCurrent(uint64 id,Council memory p) private view returns(bool){
        if(p.kind==2)return true;
        return councilTargetIdentity[id]!=bytes32(0)&&clans.getTileClan(p.x,p.y)==id
            &&_identity(p.x,p.y)==councilTargetIdentity[id]
            &&(p.kind!=1||land.hasClanHallAtCoord(p.x,p.y));
    }
    
    /// Decision is consumed before the trusted Clan callback. onDisband owns the payment guard.
    


    /// Fixed delegate module; no setter and no administrator upgrade route.
    ClanWarExtension public immutable extension;
    fallback() external payable {address target=address(extension);assembly("memory-safe"){let ptr:=mload(0x40) calldatacopy(ptr,0,calldatasize()) let ok:=delegatecall(gas(),target,ptr,calldatasize(),0,0) returndatacopy(ptr,0,returndatasize()) switch ok case 0 {revert(ptr,returndatasize())} default {return(ptr,returndatasize())}}}
    function recordDonation(uint64 id,int32 x,int32 y,bytes32 identity,uint256 resources,uint256 fixedPoints) rpcIndexed external onlyLogistics {
        IJLand(address(land)).requireWorldActive();if(identity==bytes32(0)||clans.getTileClan(x,y)!=id||identity!=_identity(x,y))return;
        uint256 points=ClanPower.credit(id,_key(x,y),identity,resources,fixedPoints);emit InfluenceEarned(id,map.getTileOccupant(x,y),points);
    }
    function memberPower(uint64 id,int32 x,int32 y) public view returns(uint256 influence,uint256 reputation){
        if(id==0||clans.getTileClan(x,y)!=id)return(0,0);ClanPower.Member storage m=ClanPower.data().members[id][_key(x,y)];if(m.identity==_identity(x,y))return(m.influence,m.reputation);
    }
    function powerSummary(uint64 id) external view returns(uint256 influence,uint256 reputation,uint256 earned){
        ICWClan.Member[] memory members=clans.getClanMemberTiles(id);for(uint256 i;i<members.length;i++){(uint256 a,uint256 b)=memberPower(id,members[i].x,members[i].y);influence+=a;reputation+=b;}earned=ClanPower.data().earned[id];
    }
    function donationTroopPoints(uint8 unit) external pure returns(uint256){return ClanPower.troopPoints(unit);}
    struct RelationRow {uint64 target;uint8 effective;uint8 ours;uint8 theirs;uint256[3] weights;}
    function relationsPage(uint64 id,uint64[] calldata targets) external view returns(RelationRow[] memory rows){
        require(targets.length<=10,"At most 10 relations");rows=new RelationRow[](targets.length);
        for(uint256 i;i<targets.length;i++){uint64 target=targets[i];(uint8 ours,uint256[3] memory weights)=ClanWarExtension(payable(address(this))).stance(id,target);(uint8 theirs,)=ClanWarExtension(payable(address(this))).stance(target,id);rows[i]=RelationRow(target,ours==2||theirs==2?2:ours==1&&theirs==1?1:0,ours,theirs,weights);}
    }
}
