pragma solidity ^0.4.19;

import "..//Mortal.sol";
import "../addressSpace/AddressSpace.sol";
import "../addressSpace/AddressSpacePointer.sol";

interface UpdatableContract { function updateContract() external; }

contract Update is Mortal {

    AddressSpacePointer pointer;
    AddressSpace addresses;

    UpdatableContract bondage;
    UpdatableContract arbiter;
    UpdatableContract dispatch;
    UpdatableContract currentCost;

    function Update(address pointerAddress) public {
        pointer = AddressSpacePointer(pointerAddress);
        addresses = AddressSpace(pointer.addresses());
        bondage = UpdatableContract(addresses.bondage());
        arbiter = UpdatableContract(addresses.arbiter());
        dispatch = UpdatableContract(addresses.dispatch());
        currentCost = UpdatableContract(addresses.currentCost());
    }

    // Update all UpdatableContracts in the Dapp (called upon deployment as well to initialize abstract contracts)
    function updateContracts() external {
        if (addresses != pointer.addresses()) addresses = AddressSpace(pointer.addresses());
     /*
        if (bondage != addresses.bondage()) bondage = UpdatableContract(addresses.bondage());
        if (arbiter != addresses.arbiter()) arbiter = UpdatableContract(addresses.arbiter());
        if (dispatch != addresses.dispatch()) dispatch = UpdatableContract(addresses.dispatch());
        if (currentCost != addresses.currentCost()) currentCost = UpdatableContract(addresses.currentCost());
    */
        currentCost.updateContract();
        bondage.updateContract();
        arbiter.updateContract();
        dispatch.updateContract();        
    }
}
