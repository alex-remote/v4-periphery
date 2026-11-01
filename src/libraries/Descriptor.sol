// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";
import {Base64} from "openzeppelin-contracts/contracts/utils/Base64.sol";
import {SVG} from "./SVG.sol";
import {HexStrings} from "./HexStrings.sol";

/// @title Descriptor
/// @notice 描述 NFT 代币头寸
/// @dev 参考：https://github.com/Uniswap/v3-periphery/blob/main/contracts/libraries/NFTDescriptor.sol
library Descriptor {
    using TickMath for int24;
    using Strings for uint256;
    using HexStrings for uint256;
    using LPFeeLibrary for uint24;

    uint256 constant sqrt10X128 = 1076067327063303206878105757264492625226;

    struct ConstructTokenURIParams {
        uint256 tokenId;
        address quoteCurrency;
        address baseCurrency;
        string quoteCurrencySymbol;
        string baseCurrencySymbol;
        uint8 quoteCurrencyDecimals;
        uint8 baseCurrencyDecimals;
        bool flipRatio;
        int24 tickLower;
        int24 tickUpper;
        int24 tickCurrent;
        int24 tickSpacing;
        uint24 fee;
        address poolManager;
        address hooks;
    }

    /// @notice 为 Uniswap v4 NFT 构造 token URI
    /// @param params 构造 token URI 所需的参数
    /// @return 字符串形式的 token URI
    function constructTokenURI(ConstructTokenURIParams memory params) internal pure returns (string memory) {
        string memory name = generateName(params, feeToPercentString(params.fee));
        string memory descriptionPartOne = generateDescriptionPartOne(
            escapeSpecialCharacters(params.quoteCurrencySymbol),
            escapeSpecialCharacters(params.baseCurrencySymbol),
            addressToString(params.poolManager)
        );
        string memory descriptionPartTwo = generateDescriptionPartTwo(
            params.tokenId.toString(),
            escapeSpecialCharacters(params.baseCurrencySymbol),
            params.quoteCurrency == address(0) ? "Native" : addressToString(params.quoteCurrency),
            params.baseCurrency == address(0) ? "Native" : addressToString(params.baseCurrency),
            params.hooks == address(0) ? "No Hook" : addressToString(params.hooks),
            feeToPercentString(params.fee)
        );
        string memory image = Base64.encode(bytes(generateSVGImage(params)));

        return string(
            abi.encodePacked(
                "data:application/json;base64,",
                Base64.encode(
                    bytes(
                        abi.encodePacked(
                            '{"name":"',
                            name,
                            '", "description":"',
                            descriptionPartOne,
                            descriptionPartTwo,
                            '", "image": "',
                            "data:image/svg+xml;base64,",
                            image,
                            '"}'
                        )
                    )
                )
            )
        );
    }

    /// @notice 若字符串中存在特殊字符，则对其进行转义
    function escapeSpecialCharacters(string memory symbol) internal pure returns (string memory) {
        bytes memory symbolBytes = bytes(symbol);
        uint8 specialCharCount = 0;
        // 统计 symbol 中双引号、换页符、换行符、回车符或制表符的数量
        for (uint8 i = 0; i < symbolBytes.length; i++) {
            if (isSpecialCharacter(symbolBytes[i])) {
                specialCharCount++;
            }
        }
        if (specialCharCount > 0) {
            // 创建一个新的 bytes 数组，空间足以容纳原始字节，以及用于转义特殊字符的反斜杠
            bytes memory escapedBytes = new bytes(symbolBytes.length + specialCharCount);
            uint256 index;
            for (uint8 i = 0; i < symbolBytes.length; i++) {
                // 在任何双引号、换页符、换行符、回车符或制表符之前添加一个 '\'
                if (isSpecialCharacter(symbolBytes[i])) {
                    escapedBytes[index++] = "\\";
                }
                // 将原字符串的每个字节复制到新数组中
                escapedBytes[index++] = symbolBytes[i];
            }
            return string(escapedBytes);
        }
        return symbol;
    }

    /// @notice 生成 Uniswap v4 NFT 描述的第一部分
    /// @param quoteCurrencySymbol 报价代币（quote currency）的符号
    /// @param baseCurrencySymbol 基础代币（base currency）的符号
    /// @param poolManager PoolManager 的地址
    /// @return 描述的第一部分
    function generateDescriptionPartOne(
        string memory quoteCurrencySymbol,
        string memory baseCurrencySymbol,
        string memory poolManager
    ) private pure returns (string memory) {
        // 先显示报价代币，再显示基础代币
        return string(
            abi.encodePacked(
                "This NFT represents a liquidity position in a Uniswap v4 ",
                quoteCurrencySymbol,
                "-",
                baseCurrencySymbol,
                " pool. ",
                "The owner of this NFT can modify or redeem the position.\\n",
                "\\nPool Manager Address: ",
                poolManager,
                "\\n",
                quoteCurrencySymbol
            )
        );
    }

    /// @notice 生成 Uniswap v4 NFT 描述的第二部分
    /// @param tokenId 代币 ID
    /// @param baseCurrencySymbol 基础代币的符号
    /// @param quoteCurrency 报价代币的地址
    /// @param baseCurrency 基础代币的地址
    /// @param hooks hooks 合约的地址
    /// @param feeTier 池的手续费档位
    /// @return 描述的第二部分
    function generateDescriptionPartTwo(
        string memory tokenId,
        string memory baseCurrencySymbol,
        string memory quoteCurrency,
        string memory baseCurrency,
        string memory hooks,
        string memory feeTier
    ) private pure returns (string memory) {
        return string(
            abi.encodePacked(
                " Address: ",
                quoteCurrency,
                "\\n",
                baseCurrencySymbol,
                " Address: ",
                baseCurrency,
                "\\nHook Address: ",
                hooks,
                "\\nFee Tier: ",
                feeTier,
                "\\nToken ID: ",
                tokenId,
                "\\n\\n",
                unicode"⚠️ DISCLAIMER: Due diligence is imperative when assessing this NFT. Make sure currency addresses match the expected currencies, as currency symbols may be imitated."
            )
        );
    }

    /// @notice 生成 Uniswap v4 NFT 的名称
    /// @param params 生成名称所需的参数
    /// @param feeTier 池的手续费档位
    /// @return NFT 的名称
    function generateName(ConstructTokenURIParams memory params, string memory feeTier)
        private
        pure
        returns (string memory)
    {
        // 图像以价格的形式显示，即 quoteCurrency/baseCurrency
        return string(
            abi.encodePacked(
                "Uniswap - ",
                feeTier,
                " - ",
                escapeSpecialCharacters(params.quoteCurrencySymbol),
                "/",
                escapeSpecialCharacters(params.baseCurrencySymbol),
                " - ",
                tickToDecimalString(
                    !params.flipRatio ? params.tickLower : params.tickUpper,
                    params.tickSpacing,
                    params.baseCurrencyDecimals,
                    params.quoteCurrencyDecimals,
                    params.flipRatio
                ),
                "<>",
                tickToDecimalString(
                    !params.flipRatio ? params.tickUpper : params.tickLower,
                    params.tickSpacing,
                    params.baseCurrencyDecimals,
                    params.quoteCurrencyDecimals,
                    params.flipRatio
                )
            )
        );
    }

    struct DecimalStringParams {
        // 小数的有效数字
        uint256 sigfigs;
        // 小数字符串的长度
        uint8 bufferLength;
        // 有效数字的结束索引（函数在复制有效数字时是从后往前处理的）
        uint8 sigfigIndex;
        // 小数点的索引（没有小数点时为 0）
        uint8 decimalIndex;
        // 极小/极大数字的末尾/前导 0 的起始索引
        uint8 zerosStartIndex;
        // 极小/极大数字的末尾/前导 0 的结束索引
        uint8 zerosEndIndex;
        // 若该小数小于 1 则为 true
        bool isLessThanOne;
        // 若字符串应包含 "%" 则为 true
        bool isPercent;
    }

    function generateDecimalString(DecimalStringParams memory params) private pure returns (string memory) {
        bytes memory buffer = new bytes(params.bufferLength);
        if (params.isPercent) {
            buffer[buffer.length - 1] = "%";
        }
        if (params.isLessThanOne) {
            buffer[0] = "0";
            buffer[1] = ".";
        }

        // 添加前导/末尾的 0
        for (uint256 zerosCursor = params.zerosStartIndex; zerosCursor < params.zerosEndIndex + 1; zerosCursor++) {
            // 将 0 的 ASCII 码（即 48）转换为 bytes1，以存入 buffer
            buffer[zerosCursor] = bytes1(uint8(48));
        }
        // 添加有效数字
        while (params.sigfigs > 0) {
            if (params.decimalIndex > 0 && params.sigfigIndex == params.decimalIndex) {
                buffer[params.sigfigIndex--] = ".";
            }
            buffer[params.sigfigIndex] = bytes1(uint8(48 + (params.sigfigs % 10)));
            // 当 sigfigIndex = 0 时可能溢出
            unchecked {
                params.sigfigIndex--;
            }
            params.sigfigs /= 10;
        }
        return string(buffer);
    }

    /// @notice 以小数形式获取特定 tick 处的价格（quote/base）
    /// 若 tick 位于价格曲线的底部或顶部，则返回 MIN 或 MAX
    /// @param tick 该 tick（tickLower 或 tickUpper）
    /// @param tickSpacing 池的 tick 间距
    /// @param baseCurrencyDecimals 基础代币的小数位数
    /// @param quoteCurrencyDecimals 报价代币的小数位数
    /// @param flipRatio 若比率已被翻转则为 true
    /// @return 字符串形式的比率值
    function tickToDecimalString(
        int24 tick,
        int24 tickSpacing,
        uint8 baseCurrencyDecimals,
        uint8 quoteCurrencyDecimals,
        bool flipRatio
    ) internal pure returns (string memory) {
        if (tick == (TickMath.MIN_TICK / tickSpacing) * tickSpacing) {
            return !flipRatio ? "MIN" : "MAX";
        } else if (tick == (TickMath.MAX_TICK / tickSpacing) * tickSpacing) {
            return !flipRatio ? "MAX" : "MIN";
        } else {
            uint160 sqrtRatioX96 = TickMath.getSqrtPriceAtTick(tick);
            if (flipRatio) {
                sqrtRatioX96 = uint160(uint256(1 << 192) / sqrtRatioX96);
            }
            return fixedPointToDecimalString(sqrtRatioX96, baseCurrencyDecimals, quoteCurrencyDecimals);
        }
    }

    function sigfigsRounded(uint256 value, uint8 digits) private pure returns (uint256, bool) {
        bool extraDigit;
        if (digits > 5) {
            value = value / (10 ** (digits - 5));
        }
        bool roundUp = value % 10 > 4;
        value = value / 10;
        if (roundUp) {
            value = value + 1;
        }
        // 99999 -> 100000 会多出一位有效数字
        if (value == 100000) {
            value /= 10;
            extraDigit = true;
        }
        return (value, extraDigit);
    }

    /// @notice 针对小数位数不同的代币调整 sqrt 价格
    /// @param sqrtRatioX96 特定 tick 处的 sqrt 价格
    /// @param baseCurrencyDecimals 基础代币的小数位数
    /// @param quoteCurrencyDecimals 报价代币的小数位数
    /// @return adjustedSqrtRatioX96 调整后的 sqrt 价格
    function adjustForDecimalPrecision(uint160 sqrtRatioX96, uint8 baseCurrencyDecimals, uint8 quoteCurrencyDecimals)
        private
        pure
        returns (uint256 adjustedSqrtRatioX96)
    {
        uint256 difference = abs(int256(uint256(baseCurrencyDecimals)) - (int256(uint256(quoteCurrencyDecimals))));
        if (difference > 0 && difference <= 18) {
            if (baseCurrencyDecimals > quoteCurrencyDecimals) {
                adjustedSqrtRatioX96 = sqrtRatioX96 * (10 ** (difference / 2));
                if (difference % 2 == 1) {
                    adjustedSqrtRatioX96 = FullMath.mulDiv(adjustedSqrtRatioX96, sqrt10X128, 1 << 128);
                }
            } else {
                adjustedSqrtRatioX96 = sqrtRatioX96 / (10 ** (difference / 2));
                if (difference % 2 == 1) {
                    adjustedSqrtRatioX96 = FullMath.mulDiv(adjustedSqrtRatioX96, 1 << 128, sqrt10X128);
                }
            }
        } else {
            adjustedSqrtRatioX96 = uint256(sqrtRatioX96);
        }
    }

    /// @notice 有符号整数的绝对值
    /// @param x 有符号整数
    /// @return x 的绝对值
    function abs(int256 x) private pure returns (uint256) {
        return uint256(x >= 0 ? x : -x);
    }

    function fixedPointToDecimalString(uint160 sqrtRatioX96, uint8 baseCurrencyDecimals, uint8 quoteCurrencyDecimals)
        internal
        pure
        returns (string memory)
    {
        uint256 adjustedSqrtRatioX96 =
            adjustForDecimalPrecision(sqrtRatioX96, baseCurrencyDecimals, quoteCurrencyDecimals);
        uint256 value = FullMath.mulDiv(adjustedSqrtRatioX96, adjustedSqrtRatioX96, 1 << 64);

        bool priceBelow1 = adjustedSqrtRatioX96 < 2 ** 96;
        if (priceBelow1) {
            // 10 ** 43 是获取最小可能价格的 5 位有效数字所需的精度，再 + 1 用于舍入
            value = FullMath.mulDiv(value, 10 ** 44, 1 << 128);
        } else {
            // 保留 4 位小数的精度，再 + 1 位用于舍入
            value = FullMath.mulDiv(value, 10 ** 5, 1 << 128);
        }

        // 获取位数
        uint256 temp = value;
        uint8 digits;
        while (temp != 0) {
            digits++;
            temp /= 10;
        }
        // 不计入为舍入而保留的那一位额外数字
        digits = digits - 1;

        // 处理舍入
        (uint256 sigfigs, bool extraDigit) = sigfigsRounded(value, digits);
        if (extraDigit) {
            digits++;
        }

        DecimalStringParams memory params;
        if (priceBelow1) {
            // 7 字节（"0." 和 5 位有效数字）+ 前导 0 的字节
            params.bufferLength = uint8(uint8(7) + (uint8(43) - digits));
            params.zerosStartIndex = 2;
            params.zerosEndIndex = uint8(uint256(43) - digits + 1);
            params.sigfigIndex = uint8(params.bufferLength - 1);
        } else if (digits >= 9) {
            // 价格字符串中没有小数点
            params.bufferLength = uint8(digits - 4);
            params.zerosStartIndex = 5;
            params.zerosEndIndex = uint8(params.bufferLength - 1);
            params.sigfigIndex = 4;
        } else {
            // 5 位有效数字分布在小数点两侧
            params.bufferLength = 6;
            params.sigfigIndex = 5;
            params.decimalIndex = uint8(digits - 5 + 1);
        }
        params.sigfigs = sigfigs;
        params.isLessThanOne = priceBelow1;
        params.isPercent = false;

        return generateDecimalString(params);
    }

    /// @notice 将以 pips 为单位的手续费数量转换为带百分号的小数字符串
    /// @param fee 手续费数量
    /// @return 带百分号的小数字符串形式的手续费
    function feeToPercentString(uint24 fee) internal pure returns (string memory) {
        if (fee.isDynamicFee()) {
            return "Dynamic";
        }
        if (fee == 0) {
            return "0%";
        }
        uint24 temp = fee;
        uint256 digits;
        uint8 numSigfigs;
        // 每次迭代都将 temp 除以 10，以此遍历 fee 的每一位数字，直到 temp 变为 0
        // 计算位数以及有效数字（非零数字）的个数
        while (temp != 0) {
            if (numSigfigs > 0) {
                // 计入最低有效数字之前的所有数字
                numSigfigs++;
            } else if (temp % 10 != 0) {
                numSigfigs++;
            }
            digits++;
            temp /= 10;
        }

        DecimalStringParams memory params;
        uint256 nZeros;
        if (digits >= 5) {
            // 表示手续费大于或等于 1%
            // 若小数 > 1（第 5 位数字是个位）
            uint256 decimalPlace = digits - numSigfigs >= 4 ? 0 : 1;
            nZeros = digits - 5 < numSigfigs - 1 ? 0 : digits - 5 - (numSigfigs - 1);
            params.zerosStartIndex = numSigfigs;
            params.zerosEndIndex = uint8(params.zerosStartIndex + nZeros - 1);
            params.sigfigIndex = uint8(params.zerosStartIndex - 1 + decimalPlace);
            params.bufferLength = uint8(nZeros + numSigfigs + 1 + decimalPlace);
        } else {
            // 表示手续费小于 1%
            // 否则若小数 < 1
            nZeros = 5 - digits; // 零的个数，包括小数点前的那个零
            params.zerosStartIndex = 2; // 前导零从小数点之后开始
            params.zerosEndIndex = uint8(nZeros + params.zerosStartIndex - 1); // 前导零的结束索引
            params.bufferLength = uint8(nZeros + numSigfigs + 2); // 字符串 buffer 的总长度，包括 "0." 和 "%"
            params.sigfigIndex = uint8(params.bufferLength - 2); // 起始有效数字的索引
            params.isLessThanOne = true;
        }
        params.sigfigs = uint256(fee) / (10 ** (digits - numSigfigs)); // 手续费的有效数字
        params.isPercent = true;
        params.decimalIndex = digits > 4 ? uint8(digits - 4) : 0; // 基于手续费的总位数

        return generateDecimalString(params);
    }

    function addressToString(address addr) internal pure returns (string memory) {
        return (uint256(uint160(addr))).toHexString(20);
    }

    /// @notice 为 Uniswap v4 NFT 生成 SVG 图像
    /// @param params 生成 SVG 图像所需的参数
    /// @return svg 字符串形式的 SVG 图像
    function generateSVGImage(ConstructTokenURIParams memory params) internal pure returns (string memory svg) {
        SVG.SVGParams memory svgParams = SVG.SVGParams({
            quoteCurrency: addressToString(params.quoteCurrency),
            baseCurrency: addressToString(params.baseCurrency),
            hooks: params.hooks,
            quoteCurrencySymbol: params.quoteCurrencySymbol,
            baseCurrencySymbol: params.baseCurrencySymbol,
            feeTier: feeToPercentString(params.fee),
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            tickSpacing: params.tickSpacing,
            overRange: overRange(params.tickLower, params.tickUpper, params.tickCurrent),
            tokenId: params.tokenId,
            color0: currencyToColorHex(uint256(uint160(params.quoteCurrency)), 136),
            color1: currencyToColorHex(uint256(uint160(params.baseCurrency)), 136),
            color2: currencyToColorHex(uint256(uint160(params.quoteCurrency)), 0),
            color3: currencyToColorHex(uint256(uint160(params.baseCurrency)), 0),
            x1: scale(getCircleCoord(uint256(uint160(params.quoteCurrency)), 16, params.tokenId), 0, 255, 16, 274),
            y1: scale(getCircleCoord(uint256(uint160(params.baseCurrency)), 16, params.tokenId), 0, 255, 100, 484),
            x2: scale(getCircleCoord(uint256(uint160(params.quoteCurrency)), 32, params.tokenId), 0, 255, 16, 274),
            y2: scale(getCircleCoord(uint256(uint160(params.baseCurrency)), 32, params.tokenId), 0, 255, 100, 484),
            x3: scale(getCircleCoord(uint256(uint160(params.quoteCurrency)), 48, params.tokenId), 0, 255, 16, 274),
            y3: scale(getCircleCoord(uint256(uint160(params.baseCurrency)), 48, params.tokenId), 0, 255, 100, 484)
        });

        return SVG.generateSVG(svgParams);
    }

    /// @notice 检查当前价格是在你的头寸区间之内、之上还是之下
    /// @param tickLower 下界 tick
    /// @param tickUpper 上界 tick
    /// @param tickCurrent 当前 tick
    /// @return 当前价格在头寸区间内时为 0，低于区间时为 -1，高于区间时为 1
    function overRange(int24 tickLower, int24 tickUpper, int24 tickCurrent) private pure returns (int8) {
        if (tickCurrent < tickLower) {
            return -1;
        } else if (tickCurrent > tickUpper) {
            return 1;
        } else {
            return 0;
        }
    }

    function isSpecialCharacter(bytes1 b) private pure returns (bool) {
        return b == '"' || b == "\u000c" || b == "\n" || b == "\r" || b == "\t";
    }

    function scale(uint256 n, uint256 inMn, uint256 inMx, uint256 outMn, uint256 outMx)
        private
        pure
        returns (string memory)
    {
        return ((n - inMn) * (outMx - outMn) / (inMx - inMn) + outMn).toString();
    }

    function currencyToColorHex(uint256 currency, uint256 offset) internal pure returns (string memory str) {
        return string((currency >> offset).toHexStringNoPrefix(3));
    }

    function getCircleCoord(uint256 currency, uint256 offset, uint256 tokenId) internal pure returns (uint256) {
        return (sliceCurrencyHex(currency, offset) * tokenId) % 255;
    }

    function sliceCurrencyHex(uint256 currency, uint256 offset) internal pure returns (uint256) {
        return uint256(uint8(currency >> offset));
    }
}
