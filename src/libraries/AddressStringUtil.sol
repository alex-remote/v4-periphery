// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/// @title AddressStringUtil
/// @notice 提供将地址转换为字符串的工具函数
/// @dev 参考：https://github.com/Uniswap/solidity-lib/blob/master/contracts/libraries/AddressStringUtil.sol
library AddressStringUtil {
    error InvalidAddressLength(uint256 len);

    /// @notice 将地址转换为大写十六进制字符串，只提取 len 个字节（最多 20，且为 2 的倍数）
    /// @param addr 要转换的地址
    /// @param len 要提取的字节数
    /// @return 十六进制字符串
    function toAsciiString(address addr, uint256 len) internal pure returns (string memory) {
        if (!(len % 2 == 0 && len > 0 && len <= 40)) {
            revert InvalidAddressLength(len);
        }

        bytes memory s = new bytes(len);
        uint256 addrNum = uint256(uint160(addr));
        for (uint256 i = 0; i < len / 2; i++) {
            // 右移并截断最低有效字节之外的所有位，以提取位置 19-i 处的字节
            uint8 b = uint8(addrNum >> (8 * (19 - i)));
            // 第一个十六进制字符取最高的 4 位
            uint8 hi = b >> 4;
            // 第二个十六进制字符取最低的 4 位
            uint8 lo = b - (hi << 4);
            s[2 * i] = char(hi);
            s[2 * i + 1] = char(lo);
        }
        return string(s);
    }

    /// @notice 将一个值转换为其十六进制表示所对应的 ASCII 字符
    // hi 和 lo 只有 4 位，取值在 0 到 16 之间
    // 字符使用大写
    /// @param b 要转换的值
    /// @return c ASCII 字符
    function char(uint8 b) private pure returns (bytes1 c) {
        if (b < 10) {
            return bytes1(b + 0x30);
        } else {
            return bytes1(b + 0x37);
        }
    }
}
