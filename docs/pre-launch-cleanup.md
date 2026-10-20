# 正式上线前必须清理的临时代码

`[TEMP-RECOVERY]` 是主网验收阶段使用的临时回收入口：Coordinator 的 `DEFAULT_ADMIN_ROLE` 可以把任意 TaxProcessor / BuybackVault 克隆中的全部资产转走。它只用于回收团队自有测试实例的资产，**不得进入正式部署**；否则正式环境中所有用户代币都会带有管理员一键清空的路径。

清理完成并通过下方核验后，再执行正式部署；正式部署完成后删除本文件。

## 1. 删除合约代码

### `src/TaxProcessor.sol`
- [ ] 文件顶部错误定义：`UnauthorizedTemporaryRecovery`、`InvalidTemporaryRecoveryRecipient`（及其上方的 `[TEMP-RECOVERY]` 注释）
- [ ] 合约内整段 `[TEMP-RECOVERY]` 代码块：
  - `event TemporaryRecovery`
  - `modifier onlyTemporaryRecoveryAdmin`
  - `function temporaryRecoverAll(address to)`

### `src/BuybackVault.sol`
- [ ] 文件顶部错误定义：`UnauthorizedVaultRecovery`、`InvalidVaultRecoveryRecipient`（及其上方的 `[TEMP-RECOVERY]` 注释）
- [ ] 合约内整段 `[TEMP-RECOVERY]` 代码块：
  - `event VaultRecovery`
  - `function temporaryRecoverAll(address to)`

> `IAccessControl` 导入仍被 `onlyKeeper` / keeper 校验使用，**不要**随之删除。

## 2. 处理测试文件 `test/TemporaryRecovery.t.sol`

- [ ] **先迁移** `KeeperRevokeTest`（及其依赖的 `RealRegistry`、`MockERC20`、`MockWBNB`、`MockRouter`）到其它测试文件（如 `test/TaxProcessor.t.sol`），并去掉其中调用 `temporaryRecoverAll` 的断言，保留“keeper 撤销后失去 `processPendingTax` 权限”的覆盖。
- [ ] 删除其余回收专用测试：`TemporaryRecoveryTaxProcessorTest`、`TemporaryRecoveryVaultTest`、`TemporaryRecoveryRealTokenTest`，以及仅被它们使用的 Mock（`MockRegistry`、`MockFailingDividend`、`MockPair`、`NoReceive`、`ReentrantRecipient`、`ETHTransferFailed`）。
- [ ] 删除 `test/TemporaryRecovery.t.sol`。

## 3. 本地核验（全部通过才可部署）

在仓库根目录执行，以下搜索必须**无任何输出**：

```bash
grep -rnE "TEMP-RECOVERY|temporaryRecoverAll|TemporaryRecovery|VaultRecovery" src test script docs/frontend-integration.md keeper/src
```

然后构建并跑全量测试：

```bash
forge build --force
```

```bash
forge test
```

## 4. 部署后链上核验

`temporaryRecoverAll(address)` 的函数选择器为 `0x777f431a`。正式部署后，对新的 `taxProcessorImplementation` 与 `buybackVaultImplementation`（地址以 `broadcast/` 产物为准）确认字节码中不含该选择器：

```bash
cast code <IMPLEMENTATION_ADDRESS> --rpc-url bsc | grep -ci 777f431a
```

输出必须为 `0`。另可调用一次确认 revert：

```bash
cast call <IMPLEMENTATION_ADDRESS> "temporaryRecoverAll(address)" 0x000000000000000000000000000000000000bEEF --rpc-url bsc
```

- [ ] TaxProcessor 实现：选择器不存在
- [ ] BuybackVault 实现：选择器不存在
- [ ] 区块浏览器上验证的源码中不含 `temporaryRecoverAll`

## 当前影响面（截至编写时已核对）

- 仅 `src/TaxProcessor.sol`、`src/BuybackVault.sol`、`test/TemporaryRecovery.t.sol` 涉及。
- `keeper/`、`script/`、`docs/frontend-integration.md` 均未引用回收函数，无需同步修改。
- 已部署的旧实例（`script/deployments/56.json` / `97.json` 对应的实现）不含该函数。
