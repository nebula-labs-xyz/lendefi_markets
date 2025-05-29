// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * @title ILendefiVault
 * @notice Interface for the Lendefi vault that isolates user position collateral
 */
interface IVAULT {
    /// @notice Returns the address of the protocol that controls this vault
    function protocol() external view returns (address);

    /// @notice Returns the address of the vault owner
    function owner() external view returns (address);

    /// @notice Sets the owner of the vault (only callable by protocol during position creation)
    /// @param _owner Address of the new owner
    function setOwner(address _owner) external;

    /// @notice Transfers tokens from the vault to the owner
    /// @param token Address of the token to transfer
    /// @param amount Amount to transfer
    function withdrawToken(address token, uint256 amount) external;

    /// @notice Transfers multiple token types to the liquidator during liquidation
    /// @param tokens Array of token addresses to liquidate
    /// @param liquidator Address receiving the tokens
    function liquidate(address[] calldata tokens, address liquidator) external;
}
