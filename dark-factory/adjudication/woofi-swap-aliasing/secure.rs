//! WOOFi swap quote-pool aliasing — SECURE variant (the fix).
//!
//! The fix is a duplicate-account guard: `pool_quote` must NOT alias `pool_to`. With the
//! constraint in place the exploit transaction (same PDA in both slots) is rejected at
//! account validation, so no reserve update is ever lost. The auditor MUST NOT report the
//! aliasing exploit as VERIFIED against this variant — it is the control that proves the
//! two-sided gate is not a rigged always-fire harness.
//!
//! (WOOFi's real remediation also splits the quote pool's two roles or reloads the account
//! between the two writes; the explicit `constraint` here is the smallest sound fix.)
use anchor_lang::prelude::*;

declare_id!("Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS");

#[program]
pub mod woofi_swap_aliasing_secure {
    use super::*;

    pub fn swap(ctx: Context<Swap>, base_in: u64, quote_out: u64, fee: u64) -> Result<()> {
        ctx.accounts.pool_from.reserve =
            ctx.accounts.pool_from.reserve.checked_add(base_in).unwrap();
        ctx.accounts.pool_to.reserve =
            ctx.accounts.pool_to.reserve.checked_sub(quote_out).unwrap();
        ctx.accounts.pool_quote.reserve =
            ctx.accounts.pool_quote.reserve.checked_add(fee).unwrap();
        Ok(())
    }
}

#[derive(Accounts)]
pub struct Swap<'info> {
    #[account(mut)]
    pub pool_from: Account<'info, Pool>,
    #[account(mut)]
    pub pool_to: Account<'info, Pool>,
    // FIX: reject the aliasing — the quote pool may not be the same account as `pool_to`,
    // so no reserve write can be silently overwritten at exit.
    #[account(mut, constraint = pool_quote.key() != pool_to.key())]
    pub pool_quote: Account<'info, Pool>,
}

#[account]
pub struct Pool {
    pub reserve: u64,
}
