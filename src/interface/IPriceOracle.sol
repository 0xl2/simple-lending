// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/************
@title IPriceOracle interface
*/
interface IPriceOracle {
    /***********
    @dev returns the asset price in ETH
     */
    function getAssetPrice(address asset) external view returns (uint256);

    /***********
    @dev sets the asset price, in wei
     */
    function setAssetPrice(address asset, uint256 price) external;
}
