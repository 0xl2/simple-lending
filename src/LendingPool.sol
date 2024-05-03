// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ILToken} from "./interface/ILToken.sol";
import {ILendingPool} from "./interface/ILendingPool.sol";
import {WadRayMath} from "./utils/WadRayMath.sol";

import "./utils/Errors.sol";

contract LendingPool is Ownable, ILendingPool {
    using SafeERC20 for IERC20;
    using WadRayMath for uint256;

    uint256 internal _reservesCount;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    address public collateralManager;

    mapping(address => ReserveData) internal _reserves;
    mapping(uint256 => address) internal _reservesList;

    constructor(address _owner) Ownable(_owner) {}

    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf
    ) external override {
        if (amount == 0) revert ZERO_AMOUNT();

        ReserveData storage reserve = _reserves[asset];
        address lToken = reserve.lTokenAddress;

        // transfer tokens
        IERC20(asset).safeTransferFrom(msg.sender, lToken, amount);

        // mint lToken
        ILToken(lToken).mint(onBehalfOf, amount, reserve.liquidityIndex);

        // emit event
        emit Deposit(asset, msg.sender, onBehalfOf, amount);
    }

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256) {
        if (amount == 0) revert ZERO_AMOUNT();

        ReserveData storage reserve = _reserves[asset];
        address lToken = reserve.lTokenAddress;

        uint256 userBalance = ILToken(lToken).balanceOf(msg.sender);

        uint256 amountToWithdraw = amount > userBalance ? userBalance : amount;

        // ValidationLogic.validateWithdraw(
        //     asset,
        //     amountToWithdraw,
        //     userBalance,
        //     _reserves,
        //     _usersConfig[msg.sender],
        //     _reservesList,
        //     _reservesCount,
        //     _addressesProvider.getPriceOracle()
        // );
        // reserve.updateState();
        // reserve.updateInterestRates(asset, lToken, 0, amountToWithdraw);

        ILToken(lToken).burn(
            msg.sender,
            to,
            amountToWithdraw,
            reserve.liquidityIndex
        );

        emit Withdraw(asset, msg.sender, to, amountToWithdraw);

        return amountToWithdraw;
    }

    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        address onBehalfOf
    ) external {
        ReserveData storage reserve = _reserves[asset];

        // _executeBorrow(
        //     ExecuteBorrowParams(
        //         asset,
        //         msg.sender,
        //         onBehalfOf,
        //         amount,
        //         interestRateMode,
        //         reserve.lTokenAddress,
        //         true
        //     )
        // );
    }

    function repay(
        address asset,
        uint256 amount,
        uint256 rateMode,
        address onBehalfOf
    ) external override returns (uint256) {
        ReserveData storage reserve = _reserves[asset];

        // (uint256 stableDebt, uint256 variableDebt) = Helpers.getUserCurrentDebt(
        //     onBehalfOf,
        //     reserve
        // );

        // DataTypes.InterestRateMode interestRateMode = DataTypes
        //     .InterestRateMode(rateMode);

        // ValidationLogic.validateRepay(
        //     reserve,
        //     amount,
        //     interestRateMode,
        //     onBehalfOf,
        //     stableDebt,
        //     variableDebt
        // );

        // uint256 paybackAmount = interestRateMode ==
        //     DataTypes.InterestRateMode.STABLE
        //     ? stableDebt
        //     : variableDebt;

        // if (amount < paybackAmount) {
        //     paybackAmount = amount;
        // }

        // reserve.updateState();

        // if (interestRateMode == DataTypes.InterestRateMode.STABLE) {
        //     IStableDebtToken(reserve.stableDebtTokenAddress).burn(
        //         onBehalfOf,
        //         paybackAmount
        //     );
        // } else {
        //     IVariableDebtToken(reserve.variableDebtTokenAddress).burn(
        //         onBehalfOf,
        //         paybackAmount,
        //         reserve.variableBorrowIndex
        //     );
        // }

        // address lToken = reserve.lTokenAddress;
        // reserve.updateInterestRates(asset, lToken, paybackAmount, 0);

        // if (stableDebt.add(variableDebt).sub(paybackAmount) == 0) {
        //     _usersConfig[onBehalfOf].setBorrowing(reserve.id, false);
        // }

        // IERC20(asset).safeTransferFrom(msg.sender, lToken, paybackAmount);

        // ILToken(lToken).handleRepayment(msg.sender, paybackAmount);

        // emit Repay(asset, onBehalfOf, msg.sender, paybackAmount);

        // return paybackAmount;
    }

    function liquidationCall(
        address collateralAsset,
        address debtAsset,
        address user,
        uint256 debtToCover,
        bool receiveLToken
    ) external override {
        //solium-disable-next-line
        (bool success, bytes memory result) = collateralManager.delegatecall(
            abi.encodeWithSignature(
                "liquidationCall(address,address,address,uint256,bool)",
                collateralAsset,
                debtAsset,
                user,
                debtToCover,
                receiveLToken
            )
        );

        if (!success) revert LP_LIQUIDATION_CALL_FAILED();

        (uint256 returnCode, string memory returnMessage) = abi.decode(
            result,
            (uint256, string)
        );

        require(returnCode == 0, string(abi.encodePacked(returnMessage)));
    }

    function getReservesList()
        external
        view
        override
        returns (address[] memory)
    {
        address[] memory _activeReserves = new address[](_reservesCount);

        for (uint256 i = 0; i < _reservesCount; i++) {
            _activeReserves[i] = _reservesList[i];
        }

        return _activeReserves;
    }

    function getReserveNormalizedIncome(
        address asset
    ) external view returns (uint256) {
        ReserveData memory reserve = _reserves[asset];

        //solium-disable-next-line
        if (reserve.lastUpdateTimestamp == block.timestamp) {
            //if the index was updated in the same block, no need to perform any calculation
            return reserve.liquidityIndex;
        }

        uint256 cumulated = ((reserve.currentLiquidityRate *
            (block.timestamp - reserve.lastUpdateTimestamp)) /
            SECONDS_PER_YEAR) + WadRayMath.ray();

        return cumulated.rayMul(reserve.liquidityIndex);
    }
}
