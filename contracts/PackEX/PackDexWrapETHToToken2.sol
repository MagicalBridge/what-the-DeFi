// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

contract PackDexWrapETHToToken {
    address public owner;
    uint256 public constant FEE_PERCENTAGE = 15; // 0.15% fee
    uint256 public constant FEE_DENOMINATOR = 10000;
    address private constant UNISWAP_V2_ROUTER = 0xd0F08FE0B691C6a7b280c8DD5C7bC6D44Ad35e35;
    address userAddress = 0x2b754dEF498d4B6ADada538F01727Ddf67D91A7D;

    receive() external payable {}

    constructor(address _owner) {
        owner = _owner;
    }

    function wrapAndExecute(bytes calldata swapData, uint256 amount) external payable {
        uint256 fee = (amount * FEE_PERCENTAGE) / FEE_DENOMINATOR;

        require(msg.value >= (amount + fee), "Not enough ETH sent");

        (bool success,) = owner.call{value: fee}("");
        require(success, "Paying fee via transfer failed");
        emit FeeReceived(msg.sender, fee);

        (bool successFlag,) = UNISWAP_V2_ROUTER.call{value: msg.value - fee}(swapData);
        require(successFlag, "Paying fee via transfer failed");
    }

    event FeeReceived(address indexed user, uint256 fee);
}
