//! Reference prices and session regimes for Arcter.
//!
//! Each listed asset has one Feed. In this build an approved publisher posts the
//! primary price and a cross-check price. A production build would replace those
//! two instructions with verified Chainlink and Pyth reports. Everything after
//! that point, the age limits and the regime rules, stays the same.

use anchor_lang::prelude::*;
use arcter_config::{Config, BPS, CONFIG_SEED};

declare_id!("FDHgEUKWuHe9FeBvcGa8dCa9KcMNpuijEFdbdjsTyGcJ");

pub const FEED_SEED: &[u8] = b"feed";

#[program]
pub mod arcter_oracle {
    use super::*;

    pub fn create_feed(ctx: Context<CreateFeed>, args: CreateFeedArgs) -> Result<()> {
        require!(
            args.max_age_regular > 0
                && args.max_age_extended >= args.max_age_regular
                && args.max_age_closed >= args.max_age_extended
                && args.max_deviation_bps > 0,
            OracleError::InvalidSettings
        );
        ctx.accounts.feed.set_inner(Feed {
            asset_mint: ctx.accounts.asset_mint.key(),
            publisher: args.publisher,
            primary_price: 0,
            primary_observed_at: 0,
            crosscheck_price: 0,
            crosscheck_observed_at: 0,
            session: Session::Closed,
            max_age_regular: args.max_age_regular,
            max_age_extended: args.max_age_extended,
            max_age_closed: args.max_age_closed,
            max_deviation_bps: args.max_deviation_bps,
            paused: false,
            jump_tripped: false,
            last_regime: Regime::Halted,
            bump: ctx.bumps.feed,
        });
        Ok(())
    }

    /// Records a primary price. Timestamps only move forward, so an older
    /// report can never be replayed over a newer one.
    pub fn post_report(ctx: Context<PostReport>, args: ReportArgs) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let max_jump_bps = ctx.accounts.config.max_jump_bps;
        let feed = &mut ctx.accounts.feed;
        require!(args.price > 0, OracleError::InvalidPrice);
        require!(
            args.observed_at > feed.primary_observed_at,
            OracleError::OutOfOrder
        );
        require!(args.observed_at <= now, OracleError::FutureReport);

        if feed.primary_price > 0
            && deviation_bps(feed.primary_price, args.price) > u128::from(max_jump_bps)
        {
            feed.jump_tripped = true;
            emit!(JumpTripped {
                asset_mint: feed.asset_mint,
                previous: feed.primary_price,
                reported: args.price,
            });
        }
        feed.primary_price = args.price;
        feed.primary_observed_at = args.observed_at;
        feed.session = args.session;
        Ok(())
    }

    pub fn post_crosscheck(ctx: Context<PostReport>, price: u64, observed_at: i64) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let feed = &mut ctx.accounts.feed;
        require!(price > 0, OracleError::InvalidPrice);
        require!(
            observed_at > feed.crosscheck_observed_at,
            OracleError::OutOfOrder
        );
        require!(observed_at <= now, OracleError::FutureReport);
        feed.crosscheck_price = price;
        feed.crosscheck_observed_at = observed_at;
        Ok(())
    }

    /// Open to any caller. Trades derive the regime themselves, so this call
    /// only keeps the stored value and the public event stream current.
    pub fn sync_regime(ctx: Context<SyncRegime>) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let regime = ctx.accounts.feed.regime(&ctx.accounts.config, now);
        let feed = &mut ctx.accounts.feed;
        if feed.last_regime != regime {
            emit!(RegimeChanged {
                asset_mint: feed.asset_mint,
                from: feed.last_regime,
                to: regime,
            });
            feed.last_regime = regime;
        }
        Ok(())
    }

    /// Issuer pauses and corporate actions land here. The guardian may halt a
    /// feed, and only the admin may restart it.
    pub fn set_feed_paused(ctx: Context<AdminFeed>, paused: bool) -> Result<()> {
        let config = &ctx.accounts.config;
        let signer = ctx.accounts.authority.key();
        if paused {
            require!(
                signer == config.guardian || signer == config.admin,
                OracleError::Unauthorized
            );
        } else {
            require_keys_eq!(signer, config.admin, OracleError::Unauthorized);
        }
        ctx.accounts.feed.paused = paused;
        Ok(())
    }

    /// Clears the 25% jump guard once the move has been reviewed.
    pub fn clear_jump(ctx: Context<AdminFeed>) -> Result<()> {
        require_keys_eq!(
            ctx.accounts.authority.key(),
            ctx.accounts.config.admin,
            OracleError::Unauthorized
        );
        ctx.accounts.feed.jump_tripped = false;
        Ok(())
    }
}

/// Session of the underlying market, as reported with each price.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug, PartialEq, Eq, InitSpace)]
pub enum Session {
    Regular,
    Extended,
    Closed,
}

/// Pricing state of a market.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug, PartialEq, Eq, InitSpace)]
pub enum Regime {
    Open,
    Extended,
    Closed,
    Halted,
}

#[account]
#[derive(InitSpace)]
pub struct Feed {
    pub asset_mint: Pubkey,
    pub publisher: Pubkey,
    /// USDC raw units for one whole scaled token.
    pub primary_price: u64,
    pub primary_observed_at: i64,
    pub crosscheck_price: u64,
    pub crosscheck_observed_at: i64,
    pub session: Session,
    pub max_age_regular: i64,
    pub max_age_extended: i64,
    pub max_age_closed: i64,
    pub max_deviation_bps: u16,
    pub paused: bool,
    pub jump_tripped: bool,
    pub last_regime: Regime,
    pub bump: u8,
}

impl Feed {
    fn max_age(&self) -> i64 {
        match self.session {
            Session::Regular => self.max_age_regular,
            Session::Extended => self.max_age_extended,
            Session::Closed => self.max_age_closed,
        }
    }

    /// Derives the live regime. Every input can only tighten the outcome: a
    /// fresh price cannot overrule a halt raised by any other check.
    pub fn regime(&self, config: &Config, now: i64) -> Regime {
        let max_age = self.max_age();
        let stale = self.primary_price == 0
            || now.saturating_sub(self.primary_observed_at) > max_age;
        let crosscheck_is_fresh = self.crosscheck_price > 0
            && now.saturating_sub(self.crosscheck_observed_at) <= max_age;
        let sources_disagree = crosscheck_is_fresh
            && deviation_bps(self.primary_price, self.crosscheck_price)
                > u128::from(self.max_deviation_bps);

        if config.paused
            || self.paused
            || self.jump_tripped
            || stale
            || sources_disagree
            || config.restart_hold_active(now)
        {
            return Regime::Halted;
        }
        match self.session {
            Session::Regular => Regime::Open,
            Session::Extended => Regime::Extended,
            Session::Closed => Regime::Closed,
        }
    }
}

/// Distance between two positive prices, in basis points of the first.
pub fn deviation_bps(reference: u64, other: u64) -> u128 {
    if reference == 0 {
        return u128::MAX;
    }
    let difference = u128::from(reference.abs_diff(other));
    difference * u128::from(BPS) / u128::from(reference)
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct CreateFeedArgs {
    pub publisher: Pubkey,
    pub max_age_regular: i64,
    pub max_age_extended: i64,
    pub max_age_closed: i64,
    pub max_deviation_bps: u16,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct ReportArgs {
    pub price: u64,
    pub observed_at: i64,
    pub session: Session,
}

#[derive(Accounts)]
pub struct CreateFeed<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        seeds::program = arcter_config::ID,
        has_one = admin @ OracleError::Unauthorized
    )]
    pub config: Account<'info, Config>,
    /// CHECK: Used only as a seed. The vault validates the mint at listing.
    pub asset_mint: UncheckedAccount<'info>,
    #[account(
        init,
        payer = admin,
        space = 8 + Feed::INIT_SPACE,
        seeds = [FEED_SEED, asset_mint.key().as_ref()],
        bump
    )]
    pub feed: Account<'info, Feed>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct PostReport<'info> {
    pub publisher: Signer<'info>,
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        seeds::program = arcter_config::ID
    )]
    pub config: Account<'info, Config>,
    #[account(
        mut,
        seeds = [FEED_SEED, feed.asset_mint.as_ref()],
        bump = feed.bump,
        has_one = publisher @ OracleError::Unauthorized
    )]
    pub feed: Account<'info, Feed>,
}

#[derive(Accounts)]
pub struct SyncRegime<'info> {
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        seeds::program = arcter_config::ID
    )]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [FEED_SEED, feed.asset_mint.as_ref()], bump = feed.bump)]
    pub feed: Account<'info, Feed>,
}

#[derive(Accounts)]
pub struct AdminFeed<'info> {
    pub authority: Signer<'info>,
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        seeds::program = arcter_config::ID
    )]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [FEED_SEED, feed.asset_mint.as_ref()], bump = feed.bump)]
    pub feed: Account<'info, Feed>,
}

#[event]
pub struct RegimeChanged {
    pub asset_mint: Pubkey,
    pub from: Regime,
    pub to: Regime,
}

#[event]
pub struct JumpTripped {
    pub asset_mint: Pubkey,
    pub previous: u64,
    pub reported: u64,
}

#[error_code]
pub enum OracleError {
    #[msg("The signer does not hold the required role")]
    Unauthorized,
    #[msg("The feed settings are inconsistent")]
    InvalidSettings,
    #[msg("The price must be above zero")]
    InvalidPrice,
    #[msg("This report is not newer than the stored one")]
    OutOfOrder,
    #[msg("This report is dated in the future")]
    FutureReport,
}
