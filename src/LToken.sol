// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {ILToken} from "./interface/ILToken.sol";
import {ILendingPool} from "./interface/ILendingPool.sol";
import {WadRayMath} from "./utils/WadRayMath.sol";

import "./utils/Errors.sol";

/**
 * @title Starlay ERC20 LToken
 * @dev Implementation of the interest bearing token for the Starlay protocol
 * @author Starlay
 */
contract LToken is Ownable, ERC20 {
    using WadRayMath for uint256;
    using SafeERC20 for IERC20;

    mapping(address => uint256) internal _balances;

    uint256 public constant LTOKEN_REVISION = 0x1;
    uint256 internal _totalSupply;

    ILendingPool internal _pool;
    address internal _treasury;
    address internal _underlyingAsset;

    modifier onlyLendingPool() {
        if (_msgSender() != address(_pool))
            revert CT_CALLER_MUST_BE_LENDING_POOL();
        _;
    }

    event Initialized(
        address indexed underlyingAsset,
        address indexed pool,
        address treasury,
        string lTokenName,
        string lTokenSymbol
    );

    /**
     * @dev Emitted after the mint action
     * @param from The address performing the mint
     * @param value The amount being
     * @param index The new liquidity index of the reserve
     **/
    event Mint(address indexed from, uint256 value, uint256 index);

    /**
     * @dev Emitted after lTokens are burned
     * @param from The owner of the lTokens, getting them burned
     * @param target The address that will receive the underlying
     * @param value The amount being burned
     * @param index The new liquidity index of the reserve
     **/
    event Burn(
        address indexed from,
        address indexed target,
        uint256 value,
        uint256 index
    );

    /**
     * @dev Emitted during the transfer action
     * @param from The user whose tokens are being transferred
     * @param to The recipient
     * @param value The amount being transferred
     * @param index The new liquidity index of the reserve
     **/
    event BalanceTransfer(
        address indexed from,
        address indexed to,
        uint256 value,
        uint256 index
    );

    function getRevision() internal pure virtual returns (uint256) {
        return LTOKEN_REVISION;
    }

    /**
     * @dev Constructor of the lToken
     * @param pool The address of the lending pool where this lToken will be used
     * @param treasury The address of the Starlay treasury, receiving the fees on this lToken
     * @param underlyingAsset The address of the underlying asset of this lToken (E.g. WETH for lWETH)
     * @param lTokenName The name of the lToken
     * @param lTokenSymbol The symbol of the lToken
     */
    constructor(
        ILendingPool pool,
        address treasury,
        address underlyingAsset,
        string memory lTokenName,
        string memory lTokenSymbol
    ) Ownable(msg.sender) ERC20(lTokenName, lTokenSymbol) {
        if (address(pool) == address(0)) revert ZERO_ADDRESS();

        if (treasury == address(0)) revert ZERO_ADDRESS();
        if (underlyingAsset == address(0)) revert ZERO_ADDRESS();

        _pool = pool;
        _treasury = treasury;
        _underlyingAsset = underlyingAsset;

        emit Initialized(
            underlyingAsset,
            address(pool),
            treasury,
            lTokenName,
            lTokenSymbol
        );
    }

    function _mintToken(address account, uint256 amount) internal {
        if (account == address(0)) revert ZERO_ADDRESS();

        _totalSupply = _totalSupply + amount;
        _balances[account] = _balances[account] + amount;
    }

    function _burnToken(address account, uint256 amount) internal {
        if (account == address(0)) revert ZERO_ADDRESS();

        _totalSupply = _totalSupply - amount;

        if (_balances[account] < amount) revert CT_BURN_EXCEEDS_BALANCE();
        _balances[account] = _balances[account] - amount;
    }

    /**
     * @dev Burns lTokens from `user` and sends the equivalent amount of underlying to `receiverOfUnderlying`
     * - Only callable by the LendingPool, as extra state updates there need to be managed
     * @param user The owner of the lTokens, getting them burned
     * @param receiverOfUnderlying The address that will receive the underlying
     * @param amount The amount being burned
     * @param index The new liquidity index of the reserve
     **/
    function burn(
        address user,
        address receiverOfUnderlying,
        uint256 amount,
        uint256 index
    ) external onlyLendingPool {
        uint256 amountScaled = amount.rayDiv(index);
        if (amountScaled == 0) revert CT_INVALID_BURN_AMOUNT();

        _burnToken(user, amountScaled);

        IERC20(_underlyingAsset).safeTransfer(receiverOfUnderlying, amount);

        emit Transfer(user, address(0), amount);
        emit Burn(user, receiverOfUnderlying, amount, index);
    }

    /**
     * @dev Mints `amount` lTokens to `user`
     * - Only callable by the LendingPool, as extra state updates there need to be managed
     * @param user The address receiving the minted tokens
     * @param amount The amount of tokens getting minted
     * @param index The new liquidity index of the reserve
     * @return `true` if the the previous balance of the user was 0
     */
    function mint(
        address user,
        uint256 amount,
        uint256 index
    ) external onlyLendingPool returns (bool) {
        uint256 previousBalance = _balances[user];

        uint256 amountScaled = amount.rayDiv(index);
        if (amountScaled == 0) revert CT_INVALID_MINT_AMOUNT();

        _mintToken(user, amountScaled);

        emit Transfer(address(0), user, amount);
        emit Mint(user, amount, index);

        return previousBalance == 0;
    }

    /**
     * @dev Mints lTokens to the reserve treasury
     * - Only callable by the LendingPool
     * @param amount The amount of tokens getting minted
     * @param index The new liquidity index of the reserve
     */
    function mintToTreasury(
        uint256 amount,
        uint256 index
    ) external onlyLendingPool {
        if (amount == 0) {
            return;
        }

        // Compared to the normal mint, we don't check for rounding errors.
        // The amount to mint can easily be very small since it is a fraction of the interest ccrued.
        // In that case, the treasury will experience a (very small) loss, but it
        // wont cause potentially valid transactions to fail.
        _mintToken(_treasury, amount.rayDiv(index));

        emit Transfer(address(0), _treasury, amount);
        emit Mint(_treasury, amount, index);
    }

    /**
     * @dev Transfers lTokens in the event of a borrow being liquidated, in case the liquidators reclaims the lToken
     * - Only callable by the LendingPool
     * @param from The address getting liquidated, current owner of the lTokens
     * @param to The recipient
     * @param value The amount of tokens getting transferred
     **/
    function transferOnLiquidation(
        address from,
        address to,
        uint256 value
    ) external onlyLendingPool {
        // Being a normal transfer, the Transfer() and BalanceTransfer() are emitted
        // so no need to emit a specific event here
        _transferToken(from, to, value);

        emit Transfer(from, to, value);
    }

    /**
     * @dev Transfers the underlying asset to `target`. Used by the LendingPool to transfer
     * assets in borrow(), withdraw() and flashLoan()
     * @param target The recipient of the lTokens
     * @param amount The amount getting transferred
     * @return The amount transferred
     **/
    function transferUnderlyingTo(
        address target,
        uint256 amount
    ) external onlyLendingPool returns (uint256) {
        IERC20(_underlyingAsset).safeTransfer(target, amount);
        return amount;
    }

    /**
     * @dev Calculates the balance of the user: principal balance + interest generated by the principal
     * @param user The user whose balance is calculated
     * @return The balance of the user
     **/
    function balanceOf(address user) public view override returns (uint256) {
        return
            _balances[user].rayMul(
                _pool.getReserveNormalizedIncome(_underlyingAsset)
            );
    }

    /**
     * @dev Returns the scaled balance of the user. The scaled balance is the sum of all the
     * updated stored balance divided by the reserve's liquidity index at the moment of the update
     * @param user The user whose balance is calculated
     * @return The scaled balance of the user
     **/
    function scaledBalanceOf(address user) external view returns (uint256) {
        return _balances[user];
    }

    /**
     * @dev Returns the scaled balance of the user and the scaled total supply.
     * @param user The address of the user
     * @return The scaled balance of the user
     * @return The scaled balance and the scaled total supply
     **/
    function getScaledUserBalanceAndSupply(
        address user
    ) external view returns (uint256, uint256) {
        return (_balances[user], _totalSupply);
    }

    /**
     * @dev calculates the total supply of the specific lToken
     * since the balance of every single user increases over time, the total supply
     * does that too.
     * @return the current total supply
     **/
    function totalSupply() public view override returns (uint256) {
        uint256 currentSupplyScaled = _totalSupply;

        if (currentSupplyScaled == 0) {
            return 0;
        }

        return
            currentSupplyScaled.rayMul(
                _pool.getReserveNormalizedIncome(_underlyingAsset)
            );
    }

    /**
     * @dev Returns the scaled total supply of the variable debt token. Represents sum(debt/index)
     * @return the scaled total supply
     **/
    function scaledTotalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    /**
     * @dev Returns the address of the Starlay treasury, receiving the fees on this lToken
     **/
    function RESERVE_TREASURY_ADDRESS() public view returns (address) {
        return _treasury;
    }

    /**
     * @dev Returns the address of the underlying asset of this lToken (E.g. WETH for lWETH)
     **/
    function UNDERLYING_ASSET_ADDRESS() public view returns (address) {
        return _underlyingAsset;
    }

    /**
     * @dev Returns the address of the lending pool where this lToken is used
     **/
    function POOL() public view returns (ILendingPool) {
        return _pool;
    }

    /**
     * @dev Transfers the lTokens between two users. Validates the transfer
     * (ie checks for valid HF after the transfer) if required
     * @param from The source address
     * @param to The destination address
     * @param amount The amount getting transferred
     **/
    function _transferToken(address from, address to, uint256 amount) internal {
        if (from == address(0)) revert ZERO_ADDRESS();
        if (to == address(0)) revert ZERO_ADDRESS();

        address underlyingAsset = _underlyingAsset;
        ILendingPool pool = _pool;

        uint256 index = pool.getReserveNormalizedIncome(underlyingAsset);
        amount = amount.rayDiv(index);

        if (amount > _balances[from]) revert CT_TRANSFER_EXCEEDS_BALANCE();
        _balances[from] = _balances[from] - amount;
        _balances[to] = _balances[to] + amount;

        emit BalanceTransfer(from, to, amount, index);
    }
}
