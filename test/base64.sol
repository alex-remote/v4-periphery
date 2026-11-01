// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Base64
/// @author Brecht Devos - <brecht@loopring.org>
/// @notice 提供 base64 解码函数
library Base64 {
    bytes internal constant TABLE_DECODE = hex"0000000000000000000000000000000000000000000000000000000000000000"
        hex"00000000000000000000003e0000003f3435363738393a3b3c3d000000000000"
        hex"00000102030405060708090a0b0c0d0e0f101112131415161718190000000000"
        hex"001a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132330000000000";

    function decode(string memory _data) internal pure returns (bytes memory) {
        bytes memory data = bytes(_data);

        if (data.length == 0) return new bytes(0);
        require(data.length % 4 == 0, "invalid base64 decoder input");

        // 将查找表加载到内存
        bytes memory table = TABLE_DECODE;

        // 每 4 个字符表示 3 个字节
        uint256 decodedLen = (data.length / 4) * 3;

        // 在末尾添加写入所需的额外缓冲区
        bytes memory result = new bytes(decodedLen + 32);

        assembly {
            // 处理 '=' 填充
            let lastBytes := mload(add(data, mload(data)))
            if eq(and(lastBytes, 0xFF), 0x3d) {
                decodedLen := sub(decodedLen, 1)
                if eq(and(lastBytes, 0xFFFF), 0x3d3d) { decodedLen := sub(decodedLen, 1) }
            }

            // 设置实际输出长度
            mstore(result, decodedLen)

            // 准备查找表
            let tablePtr := add(table, 1)

            // 输入指针
            let dataPtr := data
            let endPtr := add(dataPtr, mload(data))

            // 结果指针，跳过长度字段
            let resultPtr := add(result, 32)

            // 遍历输入，每次处理 4 个字符
            for {} lt(dataPtr, endPtr) {} {
                // 读取 4 个字符
                dataPtr := add(dataPtr, 4)
                let input := mload(dataPtr)

                // 写入 3 个字节
                let output :=
                    add(
                        add(
                            shl(18, and(mload(add(tablePtr, and(shr(24, input), 0xFF))), 0xFF)),
                            shl(12, and(mload(add(tablePtr, and(shr(16, input), 0xFF))), 0xFF))
                        ),
                        add(
                            shl(6, and(mload(add(tablePtr, and(shr(8, input), 0xFF))), 0xFF)),
                            and(mload(add(tablePtr, and(input, 0xFF))), 0xFF)
                        )
                    )
                mstore(resultPtr, shl(232, output))
                resultPtr := add(resultPtr, 3)
            }
        }

        return result;
    }
}
