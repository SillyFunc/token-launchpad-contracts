import { mkdir, readdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const GENERATED_HEADER = "// AUTO-GENERATED FILE. DO NOT EDIT.\n\n";

const sdkRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const repositoryRoot = resolve(sdkRoot, "..");
const generatedRoot = resolve(sdkRoot, "src/generated");
const abiOutputRoot = resolve(generatedRoot, "abis");
const deploymentsRoot = resolve(repositoryRoot, "script/deployments");

const ABI_CONTRACTS = [
  {
    artifactPath: "out/CoordinatorFactory.sol/CoordinatorFactory.json",
    outputFile: "coordinatorFactory.ts",
    exportName: "coordinatorFactoryAbi",
  },
  {
    artifactPath: "out/TokenFactory.sol/TokenFactory.json",
    outputFile: "tokenFactory.ts",
    exportName: "tokenFactoryAbi",
  },
  {
    artifactPath: "out/PresaleFactory.sol/PresaleFactory.json",
    outputFile: "presaleFactory.ts",
    exportName: "presaleFactoryAbi",
  },
  {
    artifactPath: "out/Presale.sol/PRESALE.json",
    outputFile: "presale.ts",
    exportName: "presaleAbi",
  },
  {
    artifactPath: "out/FlapTaxTokenV3.sol/FlapTaxTokenV3.json",
    outputFile: "flapTaxTokenV3.ts",
    exportName: "flapTaxTokenV3Abi",
  },
  {
    artifactPath: "out/BuybackVault.sol/BuybackVault.json",
    outputFile: "buybackVault.ts",
    exportName: "buybackVaultAbi",
  },
  {
    artifactPath: "out/BuybackVaultFactory.sol/BuybackVaultFactory.json",
    outputFile: "buybackVaultFactory.ts",
    exportName: "buybackVaultFactoryAbi",
  },
  {
    artifactPath: "out/TaxProcessor.sol/TaxProcessor.json",
    outputFile: "taxProcessor.ts",
    exportName: "taxProcessorAbi",
  },
] as const;

const DEPLOYMENT_ADDRESS_FIELDS = [
  "flapTaxTokenImplementation",
  "tokenFactory",
  "presaleImplementation",
  "presaleFactory",
  "coordinatorFactory",
] as const;

const OPTIONAL_DEPLOYMENT_ADDRESS_FIELDS = ["buybackVaultImplementation", "buybackVaultFactory"] as const;

type DeploymentAddressField = (typeof DEPLOYMENT_ADDRESS_FIELDS)[number];
type OptionalDeploymentAddressField = (typeof OPTIONAL_DEPLOYMENT_ADDRESS_FIELDS)[number];

type Deployment = {
  chainId: number;
} & Record<DeploymentAddressField, string> &
  Partial<Record<OptionalDeploymentAddressField, string>>;

function fail(message: string): never {
  throw new Error(`[contracts-sdk] ${message}`);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

async function readJson(path: string, label: string): Promise<unknown> {
  let source: string;
  try {
    source = await readFile(path, "utf8");
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    return fail(`${label} could not be read at ${path}: ${reason}`);
  }

  try {
    return JSON.parse(source) as unknown;
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    return fail(`${label} is not valid JSON at ${path}: ${reason}`);
  }
}

async function readAbis(): Promise<Array<{ outputFile: string; source: string }>> {
  const outputs: Array<{ outputFile: string; source: string }> = [];
  for (const contract of ABI_CONTRACTS) {
    const artifactPath = resolve(repositoryRoot, contract.artifactPath);
    const artifact = await readJson(artifactPath, `${contract.exportName} artifact`);
    if (!isRecord(artifact) || !Array.isArray(artifact.abi)) {
      fail(`Foundry artifact ${artifactPath} does not contain an ABI array; run forge build first`);
    }

    outputs.push({
      outputFile: contract.outputFile,
      source: `${GENERATED_HEADER}export const ${contract.exportName} = ${JSON.stringify(
        artifact.abi,
        null,
        2,
      )} as const;\n`,
    });
  }
  return outputs;
}

function parseDeployment(value: unknown, path: string, expectedChainId: number): Deployment {
  if (!isRecord(value)) fail(`deployment file ${path} must contain a JSON object`);

  const chainId = value.chainId;
  if (typeof chainId !== "number" || !Number.isSafeInteger(chainId) || chainId <= 0) {
    fail(`deployment file ${path} has an invalid numeric chainId`);
  }
  if (chainId !== expectedChainId) {
    fail(`deployment file ${path} declares chainId ${chainId}, expected ${expectedChainId} from its filename`);
  }

  const deployment = { chainId } as Deployment;
  for (const field of DEPLOYMENT_ADDRESS_FIELDS) {
    const address = value[field];
    if (typeof address !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(address)) {
      fail(`deployment file ${path} has an invalid EVM address in ${field}`);
    }
    if (/^0x0{40}$/.test(address)) {
      fail(`deployment file ${path} uses the zero address in ${field}`);
    }
    deployment[field] = address;
  }

  for (const field of OPTIONAL_DEPLOYMENT_ADDRESS_FIELDS) {
    const address = value[field];
    if (address === undefined) continue;
    if (typeof address !== "string" || !/^0x[0-9a-fA-F]{40}$/.test(address)) {
      fail(`deployment file ${path} has an invalid EVM address in ${field}`);
    }
    if (/^0x0{40}$/.test(address)) {
      fail(`deployment file ${path} uses the zero address in ${field}`);
    }
    deployment[field] = address;
  }

  return deployment;
}

async function readDeployments(): Promise<Deployment[]> {
  let entries: string[];
  try {
    entries = await readdir(deploymentsRoot);
  } catch (error) {
    const reason = error instanceof Error ? error.message : String(error);
    return fail(`deployment directory could not be read at ${deploymentsRoot}: ${reason}`);
  }

  const files = entries.filter((entry) => entry.endsWith(".json")).sort((a, b) => a.localeCompare(b));
  if (files.length === 0) fail(`no deployment JSON files found in ${deploymentsRoot}`);

  const deployments: Deployment[] = [];
  for (const file of files) {
    const match = /^(\d+)\.json$/.exec(file);
    if (match === null || match[1] === undefined) {
      fail(`deployment filename ${file} must use the <chainId>.json format`);
    }
    const expectedChainId = Number(match[1]);
    if (!Number.isSafeInteger(expectedChainId) || expectedChainId <= 0) {
      fail(`deployment filename ${file} contains an invalid chain ID`);
    }
    if (file !== `${expectedChainId}.json`) {
      fail(`deployment filename ${file} is not canonical; use ${expectedChainId}.json`);
    }

    const path = resolve(deploymentsRoot, file);
    deployments.push(parseDeployment(await readJson(path, "deployment"), path, expectedChainId));
  }

  return deployments.sort((a, b) => a.chainId - b.chainId);
}

function renderAddresses(deployments: readonly Deployment[]): string {
  const rows = deployments.map((deployment) => {
    const required = DEPLOYMENT_ADDRESS_FIELDS.map(
      (field) => `    ${field}: ${JSON.stringify(deployment[field])},`,
    );
    const optional = OPTIONAL_DEPLOYMENT_ADDRESS_FIELDS.flatMap((field) => {
      const address = deployment[field];
      return address === undefined ? [] : [`    ${field}: ${JSON.stringify(address)},`];
    });
    return `  ${deployment.chainId}: {
${[...required, ...optional].join("\n")}
  },`;
  });

  return `${GENERATED_HEADER}export const addresses = {
${rows.join("\n")}
} as const;

export type SupportedChainId = keyof typeof addresses;
export type DeploymentAddresses = (typeof addresses)[SupportedChainId];
`;
}

function renderContracts(deployments: readonly Deployment[]): string {
  const rows = deployments.map(
    (deployment) => `  ${deployment.chainId}: {
    coordinatorFactory: {
      address: ${JSON.stringify(deployment.coordinatorFactory)},
      abi: coordinatorFactoryAbi,
    },
    tokenFactory: {
      address: ${JSON.stringify(deployment.tokenFactory)},
      abi: tokenFactoryAbi,
    },
    presaleFactory: {
      address: ${JSON.stringify(deployment.presaleFactory)},
      abi: presaleFactoryAbi,
    },${
      deployment.buybackVaultFactory === undefined
        ? ""
        : `
    buybackVaultFactory: {
      address: ${JSON.stringify(deployment.buybackVaultFactory)},
      abi: buybackVaultFactoryAbi,
    },`
    }
  },`,
  );

  return `${GENERATED_HEADER}import { buybackVaultFactoryAbi } from "./abis/buybackVaultFactory.js";
import { coordinatorFactoryAbi } from "./abis/coordinatorFactory.js";
import { presaleFactoryAbi } from "./abis/presaleFactory.js";
import { tokenFactoryAbi } from "./abis/tokenFactory.js";

export const contracts = {
${rows.join("\n")}
} as const;
`;
}

async function main(): Promise<void> {
  const [abis, deployments] = await Promise.all([readAbis(), readDeployments()]);
  await rm(generatedRoot, { recursive: true, force: true });
  await mkdir(abiOutputRoot, { recursive: true });
  await Promise.all([
    ...abis.map((abi) => writeFile(resolve(abiOutputRoot, abi.outputFile), abi.source, "utf8")),
    writeFile(resolve(generatedRoot, "addresses.ts"), renderAddresses(deployments), "utf8"),
    writeFile(resolve(generatedRoot, "contracts.ts"), renderContracts(deployments), "utf8"),
  ]);
  console.log(`Generated ${ABI_CONTRACTS.length} ABIs and ${deployments.length} chain deployments.`);
}

await main();
