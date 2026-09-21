#!/usr/bin/env bash
set -euo pipefail

: "${BSCSCAN_API_KEY:?Set BSCSCAN_API_KEY in the shell without committing it}"

deployment_file="${1:-script/deployments/97.json}"
rpc_url="${BSC_TESTNET_RPC_URL:-https://bsc-testnet-rpc.publicnode.com}"

if [[ ! -f "$deployment_file" ]]; then
  echo "Deployment file not found: $deployment_file" >&2
  exit 1
fi

address_for() {
  local key="$1"
  local value
  value="$(jq -er --arg key "$key" '.[$key]' "$deployment_file")"
  if [[ ! "$value" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "Missing or invalid $key in $deployment_file" >&2
    exit 1
  fi
  printf '%s' "$value"
}

verify() {
  local key="$1"
  local contract="$2"
  forge verify-contract \
    --verifier etherscan \
    --chain 97 \
    --rpc-url "$rpc_url" \
    --etherscan-api-key "$BSCSCAN_API_KEY" \
    --guess-constructor-args \
    --watch \
    "$(address_for "$key")" \
    "$contract"
}

verify flapTaxTokenImplementation "src/lib/token/FlapTaxTokenV3.sol:FlapTaxTokenV3"
verify tokenFactory "src/TokenFactory.sol:TokenFactory"
verify presaleImplementation "src/Presale.sol:PRESALE"
verify presaleFactory "src/PresaleFactory.sol:PresaleFactory"
verify coordinatorFactory "src/CoordinatorFactory.sol:CoordinatorFactory"
verify taxProcessorImplementation "src/TaxProcessor.sol:TaxProcessor"
verify dividendImplementation "src/lib/dividend/Dividend.sol:Dividend"
verify taxInfrastructureFactory "src/TaxInfrastructureFactory.sol:TaxInfrastructureFactory"
verify buybackVaultImplementation "src/BuybackVault.sol:BuybackVault"
verify buybackVaultFactory "src/BuybackVaultFactory.sol:BuybackVaultFactory"
