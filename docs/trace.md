# v4-periphery 英文注释中文翻译 · 任务进度跟踪

> 本文档由主代理维护，子代理完成并通过校验后，主代理在对应文件前打勾。未完成的文件勾选框留空。

## 翻译规则

1. 只翻译注释（`//`、`///`、`/* */`、`/** */`、`#`），在英文原文位置直接替换为中文，**翻译前后每个文件行数不变**。
2. 保留专有名词、函数名、变量名、合约名、类型名及 NatSpec 标签（`@notice`、`@dev`、`@param <参数名>`、`@return`、`@inheritdoc` 等）。
3. 代码、字符串字面量、`SPDX-License-Identifier`、`forge-config` 等指令性注释保持原样；被注释掉的代码不翻译。
4. 英文 `.md` 文件另存为同目录下的 `*_zh.md` 译文，原件保留不动，译文与原件行数一致。
5. 子模块 `lib/`（v4-core、permit2）属于外部仓库，`broadcast/`、`snapshots/` 下为 JSON / 快照数据，`audits/` 下为 PDF，均不在本次翻译范围内。

## 统计总览

| 项目 | 数量 |
| --- | --- |
| 纳入范围的文件总数 | 179 |
| 其中 Solidity 文件（`.sol`） | 172 |
| 其中 TypeScript 文件（`.ts`） | 1 |
| 其中配置文件（含 `#` 注释） | 3 |
| 其中 Markdown 文件（生成 `_zh.md` 译文） | 3 |
| 文件总行数 | 31508 |
| 注释行总数（不含 SPDX 行，`.md` 不计） | 3332 |
| 并行子代理分组数 | 28 |

## 总体进度

**已完成：0 / 179**

## 分组明细

### G01（9 个文件，534 行，注释 33 行）· 进度 0/9

- [ ] `script/01_PoolManager.s.sol` — 21 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `script/02_PoolModifyLiquidityTest.s.sol` — 18 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `script/03_PoolSwapTest.s.sol` — 18 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `script/DeployPosm.s.sol` — 34 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `script/DeployReservesLens.s.sol` — 40 行｜注释 3 行
- [ ] `script/DeployStateView.s.sol` — 22 行｜注释 1 行
- [ ] `script/DeployV4Quoter.s.sol` — 22 行｜注释 1 行
- [ ] `scripts/reserves-lens-reference.ts` — 232 行｜注释 14 行
- [ ] `src/PositionDescriptor.sol` — 127 行｜注释 14 行

### G02（2 个文件，659 行，注释 146 行）· 进度 0/2

- [ ] `src/PositionManager.sol` — 574 行｜注释 132 行
- [ ] `src/UniswapV4DeployerCompetition.sol` — 85 行｜注释 14 行

### G03（9 个文件，729 行，注释 143 行）· 进度 0/9

- [ ] `src/V4Router.sol` — 233 行｜注释 24 行
- [ ] `src/base/BaseActionsRouter.sol` — 75 行｜注释 18 行
- [ ] `src/base/BaseV4Quoter.sol` — 59 行｜注释 7 行
- [ ] `src/base/DeltaResolver.sol` — 123 行｜注释 42 行
- [ ] `src/base/EIP712_v4.sol` — 56 行｜注释 16 行
- [ ] `src/base/ERC721Permit_v4.sol` — 99 行｜注释 21 行
- [ ] `src/base/ImmutableState.sol` — 25 行｜注释 5 行
- [ ] `src/base/Multicall_v4.sol` — 25 行｜注释 4 行
- [ ] `src/base/NativeWrapper.sol` — 34 行｜注释 6 行

### G04（9 个文件，727 行，注释 132 行）· 进度 0/9

- [ ] `src/base/Notifier.sol` — 127 行｜注释 15 行
- [ ] `src/base/Permit2Forwarder.sol` — 41 行｜注释 7 行
- [ ] `src/base/PoolInitializer_v4.sol` — 20 行｜注释 4 行
- [ ] `src/base/ReentrancyLock.sol` — 20 行｜注释 1 行
- [ ] `src/base/SafeCallback.sol` — 21 行｜注释 5 行
- [ ] `src/base/UnorderedNonce.sol` — 28 行｜注释 7 行
- [ ] `src/hooks/permissionedPools/BaseAllowListChecker.sol` — 13 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `src/hooks/permissionedPools/PermissionedPositionManager.sol` — 354 行｜注释 78 行
- [ ] `src/hooks/permissionedPools/PermissionedV4Router.sol` — 103 行｜注释 15 行

### G05（6 个文件，436 行，注释 111 行）· 进度 0/6

- [ ] `src/hooks/permissionedPools/PermissionsAdapter.sol` — 190 行｜注释 31 行
- [ ] `src/hooks/permissionedPools/PermissionsAdapterFactory.sol` — 48 行｜注释 5 行
- [ ] `src/hooks/permissionedPools/interfaces/IAllowlistChecker.sol` — 13 行｜注释 4 行
- [ ] `src/hooks/permissionedPools/interfaces/IPermissionsAdapter.sol` — 106 行｜注释 50 行
- [ ] `src/hooks/permissionedPools/interfaces/IPermissionsAdapterFactory.sol` — 52 行｜注释 21 行
- [ ] `src/hooks/permissionedPools/libraries/PermissionFlags.sol` — 27 行｜注释 0 行（无英文注释，仅需确认）

### G06（10 个文件，299 行，注释 136 行）· 进度 0/10

- [ ] `src/interfaces/IEIP712_v4.sol` — 10 行｜注释 4 行
- [ ] `src/interfaces/IERC721Permit_v4.sol` — 38 行｜注释 17 行
- [ ] `src/interfaces/IImmutableState.sol` — 11 行｜注释 3 行
- [ ] `src/interfaces/IMsgSender.sol` — 13 行｜注释 7 行
- [ ] `src/interfaces/IMulticall_v4.sol` — 13 行｜注释 7 行
- [ ] `src/interfaces/INotifier.sol` — 54 行｜注释 29 行
- [ ] `src/interfaces/IPermit2Forwarder.sol` — 30 行｜注释 14 行
- [ ] `src/interfaces/IPoolInitializer_v4.sol` — 15 行｜注释 7 行
- [ ] `src/interfaces/IPositionDescriptor.sol` — 40 行｜注释 19 行
- [ ] `src/interfaces/IPositionManager.sol` — 75 行｜注释 29 行

### G07（2 个文件，322 行，注释 160 行）· 进度 0/2

- [ ] `src/interfaces/IReservesLens.sol` — 189 行｜注释 88 行
- [ ] `src/interfaces/IStateView.sol` — 133 行｜注释 72 行

### G08（9 个文件，889 行，注释 144 行）· 进度 0/9

- [ ] `src/interfaces/ISubscriber.sol` — 38 行｜注释 22 行
- [ ] `src/interfaces/IUniswapV4DeployerCompetition.sol` — 25 行｜注释 8 行
- [ ] `src/interfaces/IUnorderedNonce.sol` — 17 行｜注释 7 行
- [ ] `src/interfaces/IV4Quoter.sol` — 67 行｜注释 32 行
- [ ] `src/interfaces/IV4Router.sol` — 67 行｜注释 15 行
- [ ] `src/interfaces/external/IHookStats.sol` — 18 行｜注释 5 行
- [ ] `src/interfaces/external/IWETH9.sol` — 13 行｜注释 3 行
- [ ] `src/lens/ReservesLens.sol` — 535 行｜注释 39 行
- [ ] `src/lens/StateView.sol` — 109 行｜注释 13 行

### G09（7 个文件，708 行，注释 141 行）· 进度 0/7

- [ ] `src/lens/V4Quoter.sol` — 159 行｜注释 24 行
- [ ] `src/libraries/ActionConstants.sol` — 20 行｜注释 9 行
- [ ] `src/libraries/Actions.sol` — 63 行｜注释 23 行
- [ ] `src/libraries/AddressStringUtil.sol` — 46 行｜注释 15 行
- [ ] `src/libraries/BipsLibrary.sol` — 17 行｜注释 4 行
- [ ] `src/libraries/CalldataDecoder.sol` — 387 行｜注释 62 行
- [ ] `src/libraries/CurrencyRatioSortOrder.sol` — 16 行｜注释 4 行

### G10（5 个文件，718 行，注释 151 行）· 进度 0/5

- [ ] `src/libraries/Descriptor.sol` — 528 行｜注释 92 行
- [ ] `src/libraries/ERC721PermitHash.sol` — 70 行｜注释 28 行
- [ ] `src/libraries/HexStrings.sol` — 22 行｜注释 7 行
- [ ] `src/libraries/LiquidityAmounts.sol` — 77 行｜注释 21 行
- [ ] `src/libraries/Locker.sol` — 21 行｜注释 3 行

### G11（6 个文件，732 行，注释 135 行）· 进度 0/6

- [ ] `src/libraries/PathKey.sol` — 38 行｜注释 7 行
- [ ] `src/libraries/PositionConfig.sol` — 35 行｜注释 15 行
- [ ] `src/libraries/PositionConfigId.sol` — 39 行｜注释 5 行
- [ ] `src/libraries/PositionInfoLibrary.sol` — 104 行｜注释 33 行
- [ ] `src/libraries/QuoterRevert.sol` — 49 行｜注释 16 行
- [ ] `src/libraries/SVG.sol` — 467 行｜注释 59 行

### G12（13 个文件，1761 行，注释 130 行）· 进度 0/13

- [ ] `src/libraries/SafeCurrencyMetadata.sol` — 108 行｜注释 24 行
- [ ] `src/libraries/SlippageCheck.sol` — 53 行｜注释 21 行
- [ ] `src/libraries/VanityAddressLib.sol` — 97 行｜注释 32 行
- [ ] `test/BaseActionsRouter.t.sol` — 149 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `test/DeltaResolver.t.sol` — 40 行｜注释 3 行
- [ ] `test/EIP712.t.sol` — 47 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `test/Multicall.t.sol` — 219 行｜注释 14 行
- [ ] `test/PositionDescriptor.t.sol` — 411 行｜注释 16 行
- [ ] `test/ReservesLens.fork.t.sol` — 188 行｜注释 6 行
- [ ] `test/ReservesLens.fuzz.t.sol` — 86 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `test/ReservesLens.gas.t.sol` — 60 行｜注释 1 行
- [ ] `test/ReservesLens.hooks.t.sol` — 217 行｜注释 13 行
- [ ] `test/ReservesLens.invariant.t.sol` — 86 行｜注释 0 行（无英文注释，仅需确认）

### G13（7 个文件，1948 行，注释 74 行）· 进度 0/7

- [ ] `test/ReservesLens.t.sol` — 466 行｜注释 4 行
- [ ] `test/SafeCallback.t.sol` — 34 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `test/StateViewTest.t.sol` — 488 行｜注释 35 行
- [ ] `test/UniswapV4DeployerCompetition.t.sol` — 178 行｜注释 1 行
- [ ] `test/UnorderedNonce.t.sol` — 122 行｜注释 5 行
- [ ] `test/V4Quoter.t.sol` — 586 行｜注释 15 行
- [ ] `test/base64.sol` — 74 行｜注释 14 行

### G14（3 个文件，723 行，注释 90 行）· 进度 0/3

- [ ] `test/erc721Permit/ERC721Permit.permit.t.sol` — 297 行｜注释 33 行
- [ ] `test/erc721Permit/ERC721Permit.permitForAll.t.sol` — 363 行｜注释 54 行
- [ ] `test/hooks/permissionedPools/PermissionedPoolsBase.sol` — 63 行｜注释 3 行

### G15（1 个文件，2714 行，注释 293 行）· 进度 0/1

- [ ] `test/hooks/permissionedPools/PermissionedPositionManager.t.sol` — 2714 行｜注释 293 行

### G16（1 个文件，2422 行，注释 130 行）· 进度 0/1

- [ ] `test/hooks/permissionedPools/PermissionedV4Router.t.sol` — 2422 行｜注释 130 行

### G17（8 个文件，1549 行，注释 119 行）· 进度 0/8

- [ ] `test/hooks/permissionedPools/PermissionsAdapter.t.sol` — 543 行｜注释 36 行
- [ ] `test/hooks/permissionedPools/PermissionsAdapterFactory.t.sol` — 94 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `test/hooks/permissionedPools/UnwindGasGriefPoC.t.sol` — 236 行｜注释 39 行
- [ ] `test/hooks/permissionedPools/UnwindReentrancyFixedPoC.t.sol` — 437 行｜注释 34 行
- [ ] `test/hooks/permissionedPools/mocks/MockInsecureHooks.sol` — 28 行｜注释 1 行
- [ ] `test/hooks/permissionedPools/mocks/MockPermissionedHooks.sol` — 162 行｜注释 1 行
- [ ] `test/hooks/permissionedPools/mocks/MockRemoveLiquidityDataHook.sol` — 26 行｜注释 3 行
- [ ] `test/hooks/permissionedPools/mocks/MockUnapprovedWrapper.sol` — 23 行｜注释 5 行

### G18（10 个文件，1993 行，注释 115 行）· 进度 0/10

- [ ] `test/hooks/permissionedPools/shared/PermissionedDeployers.sol` — 350 行｜注释 21 行
- [ ] `test/hooks/permissionedPools/shared/PermissionedPosmTestSetup.sol` — 251 行｜注释 10 行
- [ ] `test/hooks/permissionedPools/shared/PermissionedRoutingTestHelpers.sol` — 508 行｜注释 18 行
- [ ] `test/libraries/BipsLibrary.t.sol` — 53 行｜注释 7 行
- [ ] `test/libraries/CalldataDecoder.t.sol` — 430 行｜注释 5 行
- [ ] `test/libraries/Descriptor.t.sol` — 155 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `test/libraries/PositionInfoLibrary.t.sol` — 72 行｜注释 2 行
- [ ] `test/libraries/SVG.t.sol` — 57 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `test/libraries/SafeCurrencyMetadata.t.sol` — 16 行｜注释 3 行
- [ ] `test/libraries/VanityAddressLib.t.sol` — 101 行｜注释 49 行

### G19（25 个文件，1866 行，注释 137 行）· 进度 0/25

- [ ] `test/mocks/MockApprovalHijackSubscriber.sol` — 52 行｜注释 10 行
- [ ] `test/mocks/MockBadSubscribers.sol` — 100 行｜注释 2 行
- [ ] `test/mocks/MockBaseActionsRouter.sol` — 123 行｜注释 9 行
- [ ] `test/mocks/MockBurnRevertingSubscriber.sol` — 22 行｜注释 2 行
- [ ] `test/mocks/MockCalldataDecoder.sol` — 190 行｜注释 2 行
- [ ] `test/mocks/MockDeltaResolver.sol` — 47 行｜注释 1 行
- [ ] `test/mocks/MockERC721Permit.sol` — 19 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `test/mocks/MockFeeOnTransfer.sol` — 43 行｜注释 3 行
- [ ] `test/mocks/MockFlashAttackSubscriber.sol` — 36 行｜注释 9 行
- [ ] `test/mocks/MockHookStats.sol` — 72 行｜注释 2 行
- [ ] `test/mocks/MockMsgSenderHook.sol` — 33 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `test/mocks/MockMulticall.sol` — 87 行｜注释 5 行
- [ ] `test/mocks/MockPermissionedRouter.sol` — 129 行｜注释 2 行
- [ ] `test/mocks/MockReenterHook.sol` — 38 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `test/mocks/MockReentrantSubscriber.sol` — 33 行｜注释 6 行
- [ ] `test/mocks/MockSafeCallback.sol` — 18 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `test/mocks/MockSettableExtsloadManager.sol` — 24 行｜注释 3 行
- [ ] `test/mocks/MockShortExtsloadManager.sol` — 15 行｜注释 3 行
- [ ] `test/mocks/MockSubscriber.sol` — 53 行｜注释 1 行
- [ ] `test/mocks/MockUnorderedNonce.sol` — 15 行｜注释 1 行
- [ ] `test/mocks/MockUnsubscribeRevertingSubscriber.sol` — 23 行｜注释 3 行
- [ ] `test/mocks/MockV4Router.sol` — 42 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `test/mocks/ReentrantToken.sol` — 29 行｜注释 4 行
- [ ] `test/position-managers/Execute.t.sol` — 273 行｜注释 27 行
- [ ] `test/position-managers/FeeCollection.t.sol` — 350 行｜注释 42 行

### G20（1 个文件，828 行，注释 109 行）· 进度 0/1

- [ ] `test/position-managers/IncreaseLiquidity.t.sol` — 828 行｜注释 109 行

### G21（3 个文件，1167 行，注释 131 行）· 进度 0/3

- [ ] `test/position-managers/NativeToken.t.sol` — 796 行｜注释 93 行
- [ ] `test/position-managers/Permit.t.sol` — 296 行｜注释 35 行
- [ ] `test/position-managers/Permit2Forwarder.t.sol` — 75 行｜注释 3 行

### G22（1 个文件，928 行，注释 64 行）· 进度 0/1

- [ ] `test/position-managers/PositionManager.gas.t.sol` — 928 行｜注释 64 行

### G23（1 个文件，982 行，注释 133 行）· 进度 0/1

- [ ] `test/position-managers/PositionManager.modifyLiquidities.t.sol` — 982 行｜注释 133 行

### G24（2 个文件，1191 行，注释 90 行）· 进度 0/2

- [ ] `test/position-managers/PositionManager.multicall.t.sol` — 503 行｜注释 39 行
- [ ] `test/position-managers/PositionManager.notifier.t.sol` — 688 行｜注释 51 行

### G25（4 个文件，1738 行，注释 104 行）· 进度 0/4

- [ ] `test/position-managers/PositionManager.t.sol` — 1094 行｜注释 81 行
- [ ] `test/router/Payments.gas.t.sol` — 80 行｜注释 2 行
- [ ] `test/router/Payments.t.sol` — 189 行｜注释 9 行
- [ ] `test/router/V4Router.gas.t.sol` — 375 行｜注释 12 行

### G26（10 个文件，1730 行，注释 140 行）· 进度 0/10

- [ ] `test/router/V4Router.t.sol` — 1142 行｜注释 50 行
- [ ] `test/router/V4RouterExactOutputUnfilled.t.sol` — 111 行｜注释 19 行
- [ ] `test/script/DeployPoolManager.t.sol` — 27 行｜注释 3 行
- [ ] `test/script/DeployPoolMofifyLiquidityTest.t.sol` — 26 行｜注释 1 行
- [ ] `test/script/DeployPoolSwapTest.t.sol` — 26 行｜注释 1 行
- [ ] `test/shared/Deploy.sol` — 113 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `test/shared/FeeMath.sol` — 63 行｜注释 4 行
- [ ] `test/shared/HookMiner.sol` — 57 行｜注释 20 行
- [ ] `test/shared/HookMinerCreate3.sol` — 82 行｜注释 28 行
- [ ] `test/shared/HookModifyLiquidities.sol` — 83 行｜注释 14 行

### G27（9 个文件，1016 行，注释 37 行）· 进度 0/9

- [ ] `test/shared/HookSavesDelta.sol` — 49 行｜注释 11 行
- [ ] `test/shared/LiquidityOperations.sol` — 209 行｜注释 7 行
- [ ] `test/shared/Permit2SignatureHelpers.sol` — 132 行｜注释 2 行
- [ ] `test/shared/Planner.sol` — 97 行｜注释 2 行
- [ ] `test/shared/PositionConfig.sol` — 11 行｜注释 1 行
- [ ] `test/shared/PosmTestSetup.sol` — 175 行｜注释 9 行
- [ ] `test/shared/ReservesReference.sol` — 82 行｜注释 0 行（无英文注释，仅需确认）
- [ ] `test/shared/RoutingTestHelpers.sol` — 213 行｜注释 5 行
- [ ] `test/shared/fuzz/LiquidityFuzzers.sol` — 48 行｜注释 0 行（无英文注释，仅需确认）

### G28（6 个文件，199 行，注释 4 行）· 进度 0/6

- [ ] `README.md` — 37 行 → 译文 `README_zh.md`
- [ ] `CONTRIBUTING.md` — 61 行 → 译文 `CONTRIBUTING_zh.md`
- [ ] `.github/pull_request_template.md` — 3 行 → 译文 `.github/pull_request_template_zh.md`
- [ ] `foundry.toml` — 44 行｜注释 2 行
- [ ] `.github/workflows/deploy.yaml` — 48 行｜注释 1 行
- [ ] `.gitignore` — 6 行｜注释 1 行
