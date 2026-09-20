// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
contract TestToken is ERC20 {
    constructor(string memory symbol_) ERC20(symbol_, symbol_) {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
