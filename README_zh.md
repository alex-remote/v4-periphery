# Uniswap v4 Periphery

Uniswap v4 是一个新的自动做市商（AMM）协议，为池提供可扩展性和可定制性。`v4-periphery` 承载构建在核心池逻辑之上的逻辑，例如 hook 合约、头寸管理器，甚至可能包括集成所需的库。本仓库中的 `v4-periphery` 合约仍在开发中，更多外围合约尚未构建。

## 参与贡献

如果你有兴趣参与贡献，请参阅[贡献指南](https://github.com/Uniswap/v4-periphery/blob/main/CONTRIBUTING.md)！

## 本地部署与使用

要使用这些合约并部署到本地测试网，你可以用 forge 将代码安装到你的仓库中：

```solidity
forge install https://github.com/Uniswap/v4-periphery
```

如果你正在构建 hook，继承 [v4-hooks-public](https://github.com/Uniswap/v4-hooks-public) 中的 [`BaseHook`](https://github.com/Uniswap/v4-hooks-public/blob/main/src/base/BaseHook.sol) 合约可能会很有用：

```solidity
contract CoolHook is BaseHook {
    // 重写你的 hook 中需要的 hook 回调函数
    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata hookData
    ) internal override returns (bytes4) {
        // hook 逻辑
        return BaseHook.beforeAddLiquidity.selector;
    }
}

```

## 许可证

Uniswap V4 Periphery 采用 GNU 通用公共许可证（GPL 2.0），参见 [LICENSE](https://github.com/Uniswap/v4-periphery/blob/main/LICENSE)。
