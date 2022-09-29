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
    uint256 internal immutable farmPoolId;

    uint256 private constant PERCENT_DENOMINATOR = 10000;

    modifier onlyUpgrader() {
        if (msg.sender != address(upgrader)) revert CallerUpgrader();
        _;
    }

    /// @dev construct is intended to initialize immutables on implementation
    constructor(
        StrategyRouter _strategyRouter,
        uint256 _poolId,
        uint256 _farmPoolId,
        ERC20 _tokenA,
        ERC20 _lpToken
    ) {
        strategyRouter = _strategyRouter;
        poolId = _poolId;
        tokenA = _tokenA;
        lpToken = _lpToken;
        farmPoolId = _farmPoolId

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

        uint256 lpAmount = lpToken.balanceOf(address(this));
        lpToken.approve(address(farm), lpAmount);
        farm.deposit(farmPoolId, lpAmount);
    }

    function withdraw(uint256 strategyTokenAmountToWithdraw)
        external
        override
        onlyOwner
        returns (uint256 amountWithdrawn)
    {
        if (strategyTokenAmountToWithdraw > 0) {
            farm.withdraw(farmPoolId, strategyTokenAmountToWithdraw);

            uint256 lpAmount = lpToken.balanceOf(address(this));
            lpToken.approve(address(stargateRouter), lpAmount);
            stargateRouter.instantRedeemLocal(
                uint16(poolId),
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
        farm.withdraw(farmPoolId, 0);
        // use balance because STG is harvested on deposit and withdraw calls
        uint256 stgAmount = stg.balanceOf(address(this));

        if (stgAmount > 0) {
            sellReward(stgAmount);
            uint256 balanceA = tokenA.balanceOf(address(this));

            tokenA.approve(address(stargateRouter), balanceA);

            stargateRouter.addLiquidity(poolId, balanceA, address(this));

            uint256 lpAmount = lpToken.balanceOf(address(this));
            lpToken.approve(address(farm), lpAmount);
            farm.deposit(farmPoolId, lpAmount);
        }
    }

    function totalTokens() external view override returns (uint256) {
        (uint256 liquidity, ) = farm.userInfo(farmPoolId, address(this));

        uint256 _totalSupply = lpToken.totalSupply();
        // this formula is from uniswap.remove_liquidity -> uniswapPair.burn function
        uint256 balanceA = tokenA.balanceOf(address(lpToken));
        uint256 amountA = (liquidity * balanceA) / _totalSupply;

        return amountA;
    }

    function withdrawAll() external override onlyOwner returns (uint256 amountWithdrawn) {
        (uint256 amount, ) = farm.userInfo(farmPoolId, address(this));
        if (amount > 0) {
            farm.withdraw(farmPoolId, amount);
            uint256 lpAmount = lpToken.balanceOf(address(this));
            lpToken.approve(address(stargateRouter), lpAmount);
            stargateRouter.instantRedeemLocal(
                uint16(poolId),
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

    // swap stg for tokenA & tokenB in proportions 50/50
    function sellReward(uint256 stgAmount) private returns (uint256 receivedA) {
        // sell for lp ratio

        Exchange exchange = strategyRouter.getExchange();
        stg.transfer(address(exchange), stgAmount);
        receivedA = exchange.swap(stgAmount, address(stg), address(tokenA), address(this));

        receivedA = collectProtocolCommission(receivedA);
    }

    function collectProtocolCommission(uint256 amountA)
        private
        returns (uint256 amountAfterFeeA)
    {
        uint256 feePercent = StrategyRouter(strategyRouter).feePercent();
        address feeAddress = StrategyRouter(strategyRouter).feeAddress();
        uint256 feeAmount = (amountA * feePercent) / PERCENT_DENOMINATOR;

        tokenA.transfer(feeAddress, feeAmount);

        return (amountA);
    }

    function calculateSwapAmount(uint256 half, uint256 dexFee) private view returns (uint256 amountAfterFee) {
        (uint256 r0, uint256 r1, ) = IUniswapV2Pair(address(lpToken)).getReserves();
        uint256 halfWithFee = (2 * r0 * (dexFee + 1e18)) / ((r0 * (dexFee + 1e18)) / 1e18 + r1);
        uint256 amountB = (half * halfWithFee) / 1e18;
        return amountB;
    }
}
