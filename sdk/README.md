# @sillyfunc/launchpad-contracts

Type-safe contract ABIs, deployment addresses, and a singleton contract registry for the SillyFunc token launchpad. The package is ESM-only, has no runtime dependencies, and can be used in browsers or Node.js. It does not include React, wagmi, RPC, wallet, or business-logic wrappers.

The package name is currently configured as `@sillyfunc/launchpad-contracts`. Confirm that the npm scope is available to the publishing account before the first release, or change `name` in `package.json`.

## Install

```bash
pnpm add @sillyfunc/launchpad-contracts
```

## Fixed deployments

`contracts` contains only singleton contracts that have one fixed address per chain:

```ts
import { contracts } from "@sillyfunc/launchpad-contracts";

const coordinator = contracts[56].coordinatorFactory;

coordinator.address;
coordinator.abi;
```

With wagmi, spread the registry entry directly into a contract call:

```ts
import { contracts } from "@sillyfunc/launchpad-contracts";
import { useReadContract } from "wagmi";

const result = useReadContract({
  ...contracts[56].coordinatorFactory,
  functionName: "getTotalTokenCount",
});
```

The ABI values use `as const`, so viem and wagmi can infer valid function names, arguments, and return types.

## Dynamic presales

Each `PRESALE` is a clone with its own address. Supply the instance address discovered from `CoordinatorFactory` or its events:

```ts
import { presaleAbi } from "@sillyfunc/launchpad-contracts";
import { useReadContract } from "wagmi";

const result = useReadContract({
  address: presaleAddress,
  abi: presaleAbi,
  functionName: "getLaunchStatus",
});
```

## Dynamic tokens

Each `FlapTaxTokenV3` token is also a clone with its own address:

```ts
import { flapTaxTokenV3Abi } from "@sillyfunc/launchpad-contracts";
import { useReadContract } from "wagmi";

const result = useReadContract({
  address: tokenAddress,
  abi: flapTaxTokenV3Abi,
  functionName: "getPoolStateData",
});
```

Implementation/template addresses remain available through `addresses[chainId]` for verification and administration. They are deliberately not exposed as user-instance addresses in `contracts`.

## Public exports

```ts
import {
  addresses,
  contracts,
  coordinatorFactoryAbi,
  tokenFactoryAbi,
  presaleFactoryAbi,
  presaleAbi,
  flapTaxTokenV3Abi,
  type DeploymentAddresses,
  type SupportedChainId,
} from "@sillyfunc/launchpad-contracts";
```

## Generate and build

Run `forge build` from the repository root before generating the SDK. The generator reads these Foundry artifacts:

- `out/CoordinatorFactory.sol/CoordinatorFactory.json`
- `out/TokenFactory.sol/TokenFactory.json`
- `out/PresaleFactory.sol/PresaleFactory.json`
- `out/Presale.sol/PRESALE.json`
- `out/FlapTaxTokenV3.sol/FlapTaxTokenV3.json`

It also scans `script/deployments/*.json`, validates each chain ID and address, and writes deterministic TypeScript files under `src/generated`.

```bash
pnpm generate
pnpm typecheck
pnpm build
```

Generated TypeScript is committed so ABI and deployment changes can be reviewed in pull requests. Do not edit it by hand.

## Publish

Publishing is intentionally manual. Authenticate to npm, confirm the package name/scope, then run:

```bash
pnpm version patch
pnpm publish --access public
```

`prepublishOnly` regenerates and builds the package. Inspect the resulting Git diff and use `pnpm pack --dry-run` before publishing when changing package contents.

## Contract release flow

1. Modify Solidity and its tests.
2. Run `forge fmt --check`, `forge build`, and `forge test`.
3. Deploy with `script/Deploy.s.sol`; after every deployment and role grant succeeds, the script writes `script/deployments/<chainId>.json`.
4. Review and commit the deployment JSON.
5. From `sdk`, run `pnpm generate`, `pnpm typecheck`, and `pnpm build`.
6. Review and commit the generated ABI and address diff.
7. Bump the npm package version.
8. Run `pnpm pack --dry-run`, then publish to npm.
9. Update the DApp dependency and verify its supported chain selection.
