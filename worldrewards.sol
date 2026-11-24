// SPDX-License-Identifier: MIT
import "./PublicRPCEvents.sol";
import {WalletClaimStatus} from "./WalletClaimStatus.sol";
pragma solidity 0.8.37;

interface IWorldLand {
    function worldEndsAt() external view returns(uint256);
    function extraFeeRecipient() external view returns(address);
    function totalRealmPoints() external view returns(uint256);
    function pointsByCoords(int32 x,int32 y) external view returns(uint256);
}
interface IWorldMap {
    function hasOccupiedTile(address account) external view returns(bool);
    function getOccupiedTileByAddress(address account) external view returns(int32[2] memory);
    function getTileOccupant(int32 x,int32 y) external view returns(address);
}
interface IRewardToken { function balanceOf(address account) external view returns(uint256); }

/// @notice A fixed, pre-funded prize pool. Frozen realm points determine each owner's share.
/// Positive-score entitlements have no deadline. Only a zero-score pool can return to treasury after closure.
contract WorldRewards  is PublicRPCEvents {
    address public constant BNB_REWARD_TOKEN = 0xCF3D31Dd1BCEd6121d97E98D110f8fc54D993365;
    IWorldLand public immutable land;
    IWorldMap public immutable map;
    address public immutable token;
    address public immutable funder;
    uint256 public immutable endsAt;
    uint256 public initialPool;
    uint256 public totalClaimed;
    function walletWithdrawalStatus(address account) external view returns(uint256){return WalletClaimStatus.status(account);}
    mapping(address=>bool) public claimed;
    uint256 private guard=1;
    event PoolFunded(address indexed token,uint256 amount);
    event RewardClaimed(address indexed account,address indexed recipient,uint256 points,uint256 amount);
    error WorldStillOpen();
    error AlreadyClaimed();
    error NoReward();
    error TokenTransferFailed();
    modifier nonReentrant(){require(guard==1,"Reentrant call");guard=2;_;guard=1;}

    constructor(address m,address l,address t){
        require(m.code.length>0&&l.code.length>0&&t.code.length>0,"Invalid reward configuration");
        require(block.chainid!=56||t==BNB_REWARD_TOKEN,"Wrong BNB reward token");
        map=IWorldMap(m);land=IWorldLand(l);token=t;funder=msg.sender;endsAt=land.worldEndsAt();
    }
    /// @dev Called once by the deployer, before sealing the world. Only exact-transfer tokens are supported.
    function fund(uint256 amount) rpcIndexed external nonReentrant {
        require(msg.sender==funder&&initialPool==0&&block.timestamp<endsAt&&amount>0,"Pool funding unavailable");
        uint256 beforeBalance=IRewardToken(token).balanceOf(address(this));
        _transfer(abi.encodeWithSignature("transferFrom(address,address,uint256)",msg.sender,address(this),amount));
        require(IRewardToken(token).balanceOf(address(this))-beforeBalance==amount,"Unsupported transfer fee");
        initialPool=amount;emit PoolFunded(token,amount);
    }
    function ended() public view returns(bool){return block.timestamp>=endsAt;}
    function remainingPool() external view returns(uint256){return initialPool-totalClaimed;}
    function entitlement(address account) public view returns(uint256 points,uint256 totalPoints,uint256 amount){
        totalPoints=land.totalRealmPoints();
        if(!map.hasOccupiedTile(account))return(0,totalPoints,0);
        int32[2] memory xy=map.getOccupiedTileByAddress(account);
        if(map.getTileOccupant(xy[0],xy[1])!=account)return(0,totalPoints,0);
        points=land.pointsByCoords(xy[0],xy[1]);
        if(totalPoints!=0)amount=_mulDiv(initialPool,points,totalPoints);
    }
    function claim(address recipient) rpcIndexed external nonReentrant {
        if(!ended())revert WorldStillOpen();
        if(claimed[msg.sender])revert AlreadyClaimed();
        require(recipient!=address(0)&&recipient!=address(this),"Invalid recipient");
        (uint256 points,,uint256 amount)=entitlement(msg.sender);
        if(amount==0)revert NoReward();
        claimed[msg.sender]=true;totalClaimed+=amount;
        uint256 beforeBalance=IRewardToken(token).balanceOf(recipient);
        uint256 poolBefore=IRewardToken(token).balanceOf(address(this));
        _transfer(abi.encodeWithSignature("transfer(address,uint256)",recipient,amount));
        uint256 receivedBalance=IRewardToken(token).balanceOf(recipient);
        uint256 poolAfter=IRewardToken(token).balanceOf(address(this));
        // Both sides must move the exact entitlement. Reverting also restores the claim.
        require(receivedBalance>=beforeBalance&&receivedBalance-beforeBalance==amount, "Reward credit mismatch");
        require(poolBefore>=poolAfter&&poolBefore-poolAfter==amount, "Reward debit mismatch");
        emit RewardClaimed(msg.sender,recipient,points,amount);
    }
    function treasuryRemainder() public view returns(uint256){
        return ended()&&land.totalRealmPoints()==0?initialPool-totalClaimed:0;
    }
    event EmptyWorldPoolWithdrawn(address indexed treasury,address indexed recipient,uint256 amount);
    function withdrawTreasuryRemainder(address recipient) rpcIndexed external nonReentrant{
        require(msg.sender==land.extraFeeRecipient(),"Only treasury");
        require(recipient!=address(0)&&recipient!=address(this),"Invalid recipient");
        uint256 amount=treasuryRemainder();require(amount>0,"No treasury reward");
        totalClaimed+=amount;
        WalletClaimStatus.mark(msg.sender,2);
        uint256 beforeBalance=IRewardToken(token).balanceOf(recipient);
        uint256 poolBefore=IRewardToken(token).balanceOf(address(this));
        _transfer(abi.encodeWithSignature("transfer(address,uint256)",recipient,amount));
        require(IRewardToken(token).balanceOf(recipient)==beforeBalance+amount,"Reward credit mismatch");
        require(IRewardToken(token).balanceOf(address(this))+amount==poolBefore,"Reward debit mismatch");
        emit EmptyWorldPoolWithdrawn(msg.sender,recipient,amount);
    }
    function _transfer(bytes memory data) private {
        (bool success,bytes memory result)=token.call(data);
        if(!success||(result.length!=0&&(result.length!=32||!abi.decode(result,(bool)))))revert TokenTransferFailed();
    }
    // Exact floor(x*y/d) with a 512-bit intermediate. The final result is <= the funded pool.
    function _mulDiv(uint256 x,uint256 y,uint256 d) private pure returns(uint256 result){
        unchecked {
            uint256 low;uint256 high;
            assembly("memory-safe"){let mm:=mulmod(x,y,not(0)) low:=mul(x,y) high:=sub(sub(mm,low),lt(mm,low))}
            if(high==0)return low/d;
            require(d>high,"Reward overflow");
            uint256 remainder;
            assembly("memory-safe"){remainder:=mulmod(x,y,d) high:=sub(high,gt(remainder,low)) low:=sub(low,remainder)}
            uint256 twos=d&(~d+1);
            assembly("memory-safe"){d:=div(d,twos) low:=div(low,twos) twos:=add(div(sub(0,twos),twos),1)}
            low|=high*twos;
            uint256 inverse=(3*d)^2;
            inverse*=2-d*inverse;inverse*=2-d*inverse;inverse*=2-d*inverse;
            inverse*=2-d*inverse;inverse*=2-d*inverse;inverse*=2-d*inverse;
            return low*inverse;
        }
    }
}
