/** Buys and sells through the router, then prints what the market recorded. */
import { PublicKey } from "@solana/web3.js";
import { TOKEN_2022_PROGRAM_ID, TOKEN_PROGRAM_ID, getAccount, getOrCreateAssociatedTokenAccount } from "@solana/spl-token";
import { BN, USDC, connect, loadDeployment, pdas } from "./common";

const { connection, payer, config, access, oracle, vault, router, cluster } = connect();
const deployment = loadDeployment(cluster);
const symbol = process.argv[2] ?? "NVDAx";
const listing = deployment.markets[symbol];
const keys = pdas({ config: config.programId, access: access.programId, oracle: oracle.programId, vault: vault.programId, router: router.programId });

const mint = new PublicKey(listing.mint);
const usdcMint = new PublicKey(deployment.usdcMint);
const market = new PublicKey(listing.market);
const wallet = payer.publicKey;
const traderUsdc = await getOrCreateAssociatedTokenAccount(connection, payer, usdcMint, wallet);
const traderAsset = await getOrCreateAssociatedTokenAccount(connection, payer, mint, wallet, false, undefined, undefined, TOKEN_2022_PROGRAM_ID);

const accounts = {
  trader: wallet,
  routerAuthority: keys.routerAuthority,
  config: keys.config,
  market,
  attestation: null as never,
  feed: new PublicKey(listing.feed),
  assetMint: mint,
  usdcMint,
  assetReserve: keys.reserve(market, mint),
  usdcReserve: keys.reserve(market, usdcMint),
  traderAsset: traderAsset.address,
  traderUsdc: traderUsdc.address,
  treasuryUsdc: new PublicKey(deployment.treasuryUsdc),
  assetTokenProgram: TOKEN_2022_PROGRAM_ID,
  usdcTokenProgram: TOKEN_PROGRAM_ID,
  vaultProgram: vault.programId,
};
const expiry = () => new BN(Math.floor(Date.now() / 1000) + 60);
const assetBalance = async () => (await getAccount(connection, traderAsset.address, undefined, TOKEN_2022_PROGRAM_ID)).amount;

const before = await assetBalance();
const buy = await router.methods
  .swapExactIn({ buyAsset: true, amountIn: new BN(1_000 * USDC), minAmountOut: new BN(1), expiresAt: expiry() })
  .accountsPartial(accounts)
  .rpc();
const bought = (await assetBalance()) - before;
console.log(`Bought ${bought} raw ${symbol} for 1,000 USDC: ${buy}`);

const sell = await router.methods
  .swapExactIn({ buyAsset: false, amountIn: new BN(bought.toString()), minAmountOut: new BN(1), expiresAt: expiry() })
  .accountsPartial(accounts)
  .rpc();
console.log(`Sold it back: ${sell}`);

const markets = vault.account as unknown as { market: { fetch(key: PublicKey): Promise<{ dayVolume: BN }> } };
const state = await markets.market.fetch(market);
console.log(`Market day volume ${state.dayVolume.toString()} raw USDC`);
