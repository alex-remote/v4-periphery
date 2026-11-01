// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title HexStrings
/// @notice 提供将数字转换为十六进制字符串的函数
/// @dev 参考：https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/HexStrings.sol
library HexStrings {
    bytes16 internal constant ALPHABET = "0123456789abcdef";

    /// @notice 将数字转换为不带 '0x' 前缀的定长十六进制字符串
    /// @param value 要转换的数字
    /// @param length 输出字符串的长度，从字符串的最后一个字符开始计算
    /// @return 十六进制字符串
    function toHexStringNoPrefix(uint256 value, uint256 length) internal pure returns (string memory) {
        bytes memory buffer = new bytes(2 * length);
        for (uint256 i = buffer.length; i > 0; i--) {
            buffer[i - 1] = ALPHABET[value & 0xf];
            value >>= 4;
        }
        return string(buffer);
    }
}
