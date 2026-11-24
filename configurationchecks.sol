// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
/// Stateless, fixed deployment validator. It never writes game state.
contract GameConfigurationValidator {
    error InvalidGameConfiguration(address module,bytes4 getter);
    function word(address target,string memory getter) private view returns(uint256 value){
        bytes4 sel=bytes4(keccak256(bytes(getter)));
        if(target.code.length==0)revert InvalidGameConfiguration(target,sel);
        (bool ok,bytes memory result)=target.staticcall(abi.encodeWithSelector(sel));
        if(!ok||result.length!=32)revert InvalidGameConfiguration(target,sel);
        value=abi.decode(result,(uint256));
    }
    function addr(address target,string memory getter) private view returns(address){return address(uint160(word(target,getter)));}
    function same(address target,string memory getter,address expected) private view{
        if(addr(target,getter)!=expected)revert InvalidGameConfiguration(target,bytes4(keccak256(bytes(getter))));
    }
    function validate(address game) external view {
        address map=addr(game,"tileMapPhaser()");address clan=addr(game,"_clan()");address market=addr(game,"marketplaceAddress()");
        address logistics=addr(game,"logistics()");address stable=addr(game,"stable()");address military=addr(game,"military()");
        address war=addr(game,"clanWar()");address index=addr(game,"readIndex()");address vision=addr(game,"realmVision()");address rewards=addr(game,"worldRewards()");
        same(map,"manager()",market);
        same(clan,"tileMapPhaser()",map);same(clan,"theLand()",game);
        same(market,"tileMapPhaser()",map);same(market,"theLand()",game);same(market,"clanContract()",clan);
        same(stable,"map()",map);same(stable,"land()",game);
        same(military,"map()",map);same(military,"land()",game);
        same(war,"map()",map);same(war,"land()",game);same(war,"clans()",clan);
        same(logistics,"map()",map);same(logistics,"land()",game);same(logistics,"clans()",clan);
        same(logistics,"market()",market);same(logistics,"clanWar()",war);
        same(index,"map()",map);same(index,"land()",game);same(index,"clan()",clan);
        same(index,"logistics()",logistics);same(index,"market()",market);same(index,"clanWar()",war);
        address reader=addr(index,"reader()");
        same(reader,"map()",map);same(reader,"land()",game);same(reader,"clan()",clan);
        same(reader,"logistics()",logistics);same(reader,"military()",military);
        same(vision,"map()",map);same(vision,"land()",game);same(vision,"index()",index);
        same(rewards,"map()",map);same(rewards,"land()",game);
        uint256 end=word(game,"worldEndsAt()");
        if(word(rewards,"endsAt()")!=end||word(rewards,"initialPool()")==0||word(addr(war,"treasurySettlement()"),"worldEndsAt()")!=end)
            revert InvalidGameConfiguration(game,bytes4(0));
    }
}

