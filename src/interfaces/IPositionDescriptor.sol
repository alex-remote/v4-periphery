// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./IPositionManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";

/// @title IPositionDescriptor
/// @notice PositionDescriptor 合约的接口
interface IPositionDescriptor {
    error InvalidTokenId(uint256 tokenId);

    /// @notice 生成描述指定 token ID 的 URI
    /// @dev 注意：该 URI 可能是直接内联了 JSON 内容的 data: URI
    /// @param positionManager 待描述代币所属的 PositionManager
    /// @param tokenId 要生成描述的代币 ID，该 ID 可能无效
    /// @return 符合 ERC721 标准的元数据 URI
    function tokenURI(IPositionManager positionManager, uint256 tokenId) external view returns (string memory);

    /// @notice 若 currency0 的优先级高于 currency1，则返回 true
    /// @param currency0 第一个代币地址
    /// @param currency1 第二个代币地址
    /// @return 若 currency0 的优先级高于 currency1，则为 true
    function flipRatio(address currency0, address currency1) external view returns (bool);

    /// @notice 返回某个代币的优先级。
    /// 对于主网上的某些代币，币值越小，优先级越高
    /// 而优先级值越高（正值越大）的代币，将位于价格比率的分子位置
    /// @param currency 代币地址
    /// @return 该代币的优先级
    function currencyRatioPriority(address currency) external view returns (int256);

    /// @return 该描述器对应的包装原生代币（wrapped native token）
    function wrappedNative() external view returns (address);

    /// @return 该描述器对应的原生代币标签
    function nativeCurrencyLabel() external view returns (string memory);

    /// @return 该描述器对应的 PoolManager
    function poolManager() external view returns (IPoolManager);
}
