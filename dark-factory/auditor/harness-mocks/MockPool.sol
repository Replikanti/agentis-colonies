// SPDX-License-Identifier: MIT
// MockPool — generic LP / AMM pool stub for generated invariant harnesses (#1794). Dependency-free by contract:
// it imports NOTHING. It stands in for the Curve/Balancer/UniV2-style PRICING READS an LP-oracle or a
// collateral manager performs, which is the dependency shape that used to force the prover to hand-author a
// pool mock per run (and fail to compile it on complex targets).
//
// It covers the four read shapes those targets use, under the vendors' own names so an import resolves whatever
// the target calls:
//   * reserves        — `getReserves()` (UniV2 uint112 triple), `reserve0/1()`, `balances(i)` (Curve)
//   * LP supply       — `totalSupply()` (+ an open `mintLp` so a harness can hold LP)
//   * a rate quote    — `get_virtual_price()` / `getVirtualPrice()` / `getRate()`, settable, default 1e18
//   * a swap quote    — `get_dy(i, j, dx)` (Curve) / `getAmountOut(dx, zeroForOne)`, derived from the RESERVES
//                       with a 30 bps fee, so moving the reserves moves the quote (the manipulation lever)
//
// It is a PRICING STUB: the quotes are pure reads, no tokens move. A harness manipulates it by calling
// `setReserves` / `setVirtualPrice`, which is what the oracle lens's bounded price-perturbation action needs.
//
// `pragma >=0.8.0` — see MockAggregatorV3.sol for the rationale.
pragma solidity >=0.8.0;

contract MockPool {
    address public token0;
    address public token1;
    uint8 public decimals;

    uint256 private _reserve0;
    uint256 private _reserve1;
    uint256 private _virtualPrice;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Sync(uint256 reserve0, uint256 reserve1);

    constructor(address token0_, address token1_) {
        token0 = token0_;
        token1 = token1_;
        decimals = 18;
        _virtualPrice = 1e18;
    }

    // --- reserve reads -------------------------------------------------------------------------------------

    /// UniV2 shape: `(reserve0, reserve1, blockTimestampLast)`. Reserves are capped to uint112 on write, so this
    /// never truncates silently. Returns are unnamed to avoid shadowing the `reserve0()`/`reserve1()` accessors.
    function getReserves() external view returns (uint112, uint112, uint32) {
        return (uint112(_reserve0), uint112(_reserve1), uint32(block.timestamp));
    }

    function reserve0() external view returns (uint256) {
        return _reserve0;
    }

    function reserve1() external view returns (uint256) {
        return _reserve1;
    }

    /// Curve shape: `balances(0)` / `balances(1)`.
    function balances(uint256 i) external view returns (uint256) {
        require(i < 2, "MockPool: index");
        return i == 0 ? _reserve0 : _reserve1;
    }

    function coins(uint256 i) external view returns (address) {
        require(i < 2, "MockPool: index");
        return i == 0 ? token0 : token1;
    }

    // --- rate quotes ---------------------------------------------------------------------------------------

    /// Curve shape (snake_case) — the read an LP oracle prices the pool token with.
    function get_virtual_price() external view returns (uint256) {
        return _virtualPrice;
    }

    /// camelCase alias for the same read.
    function getVirtualPrice() external view returns (uint256) {
        return _virtualPrice;
    }

    /// Balancer rate-provider shape for the same read.
    function getRate() external view returns (uint256) {
        return _virtualPrice;
    }

    // --- swap quotes (pure reads, derived from the reserves) -----------------------------------------------

    /// Curve shape. `i`/`j` select the in/out token; only a 2-coin pool is modelled.
    function get_dy(int128 i, int128 j, uint256 dx) external view returns (uint256) {
        require(i != j, "MockPool: same coin");
        require(i >= 0 && i < 2 && j >= 0 && j < 2, "MockPool: coin index");
        return _quote(dx, i == 0);
    }

    /// UniV2-flavoured alias: `zeroForOne` = paying token0, receiving token1.
    function getAmountOut(uint256 dx, bool zeroForOne) external view returns (uint256) {
        return _quote(dx, zeroForOne);
    }

    // --- harness-side setters ------------------------------------------------------------------------------

    /// The price-manipulation lever: move the reserves and every quote above moves with them.
    function setReserves(uint256 reserve0_, uint256 reserve1_) external {
        require(reserve0_ <= type(uint112).max && reserve1_ <= type(uint112).max, "MockPool: reserve overflow");
        _reserve0 = reserve0_;
        _reserve1 = reserve1_;
        emit Sync(reserve0_, reserve1_);
    }

    function setVirtualPrice(uint256 virtualPrice_) external {
        _virtualPrice = virtualPrice_;
    }

    function setTotalSupply(uint256 totalSupply_) external {
        totalSupply = totalSupply_;
    }

    function setTokens(address token0_, address token1_) external {
        token0 = token0_;
        token1 = token1_;
    }

    /// Unpermissioned on purpose (test double): lets a harness give an actor an LP position.
    function mintLp(address to, uint256 amount) external {
        totalSupply = totalSupply + amount;
        balanceOf[to] = balanceOf[to] + amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "MockPool: balance");
        balanceOf[msg.sender] = balanceOf[msg.sender] - amount;
        balanceOf[to] = balanceOf[to] + amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    // --- internals -----------------------------------------------------------------------------------------

    /// Constant-product quote with a 30 bps fee. Returns 0 on an empty side instead of reverting, so a quote
    /// read from an uninitialised pool never bricks a fuzzed sequence.
    function _quote(uint256 dx, bool zeroForOne) private view returns (uint256) {
        uint256 rIn = zeroForOne ? _reserve0 : _reserve1;
        uint256 rOut = zeroForOne ? _reserve1 : _reserve0;
        if (rIn == 0 || rOut == 0 || dx == 0) return 0;
        uint256 dxFee = dx * 997;
        return (dxFee * rOut) / (rIn * 1000 + dxFee);
    }
}
