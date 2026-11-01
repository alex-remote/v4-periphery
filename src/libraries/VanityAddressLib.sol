// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title VanityAddressLib
/// @notice 根据地址的“靓号”程度（vanity）为地址打分的库
library VanityAddressLib {
    /// @notice 比较两个地址，若第一个地址的靓号得分更高则返回 true
    /// @param first 要比较的第一个地址
    /// @param second 要比较的第二个地址
    /// @return better 若第一个地址的靓号得分更高则为 true
    function betterThan(address first, address second) internal pure returns (bool better) {
        return score(first) > score(second);
    }

    /// @notice 根据地址的靓号程度为其打分
    /// @dev 计分规则：
    ///    要求：第一个非零 nibble（半字节）必须是 4
    ///    每个前导 0 nibble 计 10 分
    ///    若第一个 4 后面还紧跟 3 个 4，计 40 分
    ///    若这 4 个 4 之后的第一个 nibble 不是 4，计 20 分
    ///    若最后 4 个 nibble 都是 4，计 20 分
    ///    每出现一个 4 计 1 分
    /// @param addr 要打分的地址
    /// @return calculatedScore 该地址的靓号得分
    function score(address addr) internal pure returns (uint256 calculatedScore) {
        // 将地址转换为字节，便于解析
        bytes20 addrBytes = bytes20(addr);

        unchecked {
            // 每个前导零 nibble 计 10 分
            uint256 leadingZeroCount = getLeadingNibbleCount(addrBytes, 0, 0);
            calculatedScore += (leadingZeroCount * 10);

            // 对紧跟在前导 0 之后的 4 进行特殊处理
            uint256 leadingFourCount = getLeadingNibbleCount(addrBytes, leadingZeroCount, 4);
            // 若第一个非零 nibble 不是 4，返回 0
            if (leadingFourCount == 0) {
                return 0;
            } else if (leadingFourCount == 4) {
                // 恰好 4 个 4 时计 60 分
                calculatedScore += 60;
            } else if (leadingFourCount > 4) {
                // 超过 4 个 4 时计 40 分
                calculatedScore += 40;
            }

            // 处理剩余的 nibble
            for (uint256 i = 0; i < addrBytes.length * 2; i++) {
                uint8 currentNibble = getNibble(addrBytes, i);

                // 每个值为 4 的 nibble 额外计 1 分
                if (currentNibble == 4) {
                    calculatedScore += 1;
                }
            }

            // 若最后 4 个 nibble 都是 4，加 20 分
            if (addrBytes[18] == 0x44 && addrBytes[19] == 0x44) {
                calculatedScore += 20;
            }
        }
    }

    /// @notice 返回地址中与给定值相等的前导 nibble 的数量
    /// @param addrBytes 要统计前导零 nibble 的地址
    function getLeadingNibbleCount(bytes20 addrBytes, uint256 startIndex, uint8 comparison)
        internal
        pure
        returns (uint256 count)
    {
        if (startIndex >= addrBytes.length * 2) {
            return count;
        }

        for (uint256 i = startIndex; i < addrBytes.length * 2; i++) {
            uint8 currentNibble = getNibble(addrBytes, i);
            if (currentNibble != comparison) {
                return count;
            }
            count += 1;
        }
    }

    /// @notice 返回地址中指定索引处的 nibble
    /// @param input 要从中获取 nibble 的地址
    /// @param nibbleIndex 要获取的 nibble 的索引
    function getNibble(bytes20 input, uint256 nibbleIndex) internal pure returns (uint8 currentNibble) {
        uint8 currByte = uint8(input[nibbleIndex / 2]);
        if (nibbleIndex % 2 == 0) {
            // 获取该字节的高位 nibble
            currentNibble = currByte >> 4;
        } else {
            // 获取该字节的低位 nibble
            currentNibble = currByte & 0x0F;
        }
    }
}
