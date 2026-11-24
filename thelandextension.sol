// SPDX-License-Identifier: MIT
import "./PublicRPCEvents.sol";
import {WalletClaimStatus} from "./WalletClaimStatus.sol";
import "DirectReadIndex.sol";
import "RelicProduction.sol";
import "RelicSettlement.sol";
import "JourneyLootEscrow.sol";
pragma solidity 0.8.37;
import "realmscorerules.sol";
interface IReadActivity {function activity(uint8,int32,int32,int32,int32,uint256) external;}
interface IActivityIndexSource {function readIndex() external view returns(address);}

interface IWorldReadIndex {function syncRealmScore(int32,int32,uint256,uint256) external;function inventoryChanged(int32,int32) external;function syncRealm(int32,int32) external;function syncClan(uint64) external;function syncRoute(uint256) external;}
interface IReadIndexSource {function readIndex() external view returns(address);}

import "researchmath.sol";
import "depotrules.sol";
import "journeyinterfaces.sol";
import {IArmySlots} from "ArmySlots.sol";
import {IClanHallLevels} from "ClanHallLevels.sol";
import "configurationchecks.sol";
import "militarycatalog.sol";
interface IWorldRewards { function land() external view returns(address); function map() external view returns(address); function initialPool() external view returns(uint256); }
interface ILandMilitary {function inventory(int32 x,int32 y) external view returns(uint256[20] memory,uint256[15] memory);function inventoryHash(int32 x,int32 y) external view returns(bytes32);function adjustEquipment(int32 x,int32 y,uint8 item,uint256 amount,bool adding) external;}

interface ITileMapPhaser {
    function hasOccupiedTile(address) external view returns(bool);
    function getOccupiedTileByAddress(address) external view returns(int32[2] memory);
    function nativeUnitWei() external view returns (uint256);
    function getTileOccupant(int32 x, int32 y) external view returns (address);
}

interface IMarketListings { function reservedResources(int32 x,int32 y,uint8 t) external view returns(uint256); function activeListingsByTile(uint64 key) external view returns (uint8); }

interface IClanWar {
    function recordTurnFee(int32 x, int32 y, uint16 turns) external payable;
}
interface IClan {
    function getTileClan(int32 x, int32 y) external view returns (uint64);
    function canDemolishHall(int32 x,int32 y) external view returns(bool);
    function getSaleStateHash(int32 x, int32 y) external view returns (bytes32);
    function getBonus(int32 x, int32 y) external view returns (uint8);
}

/// @dev Local storage-based guard and native payment accounting; no external dependency.
abstract contract LandNativePayments  is PublicRPCWriter {
    uint256 private _reentrancyStatus = 1;
    mapping(address => uint256) public nativePayouts;
    uint256 public totalNativePayouts;
    uint256 public lockedNative;

    error ReentrantCall();
    error NoNativePayout();
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
        if(amount==0)revert NoNativePayout();
        nativePayouts[msg.sender] = 0;
        totalNativePayouts -= amount;
        WalletClaimStatus.mark(msg.sender,1);
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
        emit NativePayoutWithdrawn(msg.sender, to, amount);
    }
}

contract TheLandExtension is PublicRPCWriter, LandNativePayments  {
    function _requirePayoutClosed() internal view override {
        if(block.timestamp < IJLand(address(this)).worldEndsAt()) revert WorldStillOpen();
    }
    ITileMapPhaser public immutable tileMapPhaser;
    IClan internal _clan;
    uint256 internal constant initialInteriorCells = 9;
    uint256 internal constant turnsPerLevel = 250; // Base requirement; each completed level adds five turns
    uint256 internal turnFeeWei = 0.0001 ether;
    uint256 internal immutable rewardUnit;
    uint256 internal rewardPool;
    event RewardsFunded(address indexed funder, uint256 amount);
    uint256 internal rewardsStart;
    uint256 internal TXCounter;
    mapping(int32 => mapping(int32 => uint256)) internal totalTurnsUsedByTile;

    mapping(int32 => mapping(int32 => bool)) internal hasClanHallAt;
    mapping(int32 => mapping(int32 => bool)) internal hasMarketAt;

    mapping(int32 => mapping(int32 => uint256)) internal pointsByCoords;
    uint64[] private rankedTiles;
    mapping(uint64 => uint256) private rankPosition;

    mapping(int32 => mapping(int32 => bool)) internal resourceMessage;

    address internal owner; // Owner of the contract
    address internal marketplaceAddress; // Owner of the contract
    address internal extraFeeRecipient;
    address internal switcher;

    bool private _useTurnsPaused;

    bool private _switch;

    struct Resources {
        uint256 food;
        uint256 wood;
        uint256 stone;
        uint256 iron;
    }

    struct Military {
        uint256 offensiveArmor;
        uint256 defensiveArmor;
        uint256 offensiveWeapon;
        uint256 defensiveWeapon;
        uint256 offensiveSoldier;
        uint256 defensiveSoldier;
    }

    struct TechLevels {
        uint16 offensiveTech;
        uint16 defensiveTech;
    }

    struct TileData {
        Resources resources;
        uint256 level;
        uint256 accumulatedTurns;
        uint16 turns;
        uint256 start;
        Military military;
        TechLevels techLevels;
        uint256 points;
    }

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

    struct TilePublicResponse {
        uint256 level;
        uint256 points;
    }

    Resources internal baseOffensiveArmorCost = Resources(72, 72, 60, 108);
    Resources internal baseDefensiveArmorCost = Resources(90, 90, 60, 240);
    Resources internal baseOffensiveWeaponCost = Resources(72, 108, 60, 180);
    Resources internal baseDefensiveWeaponCost = Resources(90, 120, 60, 150);
    Resources internal baseOffensiveSoldierCost = Resources(240, 120, 90, 60);
    Resources internal baseDefensiveSoldierCost = Resources(240, 120, 90, 60);

    mapping(int32 => mapping(int32 => TileData)) private tiles;

    mapping(int32 => mapping(int32 => mapping(int128 => mapping(int128 => uint8))))
        private interiorMaps; // Sparse interior buildings, centered on (0, 0).
    mapping(int32 => mapping(int32 => uint256[13])) private buildingCounts;
    event InteriorExpanded(int32 indexed x, int32 indexed y, uint256 level);
    event InteriorCellChanged(int32 indexed x, int32 indexed y, int128 ix, int128 iy);
    event RealmScoreChanged(int32 indexed x, int32 indexed y, uint256 points);

    uint256 internal constant BASE_STORAGE_CAPACITY = 60000;
    uint256 internal constant SILO_CAPACITY_PER_LEVEL = 40000;
    mapping(int32 => mapping(int32 => mapping(int128 => mapping(int128 => uint256)))) internal siloLevels;
    mapping(int32 => mapping(int32 => uint256)) internal totalSiloLevels;

    struct BuildingCost {
        uint256 food;
        uint256 wood;
        uint256 stone;
        uint256 iron;
    }

    mapping(uint8 => BuildingCost) internal buildingCosts;
    mapping(int32 => mapping(int32 => mapping(int128 => mapping(int128 => uint256)))) internal relicForgeLevels;
    mapping(int32 => mapping(int32 => uint256)) internal relicBalances;
    uint256 internal totalRelics;
    mapping(int32 => mapping(int32 => uint256)) private turnAccruedAt;
    bool internal gameConfigurationFinalized;
    function finalizeGameConfiguration() internal onlyOwner {
        if(marketplaceAddress.code.length == 0 || address(_clan).code.length == 0) revert ConfigurationSealed();
        if (!(extraFeeRecipient != address(0) && extraFeeRecipient != address(this))) revert InvalidTreasury();
        if(worldRewards == address(0)) revert ConfigurationSealed();
        gameConfigurationFinalized = true;
        owner = address(0);
        switcher = address(0);
        _useTurnsPaused = false;
    }
    event RelicsProduced(address indexed player, uint256 quantity);
    event RelicsRedeemed(address indexed player, uint256 quantity, uint256 reward);
    event FinalRelicSettlement(uint256 pool,uint256 supply);
    event ForgeUpdated(int32 indexed x,int32 indexed y);
    event RelicForgeUpgraded(int32 x, int32 y, int128 interiorX, int128 interiorY, uint256 level);

    event TurnsUsed(address indexed user, uint256 turnsUsed, int32 x, int32 y);
    event RemainderSent(address recipient, uint256 amount, bool success);

    ResearchMath public immutable researchMath;
    constructor(address _tileMapPhaser, address _switcher) {
        researchMath = new ResearchMath();
        require(
            _tileMapPhaser.code.length > 0 && _switcher != address(0),
            "Invalid game address"
        );
        rewardUnit = ITileMapPhaser(_tileMapPhaser).nativeUnitWei();
        tileMapPhaser = ITileMapPhaser(_tileMapPhaser);
        // Costs live in TheLand storage. Delegate calls use that initialized table;
        // copying it into the view/extension deployment is unused and bloats initcode.
        owner = msg.sender;

        rewardsStart = block.timestamp;
    }

    modifier whenUseTurnsNotPaused() {
        if(_useTurnsPaused)revert GamePaused();
        _;
    }

    function isUseTurnsPaused() internal view returns (bool) {
        return _useTurnsPaused;
    }


    error InsufficientEquipment();
    error GamePaused();
    error NotSwitcher();
    error NotOwner();
    error ClanMustDisband();
    error ActiveMarketListings();
    error SiloStorageInUse();
    error InsufficientForgeResources();
    error ForgeQuoteChanged();
    error RewardPoolReserved();
    error ConfigurationSealed();
    error InvalidTreasury();
    error TreasuryTransferFailed();
    error RewardQuoteChanged();
    error InvalidCoord();
    error InteriorCellLocked();
    error StorageCapacityExceeded();
    error RawResourceOnly();
    error InvalidQuantity();
    error InvalidTurns();
    error WrongBuilding();
    error InvalidBuildingType();
    error BuildingLimitReached();
    error ZeroAddress();
    error ZeroAmount();
    error BadFee();
    error NotMarketplace();
    error NotOwnerOrMarketplace();

    modifier ownerOrMarketplace(int32 x, int32 y) {
        address occ = tileMapPhaser.getTileOccupant(x, y);
        if (
            msg.sender != occ && msg.sender != logistics && msg.sender != stable && msg.sender != military &&
            (marketplaceAddress == address(0) ||
                msg.sender != marketplaceAddress)
        ) {
            revert NotOwnerOrMarketplace();
        }
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }


    function _isValidBuilding(uint8 t) internal pure returns (bool) {
        return (t >= 1 && t <= 18);
    }


    function setMarketAddress(address _market) internal onlyOwner {
        if (!(!gameConfigurationFinalized && _switch == false)) revert ConfigurationSealed();
        marketplaceAddress = _market;
    }

    function setExtraFeeReceiver(address _address) internal onlyOwner {
        if (!(!gameConfigurationFinalized)) revert ConfigurationSealed();
        extraFeeRecipient = _address;
    }

    function setClanAddress(address _clanAddress) internal onlyOwner {
        if (!(!gameConfigurationFinalized && _switch == false)) revert ConfigurationSealed();
        _clan = IClan(_clanAddress);
    }

    function _initializeBuildingCosts() internal {
        buildingCosts[1] = BuildingCost(992, 2560, 1152, 704); // Armory
        buildingCosts[2] = BuildingCost(1040, 2400, 1040, 720); // Blacksmith
        buildingCosts[3] = BuildingCost(1760, 4200, 1960, 1320); // Clan Hall
        buildingCosts[4] = BuildingCost(992, 2240, 992, 752); // Fighting Pit
        buildingCosts[5] = BuildingCost(400, 1040, 450, 230); // House (unchanged)
        buildingCosts[6] = BuildingCost(1168, 2496, 1168, 704); // Market
        buildingCosts[7] = BuildingCost(2780, 6400, 12200, 2340); // Tower
        buildingCosts[18] = BuildingCost(11120, 25600, 48800, 9360); // Castle
        buildingCosts[8] = BuildingCost(1680, 3680, 1880, 1360); // Workshop
        buildingCosts[9] = BuildingCost(1000, 2500, 2000, 1000); // Silo
        buildingCosts[13] = BuildingCost(14400, 36000, 28800, 21600); // Arsenal
        buildingCosts[14] = BuildingCost(18000, 48000, 24000, 14400); // Logistics Depot
        buildingCosts[12] = BuildingCost(60000, 40000, 40000, 30000); // Intelligence Center; one per realm
        buildingCosts[11] = BuildingCost(1800, 3600, 1800, 1200); // Stable
        buildingCosts[10] = BuildingCost(48000, 48000, 48000, 48000); // Relic Forge
    }

    // Preserve the independent turn-regeneration cursor, including a fresh realm's 600 turns.
    function _touchActivity(int32 x,int32 y) private {if(turnAccruedAt[x][y]==0)_calcTurn(x,y);}
    modifier activeTile(int32 x,int32 y) { _touchActivity(x,y); _; }
    modifier ownsTile(int32 x, int32 y) {
        if(!(tileMapPhaser.getTileOccupant(x, y) == msg.sender)) revert NotOwner();
        _;
    }

    modifier ownerOrStable(int32 x,int32 y) {
        if(!(msg.sender==stable || msg.sender==tileMapPhaser.getTileOccupant(x,y))) revert NotOwner(); _;
    }
    modifier validInteriorTile(int32 mainX, int32 mainY, int128 interiorX, int128 interiorY) {
        if(!isInteriorUnlocked(mainX, mainY, interiorX, interiorY)) revert InteriorCellLocked();
        _;
    }

    /// @notice Zero-based, contiguous square spiral. The first nine cells form a 3x3 square.
    function interiorSpiralIndex(int128 x, int128 y) internal pure returns (uint256) {
        // int128 minimum is rejected below. For r <= 2^127-1, the largest index is (2r+1)^2-1 < 2^256.
        unchecked {
        if(!(x != type(int128).min && y != type(int128).min)) revert InvalidCoord();
        uint256 ax = uint256(x < 0 ? -int256(x) : int256(x));
        uint256 ay = uint256(y < 0 ? -int256(y) : int256(y));
        uint256 r = ax > ay ? ax : ay;
        if (r == 0) return 0;
        int256 radius = int256(r);
        uint256 side = 2 * r;
        uint256 base = (side - 1) * (side - 1);
        if (int256(x) == radius && int256(y) >= 1 - radius)
            return base + uint256(int256(y) + radius - 1);
        if (int256(y) == radius)
            return base + side + uint256(radius - 1 - int256(x));
        if (int256(x) == -radius)
            return base + 2 * side + uint256(radius - 1 - int256(y));
        return base + 3 * side + uint256(int256(x) + radius - 1);
            }
    }

    function isInteriorUnlocked(int32 mainX, int32 mainY, int128 x, int128 y) internal view returns (bool) {
        uint256 index = interiorSpiralIndex(x, y);
        return index < initialInteriorCells || index - (initialInteriorCells - 1) <= tiles[mainX][mainY].level;
    }

    // Accelerated local testing; restore the production cadence before mainnet.
    function TURN_REGEN_SECONDS() internal view returns(uint256) { return block.chainid == 31337 ? 1 : 600; }
    // Accelerate only the local test chain; other chain IDs keep their previous rate.
    function TURN_REGEN_AMOUNT() internal view returns (uint256) { return block.chainid == 31337 ? 100 : 1; }
    function _turnState(int32 x, int32 y) private view returns (uint16 available, uint256 cursor) {
        uint256 end = IJLand(address(this)).worldEndsAt();
        if(block.timestamp >= end) return (0, end);
        TileData storage t = tiles[x][y];
        cursor = turnAccruedAt[x][y];
        if (cursor == 0) cursor = t.start;
        if (cursor == 0) return (600, block.timestamp);
        uint256 elapsed = (block.timestamp - cursor) / TURN_REGEN_SECONDS();
        uint256 total = uint256(t.turns) + elapsed * TURN_REGEN_AMOUNT();
        if (total >= 600) return (600, block.timestamp);
        return (uint16(total), cursor + elapsed * TURN_REGEN_SECONDS());
    }
    function getTurn(int32 x, int32 y) internal view ownsTile(x,y) returns (uint256) {
        (uint16 available,) = _turnState(x,y); return available;
    }
    function calcTurn(int32 x, int32 y) internal nonReentrant ownsTile(x,y) { _calcTurn(x,y); }
    function _calcTurn(int32 x, int32 y) internal {
        (uint16 available, uint256 cursor) = _turnState(x,y);
        tiles[x][y].turns = available;
        turnAccruedAt[x][y] = cursor;
    }


    function produceArmor(int32,int32,uint8,uint256) external pure { revert("Legacy military retired"); }
    function produceWeapon(int32,int32,uint8,uint256) external pure { revert("Legacy military retired"); }
    function _equipment(int32 x,int32 y,uint8 kind,uint256 n,bool armor) private {
        if(n==0||n>1000||kind<1||kind>2)revert InvalidQuantity();uint256 count=buildingCounts[x][y][armor?1:2];if(count==0)revert WrongBuilding();
        Resources memory cost=armor?(kind==1?baseOffensiveArmorCost:baseDefensiveArmorCost):(kind==1?baseOffensiveWeaponCost:baseDefensiveWeaponCost);
        applyProductionCost(x,y,cost,n,count,true);Military storage m=tiles[x][y].military;
        if(armor){if(kind==1)m.offensiveArmor+=n;else m.defensiveArmor+=n;}else{if(kind==1)m.offensiveWeapon+=n;else m.defensiveWeapon+=n;}
    }
    function createSoldier(int32,int32,uint8,uint256) external pure { revert("Legacy military retired"); }

    /// @notice 1 + floor(sqrt(4 * houses)); no floating-point or per-transaction rounding.
    function productionMultiplier(uint256 houses) internal pure returns (uint256) {
        // The input bound below prevents 4*houses overflow; Newton iterates and their sums stay <= n/2+3.
        unchecked {
        require(houses <= type(uint256).max / 4);
        uint256 n = houses * 4;
        if (n == 0) return 1;
        uint256 result = n;
        uint256 next = n / 2 + 1;
        while (next < result) { result = next; next = (n / next + next) / 2; }
        return 1 + result;
            }
    }

    function countBuildings(
        int32 mainX,
        int32 mainY,
        uint8 buildingType
    ) internal view returns (uint256) {
        return buildingType==18?castleCounts[mainX][mainY]:buildingType>=15?resourceDepotCounts[mainX][mainY][buildingType-15]:buildingType>=13?depotCounts[mainX][mainY][buildingType-13]:buildingCounts[mainX][mainY][buildingType];
    }

    error InsufficientResource(uint8 resource,uint256 required,uint256 available);
    function applyProductionCost(
        int32 mainX,
        int32 mainY,
        Resources memory cost,
        uint256 quantity,
        uint256 buildingCount,
        bool notifyIndex
    ) internal {
        TileData storage tile = tiles[mainX][mainY];
        buildingCount = (productionMultiplier(buildingCount) - 1) / 2; // floor(sqrt(count))

        Resources storage resources=tile.resources;
        // All four Resources fields are full uint256 words in declaration order.
        // Arithmetic remains checked; only the compiler-resolved field access is shared.
        for(uint256 i;i<4;i++){
            uint256 base;uint256 current;uint256 slot;
            assembly("memory-safe"){base:=mload(add(cost,mul(i,32))) slot:=add(resources.slot,i) current:=sload(slot)}
            uint256 unit=(base+buildingCount-1)/buildingCount;
            uint256 required=unit*quantity;
            if(current<required)revert InsufficientResource(uint8(i+1),required,current);
            uint256 remaining;unchecked{remaining=current-required;}
            assembly("memory-safe"){sstore(slot,remaining)}
        }

        if(notifyIndex)_recalculatePoints(tile, mainX, mainY);
        else realmRevision[mainX][mainY]++; // Training publishes its final score once, after equipment and troops update.
    }

    function placeBuilding(
        int32 mainX,
        int32 mainY,
        int128 interiorX,
        int128 interiorY,
        uint8 buildingType
    )
        rpcIndexed external
        nonReentrant
        ownsTile(mainX, mainY)
        validInteriorTile(mainX, mainY, interiorX, interiorY)
    activeTile(mainX,mainY) {
        requireWorldActive();
        if (!_isValidBuilding(buildingType)) revert InvalidBuildingType();
        if(!(!(interiorX == 0 && interiorY == 0))) revert InvalidCoord();

        uint8 ExistingBuilding = interiorMaps[mainX][mainY][interiorX][
            interiorY
        ];
        if(!(ExistingBuilding == 0)) revert WrongBuilding();

        if ((((uint256(0x1458) >> buildingType) & 1) != 0) &&
            countBuildings(mainX, mainY, buildingType) != 0) revert BuildingLimitReached();

        if (buildingType == 3) {
            // Clan Hall
            hasClanHallAt[mainX][mainY] = true;
        } else if (buildingType == 6) {
            // Market
            hasMarketAt[mainX][mainY] = true;
        }

        BuildingCost memory cost = buildingCosts[buildingType];
        if(!(cost.food | cost.wood | cost.stone | cost.iron > 0)) revert InvalidBuildingType();
        TileData storage tile = tiles[mainX][mainY];

        // Ensure the tile has enough resources

        // Deduct resources
        tile.resources.food -= cost.food;
        tile.resources.wood -= cost.wood;
        tile.resources.stone -= cost.stone;
        tile.resources.iron -= cost.iron;

        interiorMaps[mainX][mainY][interiorX][interiorY] = buildingType;
        if(buildingType==18)castleCounts[mainX][mainY]++;else if(buildingType>=15)resourceDepotCounts[mainX][mainY][buildingType-15]++;else if(buildingType>=13)depotCounts[mainX][mainY][buildingType-13]++;else buildingCounts[mainX][mainY][buildingType]++;
        if (buildingType == 10) relicForgeLevels[mainX][mainY][interiorX][interiorY] = 1;
        if (buildingType == 9) { siloLevels[mainX][mainY][interiorX][interiorY] = 1; totalSiloLevels[mainX][mainY]++; }


        _recalculatePoints(tile, mainX, mainY);
        emit InteriorCellChanged(mainX,mainY,interiorX,interiorY);
    }

    struct InteriorCell { int128 x; int128 y; uint8 buildingType; bool unlocked; }

    function getBuildingCounts(int32 mainX, int32 mainY) internal view returns (uint256[13] memory) {
        return buildingCounts[mainX][mainY];
    }

    /// @notice At most 256 cells per request, independent of the realm's level or area.
    function getInteriorRegion(int32 mainX, int32 mainY, int128 startX, int128 startY, uint8 width, uint8 height)
        external view ownsTile(mainX, mainY) returns (InteriorCell[] memory cells)
    {
        if(width == 0 || width > 16 || height == 0 || height > 16) revert InvalidCoord();
        if(!(startX != type(int128).min && startY != type(int128).min)) revert InvalidCoord();
        if(!(int256(startX) + int256(uint256(width)) - 1 <= type(int128).max &&
            int256(startY) + int256(uint256(height)) - 1 <= type(int128).max)) revert InvalidCoord();
        cells = new InteriorCell[](uint256(width) * height);
        // Validated coordinates and dimensions bound all loop arithmetic (<=256 cells).
        unchecked {
        for (uint256 row; row < height; ++row) {
            for (uint256 col; col < width; ++col) {
                int128 x = int128(int256(startX) + int256(col));
                int128 y = int128(int256(startY) + int256(row));
                cells[row * width + col] = InteriorCell(x, y, interiorMaps[mainX][mainY][x][y], isInteriorUnlocked(mainX, mainY, x, y));
            }
        }
        }
    }

    /// @notice Cost of the next level, starting at level zero: 250, 255, 260, ...
    function turnsRequiredForLevel(uint256 currentLevel) public pure returns (uint256) {
        return turnsPerLevel + currentLevel * 5;
    }

    /// @notice Quote the actual turns (including the existing level boundary) and exact fee.
    function quoteUseTurns(uint16 requested, int32 x, int32 y) internal view returns (uint16 actualTurns, uint256 feeWei) {
        if(requested == 0 || requested > 600) revert InvalidTurns();
        uint256 remaining = turnsRequiredForLevel(tiles[x][y].level) - tiles[x][y].accumulatedTurns;
        actualTurns = requested > remaining ? uint16(remaining) : requested;
        // Round up at most one wei; 300 turns always cost exactly turnFeeWei.
        feeWei = (turnFeeWei * actualTurns + 299) / 300;
    }

    event TurnFeeAllocated(uint256 treasuryAmount, uint256 poolAmount);

    function useTurns(
        uint16 turns,
        int32 x,
        int32 y
    ) internal ownsTile(x, y) nonReentrant whenUseTurnsNotPaused {
        if(turns == 0 || turns > 600) revert InvalidTurns();
        if(logistics!=address(0))IJLogistics(logistics).requireNoUncollectedArmy(x,y);
        (uint16 actualTurns, uint256 feeWei) = quoteUseTurns(turns, x, y);
        if (msg.value != feeWei) revert BadFee();
        if (extraFeeRecipient == address(0)) revert ZeroAddress();

        _calcTurn(x, y);

        if(!(tiles[x][y].turns >= actualTurns))revert InvalidQuantity();

        turns = actualTurns;

        tiles[x][y].turns -= turns;
        tiles[x][y].start = block.timestamp;

        // Get the number of houses (building type 5) on this tile
        uint256 houseCount = countBuildings(x, y, 5);
        houseCount = productionMultiplier(houseCount); // Diminishing house contribution

        // Get bonus type from the TileMapPhaser contract
        uint8 bonusType = _clan.getBonus(x, y);

        TileData storage tile = tiles[x][y];

        
        uint256 production = uint256(turns) * houseCount * 3;
        production*=stable==address(0)?10000:IRealmFeatures(stable).productionBps(x,y);
        uint256 fractions=productionRemainders[x][y];uint256 nextFractions;
        Resources storage resources=tile.resources;
        for(uint8 i;i<4;i++){
            uint256 current;uint256 slot;
            assembly("memory-safe"){slot:=add(resources.slot,i) current:=sload(slot)}
            uint256 shift=uint256(i)<<4;
            uint256 numerator=production*(bonusType==i+1?2:1)+((fractions>>shift)&65535);
            uint256 limit=_availableCapacity(x,y,i+1,getResourceStorageCapacity(x,y,i+1));
            uint256 next=_storeProduction(current,numerator/10000,limit);
            // Full storage discards production, including fractions; never bank overflow.
            if(next<limit)nextFractions|=(numerator%10000)<<shift;
            assembly("memory-safe"){sstore(slot,next)}
        }

        productionRemainders[x][y]=nextFractions;
        tile.accumulatedTurns += turns;

        // Calculate levels to add
        uint256 requirement = turnsRequiredForLevel(tile.level);
        uint256 newLevels = tile.accumulatedTurns / requirement;
        tile.accumulatedTurns %= requirement; // quoteUseTurns stops at this level boundary

        tile.level += newLevels;
        if (newLevels > 0) emit InteriorExpanded(x, y, tile.level);

        _recalculatePoints(tile,x,y);

        totalTurnsUsedByTile[x][y] += turns;



        emit TurnsUsed(msg.sender, turns, x, y);if(readIndex!=address(0))IReadActivity(readIndex).activity(0,x,y,0,0,turns);

        _distributeNativeFee(msg.value, x, y, turns);

        TXCounter++;
    }

    function _currentYearIndex() internal view returns (uint256) {
        if (rewardsStart == 0 || block.timestamp < rewardsStart)
            return type(uint256).max;
        return (block.timestamp - rewardsStart) / 365 days; // 0-based: 0..4 valid
    }

    function _rewardMultiplier()
        internal
        view
        returns (uint256 num, uint256 den)
    {
        uint256 yr = _currentYearIndex();
        if (yr >= 5) {
            // After 5 years: no rewards
            return (0, 1);
        }
        // Year 0: 2, Year 1: 1, Year 2: 1/2, Year 3: 1/4, Year 4: 1/8
        // Implement as numerator/denominator powers of two
        if (yr == 0) return (2, 1);
        // from year 1 onward: 1 / 2^(yr-1)
        return (1, 2 ** (yr - 1));
    }

    // Retained selector/storage for existing worlds; global combat research is retired.
    function upgradeTech(int32,int32,uint8) internal pure { revert("Use item research in Workshop"); }

    function demolishBuilding(
        int32 mainX,
        int32 mainY,
        int128 interiorX,
        int128 interiorY
    )
        rpcIndexed external
        nonReentrant
        ownsTile(mainX, mainY)
        validInteriorTile(mainX, mainY, interiorX, interiorY)
    activeTile(mainX,mainY) {
        requireWorldActive();
        if(!(!(interiorX == 0 && interiorY == 0))) revert InvalidCoord();

        uint8 buildingType = interiorMaps[mainX][mainY][interiorX][interiorY];
        if(!(buildingType != 0)) revert WrongBuilding();

        if (!_isValidBuilding(buildingType)) revert InvalidBuildingType();
        if(buildingType==4)IArmySlots(military).resetRealmArmyCapacity(mainX,mainY);

        if (buildingType == 3) {
            // Clan Hall
            if (!(_clan.canDemolishHall(mainX,mainY))) revert ClanMustDisband();
            IClanHallLevels(clanWar).resetClanHallCapacity(mainX,mainY);
            hasClanHallAt[mainX][mainY] = false;
        } else if (buildingType == 6) {
            // Market
            uint64 key = (uint64(uint32(mainX)) << 32) | uint64(uint32(mainY));
            if (!(IMarketListings(marketplaceAddress).activeListingsByTile(key) == 0)) revert ActiveMarketListings();
            hasMarketAt[mainX][mainY] = false;
        }

        uint8 resourceKind = _resourceDepotKind(buildingType);
        if(resourceKind!=0){
            uint256 contribution = buildingType==9 ? siloLevels[mainX][mainY][interiorX][interiorY]*SILO_CAPACITY_PER_LEVEL : SILO_CAPACITY_PER_LEVEL;
            uint256 capacity = getResourceStorageCapacity(mainX,mainY,resourceKind)-contribution+1;
            Resources storage r = tiles[mainX][mainY].resources;
            uint256 stored;assembly("memory-safe"){stored:=sload(add(r.slot,sub(resourceKind,1)))}
            if(stored>=_availableCapacity(mainX,mainY,resourceKind,capacity))revert SiloStorageInUse();
            if(buildingType==9){
                totalSiloLevels[mainX][mainY]-=siloLevels[mainX][mainY][interiorX][interiorY];
                delete siloLevels[mainX][mainY][interiorX][interiorY];
            }
        }

        if(buildingType==13||buildingType==14){
            IJLand.DepotStatus memory s=IJLand(address(this)).getDepotStatus(mainX,mainY);uint256 index=buildingType-13;
            uint256 afterCapacity=s.capacity[index]-(index==0?DepotRules.ARSENAL_PER_BUILDING:DepotRules.LOGISTICS_PER_BUILDING);
            if(s.stored[index]+s.listed[index]+(index==1?s.cartsAway*DepotRules.CART_SPACE:0)>afterCapacity)revert DepotStorageInUse();
        }
        // Remove the building
        interiorMaps[mainX][mainY][interiorX][interiorY] = 0;
        if(buildingType==18)castleCounts[mainX][mainY]--;else if(buildingType>=15)resourceDepotCounts[mainX][mainY][buildingType-15]--;else if(buildingType>=13)depotCounts[mainX][mainY][buildingType-13]--;else buildingCounts[mainX][mainY][buildingType]--;
        if (buildingType == 10) delete relicForgeLevels[mainX][mainY][interiorX][interiorY];

        _recalculatePoints(tiles[mainX][mainY],mainX,mainY);
        emit InteriorCellChanged(mainX,mainY,interiorX,interiorY);
    }

    // Legacy getter returns Food capacity only; use the typed getter for all resource flows.
    function getStorageCapacity(int32 x, int32 y) internal view returns (uint256) {
        return getResourceStorageCapacity(x,y,1);
    }
    function _resourceDepotKind(uint8 buildingType) internal pure returns(uint8){
        return buildingType==9?1:buildingType>=15&&buildingType<=17?buildingType-13:0;
    }
    function getResourceStorageCapacity(int32 x,int32 y,uint8 resourceType) internal view returns(uint256){
        if(resourceType<1||resourceType>4)revert RawResourceOnly();
        uint256 levels=resourceType==1?totalSiloLevels[x][y]:resourceDepotCounts[x][y][resourceType-2];
        return BASE_STORAGE_CAPACITY+levels*SILO_CAPACITY_PER_LEVEL;
    }
    function getResourceStorageStatus(int32 x,int32 y) internal view returns(uint256[4] memory capacities,uint256[4] memory buildings){
        for(uint8 i;i<4;i++){
            capacities[i]=getResourceStorageCapacity(x,y,i+1);
            buildings[i]=i==0?buildingCounts[x][y][9]:resourceDepotCounts[x][y][i-1];
        }
    }

    function _availableCapacity(int32 x,int32 y,uint8 t,uint256 capacity) private view returns(uint256) {
        uint256 reserved = marketplaceAddress.code.length == 0 ? 0 : IMarketListings(marketplaceAddress).reservedResources(x,y,t);
        return reserved >= capacity ? 0 : capacity-reserved;
    }
    function getResourceHeadroom(int32 x, int32 y, uint8 resourceType) internal view ownerOrMarketplace(x, y) returns (uint256) {
        if(resourceType < 1 || resourceType > 4) revert RawResourceOnly();
        Resources storage r = tiles[x][y].resources;
        uint256 amount = resourceType == 1 ? r.food : resourceType == 2 ? r.wood : resourceType == 3 ? r.stone : r.iron;
        uint256 capacity = _availableCapacity(x,y,resourceType,getResourceStorageCapacity(x,y,resourceType));
        return amount >= capacity ? 0 : capacity - amount;
    }

    function _storeProduction(uint256 current, uint256 amount, uint256 capacity) private pure returns (uint256) {
        if (current >= capacity) return current;
        if (amount >= capacity - current) return capacity;
        return current + amount;
    }

    function getSiloData(int32 x, int32 y, int128 interiorX, int128 interiorY)
        internal view returns (uint256 level, uint256 capacityContribution)
    {
        uint8 buildingType=interiorMaps[x][y][interiorX][interiorY];
        if(_resourceDepotKind(buildingType)==0)revert WrongBuilding();
        level = buildingType==9?siloLevels[x][y][interiorX][interiorY]:1;
        capacityContribution = level * SILO_CAPACITY_PER_LEVEL;
        // Legacy Silo levels retain their Food capacity; all new resource stores have fixed capacity.
    }

    function getRelicForgeData(int32 x, int32 y, int128 ix, int128 iy)
        internal view returns (uint256 level, uint256 productionCost, uint256 upgradeCost, uint256 productionAvailableAt, uint256 chainTime)
    {
        if(interiorMaps[x][y][ix][iy] != 10) revert WrongBuilding();
        level = relicForgeLevels[x][y][ix][iy];
        productionCost = 6000 + (240000 + level + 8) / (level + 9);
        upgradeCost = 6000 * level;
        productionAvailableAt = RelicProduction.data().nextAt[x][y];
        chainTime = block.timestamp;
    }

    function _spendRelicResources(int32 x, int32 y, uint256 cost) private {
        Resources storage r = tiles[x][y].resources;
        if (!(r.food >= cost && r.wood >= cost && r.stone >= cost && r.iron >= cost)) revert InsufficientForgeResources();
        // The preceding check proves all four subtractions are in range.
        unchecked {r.food -= cost; r.wood -= cost; r.stone -= cost; r.iron -= cost;}
        _recalculatePoints(tiles[x][y], x, y);
    }


    function upgradeRelicForgeChecked(int32 x, int32 y, int128 ix, int128 iy, uint256 maxCost) internal {
        _upgradeRelicForge(x,y,ix,iy,maxCost);
    }
    function upgradeRelicForge(int32 x,int32 y,int128 ix,int128 iy) internal {
        _upgradeRelicForge(x,y,ix,iy,type(uint256).max);
    }
    function _upgradeRelicForge(int32 x, int32 y, int128 ix, int128 iy, uint256 maxCost) private nonReentrant ownsTile(x,y) activeTile(x,y) {
        (uint256 level,,uint256 cost,,) = getRelicForgeData(x,y,ix,iy);
        if (!(cost <= maxCost)) revert ForgeQuoteChanged();
        _spendRelicResources(x,y,cost);
        relicForgeLevels[x][y][ix][iy] = level + 1;
        emit RelicForgeUpgraded(x,y,ix,iy,level+1); emit ForgeUpdated(x,y);
    }


    function produceRelicsChecked(int32 x, int32 y, int128 ix, int128 iy, uint256 quantity, uint256 maxCost) internal {
        _produceRelics(x,y,ix,iy,quantity,maxCost);
    }
    function produceRelics(int32 x,int32 y,int128 ix,int128 iy,uint256 quantity) internal {
        _produceRelics(x,y,ix,iy,quantity,type(uint256).max);
    }
    error RelicProductionCooldown(uint256 availableAt);
    function _produceRelics(int32 x, int32 y, int128 ix, int128 iy, uint256 quantity, uint256 maxCost) private nonReentrant ownsTile(x,y) activeTile(x,y) {
        if(quantity != 1) revert InvalidQuantity();
        uint256 availableAt = RelicProduction.data().nextAt[x][y];
        if(block.timestamp < availableAt) revert RelicProductionCooldown(availableAt);
        (,uint256 cost,,,) = getRelicForgeData(x,y,ix,iy);
        if (!(cost * quantity <= maxCost)) revert ForgeQuoteChanged();
        _spendRelicResources(x,y,cost);
        RelicProduction.data().nextAt[x][y] = block.timestamp + 1 days;
        relicBalances[x][y] += quantity;
        totalRelics += quantity;
        emit RelicsProduced(msg.sender,quantity);
    }

    function quoteRelicReward(uint256 quantity) internal view returns(uint256) {
        if(totalRelics == 0 || quantity == 0) return 0;
        if(quantity > totalRelics) revert InvalidQuantity();
        return availableRelicRewards() * quantity / totalRelics;
    }

    error GlobalRedemptionCooldown();
    error InsufficientRelics();
    error InvalidRewardAmount();
    error InsufficientRewardPool();
    error LegacyRedemptionDisabled();
    /// @notice Old clients must not interpret a minimum quote as an exact payout.
    function redeemRelics(int32,int32,uint256,uint256) internal pure { revert LegacyRedemptionDisabled(); }
    /// @notice Redeem only when the displayed quote still matches the exact current value.
    function redeemRelicsExact(int32,int32,uint256,uint256) internal pure { revert LegacyRedemptionDisabled(); }
    function refreshRealmScore(int32 x,int32 y) internal {
        if(tileMapPhaser.getTileOccupant(x,y)!=msg.sender)revert NotOwner();
        // Score refresh changes no inventory revision; an actual score change is itself hashed.
        _updateRealmScore(tiles[x][y],x,y);
    }

    function adjustTileResources(
        int32 x,
        int32 y,
        uint8 resourceType,
        uint256 amount,
        bool isAdding
    ) internal nonReentrant {
        if (msg.sender != marketplaceAddress && msg.sender != logistics && msg.sender != stable && msg.sender != military &&
            (msg.sender != clanWar || isAdding || (resourceType > 4 && resourceType < 9))) revert NotMarketplace();
        if (amount == 0) revert ZeroAmount();
        if(resourceType>=101&&resourceType<=115){ILandMilitary(military).adjustEquipment(x,y,resourceType,amount,isAdding);return;}
        // Slots 5..10 and 13..14 are reserved for historical data; new inventory lives in Military.
        if(!((resourceType >= 1 && resourceType <= 4) || resourceType == 11 || resourceType == 12))revert InvalidQuantity();
        if(resourceType>10) { IJStable(stable).adjust(x,y,resourceType,amount,isAdding); return; }
        TileData storage tile = tiles[x][y];

        if (isAdding && resourceType <= 4 && amount > getResourceHeadroom(x, y, resourceType)) revert StorageCapacityExceeded();
        // Each field in Resources and Military is a full uint256 slot. Resolve
        // the compiler-assigned struct base, never a hardcoded contract slot.
        // Range validation above and checked arithmetic below retain all bounds.
        uint256 slot;
        if(resourceType<=4) {
            Resources storage r=tile.resources;
            assembly ("memory-safe") { slot := add(r.slot, sub(resourceType,1)) }
        } else {
            Military storage m=tile.military;
            assembly ("memory-safe") { slot := add(m.slot, sub(resourceType,5)) }
        }
        uint256 current;
        assembly ("memory-safe") { current := sload(slot) }
        if(!isAdding&&current<amount)revert InsufficientResource(resourceType,amount,current);
        uint256 next=isAdding?current+amount:current-amount;
        assembly ("memory-safe") { sstore(slot,next) }

        realmRevision[x][y]++;
        if(readIndex!=address(0))IWorldReadIndex(readIndex).inventoryChanged(x,y);
    }

    function getTileData(int32 x,int32 y) internal view returns(TileDataResponse memory result){
        TileData storage tile=tiles[x][y];
        // Compiler-layout assertions in the release tests guard these struct-relative slots.
        // Mapping base is compiler-assigned; only the unchanged TileData layout is traversed.
        assembly("memory-safe"){
            for{let i:=0}lt(i,6){i:=add(i,1)}{mstore(add(result,mul(i,32)),sload(add(tile.slot,i)))}
            for{let i:=0}lt(i,6){i:=add(i,1)}{mstore(add(result,mul(add(i,6),32)),sload(add(tile.slot,add(i,8))))}
            let tech:=sload(add(tile.slot,14))
            mstore(add(result,384),and(tech,65535))
            mstore(add(result,416),and(shr(16,tech),65535))
            mstore(add(result,448),sload(add(tile.slot,15)))
        }
    }

    function getTilePublic(
        int32 x,
        int32 y
    ) internal view returns (TilePublicResponse memory) {
        TileData storage tile = tiles[x][y];
        return TilePublicResponse(tile.level, tile.points);
    }

    function recordActivity(int32 x,int32 y,address actor) internal {
        if(msg.sender!=address(tileMapPhaser) && msg.sender!=address(_clan) && msg.sender!=marketplaceAddress && msg.sender!=stable && msg.sender!=logistics && msg.sender!=clanWar && msg.sender!=military) revert NotMarketplace();
        if(actor!=address(0) && tileMapPhaser.getTileOccupant(x,y)==actor) _touchActivity(x,y);
    }

    function rankedTile(uint256 index) internal view returns(uint64 key,uint256 points,uint256 count) {
        if(readIndex==address(0))return(0,0,0);
        (DirectReadIndex.RankRow[] memory rows,uint256 total,,,)=DirectReadIndex(readIndex).rankings(false,index,1,0,0);
        count=total;if(rows.length>0){key=uint64(rows[0].id);points=rows[0].points;}
    }

    function _recalculatePoints(
        TileData storage tile,
        int32 x,
        int32 y
    ) private {
        realmRevision[x][y]++;
        if(readIndex!=address(0))IWorldReadIndex(readIndex).syncRealmScore(x,y,tile.points,tile.level);
    }
    function _updateRealmScore(TileData storage tile,int32 x,int32 y) private {
        uint256 total=trainingPoints[x][y];
        uint256 previous=pointsByCoords[x][y];
        if(previous==total)return;
        if(previous==0 && total>0) rankedRealmCount++;
        else if(previous>0 && total==0) rankedRealmCount--;
        totalRealmPoints = totalRealmPoints - previous + total;
        tile.points = total;
        pointsByCoords[x][y] = total;
        emit RealmScoreChanged(x,y,total);
        if(readIndex!=address(0))IWorldReadIndex(readIndex).syncRealmScore(x,y,total,tile.level);
        // The canonical DirectReadIndex maintains the only live ranking tree.
    }

    function recalculatePointsAfterAttack(
        int32 x,
        int32 y
    ) internal nonReentrant {
        if(!(msg.sender == marketplaceAddress)) revert WrongBuilding();

        // Battles cannot change training points or level; invalidate only inventory.
        realmRevision[x][y]++;
        if(readIndex!=address(0))IWorldReadIndex(readIndex).inventoryChanged(x,y);
    }

    function _distributeNativeFee(uint256 amount, int32 x, int32 y, uint16 turns) internal {
        uint256 treasuryAmount = amount / 5;
        uint256 clanAmount;
        if (clanWar != address(0) && _clan.getTileClan(x,y) != 0) {
            clanAmount = (amount / 10) * 2;
            IClanWar(clanWar).recordTurnFee{value:clanAmount}(x,y,turns);
        }
        uint256 poolAmount = amount - treasuryAmount - clanAmount;
        _fundPool(poolAmount);
        if (treasuryAmount > 0) {
            (bool sent, ) = payable(extraFeeRecipient).call{value: treasuryAmount}("");
            if (!(sent)) revert TreasuryTransferFailed();
        }
        emit TurnFeeAllocated(treasuryAmount, poolAmount);
    }

    function _rankCoords(uint64 key) private pure returns (int32 x, int32 y) {
        return (int32(uint32(key >> 32)), int32(uint32(key)));
    }
    function _higher(uint64 a, uint64 b) private view returns (bool) {
        (int32 ax, int32 ay) = _rankCoords(a); (int32 bx, int32 by) = _rankCoords(b);
        uint256 ap = pointsByCoords[ax][ay]; uint256 bp = pointsByCoords[bx][by];
        return ap > bp || (ap == bp && (ax < bx || (ax == bx && ay < by)));
    }
    function _swapRank(uint256 a, uint256 b) private {
        // Heap keys are unique int32 coordinate pairs: at most 2^64 entries. Index arithmetic stays below 2^66.
        unchecked {
        (rankedTiles[a], rankedTiles[b]) = (rankedTiles[b], rankedTiles[a]);
        rankPosition[rankedTiles[a]] = a + 1; rankPosition[rankedTiles[b]] = b + 1;
            }
    }
    /// @dev Indexed max heap: point increases AND decreases cost O(log settled realms).
    function _syncRank(int32 x, int32 y) internal {
        // Heap keys are unique int32 coordinate pairs: at most 2^64 entries. Index arithmetic stays below 2^66.
        unchecked {
        uint64 key = (uint64(uint32(x)) << 32) | uint64(uint32(y));
        uint256 pos = rankPosition[key];
        if (pos == 0) { rankedTiles.push(key); pos = rankedTiles.length; rankPosition[key] = pos; }
        uint256 i = pos - 1;
        while (i > 0) { uint256 parent = (i - 1) / 2; if (!_higher(rankedTiles[i], rankedTiles[parent])) break; _swapRank(i,parent); i = parent; }
        while (i * 2 + 1 < rankedTiles.length) {
            uint256 child = i * 2 + 1;
            if (child + 1 < rankedTiles.length && _higher(rankedTiles[child+1],rankedTiles[child])) ++child;
            if (!_higher(rankedTiles[child],rankedTiles[i])) break;
            _swapRank(i,child); i = child;
        }
            }
    }
    function _top3Owners() internal view returns (address first, address second, address third) {
        if(readIndex==address(0))return(address(0),address(0),address(0));
        (DirectReadIndex.RankRow[] memory rows,,,,)=DirectReadIndex(readIndex).rankings(false,0,3,0,0);
        address[3] memory owners;for(uint256 i;i<rows.length;i++)owners[i]=tileMapPhaser.getTileOccupant(rows[i].x,rows[i].y);
        return(owners[0],owners[1],owners[2]);
    }

    function getTotalTurnsUsedByTile(
        int32 x,
        int32 y
    ) internal view returns (uint256) {
        return totalTurnsUsedByTile[x][y];
    }

    function getTowerCount(
        int32 mainX,
        int32 mainY
    ) internal view returns (uint256) {
        return countBuildings(mainX, mainY, 7); // 7 = Tower
    }





    function hasClanHallAtCoord(int32 x, int32 y) internal view returns (bool) {
        return hasClanHallAt[x][y];
    }

    function hasMarketAtCoord(int32 x, int32 y) internal view returns (bool) {
        return hasMarketAt[x][y];
    }

    /// @notice Reward funds can only leave through relic redemption.
    function withdrawAllNativeRewards() internal pure { revert RewardPoolReserved(); }

    function nativeRewardBalance() internal view returns (uint256) {
        return rewardPool;
    }

    /// @notice Add native funds to the reward pool; rewards are not automatically distributed.
    function fundNativeRewards() internal  {
        if (msg.value == 0) revert ZeroAmount();
        _fundPool(msg.value);
        emit RewardsFunded(msg.sender, msg.value);
    }

    receive() external payable rpcIndexed { requireWorldActive(); 
        // A fee sent to this contract by itself is retained ETH, not a new reward deposit.
        if (msg.sender == address(this)) return;
        _fundPool(msg.value);
        emit RewardsFunded(msg.sender, msg.value);
    }



    function getTileLastActiveAt(
        int32 x,
        int32 y
    ) internal view returns (uint256) {
        return 0; // Retired inactivity status; legacy ABI and storage are preserved.
    }

    function getCurrentTimestamp() internal view returns (uint256) {
        return block.timestamp;
    }

    uint256 private allocatedRelicRewards;
    bool private rewardAllocationInitialized;
    mapping(int32 => mapping(int32 => uint256)) internal realmRevision;
    // Shared by every wallet. Appended to preserve existing deployment storage.
    uint256 internal nextRelicRedemptionAt;
    mapping(int32 => mapping(int32 => uint256)) internal nextRealmRelicRedemptionAt;
    uint256 internal constant REALM_RELIC_REDEMPTION_COOLDOWN = 0;
    function getRealmRelicRedemptionStatus(int32, int32) internal pure returns (uint256 availableAt, uint256 secondsRemaining) {
        availableAt = 0;
        secondsRemaining = 0;
    }
    uint256 internal constant RELIC_REDEMPTION_COOLDOWN = 0;
    function getRelicRedemptionStatus() internal pure returns (uint256 availableAt, uint256 secondsRemaining) { return (0,0); }
    function availableRelicRewards() internal view returns(uint256) {
        return rewardPool;
    }
    function _initializeAllocation() private {
        if (!rewardAllocationInitialized) { allocatedRelicRewards = rewardPool / 2; rewardAllocationInitialized = true; }
    }
    function _fundPool(uint256 amount) private {
        
        rewardPool += amount;
    }
    // Appended storage: the local preview can retain every existing realm.
    address internal clanWar;
    function setClanWarAddress(address module) internal onlyOwner {
        if (gameConfigurationFinalized || module.code.length == 0) revert ConfigurationSealed();
        clanWar = module;
    }
    address internal logistics;
    address internal stable;
    function setJourneyModules(address j,address s) internal onlyOwner {
        if(gameConfigurationFinalized || j.code.length==0 || s.code.length==0) revert ConfigurationSealed();
        logistics=j;stable=s;
    }
    uint256 internal rankedRealmCount;
    function getSaleStateHash(int32 x, int32 y) external view returns(bytes32) {

        return keccak256(abi.encode(tiles[x][y], buildingCounts[x][y], castleCounts[x][y], depotCounts[x][y], resourceDepotCounts[x][y], realmRevision[x][y], unitResearch[x][y], unitResearchInitialized[x][y], relicBalances[x][y], nextRealmRelicRedemptionAt[x][y], _clan.getSaleStateHash(x,y), stable==address(0)?bytes32(0):IJStable(stable).inventoryHash(x,y), military==address(0)?bytes32(0):ILandMilitary(military).inventoryHash(x,y)));
    }
    // Appended; existing realms start with zero fractional production.
    mapping(int32=>mapping(int32=>uint256)) private productionRemainders;

    address internal military;
    function setMilitary(address module) internal onlyOwner {if(gameConfigurationFinalized||module.code.length==0||military!=address(0))revert ConfigurationSealed();military=module;}
    function chargeMilitary(int32 x,int32 y,uint256[4] calldata cost,uint256 amount,uint8 building) internal nonReentrant {
        if(msg.sender!=military)revert NotMarketplace();uint256 count=buildingCounts[x][y][building];if(count==0)revert WrongBuilding();
        applyProductionCost(x,y,Resources(cost[0],cost[1],cost[2],cost[3]),amount,count,building!=4);
    }

    // All gameplay modules share the same immutable, 365-day deadline.
    // Delegate calls use the deadline of their own world.
    address internal worldRewards;
    uint256 internal totalRealmPoints;
    error WorldEnded();
    function requireWorldActive() internal view { IJLand(address(this)).requireWorldActive(); }
    function setWorldRewards(address module)  external onlyOwner {
        if(gameConfigurationFinalized || worldRewards != address(0) || module.code.length == 0) revert ConfigurationSealed();
        IWorldRewards candidate = IWorldRewards(module);
        if(candidate.land() != address(this) || candidate.map() != address(tileMapPhaser) || candidate.initialPool() == 0) revert ConfigurationSealed();
        worldRewards = module;
    }

    // Appended: realm-owned product research; old research retains historical score only.
    mapping(int32=>mapping(int32=>uint8[17])) internal itemResearch;
    mapping(int32=>mapping(int32=>uint256)) internal itemResearchTotal;
    mapping(int32=>mapping(int32=>uint8[21])) internal unitResearch;
    mapping(int32=>mapping(int32=>bool)) internal unitResearchInitialized;
    // Appended; never resize the historical uint256[13] building array.
    mapping(int32=>mapping(int32=>uint256[2])) internal depotCounts;
    // Appended: separate Wood, Stone and Iron depot counts; legacy Silo slots retain Food capacity.
    mapping(int32=>mapping(int32=>uint256[3])) internal resourceDepotCounts;

    event ItemResearched(int32 indexed x,int32 indexed y,uint8 indexed item,uint8 level);
    function researchLevels(int32 x,int32 y) external view returns(uint8[17] memory){return itemResearch[x][y];}
    function unitResearchLevels(int32 x,int32 y) public view returns(uint8[21] memory){
        return unitResearchInitialized[x][y]?unitResearch[x][y]:researchMath.migrate(itemResearch[x][y]);
    }
    function cartCapacity(int32 x,int32 y) external view returns(uint256){uint8[21] memory levels=unitResearchLevels(x,y);return 10000+uint256(levels[20])*500;}
    function upgradeItem(int32,int32,uint8,uint8) external pure {revert("Upgrade troops and carts in Workshop");}
    function unitResearchQuote(int32 x,int32 y,uint8 item) public view returns(uint8 level,uint256[4] memory cost){
        require(item>=1&&item<=21,"Unknown military upgrade");uint8[21] memory levels=unitResearchLevels(x,y);level=levels[item-1];
        require(level<20,"Maximum upgrade level");uint256 workshops=countBuildings(x,y,8);require(workshops>0,"Build a Workshop first");
        uint256 divisor=(productionMultiplier(workshops)-1)/2;cost=researchMath.cost(item);
        uint256 numerator=20*5**uint256(level);uint256 denominator=divisor*4**uint256(level);
        for(uint8 i;i<4;i++)cost[i]=(cost[i]*numerator+denominator-1)/denominator;
    }
    event UnitUpgraded(int32 indexed x,int32 indexed y,uint8 indexed unit,uint8 level);
    function upgradeUnit(int32 x,int32 y,uint8 item,uint8 expectedLevel) rpcIndexed external nonReentrant ownsTile(x,y) activeTile(x,y){
        requireWorldActive();(,,bool sale,,,)=IJMap(address(tileMapPhaser)).tiles(x,y);require(!sale,"Remove realm sale first");
        (uint8 level,uint256[4] memory cost)=unitResearchQuote(x,y,item);require(level==expectedLevel,"Research changed; refresh quote");
        TileData storage tile=tiles[x][y];require(tile.resources.food>=cost[0]&&tile.resources.wood>=cost[1]&&tile.resources.stone>=cost[2]&&tile.resources.iron>=cost[3],"Not enough research supplies");
        tile.resources.food-=cost[0];tile.resources.wood-=cost[1];tile.resources.stone-=cost[2];tile.resources.iron-=cost[3];
        if(!unitResearchInitialized[x][y]){unitResearch[x][y]=researchMath.migrate(itemResearch[x][y]);unitResearchInitialized[x][y]=true;}
        unitResearch[x][y][item-1]=level+1;itemResearchTotal[x][y]++;
        _recalculatePoints(tile,x,y);emit UnitUpgraded(x,y,item,level+1);
    }


    error DepotCapacityExceeded(uint8 kind,uint256 used,uint256 added,uint256 capacity);
    error DepotStorageInUse();
    function getDepotStatus(int32 x,int32 y) public view returns(IJLand.DepotStatus memory s){
        s.buildings=depotCounts[x][y];
        s.capacity=[DepotRules.ARSENAL_BASE+s.buildings[0]*DepotRules.ARSENAL_PER_BUILDING,DepotRules.LOGISTICS_BASE+s.buildings[1]*DepotRules.LOGISTICS_PER_BUILDING];
        if(military.code.length>0){(,uint256[15] memory gear)=ILandMilitary(military).inventory(x,y);for(uint8 i;i<15;i++)s.stored[0]+=gear[i]*DepotRules.weight(i+101);}
        if(stable.code.length>0){uint256[4] memory stock=IJStable(stable).inventory(x,y);s.stored[1]=stock[0]+stock[1]*DepotRules.CART_SPACE;}
        if(marketplaceAddress.code.length>0)s.listed=IJMarket(marketplaceAddress).depotEscrow(x,y);
        if(logistics.code.length>0)s.cartsAway=IJLogistics(logistics).reservedCarts(x,y);
    }
    function requireDepotSpace(int32 x,int32 y,uint8 kind,uint256 amount,bool convertingHorses) external view {
        uint256 weight=DepotRules.weight(kind);require(weight>0,"Not a stored product");
        if(convertingHorses){require(msg.sender==stable&&kind==12,"Only cart production");weight--;}
        IJLand.DepotStatus memory s=getDepotStatus(x,y);uint256 index=kind>=101?0:1;
        uint256 used=s.stored[index]+s.listed[index]+(index==1?s.cartsAway*DepotRules.CART_SPACE:0);uint256 added=amount*weight;
        if(used>s.capacity[index]||added>s.capacity[index]-used)revert DepotCapacityExceeded(kind,used,added,s.capacity[index]);
    }


    // Append-only read projection; this does not modify balances or game rules.
    address public readIndex;
    address public realmVision;
    function setRealmVision(address target)  external onlyOwner {require(realmVision==address(0)&&target.code.length>0,"Vision configured");realmVision=target;}
    function setReadIndex(address target)  external onlyOwner {require(readIndex==address(0)&&target.code.length>0,"Read index configured");readIndex=target;}

    function realmDashboard(int32 x,int32 y) external view ownsTile(x,y) returns(
      IJLand.Inventory memory data,uint256 turns,uint256[4] memory capacities,uint256[4] memory stores,
      uint256[13] memory counts,uint256 relics,IJLand.DepotStatus memory depots,uint256[4] memory listed,uint256 castles){
      data=IJLand(address(this)).getTileData(x,y);(turns,)=_turnState(x,y);
      (capacities,stores)=getResourceStorageStatus(x,y);counts=buildingCounts[x][y];relics=relicBalances[x][y];depots=getDepotStatus(x,y);castles=castleCounts[x][y];
      for(uint8 i;i<4;i++)listed[i]=IMarketListings(marketplaceAddress).reservedResources(x,y,i+1);
    }
    // Legacy cooldown slot retained for storage compatibility; no longer enforced.
    mapping(int32=>mapping(int32=>uint256)) private realmRedemptionAt;
    // Appended: never resize the historical building-count arrays.
    mapping(int32=>mapping(int32=>uint256)) private castleCounts;
    function getCastleCount(int32 x,int32 y) external view returns(uint256){return castleCounts[x][y];}
    // One Castle contributes three Tower-equivalent defense and damage-budget units.
    function fortificationUnits(int32 x,int32 y) external view returns(uint256){return buildingCounts[x][y][7]+castleCounts[x][y]*3;}
    function relicAccountSnapshot(address account) external view returns(uint256 balance,uint256 availableAt) {
        if(tileMapPhaser.hasOccupiedTile(account)){int32[2] memory p=tileMapPhaser.getOccupiedTileByAddress(account);balance=relicBalances[p[0]][p[1]];availableAt=0;}
    }

    // Appended; legacy inventory, research and battle records retain their slots.
    mapping(int32=>mapping(int32=>uint256)) internal buildingValuePlusOne;
    mapping(int32=>mapping(int32=>uint256)) internal victoryDefense;
    // Append-only: permanent training achievements and final relic settlement.
    mapping(int32=>mapping(int32=>uint256)) internal trainingPoints;
    bool internal finalRelicSettlement;
    uint256 internal finalRelicPool;
    uint256 internal finalRelicSupply;
    mapping(int32=>mapping(int32=>uint256)) internal finalRelicsRedeemed;



    function finalRelicQuoteState(address account) external view returns(uint256 pool,uint256 supply,uint256 redeemed,bool closed){
        closed=block.timestamp>=IJLand(address(this)).worldEndsAt();pool=closed&&finalRelicSettlement?finalRelicPool:rewardPool;
        supply=closed&&finalRelicSettlement?finalRelicSupply:totalRelics;
        if(closed&&tileMapPhaser.hasOccupiedTile(account)){int32[2] memory p=tileMapPhaser.getOccupiedTileByAddress(account);redeemed=finalRelicsRedeemed[p[0]][p[1]];}
    }
    event TrainingScoreRecorded(int32 indexed x,int32 indexed y,uint8 unit,uint256 quantity,uint256 addedPoints);
    function troopTrainingPoints(uint8 unit) external pure returns(uint256){return RealmScoreRules.trainingPoints(unit);}
    function recordTrainingScore(int32 x,int32 y,uint8 unit,uint256 quantity) rpcIndexed external nonReentrant {
        requireWorldActive();if(msg.sender!=military)revert NotMarketplace();
        if(quantity==0||quantity>100000)revert InvalidQuantity();
        uint256 added=RealmScoreRules.trainingPoints(unit)*quantity;trainingPoints[x][y]+=added;
        _updateRealmScore(tiles[x][y],x,y);emit TrainingScoreRecorded(x,y,unit,quantity,added);
    }
    /// Permissionless bounded reconciliation; all values are derived from current canonical state.
    function refreshRealmScores(int32[] calldata xs,int32[] calldata ys) rpcIndexed external nonReentrant {
        requireWorldActive();require(xs.length==ys.length&&xs.length>0&&xs.length<=64,"Page size 1 to 64");
        for(uint256 i;i<xs.length;i++){if(tileMapPhaser.getTileOccupant(xs[i],ys[i])==address(0))revert InvalidCoord();_updateRealmScore(tiles[xs[i]][ys[i]],xs[i],ys[i]);}
    }

    /// @notice Claim all unpaid relic rewards and older credits without removing the realm's relics.
    /// Effects precede the receiver callback; a failed transfer rolls back settlement and credits.
    function withdrawRelicRewards(address payable to) rpcIndexed external nonReentrant {
        _requirePayoutClosed();
        if(to==address(0)||to==address(this))revert InvalidNativeRecipient();
        if(tileMapPhaser.hasOccupiedTile(msg.sender)){
            int32[2] memory p=tileMapPhaser.getOccupiedTileByAddress(msg.sender);
            if(tileMapPhaser.getTileOccupant(p[0],p[1])!=msg.sender)revert NotOwner();
            uint256 quantity=relicBalances[p[0]][p[1]]-RelicSettlement.data().settled[p[0]][p[1]];
            if(quantity>0&&block.timestamp>=IJLand(address(this)).worldEndsAt()){
                uint256 reward=_remainingRelicReward(p[0],p[1],quantity);
                if(reward>0){
                uint256 reserved=totalNativePayouts+lockedNative;
                if(reward>rewardPool||address(this).balance<reserved||reward>address(this).balance-reserved)revert InsufficientRewardPool();
                if(!finalRelicSettlement){finalRelicSettlement=true;finalRelicPool=rewardPool;finalRelicSupply=totalRelics;emit FinalRelicSettlement(finalRelicPool,finalRelicSupply);}
                finalRelicsRedeemed[p[0]][p[1]]+=quantity;
                RelicSettlement.data().settled[p[0]][p[1]]+=quantity;rewardPool-=reward;realmRevision[p[0]][p[1]]++;
                _creditNative(msg.sender,reward);emit RelicsRedeemed(msg.sender,quantity,reward);
                }
            }
        }
        uint256 amount=nativePayouts[msg.sender];if(amount==0)revert NoNativePayout();
        nativePayouts[msg.sender]=0;totalNativePayouts-=amount;
        WalletClaimStatus.mark(msg.sender,1);
        (bool ok,)=to.call{value:amount}("");if(!ok)revert NativeTransferFailed();
        emit NativePayoutWithdrawn(msg.sender,to,amount);
    }
    function _remainingRelicReward(int32 x,int32 y,uint256 quantity) private view returns(uint256){
        uint256 supply=finalRelicSettlement?finalRelicSupply:totalRelics;
        if(supply==0||quantity==0)return 0;
        uint256 pool=finalRelicSettlement?finalRelicPool:rewardPool;uint256 done=finalRelicsRedeemed[x][y];
        return pool*(done+quantity)/supply-pool*done/supply;
    }
    function relicRewardBalance(address account) external view returns(uint256 amount){
        amount=nativePayouts[account];
        if(block.timestamp<IJLand(address(this)).worldEndsAt()||!tileMapPhaser.hasOccupiedTile(account))return amount;
        int32[2] memory p=tileMapPhaser.getOccupiedTileByAddress(account);
        if(tileMapPhaser.getTileOccupant(p[0],p[1])==account)amount+=_remainingRelicReward(p[0],p[1],relicBalances[p[0]][p[1]]-RelicSettlement.data().settled[p[0]][p[1]]);
    }

    event JourneyRelicsCollected(uint256 indexed id,int32 x,int32 y,uint256 amount);
    function collectJourneyLoot(uint256 id,int32 x,int32 y,uint64 clanId) rpcIndexed external nonReentrant {
        requireWorldActive();if(msg.sender!=logistics)revert NotMarketplace();
        JourneyLootEscrow.State storage s=JourneyLootEscrow.data();JourneyLootEscrow.Entry storage e=s.entries[id];
        uint256 amount=e.amount;if(amount==0)return;
        if(e.x!=x||e.y!=y||clanId!=0)revert InvalidCoord();
        e.amount=0;s.total-=amount;relicBalances[x][y]+=amount;totalRelics+=amount;realmRevision[x][y]++;
        emit JourneyRelicsCollected(id,x,y,amount);if(readIndex!=address(0))IWorldReadIndex(readIndex).inventoryChanged(x,y);
    }

}
