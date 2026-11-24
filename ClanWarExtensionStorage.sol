// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;


interface IReadActivity {function activity(uint8,int32,int32,int32,int32,uint256) external;}
interface IActivityIndexSource {function readIndex() external view returns(address);}

import {ClanPower,CouncilBonds,ClanDiplomacyWeights} from "clanpower.sol";

import "journeyinterfaces.sol";



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
/// Exact legacy ClanWar layout, shared by the extension and fixed council module.
abstract contract ClanWarExtensionStorage {
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
    ICWMap internal immutable map;
    ICWLand internal immutable land;
    ICWClan internal immutable clans;
    uint256 internal constant BASE_CAPACITY = 40000;
    uint256 internal constant SILO_CAPACITY = 20000;
    uint256 internal constant ATTACK_TURNS = 0;
    uint256 internal constant DEFEAT_PROTECTION = 72 hours;
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
    mapping(uint64 => State) internal states;
    mapping(uint64 => mapping(uint64 => Contribution)) internal contributions;
    mapping(uint64 => mapping(uint64 => mapping(uint64 => Vote))) internal votes;
    mapping(address => uint256) internal leaderClaims;
    mapping(address => uint256) internal lootClaims;
    uint256 internal totalFeePools;
    uint256 internal totalLeaderClaims;
    uint256 internal totalLootClaims;
    uint256 internal guard = 1;
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
    Battle[] internal history;
    mapping(uint64 => uint256[]) internal clanBattles;
    event ArmyDonated(uint64 indexed clanId, address indexed member, uint256 offensive, uint256 defensive);
    event SuppliesDonated(uint64 indexed clanId, address indexed member, uint256[4] amounts);
    event SiloBuilt(uint64 indexed clanId, uint256 count);
    event TurnContribution(uint64 indexed clanId, address indexed member, uint256 turns, uint256 clanFee, uint256 leaderFee);
    event DiplomacyVoted(uint64 indexed clanId, uint64 indexed target, address indexed member, uint8 stance);
    event ClanDiplomacyNotice(address indexed recipient,uint64 indexed clanId,uint64 indexed otherClan,uint8 stance,bool outgoing,string otherName);
    event DiplomacyChanged(uint64 indexed clanId, uint64 indexed target, uint8 previousStance, uint8 stance);
    event ClanAttacked(uint256 indexed battleId, uint64 indexed attacker, uint64 indexed defender, bool won, uint256 bnbLoot);
    event Claimed(address indexed member, address indexed recipient, uint256 leaderFee, uint256 loot);
    event ClanDisbanded(uint64 indexed clanId, uint256 poolReturnedToRewards);
    modifier nonReentrant() { if(!(guard != 2))revert ClanActionInProgress(); guard=2; _; guard=1; }

    struct Recipient {int32 x;int32 y;address account;bytes32 identity;}
    mapping(uint256=>Recipient[]) internal expeditionRecipients;
    struct Council {uint8 kind;int32 x;int32 y;uint256 createdAt;uint256 nonce;bool active;}
    mapping(uint64=>Council) internal councils;
    mapping(uint64=>Recipient[]) internal electorate;
    mapping(uint64=>mapping(uint256=>mapping(bytes32=>uint8))) internal ballots;
    mapping(uint64=>bytes32) internal councilTargetIdentity;
    mapping(uint256=>uint256) internal battleJourneys;
    mapping(uint64=>uint256) internal clanCartStock;
    event InfluenceEarned(uint64 indexed clanId,address indexed member,uint256 amount);
    event InfluenceSpent(uint64 indexed clanId,address indexed member,uint256 amount);
    event CouncilProposed(uint64 indexed clanId,uint256 nonce,uint8 kind,int32 x,int32 y);
    event CouncilVoted(uint64 indexed clanId,uint256 nonce,address voter,bool approve);
    event CouncilExecuted(uint64 indexed clanId,uint256 nonce,uint8 kind);

    constructor(address m,address l,address c){require(m.code.length>0&&l.code.length>0&&c.code.length>0,"Invalid contracts");map=ICWMap(m);land=ICWLand(l);clans=ICWClan(c);}
    function _key(int32 x,int32 y) internal pure returns(uint64) { return uint64(uint32(x))<<32 | uint64(uint32(y)); }
    function _identity(int32 x,int32 y) internal view returns(bytes32) {
        return keccak256(abi.encode(clans.membershipEpoch(x,y),map.getTileOccupant(x,y),map.ownershipEpoch(x,y)));
    }
    function _member(uint64 id,int32 x,int32 y) internal view {
        if(!(id!=0 && clans.getTileClan(x,y)==id && clans.getClanInfo(id).exists))revert ClanMemberRequired();
        if(!(map.getTileOccupant(x,y)==msg.sender))revert RealmOwnerRequired();
    }
    function contribution(uint64 id,int32 x,int32 y) internal view returns(uint256) {if(id==0||clans.getTileClan(x,y)!=id)return 0;ClanPower.Member storage m=ClanPower.data().members[id][_key(x,y)];return m.identity==_identity(x,y)?m.influence:0;}
    function _eligible(uint64 id,Recipient memory r) internal view returns(bool){return clans.getTileClan(r.x,r.y)==id&&_identity(r.x,r.y)==r.identity;}
}
