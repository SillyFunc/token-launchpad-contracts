# Four-channel tax distribution design

## Scope

This design restores the Flap V3 distribution model — market, deflation,
liquidity and dividend — without restoring an unprotected swap inside the
user's buy or sell. `FlapTaxTokenV3` continues to hand tax tokens to a
per-token `TaxProcessor`; a keeper executes bounded swaps later.

The launchpad supports BSC and PancakeSwap V2 only. Dividends are paid in the
quote token (WBNB for current deployments). Custom dividend-token conversion,
SwapRegistry and commission configuration are deliberately out of scope.

## Asset lifecycle

### DEX tax tokens

1. A taxed transfer accumulates tax tokens in `FlapTaxTokenV3`.
2. At the token's liquidation threshold, `processTaxTokens` transfers them to
   `TaxProcessor`. No DEX operation occurs in the user's transaction.
3. The keeper calls `processPendingTax` with a short deadline and a non-zero
   minimum quote output. The selected batch is split after any protocol fee:
   - market: swapped to quote and sent to the immutable market recipient;
   - deflation: sent directly to the dead address;
   - LP: half is retained as tax token and half joins the quote swap;
   - dividend: swapped to quote and deposited into `Dividend`.
4. The actual quote received is assigned proportionally to the nominal inputs
   that entered the swap. Integer dust is assigned to the protocol fee ledger,
   so every quote wei remains accounted.
5. LP token and quote ledgers remain in `TaxProcessor` until the keeper calls
   `addPendingLiquidity`. The processor transfers the token side first,
   measures the pair's actual receipt (including the token's sell tax), derives
   the matching quote amount from reserves, and mints LP directly to the dead
   address. A keeper-supplied quote range and minimum LP output bound the result.

### Dividend funds

`TaxProcessor` approves the exact pending quote amount to the immutable
`Dividend` clone. A successful deposit is measured by processor balance delta.
If there are no eligible shares or the deposit fails before consuming funds,
the quote remains in the pending dividend ledger and can be retried by anyone
through `dispatch()`.

### Bonding-curve compatibility

The local launchpad does not use Flap's Portal bonding curve. The compatibility
entry point nevertheless accounts incoming quote using the same ratios. Its
deflation share is held in a dedicated quote ledger for a keeper-bounded
buyback-and-burn; it is never silently reassigned.

## Trust boundaries

- `CoordinatorFactory` fixes all recipients and basis points at creation.
  Runtime receiver or tax-config setters are intentionally absent.
- `TaxInfrastructureFactory` atomically clones and initializes a processor and,
  when enabled, a dividend contract. Uninitialized public clones are never
  exposed between transactions.
- `TaxInfrastructureFactory` remains the owner of its Dividend clones. Its
  `DEFAULT_ADMIN_ROLE` may configure deferred-share keepers and may use the
  explicit emergency-withdraw path. This is a platform custody trust boundary;
  every such action is visible on chain and the factory cannot redirect normal
  TaxProcessor dispatch.
- Deferred first-receive registration is disabled by default. The current
  keeper does not scan `FlapDividendShareDeferred`, so an administrator must
  not enable a deferred origin until a dedicated share-refresh worker is
  deployed and authorized. The bundled Dividend treats deposits during a
  deferral window as forfeited by that unsynchronized holder, not as funds held
  for later recovery.
- Only an address holding `KEEPER_ROLE` on the Coordinator may execute swaps,
  buyback burns or LP minting. `dispatch()` is permissionless because it cannot
  choose a recipient or perform a price-sensitive swap.
- The keeper must use historical reserve anchors, a protected send endpoint,
  per-run reserve caps, minimum swap output, a quote range for LP and a short
  deadline.
- Those historical anchors are an off-chain control, not an on-chain oracle. A
  compromised keeper cannot redirect proceeds or receive LP, but it can submit
  deliberately weak bounds and execute at an economically bad price. Emergency
  response is immediate `KEEPER_ROLE` revocation; production operation therefore
  also requires a dedicated low-balance signer, private/protected submission and
  alerts on reserve deviation and realized output.
- The Pancake router, canonical pair returned by its factory, WBNB and the
  bundled Dividend implementation are trusted dependencies.

## Failure and callback behaviour

- Swap, burn and LP failures revert the complete keeper transaction; original
  ledgers and balances remain retryable.
- Native BNB delivery that is rejected is rewrapped and delivered as WBNB.
- Dividend failure restores only the unconsumed amount, determined by balance
  delta. Funds already accepted by the trusted Dividend are never double-booked.
- All price-sensitive public functions are `nonReentrant`. Ledger effects are
  recorded before recipient, token, router, pair or Dividend calls.
- Direct WBNB donations are reconciled to the protocol-fee ledger. A negative
  accounting delta reverts as an invariant violation.
- Arbitrary callers can only donate assets or invoke `dispatch()`. They cannot
  choose a receiver, move an LP/deflation ledger, set a price bound or trigger a
  swap, so transaction ordering and flash liquidity do not grant them a direct
  extraction path.

## Invariants

1. Distribution bps always sum to 10,000.
2. `taxToken.balanceOf(processor) >= lpTokenBalance`; the difference is the
   processable tax balance, including fallback transfers from the token.
3. Quote balance is at least the sum of fee, commission, market, dividend, LP
   and bonding-curve burn ledgers.
4. No LP token is minted to the processor, creator, keeper or administrator;
   all newly minted LP is sent to the dead address.
5. A failed external operation cannot change a channel's economic ownership.
6. The tax processor, pool, and presale escrow never receive dividend shares. Tokens held in escrow become eligible only after a holder claims them.

## Known semantic constraint

Because the upstream `FlapTaxTokenV3` has no tax-exemption hook and `src/lib`
is protected, an asynchronous processor transfer into the pool is itself a
taxable sell while tax is active. The swap and LP code therefore use actual
balance deltas, and the keeper quotes the post-tax pool input. The secondary tax
returns to the token and is processed in a later batch; it is delayed, not lost.
Removing this recursive tax would require an explicitly approved change to the
protected token template.
