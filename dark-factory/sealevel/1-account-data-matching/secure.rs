//! coral-xyz/sealevel-attacks — lesson 1, account-data-matching (SECURE).
//! Modernized verbatim from upstream anchor-lang 0.20.0 to 0.31. The fix: the handler
//! asserts `authority.key == token.owner` before trusting the token account, so a signer
//! cannot read a token account that is not theirs. The auditor MUST NOT report the
//! account-data-matching exploit as VERIFIED here.
use anchor_lang::prelude::*;
use anchor_lang::solana_program::program_error::ProgramError;
use anchor_lang::solana_program::program_pack::Pack;
use spl_token::state::Account as SplTokenAccount;

declare_id!("Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS");

#[program]
pub mod account_data_matching_secure {
    use super::*;

    pub fn log_message(ctx: Context<LogMessage>) -> Result<()> {
        let token = SplTokenAccount::unpack(&ctx.accounts.token.data.borrow())?;
        if ctx.accounts.authority.key != &token.owner {
            return Err(ProgramError::InvalidAccountData.into());
        }
        msg!("Your account balance is: {}", token.amount);
        Ok(())
    }
}

#[derive(Accounts)]
pub struct LogMessage<'info> {
    /// CHECK: validated in the handler against `authority` via `authority.key == token.owner`.
    token: AccountInfo<'info>,
    authority: Signer<'info>,
}
