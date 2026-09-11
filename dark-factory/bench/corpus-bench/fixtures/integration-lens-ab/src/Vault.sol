// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// A minimal EXTERNAL-INTEGRATION vault fixture for the #2191 INTEGRATION_LENS A/B self-test. It reads a price
// from an external oracle and deposits into an external pool with a hardcoded `true` flag, then mints shares
// off that trusted price -- the external-integration/oracle-assumption shape the #2191 detector fires on
// (call surface + valuation read + hardcoded call arg). Generic shapes, no protocol name.

interface IOracle {
    function getPrice() external view returns (uint256);
}

interface IPool {
    function deposit(uint256 assets, bool useReserve) external returns (uint256);
}

contract Vault {
    IOracle public immutable oracle;
    address public immutable pool;

    mapping(address => uint256) public shares;

    constructor(IOracle o, address p) {
        oracle = o;
        pool = p;
    }

    // Mints shares against a trusted external price and a pool deposit with a hardcoded reserve flag. The
    // permissionless assumption (the oracle price / pool return is honest) is what the #2191 directive names.
    function deposit(uint256 assets) external {
        uint256 px = oracle.getPrice();
        uint256 minted = IPool(pool).deposit(assets, true);
        shares[msg.sender] = shares[msg.sender] + minted * px;
    }
}
