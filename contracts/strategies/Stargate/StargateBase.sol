//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "../../interfaces/IStrategy.sol";
import "../../StrategyRouter.sol";

import "../../interfaces/stargate/IStargateFarm.sol";
import "../../interfaces/stargate/IStargateRouter.sol";

import "hardhat/console.sol";

// Base contract to be inherited, works with Stargate LPstaking:
// address on BNB Chain: 0x3052A0F6ab15b4AE1df39962d5DdEFacA86DaB47
// their code on github: https://github.com/stargate-protocol/stargate/blob/main/contracts/LPStaking.sol

/// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
contract StargateBase is Initializable, UUPSUpgradeable, OwnableUpgradeable, IStrategy {
    error CallerUpgrader();

    address internal upgrader;

    ERC20 internal immutable tokenA;
    ERC20 internal immutable lpToken;
    StrategyRouter internal immutable strategyRouter;

    ERC20 internal constant stg = ERC20(0xB0D502E938ed5f4df2E681fE6E419ff29631d62b);
    IStargateFarm internal constant farm = IStargateFarm(0x3052A0F6ab15b4AE1df39962d5DdEFacA86DaB47);
    IStargateRouter internal constant stargateRouter = IStargateRouter(0x4a364f8c717cAAD9A442737Eb7b8A55cc6cf18D8);

    uint256 internal immutable poolId;

    uint256 private immutable LEFTOVER_THRESHOLD_TOKEN_A;
    uint256 private immutable LEFTOVER_THRESHOLD_TOKEN_B;
    uint256 private constant PERCENT_DENOMINATOR = 10000;

    modifier onlyUpgrader() {
        if (msg.sender != address(upgrader)) revert CallerUpgrader();
        _;
    }

    /// @dev construct is intended to initialize immutables on implementation
    constructor(
        StrategyRouter _strategyRouter,
        uint256 _poolId,
        ERC20 _tokenA,
        ERC20 _lpToken
    ) {
        strategyRouter = _strategyRouter;
        poolId = _poolId;
        tokenA = _tokenA;
        lpToken = _lpToken;
        LEFTOVER_THRESHOLD_TOKEN_A = 10**_tokenA.decimals();

        // lock implementation
        _disableInitializers();
    }

    function initialize(address _upgrader) external initializer {
        __Ownable_init();
        __UUPSUpgradeable_init();
        upgrader = _upgrader;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyUpgrader {}

    function depositToken() external view override returns (address) {
        return address(tokenA);
    }

    function deposit(uint256 amount) external override onlyOwner {
        tokenA.approve(address(stargateRouter), amount);

        stargateRouter.addLiquidity(poolId, amount, address(this));

        lpToken.approve(address(farm), amount);
        farm.deposit(poolId, amount);
    }

    function withdraw(uint256 strategyTokenAmountToWithdraw)
        external
        override
        onlyOwner
        returns (uint256 amountWithdrawn)
    {
        if (strategyTokenAmountToWithdraw > 0) {
            farm.withdraw(poolId, strategyTokenAmountToWithdraw);

            uint256 lpAmount = lpToken.balanceOf(address(this));
            lpToken.approve(address(stargateRouter), lpAmount);
            stargateRouter.instantRedeemLocal(
                poolId,
                lpToken.balanceOf(address(this)),
                address(this)
            );
        }

        uint256 amountA = tokenA.balanceOf(address(this));

        if (amountA > 0) {
            tokenA.transfer(msg.sender, amountA);
            return amountA;
        }
    }

    function compound() external override onlyOwner {
        // inside withdraw happens STG rewards collection
        farm.withdraw(poolId, 0);
        // use balance because STG is harvested on deposit and withdraw calls
        uint256 stgAmount = stg.balanceOf(address(this));

        if (stgAmount > 0) {
            fix_leftover(0);
            sellReward(stgAmount);
            uint256 balanceA = tokenA.balanceOf(address(this));
            uint256 balanceB = tokenB.balanceOf(address(this));

            tokenA.approve(address(stargateRouter), balanceA);
            tokenB.approve(address(stargateRouter), balanceB);

            stargateRouter.addLiquidity(
                address(tokenA),
                address(tokenB),
                balanceA,
                balanceB,
                0,
                0,
                address(this),
                block.timestamp
            );

            uint256 lpAmount = lpToken.balanceOf(address(this));
            lpToken.approve(address(farm), lpAmount);
            farm.deposit(poolId, lpAmount);
        }
    }

    function totalTokens() external view override returns (uint256) {
        (uint256 liquidity, ) = farm.userInfo(poolId, address(this));

        uint256 _totalSupply = lpToken.totalSupply();
        // this formula is from uniswap.remove_liquidity -> uniswapPair.burn function
        uint256 balanceA = tokenA.balanceOf(address(lpToken));
        uint256 amountA = (liquidity * balanceA) / _totalSupply;

        return amountA;
    }

    function withdrawAll() external override onlyOwner returns (uint256 amountWithdrawn) {
        (uint256 amount, ) = farm.userInfo(poolId, address(this));
        if (amount > 0) {
            farm.withdraw(poolId, amount);
            uint256 lpAmount = lpToken.balanceOf(address(this));
            lpToken.approve(address(stargateRouter), lpAmount);
            stargateRouter.instantRedeemLocal(
                poolId,
                lpToken.balanceOf(address(this)),
                address(this)
            );
        }

        uint256 amountA = tokenA.balanceOf(address(this));

        if (amountA > 0) {
            tokenA.transfer(msg.sender, amountA);
            return amountA;
        }
    }

    /// @dev Swaps leftover tokens for a better ratio for LP.
    function fix_leftover(uint256 amountIgnore) private {
        Exchange exchange = strategyRouter.getExchange();
        uint256 amountB = tokenB.balanceOf(address(this));
        uint256 amountA = tokenA.balanceOf(address(this)) - amountIgnore;
        uint256 toSwap;
        if (amountB > amountA && (toSwap = amountB - amountA) > LEFTOVER_THRESHOLD_TOKEN_B) {
            uint256 dexFee = exchange.getFee(toSwap / 2, address(tokenA), address(tokenB));
            toSwap = calculateSwapAmount(toSwap / 2, dexFee);
            tokenB.transfer(address(exchange), toSwap);
            exchange.swap(toSwap, address(tokenB), address(tokenA), address(this));
        } else if (amountA > amountB && (toSwap = amountA - amountB) > LEFTOVER_THRESHOLD_TOKEN_A) {
            uint256 dexFee = exchange.getFee(toSwap / 2, address(tokenA), address(tokenB));
            toSwap = calculateSwapAmount(toSwap / 2, dexFee);
            tokenA.transfer(address(exchange), toSwap);
            exchange.swap(toSwap, address(tokenA), address(tokenB), address(this));
        }
    }

    // swap stg for tokenA & tokenB in proportions 50/50
    function sellReward(uint256 stgAmount) private returns (uint256 receivedA, uint256 receivedB) {
        // sell for lp ratio
        uint256 amountA = stgAmount / 2;
        uint256 amountB = stgAmount - amountA;

        Exchange exchange = strategyRouter.getExchange();
        stg.transfer(address(exchange), amountA);
        receivedA = exchange.swap(amountA, address(stg), address(tokenA), address(this));

        stg.transfer(address(exchange), amountB);
        receivedB = exchange.swap(amountB, address(stg), address(tokenB), address(this));

        (receivedA, receivedB) = collectProtocolCommission(receivedA, receivedB);
    }

    function collectProtocolCommission(uint256 amountA, uint256 amountB)
        private
        returns (uint256 amountAfterFeeA, uint256 amountAfterFeeB)
    {
        uint256 feePercent = StrategyRouter(strategyRouter).feePercent();
        address feeAddress = StrategyRouter(strategyRouter).feeAddress();
        uint256 ratioUint;
        uint256 feeAmount = ((amountA + amountB) * feePercent) / PERCENT_DENOMINATOR;
        {
            (uint256 r0, uint256 r1, ) = IUniswapV2Pair(address(lpToken)).getReserves();

            // equation: (a - (c*v))/(b - (c-c*v)) = z/x
            // solution for v = (a*x - b*z + c*z) / (c * (z+x))
            // a,b is current tokenA amounts, z,x is pair reserves, c is total fee amount to take from a+b
            // v is ratio to apply to feeAmount and take fee from a and b
            // a and z should be converted to same decimals as tokenA b (TODO for cases when decimals are different)
            int256 numerator = int256(amountA * r1 + feeAmount * r0) - int256(amountB * r0);
            int256 denominator = int256(feeAmount * (r0 + r1));
            int256 ratio = (numerator * 1e18) / denominator;
            // ratio here could be negative or greater than 1.0
            // only need to be between 0 and 1
            if (ratio < 0) ratio = 0;
            if (ratio > 1e18) ratio = 1e18;

            ratioUint = uint256(ratio);
        }

        // these two have same decimals, should adjust A to have A decimals,
        // this is TODO for cases when tokenA and tokenB has different decimals
        uint256 comissionA = (feeAmount * ratioUint) / 1e18;
        uint256 comissionB = feeAmount - comissionA;

        tokenA.transfer(feeAddress, comissionA);
        tokenB.transfer(feeAddress, comissionB);

        return (amountA - comissionA, amountB - comissionB);
    }

    function calculateSwapAmount(uint256 half, uint256 dexFee) private view returns (uint256 amountAfterFee) {
        (uint256 r0, uint256 r1, ) = IUniswapV2Pair(address(lpToken)).getReserves();
        uint256 halfWithFee = (2 * r0 * (dexFee + 1e18)) / ((r0 * (dexFee + 1e18)) / 1e18 + r1);
        uint256 amountB = (half * halfWithFee) / 1e18;
        return amountB;
    }
}
