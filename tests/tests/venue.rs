//! End-to-end tests. Each one loads the compiled programs into a real Solana
//! VM, so CPIs, PDA signing, token transfers and Ed25519 checks all run for real.
//! Build first with `anchor build`, then run `cargo test` from this folder.

use anchor_lang::{system_program, AccountDeserialize, InstructionData, ToAccountMetas};
use anchor_spl::{
    token::spl_token,
    token_2022::spl_token_2022::{self, extension::ExtensionType},
};
use arcter_access::{ROLE_LP, ROLE_MAKER, ROLE_TRADER};
use arcter_config::{InitializeArgs, ParamChange};
use arcter_oracle::{CreateFeedArgs, ReportArgs, Session};
use arcter_rfq::MakerQuote;
use arcter_router::SwapArgs;
use arcter_vault::{math, FillArgs, MarketArgs};
use litesvm::LiteSVM;
use solana_sdk::{
    clock::Clock,
    instruction::{AccountMeta, Instruction},
    program_pack::Pack,
    pubkey::Pubkey,
    signature::{Keypair, Signer},
    system_instruction, sysvar,
    transaction::Transaction,
};

const USDC: u64 = 1_000_000;
const TOKEN: u64 = 100_000_000;
const MID: u64 = 200 * USDC;
const START: i64 = 1_800_000_000;
const ED25519: Pubkey =
    solana_sdk::pubkey!("Ed25519SigVerify111111111111111111111111111");

fn pda(seeds: &[&[u8]], program: &Pubkey) -> Pubkey {
    Pubkey::find_program_address(seeds, program).0
}

struct Venue {
    svm: LiteSVM,
    admin: Keypair,
    publisher: Keypair,
    usdc_mint: Pubkey,
    asset_mint: Pubkey,
    asset_program: Pubkey,
    config: Pubkey,
    treasury_usdc: Pubkey,
}

impl Venue {
    fn new() -> Self {
        Self::with_asset(spl_token::ID, None)
    }

    /// Builds a venue with one funded market. `scaled` adds a Scaled UI Amount
    /// multiplier to a Token-2022 asset mint.
    fn with_asset(asset_program: Pubkey, scaled: Option<f64>) -> Self {
        let mut svm = LiteSVM::new();
        for (id, name) in [
            (arcter_config::ID, "arcter_config"),
            (arcter_access::ID, "arcter_access"),
            (arcter_oracle::ID, "arcter_oracle"),
            (arcter_vault::ID, "arcter_vault"),
            (arcter_rfq::ID, "arcter_rfq"),
            (arcter_router::ID, "arcter_router"),
        ] {
            svm.add_program_from_file(id, format!("../target/deploy/{name}.so"))
                .unwrap();
        }
        let admin = Keypair::new();
        let publisher = Keypair::new();
        svm.airdrop(&admin.pubkey(), 100_000_000_000).unwrap();
        svm.airdrop(&publisher.pubkey(), 10_000_000_000).unwrap();
        let mut venue = Self {
            svm,
            admin,
            publisher,
            usdc_mint: Pubkey::default(),
            asset_mint: Pubkey::default(),
            asset_program,
            config: pda(&[b"config"], &arcter_config::ID),
            treasury_usdc: Pubkey::default(),
        };
        venue.set_time(START);
        venue.usdc_mint = venue.create_mint(spl_token::ID, 6, None, false);
        venue.asset_mint = venue.create_mint(asset_program, 8, scaled, false);
        venue.initialize();
        venue.list_market(venue.asset_mint, venue.asset_program, false).unwrap();
        venue.post(MID, Session::Regular).unwrap();
        venue
    }

    fn set_time(&mut self, now: i64) {
        let mut clock = self.svm.get_sysvar::<Clock>();
        clock.unix_timestamp = now;
        clock.slot += 10;
        self.svm.set_sysvar(&clock);
        self.svm.expire_blockhash();
    }

    fn now(&self) -> i64 {
        self.svm.get_sysvar::<Clock>().unix_timestamp
    }

    fn send(&mut self, ixs: &[Instruction], signers: &[&Keypair]) -> Result<(), String> {
        let payer = signers[0].pubkey();
        let tx = Transaction::new_signed_with_payer(
            ixs,
            Some(&payer),
            signers,
            self.svm.latest_blockhash(),
        );
        let result = self
            .svm
            .send_transaction(tx)
            .map(|_| ())
            .map_err(|failed| format!("{:?}\n{}", failed.err, failed.meta.logs.join("\n")));
        self.svm.expire_blockhash();
        result
    }

    fn create_mint(
        &mut self,
        program: Pubkey,
        decimals: u8,
        scaled: Option<f64>,
        hooked: bool,
    ) -> Pubkey {
        let mint = Keypair::new();
        let mut extensions = vec![];
        if scaled.is_some() {
            extensions.push(ExtensionType::ScaledUiAmount);
        }
        if hooked {
            extensions.push(ExtensionType::TransferHook);
        }
        let space = if program == spl_token::ID {
            spl_token::state::Mint::LEN
        } else {
            ExtensionType::try_calculate_account_len::<spl_token_2022::state::Mint>(&extensions)
                .unwrap()
        };
        let rent = self.svm.minimum_balance_for_rent_exemption(space);
        let admin = self.admin.pubkey();
        let mut ixs = vec![system_instruction::create_account(
            &admin,
            &mint.pubkey(),
            rent,
            space as u64,
            &program,
        )];
        if let Some(multiplier) = scaled {
            ixs.push(
                spl_token_2022::extension::scaled_ui_amount::instruction::initialize(
                    &program,
                    &mint.pubkey(),
                    Some(admin),
                    multiplier,
                )
                .unwrap(),
            );
        }
        if hooked {
            ixs.push(
                spl_token_2022::extension::transfer_hook::instruction::initialize(
                    &program,
                    &mint.pubkey(),
                    Some(admin),
                    Some(Pubkey::new_unique()),
                )
                .unwrap(),
            );
        }
        ixs.push(if program == spl_token::ID {
            spl_token::instruction::initialize_mint2(&program, &mint.pubkey(), &admin, None, decimals)
                .unwrap()
        } else {
            spl_token_2022::instruction::initialize_mint2(
                &program,
                &mint.pubkey(),
                &admin,
                None,
                decimals,
            )
            .unwrap()
        });
        let admin_key = self.admin.insecure_clone();
        self.send(&ixs, &[&admin_key, &mint]).unwrap();
        mint.pubkey()
    }

    fn token_account(&mut self, mint: Pubkey, owner: Pubkey, program: Pubkey) -> Pubkey {
        let account = Keypair::new();
        let is_classic = program == spl_token::ID;
        let space = if is_classic {
            spl_token::state::Account::LEN
        } else {
            let mint_data = self.svm.get_account(&mint).unwrap().data;
            let required = {
                use spl_token_2022::extension::{BaseStateWithExtensions, StateWithExtensions};
                let state =
                    StateWithExtensions::<spl_token_2022::state::Mint>::unpack(&mint_data).unwrap();
                ExtensionType::get_required_init_account_extensions(
                    &state.get_extension_types().unwrap(),
                )
            };
            ExtensionType::try_calculate_account_len::<spl_token_2022::state::Account>(&required)
                .unwrap()
        };
        let rent = self.svm.minimum_balance_for_rent_exemption(space);
        let init = if is_classic {
            spl_token::instruction::initialize_account3(&program, &account.pubkey(), &mint, &owner)
                .unwrap()
        } else {
            spl_token_2022::instruction::initialize_account3(
                &program,
                &account.pubkey(),
                &mint,
                &owner,
            )
            .unwrap()
        };
        let admin = self.admin.insecure_clone();
        self.send(
            &[
                system_instruction::create_account(
                    &admin.pubkey(),
                    &account.pubkey(),
                    rent,
                    space as u64,
                    &program,
                ),
                init,
            ],
            &[&admin, &account],
        )
        .unwrap();
        account.pubkey()
    }

    fn mint_to(&mut self, mint: Pubkey, to: Pubkey, program: Pubkey, amount: u64) {
        let admin = self.admin.insecure_clone();
        let ix = if program == spl_token::ID {
            spl_token::instruction::mint_to(&program, &mint, &to, &admin.pubkey(), &[], amount)
                .unwrap()
        } else {
            spl_token_2022::instruction::mint_to(&program, &mint, &to, &admin.pubkey(), &[], amount)
                .unwrap()
        };
        self.send(&[ix], &[&admin]).unwrap();
    }

    fn balance(&self, account: Pubkey) -> u64 {
        let data = self.svm.get_account(&account).unwrap().data;
        spl_token::state::Account::unpack_from_slice(&data[..spl_token::state::Account::LEN])
            .unwrap()
            .amount
    }

    fn initialize(&mut self) {
        let admin = self.admin.insecure_clone();
        let treasury = pda(&[b"treasury"], &arcter_config::ID);
        let ix = Instruction {
            program_id: arcter_config::ID,
            accounts: arcter_config::accounts::Initialize {
                admin: admin.pubkey(),
                config: self.config,
                treasury,
                system_program: system_program::ID,
            }
            .to_account_metas(None),
            data: arcter_config::instruction::Initialize {
                args: InitializeArgs {
                    guardian: admin.pubkey(),
                    router_authority: pda(&[b"router"], &arcter_router::ID),
                    usdc_mint: self.usdc_mint,
                    swap_fee_bps: 2,
                    rfq_fee_bps: 2,
                    spread_share_bps: 1_000,
                    timelock_delay: 3_600,
                    restart_gap_secs: 86_400,
                    restart_grace_secs: 3_600,
                },
            }
            .data(),
        };
        self.send(&[ix], &[&admin]).unwrap();
        self.treasury_usdc = self.token_account(self.usdc_mint, treasury, spl_token::ID);

        let issuer = self.issuer_ix();
        self.send(&[issuer], &[&admin]).unwrap();
    }

    fn issuer_ix(&self) -> Instruction {
        let admin = self.admin.pubkey();
        Instruction {
            program_id: arcter_access::ID,
            accounts: arcter_access::accounts::AddIssuer {
                admin,
                config: self.config,
                issuer_record: pda(&[b"issuer", admin.as_ref()], &arcter_access::ID),
                system_program: system_program::ID,
            }
            .to_account_metas(None),
            data: arcter_access::instruction::AddIssuer { issuer: admin }.data(),
        }
    }

    fn attest(&mut self, wallet: Pubkey, roles: u8) {
        let admin = self.admin.insecure_clone();
        let ix = Instruction {
            program_id: arcter_access::ID,
            accounts: arcter_access::accounts::Attest {
                issuer: admin.pubkey(),
                issuer_record: pda(&[b"issuer", admin.pubkey().as_ref()], &arcter_access::ID),
                attestation: attestation_key(wallet),
                system_program: system_program::ID,
            }
            .to_account_metas(None),
            data: arcter_access::instruction::Attest {
                wallet,
                roles,
                expires_at: self.now() + 86_400 * 365,
            }
            .data(),
        };
        self.send(&[ix], &[&admin]).unwrap();
    }

    fn list_market(
        &mut self,
        mint: Pubkey,
        program: Pubkey,
        requires_attestation: bool,
    ) -> Result<(), String> {
        let admin = self.admin.insecure_clone();
        let feed = feed_key(mint);
        let create_feed = Instruction {
            program_id: arcter_oracle::ID,
            accounts: arcter_oracle::accounts::CreateFeed {
                admin: admin.pubkey(),
                config: self.config,
                asset_mint: mint,
                feed,
                system_program: system_program::ID,
            }
            .to_account_metas(None),
            data: arcter_oracle::instruction::CreateFeed {
                args: CreateFeedArgs {
                    publisher: self.publisher.pubkey(),
                    max_age_regular: 3_600,
                    max_age_extended: 7_200,
                    max_age_closed: 345_600,
                    max_deviation_bps: 75,
                },
            }
            .data(),
        };
        self.send(&[create_feed], &[&admin])?;

        let market = market_key(mint);
        let ix = Instruction {
            program_id: arcter_vault::ID,
            accounts: arcter_vault::accounts::CreateMarket {
                admin: admin.pubkey(),
                config: self.config,
                asset_mint: mint,
                usdc_mint: self.usdc_mint,
                feed,
                market,
                asset_reserve: reserve_key(market, mint),
                usdc_reserve: reserve_key(market, self.usdc_mint),
                share_mint: shares_key(market),
                asset_token_program: program,
                usdc_token_program: spl_token::ID,
                share_token_program: spl_token::ID,
                system_program: system_program::ID,
            }
            .to_account_metas(None),
            data: arcter_vault::instruction::CreateMarket {
                args: tier_a(requires_attestation),
            }
            .data(),
        };
        self.send(&[ix], &[&admin])
    }

    fn post_for(&mut self, mint: Pubkey, price: u64, session: Session) -> Result<(), String> {
        let publisher = self.publisher.insecure_clone();
        let ix = Instruction {
            program_id: arcter_oracle::ID,
            accounts: arcter_oracle::accounts::PostReport {
                publisher: publisher.pubkey(),
                config: self.config,
                feed: feed_key(mint),
            }
            .to_account_metas(None),
            data: arcter_oracle::instruction::PostReport {
                args: ReportArgs {
                    price,
                    observed_at: self.now(),
                    session,
                },
            }
            .data(),
        };
        self.send(&[ix], &[&publisher])
    }

    fn post(&mut self, price: u64, session: Session) -> Result<(), String> {
        self.post_for(self.asset_mint, price, session)
    }

    /// A wallet funded with both tokens and a share account.
    fn user(&mut self, usdc: u64, asset: u64) -> User {
        let wallet = Keypair::new();
        self.svm.airdrop(&wallet.pubkey(), 10_000_000_000).unwrap();
        let usdc_account = self.token_account(self.usdc_mint, wallet.pubkey(), spl_token::ID);
        let asset_account = self.token_account(self.asset_mint, wallet.pubkey(), self.asset_program);
        let market = market_key(self.asset_mint);
        let shares = self.token_account(shares_key(market), wallet.pubkey(), spl_token::ID);
        if usdc > 0 {
            self.mint_to(self.usdc_mint, usdc_account, spl_token::ID, usdc);
        }
        if asset > 0 {
            self.mint_to(self.asset_mint, asset_account, self.asset_program, asset);
        }
        User {
            wallet,
            usdc: usdc_account,
            asset: asset_account,
            shares,
        }
    }

    fn deposit_ix(&self, user: &User, usdc: u64, asset: u64) -> Instruction {
        let wallet = user.wallet.pubkey();
        let market = market_key(self.asset_mint);
        Instruction {
            program_id: arcter_vault::ID,
            accounts: arcter_vault::accounts::Deposit {
                depositor: wallet,
                config: self.config,
                market,
                feed: feed_key(self.asset_mint),
                attestation: attestation_key(wallet),
                asset_mint: self.asset_mint,
                usdc_mint: self.usdc_mint,
                share_mint: shares_key(market),
                asset_reserve: reserve_key(market, self.asset_mint),
                usdc_reserve: reserve_key(market, self.usdc_mint),
                depositor_asset: user.asset,
                depositor_usdc: user.usdc,
                depositor_shares: user.shares,
                asset_token_program: self.asset_program,
                usdc_token_program: spl_token::ID,
                share_token_program: spl_token::ID,
            }
            .to_account_metas(None),
            data: arcter_vault::instruction::Deposit {
                usdc_amount: usdc,
                asset_amount: asset,
                min_shares: 1,
            }
            .data(),
        }
    }

    fn deposit(&mut self, user: &User, usdc: u64, asset: u64) -> Result<(), String> {
        let ix = self.deposit_ix(user, usdc, asset);
        self.send(&[ix], &[&user.wallet])
    }

    /// Funds the vault with 500,000 USDC and 2,500 tokens, an even split.
    fn seed_vault(&mut self) -> User {
        let lp = self.user(500_000 * USDC, 2_500 * TOKEN);
        self.attest(lp.wallet.pubkey(), ROLE_LP);
        self.deposit(&lp, 500_000 * USDC, 2_500 * TOKEN).unwrap();
        lp
    }

    fn withdraw(&mut self, user: &User, shares: u64) -> Result<(), String> {
        let market = market_key(self.asset_mint);
        let ix = Instruction {
            program_id: arcter_vault::ID,
            accounts: arcter_vault::accounts::Withdraw {
                depositor: user.wallet.pubkey(),
                market,
                asset_mint: self.asset_mint,
                usdc_mint: self.usdc_mint,
                share_mint: shares_key(market),
                asset_reserve: reserve_key(market, self.asset_mint),
                usdc_reserve: reserve_key(market, self.usdc_mint),
                depositor_asset: user.asset,
                depositor_usdc: user.usdc,
                depositor_shares: user.shares,
                asset_token_program: self.asset_program,
                usdc_token_program: spl_token::ID,
                share_token_program: spl_token::ID,
            }
            .to_account_metas(None),
            data: arcter_vault::instruction::Withdraw {
                shares,
                min_usdc: 0,
                min_asset: 0,
            }
            .data(),
        };
        self.send(&[ix], &[&user.wallet])
    }

    fn swap_ix(&self, user: &User, args: SwapArgs, attested: bool) -> Instruction {
        let wallet = user.wallet.pubkey();
        let market = market_key(self.asset_mint);
        Instruction {
            program_id: arcter_router::ID,
            accounts: arcter_router::accounts::SwapExactIn {
                trader: wallet,
                router_authority: pda(&[b"router"], &arcter_router::ID),
                config: self.config,
                market,
                attestation: attested.then(|| attestation_key(wallet)),
                feed: feed_key(self.asset_mint),
                asset_mint: self.asset_mint,
                usdc_mint: self.usdc_mint,
                asset_reserve: reserve_key(market, self.asset_mint),
                usdc_reserve: reserve_key(market, self.usdc_mint),
                trader_asset: user.asset,
                trader_usdc: user.usdc,
                treasury_usdc: self.treasury_usdc,
                asset_token_program: self.asset_program,
                usdc_token_program: spl_token::ID,
                vault_program: arcter_vault::ID,
            }
            .to_account_metas(None),
            data: arcter_router::instruction::SwapExactIn { args }.data(),
        }
    }

    fn buy(&mut self, user: &User, amount_in: u64, min_out: u64) -> Result<(), String> {
        let args = SwapArgs {
            buy_asset: true,
            amount_in,
            min_amount_out: min_out,
            expires_at: self.now() + 60,
        };
        let ix = self.swap_ix(user, args, false);
        self.send(&[ix], &[&user.wallet])
    }

    fn sell(&mut self, user: &User, amount_in: u64, min_out: u64) -> Result<(), String> {
        let args = SwapArgs {
            buy_asset: false,
            amount_in,
            min_amount_out: min_out,
            expires_at: self.now() + 60,
        };
        let ix = self.swap_ix(user, args, false);
        self.send(&[ix], &[&user.wallet])
    }

    fn set_paused(&mut self, paused: bool) {
        let admin = self.admin.insecure_clone();
        let ix = Instruction {
            program_id: arcter_config::ID,
            accounts: arcter_config::accounts::SetPaused {
                authority: admin.pubkey(),
                config: self.config,
            }
            .to_account_metas(None),
            data: arcter_config::instruction::SetPaused { paused }.data(),
        };
        self.send(&[ix], &[&admin]).unwrap();
    }

    fn config_account(&self) -> arcter_config::Config {
        let data = self.svm.get_account(&self.config).unwrap().data;
        arcter_config::Config::try_deserialize(&mut data.as_slice()).unwrap()
    }

    /// Prepares an approved maker holding 100,000 USDC and 500 tokens in inventory.
    fn maker(&mut self) -> Maker {
        let admin = self.admin.insecure_clone();
        let user = self.user(100_000 * USDC, 500 * TOKEN);
        let owner = user.wallet.pubkey();
        let signing = Keypair::new();
        self.attest(owner, ROLE_MAKER);
        let key = maker_key(owner);
        let register = Instruction {
            program_id: arcter_rfq::ID,
            accounts: arcter_rfq::accounts::RegisterMaker {
                admin: admin.pubkey(),
                config: self.config,
                maker: key,
                system_program: system_program::ID,
            }
            .to_account_metas(None),
            data: arcter_rfq::instruction::RegisterMaker {
                owner,
                signing_key: signing.pubkey(),
            }
            .data(),
        };
        self.send(&[register], &[&admin]).unwrap();

        let (usdc_mint, asset_mint, asset_program) =
            (self.usdc_mint, self.asset_mint, self.asset_program);
        let legs = [
            (usdc_mint, spl_token::ID, user.usdc, 100_000 * USDC),
            (asset_mint, asset_program, user.asset, 500 * TOKEN),
        ];
        for (mint, program, source, amount) in legs {
            let inventory = inventory_key(owner, mint);
            let open = Instruction {
                program_id: arcter_rfq::ID,
                accounts: arcter_rfq::accounts::OpenInventory {
                    owner,
                    maker: key,
                    mint,
                    inventory,
                    token_program: program,
                    system_program: system_program::ID,
                }
                .to_account_metas(None),
                data: arcter_rfq::instruction::OpenInventory {}.data(),
            };
            let fund = Instruction {
                program_id: arcter_rfq::ID,
                accounts: arcter_rfq::accounts::MoveInventory {
                    owner,
                    maker: key,
                    mint,
                    inventory,
                    owner_token: source,
                    token_program: program,
                }
                .to_account_metas(None),
                data: arcter_rfq::instruction::FundInventory { amount }.data(),
            };
            self.send(&[open, fund], &[&user.wallet]).unwrap();
        }
        Maker { user, signing }
    }

    fn quote_ix(&self, taker: &User, maker: &Maker, quote: MakerQuote) -> Instruction {
        let market = market_key(self.asset_mint);
        let owner = maker.user.wallet.pubkey();
        Instruction {
            program_id: arcter_router::ID,
            accounts: arcter_router::accounts::SwapWithQuote {
                taker: taker.wallet.pubkey(),
                router_authority: pda(&[b"router"], &arcter_router::ID),
                config: self.config,
                market,
                attestation: None,
                feed: feed_key(self.asset_mint),
                maker: maker_key(owner),
                maker_attestation: attestation_key(owner),
                record: pda(
                    &[b"quote", owner.as_ref(), &quote.quote_id.to_le_bytes()],
                    &arcter_rfq::ID,
                ),
                asset_mint: self.asset_mint,
                usdc_mint: self.usdc_mint,
                inventory_asset: inventory_key(owner, self.asset_mint),
                inventory_usdc: inventory_key(owner, self.usdc_mint),
                taker_asset: taker.asset,
                taker_usdc: taker.usdc,
                treasury_usdc: self.treasury_usdc,
                asset_token_program: self.asset_program,
                usdc_token_program: spl_token::ID,
                instructions: sysvar::instructions::ID,
                rfq_program: arcter_rfq::ID,
                system_program: system_program::ID,
            }
            .to_account_metas(None),
            data: arcter_router::instruction::SwapWithQuote { quote }.data(),
        }
    }

    fn quote(&self, maker: &Maker, taker: &User, quote_id: u64) -> MakerQuote {
        MakerQuote {
            maker: maker.user.wallet.pubkey(),
            taker: taker.wallet.pubkey(),
            asset_mint: self.asset_mint,
            buy_asset: true,
            usdc_amount: 10_010 * USDC,
            asset_amount: 50 * TOKEN,
            quote_id,
            expires_at: self.now() + 30,
        }
    }

    fn fill_quote(
        &mut self,
        taker: &User,
        maker: &Maker,
        signed: MakerQuote,
        sent: MakerQuote,
    ) -> Result<(), String> {
        let check = ed25519_ix(&maker.signing, &signed.signed_message().unwrap());
        let ix = self.quote_ix(taker, maker, sent);
        self.send(&[check, ix], &[&taker.wallet])
    }
}

struct User {
    wallet: Keypair,
    usdc: Pubkey,
    asset: Pubkey,
    shares: Pubkey,
}

struct Maker {
    user: User,
    signing: Keypair,
}

fn tier_a(requires_attestation: bool) -> MarketArgs {
    MarketArgs {
        requires_attestation,
        base_half_spread_bps: 10,
        max_skew_bps: 15,
        inventory_band_bps: 2_000,
        oracle_band_bps: 75,
        max_clip: 50_000 * USDC,
        daily_cap: 1_000_000 * USDC,
        tvl_cap: 10_000_000 * USDC,
    }
}

fn market_key(mint: Pubkey) -> Pubkey {
    pda(&[b"market", mint.as_ref()], &arcter_vault::ID)
}
fn feed_key(mint: Pubkey) -> Pubkey {
    pda(&[b"feed", mint.as_ref()], &arcter_oracle::ID)
}
fn reserve_key(market: Pubkey, mint: Pubkey) -> Pubkey {
    pda(&[b"reserve", market.as_ref(), mint.as_ref()], &arcter_vault::ID)
}
fn shares_key(market: Pubkey) -> Pubkey {
    pda(&[b"shares", market.as_ref()], &arcter_vault::ID)
}
fn attestation_key(wallet: Pubkey) -> Pubkey {
    pda(&[b"attestation", wallet.as_ref()], &arcter_access::ID)
}
fn maker_key(owner: Pubkey) -> Pubkey {
    pda(&[b"maker", owner.as_ref()], &arcter_rfq::ID)
}
fn inventory_key(owner: Pubkey, mint: Pubkey) -> Pubkey {
    pda(&[b"inventory", owner.as_ref(), mint.as_ref()], &arcter_rfq::ID)
}

/// Native Ed25519 instruction with every offset pointing inside itself.
fn ed25519_ix(signer: &Keypair, message: &[u8]) -> Instruction {
    ed25519_data(signer, message, u16::MAX)
}

fn ed25519_data(signer: &Keypair, message: &[u8], index: u16) -> Instruction {
    const HEADER: u16 = 16;
    let signature = signer.sign_message(message);
    let key_offset = HEADER;
    let signature_offset = key_offset + 32;
    let message_offset = signature_offset + 64;
    let mut data = vec![1u8, 0];
    for value in [
        signature_offset,
        index,
        key_offset,
        index,
        message_offset,
        message.len() as u16,
        index,
    ] {
        data.extend_from_slice(&value.to_le_bytes());
    }
    data.extend_from_slice(signer.pubkey().as_ref());
    data.extend_from_slice(signature.as_ref());
    data.extend_from_slice(message);
    Instruction {
        program_id: ED25519,
        accounts: vec![],
        data,
    }
}

fn expect_err(result: Result<(), String>, fragment: &str) {
    let logs = result.expect_err("the transaction should have failed");
    assert!(
        logs.contains(fragment),
        "expected '{fragment}' in logs:\n{logs}"
    );
}

#[test]
fn deposit_buy_sell_and_withdraw_match_the_formula() {
    let mut venue = Venue::new();
    let lp = venue.seed_vault();
    assert_eq!(venue.balance(lp.shares), 1_000_000 * USDC);

    let trader = venue.user(2_000 * USDC, 0);
    venue.buy(&trader, 1_000 * USDC, 1).unwrap();
    // The on-chain fill equals the pure formula, down to the raw unit.
    assert_eq!(venue.balance(trader.asset), 499_400_599);
    assert_eq!(venue.balance(trader.usdc), 1_000 * USDC);
    assert!(venue.balance(venue.treasury_usdc) > 200_000);

    // The vault's write to the Market survives the router's return. The router
    // holds the same account as writable and must not overwrite it.
    let data = venue.svm.get_account(&market_key(venue.asset_mint)).unwrap().data;
    let market = arcter_vault::Market::try_deserialize(&mut data.as_slice()).unwrap();
    assert_eq!(market.day_volume, 1_000 * USDC);

    venue.sell(&trader, 499_400_599, 1).unwrap();
    assert_eq!(venue.balance(trader.asset), 0);
    assert!(venue.balance(trader.usdc) < 2_000 * USDC);

    // Depositors keep the spread: a full exit returns more than was put in.
    let shares = venue.balance(lp.shares);
    venue.withdraw(&lp, shares).unwrap();
    let value = venue.balance(lp.usdc) as u128
        + math::asset_value(venue.balance(lp.asset), MID, 8, math::MULTIPLIER_ONE).unwrap();
    assert!(value > 1_000_000 * u128::from(USDC));
}

#[test]
fn minimum_output_and_expiry_protect_the_trader() {
    let mut venue = Venue::new();
    venue.seed_vault();
    let trader = venue.user(1_000 * USDC, 0);
    expect_err(venue.buy(&trader, 1_000 * USDC, u64::MAX), "SlippageExceeded");

    let args = SwapArgs {
        buy_asset: true,
        amount_in: 1_000 * USDC,
        min_amount_out: 1,
        expires_at: venue.now() - 1,
    };
    let ix = venue.swap_ix(&trader, args, false);
    expect_err(venue.send(&[ix], &[&trader.wallet]), "Expired");
    assert_eq!(venue.balance(trader.usdc), 1_000 * USDC);
}

#[test]
fn the_vault_refuses_callers_other_than_the_router() {
    let mut venue = Venue::new();
    venue.seed_vault();
    let attacker = venue.user(1_000 * USDC, 0);
    let market = market_key(venue.asset_mint);
    // The attacker cannot produce the router PDA's signature, so it signs itself.
    let ix = Instruction {
        program_id: arcter_vault::ID,
        accounts: arcter_vault::accounts::Fill {
            router_authority: attacker.wallet.pubkey(),
            trader: attacker.wallet.pubkey(),
            config: venue.config,
            market,
            feed: feed_key(venue.asset_mint),
            asset_mint: venue.asset_mint,
            usdc_mint: venue.usdc_mint,
            asset_reserve: reserve_key(market, venue.asset_mint),
            usdc_reserve: reserve_key(market, venue.usdc_mint),
            trader_asset: attacker.asset,
            trader_usdc: attacker.usdc,
            treasury_usdc: venue.treasury_usdc,
            asset_token_program: spl_token::ID,
            usdc_token_program: spl_token::ID,
        }
        .to_account_metas(None),
        data: arcter_vault::instruction::Fill {
            args: FillArgs {
                buy_asset: true,
                amount_in: 1_000 * USDC,
                min_amount_out: 1,
            },
        }
        .data(),
    };
    expect_err(venue.send(&[ix], &[&attacker.wallet]), "Unauthorized");
}

#[test]
fn a_closed_market_costs_three_times_as_much() {
    let mut open = Venue::new();
    open.seed_vault();
    let open_trader = open.user(1_000 * USDC, 0);
    open.buy(&open_trader, 1_000 * USDC, 1).unwrap();

    let mut closed = Venue::new();
    closed.seed_vault();
    closed.set_time(START + 60);
    closed.post(MID, Session::Closed).unwrap();
    let closed_trader = closed.user(1_000 * USDC, 0);
    closed.buy(&closed_trader, 1_000 * USDC, 1).unwrap();

    // 999.80 USDC at an ask of 200.60 instead of 200.20.
    assert_eq!(closed.balance(closed_trader.asset), 498_404_785);
    assert!(closed.balance(closed_trader.asset) < open.balance(open_trader.asset));

    // The clip halves too: 30,000 USDC fits when open but not when closed.
    let whale = closed.user(30_000 * USDC, 0);
    expect_err(closed.buy(&whale, 30_000 * USDC, 1), "ClipExceeded");
}

#[test]
fn halts_stop_trading_but_never_stop_withdrawals() {
    let mut venue = Venue::new();
    let lp = venue.seed_vault();
    let trader = venue.user(1_000 * USDC, 0);

    // Stale price.
    venue.set_time(START + 3_601);
    expect_err(venue.buy(&trader, 100 * USDC, 1), "MarketHalted");
    venue.post(MID, Session::Regular).unwrap();
    venue.buy(&trader, 100 * USDC, 1).unwrap();

    // Global pause.
    venue.set_paused(true);
    expect_err(venue.buy(&trader, 100 * USDC, 1), "TradingPaused");
    venue.withdraw(&lp, 100 * USDC).unwrap();
    venue.set_paused(false);

    // A 25% jump trips the guard until an admin clears it.
    venue.set_time(START + 3_700);
    venue.post(MID * 2, Session::Regular).unwrap();
    expect_err(venue.buy(&trader, 100 * USDC, 1), "MarketHalted");
    venue.withdraw(&lp, 100 * USDC).unwrap();
}

#[test]
fn sources_that_disagree_halt_the_market() {
    let mut venue = Venue::new();
    venue.seed_vault();
    let trader = venue.user(1_000 * USDC, 0);
    let publisher = venue.publisher.insecure_clone();
    let ix = Instruction {
        program_id: arcter_oracle::ID,
        accounts: arcter_oracle::accounts::PostReport {
            publisher: publisher.pubkey(),
            config: venue.config,
            feed: feed_key(venue.asset_mint),
        }
        .to_account_metas(None),
        data: arcter_oracle::instruction::PostCrosscheck {
            price: MID + MID / 50, // two percent away, band is 75 bps
            observed_at: venue.now(),
        }
        .data(),
    };
    venue.send(&[ix], &[&publisher]).unwrap();
    expect_err(venue.buy(&trader, 100 * USDC, 1), "MarketHalted");
}

#[test]
fn old_reports_cannot_replace_newer_ones() {
    let mut venue = Venue::new();
    venue.set_time(START + 100);
    venue.post(MID, Session::Regular).unwrap();
    let publisher = venue.publisher.insecure_clone();
    let ix = Instruction {
        program_id: arcter_oracle::ID,
        accounts: arcter_oracle::accounts::PostReport {
            publisher: publisher.pubkey(),
            config: venue.config,
            feed: feed_key(venue.asset_mint),
        }
        .to_account_metas(None),
        data: arcter_oracle::instruction::PostReport {
            args: ReportArgs {
                price: MID / 2,
                observed_at: START + 50,
                session: Session::Regular,
            },
        }
        .data(),
    };
    expect_err(venue.send(&[ix], &[&publisher]), "OutOfOrder");
}

#[test]
fn a_silent_network_triggers_the_restart_window() {
    let mut venue = Venue::new();
    venue.seed_vault();
    let trader = venue.user(1_000 * USDC, 0);

    // A silence past the gap halts trading, even with a fresh price.
    let after_gap = START + 86_401;
    venue.set_time(after_gap);
    venue.post(MID, Session::Closed).unwrap();
    expect_err(venue.buy(&trader, 100 * USDC, 1), "MarketHalted");

    let beat = Instruction {
        program_id: arcter_config::ID,
        accounts: arcter_config::accounts::Heartbeat {
            config: venue.config,
        }
        .to_account_metas(None),
        data: arcter_config::instruction::Heartbeat {}.data(),
    };
    let anyone = venue.user(0, 0);
    venue.send(&[beat.clone()], &[&anyone.wallet]).unwrap();
    assert_eq!(venue.config_account().grace_until, after_gap + 3_600);
    expect_err(venue.buy(&trader, 100 * USDC, 1), "MarketHalted");

    // Trading resumes once the hour has passed.
    venue.set_time(after_gap + 3_601);
    venue.post(MID, Session::Closed).unwrap();
    venue.send(&[beat], &[&anyone.wallet]).unwrap();
    venue.buy(&trader, 100 * USDC, 1).unwrap();
}

#[test]
fn permissioned_markets_need_an_attestation() {
    let mut venue = Venue::new();
    let admin = venue.admin.insecure_clone();
    let lp = venue.seed_vault();
    drop(lp);
    let ix = Instruction {
        program_id: arcter_vault::ID,
        accounts: arcter_vault::accounts::AdminMarket {
            admin: admin.pubkey(),
            config: venue.config,
            market: market_key(venue.asset_mint),
        }
        .to_account_metas(None),
        data: arcter_vault::instruction::UpdateMarket {
            args: tier_a(true),
        }
        .data(),
    };
    venue.send(&[ix], &[&admin]).unwrap();

    let trader = venue.user(1_000 * USDC, 0);
    expect_err(venue.buy(&trader, 100 * USDC, 1), "NotAttested");

    venue.attest(trader.wallet.pubkey(), ROLE_TRADER);
    let args = SwapArgs {
        buy_asset: true,
        amount_in: 100 * USDC,
        min_amount_out: 1,
        expires_at: venue.now() + 60,
    };
    let ix = venue.swap_ix(&trader, args, true);
    venue.send(&[ix], &[&trader.wallet]).unwrap();

    // Someone else's attestation does not help.
    let stranger = venue.user(1_000 * USDC, 0);
    let mut ix = venue.swap_ix(&stranger, args, true);
    let slot = arcter_router::accounts::SwapExactIn {
        trader: Pubkey::default(),
        router_authority: Pubkey::default(),
        config: Pubkey::default(),
        market: Pubkey::default(),
        attestation: Some(Pubkey::default()),
        feed: Pubkey::default(),
        asset_mint: Pubkey::default(),
        usdc_mint: Pubkey::default(),
        asset_reserve: Pubkey::default(),
        usdc_reserve: Pubkey::default(),
        trader_asset: Pubkey::default(),
        trader_usdc: Pubkey::default(),
        treasury_usdc: Pubkey::default(),
        asset_token_program: Pubkey::default(),
        usdc_token_program: Pubkey::default(),
        vault_program: Pubkey::default(),
    }
    .to_account_metas(None);
    assert_eq!(slot.len(), ix.accounts.len());
    ix.accounts[4] = AccountMeta::new_readonly(attestation_key(trader.wallet.pubkey()), false);
    expect_err(venue.send(&[ix], &[&stranger.wallet]), "NotAttested");
}

#[test]
fn deposits_need_the_lp_role() {
    let mut venue = Venue::new();
    let outsider = venue.user(1_000 * USDC, 0);
    venue.attest(outsider.wallet.pubkey(), ROLE_TRADER);
    expect_err(venue.deposit(&outsider, 1_000 * USDC, 0), "NotAttested");
}

#[test]
fn signed_quotes_settle_atomically_and_only_once() {
    let mut venue = Venue::new();
    venue.seed_vault();
    let maker = venue.maker();
    let taker = venue.user(20_100 * USDC, 0);

    let quote = venue.quote(&maker, &taker, 7);
    venue.fill_quote(&taker, &maker, quote, quote).unwrap();
    assert_eq!(venue.balance(taker.asset), 50 * TOKEN);
    // 10,010 USDC plus 2 bps paid to the treasury.
    assert_eq!(
        venue.balance(taker.usdc),
        20_100 * USDC - 10_010 * USDC - 2_002_000
    );
    let owner = maker.user.wallet.pubkey();
    assert_eq!(
        venue.balance(inventory_key(owner, venue.asset_mint)),
        450 * TOKEN
    );

    expect_err(
        venue.fill_quote(&taker, &maker, quote, quote),
        "already in use",
    );
}

#[test]
fn forged_quotes_are_rejected() {
    let mut venue = Venue::new();
    venue.seed_vault();
    let maker = venue.maker();
    let taker = venue.user(20_000 * USDC, 0);
    let honest = venue.quote(&maker, &taker, 1);

    // Better terms than the maker signed.
    let mut altered = honest;
    altered.usdc_amount = 10_000 * USDC;
    expect_err(
        venue.fill_quote(&taker, &maker, honest, altered),
        "SignatureMismatch",
    );

    // Signed by a key the maker never registered.
    let impostor = Keypair::new();
    let check = ed25519_ix(&impostor, &honest.signed_message().unwrap());
    let ix = venue.quote_ix(&taker, &maker, honest);
    expect_err(
        venue.send(&[check, ix], &[&taker.wallet]),
        "SignatureMismatch",
    );

    // No Ed25519 instruction at all.
    let ix = venue.quote_ix(&taker, &maker, honest);
    expect_err(venue.send(&[ix], &[&taker.wallet]), "SignatureMissing");

    // Ed25519 data that points at another instruction instead of itself.
    let spoof = ed25519_data(&maker.signing, &honest.signed_message().unwrap(), 1);
    let ix = venue.quote_ix(&taker, &maker, honest);
    assert!(venue.send(&[spoof, ix], &[&taker.wallet]).is_err());
}

#[test]
fn maker_quotes_obey_expiry_taker_band_and_cancels() {
    let mut venue = Venue::new();
    venue.seed_vault();
    let maker = venue.maker();
    let taker = venue.user(20_000 * USDC, 0);
    let stranger = venue.user(20_000 * USDC, 0);

    let quote = venue.quote(&maker, &taker, 1);
    expect_err(venue.fill_quote(&stranger, &maker, quote, quote), "WrongTaker");

    let mut pricey = venue.quote(&maker, &taker, 2);
    pricey.usdc_amount = 11_000 * USDC;
    expect_err(
        venue.fill_quote(&taker, &maker, pricey, pricey),
        "OutsideOracleBand",
    );

    let mut late = venue.quote(&maker, &taker, 3);
    late.expires_at = venue.now();
    expect_err(venue.fill_quote(&taker, &maker, late, late), "QuoteExpired");

    let owner = maker.user.wallet.pubkey();
    let cancel = Instruction {
        program_id: arcter_rfq::ID,
        accounts: arcter_rfq::accounts::MakerAction {
            owner,
            maker: maker_key(owner),
        }
        .to_account_metas(None),
        data: arcter_rfq::instruction::CancelQuotes { floor: 100 }.data(),
    };
    venue.send(&[cancel], &[&maker.user.wallet]).unwrap();
    let void = venue.quote(&maker, &taker, 99);
    expect_err(venue.fill_quote(&taker, &maker, void, void), "QuoteCancelled");
}

#[test]
fn a_two_leg_trade_unwinds_if_the_second_leg_fails() {
    let mut venue = Venue::new();
    venue.seed_vault();
    let seller = venue.user(0, 5 * TOKEN);
    let sell = SwapArgs {
        buy_asset: false,
        amount_in: 5 * TOKEN,
        min_amount_out: 1,
        expires_at: venue.now() + 60,
    };
    let impossible = SwapArgs {
        buy_asset: true,
        amount_in: 100 * USDC,
        min_amount_out: u64::MAX,
        expires_at: venue.now() + 60,
    };
    let first = venue.swap_ix(&seller, sell, false);
    let second = venue.swap_ix(&seller, impossible, false);
    expect_err(
        venue.send(&[first, second], &[&seller.wallet]),
        "SlippageExceeded",
    );
    assert_eq!(venue.balance(seller.asset), 5 * TOKEN);
    assert_eq!(venue.balance(seller.usdc), 0);
}

#[test]
fn the_time_lock_delays_changes() {
    let mut venue = Venue::new();
    let admin = venue.admin.insecure_clone();
    let queued = pda(&[b"change", &0u64.to_le_bytes()], &arcter_config::ID);
    let queue = Instruction {
        program_id: arcter_config::ID,
        accounts: arcter_config::accounts::QueueChange {
            admin: admin.pubkey(),
            config: venue.config,
            queued,
            system_program: system_program::ID,
        }
        .to_account_metas(None),
        data: arcter_config::instruction::QueueChange {
            change: ParamChange::SwapFee { bps: 5 },
            reason_hash: [9; 32],
        }
        .data(),
    };
    venue.send(&[queue], &[&admin]).unwrap();

    let apply = Instruction {
        program_id: arcter_config::ID,
        accounts: arcter_config::accounts::ApplyChange {
            admin: admin.pubkey(),
            config: venue.config,
            queued,
        }
        .to_account_metas(None),
        data: arcter_config::instruction::ApplyChange {}.data(),
    };
    let anyone = venue.user(0, 0);
    expect_err(
        venue.send(&[apply.clone()], &[&anyone.wallet]),
        "DelayNotElapsed",
    );
    venue.set_time(START + 3_601);
    venue.send(&[apply], &[&anyone.wallet]).unwrap();
    assert_eq!(venue.config_account().swap_fee_bps, 5);
}

#[test]
fn out_of_range_settings_cannot_be_queued() {
    let mut venue = Venue::new();
    let admin = venue.admin.insecure_clone();
    let queue = Instruction {
        program_id: arcter_config::ID,
        accounts: arcter_config::accounts::QueueChange {
            admin: admin.pubkey(),
            config: venue.config,
            queued: pda(&[b"change", &0u64.to_le_bytes()], &arcter_config::ID),
            system_program: system_program::ID,
        }
        .to_account_metas(None),
        data: arcter_config::instruction::QueueChange {
            change: ParamChange::SwapFee { bps: 5_000 },
            reason_hash: [0; 32],
        }
        .data(),
    };
    expect_err(venue.send(&[queue], &[&admin]), "InvalidValue");
}

#[test]
fn token_2022_scaled_balances_are_priced_after_the_multiplier() {
    // A two for one split: each raw unit is worth two scaled units.
    let mut venue = Venue::with_asset(spl_token_2022::ID, Some(2.0));
    let lp = venue.user(500_000 * USDC, 1_250 * TOKEN);
    venue.attest(lp.wallet.pubkey(), ROLE_LP);
    venue.deposit(&lp, 500_000 * USDC, 1_250 * TOKEN).unwrap();
    // 1,250 raw tokens at 2x and a mid of 200 are worth 500,000 USDC.
    assert_eq!(venue.balance(lp.shares), 1_000_000 * USDC);

    let trader = venue.user(1_000 * USDC, 0);
    venue.buy(&trader, 1_000 * USDC, 1).unwrap();
    assert_eq!(venue.balance(trader.asset), 499_400_599 / 2);
}

#[test]
fn mints_with_a_transfer_hook_are_refused_at_listing() {
    let mut venue = Venue::new();
    let hooked = venue.create_mint(spl_token_2022::ID, 8, None, true);
    expect_err(
        venue.list_market(hooked, spl_token_2022::ID, false),
        "UnsupportedMint",
    );
}

#[test]
fn only_the_admin_can_list_or_retire_markets() {
    let mut venue = Venue::new();
    let lp = venue.seed_vault();
    let attacker = venue.user(0, 0);
    let ix = Instruction {
        program_id: arcter_vault::ID,
        accounts: arcter_vault::accounts::AdminMarket {
            admin: attacker.wallet.pubkey(),
            config: venue.config,
            market: market_key(venue.asset_mint),
        }
        .to_account_metas(None),
        data: arcter_vault::instruction::RetireMarket {}.data(),
    };
    expect_err(venue.send(&[ix], &[&attacker.wallet]), "Unauthorized");

    // A retired market trades no more, and depositors can still leave.
    let admin = venue.admin.insecure_clone();
    let ix = Instruction {
        program_id: arcter_vault::ID,
        accounts: arcter_vault::accounts::AdminMarket {
            admin: admin.pubkey(),
            config: venue.config,
            market: market_key(venue.asset_mint),
        }
        .to_account_metas(None),
        data: arcter_vault::instruction::RetireMarket {}.data(),
    };
    venue.send(&[ix], &[&admin]).unwrap();
    let trader = venue.user(1_000 * USDC, 0);
    expect_err(venue.buy(&trader, 100 * USDC, 1), "MarketRetired");
    let shares = venue.balance(lp.shares);
    venue.withdraw(&lp, shares).unwrap();
    assert_eq!(venue.balance(lp.shares), 0);
}
