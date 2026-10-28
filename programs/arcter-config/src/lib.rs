//! Protocol settings for Arcter.
//!
//! One Config account holds every value the other programs read: fees, regime
//! multipliers, the guardian key and the restart window. Sensitive values only
//! change through a queue with a delay, so anyone can see a change coming.

use anchor_lang::prelude::*;

declare_id!("2N5AqtBmZyUYbNufeMPcSuKWFYBxRzwuQ1HFPxCj7ajk");

pub const BPS: u64 = 10_000;
pub const CONFIG_SEED: &[u8] = b"config";
pub const TREASURY_SEED: &[u8] = b"treasury";
pub const CHANGE_SEED: &[u8] = b"change";

/// Upper limit on either trading fee, one percent.
pub const MAX_FEE_BPS: u16 = 100;

#[program]
pub mod arcter_config {
    use super::*;

    pub fn initialize(ctx: Context<Initialize>, args: InitializeArgs) -> Result<()> {
        require!(args.timelock_delay >= 0, ConfigError::InvalidValue);
        require!(args.restart_gap_secs > 0, ConfigError::InvalidValue);
        require!(args.swap_fee_bps <= MAX_FEE_BPS, ConfigError::InvalidValue);
        require!(args.rfq_fee_bps <= MAX_FEE_BPS, ConfigError::InvalidValue);
        require!(u64::from(args.spread_share_bps) <= BPS, ConfigError::InvalidValue);

        let now = Clock::get()?.unix_timestamp;
        ctx.accounts.config.set_inner(Config {
            admin: ctx.accounts.admin.key(),
            guardian: args.guardian,
            router_authority: args.router_authority,
            usdc_mint: args.usdc_mint,
            treasury: ctx.accounts.treasury.key(),
            swap_fee_bps: args.swap_fee_bps,
            rfq_fee_bps: args.rfq_fee_bps,
            spread_share_bps: args.spread_share_bps,
            extended_spread_bps: 15_000,
            extended_clip_bps: 7_500,
            closed_spread_bps: 30_000,
            closed_clip_bps: 5_000,
            max_jump_bps: 2_500,
            timelock_delay: args.timelock_delay,
            restart_gap_secs: args.restart_gap_secs,
            restart_grace_secs: args.restart_grace_secs,
            last_heartbeat: now,
            grace_until: 0,
            paused: false,
            next_change_id: 0,
            bump: ctx.bumps.config,
            treasury_bump: ctx.bumps.treasury,
        });
        Ok(())
    }

    /// Stops new trades. The guardian may pause, but only the admin may resume.
    pub fn set_paused(ctx: Context<SetPaused>, paused: bool) -> Result<()> {
        let config = &mut ctx.accounts.config;
        let signer = ctx.accounts.authority.key();
        if paused {
            require!(
                signer == config.guardian || signer == config.admin,
                ConfigError::Unauthorized
            );
        } else {
            require_keys_eq!(signer, config.admin, ConfigError::Unauthorized);
        }
        config.paused = paused;
        emit!(PauseChanged { paused, by: signer });
        Ok(())
    }

    /// Open to any caller. A long silence since the last call is treated as a
    /// possible cluster restart and starts the grace window.
    pub fn heartbeat(ctx: Context<Heartbeat>) -> Result<()> {
        let config = &mut ctx.accounts.config;
        let now = Clock::get()?.unix_timestamp;
        if config.heartbeat_gap_exceeded(now) {
            config.grace_until = now.saturating_add(config.restart_grace_secs);
            emit!(RestartWindowOpened {
                last_heartbeat: config.last_heartbeat,
                grace_until: config.grace_until,
            });
        }
        config.last_heartbeat = now;
        Ok(())
    }

    pub fn queue_change(
        ctx: Context<QueueChange>,
        change: ParamChange,
        reason_hash: [u8; 32],
    ) -> Result<()> {
        change.validate()?;
        let config = &mut ctx.accounts.config;
        let id = config.next_change_id;
        config.next_change_id = id.checked_add(1).ok_or(ConfigError::MathOverflow)?;

        let earliest = Clock::get()?
            .unix_timestamp
            .checked_add(config.timelock_delay)
            .ok_or(ConfigError::MathOverflow)?;
        ctx.accounts.queued.set_inner(QueuedChange {
            id,
            change,
            earliest_execution: earliest,
            reason_hash,
            bump: ctx.bumps.queued,
        });
        emit!(ChangeQueued {
            id,
            earliest_execution: earliest,
            reason_hash,
        });
        Ok(())
    }

    /// Open to any caller once the delay has passed.
    pub fn apply_change(ctx: Context<ApplyChange>) -> Result<()> {
        let queued = &ctx.accounts.queued;
        require!(
            Clock::get()?.unix_timestamp >= queued.earliest_execution,
            ConfigError::DelayNotElapsed
        );
        ctx.accounts.config.apply(&queued.change);
        emit!(ChangeApplied { id: queued.id });
        Ok(())
    }

    pub fn cancel_change(ctx: Context<CancelChange>) -> Result<()> {
        emit!(ChangeCancelled {
            id: ctx.accounts.queued.id,
        });
        Ok(())
    }
}

#[account]
#[derive(InitSpace)]
pub struct Config {
    pub admin: Pubkey,
    pub guardian: Pubkey,
    /// Signing PDA of arcter-router, the only caller allowed to trade.
    pub router_authority: Pubkey,
    pub usdc_mint: Pubkey,
    pub treasury: Pubkey,
    pub swap_fee_bps: u16,
    pub rfq_fee_bps: u16,
    /// Portion of captured spread paid to the treasury instead of depositors.
    pub spread_share_bps: u16,
    pub extended_spread_bps: u16,
    pub extended_clip_bps: u16,
    pub closed_spread_bps: u16,
    pub closed_clip_bps: u16,
    pub max_jump_bps: u16,
    pub timelock_delay: i64,
    pub restart_gap_secs: i64,
    pub restart_grace_secs: i64,
    pub last_heartbeat: i64,
    pub grace_until: i64,
    pub paused: bool,
    pub next_change_id: u64,
    pub bump: u8,
    pub treasury_bump: u8,
}

impl Config {
    pub fn heartbeat_gap_exceeded(&self, now: i64) -> bool {
        now.saturating_sub(self.last_heartbeat) > self.restart_gap_secs
    }

    /// True while markets must stay shut after a suspected restart. A gap with
    /// no heartbeat yet counts too, since a swap may see it first.
    pub fn restart_hold_active(&self, now: i64) -> bool {
        now < self.grace_until || self.heartbeat_gap_exceeded(now)
    }

    fn apply(&mut self, change: &ParamChange) {
        match *change {
            ParamChange::SwapFee { bps } => self.swap_fee_bps = bps,
            ParamChange::RfqFee { bps } => self.rfq_fee_bps = bps,
            ParamChange::SpreadShare { bps } => self.spread_share_bps = bps,
            ParamChange::RegimeMultipliers {
                extended_spread_bps,
                extended_clip_bps,
                closed_spread_bps,
                closed_clip_bps,
            } => {
                self.extended_spread_bps = extended_spread_bps;
                self.extended_clip_bps = extended_clip_bps;
                self.closed_spread_bps = closed_spread_bps;
                self.closed_clip_bps = closed_clip_bps;
            }
            ParamChange::MaxJump { bps } => self.max_jump_bps = bps,
            ParamChange::Guardian { key } => self.guardian = key,
            ParamChange::TimelockDelay { seconds } => self.timelock_delay = seconds,
            ParamChange::RestartWindow {
                gap_secs,
                grace_secs,
            } => {
                self.restart_gap_secs = gap_secs;
                self.restart_grace_secs = grace_secs;
            }
        }
    }
}

#[account]
#[derive(InitSpace)]
pub struct QueuedChange {
    pub id: u64,
    pub change: ParamChange,
    pub earliest_execution: i64,
    pub reason_hash: [u8; 32],
    pub bump: u8,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Copy, Debug, PartialEq, Eq, InitSpace)]
pub enum ParamChange {
    SwapFee {
        bps: u16,
    },
    RfqFee {
        bps: u16,
    },
    SpreadShare {
        bps: u16,
    },
    RegimeMultipliers {
        extended_spread_bps: u16,
        extended_clip_bps: u16,
        closed_spread_bps: u16,
        closed_clip_bps: u16,
    },
    MaxJump {
        bps: u16,
    },
    Guardian {
        key: Pubkey,
    },
    TimelockDelay {
        seconds: i64,
    },
    RestartWindow {
        gap_secs: i64,
        grace_secs: i64,
    },
}

impl ParamChange {
    fn validate(&self) -> Result<()> {
        let valid = match *self {
            Self::SwapFee { bps } | Self::RfqFee { bps } => bps <= MAX_FEE_BPS,
            Self::SpreadShare { bps } => u64::from(bps) <= BPS,
            Self::RegimeMultipliers {
                extended_spread_bps,
                extended_clip_bps,
                closed_spread_bps,
                closed_clip_bps,
            } => {
                // A closed market may never be cheaper or larger than a regular one.
                u64::from(extended_spread_bps) >= BPS
                    && u64::from(closed_spread_bps) >= BPS
                    && u64::from(extended_clip_bps) <= BPS
                    && u64::from(closed_clip_bps) <= BPS
            }
            Self::MaxJump { bps } => bps > 0 && u64::from(bps) <= BPS,
            Self::Guardian { key } => key != Pubkey::default(),
            Self::TimelockDelay { seconds } => seconds >= 0,
            Self::RestartWindow {
                gap_secs,
                grace_secs,
            } => gap_secs > 0 && grace_secs >= 0,
        };
        require!(valid, ConfigError::InvalidValue);
        Ok(())
    }
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct InitializeArgs {
    pub guardian: Pubkey,
    pub router_authority: Pubkey,
    pub usdc_mint: Pubkey,
    pub swap_fee_bps: u16,
    pub rfq_fee_bps: u16,
    pub spread_share_bps: u16,
    pub timelock_delay: i64,
    pub restart_gap_secs: i64,
    pub restart_grace_secs: i64,
}

#[derive(Accounts)]
pub struct Initialize<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(init, payer = admin, space = 8 + Config::INIT_SPACE, seeds = [CONFIG_SEED], bump)]
    pub config: Account<'info, Config>,
    /// CHECK: Fee authority PDA. It holds no data and is only ever used as a token owner.
    #[account(seeds = [TREASURY_SEED], bump)]
    pub treasury: UncheckedAccount<'info>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct SetPaused<'info> {
    pub authority: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
}

#[derive(Accounts)]
pub struct Heartbeat<'info> {
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
}

#[derive(Accounts)]
pub struct QueueChange<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump, has_one = admin @ ConfigError::Unauthorized)]
    pub config: Account<'info, Config>,
    #[account(
        init,
        payer = admin,
        space = 8 + QueuedChange::INIT_SPACE,
        seeds = [CHANGE_SEED, &config.next_change_id.to_le_bytes()],
        bump
    )]
    pub queued: Account<'info, QueuedChange>,
    pub system_program: Program<'info, System>,
}

#[derive(Accounts)]
pub struct ApplyChange<'info> {
    /// CHECK: Must match the admin recorded in Config. Receives the rent refund.
    #[account(mut, address = config.admin @ ConfigError::Unauthorized)]
    pub admin: UncheckedAccount<'info>,
    #[account(mut, seeds = [CONFIG_SEED], bump = config.bump)]
    pub config: Account<'info, Config>,
    #[account(
        mut,
        close = admin,
        seeds = [CHANGE_SEED, &queued.id.to_le_bytes()],
        bump = queued.bump
    )]
    pub queued: Account<'info, QueuedChange>,
}

#[derive(Accounts)]
pub struct CancelChange<'info> {
    #[account(mut)]
    pub admin: Signer<'info>,
    #[account(seeds = [CONFIG_SEED], bump = config.bump, has_one = admin @ ConfigError::Unauthorized)]
    pub config: Account<'info, Config>,
    #[account(
        mut,
        close = admin,
        seeds = [CHANGE_SEED, &queued.id.to_le_bytes()],
        bump = queued.bump
    )]
    pub queued: Account<'info, QueuedChange>,
}

#[event]
pub struct PauseChanged {
    pub paused: bool,
    pub by: Pubkey,
}

#[event]
pub struct RestartWindowOpened {
    pub last_heartbeat: i64,
    pub grace_until: i64,
}

#[event]
pub struct ChangeQueued {
    pub id: u64,
    pub earliest_execution: i64,
    pub reason_hash: [u8; 32],
}

#[event]
pub struct ChangeApplied {
    pub id: u64,
}

#[event]
pub struct ChangeCancelled {
    pub id: u64,
}

#[error_code]
pub enum ConfigError {
    #[msg("The signer does not hold the required role")]
    Unauthorized,
    #[msg("The value falls outside its permitted range")]
    InvalidValue,
    #[msg("The time lock on this change has not elapsed")]
    DelayNotElapsed,
    #[msg("Arithmetic overflow")]
    MathOverflow,
}
