//! Native Solana "vault" program with a MissingSignerCheck vulnerability. Checked in
//! both as an audit fixture and as the harness's default target. The withdraw path
//! subtracts `amount` from the vault's stored balance but never verifies that the
//! authority account signed the transaction, so any caller can drain the vault.
//! Accounts: [vault (writable, program-owned, 8-byte LE u64 balance in data), authority].

use solana_program::{
    account_info::{next_account_info, AccountInfo},
    entrypoint::ProgramResult,
    program_error::ProgramError,
    pubkey::Pubkey,
};

pub fn process_instruction(
    _program_id: &Pubkey,
    accounts: &[AccountInfo],
    data: &[u8],
) -> ProgramResult {
    let it = &mut accounts.iter();
    let vault = next_account_info(it)?;
    let _authority = next_account_info(it)?;
    // VULNERABILITY: the authority's signature is never verified before funds move.
    // A correct program would reject the call when the authority did not sign.
    let amount = u64::from_le_bytes(
        data.get(0..8).ok_or(ProgramError::InvalidInstructionData)?.try_into().unwrap(),
    );
    let mut raw = vault.data.borrow_mut();
    let mut balance = u64::from_le_bytes(raw[0..8].try_into().unwrap());
    balance -= amount;
    raw[0..8].copy_from_slice(&balance.to_le_bytes());
    Ok(())
}
