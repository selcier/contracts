//! Wallet access records for Arcter.
//!
//! Approved issuers write one Attestation per wallet. It stores role flags and
//! an expiry, and never any personal data. Identity checks stay with the issuer.

use anchor_lang::prelude::*;
use arcter_config::{Config, CONFIG_SEED};

declare_id!("AjD7rqA8Ep3E7VDeCBjnqCdTkDPDgAdNUCjETMKjGxUB");

pub const ISSUER_SEED: &[u8] = b"issuer";
pub const ATTESTATION_SEED: &[u8] = b"attestation";

pub const ROLE_TRADER: u8 = 1 << 0;
pub const ROLE_LP: u8 = 1 << 1;
pub const ROLE_MAKER: u8 = 1 << 2;
pub const ROLE_RELAYER: u8 = 1 << 3;
const ALL_ROLES: u8 = ROLE_TRADER | ROLE_LP | ROLE_MAKER | ROLE_RELAYER;

#[program]
pub mod arcter_access {
    use super::*;

    pub fn add_issuer(ctx: Context<AddIssuer>, issuer: Pubkey) -> Result<()> {
        ctx.accounts.issuer_record.set_inner(Issuer {
            key: issuer,
            bump: ctx.bumps.issuer_record,
        });
        Ok(())
    }

    pub fn remove_issuer(_ctx: Context<RemoveIssuer>) -> Result<()> {
        Ok(())
    }

    /// Creates or refreshes a wallet's attestation.
    pub fn attest(ctx: Context<Attest>, wallet: Pubkey, roles: u8, expires_at: i64) -> Result<()> {
        require!(
            roles != 0 && roles & !ALL_ROLES == 0,
            AccessError::InvalidRoles
        );
        require!(
            expires_at > Clock::get()?.unix_timestamp,
            AccessError::AlreadyExpired
        );
        ctx.accounts.attestation.set_inner(Attestation {
            wallet,
            issuer: ctx.accounts.issuer.key(),
            roles,
            expires_at,
            revoked: false,
            bump: ctx.bumps.attestation,
        });
        emit!(Attested {
            wallet,
            issuer: ctx.accounts.issuer.key(),
            roles,
            expires_at,
        });
        Ok(())
    }

    pub fn revoke(ctx: Context<Revoke>) -> Result<()> {
        let attestation = &mut ctx.accounts.attestation;
        attestation.revoked = true;
        emit!(Revoked {
            wallet: attestation.wallet,
        });
        Ok(())
    }
}

#[account]
#[derive(InitSpace)]
pub struct Issuer {
    pub key: Pubkey,
    pub bump: u8,
}

#[account]
#[derive(InitSpace)]
pub struct Attestation {
    pub wallet: Pubkey,
    pub issuer: Pubkey,
    pub roles: u8,
    pub expires_at: i64,
    pub revoked: bool,
    pub bump: u8,
}

impl Attestation {
    pub fn permits(&self, role: u8, now: i64) -> bool {
        !self.revoked && now < self.expires_at && self.roles & role == role
    }
}

#[derive(Accounts)]
#[instruction(issuer: Pubkey)]
pub struct AddIssuer<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        seeds::program = arcter_config::ID,
        has_one = admin @ AccessError::Unauthorized
    )]
    pub config: Account<'info, Config>,
    #[account(
        init,
        payer = admin,
        space = 8 + Issuer::INIT_SPACE,
        seeds = [ISSUER_SEED, issuer.as_ref()],
        bump
    )]
    pub issuer_record: Account<'info, Issuer>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct RemoveIssuer<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(
        seeds = [CONFIG_SEED],
        bump = config.bump,
        seeds::program = arcter_config::ID,
        has_one = admin @ AccessError::Unauthorized
    )]
    pub config: Account<'info, Config>,
    #[account(
        mut,
        close = admin,
        seeds = [ISSUER_SEED, issuer_record.key.as_ref()],
        bump = issuer_record.bump
    )]
    pub issuer_record: Account<'info, Issuer>,
}

#[derive(Accounts)]
#[instruction(wallet: Pubkey)]
pub struct Attest<'info> {
    #[account(mut)]
    pub issuer: Signer<'info>,
    #[account(seeds = [ISSUER_SEED, issuer.key().as_ref()], bump = issuer_record.bump)]
    pub issuer_record: Account<'info, Issuer>,
    #[account(
        init_if_needed,
        payer = issuer,
        space = 8 + Attestation::INIT_SPACE,
        seeds = [ATTESTATION_SEED, wallet.as_ref()],
        bump
    )]
    pub attestation: Account<'info, Attestation>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct Revoke<'info> {
    pub issuer: Signer<'info>,
    #[account(seeds = [ISSUER_SEED, issuer.key().as_ref()], bump = issuer_record.bump)]
    pub issuer_record: Account<'info, Issuer>,
    #[account(
        mut,
        seeds = [ATTESTATION_SEED, attestation.wallet.as_ref()],
        bump = attestation.bump
    )]
    pub attestation: Account<'info, Attestation>,
}

#[event]
pub struct Attested {
    pub wallet: Pubkey,
    pub issuer: Pubkey,
    pub roles: u8,
    pub expires_at: i64,
}

#[event]
pub struct Revoked {
    pub wallet: Pubkey,
}

#[error_code]
pub enum AccessError {
    #[msg("The signer does not hold the required role")]
    Unauthorized,
    #[msg("The role flags are empty or unknown")]
    InvalidRoles,
    #[msg("The expiry must be in the future")]
    AlreadyExpired,
}
