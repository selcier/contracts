//! Single-asset vaults for Arcter.
//!
//! A market pairs one asset with USDC. The oracle sets the middle of the quote,
//! and reserves only tilt the spread. Depositors hold a plain SPL share mint and
//! can always redeem pro rata, with no oracle read and no permission check.

use anchor_lang::prelude::*;
use anchor_spl::token_2022::spl_token_2022::{
    self,
    extension::{
        non_transferable::NonTransferable, scaled_ui_amount::ScaledUiAmountConfig,
        transfer_fee::TransferFeeConfig, transfer_hook::TransferHook, BaseStateWithExtensions,
        StateWithExtensions,
    },
};
use anchor_spl::token_interface::{
    self, Burn, Mint, MintTo, TokenAccount, TokenInterface, TransferChecked,
};
use arcter_access::{Attestation, ATTESTATION_SEED, ROLE_LP};
use arcter_config::{Config, CONFIG_SEED};
use arcter_oracle::{Feed, Regime, FEED_SEED};

pub mod math;

use math::{asset_value, QuoteFailure, QuoteInputs, Tier};

declare_id!("Gkz6QizHjtNvMVmaTSuTnEfjrM4W83mF15PVq5j1CoY5");

pub const MARKET_SEED: &[u8] = b"market";
pub const RESERVE_SEED: &[u8] = b"reserve";
pub const SHARES_SEED: &[u8] = b"shares";

const SECONDS_PER_DAY: i64 = 86_400;
/// First deposit floor in USDC raw units, which keeps share pricing out of
/// dust territory where rounding could be abused.
pub const MIN_FIRST_DEPOSIT: u128 = 1_000_000;

#[program]
pub mod arcter_vault {
    use super::*;

    pub fn create_market(ctx: Context<CreateMarket>, args: MarketArgs) -> Result<()> {
        args.validate()?;
        require_supported_mint(&ctx.accounts.asset_mint.to_account_info())?;

        ctx.accounts.market.set_inner(Market {
            asset_mint: ctx.accounts.asset_mint.key(),
            usdc_mint: ctx.accounts.usdc_mint.key(),
            feed: ctx.accounts.feed.key(),
            asset_reserve: ctx.accounts.asset_reserve.key(),
            usdc_reserve: ctx.accounts.usdc_reserve.key(),
            share_mint: ctx.accounts.share_mint.key(),
            asset_decimals: ctx.accounts.asset_mint.decimals,
            usdc_decimals: ctx.accounts.usdc_mint.decimals,
            status: MarketStatus::Active,
            requires_attestation: args.requires_attestation,
            base_half_spread_bps: args.base_half_spread_bps,
            max_skew_bps: args.max_skew_bps,
            inventory_band_bps: args.inventory_band_bps,
            oracle_band_bps: args.oracle_band_bps,
            max_clip: args.max_clip,
            daily_cap: args.daily_cap,
            tvl_cap: args.tvl_cap,
            day_index: 0,
            day_volume: 0,
            bump: ctx.bumps.market,
        });
        emit!(MarketCreated {
            market: ctx.accounts.market.key(),
            asset_mint: ctx.accounts.asset_mint.key(),
        });
        Ok(())
    }

    pub fn update_market(ctx: Context<AdminMarket>, args: MarketArgs) -> Result<()> {
        args.validate()?;
        let market = &mut ctx.accounts.market;
        market.requires_attestation = args.requires_attestation;
        market.base_half_spread_bps = args.base_half_spread_bps;
        market.max_skew_bps = args.max_skew_bps;
        market.inventory_band_bps = args.inventory_band_bps;
        market.oracle_band_bps = args.oracle_band_bps;
        market.max_clip = args.max_clip;
        market.daily_cap = args.daily_cap;
        market.tvl_cap = args.tvl_cap;
        Ok(())
    }

    /// Ends trading and deposits for good. Withdrawals carry on.
    pub fn retire_market(ctx: Context<AdminMarket>) -> Result<()> {
        ctx.accounts.market.status = MarketStatus::Retired;
        Ok(())
    }

    /// Accepts USDC, the asset or both, valued at the mid. Needs a live price,
    /// so deposits wait during a halt.
    pub fn deposit(
        ctx: Context<Deposit>,
        usdc_amount: u64,
        asset_amount: u64,
        min_shares: u64,
    ) -> Result<()> {
        require!(
            usdc_amount > 0 || asset_amount > 0,
            VaultError::ZeroAmount
        );
        let accounts = &ctx.accounts;
        let market = &accounts.market;
        let now = Clock::get()?.unix_timestamp;
        require!(
            market.status == MarketStatus::Active,
            VaultError::MarketRetired
        );
        require!(
            accounts.attestation.permits(ROLE_LP, now),
            VaultError::NotAttested
        );
        require!(
            accounts.feed.regime(&accounts.config, now) != Regime::Halted,
            VaultError::MarketHalted
        );

        let mid = accounts.feed.primary_price;
        let multiplier = read_multiplier_e9(&accounts.asset_mint.to_account_info(), now)?;
        let decimals = market.asset_decimals;
        let deposit_value = u128::from(usdc_amount)
            + asset_value(asset_amount, mid, decimals, multiplier).map_err(fail)?;
        let total_value = u128::from(accounts.usdc_reserve.amount)
            + asset_value(accounts.asset_reserve.amount, mid, decimals, multiplier)
                .map_err(fail)?;
        require!(
            total_value + deposit_value <= u128::from(market.tvl_cap),
            VaultError::TvlCapExceeded
        );

        let supply = accounts.share_mint.supply;
        if supply == 0 {
            require!(
                deposit_value >= MIN_FIRST_DEPOSIT,
                VaultError::FirstDepositTooSmall
            );
        }
        let shares = math::shares_for_deposit(deposit_value, supply, total_value).map_err(fail)?;
        require!(shares > 0, VaultError::ZeroShares);
        require!(shares >= min_shares, VaultError::SlippageExceeded);

        if usdc_amount > 0 {
            token_interface::transfer_checked(
                CpiContext::new(
                    accounts.usdc_token_program.to_account_info(),
                    TransferChecked {
                        from: accounts.depositor_usdc.to_account_info(),
                        mint: accounts.usdc_mint.to_account_info(),
                        to: accounts.usdc_reserve.to_account_info(),
                        authority: accounts.depositor.to_account_info(),
                    },
                ),
                usdc_amount,
                market.usdc_decimals,
            )?;
        }
        if asset_amount > 0 {
            token_interface::transfer_checked(
                CpiContext::new(
                    accounts.asset_token_program.to_account_info(),
                    TransferChecked {
                        from: accounts.depositor_asset.to_account_info(),
                        mint: accounts.asset_mint.to_account_info(),
                        to: accounts.asset_reserve.to_account_info(),
                        authority: accounts.depositor.to_account_info(),
                    },
                ),
                asset_amount,
                decimals,
            )?;
        }

        let seeds: &[&[u8]] = &[MARKET_SEED, market.asset_mint.as_ref(), &[market.bump]];
        token_interface::mint_to(
            CpiContext::new_with_signer(
                accounts.share_token_program.to_account_info(),
                MintTo {
                    mint: accounts.share_mint.to_account_info(),
                    to: accounts.depositor_shares.to_account_info(),
                    authority: market.to_account_info(),
                },
                &[seeds],
            ),
            shares,
        )?;

        emit!(Deposited {
            market: market.key(),
            depositor: accounts.depositor.key(),
            usdc_amount,
            asset_amount,
            shares,
        });
        Ok(())
    }

    /// Redeems shares for a pro rata slice of both reserves. Pauses, halts,
    /// expired attestations and retirement do not stop this call.
    pub fn withdraw(
        ctx: Context<Withdraw>,
        shares: u64,
        min_usdc: u64,
        min_asset: u64,
    ) -> Result<()> {
        require!(shares > 0, VaultError::ZeroShares);
        let accounts = &ctx.accounts;
        let market = &accounts.market;
        let supply = accounts.share_mint.supply;
        let usdc_out = math::pro_rata(accounts.usdc_reserve.amount, shares, supply).map_err(fail)?;
        let asset_out =
            math::pro_rata(accounts.asset_reserve.amount, shares, supply).map_err(fail)?;
        require!(
            usdc_out >= min_usdc && asset_out >= min_asset,
            VaultError::SlippageExceeded
        );

        token_interface::burn(
            CpiContext::new(
                accounts.share_token_program.to_account_info(),
                Burn {
                    mint: accounts.share_mint.to_account_info(),
                    from: accounts.depositor_shares.to_account_info(),
                    authority: accounts.depositor.to_account_info(),
                },
            ),
            shares,
        )?;

        let seeds: &[&[u8]] = &[MARKET_SEED, market.asset_mint.as_ref(), &[market.bump]];
        if usdc_out > 0 {
            token_interface::transfer_checked(
                CpiContext::new_with_signer(
                    accounts.usdc_token_program.to_account_info(),
                    TransferChecked {
                        from: accounts.usdc_reserve.to_account_info(),
                        mint: accounts.usdc_mint.to_account_info(),
                        to: accounts.depositor_usdc.to_account_info(),
                        authority: market.to_account_info(),
                    },
                    &[seeds],
                ),
                usdc_out,
                market.usdc_decimals,
            )?;
        }
        if asset_out > 0 {
            token_interface::transfer_checked(
                CpiContext::new_with_signer(
                    accounts.asset_token_program.to_account_info(),
                    TransferChecked {
                        from: accounts.asset_reserve.to_account_info(),
                        mint: accounts.asset_mint.to_account_info(),
                        to: accounts.depositor_asset.to_account_info(),
                        authority: market.to_account_info(),
                    },
                    &[seeds],
                ),
                asset_out,
                market.asset_decimals,
            )?;
        }

        emit!(Withdrawn {
            market: market.key(),
            depositor: accounts.depositor.key(),
            shares,
            usdc_out,
            asset_out,
        });
        Ok(())
    }

    /// Fills a trade against the vault. Only arcter-router may call this.
    pub fn fill(ctx: Context<Fill>, args: FillArgs) -> Result<u64> {
        let now = Clock::get()?.unix_timestamp;
        let accounts = &ctx.accounts;
        let config = &accounts.config;
        let market = &accounts.market;
        require!(
            market.status == MarketStatus::Active,
            VaultError::MarketRetired
        );

        let regime = accounts.feed.regime(config, now);
        let (spread_multiplier_bps, clip_multiplier_bps) =
            regime_multipliers(config, regime).ok_or(VaultError::MarketHalted)?;
        let day = now / SECONDS_PER_DAY;
        let used_daily_volume = if market.day_index == day {
            market.day_volume
        } else {
            0
        };

        let quote = math::quote_fill(&QuoteInputs {
            tier: market.tier(),
            spread_multiplier_bps,
            clip_multiplier_bps,
            fee_bps: config.swap_fee_bps,
            spread_share_bps: config.spread_share_bps,
            mid: accounts.feed.primary_price,
            asset_decimals: market.asset_decimals,
            multiplier_e9: read_multiplier_e9(&accounts.asset_mint.to_account_info(), now)?,
            usdc_reserve: accounts.usdc_reserve.amount,
            asset_reserve: accounts.asset_reserve.amount,
            used_daily_volume,
            buy_asset: args.buy_asset,
            amount_in: args.amount_in,
        })
        .map_err(fail)?;
        require!(
            quote.amount_out >= args.min_amount_out,
            VaultError::SlippageExceeded
        );
        require!(quote.amount_out > 0, VaultError::ZeroAmount);

        let seeds: &[&[u8]] = &[MARKET_SEED, market.asset_mint.as_ref(), &[market.bump]];
        let signer: &[&[&[u8]]] = &[seeds];
        let to_treasury = quote
            .fee
            .checked_add(quote.protocol_spread)
            .ok_or(VaultError::MathOverflow)?;

        // Trader pays in.
        let (from, mint, to, program, amount_decimals) = if args.buy_asset {
            (
                accounts.trader_usdc.to_account_info(),
                accounts.usdc_mint.to_account_info(),
                accounts.usdc_reserve.to_account_info(),
                accounts.usdc_token_program.to_account_info(),
                market.usdc_decimals,
            )
        } else {
            (
                accounts.trader_asset.to_account_info(),
                accounts.asset_mint.to_account_info(),
                accounts.asset_reserve.to_account_info(),
                accounts.asset_token_program.to_account_info(),
                market.asset_decimals,
            )
        };
        token_interface::transfer_checked(
            CpiContext::new(
                program,
                TransferChecked {
                    from,
                    mint,
                    to,
                    authority: accounts.trader.to_account_info(),
                },
            ),
            args.amount_in,
            amount_decimals,
        )?;

        // Vault pays out.
        let (from, mint, to, program, amount_decimals) = if args.buy_asset {
            (
                accounts.asset_reserve.to_account_info(),
                accounts.asset_mint.to_account_info(),
                accounts.trader_asset.to_account_info(),
                accounts.asset_token_program.to_account_info(),
                market.asset_decimals,
            )
        } else {
            (
                accounts.usdc_reserve.to_account_info(),
                accounts.usdc_mint.to_account_info(),
                accounts.trader_usdc.to_account_info(),
                accounts.usdc_token_program.to_account_info(),
                market.usdc_decimals,
            )
        };
        token_interface::transfer_checked(
            CpiContext::new_with_signer(
                program,
                TransferChecked {
                    from,
                    mint,
                    to,
                    authority: market.to_account_info(),
                },
                signer,
            ),
            quote.amount_out,
            amount_decimals,
        )?;

        // Treasury takes the fee and its share of the spread in USDC.
        if to_treasury > 0 {
            token_interface::transfer_checked(
                CpiContext::new_with_signer(
                    accounts.usdc_token_program.to_account_info(),
                    TransferChecked {
                        from: accounts.usdc_reserve.to_account_info(),
                        mint: accounts.usdc_mint.to_account_info(),
                        to: accounts.treasury_usdc.to_account_info(),
                        authority: market.to_account_info(),
                    },
                    signer,
                ),
                to_treasury,
                market.usdc_decimals,
            )?;
        }

        let market_key = market.key();
        let mid = accounts.feed.primary_price;
        let fee_bps = config.swap_fee_bps;
        let market = &mut ctx.accounts.market;
        market.day_index = day;
        market.day_volume = used_daily_volume.saturating_add(quote.notional);

        emit!(VaultFill {
            market: market_key,
            trader: ctx.accounts.trader.key(),
            buy_asset: args.buy_asset,
            amount_in: args.amount_in,
            amount_out: quote.amount_out,
            mid,
            half_spread_bps: quote.half_spread_bps,
            skew_bps: quote.skew_bps,
            fee_bps,
            regime,
        });
        Ok(quote.amount_out)
    }
}

/// Spread and clip multipliers for a tradable regime, or nothing when halted.
pub fn regime_multipliers(config: &Config, regime: Regime) -> Option<(u16, u16)> {
    match regime {
        Regime::Open => Some((10_000, 10_000)),
        Regime::Extended => Some((config.extended_spread_bps, config.extended_clip_bps)),
        Regime::Closed => Some((config.closed_spread_bps, config.closed_clip_bps)),
        Regime::Halted => None,
    }
}

/// The Scaled UI Amount multiplier in force, as fixed point with nine decimals.
/// Mints without the extension scale by exactly one.
pub fn read_multiplier_e9(mint: &AccountInfo, now: i64) -> Result<u128> {
    if *mint.owner != spl_token_2022::ID {
        return Ok(math::MULTIPLIER_ONE);
    }
    let data = mint.try_borrow_data()?;
    let state = StateWithExtensions::<spl_token_2022::state::Mint>::unpack(&data)?;
    let Ok(config) = state.get_extension::<ScaledUiAmountConfig>() else {
        return Ok(math::MULTIPLIER_ONE);
    };
    let scheduled = i64::from(config.new_multiplier_effective_timestamp);
    let multiplier = if now >= scheduled {
        f64::from(config.new_multiplier)
    } else {
        f64::from(config.multiplier)
    };
    require!(
        multiplier.is_finite() && multiplier > 0.0,
        VaultError::UnsupportedMint
    );
    Ok((multiplier * 1e9) as u128)
}

/// Refuses mints these programs cannot handle correctly. Transfer hooks need
/// extra accounts on every token movement, and transfer fees would break the
/// reserve arithmetic.
fn require_supported_mint(mint: &AccountInfo) -> Result<()> {
    if *mint.owner != spl_token_2022::ID {
        return Ok(());
    }
    let data = mint.try_borrow_data()?;
    let state = StateWithExtensions::<spl_token_2022::state::Mint>::unpack(&data)?;
    let has_hook = state
        .get_extension::<TransferHook>()
        .is_ok_and(|hook| Option::<Pubkey>::from(hook.program_id).is_some());
    require!(
        !has_hook
            && state.get_extension::<TransferFeeConfig>().is_err()
            && state.get_extension::<NonTransferable>().is_err(),
        VaultError::UnsupportedMint
    );
    Ok(())
}

fn fail(failure: QuoteFailure) -> Error {
    match failure {
        QuoteFailure::ZeroAmount => VaultError::ZeroAmount,
        QuoteFailure::NoLiquidity => VaultError::NoLiquidity,
        QuoteFailure::OutsideOracleBand => VaultError::OutsideOracleBand,
        QuoteFailure::ClipExceeded => VaultError::ClipExceeded,
        QuoteFailure::DailyCapExceeded => VaultError::DailyCapExceeded,
        QuoteFailure::InsufficientInventory => VaultError::InsufficientInventory,
        QuoteFailure::InventoryBandExceeded => VaultError::InventoryBandExceeded,
        QuoteFailure::Overflow => VaultError::MathOverflow,
    }
    .into()
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug, PartialEq, Eq, InitSpace)]
pub enum MarketStatus {
    Active,
    Retired,
}

#[account]
#[derive(InitSpace)]
pub struct Market {
    pub asset_mint: Pubkey,
    pub usdc_mint: Pubkey,
    pub feed: Pubkey,
    pub asset_reserve: Pubkey,
    pub usdc_reserve: Pubkey,
    pub share_mint: Pubkey,
    pub asset_decimals: u8,
    pub usdc_decimals: u8,
    pub status: MarketStatus,
    pub requires_attestation: bool,
    pub base_half_spread_bps: u16,
    pub max_skew_bps: u16,
    pub inventory_band_bps: u16,
    pub oracle_band_bps: u16,
    pub max_clip: u64,
    pub daily_cap: u64,
    pub tvl_cap: u64,
    pub day_index: i64,
    pub day_volume: u64,
    pub bump: u8,
}

impl Market {
    pub fn tier(&self) -> Tier {
        Tier {
            base_half_spread_bps: self.base_half_spread_bps,
            max_skew_bps: self.max_skew_bps,
            inventory_band_bps: self.inventory_band_bps,
            oracle_band_bps: self.oracle_band_bps,
            max_clip: self.max_clip,
            daily_cap: self.daily_cap,
        }
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct MarketArgs {
    pub requires_attestation: bool,
    pub base_half_spread_bps: u16,
    pub max_skew_bps: u16,
    pub inventory_band_bps: u16,
    pub oracle_band_bps: u16,
    pub max_clip: u64,
    pub daily_cap: u64,
    pub tvl_cap: u64,
}

impl MarketArgs {
    fn validate(&self) -> Result<()> {
        require!(
            self.inventory_band_bps > 0
                && u64::from(self.inventory_band_bps) < 5_000
                && self.oracle_band_bps > 0
                && self.max_clip > 0
                && self.daily_cap >= self.max_clip
                && self.tvl_cap > 0,
            VaultError::InvalidSettings
        );
        Ok(())
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug)]
pub struct FillArgs {
    pub buy_asset: bool,
    pub amount_in: u64,
    pub min_amount_out: u64,
}

#[derive(Accounts)]
pub struct CreateMarket<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        seeds::program = arcter_config::ID,
        has_one = admin @ VaultError::Unauthorized,
        has_one = usdc_mint @ VaultError::WrongMint
    )]
    pub config: Box<Account<'info, Config>>,
    pub asset_mint: Box<InterfaceAccount<'info, Mint>>,
    pub usdc_mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(
        seeds = [FEED_SEED, asset_mint.key().as_ref()],
        bump = feed.bump,
        seeds::program = arcter_oracle::ID
    )]
    pub feed: Box<Account<'info, Feed>>,
    #[account(
        init,
        payer = admin,
        space = 8 + Market::INIT_SPACE,
        seeds = [MARKET_SEED, asset_mint.key().as_ref()],
        bump
    )]
    pub market: Box<Account<'info, Market>>,
    #[account(
        init,
        payer = admin,
        token::mint = asset_mint,
        token::authority = market,
        token::token_program = asset_token_program,
        seeds = [RESERVE_SEED, market.key().as_ref(), asset_mint.key().as_ref()],
        bump
    )]
    pub asset_reserve: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(
        init,
        payer = admin,
        token::mint = usdc_mint,
        token::authority = market,
        token::token_program = usdc_token_program,
        seeds = [RESERVE_SEED, market.key().as_ref(), usdc_mint.key().as_ref()],
        bump
    )]
    pub usdc_reserve: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(
        init,
        payer = admin,
        mint::decimals = usdc_mint.decimals,
        mint::authority = market,
        mint::token_program = share_token_program,
        seeds = [SHARES_SEED, market.key().as_ref()],
        bump
    )]
    pub share_mint: Box<InterfaceAccount<'info, Mint>>,
    pub asset_token_program: Interface<'info, TokenInterface>,
    pub usdc_token_program: Interface<'info, TokenInterface>,
    pub share_token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct AdminMarket<'info> {
    pub admin: Signer<'info>,
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        seeds::program = arcter_config::ID,
        has_one = admin @ VaultError::Unauthorized
    )]
    pub config: Box<Account<'info, Config>>,
    #[account(mut, seeds = [MARKET_SEED, market.asset_mint.as_ref()], bump = market.bump)]
    pub market: Box<Account<'info, Market>>,
}

#[derive(Accounts)]
pub struct Deposit<'info> {
    pub depositor: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump, seeds::program = arcter_config::ID)]
    pub config: Box<Account<'info, Config>>,
    #[account(
        seeds = [MARKET_SEED, market.asset_mint.as_ref()],
        bump = market.bump,
        has_one = feed @ VaultError::WrongAccount,
        has_one = asset_mint @ VaultError::WrongMint,
        has_one = usdc_mint @ VaultError::WrongMint,
        has_one = asset_reserve @ VaultError::WrongAccount,
        has_one = usdc_reserve @ VaultError::WrongAccount,
        has_one = share_mint @ VaultError::WrongMint
    )]
    pub market: Box<Account<'info, Market>>,
    pub feed: Box<Account<'info, Feed>>,
    #[account(
        seeds = [ATTESTATION_SEED, depositor.key().as_ref()],
        bump = attestation.bump,
        seeds::program = arcter_access::ID
    )]
    pub attestation: Box<Account<'info, Attestation>>,
    pub asset_mint: Box<InterfaceAccount<'info, Mint>>,
    pub usdc_mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(mut)]
    pub share_mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(mut)]
    pub asset_reserve: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut)]
    pub usdc_reserve: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut, token::mint = asset_mint, token::authority = depositor, token::token_program = asset_token_program)]
    pub depositor_asset: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut, token::mint = usdc_mint, token::authority = depositor, token::token_program = usdc_token_program)]
    pub depositor_usdc: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut, token::mint = share_mint, token::authority = depositor, token::token_program = share_token_program)]
    pub depositor_shares: Box<InterfaceAccount<'info, TokenAccount>>,
    pub asset_token_program: Interface<'info, TokenInterface>,
    pub usdc_token_program: Interface<'info, TokenInterface>,
    pub share_token_program: Interface<'info, TokenInterface>,
}

#[derive(Accounts)]
pub struct Withdraw<'info> {
    pub depositor: Signer<'info>,
    #[account(
        seeds = [MARKET_SEED, market.asset_mint.as_ref()],
        bump = market.bump,
        has_one = asset_mint @ VaultError::WrongMint,
        has_one = usdc_mint @ VaultError::WrongMint,
        has_one = asset_reserve @ VaultError::WrongAccount,
        has_one = usdc_reserve @ VaultError::WrongAccount,
        has_one = share_mint @ VaultError::WrongMint
    )]
    pub market: Box<Account<'info, Market>>,
    pub asset_mint: Box<InterfaceAccount<'info, Mint>>,
    pub usdc_mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(mut)]
    pub share_mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(mut)]
    pub asset_reserve: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut)]
    pub usdc_reserve: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut, token::mint = asset_mint, token::authority = depositor, token::token_program = asset_token_program)]
    pub depositor_asset: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut, token::mint = usdc_mint, token::authority = depositor, token::token_program = usdc_token_program)]
    pub depositor_usdc: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut, token::mint = share_mint, token::authority = depositor, token::token_program = share_token_program)]
    pub depositor_shares: Box<InterfaceAccount<'info, TokenAccount>>,
    pub asset_token_program: Interface<'info, TokenInterface>,
    pub usdc_token_program: Interface<'info, TokenInterface>,
    pub share_token_program: Interface<'info, TokenInterface>,
}

#[derive(Accounts)]
pub struct Fill<'info> {
    #[account(address = config.router_authority @ VaultError::Unauthorized)]
    pub router_authority: Signer<'info>,
    pub trader: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump, seeds::program = arcter_config::ID)]
    pub config: Box<Account<'info, Config>>,
    #[account(
        mut,
        seeds = [MARKET_SEED, market.asset_mint.as_ref()],
        bump = market.bump,
        has_one = feed @ VaultError::WrongAccount,
        has_one = asset_mint @ VaultError::WrongMint,
        has_one = usdc_mint @ VaultError::WrongMint,
        has_one = asset_reserve @ VaultError::WrongAccount,
        has_one = usdc_reserve @ VaultError::WrongAccount
    )]
    pub market: Box<Account<'info, Market>>,
    pub feed: Box<Account<'info, Feed>>,
    pub asset_mint: Box<InterfaceAccount<'info, Mint>>,
    pub usdc_mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(mut)]
    pub asset_reserve: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut)]
    pub usdc_reserve: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut, token::mint = asset_mint, token::authority = trader, token::token_program = asset_token_program)]
    pub trader_asset: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut, token::mint = usdc_mint, token::authority = trader, token::token_program = usdc_token_program)]
    pub trader_usdc: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(
        mut,
        token::mint = usdc_mint,
        token::authority = config.treasury,
        token::token_program = usdc_token_program
    )]
    pub treasury_usdc: Box<InterfaceAccount<'info, TokenAccount>>,
    pub asset_token_program: Interface<'info, TokenInterface>,
    pub usdc_token_program: Interface<'info, TokenInterface>,
}

#[event]
pub struct MarketCreated {
    pub market: Pubkey,
    pub asset_mint: Pubkey,
}

#[event]
pub struct Deposited {
    pub market: Pubkey,
    pub depositor: Pubkey,
    pub usdc_amount: u64,
    pub asset_amount: u64,
    pub shares: u64,
}

#[event]
pub struct Withdrawn {
    pub market: Pubkey,
    pub depositor: Pubkey,
    pub shares: u64,
    pub usdc_out: u64,
    pub asset_out: u64,
}

#[event]
pub struct VaultFill {
    pub market: Pubkey,
    pub trader: Pubkey,
    pub buy_asset: bool,
    pub amount_in: u64,
    pub amount_out: u64,
    pub mid: u64,
    pub half_spread_bps: u16,
    pub skew_bps: i16,
    pub fee_bps: u16,
    pub regime: Regime,
}

#[error_code]
pub enum VaultError {
    #[msg("The signer does not hold the required role")]
    Unauthorized,
    #[msg("The market settings are inconsistent")]
    InvalidSettings,
    #[msg("The mint is not the one this market uses")]
    WrongMint,
    #[msg("An account does not match this market")]
    WrongAccount,
    #[msg("This mint uses an extension the vault does not support")]
    UnsupportedMint,
    #[msg("This market has been retired")]
    MarketRetired,
    #[msg("This market is halted")]
    MarketHalted,
    #[msg("The wallet lacks a valid attestation for this action")]
    NotAttested,
    #[msg("The amount must be above zero")]
    ZeroAmount,
    #[msg("This deposit would mint no shares")]
    ZeroShares,
    #[msg("The first deposit into a vault is below the minimum")]
    FirstDepositTooSmall,
    #[msg("The result is below your minimum")]
    SlippageExceeded,
    #[msg("The vault holds no liquidity")]
    NoLiquidity,
    #[msg("The quote falls outside the oracle band")]
    OutsideOracleBand,
    #[msg("The order is larger than the current clip")]
    ClipExceeded,
    #[msg("The market has reached its daily volume cap")]
    DailyCapExceeded,
    #[msg("The vault cannot cover this order")]
    InsufficientInventory,
    #[msg("This fill would push inventory outside the band")]
    InventoryBandExceeded,
    #[msg("This deposit would exceed the vault cap")]
    TvlCapExceeded,
    #[msg("Arithmetic overflow")]
    MathOverflow,
}
