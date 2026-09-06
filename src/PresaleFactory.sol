// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {PRESALE} from "src/Presale.sol";
import {Clones} from "src/Clones.sol";

// ---------------------------------------------------------------------------
// 自定义错误
// ---------------------------------------------------------------------------

// ============================================================================
// PresaleFactory - 轻量克隆版 PRESALE（仅作托管仓创建；预售配置见 CoordinatorFactory.setupPresale）
// ============================================================================

struct PresaleConfig {
    uint256 presaleTokenPrice; // BNB per token（wei）
    uint256 maxBuyPerWallet;
    uint256 hardcap;
    uint256 minLiquidityAmount;
    uint256 softCap; // 认购成功线：必须 ≥ minLiquidityAmount，否则 endPresale 判失败开放退款
    uint256 startTime;
    uint256 duration; // 认购时长（秒）：openPresale 锚定 endTime = max(开盘时刻, startTime) + duration
    uint256 vestingDelay;
    uint256 vestingRate;
    uint256 slippage;
    uint256 creatorBuyTokens; // 创建者购买目标数量（wei）：0 = quote 模式（买多少 BNB）；BNB 金额由 setupPresale 的 msg.value 承载
}

contract PresaleFactory is AccessControl {
    bytes32 public constant COORDINATOR_ROLE = keccak256("COORDINATOR_ROLE");

    address public immutable presaleImplementation;

    event PresaleCreated(address indexed presale, address indexed creator);

    constructor(address _presaleImplementation, address _coordinator) {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(COORDINATOR_ROLE, _coordinator);
        presaleImplementation = _presaleImplementation;

        // 锁定实现合约：以占位参数初始化模板本体，使其 _initialized 置位、任何人
        // （含恶意方）都无法再 initialize 实现合约并伪装其归属（克隆存储各自独立，
        // 不受模板初始化状态影响；EIP-1167 标准加固，对齐 OZ _disableInitializers 语义）。
        // 模板未部署（地址无代码）时本调用回滚，工厂部署随之失败，配置事故在部署期暴露
        PRESALE(payable(_presaleImplementation)).initialize(address(1), address(1));
    }

    /// @dev 克隆并创建未配置的托管仓（owner=工厂，配置完成后移交上层）。
    ///      预售各项配置（份额/价格/vesting）由 CoordinatorFactory.setupPresale 完成。
    ///      份额写入锁（_sharesLocked）首次 setup 时置位：纯托管初始化绕开 configureLaunch
    ///      直接置位 presaleEnabled=false，避免工厂的一次性初始化消费掉唯一写入名额
    function createPresale(address _router) external onlyRole(COORDINATOR_ROLE) returns (address) {
        address presaleAddress = Clones.clone(presaleImplementation);
        PRESALE presale = PRESALE(payable(presaleAddress));

        presale.initialize(address(this), _router); // owner = 工厂（配置期间），末尾移交
        presale.setCustodyMode(); // 纯托管模式（份额三字段保持 0，不动写入锁）

        // 配置完成，所有权移交上层（Coordinator），由其再转给创建者
        presale.transferOwnership(msg.sender);

        emit PresaleCreated(presaleAddress, msg.sender);
        return presaleAddress;
    }
}
