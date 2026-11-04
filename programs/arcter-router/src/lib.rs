//! Trading entry point for Arcter.
//!
//! Every fill passes through here. The router checks expiry, the global pause
//! and market access, then hands over to the vault or the maker lane by signing
//! as its own PDA, the one caller those programs accept.
//!
//! A trade between two assets is two `swap_exact_in` calls in one transaction,
//! through USDC. Solana runs them atomically, so if the second leg misses its
//! minimum the first leg unwinds as well.

use anchor_lang::prelude::*;
use arcter_access::{Attestation, ATTESTATION_SEED, ROLE_TRADER};
use arcter_config::{Config, CONFIG_SEED};
use arcter_rfq::{cpi::accounts::SettleQuote, MakerQuote};
use arcter_vault::{cpi::accounts::Fill, FillArgs, Market, MARKET_SEED};

declare_id!("4k5xDqZX8ry422znZoafGrA5WQVW5R9pJ4hYooU1ESXH");

pub const ROUTER_SEED: &[u8] = b"router";

#[program]
pub mod arcter_router {
    use super::*;

    /// Fills against the vault.
    pub fn swap_exact_in(ctx: Context<SwapExactIn>, args: SwapArgs) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let accounts = &ctx.accounts;
        require!(!accounts.config.paused, RouterError::TradingPaused);
        require!(now <= args.expires_at, RouterError::Expired);
        check_access(
            &accounts.market,
            accounts.attestation.as_deref(),
            &accounts.trader.key(),
            now,
        )?;

        let seeds: &[&[u8]] = &[ROUTER_SEED, &[ctx.bumps.router_authority]];
        let signer: &[&[&[u8]]] = &[seeds];
        let filled = arcter_vault::cpi::fill(
            CpiContext::new_with_signer(
                accounts.vault_program.to_account_info(),
                Fill {
                    router_authority: accounts.router_authority.to_account_info(),
                    trader: accounts.trader.to_account_info(),
                    config: accounts.config.to_account_info(),
                    market: accounts.market.to_account_info(),
                    feed: accounts.feed.to_account_info(),
                    asset_mint: accounts.asset_mint.to_account_info(),
                    usdc_mint: accounts.usdc_mint.to_account_info(),
                    asset_reserve: accounts.asset_reserve.to_account_info(),
                    usdc_reserve: accounts.usdc_reserve.to_account_info(),
                    trader_asset: accounts.trader_asset.to_account_info(),
                    trader_usdc: accounts.trader_usdc.to_account_info(),
                    treasury_usdc: accounts.treasury_usdc.to_account_info(),
                    asset_token_program: accounts.asset_token_program.to_account_info(),
                    usdc_token_program: accounts.usdc_token_program.to_account_info(),
                },
                signer,
            ),
            FillArgs {
                buy_asset: args.buy_asset,
                amount_in: args.amount_in,
                min_amount_out: args.min_amount_out,
            },
        )?
        .get();

        emit!(SwapSettled {
            trader: accounts.trader.key(),
            market: accounts.market.key(),
            buy_asset: args.buy_asset,
            amount_in: args.amount_in,
            amount_out: filled,
            lane: Lane::Vault,
        });
        Ok(())
    }

    /// Settles a signed maker quote. The transaction must carry the matching
    /// Ed25519 instruction directly before this one.
    pub fn swap_with_quote(ctx: Context<SwapWithQuote>, quote: MakerQuote) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let accounts = &ctx.accounts;
        require!(!accounts.config.paused, RouterError::TradingPaused);
        check_access(
            &accounts.market,
            accounts.attestation.as_deref(),
            &accounts.taker.key(),
            now,
        )?;

        let seeds: &[&[u8]] = &[ROUTER_SEED, &[ctx.bumps.router_authority]];
        arcter_rfq::cpi::settle_quote(
            CpiContext::new_with_signer(
                accounts.rfq_program.to_account_info(),
                SettleQuote {
                    router_authority: accounts.router_authority.to_account_info(),
                    taker: accounts.taker.to_account_info(),
                    config: accounts.config.to_account_info(),
                    market: accounts.market.to_account_info(),
                    feed: accounts.feed.to_account_info(),
                    maker: accounts.maker.to_account_info(),
                    maker_attestation: accounts.maker_attestation.to_account_info(),
                    record: accounts.record.to_account_info(),
                    asset_mint: accounts.asset_mint.to_account_info(),
                    usdc_mint: accounts.usdc_mint.to_account_info(),
                    inventory_asset: accounts.inventory_asset.to_account_info(),
                    inventory_usdc: accounts.inventory_usdc.to_account_info(),
                    taker_asset: accounts.taker_asset.to_account_info(),
                    taker_usdc: accounts.taker_usdc.to_account_info(),
                    treasury_usdc: accounts.treasury_usdc.to_account_info(),
                    asset_token_program: accounts.asset_token_program.to_account_info(),
                    usdc_token_program: accounts.usdc_token_program.to_account_info(),
                    instructions: accounts.instructions.to_account_info(),
                    system_program: accounts.system_program.to_account_info(),
                },
                &[seeds],
            ),
            quote,
        )?;

        let (amount_in, amount_out) = if quote.buy_asset {
            (quote.usdc_amount, quote.asset_amount)
        } else {
            (quote.asset_amount, quote.usdc_amount)
        };
        emit!(SwapSettled {
            trader: accounts.taker.key(),
            market: accounts.market.key(),
            buy_asset: quote.buy_asset,
            amount_in,
            amount_out,
            lane: Lane::Maker,
        });
        Ok(())
    }
}

/// Permissioned markets need a live `TRADER` attestation for the signing wallet.
fn check_access(
    market: &Market,
    attestation: Option<&Account<Attestation>>,
    wallet: &Pubkey,
    now: i64,
) -> Result<()> {
    if !market.requires_attestation {
        return Ok(());
    }
    let attestation = attestation.ok_or(RouterError::NotAttested)?;
    let (expected, _) = Pubkey::find_program_address(
        &[ATTESTATION_SEED, wallet.as_ref()],
        &arcter_access::ID,
    );
    require_keys_eq!(attestation.key(), expected, RouterError::NotAttested);
    require!(
        attestation.permits(ROLE_TRADER, now),
        RouterError::NotAttested
    );
    Ok(())
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug)]
pub struct SwapArgs {
    /// True to pay USDC for the asset, false to sell the asset for USDC.
    pub buy_asset: bool,
    pub amount_in: u64,
    pub min_amount_out: u64,
    pub expires_at: i64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub enum Lane {
    Vault,
    Maker,
}

#[derive(Accounts)]
pub struct SwapExactIn<'info> {
    pub trader: Signer<'info>,
    /// CHECK: Signing PDA with no data, fixed by its seeds.
    #[account(seeds = [ROUTER_SEED], bump)]
    pub router_authority: UncheckedAccount<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump, seeds::program = arcter_config::ID)]
    pub config: Box<Account<'info, Config>>,
    #[account(
        mut,
        seeds = [MARKET_SEED, market.asset_mint.as_ref()],
        bump = market.bump,
        seeds::program = arcter_vault::ID
    )]
    pub market: Box<Account<'info, Market>>,
    pub attestation: Option<Box<Account<'info, Attestation>>>,
    /// CHECK: Validated by arcter-vault against the market.
    pub feed: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-vault against the market.
    pub asset_mint: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-vault against the market.
    pub usdc_mint: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-vault against the market.
    #[account(mut)]
    pub asset_reserve: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-vault against the market.
    #[account(mut)]
    pub usdc_reserve: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-vault, which requires the trader as authority.
    #[account(mut)]
    pub trader_asset: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-vault, which requires the trader as authority.
    #[account(mut)]
    pub trader_usdc: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-vault against the Config treasury.
    #[account(mut)]
    pub treasury_usdc: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-vault as a token program.
    pub asset_token_program: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-vault as a token program.
    pub usdc_token_program: UncheckedAccount<'info>,
    pub vault_program: Program<'info, arcter_vault::program::ArcterVault>,
}

#[derive(Accounts)]
pub struct SwapWithQuote<'info> {
    #[account(mut)]
    pub taker: Signer<'info>,
    /// CHECK: Signing PDA with no data, fixed by its seeds.
    #[account(seeds = [ROUTER_SEED], bump)]
    pub router_authority: UncheckedAccount<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump, seeds::program = arcter_config::ID)]
    pub config: Box<Account<'info, Config>>,
    #[account(
        seeds = [MARKET_SEED, market.asset_mint.as_ref()],
        bump = market.bump,
        seeds::program = arcter_vault::ID
    )]
    pub market: Box<Account<'info, Market>>,
    pub attestation: Option<Box<Account<'info, Attestation>>>,
    /// CHECK: Validated by arcter-rfq against the market.
    pub feed: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-rfq.
    pub maker: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-rfq.
    pub maker_attestation: UncheckedAccount<'info>,
    /// CHECK: Created by arcter-rfq, and its seeds block replays.
    #[account(mut)]
    pub record: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-rfq against the market.
    pub asset_mint: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-rfq against the market.
    pub usdc_mint: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-rfq through its seeds.
    #[account(mut)]
    pub inventory_asset: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-rfq through its seeds.
    #[account(mut)]
    pub inventory_usdc: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-rfq, which requires the taker as authority.
    #[account(mut)]
    pub taker_asset: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-rfq, which requires the taker as authority.
    #[account(mut)]
    pub taker_usdc: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-rfq against the Config treasury.
    #[account(mut)]
    pub treasury_usdc: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-rfq as a token program.
    pub asset_token_program: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-rfq as a token program.
    pub usdc_token_program: UncheckedAccount<'info>,
    /// CHECK: Validated by arcter-rfq as the instructions sysvar.
    pub instructions: UncheckedAccount<'info>,
    pub rfq_program: Program<'info, arcter_rfq::program::ArcterRfq>,
    pub system_program: Program<'info, System>,
}

#[event]
pub struct SwapSettled {
    pub trader: Pubkey,
    pub market: Pubkey,
    pub buy_asset: bool,
    pub amount_in: u64,
    pub amount_out: u64,
    pub lane: Lane,
}

#[error_code]
pub enum RouterError {
    #[msg("Trading is paused")]
    TradingPaused,
    #[msg("This order has expired")]
    Expired,
    #[msg("This market needs a valid attestation for the signing wallet")]
    NotAttested,
}
