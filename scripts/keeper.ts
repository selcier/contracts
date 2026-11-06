/**
 * Keeps a devnet deployment tradable. Each round sends a heartbeat, publishes a
 * price and cross-check for every market, and syncs the stored regime. Prices
 * follow a small random walk around each listing's sample mid. They are test
 * values, standing in for verified oracle reports.
 */
import { PublicKey } from "@solana/web3.js";
import { connect, currentSession, loadDeployment, observedAt, pdas, usdcUnits } from "./common";

const { config, access, oracle, vault, router, payer, cluster } = connect();
const deployment = loadDeployment(cluster);
const keys = pdas({ config: config.programId, access: access.programId, oracle: oracle.programId, vault: vault.programId, router: router.programId });
const intervalMs = Number(process.env.KEEPER_INTERVAL_SECS ?? 30) * 1000;
const once = process.argv.includes("--once");
const walk = new Map(Object.entries(deployment.markets).map(([symbol, market]) => [symbol, market.mid]));

async function round() {
  await config.methods.heartbeat().accountsPartial({ config: keys.config }).rpc();
  const session = currentSession();
  for (const [symbol, listing] of Object.entries(deployment.markets)) {
    const feed = new PublicKey(listing.feed);
    const price = (walk.get(symbol) ?? listing.mid) * (1 + (Math.random() - 0.5) / 1_000);
    walk.set(symbol, price);
    await oracle.methods
      .postReport({ price: usdcUnits(price), observedAt: observedAt(), session: session as never })
      .accountsPartial({ publisher: payer.publicKey, config: keys.config, feed })
      .rpc();
    await oracle.methods
      .postCrosscheck(usdcUnits(price), observedAt())
      .accountsPartial({ publisher: payer.publicKey, config: keys.config, feed })
      .rpc();
    await oracle.methods.syncRegime().accountsPartial({ config: keys.config, feed }).rpc();
  }
  console.log(`${new Date().toISOString()} round complete, session ${Object.keys(session)[0]}`);
}

do {
  try {
    await round();
  } catch (error) {
    console.error(`Round failed: ${(error as Error).message}`);
    if (once) process.exit(1);
  }
  if (!once) await new Promise((resolve) => setTimeout(resolve, intervalMs));
} while (!once);
