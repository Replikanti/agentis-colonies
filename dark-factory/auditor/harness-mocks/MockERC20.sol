// SPDX-License-Identifier: MIT
// MockERC20 — configurable-decimals ERC20 for generated invariant harnesses (#1794). Dependency-free by
// contract: it imports NOTHING (no OpenZeppelin, no solmate, no forge-std), so it always compiles inside a bare
// Foundry project with zero remappings.
//
// `decimals` is a CONSTRUCTOR argument because the #1720 MOCK-DEP FIDELITY guard requires the mock's units to
// match what the target assumes (a target that treats the asset as 6-decimal USDC needs `new MockERC20("USDC",
// "USDC", 6)`, not an 18-decimal default).
//
// Deliberately UNPERMISSIONED: `mint`/`burn` are open so the harness can fund actors from any context without
// wiring an owner. This is a test double, never a production token.
//
// `pragma >=0.8.0` — see MockAggregatorV3.sol for the rationale.
pragma solidity >=0.8.0;

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public decimals;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory name_, string memory symbol_, uint8 decimals_) {
        name = name_;
        symbol = symbol_;
        decimals = decimals_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        // type(uint256).max is the conventional infinite allowance — do not decrement it.
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "MockERC20: allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        totalSupply = totalSupply + amount;
        balanceOf[to] = balanceOf[to] + amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        require(balanceOf[from] >= amount, "MockERC20: burn balance");
        balanceOf[from] = balanceOf[from] - amount;
        totalSupply = totalSupply - amount;
        emit Transfer(from, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "MockERC20: balance");
        balanceOf[from] = balanceOf[from] - amount;
        balanceOf[to] = balanceOf[to] + amount;
        emit Transfer(from, to, amount);
    }
}
