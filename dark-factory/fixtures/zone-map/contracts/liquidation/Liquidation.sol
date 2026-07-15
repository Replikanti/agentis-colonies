// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @notice An intentionally OVERSIZED CDP liquidation engine fixture for the zone-map demo. Its purpose is
///         to exceed map-zones.sh's function-slice threshold so scope.tsv emits it as `file@fn1+fn2+...`
///         (the slice-fns.sh format). Generic, public-safe — no real protocol, no real math soundness.
interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address who) external view returns (uint256);
}

interface IPriceOracle {
    function latestPrice() external view returns (uint256);
}

contract Liquidation {
    struct Position {
        uint256 collateral;
        uint256 debt;
        uint256 lastAccrued;
    }

    address public owner;
    IERC20 public collateralToken;
    IERC20 public debtToken;
    IPriceOracle public oracle;

    uint256 public constant LIQUIDATION_THRESHOLD = 80; // percent
    uint256 public constant LIQUIDATION_BONUS = 5;      // percent
    uint256 public constant RATE_PER_SECOND = 1;        // bps-ish, fixture only
    uint256 public constant PRECISION = 1e18;

    mapping(address => Position) public positions;
    uint256 public totalDebt;
    uint256 public totalCollateral;
    bool internal _entered;

    event Opened(address indexed who, uint256 collateral, uint256 debt);
    event Liquidated(address indexed who, address indexed by, uint256 repaid, uint256 seized);

    modifier nonReentrant() {
        require(!_entered, "reentrant");
        _entered = true;
        _;
        _entered = false;
    }

    uint256 public feeBps;
    bool public paused;
    uint256 public minCollateral;
    uint256 public gracePeriod;

    constructor(address collateral_, address debt_, address oracle_) {
        owner = msg.sender;
        collateralToken = IERC20(collateral_);
        debtToken = IERC20(debt_);
        oracle = IPriceOracle(oracle_);
    }

    // Admin/init setters (#1701 fixture): declared here, ahead of the value-moving/recovery functions
    // below, so this fixture mirrors the dodo Gateway* shape (many admin setters declared before
    // liquidate/redeem) that map-zones.sh's fn_names()[:8] truncation used to starve of exactly the
    // functions a hunt most needs to see.
    function setFeeBps(uint256 bps_) external {
        require(msg.sender == owner, "not owner");
        feeBps = bps_;
    }

    function setPaused(bool paused_) external {
        require(msg.sender == owner, "not owner");
        paused = paused_;
    }

    function setMinCollateral(uint256 amount_) external {
        require(msg.sender == owner, "not owner");
        minCollateral = amount_;
    }

    function setGracePeriod(uint256 seconds_) external {
        require(msg.sender == owner, "not owner");
        gracePeriod = seconds_;
    }

    function openPosition(uint256 collateralAmount, uint256 debtAmount) external nonReentrant {
        require(collateralAmount > 0, "no collateral");
        Position storage p = positions[msg.sender];
        require(collateralToken.transferFrom(msg.sender, address(this), collateralAmount), "xfer in");
        p.collateral += collateralAmount;
        p.debt += debtAmount;
        p.lastAccrued = block.timestamp;
        totalCollateral += collateralAmount;
        totalDebt += debtAmount;
        require(_healthFactor(msg.sender) >= PRECISION, "unhealthy open");
        if (debtAmount > 0) {
            require(debtToken.transfer(msg.sender, debtAmount), "xfer out");
        }
        emit Opened(msg.sender, collateralAmount, debtAmount);
    }

    function addCollateral(uint256 amount) external nonReentrant {
        require(amount > 0, "zero");
        Position storage p = positions[msg.sender];
        require(p.collateral > 0 || p.debt > 0, "no position");
        require(collateralToken.transferFrom(msg.sender, address(this), amount), "xfer in");
        p.collateral += amount;
        totalCollateral += amount;
    }

    function accrue(address who) public {
        Position storage p = positions[who];
        if (p.debt == 0 || p.lastAccrued == 0) {
            p.lastAccrued = block.timestamp;
            return;
        }
        uint256 dt = block.timestamp - p.lastAccrued;
        uint256 interest = (p.debt * RATE_PER_SECOND * dt) / (PRECISION);
        p.debt += interest;
        totalDebt += interest;
        p.lastAccrued = block.timestamp;
    }

    function liquidate(address who, uint256 repayAmount) external nonReentrant {
        accrue(who);
        require(_healthFactor(who) < PRECISION, "healthy");
        Position storage p = positions[who];
        uint256 repay = repayAmount > p.debt ? p.debt : repayAmount;
        uint256 seized = seize(who, repay);
        require(debtToken.transferFrom(msg.sender, address(this), repay), "repay in");
        p.debt -= repay;
        totalDebt -= repay;
        require(collateralToken.transfer(msg.sender, seized), "seize out");
        emit Liquidated(who, msg.sender, repay, seized);
    }

    function seize(address who, uint256 repay) internal returns (uint256 seized) {
        Position storage p = positions[who];
        uint256 price = oracle.latestPrice();
        seized = (repay * (100 + LIQUIDATION_BONUS)) / (100 * price);
        if (seized > p.collateral) {
            seized = p.collateral;
        }
        p.collateral -= seized;
        totalCollateral -= seized;
    }

    function redeem(uint256 amount) external nonReentrant {
        Position storage p = positions[msg.sender];
        require(p.debt == 0, "outstanding debt");
        require(amount <= p.collateral, "too much");
        p.collateral -= amount;
        totalCollateral -= amount;
        require(collateralToken.transfer(msg.sender, amount), "redeem out");
    }

    function _healthFactor(address who) internal view returns (uint256) {
        Position storage p = positions[who];
        if (p.debt == 0) return type(uint256).max;
        uint256 price = oracle.latestPrice();
        uint256 collateralValue = (p.collateral * price) / PRECISION;
        uint256 maxDebt = (collateralValue * LIQUIDATION_THRESHOLD) / 100;
        return (maxDebt * PRECISION) / p.debt;
    }

    function setOracle(address oracle_) external {
        require(msg.sender == owner, "not owner");
        oracle = IPriceOracle(oracle_);
    }
}
