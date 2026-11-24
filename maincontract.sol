// SPDX-License-Identifier: MIT
import "./PublicRPCEvents.sol";
import {WalletClaimStatus} from "./WalletClaimStatus.sol";
pragma solidity 0.8.37;
import "FeeExemptions.sol";

interface IWorldReadIndex {function syncRealm(int32,int32) external;function syncClan(uint64) external;function syncRoute(uint256) external;}
interface IReadIndexSource {function readIndex() external view returns(address);}

import "journeyinterfaces.sol";

/// @dev Local storage-based guard and native payment accounting; no external dependency.
abstract contract MapNativePayments  is PublicRPCEvents {
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

interface ISaleManager { function theLand() external view returns(address); function tileMapPhaser() external view returns(address); function listingRevision(uint64 key) external view returns(uint256); }
interface IInactiveClan {function canRecoverInactiveLeader(int32 x,int32 y) external view returns(bool);}
interface ISaleLand { function fundNativeRewards() external payable; function extraFeeRecipient() external view returns(address); function _clan() external view returns(address); function getSaleStateHash(int32 x,int32 y) external view returns(bytes32); }
contract TileMapPhaser is PublicRPCEvents, MapNativePayments  {
    function _requirePayoutClosed() internal view override {
        if(block.timestamp < IJLand(ISaleManager(manager).theLand()).worldEndsAt()) revert WorldStillOpen();
    }
    int32 public nextSettlementX;
    int32 public nextSettlementY;
    uint64[] private settledTileKeys;
    uint8 public constant REGION_SIZE = 16;
    uint256 public constant MAX_PAGE_SIZE = 128;
    event SettlementOpened(int32 indexed x, int32 indexed y, uint256 ordinal);

    function worldVersion() external pure returns (uint256) { return 8; }
    function settledCount() external view returns (uint256) { return settledTileKeys.length; }
    function nextSettlement() external view returns (int32 x, int32 y) {
        return (nextSettlementX, nextSettlementY);
    }
    function tileKey(int32 x, int32 y) public pure returns (uint64) {
        return (uint64(uint32(x)) << 32) | uint64(uint32(y));
    }
    /// @notice The playable window starts at 20x20 and grows before the spiral reaches its edge.
    function worldBounds() external view returns (int32 min, int32 max) {
        int64 x = nextSettlementX; int64 y = nextSettlementY;
        int64 radius = x < 0 ? -x : x;
        int64 ay = y < 0 ? -y : y;
        if (ay > radius) radius = ay;
        int64 extent = radius + 2;
        if (extent < 10) extent = 10;
        return (int32(-extent), int32(extent - 1));
    }
    function _advanceSettlement() private {
        int64 x = nextSettlementX; int64 y = nextSettlementY;
        if (x >= 0 && x == -y) ++x;
        else if (x > y && x > -y) ++y;
        else if (x <= y && x > -y) --x;
        else if (x < y && x <= -y) --y;
        else ++x;
        require(x >= -2147483645 && x <= 2147483645 && y >= -2147483645 && y <= 2147483645, "Coordinate space exhausted");
        nextSettlementX = int32(x); nextSettlementY = int32(y);
    }
    function getSettledTilesPage(uint256 offset, uint256 limit) external view returns (uint64[] memory keys) {
        require(limit > 0 && limit <= MAX_PAGE_SIZE, "Page limit 1-128");
        uint256 count = settledTileKeys.length;
        if (offset >= count) return new uint64[](0);
        uint256 size = count - offset;
        if (size > limit) size = limit;
        keys = new uint64[](size);
        for (uint256 i; i < size; ++i) keys[i] = settledTileKeys[offset + i];
    }
    struct RegionTile { int32 x; int32 y; address occupant; bool isOnSale; uint8 bonus; }
    function getRegion(int32 startX, int32 startY, uint8 width, uint8 height) external view returns (RegionTile[] memory result) {
        require(width > 0 && width <= REGION_SIZE && height > 0 && height <= REGION_SIZE, "Region limit 16x16");
        require(int64(startX) + int64(uint64(width)) - 1 <= type(int32).max && int64(startY) + int64(uint64(height)) - 1 <= type(int32).max, "Region overflow");
        result = new RegionTile[](uint256(width) * height);
        for (uint32 i; i < width; ++i) for (uint32 j; j < height; ++j) {
            int32 x = startX + int32(i); int32 y = startY + int32(j);
            result[uint256(i) * height + j] = RegionTile(x, y, tiles[x][y].occupant, tiles[x][y].isOnSale, bonuses[x][y]);
        }
    }
    address public owner; // Owner of the contract
    address public manager; // Manager of the contract
    address public switcher; // Manager of the contract
    bool public paused; // Emergency pause status
    bool public switchStatus;

    uint256 public immutable nativeUnitWei;
    uint256 public immutable occupationCost;

    // Struct to represent each tile
    struct Tile {
        bool isOccupied; // Indicates if the tile is occupied
        address occupant; // Address of the occupant (if any)
        bool isOnSale; // Indicates if the tile is on sale (1 for sale, 0 for not)
        uint salePrice; // Price in native units for buying this tile
        uint saleBurnAmount; // Price in native units for buying this tile
        uint lastPurchasePrice;
    }

    // 2D array to store the tile map
    mapping(int32 => mapping(int32 => Tile)) public tiles;

    /// @notice 0 = neutral/unsettled; 1 = Food, 2 = Wood, 3 = Stone, 4 = Iron.
    /// Chosen once at first settlement; ownership transfers keep the stored bonus.
    mapping(int32 => mapping(int32 => uint8)) public bonuses;
    event ResourceBonusChosen(int32 indexed x, int32 indexed y, uint8 bonus);

    // Mapping to store if an address has already occupied a tile
    mapping(address => bool) public hasOccupiedTile;

    // Mapping to store the tile coordinates occupied by each address
    mapping(address => int32[2]) public occupantTileCoordinates;

    // Event to log when a tile is occupied or freed
    mapping(int32 => mapping(int32 => uint256)) public lastAcquiredAt;
    /// @notice Original settlement time; ownership transfers never restart the starter shield.
    mapping(int32 => mapping(int32 => uint256)) public firstSettledAt;

    event TileUpdated(int32 x, int32 y, bool isOccupied, address occupant);

    // Event to log when a tile is put on sale
    event TileOnSale(int32 x, int32 y, bool isOnSale, uint salePrice);

    event ManagerSet(address indexed newManager);


    event Paused(address indexed account);
    event Unpaused(address indexed account);

    constructor(address _switcher, uint256 _nativeUnitWei) {
        require(_switcher != address(0), "Zero switcher");
        require(
            _nativeUnitWei > 0 &&
                _nativeUnitWei <= type(uint256).max / 1_000_000_000_000,
            "Invalid native unit"
        );
        nativeUnitWei = _nativeUnitWei;
        occupationCost = 0.001 ether;
        owner = msg.sender;
        // Constructor argument retained for deployment compatibility; no switcher authority.

        paused = true;
    }

    modifier whenNotPaused() {
        require(!paused, "Contract is paused");
        _;
    }


    // Modifier to check if caller is the tile occupant or manager
    modifier onlyManagerOrOccupant(int32 x, int32 y) {
        require(
            msg.sender == manager || msg.sender == tiles[x][y].occupant,
            "Caller is not the manager or occupant"
        );
        _;
    }

    // Modifier to restrict access to the owner
    modifier onlyOwner() {
        require(msg.sender == owner, "Caller is not the owner");
        _;
    }

    // One-time deployment wiring. No administrator survives initialization.
    function setManager(address _manager) rpcIndexed external onlyOwner {
        require(manager == address(0) && _manager.code.length > 0, "Already configured or invalid market");
        require(ISaleManager(_manager).tileMapPhaser() == address(this), "Wrong market");
        manager = _manager;
        owner = address(0);
        switcher = address(0);
        paused = false;
        emit ManagerSet(_manager);
    }

    event FeeExemptionConfigured(address indexed account,uint8 flags);
    event FeeExemptionUsed(address indexed account,uint8 action);
    /// Bit 0: land claim; bit 1: first clan creation and first flag. Frozen by setManager.
    function feeExemptions(address account) external view returns(uint8){return FeeExemptions.data().flags[account];}
    /// Remaining rights: bit 0 claim, bit 1 clan creation, bit 2 clan flag.
    function availableFeeExemptions(address account) public view returns(uint8){
        FeeExemptions.Data storage d=FeeExemptions.data();
        uint8 flags=d.flags[account];
        return (flags&1)|(flags&2!=0?(uint8(6)&~d.used[account]):0);
    }
    function setFeeExemptions(address[] calldata accounts,uint8 flags) rpcIndexed external onlyOwner {
        require(manager==address(0)&&flags<=3&&accounts.length>0&&accounts.length<=64,"Invalid exemption configuration");
        for(uint256 i;i<accounts.length;i++){
            require(accounts[i]!=address(0)&&accounts[i]!=address(this),"Invalid exempt account");
            FeeExemptions.data().flags[accounts[i]]=flags;emit FeeExemptionConfigured(accounts[i],flags);
        }
    }
    function requireClanFee(address account,uint256 paid,bool flag) rpcIndexed external {
        require(msg.sender==ISaleLand(ISaleManager(manager).theLand())._clan(),"Caller is not clan");
        uint8 action=flag?4:2;
        uint256 expected=availableFeeExemptions(account)&action!=0?0:(flag?0.01 ether:0.001 ether);
        if(paid!=expected)revert IncorrectNativePayment(expected,paid);
        if(expected==0){FeeExemptions.data().used[account]|=action;emit FeeExemptionUsed(account,action);}
    }
    function clanCreationCostFor(address account) external view returns(uint256){return availableFeeExemptions(account)&2!=0?0:0.001 ether;}
    function clanFlagCostFor(address account) external view returns(uint256){return availableFeeExemptions(account)&4!=0?0:0.01 ether;}
    function claimCostFor(address account) public view returns(uint256){return FeeExemptions.data().flags[account]&1!=0?0:occupationCost;}

    /// @notice Allocate the next frontier tile at execution time; concurrent settlers do not race on a quoted coordinate.
    function settleNext(uint8 bonus) rpcIndexed external payable returns (int32 x, int32 y) { IJLand(ISaleManager(manager).theLand()).requireWorldActive(); 
        x = nextSettlementX;
        y = nextSettlementY;
        occupyTile(x, y, bonus);
    }

    event LandClaimFeePaid(address indexed claimant, address indexed referrer, uint256 referrerAmount, uint256 treasuryAmount);
    error ReferrerTransferFailed();
    error LandClaimsClosed();
    uint256 public constant LAND_CLAIM_CLOSING_WINDOW = 90 days;

    /// @notice New settlements close at the start of the world's final 90 days.
    function landClaimClosesAt() public view returns (uint256) {
        uint256 end = IJLand(ISaleManager(manager).theLand()).worldEndsAt();
        return end > LAND_CLAIM_CLOSING_WINDOW ? end - LAND_CLAIM_CLOSING_WINDOW : 0;
    }

    /// @notice Optional referral; the fee stays fixed and is paid during this claim.
    function settleNextWithReferrer(uint8 bonus, address referrer) rpcIndexed external payable nonReentrant whenNotPaused returns (int32 x, int32 y) {
        x = nextSettlementX;
        y = nextSettlementY;
        _occupyTile(x, y, bonus, referrer);
    }

    function occupyTile(int32 x, int32 y, uint8 bonus) rpcIndexed public payable nonReentrant whenNotPaused {
        _occupyTile(x, y, bonus, address(0));
    }

    function _occupyTile(int32 x, int32 y, uint8 bonus, address referrer) private {
        IJLand(ISaleManager(manager).theLand()).requireWorldActive();
        if (block.timestamp >= landClaimClosesAt()) revert LandClaimsClosed();
        require(bonus >= 1 && bonus <= 4, "Choose a resource bonus (1-4)");
        require(x == nextSettlementX && y == nextSettlementY, "Settlement moved; refresh location");
        require(!tiles[x][y].isOccupied, "Tile is already occupied");
        require(
            !hasOccupiedTile[msg.sender],
            "You have already occupied a tile"
        );

        uint256 claimFee=claimCostFor(msg.sender);
        _requireNative(claimFee);
        // Record the realm before either fee recipient is called.

        // Mark the tile as occupied and store the occupant
        tiles[x][y].isOccupied = true;
        tiles[x][y].occupant = msg.sender;
        bonuses[x][y] = bonus;
        emit ResourceBonusChosen(x, y, bonus);

        // Mark the caller's address as having occupied a tile
        hasOccupiedTile[msg.sender] = true;

        // Store the tile coordinates for the caller's address
        occupantTileCoordinates[msg.sender] = [x, y];

        tiles[x][y].lastPurchasePrice = claimFee;
        lastAcquiredAt[x][y] = block.timestamp;
        ownershipEpoch[x][y]++;

        settledTileKeys.push(tileKey(x, y));
        emit SettlementOpened(x, y, settledTileKeys.length - 1);
        firstSettledAt[x][y] = block.timestamp;
        _advanceSettlement();
        emit TileUpdated(x, y, true, msg.sender); _indexRealm(x,y);
        address treasury = ISaleLand(ISaleManager(manager).theLand()).extraFeeRecipient();
        if(treasury == address(0) || treasury == address(this)) revert InvalidNativeRecipient();
        // A wallet cannot refer itself. Zero means no referral.
        if(referrer == msg.sender) referrer = address(0);
        if(referrer == address(this)) revert InvalidNativeRecipient();
        uint256 referralShare = referrer == address(0) ? 0 : claimFee / 2;
        uint256 treasuryShare = claimFee - referralShare;
        if(treasuryShare != 0) {
            (bool paid,) = payable(treasury).call{value:treasuryShare}("");
            if(!paid) revert NativeTransferFailed();
        }
        if(referralShare != 0) {
            (bool referred,) = payable(referrer).call{value:referralShare}("");
            if(!referred) revert ReferrerTransferFailed();
        }
        emit LandClaimFeePaid(msg.sender, referrer, referralShare, treasuryShare);
    }

    // Function to mark a tile as on sale with a specified price
    error RealmSalesDisabled();
    /// @notice Retired listings can only be cleared; ownership never changes.
    function setTileOnSale(int32 x,int32 y,bool onSale,uint256) rpcIndexed public onlyManagerOrOccupant(x,y) {
        if(onSale)revert RealmSalesDisabled();
        tiles[x][y].isOnSale=false;tiles[x][y].salePrice=0;tiles[x][y].saleBurnAmount=0;
        emit TileOnSale(x,y,false,0);_indexRealm(x,y);
    }

    // Function to buy a tile
    function buyTile(int32,int32,bytes32)  public payable {revert RealmSalesDisabled();}

    // Function to check if a tile is occupied
    function isTileOccupied(int32 x, int32 y) public view returns (bool) {
        return tiles[x][y].isOccupied;
    }

    // Function to get the occupant of a tile
    function getTileOccupant(int32 x, int32 y) public view returns (address) {
        return tiles[x][y].occupant;
    }

    // New function to get the tile coordinates occupied by a specific address
    function getOccupiedTileByAddress(
        address occupant
    ) public view returns (int32[2] memory) {
        require(
            hasOccupiedTile[occupant],
            "This address has not occupied a tile"
        );
        return occupantTileCoordinates[occupant];
    }

    // Monotonic across transfers, including several purchases in the same block.
    mapping(int32 => mapping(int32 => uint256)) public ownershipEpoch;
    function _noJourneys(int32 x,int32 y,bool inactiveRecovery) private view {
        IJLand l=IJLand(ISaleManager(manager).theLand());address j=l.logistics();
        require(j==address(0)||IJLogistics(j).canTransferRealm(x,y),"Collect journeys before selling");
        // Retired relic queue entries do not restrict realm transfers.
        bool transferable=l.clanWar()==address(0)||IClanGovernance(l.clanWar()).canTransferRealm(x,y);
        if(!transferable&&inactiveRecovery)transferable=IInactiveClan(ISaleLand(address(l))._clan()).canRecoverInactiveLeader(x,y);
        require(transferable,"Transfer clan leadership before selling");
    }
    function getSaleStateHash(int32 x,int32 y) public view returns(bytes32) {
        address j=IJLand(ISaleManager(manager).theLand()).logistics();
        bytes32 returnsHash=j==address(0)?bytes32(0):IJLogistics(j).getRealmSaleStateHash(x,y);
        return keccak256(abi.encode(returnsHash,tiles[x][y], ISaleLand(ISaleManager(manager).theLand()).getSaleStateHash(x,y), ISaleManager(manager).listingRevision(tileKey(x,y))));
    }

 function _indexRealm(int32 x,int32 y) private {address target=IReadIndexSource(ISaleManager(manager).theLand()).readIndex();if(target!=address(0))IWorldReadIndex(target).syncRealm(x,y);}
}
