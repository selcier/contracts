//! Quote arithmetic for oracle-centered vaults.
//!
//! Pure functions with no account access, so a client can reproduce any fill
//! from public inputs. Amounts are raw token units. `mid` is USDC raw units per
//! one whole scaled token, and `multiplier_e9` maps raw balances to scaled ones.

pub const BPS: u128 = 10_000;
pub const TARGET_RATIO_BPS: u128 = 5_000;
pub const MULTIPLIER_ONE: u128 = 1_000_000_000;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QuoteFailure {
    ZeroAmount,
    NoLiquidity,
    OutsideOracleBand,
    ClipExceeded,
    DailyCapExceeded,
    InsufficientInventory,
    InventoryBandExceeded,
    Overflow,
}

#[derive(Clone, Copy, Debug)]
pub struct Tier {
    pub base_half_spread_bps: u16,
    pub max_skew_bps: u16,
    pub inventory_band_bps: u16,
    pub oracle_band_bps: u16,
    pub max_clip: u64,
    pub daily_cap: u64,
}

#[derive(Clone, Copy, Debug)]
pub struct QuoteInputs {
    pub tier: Tier,
    /// Regime multipliers, 10,000 meaning 1.0.
    pub spread_multiplier_bps: u16,
    pub clip_multiplier_bps: u16,
    pub fee_bps: u16,
    pub spread_share_bps: u16,
    pub mid: u64,
    pub asset_decimals: u8,
    pub multiplier_e9: u128,
    pub usdc_reserve: u64,
    pub asset_reserve: u64,
    pub used_daily_volume: u64,
    /// True when the trader pays USDC and receives the asset.
    pub buy_asset: bool,
    pub amount_in: u64,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Quote {
    pub amount_out: u64,
    /// Order size in USDC, valued at the mid.
    pub notional: u64,
    pub fee: u64,
    /// Captured spread sent to the treasury.
    pub protocol_spread: u64,
    pub half_spread_bps: u16,
    pub skew_bps: i16,
}

type Calc<T> = Result<T, QuoteFailure>;

fn pow10(decimals: u8) -> Calc<u128> {
    10u128
        .checked_pow(u32::from(decimals))
        .ok_or(QuoteFailure::Overflow)
}

fn mul_div(a: u128, b: u128, divisor: u128) -> Calc<u128> {
    if divisor == 0 {
        return Err(QuoteFailure::Overflow);
    }
    Ok(a.checked_mul(b).ok_or(QuoteFailure::Overflow)? / divisor)
}

fn to_u64(value: u128) -> Calc<u64> {
    u64::try_from(value).map_err(|_| QuoteFailure::Overflow)
}

/// USDC value of a raw asset amount at the mid, rounded down.
pub fn asset_value(raw: u64, mid: u64, decimals: u8, multiplier_e9: u128) -> Calc<u128> {
    let scaled = mul_div(u128::from(raw), multiplier_e9, MULTIPLIER_ONE)?;
    mul_div(scaled, u128::from(mid), pow10(decimals)?)
}

/// Raw asset units bought by `usdc` at `price`, rounded down in the vault's favor.
fn raw_for_value(usdc: u128, price: u128, decimals: u8, multiplier_e9: u128) -> Calc<u128> {
    let scaled = mul_div(usdc, pow10(decimals)?, price)?;
    mul_div(scaled, MULTIPLIER_ONE, multiplier_e9)
}

/// Signed distance of the inventory from its target, capped at `max_skew_bps`.
/// Positive means the vault holds too much of the asset.
pub fn skew_bps(asset_value: u128, total: u128, tier: &Tier) -> Calc<i128> {
    if total == 0 {
        return Err(QuoteFailure::NoLiquidity);
    }
    let ratio = mul_div(asset_value, BPS, total)? as i128;
    let drift = ratio - TARGET_RATIO_BPS as i128;
    let max_skew = i128::from(tier.max_skew_bps);
    let band = i128::from(tier.inventory_band_bps).max(1);
    Ok((max_skew * drift / band).clamp(-max_skew, max_skew))
}

fn drift_bps(asset_value: u128, total: u128) -> Calc<u128> {
    if total == 0 {
        return Err(QuoteFailure::NoLiquidity);
    }
    Ok(mul_div(asset_value, BPS, total)?.abs_diff(TARGET_RATIO_BPS))
}

/// Applies the full quote sequence: regime-scaled spread, inventory skew, fee,
/// then the band, clip, daily cap, inventory and reserve checks.
pub fn quote_fill(input: &QuoteInputs) -> Calc<Quote> {
    if input.amount_in == 0 {
        return Err(QuoteFailure::ZeroAmount);
    }
    let tier = input.tier;
    let mid = u128::from(input.mid);
    let usdc_reserve = u128::from(input.usdc_reserve);
    let asset_val = asset_value(
        input.asset_reserve,
        input.mid,
        input.asset_decimals,
        input.multiplier_e9,
    )?;
    let total = usdc_reserve + asset_val;
    if total == 0 {
        return Err(QuoteFailure::NoLiquidity);
    }

    let skew = skew_bps(asset_val, total, &tier)?;
    let base = i128::from(tier.base_half_spread_bps) * i128::from(input.spread_multiplier_bps)
        / BPS as i128;
    // Buying from a vault long the asset gets cheaper and selling to it pays
    // less. The floor stops the corrective side from crossing the mid.
    let half = (base + if input.buy_asset { -skew } else { skew }).max(0) as u128;
    if half + u128::from(input.fee_bps) > u128::from(tier.oracle_band_bps) {
        return Err(QuoteFailure::OutsideOracleBand);
    }

    let notional = if input.buy_asset {
        u128::from(input.amount_in)
    } else {
        asset_value(
            input.amount_in,
            input.mid,
            input.asset_decimals,
            input.multiplier_e9,
        )?
    };
    let clip = mul_div(
        u128::from(tier.max_clip),
        u128::from(input.clip_multiplier_bps),
        BPS,
    )?;
    if notional > clip {
        return Err(QuoteFailure::ClipExceeded);
    }
    if u128::from(input.used_daily_volume) + notional > u128::from(tier.daily_cap) {
        return Err(QuoteFailure::DailyCapExceeded);
    }

    let fee_bps = u128::from(input.fee_bps);
    let share_bps = u128::from(input.spread_share_bps);
    let (amount_out, fee, protocol_spread, new_usdc, new_asset_value);

    if input.buy_asset {
        let amount_in = u128::from(input.amount_in);
        let charged_fee = mul_div(amount_in, fee_bps, BPS)?;
        let net = amount_in - charged_fee;
        let ask = mul_div(mid, BPS + half, BPS)?;
        let out = raw_for_value(net, ask, input.asset_decimals, input.multiplier_e9)?;
        if out > u128::from(input.asset_reserve) {
            return Err(QuoteFailure::InsufficientInventory);
        }
        let out_value = asset_value(
            to_u64(out)?,
            input.mid,
            input.asset_decimals,
            input.multiplier_e9,
        )?;
        let spread = mul_div(net.saturating_sub(out_value), share_bps, BPS)?;
        amount_out = out;
        fee = charged_fee;
        protocol_spread = spread;
        new_usdc = usdc_reserve + amount_in - charged_fee - spread;
        new_asset_value = asset_val.saturating_sub(out_value);
    } else {
        let bid = mul_div(mid, BPS - half, BPS)?;
        let scaled = mul_div(
            u128::from(input.amount_in),
            input.multiplier_e9,
            MULTIPLIER_ONE,
        )?;
        let gross = mul_div(scaled, bid, pow10(input.asset_decimals)?)?;
        let charged_fee = mul_div(gross, fee_bps, BPS)?;
        let spread = mul_div(notional.saturating_sub(gross), share_bps, BPS)?;
        if gross + spread > usdc_reserve {
            return Err(QuoteFailure::InsufficientInventory);
        }
        amount_out = gross - charged_fee;
        fee = charged_fee;
        protocol_spread = spread;
        new_usdc = usdc_reserve - gross - spread;
        new_asset_value = asset_val + notional;
    }

    // Outside the band only the side that shrinks the drift may fill, so normal
    // flow repairs the vault without any manual step.
    let drift_after = drift_bps(new_asset_value, new_usdc + new_asset_value)?;
    let drift_before = drift_bps(asset_val, total)?;
    if drift_after > u128::from(tier.inventory_band_bps) && drift_after >= drift_before {
        return Err(QuoteFailure::InventoryBandExceeded);
    }

    Ok(Quote {
        amount_out: to_u64(amount_out)?,
        notional: to_u64(notional)?,
        fee: to_u64(fee)?,
        protocol_spread: to_u64(protocol_spread)?,
        half_spread_bps: u16::try_from(half).map_err(|_| QuoteFailure::Overflow)?,
        skew_bps: i16::try_from(skew).map_err(|_| QuoteFailure::Overflow)?,
    })
}

/// Shares owed for a deposit worth `value`, given current supply and total value.
pub fn shares_for_deposit(value: u128, supply: u64, total_value: u128) -> Calc<u64> {
    if supply == 0 {
        return to_u64(value);
    }
    if total_value == 0 {
        return Err(QuoteFailure::NoLiquidity);
    }
    to_u64(mul_div(value, u128::from(supply), total_value)?)
}

/// Pro rata slice of a reserve for `shares` out of `supply`, rounded down.
pub fn pro_rata(reserve: u64, shares: u64, supply: u64) -> Calc<u64> {
    if supply == 0 {
        return Ok(0);
    }
    to_u64(mul_div(
        u128::from(reserve),
        u128::from(shares),
        u128::from(supply),
    )?)
}

/// True when a maker's price sits within `band_bps` of the mid. A maker quote
/// fails if its price is outside the band in either direction.
pub fn within_band(
    usdc_amount: u64,
    asset_amount: u64,
    mid: u64,
    decimals: u8,
    multiplier_e9: u128,
    band_bps: u16,
) -> Calc<bool> {
    let value_at_mid = asset_value(asset_amount, mid, decimals, multiplier_e9)?;
    if value_at_mid == 0 {
        return Err(QuoteFailure::ZeroAmount);
    }
    let difference = value_at_mid.abs_diff(u128::from(usdc_amount));
    Ok(mul_div(difference, BPS, value_at_mid)? <= u128::from(band_bps))
}

#[cfg(test)]
mod tests {
    use super::*;

    const USDC: u64 = 1_000_000;
    const TOKEN: u64 = 100_000_000; // eight decimals

    fn tier_a() -> Tier {
        Tier {
            base_half_spread_bps: 10,
            max_skew_bps: 15,
            inventory_band_bps: 2_000,
            oracle_band_bps: 75,
            max_clip: 50_000 * USDC,
            daily_cap: 1_000_000 * USDC,
        }
    }

    /// Balanced vault holding 500,000 USDC against 2,500 tokens at a mid of 200.
    fn inputs(buy_asset: bool, amount_in: u64) -> QuoteInputs {
        QuoteInputs {
            tier: tier_a(),
            spread_multiplier_bps: 10_000,
            clip_multiplier_bps: 10_000,
            fee_bps: 2,
            spread_share_bps: 1_000,
            mid: 200 * USDC,
            asset_decimals: 8,
            multiplier_e9: MULTIPLIER_ONE,
            usdc_reserve: 500_000 * USDC,
            asset_reserve: 2_500 * TOKEN,
            used_daily_volume: 0,
            buy_asset,
            amount_in,
        }
    }

    #[test]
    fn balanced_buy_pays_half_spread_and_fee() {
        let quote = quote_fill(&inputs(true, 1_000 * USDC)).unwrap();
        assert_eq!(quote.skew_bps, 0);
        assert_eq!(quote.half_spread_bps, 10);
        assert_eq!(quote.fee, 200_000); // 2 bps of 1,000 USDC
        // 999.80 USDC net at an ask of 200.20 buys about 4.9940 tokens.
        assert_eq!(quote.amount_out, 499_400_599);
    }

    #[test]
    fn balanced_sell_pays_half_spread_and_fee() {
        let quote = quote_fill(&inputs(false, 5 * TOKEN)).unwrap();
        assert_eq!(quote.notional, 1_000 * USDC);
        // 1,000 at 10 bps is 999.00 gross, then 2 bps comes off as the fee.
        assert_eq!(quote.fee, 199_800);
        assert_eq!(quote.amount_out, 998_800_200);
        // A tenth of the 1 USDC captured goes to the treasury.
        assert_eq!(quote.protocol_spread, 100_000);
    }

    #[test]
    fn closed_regime_triples_spread_and_halves_clip() {
        let mut input = inputs(true, 30_000 * USDC);
        input.spread_multiplier_bps = 30_000;
        input.clip_multiplier_bps = 5_000;
        assert_eq!(quote_fill(&input), Err(QuoteFailure::ClipExceeded));
        input.amount_in = 20_000 * USDC;
        assert_eq!(quote_fill(&input).unwrap().half_spread_bps, 30);
    }

    #[test]
    fn long_vault_cheapens_buys_and_worsens_sells() {
        let mut long = inputs(true, 1_000 * USDC);
        long.usdc_reserve = 400_000 * USDC;
        long.asset_reserve = 3_000 * TOKEN; // 60% asset, half the band
        let buy = quote_fill(&long).unwrap();
        assert_eq!(buy.skew_bps, 7);
        assert_eq!(buy.half_spread_bps, 3);

        long.buy_asset = false;
        long.amount_in = 5 * TOKEN;
        assert_eq!(quote_fill(&long).unwrap().half_spread_bps, 17);
    }

    #[test]
    fn half_spread_floors_at_zero() {
        let mut input = inputs(true, 1_000 * USDC);
        input.usdc_reserve = 300_000 * USDC;
        input.asset_reserve = 3_500 * TOKEN; // skew pinned at 15 bps
        assert_eq!(quote_fill(&input).unwrap().half_spread_bps, 0);
    }

    #[test]
    fn harmful_side_stops_at_the_band_edge() {
        let mut input = inputs(false, 5 * TOKEN);
        input.usdc_reserve = 300_000 * USDC;
        input.asset_reserve = 3_500 * TOKEN; // already at 70%
        assert_eq!(
            quote_fill(&input),
            Err(QuoteFailure::InventoryBandExceeded)
        );
        // The corrective side still fills.
        input.buy_asset = true;
        input.amount_in = 1_000 * USDC;
        assert!(quote_fill(&input).is_ok());
    }

    #[test]
    fn multiplier_scales_value_and_output() {
        let mut input = inputs(true, 1_000 * USDC);
        input.multiplier_e9 = 2 * MULTIPLIER_ONE; // two for one split
        input.asset_reserve = 1_250 * TOKEN;
        let quote = quote_fill(&input).unwrap();
        assert_eq!(quote.skew_bps, 0);
        // Half the raw units of the unsplit case, as each now shows as two.
        assert_eq!(quote.amount_out, 499_400_599 / 2);
    }

    #[test]
    fn daily_cap_and_zero_amount_are_refused() {
        let mut input = inputs(true, 1_000 * USDC);
        input.used_daily_volume = 999_500 * USDC;
        assert_eq!(quote_fill(&input), Err(QuoteFailure::DailyCapExceeded));
        input.amount_in = 0;
        assert_eq!(quote_fill(&input), Err(QuoteFailure::ZeroAmount));
    }

    #[test]
    fn empty_vault_has_no_quote() {
        let mut input = inputs(true, 1_000 * USDC);
        input.usdc_reserve = 0;
        input.asset_reserve = 0;
        assert_eq!(quote_fill(&input), Err(QuoteFailure::NoLiquidity));
    }

    #[test]
    fn share_math_is_pro_rata() {
        assert_eq!(shares_for_deposit(1_000, 0, 0).unwrap(), 1_000);
        assert_eq!(shares_for_deposit(500, 1_000, 2_000).unwrap(), 250);
        assert_eq!(pro_rata(9_000, 250, 1_000).unwrap(), 2_250);
        assert_eq!(pro_rata(9_000, 1, 0).unwrap(), 0);
    }

    #[test]
    fn maker_band_rejects_prices_on_either_side() {
        let (asset, mid) = (5 * TOKEN, 200 * USDC); // worth 1,000 USDC
        let check = |usdc| within_band(usdc, asset, mid, 8, MULTIPLIER_ONE, 75).unwrap();
        assert!(check(1_000 * USDC));
        assert!(check(1_007 * USDC));
        assert!(!check(1_010 * USDC));
        assert!(!check(990 * USDC));
    }
}
