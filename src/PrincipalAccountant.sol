// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title PrincipalAccountant
 * @notice Fixed 1:1 rate accountant for the BoringVault.
 *         Returns 1e6 (1 USDC, 6 decimals) per share, ensuring yield
 *         is never reflected in the share price (it is extracted separately).
 */
interface IAccountant {
    function getRate() external view returns (uint256);
    function decimals() external view returns (uint8);
}

contract PrincipalAccountant is IAccountant {
    /// @notice The BoringVault this accountant serves
    address public immutable vault;

    /// @notice The USDC token address on Base
    address public immutable usdc;

    constructor(address _vault, address _usdc) {
        require(_vault != address(0), "PrincipalAccountant: zero vault");
        require(_usdc != address(0), "PrincipalAccountant: zero usdc");
        vault = _vault;
        usdc = _usdc;
    }

    /**
     * @notice Returns 1e6 — always 1 USDC per vUSDC share (6 decimals).
     *         This constant rate prevents yield from inflating the share price.
     */
    function getRate() public pure override returns (uint256) {
        return 1e6;
    }

    /**
     * @notice Returns the decimals of the rate (matches USDC).
     */
    function decimals() public pure override returns (uint8) {
        return 6;
    }

    /**
     * @notice Deployment sanity check: rate / 10**decimals must equal 1.
     */
    function validateRatePeg() external pure returns (bool) {
        return getRate() / (10 ** uint256(decimals())) == 1;
    }
}
