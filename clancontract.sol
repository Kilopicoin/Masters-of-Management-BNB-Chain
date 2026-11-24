// SPDX-License-Identifier: MIT
import "./PublicRPCEvents.sol";
import "./ClanNoticeWriter.sol";
pragma solidity 0.8.37;
import "DirectReadIndex.sol";
interface IClanReadIndex {function readIndex() external view returns(address);}
interface IWorldReadIndex {function syncRealm(int32,int32) external;function syncClan(uint64) external;function syncRoute(uint256) external;}
interface IReadIndexSource {function readIndex() external view returns(address);}

import {IJLand} from "journeyinterfaces.sol";
import {IClanText} from "ClanText.sol";
import {IClanHallLevels} from "ClanHallLevels.sol";

interface ITileMapPhaser {
    function requireClanFee(address account,uint256 paid,bool flag) external;
    function nativeUnitWei() external view returns (uint256);
    function bonuses(int32 x, int32 y) external view returns (uint8);
    function lastAcquiredAt(int32 x,int32 y) external view returns(uint256);
    function getTileOccupant(int32 x, int32 y) external view returns (address);
    function getOccupiedTileByAddress(
        address occupant
    ) external view returns (int32[2] memory);
}

interface IClanJourneyCounter {function nextId() external view returns(uint256);}
interface IClanMarket {function cancelLeaderResourceListings(int32 x,int32 y) external;}
interface IClanWarLifecycle { function fundClanFees(uint64 clanId) external payable; function onDisband(uint64 clanId) external; function getStateHash(uint64 clanId) external view returns(bytes32); }
interface ITheLand {
    function fundNativeRewards() external payable;
    function logistics() external view returns(address);
    function recordActivity(int32 x,int32 y,address actor) external;
    function getTileLastActiveAt(int32 x,int32 y) external view returns(uint256);
    function rankedTile(uint256 index) external view returns(uint64 key,uint256 points,uint256 count);
    function rankedRealmCount() external view returns(uint256);
    function pointsByCoords(int32 x,int32 y) external view returns(uint256);
    function clanWar() external view returns (address);
    function hasClanHallAtCoord(int32 x, int32 y) external view returns (bool);
}

/// @dev Local storage-based guard and native payment accounting; no external dependency.
abstract contract ClanNativePayments  is PublicRPCEvents {
    uint256 private _reentrancyStatus = 1;
    mapping(address => uint256) public nativePayouts;
    uint256 public totalNativePayouts;
    uint256 public lockedNative;

    error ReentrantCall();
    error IncorrectNativePayment(uint256 expected, uint256 received);
    error NativeTransferFailed();
    error InvalidNativeRecipient();
    event NativePayoutAccrued(address indexed recipient, uint256 amount);
    event NativePayoutWithdrawn(
        address indexed recipient,
        address indexed to,
        uint256 amount
    );
    event NativeLocked(uint256 amount);

    modifier nonReentrant() {
        if (_reentrancyStatus == 2) revert ReentrantCall();
        _reentrancyStatus = 2;
        _;
        _reentrancyStatus = 1;
    }

    function _requireNative(uint256 expected) internal view {
        if (msg.value != expected)
            revert IncorrectNativePayment(expected, msg.value);
    }

    /// @dev Economically removes fees from circulation within this game; not a protocol ETH burn.
    function _lockNative(uint256 amount) internal {
        lockedNative += amount;
        emit NativeLocked(amount);
    }

    /// @dev No receiver callback during gameplay. Claims belong to the owner at transaction time.
    function _creditNative(address recipient, uint256 amount) internal {
        if (recipient == address(0)) revert InvalidNativeRecipient();
        if (amount == 0) return;
        nativePayouts[recipient] += amount;
        totalNativePayouts += amount;
        emit NativePayoutAccrued(recipient, amount);
    }

    /// @notice Withdraw all your accrued payments to a payable address of your choice.
    error WorldStillOpen();
    function _requirePayoutClosed() internal view virtual;
    function withdrawNativePayout(address payable to) rpcIndexed external nonReentrant {
        _requirePayoutClosed();
        if (to == address(0) || to == address(this))
            revert InvalidNativeRecipient();
        uint256 amount = nativePayouts[msg.sender];
        require(amount > 0, "No native payout");
        nativePayouts[msg.sender] = 0;
        totalNativePayouts -= amount;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit NativePayoutWithdrawn(msg.sender, to, amount);
    }
}

interface IClanReturns {function clanJourneysHome(uint64 id) external view returns(bool);}
contract Clan is PublicRPCEvents, ClanNativePayments  {
    function _requirePayoutClosed() internal view override {
        if(block.timestamp < worldEndsAt) revert WorldStillOpen();
    }
    error NameTooLong();

    error ClanCouncilRequired();
    error CouncilLeaderIneligible();
    error InvalidRankCursor();
    error InvalidRankPage();
    error InvalidClanPage();
    error InvalidClanRegion();
    error ClanRegionOverflow();
    error TooManyClanIds();


    struct ClanInfo {
        string name;
        int32 leaderX;
        int32 leaderY;
        uint8 memberCount;
        bool exists;
    }

    struct MemberInfo {
        uint64 clanId;
        bool isMember;
    }

    struct TileClanInfo {
        int32 x;
        int32 y;
        uint64 clanId;
        uint256 flagId;
    }

    ITileMapPhaser public immutable tileMapPhaser;

    ITheLand public immutable theLand;

    uint256 public immutable REMOVE_MEMBER_COST;
    uint256 public immutable REMOVE_MEMBER_PAYOUT;
    uint256 public immutable REMOVE_MEMBER_BURN;

    uint256 public immutable CLAN_CREATION_COST;
    uint256 public immutable TILE_NAMING_COST;
    uint256 public immutable CLAN_FLAG_COST;

    uint256 public immutable LEAVE_CLAN_COST;
    uint256 public immutable LEAVE_CLAN_PAYOUT;
    uint256 public immutable LEAVE_CLAN_BURN;

    uint256 private constant NAME_MIN = 1;
    uint256 private constant NAME_MAX = 32;

    mapping(bytes32 => bool) public clanNameTaken; // canonical name hash => taken?
    mapping(uint64 => bytes32) private clanNameHashById; // clanId => canonical name hash

    uint8 public constant MAX_MEMBERS = 30;
    uint64 private clanCounter;

    mapping(uint64 => ClanInfo) public clans;

    struct MemberInfoByTile {
        uint64 clanId;
        bool isMember;
    }
    mapping(uint64 => MemberInfoByTile) public membersByTile; // tileKey => membership
    mapping(uint64 => uint64[]) public clanMemberTiles; // clanId => list of tileKeys
    mapping(uint64 => uint64) public pendingInvitesByTile; // tileKey => clanId (invite)

    mapping(int32 => mapping(int32 => string)) public tileNames;
    mapping(address => string) private _retiredTwitterHandles; // Reserved storage only; the handle system is retired.

    // New mapping to store which tile has a clan
    mapping(int32 => mapping(int32 => uint64)) public tileClans; // (x, y) → clanId

    /// @notice Opaque in-game cosmetic identifier; no NFT ownership or metadata lookup.
    mapping(uint64 => uint256) public clanFlags; // clanId => flagId

    // A new membership never inherits the previous membership's contribution or votes.
    mapping(int32 => mapping(int32 => uint256)) public membershipEpoch;

    uint256 private immutable worldEndsAt;
    error WorldEnded();
    error CouncilRequired();
    constructor(address _tileMapPhaser, address _theLand) {
        worldEndsAt = IJLand(_theLand).worldEndsAt();
        require(
            _tileMapPhaser.code.length > 0 && _theLand.code.length > 0,
            "Invalid game contract"
        );
        REMOVE_MEMBER_COST = 0.001 ether;
        REMOVE_MEMBER_PAYOUT = 0; // Historical claims remain withdrawable.
        REMOVE_MEMBER_BURN = 0;
        CLAN_CREATION_COST = 0.001 ether;
        TILE_NAMING_COST = 0.001 ether;
        CLAN_FLAG_COST = 0.01 ether; // Fixed native BNB price for choosing a clan banner.
        LEAVE_CLAN_COST = 0.001 ether;
        LEAVE_CLAN_PAYOUT = 0;
        LEAVE_CLAN_BURN = 0;
        tileMapPhaser = ITileMapPhaser(_tileMapPhaser);
        theLand = ITheLand(_theLand); // <-- New
        noticeWriter = new ClanNoticeWriter(_tileMapPhaser);
    }

    function _assertValidName(string calldata name) internal view {
        IClanText(theLand.clanWar()).validateClanName(name);
    }

    error InvalidText();
    /// @dev Canonical UTF-8 only: reject truncated sequences, overlong encodings,
    /// surrogates, values above U+10FFFF and ASCII control characters.
    function _tileKey(int32 x, int32 y) internal pure returns (uint64) {
        return (uint64(uint32(x)) << 32) | uint64(uint32(y));
    }
    function _unpackKey(uint64 k) internal pure returns (int32 x, int32 y) {
        x = int32(uint32(k >> 32));
        y = int32(uint32(k));
    }

    modifier onlyClanLeaderTile(uint64 clanId, int32 lx, int32 ly) {
        require(clans[clanId].exists, "Clan does not exist");
        require(
            clans[clanId].leaderX == lx && clans[clanId].leaderY == ly,
            "Not leader tile"
        );
        require(
            tileMapPhaser.getTileOccupant(lx, ly) == msg.sender,
            "You don't own the leader tile"
        );
        theLand.recordActivity(lx,ly,msg.sender);
        _;
    }

    modifier ownsTile(int32 x, int32 y) {
        require(
            tileMapPhaser.getTileOccupant(x, y) == msg.sender,
            "You do not own this tile"
        );
        theLand.recordActivity(x,y,msg.sender);
        _;
    }

    function _nameKey(string memory name) internal view returns(bytes32 key) {
        (key,)=noticeWriter.nameKey(name);
    }

    event RealmClanChanged(int32 x,int32 y);
    event ClanNotice(address indexed recipient,uint64 indexed clanId,uint8 kind,int32 x,int32 y);
    ClanNoticeWriter public immutable noticeWriter;
    // Capture recipients before membership mutation. No stored inbox or external
    // callbacks: wallet-filtered logs remain exact even within batched operations.
    function _notifyMembers(uint64 id,uint8 kind,int32 x,int32 y) private {
        uint64[] storage members=clanMemberTiles[id];uint256 memberSlot;
        assembly("memory-safe"){memberSlot:=members.slot}
        (bool ok,bytes memory result)=address(noticeWriter).delegatecall(abi.encodeCall(ClanNoticeWriter.notify,(id,kind,x,y,memberSlot)));
        if(!ok)assembly("memory-safe"){revert(add(result,32),mload(result))}
    }
    event ClanAppearanceChanged(uint64 indexed clanId);
    event RealmNamed(int32 indexed x,int32 indexed y);

    function createClan(
        int32 x,
        int32 y,
        string calldata name
    ) rpcIndexed external payable nonReentrant ownsTile(x, y) { 
        _assertValidName(name);
        require(tileClans[x][y] == 0, "Tile already in a clan");

        bytes32 key = _nameKey(name);
        require(!clanNameTaken[key], "Clan name already taken");

        require(theLand.hasClanHallAtCoord(x, y), "You must have a Clan Hall");
        tileMapPhaser.requireClanFee(msg.sender,msg.value,false);
        if(msg.value>0)theLand.fundNativeRewards{value:msg.value}();

        clanCounter++;
        clans[clanCounter] = ClanInfo({
            name: name,
            leaderX: x,
            leaderY: y,
            memberCount: 1,
            exists: true
        });

        uint64 k = _tileKey(x, y);
        tileClans[x][y] = clanCounter;
        emit RealmClanChanged(x,y); _indexRealm(x,y);
        membershipEpoch[x][y]++;
        membersByTile[k] = MemberInfoByTile(clanCounter, true);
        clanMemberTiles[clanCounter].push(k);

        IClanHallLevels(theLand.clanWar()).syncClanHallCapacity(clanCounter);
        clanNameTaken[key] = true;
        clanNameHashById[clanCounter] = key;
        foundingDeliveries[k]=FoundingDeliveries(IClanJourneyCounter(IJLand(address(theLand)).logistics()).nextId(),membershipEpoch[x][y]);
    }

    function inviteTileToClan(
        uint64 clanId,
        int32 lx,
        int32 ly, // leader tile
        int32 targetX,
        int32 targetY // invited member tile
    ) rpcIndexed external nonReentrant onlyClanLeaderTile(clanId, lx, ly) { 
        require(clans[clanId].exists, "Clan does not exist");
        require(clans[clanId].memberCount < MAX_MEMBERS, "Clan is full");
        require(theLand.hasClanHallAtCoord(lx, ly), "You must have a Clan Hall");

        address targetOwner = tileMapPhaser.getTileOccupant(targetX, targetY);
        require(targetOwner != address(0), "Target tile unowned");
        require(
            tileClans[targetX][targetY] == 0,
            "Target tile already in a clan"
        );

        uint64 tk = _tileKey(targetX, targetY);

        if (!clans[pendingInvitesByTile[tk]].exists) delete pendingInvitesByTile[tk];
        require(pendingInvitesByTile[tk] == 0, "Invite already pending");

        pendingInvitesByTile[tk] = clanId;
        inviteNonceByTile[tk]++;
        emit ClanInviteChanged(targetX,targetY,clanId); emit InviteUpdated(targetX,targetY,clanId);
    }

    error InvitationChanged();

    event InviteUpdated(int32 indexed x,int32 indexed y,uint64 clanId);
    event ClanInviteChanged(int32 x,int32 y,uint64 clanId);

    function acceptInviteForTile(
        int32 x,
        int32 y,
        uint64 expectedClanId,
        uint256 expectedInviteNonce
    ) rpcIndexed external nonReentrant ownsTile(x, y) { 
        uint64 k = _tileKey(x, y);
        uint64 clanId = pendingInvitesByTile[k];
        require(clanId > 0, "No pending invite for this tile");
        if (clanId != expectedClanId || inviteNonceByTile[k] != expectedInviteNonce) revert InvitationChanged();
        // Preserve the existing cleanup rules for the exact invitation only.
        if (!clans[clanId].exists || tileClans[x][y] != 0 || clans[clanId].memberCount >= MAX_MEMBERS) {
            delete pendingInvitesByTile[k];
            emit ClanInviteChanged(x,y,0); emit InviteUpdated(x,y,0);
            return;
        }

        // set membership
        tileClans[x][y] = clanId;
        emit RealmClanChanged(x,y); _indexRealm(x,y);
        membershipEpoch[x][y]++;
        membersByTile[k] = MemberInfoByTile(clanId, true);
        clanMemberTiles[clanId].push(k);
        clans[clanId].memberCount++;
        _notifyMembers(clanId,5,x,y);

        delete pendingInvitesByTile[k];
        emit ClanInviteChanged(x,y,0); emit InviteUpdated(x,y,0);
    }

    function refuseInviteForTile(
        int32 x,
        int32 y,
        uint64 expectedClanId,
        uint256 expectedInviteNonce
    ) rpcIndexed external nonReentrant ownsTile(x, y) { 
        uint64 k = _tileKey(x, y);
        require(pendingInvitesByTile[k] > 0, "No pending invite for this tile");
        if (pendingInvitesByTile[k] != expectedClanId || inviteNonceByTile[k] != expectedInviteNonce) revert InvitationChanged();
        delete pendingInvitesByTile[k];
        emit ClanInviteChanged(x,y,0); emit InviteUpdated(x,y,0);
    }

    // Legacy entry point cannot bypass the council, even before a proposal opens.
    function removeMemberTile(uint64,int32,int32,int32,int32)  external payable { 
        revert CouncilRequired();
    }
    function _removeMember(uint64 clanId,int32 mx,int32 my) private {
        require(
            !(clans[clanId].leaderX == mx && clans[clanId].leaderY == my),
            "Cannot remove leader tile"
        );

        uint64 mk = _tileKey(mx, my);
        require(
            membersByTile[mk].isMember && membersByTile[mk].clanId == clanId,
            "Tile not in this clan"
        );

        _requireNative(REMOVE_MEMBER_COST);

        _notifyMembers(clanId,3,mx,my);
        membersByTile[mk].isMember = false;
        tileClans[mx][my] = 0;
        emit RealmClanChanged(mx,my); _indexRealm(mx,my);
        if (clans[clanId].memberCount < 1) {
            clans[clanId].memberCount = 1;
        }
        clans[clanId].memberCount--;

        uint64[] storage arr = clanMemberTiles[clanId];
        for (uint i = 0; i < arr.length; i++) {
            if (arr[i] == mk) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                break;
            }
        }

        theLand.fundNativeRewards{value:REMOVE_MEMBER_COST}();
    }

    error MembershipChanged();

    function leaveClanForTile(
        int32 x,
        int32 y,
        uint64 expectedClanId,
        uint256 expectedMembershipEpoch
    ) rpcIndexed external payable nonReentrant ownsTile(x, y) { 
        uint64 k = _tileKey(x, y);
        if (!membersByTile[k].isMember || membersByTile[k].clanId != expectedClanId
            || membershipEpoch[x][y] != expectedMembershipEpoch) revert MembershipChanged();
        uint64 clanId = expectedClanId;
        require(clans[clanId].exists, "Clan does not exist");

        // The leader tile cannot leave; disband or transfer leadership first
        require(
            !(clans[clanId].leaderX == x && clans[clanId].leaderY == y),
            "Leader tile cannot leave"
        );

        _requireNative(LEAVE_CLAN_COST);
        _notifyMembers(clanId,4,x,y);

        membersByTile[k].isMember = false;
        tileClans[x][y] = 0;
        emit RealmClanChanged(x,y); _indexRealm(x,y);
        if (clans[clanId].memberCount < 1) {
            clans[clanId].memberCount = 1;
        }
        clans[clanId].memberCount--;

        uint64[] storage arr = clanMemberTiles[clanId];
        for (uint i = 0; i < arr.length; i++) {
            if (arr[i] == k) {
                arr[i] = arr[arr.length - 1];
                arr.pop();
                break;
            }
        }

        theLand.fundNativeRewards{value:LEAVE_CLAN_COST}();
    }

    function disbandClan(uint64,int32,int32) external pure {revert CouncilRequired();}
    event LeadershipTransferred(uint64 indexed clanId,int32 x,int32 y);
    function applyCouncil(uint64 id,uint8 kind,int32 x,int32 y) rpcIndexed external payable nonReentrant { if(block.timestamp >= worldEndsAt) revert WorldEnded(); 
        if(!(msg.sender==theLand.clanWar()&&clans[id].exists))revert ClanCouncilRequired();
        if(kind==3){_removeMember(id,x,y);return;}
        _requireNative(0);
        if(kind==1){
            if(!(IClanHallLevels(theLand.clanWar()).leadershipHallEligible(id,x,y)))revert CouncilLeaderIneligible();
            _notifyMembers(id,1,x,y);
            clans[id].leaderX=x;clans[id].leaderY=y;
            IClanHallLevels(theLand.clanWar()).syncClanHallCapacity(id);
            IClanMarket(IJLand(address(theLand)).marketplaceAddress()).cancelLeaderResourceListings(x,y);
            emit LeadershipTransferred(id,x,y);_indexClan(id);
        }else{require(kind==2,"Unknown decision");_disbandClan(id);}
    }
    function _disbandClan(uint64 clanId) private {
        _notifyMembers(clanId,2,0,0);
        address module = theLand.clanWar();
        if (module != address(0)) IClanWarLifecycle(module).onDisband(clanId);
        uint64[] storage arr = clanMemberTiles[clanId];
        for (uint i = 0; i < arr.length; i++) {
            (int32 x, int32 y) = _unpackKey(arr[i]);
            membersByTile[arr[i]].isMember = false;
            tileClans[x][y] = 0;
        emit RealmClanChanged(x,y); _indexRealm(x,y);
        }
        delete clanMemberTiles[clanId];

        bytes32 key = clanNameHashById[clanId];
        if (key != bytes32(0)) {
            delete clanNameTaken[key];
            delete clanNameHashById[clanId];
        }
        // Keep the historical name for battle reports; the clan itself is closed.
        ClanInfo storage ended=clans[clanId];ended.leaderX=0;ended.leaderY=0;ended.memberCount=0;ended.exists=false;_indexClan(clanId);
    }

    // Trim Unicode whitespace and common invisible formatting at the edges. Interior
    // joiners are retained for names written in other scripts and emoji sequences.
    uint256 private constant TILE_NAME_MAX = 64;

    function nameTile(
        int32 x,
        int32 y,
        string calldata newName
    ) rpcIndexed external payable nonReentrant { 
        require(
            bytes(newName).length > 0 && bytes(newName).length <= 256,
            "Bad name length"
        );
        require(
            tileMapPhaser.getTileOccupant(x, y) == msg.sender,
            "Not tile owner"
        );

        // Pay the naming fee
        string memory normalized = IClanText(theLand.clanWar()).normalizeRealmName(newName);
        require(bytes(normalized).length > 0 && bytes(normalized).length <= TILE_NAME_MAX, "Bad name length");

        _requireNative(TILE_NAMING_COST);
        theLand.fundNativeRewards{value:TILE_NAMING_COST}();

        theLand.recordActivity(x,y,msg.sender);
        tileNames[x][y] = normalized;
        emit RealmNamed(x,y); _indexRealm(x,y);
    }

    function setClanFlag(
        uint64 clanId,
        int32 lx,
        int32 ly,
        uint256 flagId
    ) rpcIndexed external payable nonReentrant onlyClanLeaderTile(clanId, lx, ly) { 
        require(
            theLand.hasClanHallAtCoord(lx, ly),
            "You must have a Clan Hall"
        );

        require(flagId >= 31 && flagId <= 240, "Unknown clan flag");
        tileMapPhaser.requireClanFee(msg.sender,msg.value,true);
        if(msg.value>0)IClanWarLifecycle(theLand.clanWar()).fundClanFees{value:msg.value}(clanId);
        clanFlags[clanId] = flagId;
        emit ClanAppearanceChanged(clanId); _indexClan(clanId);
    }

    struct RankNode {uint256 index;uint64 key;uint256 points;}
    struct RankedRealm {uint64 key;uint256 points;string name;string clanName;}
    function _rankHigher(RankNode memory a,RankNode memory b) private pure returns(bool) {
        if(a.points!=b.points)return a.points>b.points;
        (int32 ax,int32 ay)=_unpackKey(a.key);(int32 bx,int32 by)=_unpackKey(b.key);
        return ax<bx || (ax==bx && ay<by);
    }
    function _pushRank(RankNode[] memory heap,uint256 size,uint256 index) private view returns(uint256) {
        (uint64 key,uint256 points,uint256 count)=theLand.rankedTile(index);
        if(!(index<count))revert InvalidRankCursor();
        if(points==0)return size;
        RankNode memory item=RankNode(index,key,points);uint256 at=size;
        while(at>0){uint256 parent=(at-1)/2;if(!_rankHigher(item,heap[parent]))break;heap[at]=heap[parent];at=parent;}
        heap[at]=item;return size+1;
    }
    /// @notice Only the next <=64 ranked realms. Reuse the returned opaque cursor at the SAME block.
    /// Uses the canonical read index; no second score heap or world scan.
    function getLeaderboardPage(uint256[] calldata cursor,uint8 limit) external view returns(RankedRealm[] memory rows,uint256[] memory next,uint256 total) {
        require(cursor.length<=1&&limit>0&&limit<=64,"Invalid page");uint256 offset=cursor.length==0?0:cursor[0];
        DirectReadIndex idx=DirectReadIndex(IClanReadIndex(address(theLand)).readIndex());
        (DirectReadIndex.RankRow[] memory page,uint256 count,,,)=idx.rankings(false,offset,limit,0,0);total=count;
        rows=new RankedRealm[](page.length);for(uint256 i;i<page.length;i++)rows[i]=RankedRealm(uint64(page[i].id),page[i].points,page[i].name,page[i].clanName);
        if(offset+page.length<total){next=new uint256[](1);next[0]=offset+page.length;}else next=new uint256[](0);
    }
    function getLeaderboardRank(int32 x,int32 y) external view returns(uint256 rank){
        (,,rank,,)=DirectReadIndex(IClanReadIndex(address(theLand)).readIndex()).rankings(false,0,1,x,y);
    }

    function getTileName(
        int32 x,
        int32 y
    ) external view returns (string memory) {
        return tileNames[x][y];
    }

    // Return member tiles of a clan as pairs
    function getClanMemberTiles(
        uint64 clanId
    ) external view returns (TileClanInfo[] memory) {
        uint64[] storage arr = clanMemberTiles[clanId];
        TileClanInfo[] memory out = new TileClanInfo[](arr.length);
        for (uint i = 0; i < arr.length; i++) {
            (int32 x, int32 y) = _unpackKey(arr[i]);
            out[i] = TileClanInfo({
                x: x,
                y: y,
                clanId: clanId,
                flagId: clanFlags[clanId]
            });
        }
        return out;
    }

    function getClanMemberCount(uint64 clanId) external view returns (uint8) {
        require(clans[clanId].exists, "Clan does not exist");
        return clans[clanId].memberCount;
    }

    function getClanInfo(
        uint64 clanId
    ) external view returns (ClanInfo memory) {
        return clans[clanId];
    }

    function getTileClan(int32 x, int32 y) external view returns (uint64) {
        return tileClans[x][y];
    }

    function clanCount() external view returns(uint64) { return clanCounter; }
    function getClansPage(uint64 offset, uint64 limit) external view returns (ClanInfo[] memory result) {
        if(!(limit > 0 && limit <= 128))revert InvalidClanPage();
        if (offset >= clanCounter) return new ClanInfo[](0);
        uint64 size = clanCounter - offset;
        if (size > limit) size = limit;
        result = new ClanInfo[](size);
        for (uint64 i; i < size; ++i) result[i] = clans[offset + i + 1];
    }

    function getClanRegion(int32 startX, int32 startY, uint8 width, uint8 height) external view returns (TileClanInfo[] memory result) {
        if(!(width > 0 && width <= 16 && height > 0 && height <= 16))revert InvalidClanRegion();
        if(!(int64(startX) + int64(uint64(width))-1 <= type(int32).max && int64(startY) + int64(uint64(height))-1 <= type(int32).max))revert ClanRegionOverflow();
        result = new TileClanInfo[](uint256(width)*height);
        for (uint32 i; i < width; ++i) for (uint32 j; j < height; ++j) {
            int32 x = startX + int32(i); int32 y = startY + int32(j);
            uint64 id = tileClans[x][y];
            result[uint256(i)*height+j] = TileClanInfo(x,y,id,clanFlags[id]);
        }
    }

    function getBonus(int32 x, int32 y) external view returns (uint8) {
        return tileMapPhaser.bonuses(x,y);
    }

    function isClanNameAvailable(
        string calldata name
    ) external view returns (bool) {
        (bytes32 key,bool nonEmpty)=noticeWriter.nameKey(name);
        return nonEmpty && !clanNameTaken[key];
    }

    function getClanLeaderCoords(
        uint64 clanId
    ) external view returns (int32, int32) {
        require(clans[clanId].exists, "Clan does not exist");
        return (clans[clanId].leaderX, clans[clanId].leaderY);
    }

    function getClanLeaders(uint64[] calldata ids) external view returns (int32[2][] memory leaders) {
        if(!(ids.length <= 256))revert TooManyClanIds();
        leaders = new int32[2][](ids.length);
        for (uint256 i; i < ids.length; i++) leaders[i] = [clans[ids[i]].leaderX, clans[ids[i]].leaderY];
    }

    function getTileClanName(
        int32 x,
        int32 y
    ) external view returns (string memory) {
        uint64 id = tileClans[x][y];
        if (id == 0) return "";
        return clans[id].name;
    }
    /// @notice Bounded clan and realm identity snapshot for reviewed realm purchases.
    function getSaleStateHash(int32 x, int32 y) external view returns (bytes32) {
        uint64 id = tileClans[x][y];
        bytes32 assets;
        if(id!=0&&clans[id].memberCount==1&&theLand.clanWar()!=address(0))assets=IClanWarLifecycle(theLand.clanWar()).getStateHash(id);
        return keccak256(abi.encode(id, clans[id], clanFlags[id], tileNames[x][y],assets));
    }
    /// @notice A sole inactive clan passes intact with its leader realm on a forced sale.
    /// Multi-member clans still choose a replacement through their council.
    function canRecoverInactiveLeader(int32,int32) external pure returns(bool){return false;}
    function canDemolishHall(int32 x,int32 y) external view returns(bool) {
        uint64 id=tileClans[x][y];return id==0 || clans[id].leaderX!=x || clans[id].leaderY!=y;
    }
    // Monotonic invitation identity, including invitations missed while disconnected.
    mapping(uint64 => uint256) public inviteNonceByTile;

    // Append-only state: founding preserves only journeys already started in this membership epoch.
    struct FoundingDeliveries {uint256 lastJourneyId;uint256 epoch;}
    mapping(uint64=>FoundingDeliveries) private foundingDeliveries;
    function preservesFoundingDelivery(int32 x,int32 y,uint256 journeyId) external view returns(bool){
        FoundingDeliveries storage f=foundingDeliveries[_tileKey(x,y)];
        return journeyId!=0&&journeyId<=f.lastJourneyId&&f.epoch!=0&&f.epoch==membershipEpoch[x][y]&&tileClans[x][y]!=0;
    }

 function _indexRealm(int32 x,int32 y) private {address target=IReadIndexSource(address(theLand)).readIndex();if(target!=address(0))IWorldReadIndex(target).syncRealm(x,y);}
 function _indexClan(uint64 id) private {address target=IReadIndexSource(address(theLand)).readIndex();if(target!=address(0))IWorldReadIndex(target).syncClan(id);}
}
