// SPDX-License-Identifier: UNLICENSED
// pragma solidity =0.8.17 >=0.5.16 >=0.7.6 ^0.8.0 ^0.8.1;
pragma solidity ^0.8.17;

contract PackDexWrap {
    address public owner;
    uint256 public constant FEE_PERCENTAGE = 15; // 0.15% fee
    uint256 public constant FEE_DENOMINATOR = 10000;
    address private constant ETH_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    constructor(address _owner) {
        owner = _owner;
    }

    function wrapAndExecute(
        address fromToken,
        uint256 amount,
        address uniswapV2Router,
        uint256 amountOutMin,
        bytes calldata uniswapV2swapData
    ) external payable {
        uint256 fee = (amount * FEE_PERCENTAGE) / FEE_DENOMINATOR; // Calculate 0.15% fee
        // native token
        if (fromToken == ETH_ADDRESS) {
            // Transfer amount + fee from sender to this contract
            // require(msg.value >= (amount + fee));
            if (msg.value < (amount + fee)) {
                revert("Insufficient Ether");
            }
            // Send fee to owner address
            (bool success,) = owner.call{value: fee}("");
            if (!success) {
                revert("Paying fee via transfer failed");
            }
            emit FeeReceived(msg.sender, fee);

            // Call the swapExactETHForTokens function on the Uniswap V2 router
            // with the encoded swap data
            (bool swapSuccessFlag,) = uniswapV2Router.call{value: amount}(uniswapV2swapData);
            if (!swapSuccessFlag) {
                revert("Uniswap V2 swap failed");
            }
            emit SwapCompleted(msg.sender, amountOutMin);
        } else {
            // ERC20 token
        }
    }

    /**
     * @notice event emitted every time a fee is received from a user.
     */
    event FeeReceived(address indexed user, uint256 fee);

    event SwapCompleted(address indexed user, uint256 amountOutMin);
}
