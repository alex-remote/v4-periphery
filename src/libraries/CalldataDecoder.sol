// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IV4Router} from "../interfaces/IV4Router.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @title 在 calldata 中进行 abi 解码的库
library CalldataDecoder {
    using CalldataDecoder for bytes;

    error SliceOutOfBounds();

    /// @notice 用于偏移量和长度的掩码，以确保不会溢出
    /// @dev 任何正常的 abi 编码都不会传入大于 type(uint32).max 的偏移量或长度
    ///      （注意：这确实偏离了标准 solidity 的行为，偏移量/长度将
    ///      被解释为对 type(uint32).max 取模，这只会影响恶意或有缺陷的调用者）
    uint256 constant OFFSET_OR_LENGTH_MASK = 0xffffffff;
    uint256 constant OFFSET_OR_LENGTH_MASK_AND_WORD_ALIGN = 0xffffffe0;

    /// @notice 等同于 SliceOutOfBounds.selector，存放在最低有效位中
    uint256 constant SLICE_ERROR_SELECTOR = 0x3b99b53d;

    /// @dev 等价于在 calldata 中执行：abi.decode(params, (bytes, bytes[]))（要求严格的 abi 编码）
    function decodeActionsRouterParams(bytes calldata _bytes)
        internal
        pure
        returns (bytes calldata actions, bytes[] calldata params)
    {
        assembly ("memory-safe") {
            // 严格编码要求数据以如下内容开头：
            // 0x00: 0x40（指向 `actions.length` 的偏移量）
            // 0x20: 0x60 + actions.length（指向 `params.length` 的偏移量）
            // 0x40: `actions.length`
            // 0x60: actions 的起始位置

            // 校验 actions 偏移量符合严格编码
            let invalidData := xor(calldataload(_bytes.offset), 0x40)
            actions.offset := add(_bytes.offset, 0x60)
            actions.length := and(calldataload(add(_bytes.offset, 0x40)), OFFSET_OR_LENGTH_MASK)

            // 将 actions 长度向上取整到字对齐，再加上 0x60（对应编码的前 3 个字）
            let paramsLengthOffset := add(and(add(actions.length, 0x1f), OFFSET_OR_LENGTH_MASK_AND_WORD_ALIGN), 0x60)
            // 校验 params 偏移量符合严格编码
            invalidData := or(invalidData, xor(calldataload(add(_bytes.offset, 0x20)), paramsLengthOffset))
            let paramsLengthPointer := add(_bytes.offset, paramsLengthOffset)
            params.length := and(calldataload(paramsLengthPointer), OFFSET_OR_LENGTH_MASK)
            params.offset := add(paramsLengthPointer, 0x20)

            // `params[0]` 的预期偏移量为 params.length * 32
            // 因为前 `params.length` 个槽位是分别指向各数组元素长度的指针
            let tailOffset := shl(5, params.length)
            let expectedOffset := tailOffset

            for { let offset := 0 } lt(offset, tailOffset) { offset := add(offset, 32) } {
                let itemLengthOffset := calldataload(add(params.offset, offset))
                // 校验该偏移量与严格编码下的预期偏移量一致
                invalidData := or(invalidData, xor(itemLengthOffset, expectedOffset))
                let itemLengthPointer := add(params.offset, itemLengthOffset)
                let length :=
                    add(and(add(calldataload(itemLengthPointer), 0x1f), OFFSET_OR_LENGTH_MASK_AND_WORD_ALIGN), 0x20)
                expectedOffset := add(expectedOffset, length)
            }

            // 如果数据编码无效，或提供的字节串长度不及编码所声明的长度，则回滚（revert）
            if or(invalidData, lt(add(_bytes.length, _bytes.offset), add(params.offset, expectedOffset))) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
        }
    }

    /// @dev 等价于在 calldata 中执行：abi.decode(params, (uint256, uint256, uint128, uint128, bytes))
    function decodeModifyLiquidityParams(bytes calldata params)
        internal
        pure
        returns (uint256 tokenId, uint256 liquidity, uint128 amount0, uint128 amount1, bytes calldata hookData)
    {
        // 此处不做长度检查，因为 `toBytes` 中已有长度检查
        assembly ("memory-safe") {
            tokenId := calldataload(params.offset)
            liquidity := calldataload(add(params.offset, 0x20))
            amount0 := calldataload(add(params.offset, 0x40))
            amount1 := calldataload(add(params.offset, 0x60))
        }

        hookData = params.toBytes(4);
    }

    /// @dev 等价于在 calldata 中执行：abi.decode(params, (uint256, uint128, uint128, bytes))
    function decodeIncreaseLiquidityFromDeltasParams(bytes calldata params)
        internal
        pure
        returns (uint256 tokenId, uint128 amount0Max, uint128 amount1Max, bytes calldata hookData)
    {
        // 此处不做长度检查，因为 `toBytes` 中已有长度检查
        assembly ("memory-safe") {
            tokenId := calldataload(params.offset)
            amount0Max := calldataload(add(params.offset, 0x20))
            amount1Max := calldataload(add(params.offset, 0x40))
        }

        hookData = params.toBytes(3);
    }

    /// @dev 等价于在 calldata 中执行：abi.decode(params, (PoolKey, int24, int24, uint256, uint128, uint128, address, bytes))
    function decodeMintParams(bytes calldata params)
        internal
        pure
        returns (
            PoolKey calldata poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint256 liquidity,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            bytes calldata hookData
        )
    {
        // 此处不做长度检查，因为 `toBytes` 中已有长度检查
        assembly ("memory-safe") {
            poolKey := params.offset
            tickLower := calldataload(add(params.offset, 0xa0))
            tickUpper := calldataload(add(params.offset, 0xc0))
            liquidity := calldataload(add(params.offset, 0xe0))
            amount0Max := calldataload(add(params.offset, 0x100))
            amount1Max := calldataload(add(params.offset, 0x120))
            owner := calldataload(add(params.offset, 0x140))
        }
        hookData = params.toBytes(11);
    }

    /// @dev 等价于在 calldata 中执行：abi.decode(params, (PoolKey, int24, int24, uint128, uint128, address, bytes))
    function decodeMintFromDeltasParams(bytes calldata params)
        internal
        pure
        returns (
            PoolKey calldata poolKey,
            int24 tickLower,
            int24 tickUpper,
            uint128 amount0Max,
            uint128 amount1Max,
            address owner,
            bytes calldata hookData
        )
    {
        // 此处不做长度检查，因为 `toBytes` 中已有长度检查
        assembly ("memory-safe") {
            poolKey := params.offset
            tickLower := calldataload(add(params.offset, 0xa0))
            tickUpper := calldataload(add(params.offset, 0xc0))
            amount0Max := calldataload(add(params.offset, 0xe0))
            amount1Max := calldataload(add(params.offset, 0x100))
            owner := calldataload(add(params.offset, 0x120))
        }

        hookData = params.toBytes(10);
    }

    /// @dev 等价于在 calldata 中执行：abi.decode(params, (uint256, uint128, uint128, bytes))
    function decodeBurnParams(bytes calldata params)
        internal
        pure
        returns (uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData)
    {
        // 此处不做长度检查，因为 `toBytes` 中已有长度检查
        assembly ("memory-safe") {
            tokenId := calldataload(params.offset)
            amount0Min := calldataload(add(params.offset, 0x20))
            amount1Min := calldataload(add(params.offset, 0x40))
        }

        hookData = params.toBytes(3);
    }

    /// @dev 等价于：abi.decode(params, (IV4Router.ExactInputParams))
    function decodeSwapExactInParams(bytes calldata params)
        internal
        pure
        returns (IV4Router.ExactInputParams calldata swapParams)
    {
        // ExactInputParams 是变长结构体，因此只需查找它的位置
        assembly ("memory-safe") {
            // 仅对最小长度做安全检查，即 path 和 minHopPriceX36 均为空的情况
            // 0xe0 = 7 * 0x20 -> 3 个元素、path 偏移量、minHopPriceX36 偏移量、path 长度 0 以及 minHopPriceX36 长度 0
            if lt(params.length, 0xe0) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            swapParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// @dev 等价于：abi.decode(params, (IV4Router.ExactInputSingleParams))
    function decodeSwapExactInSingleParams(bytes calldata params)
        internal
        pure
        returns (IV4Router.ExactInputSingleParams calldata swapParams)
    {
        // ExactInputSingleParams 是变长结构体，因此只需查找它的位置
        assembly ("memory-safe") {
            // 仅对最小长度做安全检查，即 hookData 为空的情况
            // 0x160 = 11 * 0x20 -> 9 个元素、bytes 偏移量以及 bytes 长度 0
            if lt(params.length, 0x160) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            swapParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// @dev 等价于：abi.decode(params, (IV4Router.ExactOutputParams))
    function decodeSwapExactOutParams(bytes calldata params)
        internal
        pure
        returns (IV4Router.ExactOutputParams calldata swapParams)
    {
        // ExactOutputParams 是变长结构体，因此只需查找它的位置
        assembly ("memory-safe") {
            // 仅对最小长度做安全检查，即 path 和 minHopPriceX36 均为空的情况
            // 0xe0 = 7 * 0x20 -> 3 个元素、path 偏移量、minHopPriceX36 偏移量、path 长度 0 以及 minHopPriceX36 长度 0
            if lt(params.length, 0xe0) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            swapParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// @dev 等价于：abi.decode(params, (IV4Router.ExactOutputSingleParams))
    function decodeSwapExactOutSingleParams(bytes calldata params)
        internal
        pure
        returns (IV4Router.ExactOutputSingleParams calldata swapParams)
    {
        // ExactOutputSingleParams 是变长结构体，因此只需查找它的位置
        assembly ("memory-safe") {
            // 仅对最小长度做安全检查，即 hookData 为空的情况
            // 0x160 = 11 * 0x20 -> 9 个元素、bytes 偏移量以及 bytes 长度 0
            if lt(params.length, 0x160) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            swapParams := add(params.offset, calldataload(params.offset))
        }
    }

    /// @dev 等价于在 calldata 中执行：abi.decode(params, (Currency))
    function decodeCurrency(bytes calldata params) internal pure returns (Currency currency) {
        assembly ("memory-safe") {
            if lt(params.length, 0x20) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
        }
    }

    /// @dev 等价于在 calldata 中执行：abi.decode(params, (Currency, Currency))
    function decodeCurrencyPair(bytes calldata params) internal pure returns (Currency currency0, Currency currency1) {
        assembly ("memory-safe") {
            if lt(params.length, 0x40) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency0 := calldataload(params.offset)
            currency1 := calldataload(add(params.offset, 0x20))
        }
    }

    /// @dev 等价于在 calldata 中执行：abi.decode(params, (Currency, Currency, address))
    function decodeCurrencyPairAndAddress(bytes calldata params)
        internal
        pure
        returns (Currency currency0, Currency currency1, address _address)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x60) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency0 := calldataload(params.offset)
            currency1 := calldataload(add(params.offset, 0x20))
            _address := calldataload(add(params.offset, 0x40))
        }
    }

    /// @dev 等价于在 calldata 中执行：abi.decode(params, (Currency, address))
    function decodeCurrencyAndAddress(bytes calldata params)
        internal
        pure
        returns (Currency currency, address _address)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x40) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
            _address := calldataload(add(params.offset, 0x20))
        }
    }

    /// @dev 等价于在 calldata 中执行：abi.decode(params, (Currency, address, uint256))
    function decodeCurrencyAddressAndUint256(bytes calldata params)
        internal
        pure
        returns (Currency currency, address _address, uint256 amount)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x60) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
            _address := calldataload(add(params.offset, 0x20))
            amount := calldataload(add(params.offset, 0x40))
        }
    }

    /// @dev 等价于在 calldata 中执行：abi.decode(params, (Currency, uint256))
    function decodeCurrencyAndUint256(bytes calldata params) internal pure returns (Currency currency, uint256 amount) {
        assembly ("memory-safe") {
            if lt(params.length, 0x40) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
            amount := calldataload(add(params.offset, 0x20))
        }
    }

    /// @dev 等价于在 calldata 中执行：abi.decode(params, (uint256))
    function decodeUint256(bytes calldata params) internal pure returns (uint256 amount) {
        assembly ("memory-safe") {
            if lt(params.length, 0x20) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            amount := calldataload(params.offset)
        }
    }

    /// @dev 等价于在 calldata 中执行：abi.decode(params, (Currency, uint256, bool))
    function decodeCurrencyUint256AndBool(bytes calldata params)
        internal
        pure
        returns (Currency currency, uint256 amount, bool boolean)
    {
        assembly ("memory-safe") {
            if lt(params.length, 0x60) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
            currency := calldataload(params.offset)
            amount := calldataload(add(params.offset, 0x20))
            boolean := calldataload(add(params.offset, 0x40))
        }
    }

    /// @notice 将 `_bytes` 中第 `_arg` 个元素解码为 `bytes`
    /// @param _bytes 要从中提取字节串的输入字节串
    /// @param _arg 要提取的参数的索引
    function toBytes(bytes calldata _bytes, uint256 _arg) internal pure returns (bytes calldata res) {
        uint256 length;
        assembly ("memory-safe") {
            // 第 `_arg` 个元素的偏移量为 `32 * arg`，该位置存放的是长度指针的偏移量。
            // shl(5, x) 等价于 mul(32, x)
            let lengthPtr :=
                add(_bytes.offset, and(calldataload(add(_bytes.offset, shl(5, _arg))), OFFSET_OR_LENGTH_MASK))
            // 字节串中的字节数
            length := and(calldataload(lengthPtr), OFFSET_OR_LENGTH_MASK)
            // 字节串开始处的偏移量
            let offset := add(lengthPtr, 0x20)
            // 为返回参数赋值
            res.length := length
            res.offset := offset

            // 如果提供的字节串长度不及编码所声明的长度，则回滚（revert）
            if lt(add(_bytes.length, _bytes.offset), add(length, offset)) {
                mstore(0, SLICE_ERROR_SELECTOR)
                revert(0x1c, 4)
            }
        }
    }
}
