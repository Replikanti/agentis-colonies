// SPDX-License-Identifier: MIT
// MockVault4626 — minimal ERC4626-shaped share vault for generated invariant harnesses (#1794).
// Dependency-free by contract: it imports NOTHING. The asset is reached through a LOCAL minimal interface
// (`IVaultAsset`) whose name is UNIQUE across this library, so a harness may import this file alongside
// MockERC20.sol / MockPool.sol without an "identifier already declared" clash.
//
// Share math is the CLASSIC, offset-free ERC4626 formula (`shares = assets * totalSupply / totalAssets`, empty
// vault = 1:1) and `totalAssets()` reads the raw asset balance. That is deliberate: the first-depositor /
// donation share-inflation path stays REACHABLE, which is exactly the shape the value-custody lens fuzzes. Do
// NOT "harden" this mock — a mock that cannot be inflated hides the class of bug the harness is hunting.
//
// `pragma >=0.8.0` — see MockAggregatorV3.sol for the rationale.
pragma solidity >=0.8.0;

interface IVaultAsset {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract MockVault4626 {
    address public asset;
    uint8 public decimals;
    string public name;
    string public symbol;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed caller, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    constructor(address asset_, uint8 decimals_) {
        asset = asset_;
        decimals = decimals_;
        name = "Mock Vault";
        symbol = "mVLT";
    }

    // --- accounting ----------------------------------------------------------------------------------------

    function totalAssets() public view returns (uint256) {
        return IVaultAsset(asset).balanceOf(address(this));
    }

    function convertToShares(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return assets;
        return (assets * supply) / totalAssets();
    }

    function convertToAssets(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return shares;
        return (shares * totalAssets()) / supply;
    }

    function previewDeposit(uint256 assets) public view returns (uint256) {
        return convertToShares(assets);
    }

    function previewMint(uint256 shares) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return shares;
        return _mulDivUp(shares, totalAssets(), supply);
    }

    function previewWithdraw(uint256 assets) public view returns (uint256) {
        uint256 supply = totalSupply;
        if (supply == 0) return assets;
        return _mulDivUp(assets, supply, totalAssets());
    }

    function previewRedeem(uint256 shares) public view returns (uint256) {
        return convertToAssets(shares);
    }

    // --- ERC4626 actions -----------------------------------------------------------------------------------

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = previewDeposit(assets);
        require(shares != 0, "MockVault4626: zero shares");
        IVaultAsset(asset).transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function mint(uint256 shares, address receiver) external returns (uint256 assets) {
        assets = previewMint(shares);
        IVaultAsset(asset).transferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    function withdraw(uint256 assets, address receiver, address owner) external returns (uint256 shares) {
        shares = previewWithdraw(assets);
        _spendAllowance(owner, shares);
        _burn(owner, shares);
        IVaultAsset(asset).transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        assets = previewRedeem(shares);
        _spendAllowance(owner, shares);
        _burn(owner, shares);
        IVaultAsset(asset).transfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, owner, assets, shares);
    }

    // --- share token ---------------------------------------------------------------------------------------

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _moveShares(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= amount, "MockVault4626: allowance");
            allowance[from][msg.sender] = allowed - amount;
        }
        _moveShares(from, to, amount);
        return true;
    }

    // --- internals -----------------------------------------------------------------------------------------

    function _spendAllowance(address owner, uint256 shares) private {
        if (msg.sender == owner) return;
        uint256 allowed = allowance[owner][msg.sender];
        if (allowed != type(uint256).max) {
            require(allowed >= shares, "MockVault4626: share allowance");
            allowance[owner][msg.sender] = allowed - shares;
        }
    }

    function _mint(address to, uint256 shares) private {
        totalSupply = totalSupply + shares;
        balanceOf[to] = balanceOf[to] + shares;
        emit Transfer(address(0), to, shares);
    }

    function _burn(address from, uint256 shares) private {
        require(balanceOf[from] >= shares, "MockVault4626: burn balance");
        balanceOf[from] = balanceOf[from] - shares;
        totalSupply = totalSupply - shares;
        emit Transfer(from, address(0), shares);
    }

    function _moveShares(address from, address to, uint256 amount) private {
        require(balanceOf[from] >= amount, "MockVault4626: balance");
        balanceOf[from] = balanceOf[from] - amount;
        balanceOf[to] = balanceOf[to] + amount;
        emit Transfer(from, to, amount);
    }

    function _mulDivUp(uint256 a, uint256 b, uint256 d) private pure returns (uint256) {
        require(d != 0, "MockVault4626: div by zero");
        uint256 p = a * b;
        return p == 0 ? 0 : (p - 1) / d + 1;
    }
}
