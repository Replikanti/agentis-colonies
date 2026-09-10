// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2171 negative arm (SCOPE via TRANSITIVE interface chain), the #2176 review path 1: the callee address (`oracle`)
// IS settable, and the vault casts to `IOracle`. No contract implements `IOracle` DIRECTLY, but an in-scope
// interface EXTENDS it (`interface IOracleV2 is IOracle`) and an in-scope contract implements that
// (`contract ChainImpl is IOracleV2`) — so an in-scope, drivable type carries IOracle. A resolver that only
// looked for `contract <Name> is ... IOracle` would miss the interface carrier and fabricate a stub. Recognizing
// `interface` headers as carriers keeps the callee IN-scope and stub_eligible = 0.

interface IOracle {
    function price() external view returns (uint256);
}

interface IOracleV2 is IOracle {
    function extra() external;
}

contract ChainImpl is IOracleV2 {
    function price() external pure returns (uint256) {
        return 1;
    }
    function extra() external {}
}

contract TransitiveImplCalleeVault {
    address public owner;
    address public oracle;
    mapping(address => uint256) public shares;

    constructor(address o) {
        owner = msg.sender;
        oracle = o;
    }

    function setOracle(address newOracle) external {
        require(msg.sender == owner, "only owner");
        oracle = newOracle;
    }

    function deposit(uint256 amount) external returns (uint256 minted) {
        uint256 p = IOracle(oracle).price();
        minted = amount * p;
        shares[msg.sender] = shares[msg.sender] + minted;
    }
}
