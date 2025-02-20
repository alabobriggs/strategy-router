//SPDX-License-Identifier: Unlicense
pragma solidity ^0.8.0;
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "../../StrategyRouter.sol";
import "./StargateBase.sol";

/// @custom:oz-upgrades-unsafe-allow constructor state-variable-immutable
contract StargateUsdt is StargateBase {
    constructor(StrategyRouter _strategyRouter)
        StargateBase(
            _strategyRouter,
            2, // poolId
            0, // farmPoolId
            ERC20(0x55d398326f99059fF775485246999027B3197955), // tokenA - USDT 
            ERC20(0x9aA83081AA06AF7208Dcc7A4cB72C94d057D2cda) // lpToken USDT
        )
    {}
}
