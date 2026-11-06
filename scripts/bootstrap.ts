/**
 * Sets up a freshly deployed cluster: mock mints, settings, feeds, markets and
 * seed liquidity. Run it straight after deploying, because whoever first calls
 * initialize becomes the admin. Safe to run only once per deployment.
 */
import { writeFileSync } from "node:fs";
import { SystemProgram } from "@solana/web3.js";
import {
  TOKEN_2022_PROGRAM_ID,
  TOKEN_PROGRAM_ID,
  createAccount,
  createMint,
  getOrCreateAssociatedTokenAccount,
  mintTo,
} from "@solana/spl-token";
import { BN, LISTINGS, TIERS, TOKEN, USDC, connect, currentSession, deploymentPath, observedAt, pdas, usdcUnits, type Deployment } from "./common";

const ROLE_TRADER = 1;
const ROLE_LP = 2;
const VAULT_DEPOSIT_USDC = 100_000;

const ctx = connect();
const { connection, payer, config, access, oracle, vault, rfq, router, cluster } = ctx;
const admin = payer.publicKey;
const keys = pdas({
  config: config.programId,
  access: access.programId,
  oracle: oracle.programId,
  vault: vault.programId,
  router: router.programId,
});

console.log(`Cluster ${cluster}, admin ${admin.toBase58()}`);

const usdcMint = await createMint(connection, payer, admin, null, 6, undefined, undefined, TOKEN_PROGRAM_ID);
console.log(`Mock USDC mint ${usdcMint.toBase58()}`);

await config.methods
  .initialize({
    guardian: admin,
    routerAuthority: keys.routerAuthority,
    usdcMint,
    swapFeeBps: 2,
    rfqFeeBps: 2,
    spreadShareBps: 1_000,
    timelockDelay: new BN(3_600),
    restartGapSecs: new BN(3_600),
    restartGraceSecs: new BN(3_600),
  })
  .accountsPartial({ admin, config: keys.config, treasury: keys.treasury, systemProgram: SystemProgram.programId })
  .rpc();

const treasuryUsdc = await createAccount(connection, payer, usdcMint, keys.treasury, undefined, undefined, TOKEN_PROGRAM_ID)
  .catch(async () => (await getOrCreateAssociatedTokenAccount(connection, payer, usdcMint, keys.treasury, true)).address);

await access.methods.addIssuer(admin).accountsPartial({ admin, config: keys.config, issuerRecord: keys.issuer(admin) }).rpc();
await access.methods
  .attest(admin, ROLE_TRADER | ROLE_LP, new BN(Math.floor(Date.now() / 1000) + 365 * 86_400))
  .accountsPartial({ issuer: admin, issuerRecord: keys.issuer(admin), attestation: keys.attestation(admin) })
  .rpc();

const adminUsdc = await getOrCreateAssociatedTokenAccount(connection, payer, usdcMint, admin);
await mintTo(connection, payer, usdcMint, adminUsdc.address, admin, 10_000_000 * USDC);

const markets: Deployment["markets"] = {};

for (const listing of LISTINGS) {
  const tier = TIERS[listing.tier];
  const mint = await createMint(connection, payer, admin, null, 8, undefined, undefined, TOKEN_2022_PROGRAM_ID);
  const feed = keys.feed(mint);
  const market = keys.market(mint);

  await oracle.methods
    .createFeed({
      publisher: admin,
      maxAgeRegular: new BN(3_600),
      maxAgeExtended: new BN(7_200),
      maxAgeClosed: new BN(345_600),
      maxDeviationBps: tier.oracleBand,
    })
    .accountsPartial({ admin, config: keys.config, assetMint: mint, feed })
    .rpc();

  await oracle.methods
    .postReport({ price: usdcUnits(listing.mid), observedAt: observedAt(), session: currentSession() as never })
    .accountsPartial({ publisher: admin, config: keys.config, feed })
    .rpc();

  await vault.methods
    .createMarket({
      requiresAttestation: false,
      baseHalfSpreadBps: tier.halfSpread,
      maxSkewBps: tier.maxSkew,
      inventoryBandBps: tier.band,
      oracleBandBps: tier.oracleBand,
      maxClip: new BN(tier.clip * USDC),
      dailyCap: new BN(tier.clip * 20 * USDC),
      tvlCap: new BN(5_000_000 * USDC),
    })
    .accountsPartial({
      admin,
      config: keys.config,
      assetMint: mint,
      usdcMint,
      feed,
      market,
      assetReserve: keys.reserve(market, mint),
      usdcReserve: keys.reserve(market, usdcMint),
      shareMint: keys.shares(market),
      assetTokenProgram: TOKEN_2022_PROGRAM_ID,
      usdcTokenProgram: TOKEN_PROGRAM_ID,
      shareTokenProgram: TOKEN_PROGRAM_ID,
    })
    .rpc();

  // Seed an even split so the vault opens at its inventory target.
  const assetAccount = await getOrCreateAssociatedTokenAccount(connection, payer, mint, admin, false, undefined, undefined, TOKEN_2022_PROGRAM_ID);
  const assetRaw = BigInt(Math.floor((VAULT_DEPOSIT_USDC / listing.mid) * TOKEN));
  await mintTo(connection, payer, mint, assetAccount.address, admin, assetRaw * 2n, [], undefined, TOKEN_2022_PROGRAM_ID);
  const shareAccount = await getOrCreateAssociatedTokenAccount(connection, payer, keys.shares(market), admin);

  await vault.methods
    .deposit(new BN(VAULT_DEPOSIT_USDC * USDC), new BN(assetRaw.toString()), new BN(1))
    .accountsPartial({
      depositor: admin,
      config: keys.config,
      market,
      feed,
      attestation: keys.attestation(admin),
      assetMint: mint,
      usdcMint,
      shareMint: keys.shares(market),
      assetReserve: keys.reserve(market, mint),
      usdcReserve: keys.reserve(market, usdcMint),
      depositorAsset: assetAccount.address,
      depositorUsdc: adminUsdc.address,
      depositorShares: shareAccount.address,
      assetTokenProgram: TOKEN_2022_PROGRAM_ID,
      usdcTokenProgram: TOKEN_PROGRAM_ID,
      shareTokenProgram: TOKEN_PROGRAM_ID,
    })
    .rpc();

  markets[listing.symbol] = { mint: mint.toBase58(), market: market.toBase58(), feed: feed.toBase58(), tier: listing.tier, mid: listing.mid };
  console.log(`Listed ${listing.symbol} ${market.toBase58()}`);
}

const deployment: Deployment = {
  cluster,
  admin: admin.toBase58(),
  usdcMint: usdcMint.toBase58(),
  treasuryUsdc: treasuryUsdc.toBase58(),
  programs: {
    arcter_config: config.programId.toBase58(),
    arcter_access: access.programId.toBase58(),
    arcter_oracle: oracle.programId.toBase58(),
    arcter_vault: vault.programId.toBase58(),
    arcter_rfq: rfq.programId.toBase58(),
    arcter_router: router.programId.toBase58(),
  },
  markets,
};
writeFileSync(deploymentPath(cluster), `${JSON.stringify(deployment, null, 2)}\n`);
console.log(`Saved ${deploymentPath(cluster)}`);
