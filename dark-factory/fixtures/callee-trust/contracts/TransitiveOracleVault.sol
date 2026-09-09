// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2150 fixture: the #2145 detector reached THROUGH the slicer's same-file callee closure.
//
// Same trust question as SettableOracleVault.sol, moved one call-graph hop away from the entry point. The
// only externally callable member does no external call itself: it hands off to an internal helper, and
// that helper is where the vault pokes an oracle whose address it resolves through the config contract at
// call time (a computed target — whoever owns the config decides what code runs).
//
// The zone this fixture stands for is scoped as `<file>@deposit`: the helper is NOT requested. Before #2150
// the slice was the contract header plus `deposit` alone, which contains no external call at all, so
// hunter.ag's attacker-controlled-callee detector saw no call surface and stayed silent — a false negative
// caused entirely by the PAYLOAD, not by the detector. With the closure the helper travels with `deposit`
// and the detector fires with exactly ONE settable-target signal (the computed target; there is deliberately
// no setter and no mutable address state variable here, so the OTHER two signals cannot mask the result).
//
// This file therefore only ever produces a CALLEE-TRUST| sentinel if the closure works.
//
// NOTE for editors: the word that introduces a Solidity member must not appear followed by a space anywhere
// in this comment block — the slicer ends the header at the first line that looks like a definition.

interface IOracle {
    function poke() external;
}

interface IConfig {
    function getOracle() external view returns (address);
}

contract TransitiveOracleVault {
    IConfig public immutable cfg;

    mapping(address => uint256) public balanceOf;

    constructor(address configAddress) {
        cfg = IConfig(configAddress);
    }

    function deposit(uint256 amount) external {
        _settleOracle();
        balanceOf[msg.sender] = balanceOf[msg.sender] + amount;
    }

    function _settleOracle() internal {
        IOracle(cfg.getOracle()).poke();
    }
}
