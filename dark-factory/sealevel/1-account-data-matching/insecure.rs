//! coral-xyz/sealevel-attacks — lesson 1, account-data-matching (INSECURE).
//! Modernized verbatim from the upstream anchor-lang 0.20.0 source to anchor-lang 0.31
//! (`ProgramResult` -> `Result<()>`, `ProgramError -> .into()`, the anchor>=0.24 `/// CHECK:`
//! doc). The vulnerability is untouched: the handler reads + logs a token account's data
//! WITHOUT verifying that account belongs to `authority` (no `authority.key == token.owner`
//! check), so any signer can read any token account's balance.
use anchor_lang::prelude::*;
use anchor_lang::solana_program::program_pack::Pack;
use spl_token::state::Account as SplTokenAccount;

declare_id!("Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS");

#[program]
pub mod account_data_matching_insecure {
    use super::*;

    pub fn log_message(ctx: Context<LogMessage>) -> Result<()> {
        let token = SplTokenAccount::unpack(&ctx.accounts.token.data.borrow())?;
        msg!("Your account balance is: {}", token.amount);
        Ok(())
    }
}

#[derive(Accounts)]
pub struct LogMessage<'info> {
    /// CHECK: VULNERABILITY — the token account's data is read without checking that its
    /// stored owner matches `authority`. A correct program asserts `authority.key == token.owner`.
    token: AccountInfo<'info>,
    authority: Signer<'info>,
}
