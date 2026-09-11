// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.20;

// #2191 fixture (positive arm) for hunter.ag's external-integration/oracle-assumption detector.
//
// The vault reads a price from an external oracle and deposits into an external pool with a hardcoded `true`
// flag, then mints shares off that trusted price. MUST trip has_external_integration_surface():
//   - has_call_surface(): the interface-typed call `IPool(pool).deposit(assets, true)` (deposit is not a
//     view idiom) is the external call surface.
//   - signal (a) valuation read: the `oracle.getPrice()` / `IOracle` valuation shape.
//   - signal (b) hardcoded call arg: the literal `true` passed into the pool deposit.
// Signal (c) (dual asset representation) is deliberately absent, so the sentinel's <n> is exactly 2. The
// callee targets are `immutable`, so the #2145 settable-callee detector does NOT also fire — this fixture
// isolates the integration lens.

interface IOracle {
    function getPrice() external view returns (uint256);
}

interface IPool {
    function deposit(uint256 assets, bool useReserve) external returns (uint256);
}

contract IntegrationVault {
    IOracle public immutable oracle;
    address public immutable pool;

    mapping(address => uint256) public shares;

    constructor(IOracle o, address p) {
        oracle = o;
        pool = p;
    }

    function deposit(uint256 assets) external {
        uint256 px = oracle.getPrice();
        uint256 minted = IPool(pool).deposit(assets, true);
        shares[msg.sender] = shares[msg.sender] + minted * px;
    }
}
