// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

abstract contract JourneyRouteTypes {
    struct Route {uint256 id; uint8 kind; uint8 state; int32 sx; int32 sy; int32 tx; int32 ty; uint64 sourceClan; uint64 targetClan; uint256 startedAt; uint256 arrivesAt; uint256 returnStartedAt; uint256 returnsAt; uint256 amount;}
}
abstract contract JourneyRouteSource is JourneyRouteTypes {
    function routeSummaries(uint256[] calldata ids) external view virtual returns(Route[] memory);
}
