# Routr (ROUTR)

A fixed-supply ERC-20 token for a custom token launch on Ethereum mainnet (chain id 1).

| Property        | Value                                                   |
| --------------- | ------------------------------------------------------- |
| Contract        | `RoutrToken` (`src/RoutrToken.sol`)                     |
| `name()`        | `Routr`                                                 |
| `symbol()`      | `ROUTR`                                                 |
| `decimals()`    | `18`                                                    |
| `totalSupply()` | `1000000000000000000000000000` (1,000,000,000 × 10^18)  |
| Constructor     | no arguments                                            |

## Behaviour

- The constructor mints the whole supply once, to `msg.sender` (the deployer). For the launch, that's
  IMD's `ProjectFactory`, which then pays the supply out.
- Nothing can mint after that. There are no `mint`, `burn`, `pause`, `blacklist`, `freeze` or
  `upgrade` functions. There is no owner and no fee or tax on transfers. Only a holder, or a spender
  the holder approved, can move a balance.
- The token is a standard OpenZeppelin v5.1.0 `ERC20`, vendored under `lib/openzeppelin-contracts`.
  It has no hooks and no overrides. Every transfer delivers exactly the amount sent, so the launch
  flows (factory → MerkleDistributor, distributor → claimants, factory → Uniswap v4 PoolManager, and
  swaps through the PoolManager) need no exemptions.
- The contract has no `receive`/`fallback`, so it rejects ETH.

## Assumptions

- "Deployer" in the brief means the account that runs the constructor. In the launch, that's the
  factory, which hands out the supply under the launch economics:
  - 10% to the swarm's MerkleDistributor;
  - `poolBps` 8000 (80%) seeds the native-ETH pool. The pool's fee is 12500 and its tick spacing 60.
  - the other 10% goes to `0x6bf192ebef135e0f645e99d59d9bf44e7711606c`.

  The token contract doesn't encode any of this. It only mints to its deployer.
- The brief asks for no admin powers, so the token has none. No value is left open that the
  requester has to set later.

## Deployment parameters

- Compiler: solc `0.8.26`, optimizer on (200 runs), `evm_version = "cancun"`,
  `bytecode_hash = "none"` (all set in `foundry.toml`).
- Constructor arguments: none.
- Launch manifest values: `token.contract = "RoutrToken"`, `name = "Routr"`, `symbol = "ROUTR"`,
  `decimals = 18`, `totalSupply = "1000000000000000000000000000"`, `constructorArgs = []`, no
  application contracts. A separate manifest step writes `launch.json`. This repository
  deliberately doesn't contain one.
- `script/DeployRoutr.s.sol` is a reviewable reference deployment. The production deployment is
  IMD's, through the factory. Nothing in this repository holds keys or broadcasts transactions.

## After launch

There's nothing to configure: the token has no settings and no owner.

## Operational responsibilities

- Nobody administers the token after deployment, and nobody can recover it. Tokens sent to the
  wrong address, including the token contract itself, can't be retrieved.
- Getting liquidity, distributions and remainder transfers right is the job of the launch factory
  and its operator (IMD), not of this contract.
- Verifying the source on a block explorer (for example with `forge verify-contract`) after
  deployment is an open item for the deployer.

## Development

```sh
forge build
forge test
forge fmt --check
```

The dependencies (forge-std v1.9.7 and OpenZeppelin Contracts v5.1.0) are vendored as plain files
under `lib/`, so building needs no network access.

The tests cover:
- metadata;
- the single constructor mint to the deployer;
- transfers and `transferFrom`/allowances;
- failure paths: insufficient balance, insufficient allowance, zero receiver, zero spender, ETH sent
  to the token;
- the absence of mint and admin entry points;
- fuzz tests, plus an invariant test that the supply stays fixed and balances sum to it.

Tests that pass are not a security audit. The contract is unmodified OpenZeppelin `ERC20` with a
constructor mint.
