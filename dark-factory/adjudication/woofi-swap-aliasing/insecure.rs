//! WOOFi swap quote-pool aliasing — INSECURE target (agentis-core issue #857, backtest #3 wildcard).
//!
//! Minimal faithful reproduction of the 3/3-converged High in WOOFi's `swap.rs`: on a
//! base<->quote trade the QUOTE pool is passed into TWO mutable account slots of the same
//! instruction (`woopool_to`/`woopool_from` AND `woopool_quote` — the same canonical PDA).
//! Each Anchor `Account<'info, Pool>` deserializes an INDEPENDENT in-memory copy; the handler
//! mutates each through its own slot reference; at exit Anchor serializes them back in
//! DECLARATION ORDER, so the last-declared copy clobbers the earlier copy's mutation. One
//! `reserve` update is silently discarded and the pool reserve desyncs from the vault.
//!
//! There is NO duplicate-account guard — `pool_to` and `pool_quote` may alias. That is the bug.
//!
//! Anchor version note: WOOFi shipped on 0.29; this harness pins 0.31 (strictly newer, only
//! adds safety checks). The reproduction under 0.31 is therefore conservative.
use anchor_lang::prelude::*;

declare_id!("Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS");

#[program]
pub mod woofi_swap_aliasing_insecure {
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
    // VULNERABILITY: no `constraint = pool_quote.key() != pool_to.key()` — the quote pool
    // can alias `pool_to`, and the `pool_to` reserve write is then silently lost at exit.
    #[account(mut)]
    pub pool_quote: Account<'info, Pool>,
}

#[account]
pub struct Pool {
    pub reserve: u64,
}
