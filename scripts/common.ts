import { readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import anchor, { type Idl } from "@coral-xyz/anchor";
import { Connection, Keypair, PublicKey } from "@solana/web3.js";

const { AnchorProvider, Program, Wallet } = anchor;
export const BN = anchor.BN;
export type BN = InstanceType<typeof anchor.BN>;

export const USDC = 1_000_000;
export const TOKEN = 100_000_000;

/** Launch tiers, in USDC. Values match the published tier table. */
export const TIERS = {
  A: { halfSpread: 10, maxSkew: 15, band: 2_000, oracleBand: 75, clip: 50_000 },
  B: { halfSpread: 20, maxSkew: 25, band: 2_000, oracleBand: 150, clip: 20_000 },
  C: { halfSpread: 40, maxSkew: 50, band: 2_000, oracleBand: 300, clip: 5_000 },
} as const;

/** Mock devnet listings. These mints stand in for real issuer tokens. */
export const LISTINGS = [
  { symbol: "NVDAx", tier: "A", mid: 177.4 },
  { symbol: "SPYx", tier: "A", mid: 643.56 },
  { symbol: "AAPLx", tier: "A", mid: 229.65 },
  { symbol: "TSLAx", tier: "B", mid: 345.57 },
  { symbol: "PLTRx", tier: "C", mid: 146.61 },
] as const;

export interface Deployment {
  cluster: string;
  admin: string;
  usdcMint: string;
  treasuryUsdc: string;
  programs: Record<string, string>;
  markets: Record<string, { mint: string; market: string; feed: string; tier: string; mid: number }>;
}

const here = join(import.meta.dirname, "..");
export const deploymentPath = (cluster: string) => join(here, "deployments", `${cluster}.json`);

export function loadDeployment(cluster: string): Deployment {
  const path = deploymentPath(cluster);
  if (!existsSync(path)) throw new Error(`No deployment record at ${path}. Run the bootstrap first.`);
  return JSON.parse(readFileSync(path, "utf8"));
}

export function clusterName(url: string) {
  if (url.includes("devnet")) return "devnet";
  if (url.includes("127.0.0.1") || url.includes("localhost")) return "localnet";
  throw new Error(`Refusing to run against ${url}. These scripts are for devnet and localnet only.`);
}

export function connect() {
  const url = process.env.ARCTER_RPC_URL ?? "https://api.devnet.solana.com";
  const path = (process.env.ANCHOR_WALLET ?? "~/.config/solana/arcter-devnet.json").replace("~", homedir());
  const payer = Keypair.fromSecretKey(Uint8Array.from(JSON.parse(readFileSync(path, "utf8"))));
  const connection = new Connection(url, "confirmed");
  const provider = new AnchorProvider(connection, new Wallet(payer), { commitment: "confirmed" });
  const program = (name: string) => {
    const idl = JSON.parse(readFileSync(join(here, "target", "idl", `arcter_${name}.json`), "utf8")) as Idl;
    return new Program(idl, provider);
  };
  return {
    cluster: clusterName(url),
    connection,
    provider,
    payer,
    config: program("config"),
    access: program("access"),
    oracle: program("oracle"),
    vault: program("vault"),
    rfq: program("rfq"),
    router: program("router"),
  };
}

const seed = (text: string) => Buffer.from(text);

export const pdas = (ids: { config: PublicKey; access: PublicKey; oracle: PublicKey; vault: PublicKey; router: PublicKey }) => {
  const find = (program: PublicKey, ...seeds: Buffer[]) => PublicKey.findProgramAddressSync(seeds, program)[0];
  return {
    config: find(ids.config, seed("config")),
    treasury: find(ids.config, seed("treasury")),
    routerAuthority: find(ids.router, seed("router")),
    issuer: (key: PublicKey) => find(ids.access, seed("issuer"), key.toBuffer()),
    attestation: (wallet: PublicKey) => find(ids.access, seed("attestation"), wallet.toBuffer()),
    feed: (mint: PublicKey) => find(ids.oracle, seed("feed"), mint.toBuffer()),
    market: (mint: PublicKey) => find(ids.vault, seed("market"), mint.toBuffer()),
    reserve: (market: PublicKey, mint: PublicKey) => find(ids.vault, seed("reserve"), market.toBuffer(), mint.toBuffer()),
    shares: (market: PublicKey) => find(ids.vault, seed("shares"), market.toBuffer()),
  };
};

/** US equity session for the current moment, in New York time. Ignores holidays. */
export function currentSession(now = new Date()): { regular: object } | { extended: object } | { closed: object } {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone: "America/New_York",
    weekday: "short",
    hour: "numeric",
    minute: "numeric",
    hour12: false,
  }).formatToParts(now);
  const part = (type: string) => parts.find((p) => p.type === type)?.value ?? "";
  const minutes = (Number(part("hour")) % 24) * 60 + Number(part("minute"));
  if (part("weekday") === "Sat" || part("weekday") === "Sun") return { closed: {} };
  if (minutes >= 570 && minutes < 960) return { regular: {} };
  if (minutes >= 240 && minutes < 1200) return { extended: {} };
  return { closed: {} };
}

/** Publishes a price dated slightly in the past, so it is never ahead of the cluster clock. */
export const observedAt = () => new BN(Math.floor(Date.now() / 1000) - 15);

export const usdcUnits = (price: number) => new BN(Math.round(price * USDC));
