//! Signed maker quotes for Arcter.
//!
//! A quote signature proves a maker agreed to a price, yet it cannot move
//! tokens. Makers therefore prefund inventory in accounts this program controls.
//! Only the maker can withdraw those balances, and only a valid signed quote can
//! draw on them during a fill.
//!
//! The taker's transaction must place a native Ed25519 instruction directly
//! before the router call. This program reads that instruction back to confirm
//! which key signed which bytes.

use anchor_lang::prelude::*;
use anchor_lang::solana_program::sysvar::instructions::{
    load_current_index_checked, load_instruction_at_checked,
};
use anchor_spl::token_interface::{self, Mint, TokenAccount, TokenInterface, TransferChecked};
use arcter_access::{Attestation, ATTESTATION_SEED, ROLE_MAKER};
use arcter_config::{Config, BPS, CONFIG_SEED};
use arcter_oracle::{Feed, Regime};
use arcter_vault::{math, read_multiplier_e9, Market, MarketStatus, MARKET_SEED};

declare_id!("BKBsrCf2vdcfn9CzkEhfFcmAXqjPUszg7kCpx4fXBgjs");

pub const MAKER_SEED: &[u8] = b"maker";
pub const INVENTORY_SEED: &[u8] = b"inventory";
pub const QUOTE_SEED: &[u8] = b"quote";

/// Binds a signature to this protocol and message version.
pub const QUOTE_DOMAIN: &[u8; 16] = b"ARCTER_QUOTE_V1\0";

const ED25519_PROGRAM: Pubkey = pubkey!("Ed25519SigVerify111111111111111111111111111");
const ED25519_HEADER_LEN: usize = 16;
/// Marks an Ed25519 offset as pointing inside its own instruction data.
const SAME_INSTRUCTION: u16 = u16::MAX;

#[program]
pub mod arcter_rfq {
    use super::*;

    pub fn register_maker(
        ctx: Context<RegisterMaker>,
        owner: Pubkey,
        signing_key: Pubkey,
    ) -> Result<()> {
        ctx.accounts.maker.set_inner(Maker {
            owner,
            signing_key,
            approved: true,
            cancel_floor: 0,
            bump: ctx.bumps.maker,
        });
        Ok(())
    }

    pub fn set_maker_approval(ctx: Context<SetMakerApproval>, approved: bool) -> Result<()> {
        ctx.accounts.maker.approved = approved;
        Ok(())
    }

    /// Rotates the key that signs quotes.
    pub fn set_signing_key(ctx: Context<MakerAction>, signing_key: Pubkey) -> Result<()> {
        ctx.accounts.maker.signing_key = signing_key;
        Ok(())
    }

    /// Voids every quote with an identifier below `floor` in one call.
    pub fn cancel_quotes(ctx: Context<MakerAction>, floor: u64) -> Result<()> {
        let maker = &mut ctx.accounts.maker;
        require!(floor > maker.cancel_floor, RfqError::FloorMustRise);
        maker.cancel_floor = floor;
        Ok(())
    }

    pub fn open_inventory(_ctx: Context<OpenInventory>) -> Result<()> {
        Ok(())
    }

    pub fn fund_inventory(ctx: Context<MoveInventory>, amount: u64) -> Result<()> {
        let accounts = &ctx.accounts;
        token_interface::transfer_checked(
            CpiContext::new(
                accounts.token_program.to_account_info(),
                TransferChecked {
                    from: accounts.owner_token.to_account_info(),
                    mint: accounts.mint.to_account_info(),
                    to: accounts.inventory.to_account_info(),
                    authority: accounts.owner.to_account_info(),
                },
            ),
            amount,
            accounts.mint.decimals,
        )
    }

    pub fn withdraw_inventory(ctx: Context<MoveInventory>, amount: u64) -> Result<()> {
        let accounts = &ctx.accounts;
        let owner = accounts.owner.key();
        let seeds: &[&[u8]] = &[MAKER_SEED, owner.as_ref(), &[accounts.maker.bump]];
        token_interface::transfer_checked(
            CpiContext::new_with_signer(
                accounts.token_program.to_account_info(),
                TransferChecked {
                    from: accounts.inventory.to_account_info(),
                    mint: accounts.mint.to_account_info(),
                    to: accounts.owner_token.to_account_info(),
                    authority: accounts.maker.to_account_info(),
                },
                &[seeds],
            ),
            amount,
            accounts.mint.decimals,
        )
    }

    /// Settles one signed quote. Only arcter-router may call this. A quote
    /// record is created for the identifier, so a second attempt fails.
    pub fn settle_quote(ctx: Context<SettleQuote>, quote: MakerQuote) -> Result<()> {
        let now = Clock::get()?.unix_timestamp;
        let accounts = &ctx.accounts;
        let maker = &accounts.maker;
        let market = &accounts.market;
        let config = &accounts.config;

        require!(maker.approved, RfqError::MakerNotApproved);
        require!(
            accounts.maker_attestation.permits(ROLE_MAKER, now),
            RfqError::MakerNotApproved
        );
        require_keys_eq!(quote.maker, maker.owner, RfqError::WrongQuote);
        require_keys_eq!(quote.asset_mint, market.asset_mint, RfqError::WrongQuote);
        require!(
            quote.taker == Pubkey::default() || quote.taker == accounts.taker.key(),
            RfqError::WrongTaker
        );
        require!(now < quote.expires_at, RfqError::QuoteExpired);
        require!(
            quote.quote_id >= maker.cancel_floor,
            RfqError::QuoteCancelled
        );
        require!(
            quote.usdc_amount > 0 && quote.asset_amount > 0,
            RfqError::ZeroAmount
        );
        require!(
            market.status == MarketStatus::Active,
            RfqError::MarketUnavailable
        );
        require!(
            accounts.feed.regime(config, now) != Regime::Halted,
            RfqError::MarketUnavailable
        );

        // A maker quote is held to the same band as a vault quote.
        let multiplier = read_multiplier_e9(&accounts.asset_mint.to_account_info(), now)?;
        let in_band = math::within_band(
            quote.usdc_amount,
            quote.asset_amount,
            accounts.feed.primary_price,
            market.asset_decimals,
            multiplier,
            market.oracle_band_bps,
        )
        .map_err(|_| error!(RfqError::MathOverflow))?;
        require!(in_band, RfqError::OutsideOracleBand);

        verify_signature(
            &accounts.instructions.to_account_info(),
            &maker.signing_key,
            &quote.signed_message()?,
        )?;

        let owner = maker.owner;
        ctx.accounts.record.set_inner(QuoteRecord {
            maker: owner,
            quote_id: quote.quote_id,
            settled_at: now,
            bump: ctx.bumps.record,
        });

        let accounts = &ctx.accounts;
        let seeds: &[&[u8]] = &[MAKER_SEED, owner.as_ref(), &[accounts.maker.bump]];
        let market = &accounts.market;

        let usdc = (
            accounts.usdc_token_program.to_account_info(),
            accounts.usdc_mint.to_account_info(),
            market.usdc_decimals,
        );
        let asset = (
            accounts.asset_token_program.to_account_info(),
            accounts.asset_mint.to_account_info(),
            market.asset_decimals,
        );
        let taker = accounts.taker.to_account_info();
        let maker_info = accounts.maker.to_account_info();
        let (taker_usdc, taker_asset) = (
            accounts.taker_usdc.to_account_info(),
            accounts.taker_asset.to_account_info(),
        );
        let (inventory_usdc, inventory_asset) = (
            accounts.inventory_usdc.to_account_info(),
            accounts.inventory_asset.to_account_info(),
        );

        if quote.buy_asset {
            send(&usdc, taker_usdc.clone(), inventory_usdc, taker.clone(), quote.usdc_amount, None)?;
            send(&asset, inventory_asset, taker_asset, maker_info, quote.asset_amount, Some(seeds))?;
        } else {
            send(&asset, taker_asset, inventory_asset, taker.clone(), quote.asset_amount, None)?;
            send(&usdc, inventory_usdc, taker_usdc.clone(), maker_info, quote.usdc_amount, Some(seeds))?;
        }

        let fee = quote.usdc_amount as u128 * u128::from(accounts.config.rfq_fee_bps) / u128::from(BPS);
        let fee = u64::try_from(fee).map_err(|_| error!(RfqError::MathOverflow))?;
        if fee > 0 {
            send(
                &usdc,
                taker_usdc,
                accounts.treasury_usdc.to_account_info(),
                taker,
                fee,
                None,
            )?;
        }

        emit!(QuoteSettled {
            market: market.key(),
            maker: owner,
            taker: accounts.taker.key(),
            quote_id: quote.quote_id,
            buy_asset: quote.buy_asset,
            usdc_amount: quote.usdc_amount,
            asset_amount: quote.asset_amount,
            fee,
        });
        Ok(())
    }
}

fn send<'info>(
    (program, mint, decimals): &(AccountInfo<'info>, AccountInfo<'info>, u8),
    from: AccountInfo<'info>,
    to: AccountInfo<'info>,
    authority: AccountInfo<'info>,
    amount: u64,
    seeds: Option<&[&[u8]]>,
) -> Result<()> {
    let accounts = TransferChecked {
        from,
        mint: mint.clone(),
        to,
        authority,
    };
    match seeds {
        Some(seeds) => token_interface::transfer_checked(
            CpiContext::new_with_signer(program.clone(), accounts, &[seeds]),
            amount,
            *decimals,
        ),
        None => token_interface::transfer_checked(
            CpiContext::new(program.clone(), accounts),
            amount,
            *decimals,
        ),
    }
}

/// Confirms that the instruction directly before this one is an Ed25519 check
/// of `expected_message` by `expected_signer`. Every offset must point inside
/// that same instruction, otherwise an attacker could have it verify one
/// message while this program reads another.
fn verify_signature(
    instructions: &AccountInfo,
    expected_signer: &Pubkey,
    expected_message: &[u8],
) -> Result<()> {
    let current = load_current_index_checked(instructions)?;
    let previous = current.checked_sub(1).ok_or(RfqError::SignatureMissing)?;
    let check = load_instruction_at_checked(usize::from(previous), instructions)?;
    require_keys_eq!(
        check.program_id,
        ED25519_PROGRAM,
        RfqError::SignatureMissing
    );

    let data = &check.data;
    require!(
        data.len() >= ED25519_HEADER_LEN && data[0] == 1,
        RfqError::SignatureMalformed
    );
    let field = |at: usize| u16::from_le_bytes([data[at], data[at + 1]]);
    let (signature_index, key_offset, key_index) = (field(4), field(6), field(8));
    let (message_offset, message_size, message_index) = (field(10), field(12), field(14));
    require!(
        signature_index == SAME_INSTRUCTION
            && key_index == SAME_INSTRUCTION
            && message_index == SAME_INSTRUCTION,
        RfqError::SignatureMalformed
    );

    let key_start = usize::from(key_offset);
    let key = data
        .get(key_start..key_start + 32)
        .ok_or(RfqError::SignatureMalformed)?;
    require!(
        key == expected_signer.as_ref(),
        RfqError::SignatureMismatch
    );

    let message_start = usize::from(message_offset);
    let message = data
        .get(message_start..message_start + usize::from(message_size))
        .ok_or(RfqError::SignatureMalformed)?;
    require!(message == expected_message, RfqError::SignatureMismatch);
    Ok(())
}

/// Terms a maker signs. The taker field may be left empty to allow any taker.
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug, PartialEq, Eq)]
pub struct MakerQuote {
    pub maker: Pubkey,
    pub taker: Pubkey,
    pub asset_mint: Pubkey,
    /// True when the taker buys the asset with USDC.
    pub buy_asset: bool,
    pub usdc_amount: u64,
    pub asset_amount: u64,
    pub quote_id: u64,
    pub expires_at: i64,
}

impl MakerQuote {
    /// The exact bytes a maker signs: domain, this program's ID, then the quote.
    pub fn signed_message(&self) -> Result<Vec<u8>> {
        let mut message = Vec::with_capacity(160);
        message.extend_from_slice(QUOTE_DOMAIN);
        message.extend_from_slice(crate::ID.as_ref());
        self.serialize(&mut message)?;
        Ok(message)
    }
}

#[account]
#[derive(InitSpace)]
pub struct Maker {
    pub owner: Pubkey,
    pub signing_key: Pubkey,
    pub approved: bool,
    /// Identifiers below this value are void.
    pub cancel_floor: u64,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct QuoteRecord {
    pub maker: Pubkey,
    pub quote_id: u64,
    pub settled_at: i64,
    pub bump: u8,
}

#[derive(Accounts)]
#[instruction(owner: Pubkey)]
pub struct RegisterMaker<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        seeds::program = arcter_config::ID,
        has_one = admin @ RfqError::Unauthorized
    )]
    pub config: Account<'info, Config>,
    #[account(
        init,
        payer = admin,
        space = 8 + Maker::INIT_SPACE,
        seeds = [MAKER_SEED, owner.as_ref()],
        bump
    )]
    pub maker: Account<'info, Maker>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct SetMakerApproval<'info> {
    pub admin: Signer<'info>,
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        seeds::program = arcter_config::ID,
        has_one = admin @ RfqError::Unauthorized
    )]
    pub config: Account<'info, Config>,
    #[account(mut, seeds = [MAKER_SEED, maker.owner.as_ref()], bump = maker.bump)]
    pub maker: Account<'info, Maker>,
}

#[derive(Accounts)]
pub struct MakerAction<'info> {
    pub owner: Signer<'info>,
    #[account(
        mut,
        seeds = [MAKER_SEED, owner.key().as_ref()],
        bump = maker.bump,
        has_one = owner @ RfqError::Unauthorized
    )]
    pub maker: Account<'info, Maker>,
}

#[derive(Accounts)]
pub struct OpenInventory<'info> {
    #[account(mut)]
    pub owner: Signer<'info>,
    #[account(
        seeds = [MAKER_SEED, owner.key().as_ref()],
        bump = maker.bump,
        has_one = owner @ RfqError::Unauthorized
    )]
    pub maker: Account<'info, Maker>,
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(
        init,
        payer = owner,
        token::mint = mint,
        token::authority = maker,
        token::token_program = token_program,
        seeds = [INVENTORY_SEED, owner.key().as_ref(), mint.key().as_ref()],
        bump
    )]
    pub inventory: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct MoveInventory<'info> {
    pub owner: Signer<'info>,
    #[account(
        seeds = [MAKER_SEED, owner.key().as_ref()],
        bump = maker.bump,
        has_one = owner @ RfqError::Unauthorized
    )]
    pub maker: Account<'info, Maker>,
    pub mint: InterfaceAccount<'info, Mint>,
    #[account(
        mut,
        seeds = [INVENTORY_SEED, owner.key().as_ref(), mint.key().as_ref()],
        bump
    )]
    pub inventory: InterfaceAccount<'info, TokenAccount>,
    #[account(mut, token::mint = mint, token::authority = owner, token::token_program = token_program)]
    pub owner_token: InterfaceAccount<'info, TokenAccount>,
    pub token_program: Interface<'info, TokenInterface>,
}

#[derive(Accounts)]
#[instruction(quote: MakerQuote)]
pub struct SettleQuote<'info> {
    #[account(address = config.router_authority @ RfqError::Unauthorized)]
    pub router_authority: Signer<'info>,
    #[account(mut)]
    pub taker: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump, seeds::program = arcter_config::ID)]
    pub config: Box<Account<'info, Config>>,
    #[account(
        seeds = [MARKET_SEED, market.asset_mint.as_ref()],
        bump = market.bump,
        seeds::program = arcter_vault::ID,
        has_one = feed @ RfqError::WrongAccount,
        has_one = asset_mint @ RfqError::WrongAccount,
        has_one = usdc_mint @ RfqError::WrongAccount
    )]
    pub market: Box<Account<'info, Market>>,
    pub feed: Box<Account<'info, Feed>>,
    #[account(seeds = [MAKER_SEED, maker.owner.as_ref()], bump = maker.bump)]
    pub maker: Box<Account<'info, Maker>>,
    #[account(
        seeds = [ATTESTATION_SEED, maker.owner.as_ref()],
        bump = maker_attestation.bump,
        seeds::program = arcter_access::ID
    )]
    pub maker_attestation: Box<Account<'info, Attestation>>,
    #[account(
        init,
        payer = taker,
        space = 8 + QuoteRecord::INIT_SPACE,
        seeds = [QUOTE_SEED, maker.owner.as_ref(), &quote.quote_id.to_le_bytes()],
        bump
    )]
    pub record: Box<Account<'info, QuoteRecord>>,
    pub asset_mint: Box<InterfaceAccount<'info, Mint>>,
    pub usdc_mint: Box<InterfaceAccount<'info, Mint>>,
    #[account(
        mut,
        seeds = [INVENTORY_SEED, maker.owner.as_ref(), asset_mint.key().as_ref()],
        bump
    )]
    pub inventory_asset: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(
        mut,
        seeds = [INVENTORY_SEED, maker.owner.as_ref(), usdc_mint.key().as_ref()],
        bump
    )]
    pub inventory_usdc: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut, token::mint = asset_mint, token::authority = taker, token::token_program = asset_token_program)]
    pub taker_asset: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(mut, token::mint = usdc_mint, token::authority = taker, token::token_program = usdc_token_program)]
    pub taker_usdc: Box<InterfaceAccount<'info, TokenAccount>>,
    #[account(
        mut,
        token::mint = usdc_mint,
        token::authority = config.treasury,
        token::token_program = usdc_token_program
    )]
    pub treasury_usdc: Box<InterfaceAccount<'info, TokenAccount>>,
    pub asset_token_program: Interface<'info, TokenInterface>,
    pub usdc_token_program: Interface<'info, TokenInterface>,
    /// CHECK: Fixed to the instructions sysvar by the address constraint.
    #[account(address = anchor_lang::solana_program::sysvar::instructions::ID)]
    pub instructions: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

#[event]
pub struct QuoteSettled {
    pub market: Pubkey,
    pub maker: Pubkey,
    pub taker: Pubkey,
    pub quote_id: u64,
    pub buy_asset: bool,
    pub usdc_amount: u64,
    pub asset_amount: u64,
    pub fee: u64,
}

#[error_code]
pub enum RfqError {
    #[msg("The signer does not hold the required role")]
    Unauthorized,
    #[msg("This maker is not approved to quote")]
    MakerNotApproved,
    #[msg("The quote does not match the supplied accounts")]
    WrongQuote,
    #[msg("An account does not match this market")]
    WrongAccount,
    #[msg("This quote is reserved for another taker")]
    WrongTaker,
    #[msg("This quote has expired")]
    QuoteExpired,
    #[msg("This quote has been cancelled")]
    QuoteCancelled,
    #[msg("The amount must be above zero")]
    ZeroAmount,
    #[msg("This market cannot accept a fill right now")]
    MarketUnavailable,
    #[msg("The quote price falls outside the oracle band")]
    OutsideOracleBand,
    #[msg("The transaction has no Ed25519 check before this call")]
    SignatureMissing,
    #[msg("The Ed25519 check is malformed")]
    SignatureMalformed,
    #[msg("The Ed25519 check covers a different key or message")]
    SignatureMismatch,
    #[msg("The cancel floor can only rise")]
    FloorMustRise,
    #[msg("Arithmetic overflow")]
    MathOverflow,
}
