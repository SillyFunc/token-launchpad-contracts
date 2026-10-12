## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

- **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
- **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
- **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
- **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

项目文档:

- [`docs/frontend-integration.md`](docs/frontend-integration.md) — 前端对接(BSC 主网与测试网)
- [`docs/four-channel-tax-design.md`](docs/four-channel-tax-design.md) — 四通道税收分配的资金流设计与威胁模型

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Deploy.s.sol:Deploy --rpc-url <your_rpc_url> --broadcast --private-key <your_private_key>
```

部署前必须设置环境对应的 `KEEPER_ADDRESS` 与 `ROUTER_ADDRESS`；测试网和主网不得混用 Router 或 Keeper 私钥。

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```
