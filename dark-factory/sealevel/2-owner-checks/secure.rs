//! coral-xyz/sealevel-attacks — lesson 2, owner-checks (SECURE).
//! Modernized verbatim from upstream anchor-lang 0.20.0 to 0.31. The fix: the handler
//! first verifies the account is owned by the SPL Token program before trusting its data,
//! then checks `authority.key == token.owner`. A forged account owned by another program
//! is rejected. The auditor MUST NOT report the owner-confusion exploit as VERIFIED here.
use anchor_lang::prelude::*;
use anchor_lang::solana_program::program_error::ProgramError;
use anchor_lang::solana_program::program_pack::Pack;
use spl_token::state::Account as SplTokenAccount;

declare_id!("Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS");

#[program]
pub mod owner_checks_secure {
    use super::*;

    pub fn log_message(ctx: Context<LogMessage>) -> Result<()> {
        if ctx.accounts.token.owner != &spl_token::ID {
            return Err(ProgramError::InvalidAccountData.into());
        }
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
    /// CHECK: validated in the handler — must be owned by the SPL Token program and its
    /// stored owner must equal `authority`.
    token: AccountInfo<'info>,
    authority: Signer<'info>,
}
