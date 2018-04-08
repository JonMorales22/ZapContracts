pragma solidity ^0.4.19;
// v1.0

import "../lib/Mortal.sol";
import "../lib/update/Updatable.sol";
import "../lib/ERC20.sol";
import "../lib/addressSpace/AddressSpace.sol";
import "../lib/addressSpace/AddressSpacePointer.sol";
import "./currentCost/CurrentCostInterface.sol";
import "./BondageStorage.sol";

contract Bondage is Mortal, Updatable {

    event Bound(address indexed holder, address indexed oracle, bytes32 indexed endpoint, uint256 numTok);
    event Unbound(address indexed holder, address indexed oracle, bytes32 indexed endpoint, uint256 numDots);
    event Escrowed(address indexed holder, address indexed oracle, bytes32 indexed endpoint, uint256 numDots);
    event Released(address indexed holder, address indexed oracle, bytes32 indexed endpoint, uint256 numDots);

    BondageStorage stor;
    CurrentCostInterface public currentCost;
    ERC20 token;
    uint256 decimals = 10 ** 18;

    AddressSpacePointer pointer;
    AddressSpace addresses;

    address public storageAddress;
    address arbiterAddress;
    address dispatchAddress;

    // For restricting dot escrow/transfer method calls to Dispatch and Arbiter
    modifier operatorOnly {
        if (msg.sender == arbiterAddress || msg.sender == dispatchAddress)
            _;
    }

    /// @dev Initialize Storage, Token, anc CurrentCost Contracts
    function Bondage(address pointerAddress, address _storageAddress, address tokenAddress) public {
        storageAddress = _storageAddress;
        stor = BondageStorage(storageAddress);
        token = ERC20(tokenAddress);
        pointer = AddressSpacePointer(pointerAddress);
    }

    // Called on deployment to initialize arbiterAddress and dispatchAddress
    function updateContract() external {
        if (addresses != pointer.addresses()) addresses = AddressSpace(pointer.addresses());        
        if (arbiterAddress != addresses.arbiter()) arbiterAddress = addresses.arbiter();
        if (dispatchAddress != addresses.dispatch()) dispatchAddress = addresses.dispatch();
        currentCost = addresses.instantiateCurrentCost(currentCost);
    }

    /// @dev will bond to an oracle
    /// @return total TOK bound to oracle
    function bond(address oracleAddress, bytes32 endpoint, uint256 numTok) external returns (uint256 bound) {
        bound = _bond(msg.sender, oracleAddress, endpoint, numTok);
        Bound(msg.sender, oracleAddress, endpoint, numTok);
    }

    /// @return total TOK unbound from oracle
    function unbond(address oracleAddress, bytes32 endpoint, uint256 numDots) external returns (uint256 unbound) {
        unbound = _unbond(msg.sender, oracleAddress, endpoint, numDots);
        Unbound(msg.sender, oracleAddress, endpoint, numDots);
    }        

    /// @dev will bond to an oracle on behalf of some holder
    /// @return total TOK bound to oracle
    function delegateBond(address holderAddress, address oracleAddress, bytes32 endpoint, uint256 numTok) external returns (uint256 bound) {
        require(stor.getDelegate(holderAddress, oracleAddress) == 0x0);
        stor.setDelegate(holderAddress, oracleAddress, msg.sender);
        bound = _bond(holderAddress, oracleAddress, endpoint, numTok);
        Bound(holderAddress, oracleAddress, endpoint, numTok);
    }

    /// @return total TOK unbound from oracle
    function delegateUnbond(address holderAddress, address oracleAddress, bytes32 endpoint, uint256 numDots) external returns (uint256 unbound) {
        require(stor.getDelegate(holderAddress, oracleAddress) == msg.sender);
        unbound = _unbond(holderAddress, oracleAddress, endpoint, numDots);
        Unbound(holderAddress, oracleAddress, endpoint, numDots);
    }

    /// @dev will reset delegate 
    function resetDelegate(address oracleAddress) external {
        stor.deleteDelegate(msg.sender, oracleAddress);
    }

    /// @dev Move numDots dots from provider-requester to bondage according to 
    /// data-provider address, holder address, and endpoint specifier (ala 'smart_contract')
    /// Called only by Disptach or Arbiter Contracts
    function escrowDots(        
        address holderAddress,
        address oracleAddress,
        bytes32 endpoint,
        uint256 numDots
    )
        external
        operatorOnly        
        returns (bool success)
    {
        uint256 currentDots = getDots(holderAddress, oracleAddress, endpoint);
        uint256 dotsToEscrow = numDots;
        if (numDots > currentDots) dotsToEscrow = currentDots; 
        stor.updateBondValue(holderAddress, oracleAddress, endpoint, dotsToEscrow, "sub");
        stor.updateEscrow(holderAddress, oracleAddress, endpoint, dotsToEscrow, "add");
        Escrowed(holderAddress, oracleAddress, endpoint, dotsToEscrow);
        return true;
    }

    /// @dev Transfer N dots from fromAddress to destAddress. 
    /// Called only by Disptach or Arbiter Contracts
    /// In smart contract endpoint, occurs per satisfied request. 
    /// In socket endpoint called on termination of subscription.
    function releaseDots(
        address holderAddress,
        address oracleAddress,
        bytes32 endpoint,
        uint256 numDots
    )
        external
        operatorOnly 
        returns (bool success)
    {
        uint256 numEscrowed = stor.getNumEscrow(holderAddress, oracleAddress, endpoint);
        uint256 dotsToEscrow = numDots;
        if (numDots > numEscrowed) dotsToEscrow = numEscrowed;
        stor.updateEscrow(holderAddress, oracleAddress, endpoint, dotsToEscrow, "sub");
        stor.updateBondValue(oracleAddress, oracleAddress, endpoint, dotsToEscrow, "add");
        Released(holderAddress, oracleAddress, endpoint, dotsToEscrow);
        return true;
    }

    /// @dev Calculate quantity of tokens required for specified amount of dots
    /// for endpoint defined by endpoint and data provider defined by oracleAddress
    function calcTokForDots(
        address oracleAddress,
        bytes32 endpoint,
        uint256 numDots       
    ) 
        external
        view
        returns (uint256 numTok)
    {
        for (uint256 i = 0; i < numDots; i++) {
            numTok += currentCostOfDot(                
                oracleAddress,
                endpoint,
                getDotsIssued(oracleAddress, endpoint) + i
            );
        }
        return numTok;
    }

    /// @dev Calculate amount of dots which could be purchased with given (numTok) TOK tokens (max is 1000)
    /// for endpoint specified by endpoint and data-provider address specified by oracleAddress
    function calcBondRate(
        address oracleAddress,
        bytes32 endpoint,
        uint256 numTok
    )
        public
        view
        returns (uint256 maxNumTok, uint256 numDots) 
    {
        uint256 infinity = decimals;
        uint256 dotCost;
        if (numTok > 1000) numTok = 1000;

        for (numDots; numDots < infinity; numDots++) {
            dotCost = currentCostOfDot(
                oracleAddress,
                endpoint,
                getDotsIssued(oracleAddress, endpoint) + numDots
            );

            if (numTok >= dotCost) {
                numTok -= dotCost;
                maxNumTok += dotCost;
            } else {
                break;
            }
        }
        return (maxNumTok, numDots);
    }

    /// @dev Get the current cost of a dot.
    /// @param endpoint specifier
    /// @param oracleAddress data-provider
    function currentCostOfDot(
        address oracleAddress,
        bytes32 endpoint,
        uint256 totalBound
    )
        public
        view
        returns (uint256 cost)
    {
        return currentCost._currentCostOfDot(oracleAddress, endpoint, totalBound);
    }

    function getDotsIssued(
        address oracleAddress,
        bytes32 endpoint        
    )        
        public
        view
        returns (uint256 dots)
    {
        return stor.getTotalDots(oracleAddress, endpoint);
    }

    function getDots(        
        address holderAddress,
        address oracleAddress,
        bytes32 endpoint
    )
        public
        view        
        returns (uint256 dots)
    {
        return stor.getBoundDots(holderAddress, oracleAddress, endpoint);
    }

    /// @return total TOK held by contract
    function getTokBound(address oracleAddress, bytes32 endpoint) public view returns (uint256) {
        return stor.getNumTok(oracleAddress, endpoint);
    }

    function _bond(
        address holderAddress,
        address oracleAddress,
        bytes32 endpoint,
        uint256 numTok        
    )
        private
        returns (uint256 numDots) 
    {   
        // This also checks if oracle is registered w/an initialized curve
        (numTok, numDots) = calcBondRate(oracleAddress, endpoint, numTok);

        if (!stor.isProviderInitialized(holderAddress, oracleAddress)) {            
            stor.setProviderInitialized(holderAddress, oracleAddress);
            stor.addHolderOracle(holderAddress, oracleAddress);
        }

        // User must have approved contract to transfer workingTOK
        require(token.transferFrom(msg.sender, this, numTok * decimals));

        stor.updateBondValue(holderAddress, oracleAddress, endpoint, numDots, "add");        
        stor.updateTotalIssued(oracleAddress, endpoint, numDots, "add");
        stor.updateTotalBound(oracleAddress, endpoint, numTok, "add");

        return numDots;
    }

    function _unbond(        
        address holderAddress,
        address oracleAddress,
        bytes32 endpoint,
        uint256 numDots
    )
        private
        returns (uint256 numTok)
    {
        //currentDots
        uint256 bondValue = stor.getBondValue(holderAddress, oracleAddress, endpoint);
        if (bondValue >= numDots && numDots > 0) {

            uint256 subTotal = 1;
            uint256 dotsIssued;

            for (subTotal; subTotal < numDots; subTotal++) {

                dotsIssued = getDotsIssued(oracleAddress, endpoint) - subTotal;

                numTok += currentCostOfDot(
                    oracleAddress,
                    endpoint,
                    dotsIssued
                ); 
            }    
            stor.updateTotalBound(oracleAddress, endpoint, numTok, "sub");
            stor.updateTotalIssued(oracleAddress, endpoint, numDots, "sub");
            stor.updateBondValue(holderAddress, oracleAddress, endpoint, subTotal, "sub");

            if(token.transfer(holderAddress, numTok * decimals))
                return numTok;
        }
        return 0;
    }

    //log based 2 taylor series in assembly
    function fastlog2(uint256 x) private pure returns (uint256 y) {
        assembly {
            let arg := x
            x := sub(x, 1)
            x := or(x, div(x, 0x02))
            x := or(x, div(x, 0x04))
            x := or(x, div(x, 0x10))
            x := or(x, div(x, 0x100))
            x := or(x, div(x, 0x10000))
            x := or(x, div(x, 0x100000000))
            x := or(x, div(x, 0x10000000000000000))
            x := or(x, div(x, 0x100000000000000000000000000000000))
            x := add(x, 1)
            let m := mload(0x40)
            mstore(m, 0xf8f9cbfae6cc78fbefe7cdc3a1793dfcf4f0e8bbd8cec470b6a28a7a5a3e1efd)
            mstore(add(m, 0x20), 0xf5ecf1b3e9debc68e1d9cfabc5997135bfb7a7a3938b7b606b5b4b3f2f1f0ffe)
            mstore(add(m, 0x40), 0xf6e4ed9ff2d6b458eadcdf97bd91692de2d4da8fd2d0ac50c6ae9a8272523616)
            mstore(add(m, 0x60), 0xc8c0b887b0a8a4489c948c7f847c6125746c645c544c444038302820181008ff)
            mstore(add(m, 0x80), 0xf7cae577eec2a03cf3bad76fb589591debb2dd67e0aa9834bea6925f6a4a2e0e)
            mstore(add(m, 0xa0), 0xe39ed557db96902cd38ed14fad815115c786af479b7e83247363534337271707)
            mstore(add(m, 0xc0), 0xc976c13bb96e881cb166a933a55e490d9d56952b8d4e801485467d2362422606)
            mstore(add(m, 0xe0), 0x753a6d1b65325d0c552a4d1345224105391a310b29122104190a110309020100)
            mstore(0x40, add(m, 0x100))
            let magic := 0x818283848586878898a8b8c8d8e8f929395969799a9b9d9e9faaeb6bedeeff
            let shift := 0x100000000000000000000000000000000000000000000000000000000000000
            let a := div(mul(x, magic), shift)
            y := div(mload(add(m, sub(255, a))), shift)
            y := add(y, mul(256, gt(arg, 0x8000000000000000000000000000000000000000000000000000000000000000)))
        }
    }
}