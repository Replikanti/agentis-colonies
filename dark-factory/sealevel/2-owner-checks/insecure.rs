//! coral-xyz/sealevel-attacks — lesson 2, owner-checks (INSECURE).
//! Modernized verbatim from upstream anchor-lang 0.20.0 to 0.31. The vulnerability is
//! untouched: the handler unpacks the token account and checks `authority.key ==
//! token.owner`, but NEVER verifies the account is actually owned by the SPL Token program.
//! An attacker passes a fake account (owned by their own program) carrying forged token
//! bytes whose `owner` field equals `authority`, and the check passes.
use anchor_lang::prelude::*;
use anchor_lang::solana_program::program_error::ProgramError;
use anchor_lang::solana_program::program_pack::Pack;
use spl_token::state::Account as SplTokenAccount;

declare_id!("Fg6PaFpoGXkYsidMpWTK6W2BeZ7FEfcYkg476zPFsLnS");

#[program]
pub mod owner_checks_insecure {
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
    /// CHECK: VULNERABILITY — the account is never verified to be owned by the SPL Token
    /// program (`token.to_account_info().owner == &spl_token::ID`), so a fake account with
    /// forged data is accepted.
    token: AccountInfo<'info>,
    authority: Signer<'info>,
}
