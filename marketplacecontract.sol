// SPDX-License-Identifier: MIT
import "./PublicRPCEvents.sol";
import {WalletClaimStatus} from "./WalletClaimStatus.sol";
pragma solidity 0.8.37;
import "realmsaleprice.sol";
interface IReadActivity {function activity(uint8,int32,int32,int32,int32,uint256) external;}
interface IActivityIndexSource {function readIndex() external view returns(address);}

import {LootAllocation} from "lootallocation.sol";
interface IRelicSpoils {function seizeRealmRelics(uint256,int32,int32,int32,int32) external returns(uint256);}

import {MarketPlaceExtension} from "marketplaceextension.sol";
import "journeyinterfaces.sol";
import "militarycontract.sol";

interface IMilitaryRaid {function raidRealmResourceLimited(int32 ax,int32 ay,int32 dx,int32 dy,uint8 kind,uint256 stock,uint256 percent,uint256 limit) external returns(uint256);}
interface ITheLand {
    function extraFeeRecipient() external view returns(address);
    struct TileDataResponse {
        uint256 food;
        uint256 wood;
        uint256 stone;
        uint256 iron;
        uint256 level;
        uint256 accumulatedTurns;
        uint256 offensiveArmor;
        uint256 defensiveArmor;
        uint256 offensiveWeapon;
        uint256 defensiveWeapon;
        uint256 offensiveSoldier;
        uint256 defensiveSoldier;
        uint16 offensiveTech;
        uint16 defensiveTech;
        uint256 points;
    }

    function getTileData(
        int32 x,
        int32 y
    ) external view returns (TileDataResponse memory);
    function getTotalTurnsUsedByTile(
        int32 x,
        int32 y
    ) external view returns (uint256);
    function getResourceHeadroom(int32 x, int32 y, uint8 resourceType) external view returns (uint256);
    function adjustTileResources(
        int32 x,
        int32 y,
        uint8 resourceType,
        uint256 amount,
        bool isAdding
    ) external;
    function recalculatePointsAfterAttack(int32 x, int32 y) external;

    function hasMarketAtCoord(int32 x, int32 y) external view returns (bool);
    function getTowerCount(int32 x, int32 y) external view returns (uint256);
    function fortificationUnits(int32 x,int32 y) external view returns(uint256);
    function setResourceMessageFlag(int32 x, int32 y, bool value) external;
    function getResourceMessageFlag(
        int32 x,
        int32 y
    ) external view returns (bool);
    function getTileLastActiveAt(
        int32 x,
        int32 y
    ) external view returns (uint256);
}

interface IClan {
    function getTileClan(int32 x, int32 y) external view returns (uint64);
    function getTileClanName(
        int32 x,
        int32 y
    ) external view returns (string memory);
}

interface ITileMapPhaser {
    function lastAcquiredAt(int32 x,int32 y) external view returns(uint256);
    function firstSettledAt(int32 x,int32 y) external view returns(uint256);
    function nativeUnitWei() external view returns (uint256);
    function getTileOccupant(int32 x, int32 y) external view returns (address);
    function tiles(
        int32 x,
        int32 y
    )
        external
        view
        returns (
            bool isOccupied,
            address occupant,
            bool isOnSale,
            uint256 salePrice,
            uint256 saleBurnAmount,
            uint256 lastPurchasePrice
        );
    function setTileOnSale(
        int32 x,
        int32 y,
        bool onSale,
        uint256 salePrice
    ) external;
}

/// @dev Local storage-based guard and native payment accounting; no external dependency.
abstract contract MarketNativePayments  is PublicRPCEvents {
    uint256 private _reentrancyStatus = 1;
    function walletWithdrawalStatus(address account) external view returns(uint256){return WalletClaimStatus.status(account);}
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
        WalletClaimStatus.mark(msg.sender,1);
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit NativePayoutWithdrawn(msg.sender, to, amount);
    }
}

contract MarketPlace is PublicRPCEvents, MarketNativePayments  {
    function _requirePayoutClosed() internal view override {
        if(block.timestamp < IJLand(address(theLand)).worldEndsAt()) revert WorldStillOpen();
    }
    uint256 public immutable nativeUnitWei;
    ITheLand public immutable theLand;

    ITileMapPhaser public immutable tileMapPhaser;
    IClan public immutable clanContract;

    struct ResourceMessage {
        int32 fromX;
        int32 fromY;
        uint8 resourceType;
        uint256 amount;
    }

    mapping(int32 => mapping(int32 => ResourceMessage))
        private resourceMessages;
    mapping(uint64 => uint8) public activeListingsByTile;

    struct MarketItem {
        int32 sellerX;
        int32 sellerY;
        uint8 resourceType;
        uint256 amount;
        uint256 price;
    }

    struct AttackContext {
        int32 ax;
        int32 ay;
        int32 dx;
        int32 dy;
        ITheLand.TileDataResponse atk;
        ITheLand.TileDataResponse def;
        uint attackerPower;
        uint defenderPower;
    }

    struct SoldierCasualties {
        uint256 attOffLoss;
        uint256 attDefLoss;
        uint256 defOffLoss;
        uint256 defDefLoss;
    }

    struct BattleResult {
        SoldierCasualties casualties;
        uint256 totalResourcesStolen;
        bool attackerWon;
    }

    struct WarRecord {
        int32 attackerX;
        int32 attackerY;
        int32 defenderX;
        int32 defenderY;
        uint256 timestamp;
        bool attackerWon;
        uint256 attackerSoldiers;
        uint256 attackerCasualties;
        uint attackerPower;
        uint256 defenderSoldiers;
        uint256 defenderCasualties;
        uint defenderPower;
        uint256 resourcesStolen;
    }

    struct WarRecordPublic {
        int32 attackerX;
        int32 attackerY;
        int32 defenderX;
        int32 defenderY;
        uint256 timestamp;
        bool attackerWon;
    }

    struct WarRecordClan {
        string attackerClanNam;
        string defenderClanNam;
    }

    event ResourcesSent(
        address indexed sender,
        int32 senderX,
        int32 senderY,
        address indexed receiver,
        int32 receiverX,
        int32 receiverY,
        uint8 resourceType
    );

    mapping(uint8 => MarketItem[]) private marketListings;

    uint256 public constant ATTACK_COST_FACTOR = 5;

    mapping(int32 => mapping(int32 => uint256)) public lastAttackTurn;
    mapping(int32 => mapping(int32 => uint256)) public defeatProtectionUntil;
    uint256 public constant NEW_REALM_PROTECTION_DURATION = 14 days;
    uint256 public constant DEFEAT_PROTECTION_DURATION = 72 hours;
    event DefeatProtectionStarted(int32 indexed x, int32 indexed y, uint256 until);

    WarRecord[] private warHistory;
    WarRecordClan[] private warHistoryClan;
    mapping(uint64 => uint256[]) private tileWars;

    uint256 private nextListingId;
    mapping(uint8 => mapping(uint256 => uint256)) private idsAtIndex;
    mapping(uint256 => uint256) private indexOfId;
    mapping(uint64 => uint256) public listingRevision;
    // At most three IDs per realm: raids never scan the global marketplace.
    mapping(uint64 => uint256[]) private realmListingIds;
    mapping(uint256 => uint8) private listingTypes;
    event MarketInventoryChanged(int32 indexed x,int32 indexed y);
    event ListingReturnedForRaid(uint256 indexed id, int32 x, int32 y, uint8 resourceType, uint256 amount);
    struct ListingView { int32 sellerX; int32 sellerY; uint8 resourceType; uint256 amount; uint256 price; uint256 id; bool resourceSaleBlocked; }
    function _listingIndex(uint8 t, uint256 id) private view returns(uint256 i) {
        require(id != 0 && indexOfId[id] != 0, "Listing unavailable");
        i = indexOfId[id]-1;
        require(idsAtIndex[t][i] == id, "Listing unavailable");
    }
    event TileAttacked(
        address indexed attacker,
        int32 attackerX,
        int32 attackerY,
        address indexed defender,
        int32 defenderX,
        int32 defenderY,
        bool attackerWon
    );

    constructor(
        address _theLand,
        address _tileMapPhaser,
        address _clanContract
    ) {
        extension=new MarketPlaceExtension(_theLand,_tileMapPhaser,_clanContract);
        require(
            _theLand.code.length > 0 &&
                _tileMapPhaser.code.length > 0 &&
                _clanContract.code.length > 0,
            "Invalid game contract"
        );
        nativeUnitWei = ITileMapPhaser(_tileMapPhaser).nativeUnitWei();
        theLand = ITheLand(_theLand);

        tileMapPhaser = ITileMapPhaser(_tileMapPhaser);
        clanContract = IClan(_clanContract);
    }

    error ErrOwnsTile();

    error MarketListingLimit(uint256 maximum,uint256 active);
    function _incListings(int32 x, int32 y) internal {
        uint64 k = _tileKey(x, y);
        if(activeListingsByTile[k]>=3)revert MarketListingLimit(3,activeListingsByTile[k]);
        unchecked {
            activeListingsByTile[k]++;
        }
    }

    function _decListings(int32 x, int32 y) internal {
        uint64 k = _tileKey(x, y);
        if (activeListingsByTile[k] > 0) {
            unchecked {
                activeListingsByTile[k]--;
            }
        }
    }

    modifier ownsTile(int32 x, int32 y) {
        if (tileMapPhaser.getTileOccupant(x, y) != msg.sender)
            revert ErrOwnsTile();
        _;
    }

    error TargetRecentlyActive();
    error TargetUnoccupied();
    error TargetAlreadyOnSale();

    error RealmSalesDisabled();
    function maybeAutoListIfInactive(int32,int32,int32,int32) external pure {revert RealmSalesDisabled();}

    function _tileKey(int32 x, int32 y) internal pure returns (uint64) {
        return (uint64(uint32(x)) << 32) | uint64(uint32(y));
    }

    // -------------------- LIST AN ITEM FOR SALE --------------------
    error RecipientStorageExceeded();
    error RecipientUnoccupied();
    function getRecipientHeadroom(int32 x, int32 y, uint8 resourceType) external view returns(uint256) {
        if (tileMapPhaser.getTileOccupant(x,y) == address(0)) revert RecipientUnoccupied();
        return theLand.getResourceHeadroom(x,y,resourceType);
    }
    

    function _removeListingAt(uint8 resourceType, uint256 index) internal {
        MarketItem storage removed = marketListings[resourceType][index];
        uint256 removedId = idsAtIndex[resourceType][index];
        uint256[] storage realmIds = realmListingIds[_tileKey(removed.sellerX,removed.sellerY)];
        for (uint256 j; j < realmIds.length; ++j) if (realmIds[j] == removedId) {
            realmIds[j] = realmIds[realmIds.length-1];
            realmIds.pop();
            break;
        }
        delete listingTypes[removedId];
        if (resourceType <= 4) reservedResources[removed.sellerX][removed.sellerY][resourceType] -= removed.amount;
        listingRevision[_tileKey(removed.sellerX,removed.sellerY)]++; emit MarketInventoryChanged(removed.sellerX,removed.sellerY);
        uint256 last = marketListings[resourceType].length - 1;
        delete indexOfId[idsAtIndex[resourceType][index]];
        if (index != last) {
            uint256 moved = idsAtIndex[resourceType][last];
            idsAtIndex[resourceType][index] = moved;
            if (moved != 0) indexOfId[moved] = index+1;
            marketListings[resourceType][index] = marketListings[resourceType][
                last
            ];
        }
        delete idsAtIndex[resourceType][last];
        marketListings[resourceType].pop();
    }

    

    // -------------------- BUY AN ITEM FROM MARKET --------------------
    

    

    function _absDiff(int32 a, int32 b) internal pure returns (uint64) {
        return uint64(a > b ? int64(a) - int64(b) : int64(b) - int64(a));
    }

    function _starterSeconds(int32 x, int32 y) internal view returns (uint256) {
        uint256 settled = tileMapPhaser.firstSettledAt(x,y);
        if (settled == 0) return 0;
        uint256 until = settled + NEW_REALM_PROTECTION_DURATION;
        return until > block.timestamp ? until - block.timestamp : 0;
    }
    /// @notice Independent starter and defeat shields; both use chain time.
    function getDefenderProtection(int32 x, int32 y) external view returns (uint256 starterSecondsRemaining, uint256 protectedUntil, uint256 secondsRemaining) {
        starterSecondsRemaining = _starterSeconds(x,y);
        protectedUntil = defeatProtectionUntil[x][y];
        secondsRemaining = protectedUntil > block.timestamp ? protectedUntil - block.timestamp : 0;
    }
    error AttackerProtected();
    error FriendlyClanAttack();
    error EnemyClanRequired();
    error InvalidWarPage();
    error EnemyClanDelivery();
    error ClanFriendshipRequired();
    /// @notice Shared by resource departure and acceptance; no cargo or clan state is mutated.
    function requireResourceDiplomacy(int32 sx,int32 sy,int32 tx,int32 ty) external view {
        uint64 source=clanContract.getTileClan(sx,sy);uint64 target=clanContract.getTileClan(tx,ty);
        if(source==0||target==0||source==target)return;
        address warfare=IJLand(address(theLand)).clanWar();
        if(warfare==address(0))revert ClanFriendshipRequired();
        (uint8 relation,,)=IClanGovernance(warfare).relationship(source,target);
        if(relation==2)revert EnemyClanDelivery();
        if(relation!=1)revert ClanFriendshipRequired();
    }
    function _validateAttack(
        int32 ax,
        int32 ay,
        int32 dx,
        int32 dy,
        address attacker,
        address defender,
        bool checkProtection
    ) internal view {
        require(defender != attacker, "");
        // Protection prevents receiving attacks; the attacker keeps their own shield.

        uint64 attackerClanId = clanContract.getTileClan(ax, ay);
        uint64 defenderClanId = clanContract.getTileClan(dx, dy);

        require(
            attackerClanId == 0 ||
                defenderClanId == 0 ||
                attackerClanId != defenderClanId,
            "c"
        );

        // Cross-clan personal raids obey the same Enemy requirement as collective armies.
        if(attackerClanId!=0&&defenderClanId!=0){
            address warfare=IJLand(address(theLand)).clanWar();
            if(warfare==address(0))revert EnemyClanRequired();
            (uint8 relation,,)=IClanGovernance(warfare).relationship(attackerClanId,defenderClanId);
            if(relation==1)revert FriendlyClanAttack();
            if(relation!=2)revert EnemyClanRequired();
        }
        uint64 distance = uint64(_absDiff(ax, dx) + _absDiff(ay, dy));
        require(distance > 0, "");

        require(
            theLand.getTotalTurnsUsedByTile(ax, ay) >=
                lastAttackTurn[ax][ay] + 150,
            ""
        );
        require(
            !checkProtection || _starterSeconds(dx,dy) == 0,
            "Defender starter protection: 14 days"
        );
        require(!checkProtection || block.timestamp >= defeatProtectionUntil[dx][dy], "Defender defeat protection: 72 hours");
    }

    error InvalidAttackForce();

    modifier onlyLogistics() { require(msg.sender==IJLand(address(theLand)).logistics(),"Only Logistics"); _; }
    function prepareExpedition(int32 ax,int32 ay,int32 dx,int32 dy,uint256 off,uint256 def)  external nonReentrant onlyLogistics { IJLand(address(theLand)).requireWorldActive(); 
        _validateAttack(ax,ay,dx,dy,tileMapPhaser.getTileOccupant(ax,ay),tileMapPhaser.getTileOccupant(dx,dy),false);
        if(off<100) revert InvalidAttackForce();
        ITheLand.TileDataResponse memory atk;
        atk.offensiveSoldier=off;atk.defensiveSoldier=def;
        _payAttackResourceCost(ax,ay,uint64(_absDiff(ax,dx)+_absDiff(ay,dy)),atk);
    }
    function resolveExpedition(uint256 id,int32 ax,int32 ay,int32 dx,int32 dy,uint256 off,uint256 def) rpcIndexed external nonReentrant onlyLogistics returns(uint256[2] memory losses,uint256[4] memory loot) { IJLand(address(theLand)).requireWorldActive(); 
        address attacker=tileMapPhaser.getTileOccupant(ax,ay);
        address defender=tileMapPhaser.getTileOccupant(dx,dy);
        require(defender!=address(0),"Unoccupied target");
        _validateAttack(ax,ay,dx,dy,attacker,defender,true);
        AttackContext memory ctx;ctx.ax=ax;ctx.ay=ay;ctx.dx=dx;ctx.dy=dy;
        ctx.atk=theLand.getTileData(ax,ay);ctx.def=theLand.getTileData(dx,dy);
        ctx.atk.offensiveSoldier=off;ctx.atk.defensiveSoldier=def;
        uint256[4] memory cavalry=IJStable(IJLand(address(theLand)).stable()).inventory(dx,dy);
        ctx.def.offensiveSoldier+=cavalry[2];ctx.def.defensiveSoldier+=cavalry[3];
        IRealmFeatures features=IRealmFeatures(IJLand(address(theLand)).stable());
        (ctx.attackerPower,ctx.defenderPower)=features.combatPowers(ax,ay,dx,dy,off,def);
        uint256[4] memory loss=features.battleLosses([off,def],[ctx.def.offensiveSoldier,ctx.def.defensiveSoldier],ctx.attackerPower,ctx.defenderPower,theLand.fortificationUnits(dx,dy));
        SoldierCasualties memory casualties=SoldierCasualties(loss[0],loss[1],loss[2],loss[3]);
        uint256 mountedOff=ctx.def.offensiveSoldier==0?0:casualties.defOffLoss*cavalry[2]/ctx.def.offensiveSoldier;
        uint256 mountedDef=ctx.def.defensiveSoldier==0?0:casualties.defDefLoss*cavalry[3]/ctx.def.defensiveSoldier;
        if(casualties.defOffLoss>mountedOff)theLand.adjustTileResources(dx,dy,9,casualties.defOffLoss-mountedOff,false);
        if(casualties.defDefLoss>mountedDef)theLand.adjustTileResources(dx,dy,10,casualties.defDefLoss-mountedDef,false);
        IJStable(IJLand(address(theLand)).stable()).loseDefenders(dx,dy,mountedOff,mountedDef);
        BattleResult memory result;result.casualties=casualties;result.attackerWon=ctx.attackerPower>ctx.defenderPower;
        if(result.attackerWon) _captureRelics(id,ctx);
        _finalizeAttack(ctx,result,attacker,defender);
        losses=[casualties.attOffLoss,casualties.attDefLoss];
    }

    function resolveExpeditionTyped(uint256 id,int32 ax,int32 ay,int32 dx,int32 dy,uint256[4] calldata army) internal nonReentrant onlyLogistics returns(uint256[4] memory losses,uint256[4] memory loot){
        address attacker=tileMapPhaser.getTileOccupant(ax,ay);address defender=tileMapPhaser.getTileOccupant(dx,dy);require(defender!=address(0),"Unoccupied target");_validateAttack(ax,ay,dx,dy,attacker,defender,true);
        AttackContext memory ctx;ctx.ax=ax;ctx.ay=ay;ctx.dx=dx;ctx.dy=dy;ctx.atk=theLand.getTileData(ax,ay);ctx.def=theLand.getTileData(dx,dy);
        IJLand l=IJLand(address(theLand));Military m=Military(l.military());uint256[4] memory cav=IJStable(l.stable()).inventory(dx,dy);
        uint256[4] memory defending=[ctx.def.offensiveSoldier,ctx.def.defensiveSoldier,cav[2],cav[3]];
        Military.Summary memory o=m.resolve(id,ax,ay,dx,dy,0,army,defending);
        ctx.atk.offensiveSoldier=o.sent;ctx.atk.defensiveSoldier=0;ctx.def.offensiveSoldier=o.defenders;ctx.def.defensiveSoldier=0;
        SoldierCasualties memory casualties=SoldierCasualties(o.attackerLosses,0,o.defenderLosses,0);
        for(uint8 i;i<4;i++)losses[i]=o.attackLoss[i];
        if(o.defenseLoss[0]>0)theLand.adjustTileResources(dx,dy,9,o.defenseLoss[0],false);if(o.defenseLoss[1]>0)theLand.adjustTileResources(dx,dy,10,o.defenseLoss[1],false);
        if(o.defenseLoss[2]>0||o.defenseLoss[3]>0)IJStable(l.stable()).loseDefenders(dx,dy,o.defenseLoss[2],o.defenseLoss[3]);
        ctx.attackerPower=o.attackPower;ctx.defenderPower=o.defensePower;BattleResult memory result;result.casualties=casualties;result.attackerWon=o.attackPower>o.defensePower;
        relicLootEncoded[id]=1+(result.attackerWon?_captureRelics(id,ctx):0);warJourneyIds[warHistory.length]=id;_finalizeAttack(ctx,result,attacker,defender);
    }
    function _finalizeAttack(
        AttackContext memory ctx,
        BattleResult memory result,
        address attacker,
        address defender
    ) internal {
        lastAttackTurn[ctx.ax][ctx.ay] = theLand.getTotalTurnsUsedByTile(
            ctx.ax,
            ctx.ay
        );

        if (result.attackerWon) {
            uint256 until = block.timestamp + DEFEAT_PROTECTION_DURATION;
            defeatProtectionUntil[ctx.dx][ctx.dy] = until;
            emit DefeatProtectionStarted(ctx.dx, ctx.dy, until);
        }

        theLand.recalculatePointsAfterAttack(ctx.ax, ctx.ay);
        theLand.recalculatePointsAfterAttack(ctx.dx, ctx.dy);

        bool attackerWon = result.attackerWon;

        string memory attackerClanNamX = clanContract.getTileClanName(
            ctx.ax,
            ctx.ay
        );
        string memory defenderClanNamX = clanContract.getTileClanName(
            ctx.dx,
            ctx.dy
        );

        warHistory.push(
            WarRecord({
                attackerX: ctx.ax,
                attackerY: ctx.ay,
                defenderX: ctx.dx,
                defenderY: ctx.dy,
                timestamp: block.timestamp,
                attackerWon: result.attackerWon,
                attackerSoldiers: ctx.atk.offensiveSoldier +
                    ctx.atk.defensiveSoldier,
                attackerCasualties: result.casualties.attOffLoss +
                    result.casualties.attDefLoss,
                attackerPower: ctx.attackerPower,
                defenderSoldiers: ctx.def.offensiveSoldier +
                    ctx.def.defensiveSoldier,
                defenderCasualties: result.casualties.defOffLoss +
                    result.casualties.defDefLoss,
                defenderPower: ctx.defenderPower,
                resourcesStolen: result.totalResourcesStolen
            })
        );

        warHistoryClan.push(
            WarRecordClan({
                attackerClanNam: attackerClanNamX,
                defenderClanNam: defenderClanNamX
            })
        );

        uint256 warIndex = warHistory.length - 1;

        tileWars[_tileKey(ctx.ax, ctx.ay)].push(warIndex);
        tileWars[_tileKey(ctx.dx, ctx.dy)].push(warIndex);

        {_recordRPCRecipient(defender);emit TileAttacked(
            attacker,
            ctx.ax,
            ctx.ay,
            defender,
            ctx.dx,
            ctx.dy,
            attackerWon
        );}
        address readProjection=IActivityIndexSource(address(theLand)).readIndex();if(readProjection!=address(0))IReadActivity(readProjection).activity(1,ctx.ax,ctx.ay,ctx.dx,ctx.dy,0);
    }

    function _payAttackResourceCost(
        int32 ax,
        int32 ay,
        uint64 distance,
        ITheLand.TileDataResponse memory atk
    ) internal {
        uint256 totalCost = ATTACK_COST_FACTOR *
            distance *
            (atk.offensiveSoldier + atk.defensiveSoldier);
        theLand.adjustTileResources(ax, ay, 1, (totalCost * 40) / 100, false);
        theLand.adjustTileResources(ax, ay, 2, (totalCost * 30) / 100, false);
        theLand.adjustTileResources(ax, ay, 3, (totalCost * 20) / 100, false);
        theLand.adjustTileResources(ax, ay, 4, (totalCost * 10) / 100, false);
    }

    function _min(uint a, uint b) internal pure returns (uint) {
        return a < b ? a : b;
    }

    function _max(uint a, uint b) internal pure returns (uint) {
        return a > b ? a : b;
    }

    function _stealResources(
        AttackContext memory ctx,uint256 carry
    ) internal returns (uint256[4] memory loot) {
        uint margin = ctx.attackerPower > ctx.defenderPower
            ? ctx.attackerPower - ctx.defenderPower
            : ctx.defenderPower - ctx.attackerPower;
        uint totalPower = ctx.attackerPower + ctx.defenderPower;
        require(totalPower > 0, "");
        uint rawStealPercent = (margin * 100) / totalPower;
        uint stealPercent = _capBetween(rawStealPercent + 30, 10, 40);

        uint256[4] memory returned = _returnRaidListings(ctx.dx,ctx.dy);
        uint256[4] memory stock = [ctx.def.food,ctx.def.wood,ctx.def.stone,ctx.def.iron];
        address logistics = IJLand(address(theLand)).logistics();
        (uint256[8] memory cargo,) = IJLogistics(logistics).returnedAssets(ctx.dx,ctx.dy,0);
        uint256[4] memory limits;
        for (uint8 i; i<4; ++i) {
            uint256 total = stock[i]+returned[i]+cargo[i];
            limits[i] = total>1 ? _min(total*stealPercent/100,theLand.getResourceHeadroom(ctx.ax,ctx.ay,i+1)) : 0;
        }
        uint256[4] memory allocation = LootAllocation.allocate(limits,carry);
        for (uint8 t=1; t<=4; ++t) if (allocation[t-1]>0) {
            loot[t-1] = IMilitaryRaid(logistics).raidRealmResourceLimited(ctx.ax,ctx.ay,ctx.dx,ctx.dy,t,stock[t-1]+returned[t-1],stealPercent,allocation[t-1]);
        }

        return loot;
    }

    /// @dev Successful raids close raw-resource listings without a cancellation fee.
    /// Returning stock before loot keeps storage and stale-buy protections unchanged.
    function _returnRaidListings(int32 x,int32 y) private returns(uint256[4] memory returned) {
        uint256[] storage ids = realmListingIds[_tileKey(x,y)];
        uint256 i = ids.length;
        while (i > 0) {
            uint256 id = ids[--i];
            uint8 t = listingTypes[id];
            if (t > 4) continue;
            uint256 index = _listingIndex(t,id);
            uint256 amount = marketListings[t][index].amount;
            _removeListingAt(t,index);
            _decListings(x,y);
            theLand.adjustTileResources(x,y,t,amount,true);
            returned[t-1] += amount;
            emit ListingReturnedForRaid(id,x,y,t,amount);
        }
    }

    function _stealOneResource(
        uint8 resourceType,
        uint256 defAmount,
        int32 ax,
        int32 ay,
        int32 dx,
        int32 dy,
        uint stealPercent
    ) internal returns (uint256 stolen) {
        return IJLogistics(IJLand(address(theLand)).logistics()).raidRealmResource(ax,ay,dx,dy,resourceType,defAmount,stealPercent);
    }

    function _capBetween(
        uint value,
        uint minVal,
        uint maxVal
    ) internal pure returns (uint) {
        if (value < minVal) return minVal;
        if (value > maxVal) return maxVal;
        return value;
    }


    function _warIndex(bool personal, uint64 key, uint256 i) private view returns(uint256) {
        return personal ? tileWars[key][i] : i;
    }
    function _warBound(bool personal,uint64 key,uint256 n,uint256 ts,bool upper) private view returns(uint256 lo) {
        uint256 hi=n;
        while(lo<hi){uint256 mid=lo+(hi-lo)/2;uint256 t=warHistory[_warIndex(personal,key,mid)].timestamp;
            if(t<ts || (upper && t==ts))lo=mid+1;else hi=mid;
        }
    }
    function _warPage(bool personal,uint64 key,uint256 fromTs,uint256 toTs,uint256 offset,uint256 limit)
        private view returns(uint256 end,uint256 count,uint256 total) {
        if(limit==0 || limit>50)revert InvalidWarPage();
        if(toTs==0)toTs=block.timestamp;
        if(fromTs>toTs)revert InvalidWarPage();
        uint256 n=personal?tileWars[key].length:warHistory.length;
        uint256 start=_warBound(personal,key,n,fromTs,false);
        end=_warBound(personal,key,n,toTs,true);total=end-start;
        if(offset>=total)return(end,0,total);
        end-=offset;count=total-offset;if(count>limit)count=limit;
    }
    
    

    function getMyResourceMessage(
        int32 x,
        int32 y
    )
        external
        view
        ownsTile(x, y) // ✅ only the tile’s current owner can call
        returns (ResourceMessage memory)
    {
        return resourceMessages[x][y];
    }
    mapping(int32 => mapping(int32 => mapping(uint8 => uint256))) public reservedResources;

    /// Fixed delegate module; no setter and no administrator upgrade route.
    MarketPlaceExtension public immutable extension;
    fallback() external payable {address target=address(extension);assembly("memory-safe"){let ptr:=mload(0x40) calldatacopy(ptr,0,calldatasize()) let ok:=delegatecall(gas(),target,ptr,calldatasize(),0,0) returndatacopy(ptr,0,returndatasize()) switch ok case 0 {revert(ptr,returndatasize())} default {return(ptr,returndatasize())}}}
    mapping(uint256=>uint256) private warJourneyIds;
    mapping(uint256=>uint256) private relicLootEncoded;
    function journeyRelicLoot(uint256 id) external view returns(uint256 amount,bool relicOnly){uint256 value=relicLootEncoded[id];return(value==0?0:value-1,value!=0);}
    function _captureRelics(uint256 id,AttackContext memory ctx) private returns(uint256) {
        return IRelicSpoils(address(theLand)).seizeRealmRelics(id,ctx.ax,ctx.ay,ctx.dx,ctx.dy);
    }

}
