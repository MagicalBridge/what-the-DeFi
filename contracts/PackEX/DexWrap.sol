pragma solidity =0.8.17 >=0.5.16 >=0.7.6 ^0.8.0 ^0.8.1;

contract DexWrap {
    address public owner;
    uint256 public constant FEE_PERCENTAGE = 15; // 0.15% fee
    uint256 public constant FEE_DENOMINATOR = 10000;

    address private constant ETH_ADDRESS = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);

    constructor(address _owner) {
        owner = _owner;
    }

    /**
     * @param aggregatorAddress
     * @param fromToken:
     * @param amount
     * @param aggregatorData
     */
    function wrapAndExecute(address aggregatorAddress, address fromToken, uint256 amount, bytes calldata aggregatorData)
        external
        payable
    {
        uint256 fee = (amount * feeRate) / 10000; // Calculate 0.15% fee
    }
}
