// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

import { ERC20Burnable, ERC20 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";


abstract contract  DSCoin is ERC20Burnable, Ownable {
    error DSCoin__AmountMustBeMoreThanZero();   
    error DSCoin__BurnAmountExceedsBalance();
    error DSCoin__NotZeroAddress();

    
    constructor(string memory name , string memory symbol) ERC20("DSCoin", "DSC") { 
        // _name = name;
        // _symbol = symbol;
    }

    function burn(uint256 _amount) public override onlyOwner {
        uint256 balance = balanceOf(msg.sender);
        if (_amount <= 0) {
            revert DSCoin__AmountMustBeMoreThanZero();
        }
        if (balance < _amount) {
            revert DSCoin__BurnAmountExceedsBalance();
        }
        super.burn(_amount);
    }

    function mint(address _to, uint256 _amount) external onlyOwner returns (bool) {
        if (_to == address(0)) {
            revert DSCoin__NotZeroAddress();
        }
        if (_amount <= 0) {
            revert DSCoin__AmountMustBeMoreThanZero();
        }
        _mint(_to, _amount);
        return true;
    }
}