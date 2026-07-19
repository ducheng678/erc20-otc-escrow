# ERC20 OTC Escrow

一个固定价格的链上 ERC-20 场外交易托管合约。Maker 先锁定卖出资产，Taker
在截止时间前支付报价资产，合约在同一笔交易中完成双边结算。

## 核心流程

1. Maker 调用 `createOffer` 并授权合约锁定 `sellToken`。
2. 任意 Taker（或指定的 `allowedTaker`）调用 `acceptOffer`。
3. 合约先把订单标记为 `Filled`，再将 Taker 的 `buyToken` 转给 Maker，
   并将托管的 `sellToken` 转给 Taker。
4. Maker 可在成交和到期前取消；到期后任何人都可触发退款。

## 安全设计

- `SafeERC20` 兼容返回 `false` 或无返回值的常见 ERC-20 实现。
- 五个状态变更入口均使用 `nonReentrant`。
- 所有结算路径遵循 Checks-Effects-Interactions。
- 自定义 error 明确区分参数、权限、截止时间和状态机错误。
- `allowedTaker` 为零地址时公开接单，否则仅指定地址可成交。
- 状态在 Token 外部调用前更新；任一转账失败会回滚整个交易。
- 对进入托管的余额做精确差额检查，fee-on-transfer Token 会被明确拒绝，
  避免不同订单之间出现资金缺口。

合约面向标准 ERC-20；fee-on-transfer Token 会回滚，rebasing Token 不受支持。

## 项目结构

```text
src/ERC20OTCEscrow.sol           核心合约
test/ERC20OTCEscrow.t.sol        单元与安全测试
test/mocks/MockERC20.sol         标准测试 Token
test/mocks/ReentrantERC20.sol    transferFrom 回调攻击 Token
test/mocks/FeeOnTransferERC20.sol 手续费 Token
test/utils/TestBase.sol          最小 Foundry 测试基类
```

## 运行

需要 Node.js 20 或更高版本。项目会按当前操作系统安装对应的 Forge 二进制，
不要求全局安装。

```bash
npm install
npm test
```

查看 Gas 报告：

```bash
npm run test:gas
```

## 已覆盖场景

- 创建报价并锁定 Maker Token
- 原子成交与双方余额结算
- 非 Maker 取消失败
- 已成交订单不能取消
- 截止前不能过期
- 截止后退款给 Maker
- 同一订单不能重复成交
- `allowedTaker` 权限限制
- 零地址、零金额、相同 Token 参数校验
- 非未来截止时间与截止时刻成交边界
- fee-on-transfer Token 精确到账校验
- 恶意 Token 回调被 `ReentrancyGuard` 阻止
