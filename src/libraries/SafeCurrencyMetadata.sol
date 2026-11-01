// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20Metadata} from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AddressStringUtil} from "./AddressStringUtil.sol";

/// @title SafeCurrencyMetadata
/// @notice 能够从不规范或缺失的 ERC20 实现中获取代币符号（symbol）和精度（decimals）
/// @dev 参考：https://github.com/Uniswap/solidity-lib/blob/master/contracts/libraries/SafeERC20Namer.sol
library SafeCurrencyMetadata {
    uint8 constant MAX_SYMBOL_LENGTH = 12;

    /// @notice 尝试获取代币符号。若代币未实现 symbol，则返回由其地址派生的符号
    /// @param currency 代币地址
    /// @param nativeLabel 原生代币的标签
    /// @return 代币符号
    function currencySymbol(address currency, string memory nativeLabel) internal view returns (string memory) {
        if (currency == address(0)) {
            return nativeLabel;
        }
        string memory symbol = callAndParseStringReturn(currency, IERC20Metadata.symbol.selector);
        if (bytes(symbol).length == 0) {
            // 回退为地址的 6 位大写十六进制字符
            return addressToSymbol(currency);
        }
        if (bytes(symbol).length > MAX_SYMBOL_LENGTH) {
            return truncateSymbol(symbol);
        }
        return symbol;
    }

    /// @notice 尝试获取代币精度（decimals），若未实现或返回值不是 uint8 则返回 0
    /// @param currency 代币地址
    /// @return 代币精度（decimals）
    function currencyDecimals(address currency) internal view returns (uint8) {
        if (currency == address(0)) {
            return 18;
        }
        (bool success, bytes memory data) = currency.staticcall(abi.encodeCall(IERC20Metadata.decimals, ()));
        if (!success) {
            return 0;
        }
        if (data.length == 32) {
            uint256 decimals = abi.decode(data, (uint256));
            if (decimals <= type(uint8).max) {
                return uint8(decimals);
            }
        }
        return 0;
    }

    function bytes32ToString(bytes32 x) private pure returns (string memory) {
        bytes memory bytesString = new bytes(32);
        uint256 charCount = 0;
        for (uint256 j = 0; j < 32; j++) {
            bytes1 char = x[j];
            if (char != 0) {
                bytesString[charCount] = char;
                charCount++;
            }
        }
        bytes memory bytesStringTrimmed = new bytes(charCount);
        for (uint256 j = 0; j < charCount; j++) {
            bytesStringTrimmed[j] = bytesString[j];
        }
        return string(bytesStringTrimmed);
    }

    /// @notice 根据地址生成符号——取地址字符串的前 6 位十六进制字符并转为大写
    /// @param currencyAddress 代币地址
    /// @return 生成的符号
    function addressToSymbol(address currencyAddress) private pure returns (string memory) {
        return AddressStringUtil.toAsciiString(currencyAddress, 6);
    }

    /// @notice 调用外部合约中返回符号的 view 方法，并将输出解析为字符串
    /// @param currencyAddress 代币地址
    /// @param selector symbol 方法的函数选择器
    /// @return 解析得到的符号
    function callAndParseStringReturn(address currencyAddress, bytes4 selector) private view returns (string memory) {
        (bool success, bytes memory data) = currencyAddress.staticcall(abi.encodeWithSelector(selector));
        // 若未实现，则返回空字符串
        if (!success) {
            return "";
        }
        // bytes32 类型的数据长度总是 32
        if (data.length == 32) {
            bytes32 decoded = abi.decode(data, (bytes32));
            return bytes32ToString(decoded);
        } else if (data.length > 64) {
            return abi.decode(data, (string));
        }
        return "";
    }

    /// @notice 将符号截断为 MAX_SYMBOL_LENGTH 长度
    /// @dev 假定该字符串的长度已大于（或等于）MAX_SYMBOL_LENGTH
    /// @param str 符号
    /// @return 截断后的符号
    function truncateSymbol(string memory str) internal pure returns (string memory) {
        bytes memory strBytes = bytes(str);
        bytes memory truncatedBytes = new bytes(MAX_SYMBOL_LENGTH);
        for (uint256 i = 0; i < MAX_SYMBOL_LENGTH; i++) {
            truncatedBytes[i] = strBytes[i];
        }
        return string(truncatedBytes);
    }
}
