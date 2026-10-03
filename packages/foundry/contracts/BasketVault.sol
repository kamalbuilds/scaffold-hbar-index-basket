// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IHederaTokenService } from "./interfaces/IHederaTokenService.sol";
import { IHederaScheduleService } from "./interfaces/IHederaScheduleService.sol";
import { IHRC719 } from "./interfaces/IHRC719.sol";
import { ISaucerSwapV2Router, ISaucerSwapV2Pool, IWhbarHelper } from "./interfaces/ISaucerSwapV2.sol";
import { AggregatorV3Interface } from "./interfaces/AggregatorV3Interface.sol";

/// @title BasketVault
/// @notice A tokenised index fund on Hedera. Deposit HBAR and the vault buys a weighted basket of HTS tokens on
/// SaucerSwap V2, then mints you an HTS share token for your slice. Redeem burns shares and pays out your slice of
/// every token in the basket. The vault books its own rebalances through the Hedera Schedule Service, and values the
/// fund in USD through Chainlink.
/// @dev The basket's HBAR leg is held as WHBAR, so the vault's native HBAR balance is only fuel for scheduled runs.
contract BasketVault is Ownable, ReentrancyGuard {
    /// @notice A non-WHBAR token in the basket, priced and traded through one SaucerSwap V2 pool against WHBAR.
    struct Leg {
        address token;
        address pool;
        uint24 fee;
        bool tokenIsToken0;
        uint16 weightBps;
    }

    /// @notice One row of `holdings()`: a basket token, what the vault holds and what it is worth.
    struct Holding {
        address token;
        uint256 balance;
        uint256 valueWhbar;
        uint16 targetBps;
    }

    IHederaTokenService private constant HTS = IHederaTokenService(address(0x167));
    IHederaScheduleService private constant HSS = IHederaScheduleService(address(0x16b));
    int64 private constant SUCCESS = 22;
    int64 private constant TOKEN_ALREADY_ASSOCIATED = 194;
    uint256 private constant BPS = 10_000;
    uint256 private constant Q96 = 2 ** 96;
    uint8 private constant SHARE_DECIMALS = 8;
    /// Seconds past the ideal expiry to probe for a free slot: 1, 2, 4, 8, 16.
    uint256 private constant MAX_CAPACITY_DELAY = 16;

    /// @notice Shortest and longest gap between scheduled rebalances. Hedera refuses expiries past 62 days.
    uint256 public constant MIN_INTERVAL = 60;
    uint256 public constant MAX_INTERVAL = 60 days;
    /// @notice A self-rescheduling call under 3M gas runs once, fails to book its successor, and still reports
    /// SUCCESS. Measured on testnet; see docs/hedera-gotchas.md.
    uint256 public constant MIN_SCHEDULED_GAS = 3_000_000;

    ISaucerSwapV2Router public immutable router;
    IWhbarHelper public immutable whbarHelper;
    address public immutable whbar;
    AggregatorV3Interface public immutable hbarUsdFeed;
    /// @notice A Chainlink answer older than this blocks deposits and rebalances, never redemptions.
    uint256 public immutable maxOracleAge;
    /// @notice A leg is traded back to target once it is this far from its weight, in basis points of NAV.
    uint256 public immutable driftBps;
    /// @notice Most a swap may return below the pre-trade spot price, in basis points.
    uint256 public immutable slippageBps;
    /// @notice Gas each scheduled rebalance is booked with.
    uint256 public immutable scheduledGas;
    /// @notice Index into `legs` of a USD stablecoin leg checked against Chainlink, or type(uint256).max for none.
    uint256 public immutable guardLeg;
    /// @notice Most the stablecoin pool's implied HBAR/USD may differ from Chainlink's, in basis points.
    uint256 public immutable maxDeviationBps;

    Leg[] private _legs;
    /// @notice Weight of the WHBAR leg: whatever the other legs leave.
    uint16 public immutable whbarWeightBps;

    /// @notice The HTS share token. The vault is its treasury and holds its supply key.
    address public shareToken;

    /// @notice Seconds between scheduled rebalances; 0 while automation is off.
    uint256 public rebalanceInterval;
    /// @notice The schedule that will run the next rebalance, or address(0).
    address public pendingSchedule;
    /// @notice Consensus second the pending schedule is booked for.
    uint256 public nextRunAt;

    event Initialized(address indexed shareToken);
    event Deposited(address indexed account, uint256 hbarIn, uint256 valueAdded, uint256 shares);
    event Redeemed(address indexed account, uint256 shares, uint256 whbarOut, uint256[] legAmounts);
    event Swapped(address indexed tokenIn, address indexed tokenOut, uint256 amountIn, uint256 amountOut);
    event Rebalanced(uint256 navBefore, uint256 navAfter, bool traded);
    event AutomationStarted(uint256 interval);
    event AutomationStopped();
    event RunBooked(address indexed schedule, uint256 expiry);
    event BookingFailed(int64 responseCode);
    event ScheduledRun(bool traded);
    event ScheduledRunFailed(bytes reason);

    error AlreadyInitialized();
    error NotInitialized();
    error BadConfig();
    error ZeroAmount();
    error InsufficientShares(uint256 shares, uint256 minShares);
    error StaleOracle(uint256 updatedAt);
    error BadOraclePrice(int256 answer);
    error PoolPriceDeviates(uint256 poolHbarUsd, uint256 oracleHbarUsd);
    error HtsCallFailed(int64 responseCode);
    error TransferFailed(address token);
    error OnlySelf();
    error AutomationActive();
    error BadInterval(uint256 interval);
    error ScheduleFailed(int64 responseCode);

    struct Config {
        address router;
        address whbarHelper;
        address whbar;
        address hbarUsdFeed;
        uint256 maxOracleAge;
        uint256 driftBps;
        uint256 slippageBps;
        uint256 scheduledGas;
        uint256 guardLeg;
        uint256 maxDeviationBps;
    }

    struct LegConfig {
        address token;
        address pool;
        uint16 weightBps;
    }

    constructor(Config memory config, LegConfig[] memory legConfigs) Ownable(msg.sender) {
        if (
            config.router == address(0) || config.whbarHelper == address(0) || config.whbar == address(0)
                || config.hbarUsdFeed == address(0) || legConfigs.length == 0 || config.slippageBps >= BPS
                || config.driftBps == 0 || config.driftBps >= BPS || config.scheduledGas < MIN_SCHEDULED_GAS
                || (config.guardLeg != type(uint256).max && config.guardLeg >= legConfigs.length)
        ) revert BadConfig();

        router = ISaucerSwapV2Router(config.router);
        whbarHelper = IWhbarHelper(config.whbarHelper);
        whbar = config.whbar;
        hbarUsdFeed = AggregatorV3Interface(config.hbarUsdFeed);
        maxOracleAge = config.maxOracleAge;
        driftBps = config.driftBps;
        slippageBps = config.slippageBps;
        scheduledGas = config.scheduledGas;
        guardLeg = config.guardLeg;
        maxDeviationBps = config.maxDeviationBps;

        uint256 legWeights;
        for (uint256 i; i < legConfigs.length; ++i) {
            ISaucerSwapV2Pool pool = ISaucerSwapV2Pool(legConfigs[i].pool);
            address token0 = pool.token0();
            address token1 = pool.token1();
            bool tokenIsToken0 = token0 == legConfigs[i].token;
            if ((tokenIsToken0 ? token1 : token0) != config.whbar) revert BadConfig();
            if (!tokenIsToken0 && token1 != legConfigs[i].token) revert BadConfig();
            if (legConfigs[i].weightBps == 0) revert BadConfig();
            legWeights += legConfigs[i].weightBps;
            _legs.push(Leg(legConfigs[i].token, legConfigs[i].pool, pool.fee(), tokenIsToken0, legConfigs[i].weightBps));
        }
        if (legWeights >= BPS) revert BadConfig();
        // forge-lint: disable-next-line(unsafe-typecast)
        whbarWeightBps = uint16(BPS - legWeights);
    }

    /// @notice Native HBAR sent here is fuel for scheduled rebalances; it is not part of the basket.
    receive() external payable { }

    // ---------------------------------------------------------------- setup

    /// @notice Associates the vault with every basket token and creates the HTS share token. Send enough HBAR to
    /// cover the token creation fee; what HTS does not take stays as fuel.
    function initialize(string calldata name, string calldata symbol) external payable onlyOwner {
        if (shareToken != address(0)) revert AlreadyInitialized();
        _associate(whbar);
        for (uint256 i; i < _legs.length; ++i) {
            _associate(_legs[i].token);
        }

        IHederaTokenService.TokenKey[] memory keys = new IHederaTokenService.TokenKey[](1);
        keys[0] = IHederaTokenService.TokenKey({
            keyType: 16, // supply
            key: IHederaTokenService.KeyValue({
                inheritAccountKey: false,
                contractId: address(this),
                ed25519: "",
                ECDSA_secp256k1: "",
                delegatableContractId: address(0)
            })
        });
        IHederaTokenService.HederaToken memory token = IHederaTokenService.HederaToken({
            name: name,
            symbol: symbol,
            treasury: address(this),
            memo: "BasketVault share",
            tokenSupplyType: false,
            maxSupply: 0,
            freezeDefault: false,
            tokenKeys: keys,
            expiry: IHederaTokenService.Expiry({ second: 0, autoRenewAccount: address(this), autoRenewPeriod: 7_890_000 })
        });
        (int64 rc, address created) =
            HTS.createFungibleToken{ value: msg.value }(token, 0, int32(uint32(SHARE_DECIMALS)));
        if (rc != SUCCESS) revert HtsCallFailed(rc);
        shareToken = created;
        emit Initialized(created);
    }

    // ---------------------------------------------------------------- deposit / redeem

    /// @notice Buys the basket with the HBAR sent and mints shares for the value it added.
    /// @dev Everything is valued at the spot prices read before the swaps, so a depositor's own price impact and
    /// pool fees come out of their shares, not out of existing holders.
    /// @param minShares Reverts if fewer shares would be minted.
    function deposit(uint256 minShares) external payable nonReentrant returns (uint256 shares) {
        if (shareToken == address(0)) revert NotInitialized();
        if (msg.value == 0) revert ZeroAmount();
        _checkPriceGuard();

        uint160[] memory prices = _spotPrices();
        uint256 navBefore = _nav(prices);
        uint256 supply = IERC20(shareToken).totalSupply();

        whbarHelper.deposit{ value: msg.value }();
        uint256 valueAdded = msg.value;
        for (uint256 i; i < _legs.length; ++i) {
            Leg memory leg = _legs[i];
            uint256 spend = msg.value * leg.weightBps / BPS;
            if (spend == 0) continue;
            uint256 minOut = _whbarToLeg(leg, prices[i], spend) * (BPS - slippageBps) / BPS;
            uint256 bought = _swap(whbar, leg.token, leg.fee, spend, minOut);
            valueAdded = valueAdded - spend + _legToWhbar(leg, prices[i], bought);
        }

        shares = supply == 0 ? valueAdded : valueAdded * supply / navBefore;
        if (shares == 0 || shares < minShares) revert InsufficientShares(shares, minShares);
        _mintShares(shares);
        _transfer(shareToken, msg.sender, shares);
        emit Deposited(msg.sender, msg.value, valueAdded, shares);
    }

    /// @notice Burns `shares` and pays out the same fraction of every token the vault holds. Needs a share token
    /// allowance for the vault. Reads no price, so it works even when the oracle or a pool does not.
    function redeem(uint256 shares) external nonReentrant returns (uint256 whbarOut, uint256[] memory legAmounts) {
        if (shares == 0) revert ZeroAmount();
        address share = shareToken;
        uint256 supply = IERC20(share).totalSupply();
        if (!IERC20(share).transferFrom(msg.sender, address(this), shares)) revert TransferFailed(share);
        (int64 rc,) = HTS.burnToken(share, _int64(shares), new int64[](0));
        if (rc != SUCCESS) revert HtsCallFailed(rc);

        whbarOut = IERC20(whbar).balanceOf(address(this)) * shares / supply;
        if (whbarOut > 0) _transfer(whbar, msg.sender, whbarOut);
        legAmounts = new uint256[](_legs.length);
        for (uint256 i; i < _legs.length; ++i) {
            address token = _legs[i].token;
            uint256 out = IERC20(token).balanceOf(address(this)) * shares / supply;
            legAmounts[i] = out;
            if (out > 0) _transfer(token, msg.sender, out);
        }
        emit Redeemed(msg.sender, shares, whbarOut, legAmounts);
    }

    // ---------------------------------------------------------------- rebalance

    /// @notice Trades every leg that has drifted more than `driftBps` back to its target weight. Anyone may call
    /// it; it only ever moves the basket toward its targets. Returns false when nothing had drifted.
    function rebalance() public nonReentrant returns (bool traded) {
        _checkPriceGuard();
        uint160[] memory prices = _spotPrices();
        uint256 navBefore = _nav(prices);
        uint256 band = navBefore * driftBps / BPS;

        // Sell overweight legs first so the buys below have the WHBAR to spend.
        uint256[] memory values = new uint256[](_legs.length);
        for (uint256 i; i < _legs.length; ++i) {
            Leg memory leg = _legs[i];
            uint256 balance = IERC20(leg.token).balanceOf(address(this));
            uint256 value = _legToWhbar(leg, prices[i], balance);
            uint256 target = navBefore * leg.weightBps / BPS;
            values[i] = value;
            if (value > target + band) {
                uint256 excess = value - target;
                uint256 amountIn = balance * excess / value;
                _swap(leg.token, whbar, leg.fee, amountIn, excess * (BPS - slippageBps) / BPS);
                traded = true;
            }
        }
        for (uint256 i; i < _legs.length; ++i) {
            Leg memory leg = _legs[i];
            uint256 target = navBefore * leg.weightBps / BPS;
            if (values[i] + band < target) {
                uint256 spend = Math.min(target - values[i], IERC20(whbar).balanceOf(address(this)));
                if (spend == 0) continue;
                uint256 minOut = _whbarToLeg(leg, prices[i], spend) * (BPS - slippageBps) / BPS;
                _swap(whbar, leg.token, leg.fee, spend, minOut);
                traded = true;
            }
        }
        emit Rebalanced(navBefore, _nav(_spotPrices()), traded);
    }

    // ---------------------------------------------------------------- automation (HIP-1215)

    /// @notice Books a rebalance every `interval` seconds, paid from the vault's native HBAR. Keep at least
    /// `scheduledGas` times the network gas price in the vault: Hedera checks the payer against the gas reserved,
    /// not the gas burned.
    function startAutomation(uint256 interval) external onlyOwner {
        if (rebalanceInterval != 0) revert AutomationActive();
        if (interval < MIN_INTERVAL || interval > MAX_INTERVAL) revert BadInterval(interval);
        rebalanceInterval = interval;
        int64 rc = _bookNext();
        if (rc != SUCCESS) revert ScheduleFailed(rc);
        emit AutomationStarted(interval);
    }

    /// @notice Stops automation and deletes the pending schedule.
    function stopAutomation() external onlyOwner {
        rebalanceInterval = 0;
        address pending = pendingSchedule;
        pendingSchedule = address(0);
        nextRunAt = 0;
        if (pending != address(0)) HSS.deleteSchedule(pending);
        emit AutomationStopped();
    }

    /// @notice Entry point for scheduled runs. Hedera executes a scheduled call with msg.sender set to the
    /// scheduling contract, so only the vault's own schedule can reach it.
    /// @dev Books the successor before rebalancing and never reverts, so a failed rebalance costs one run, not the
    /// chain. A scheduled execution may book exactly one schedule, so this is the only booking in the run.
    function runScheduled() external {
        if (msg.sender != address(this)) revert OnlySelf();
        pendingSchedule = address(0);
        nextRunAt = 0;
        if (rebalanceInterval == 0) return;
        _bookNext();
        try this.rebalance() returns (bool traded) {
            emit ScheduledRun(traded);
        } catch (bytes memory reason) {
            emit ScheduledRunFailed(reason);
        }
    }

    /// @notice Sends native HBAR fuel out of the vault. Basket tokens are not reachable from here.
    function withdrawFuel(address payable to, uint256 amount) external onlyOwner {
        (bool ok,) = to.call{ value: amount }("");
        if (!ok) revert TransferFailed(address(0));
    }

    // ---------------------------------------------------------------- views

    function legs() external view returns (Leg[] memory) {
        return _legs;
    }

    /// @notice Net asset value in WHBAR (8 decimals, 1e8 = 1 HBAR) at current pool spot prices.
    function nav() public view returns (uint256) {
        return _nav(_spotPrices());
    }

    /// @notice Net asset value in USD (8 decimals) through Chainlink HBAR/USD.
    function navUsd() public view returns (uint256) {
        return nav() * hbarUsd() / 1e8;
    }

    /// @notice USD value of one whole share (8 decimals), or 0 before the first deposit.
    function sharePriceUsd() external view returns (uint256) {
        uint256 supply = shareToken == address(0) ? 0 : IERC20(shareToken).totalSupply();
        return supply == 0 ? 0 : navUsd() * 10 ** SHARE_DECIMALS / supply;
    }

    /// @notice Chainlink HBAR/USD with 8 decimals. Reverts if the answer is stale or not positive.
    function hbarUsd() public view returns (uint256) {
        (, int256 answer,, uint256 updatedAt,) = hbarUsdFeed.latestRoundData();
        if (answer <= 0) revert BadOraclePrice(answer);
        if (block.timestamp > updatedAt + maxOracleAge) revert StaleOracle(updatedAt);
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(answer);
    }

    /// @notice Every basket token with its balance, WHBAR value and target weight. WHBAR is row 0.
    function holdings() external view returns (Holding[] memory rows) {
        uint160[] memory prices = _spotPrices();
        rows = new Holding[](_legs.length + 1);
        uint256 whbarBalance = IERC20(whbar).balanceOf(address(this));
        rows[0] = Holding(whbar, whbarBalance, whbarBalance, whbarWeightBps);
        for (uint256 i; i < _legs.length; ++i) {
            Leg memory leg = _legs[i];
            uint256 balance = IERC20(leg.token).balanceOf(address(this));
            rows[i + 1] = Holding(leg.token, balance, _legToWhbar(leg, prices[i], balance), leg.weightBps);
        }
    }

    // ---------------------------------------------------------------- internals

    function _bookNext() private returns (int64 rc) {
        uint256 expiry = _secondWithCapacity(block.timestamp + rebalanceInterval);
        address schedule;
        (rc, schedule) = HSS.scheduleCall(address(this), expiry, scheduledGas, 0, abi.encodeCall(this.runScheduled, ()));
        if (rc != SUCCESS) {
            emit BookingFailed(rc);
            return rc;
        }
        pendingSchedule = schedule;
        nextRunAt = expiry;
        emit RunBooked(schedule, expiry);
    }

    /// HIP-1215's probe for a busy second. If none has capacity, scheduleCall reports SCHEDULE_EXPIRY_IS_BUSY.
    function _secondWithCapacity(uint256 ideal) private view returns (uint256) {
        if (HSS.hasScheduleCapacity(ideal, scheduledGas)) return ideal;
        for (uint256 delay = 1; delay <= MAX_CAPACITY_DELAY; delay *= 2) {
            if (HSS.hasScheduleCapacity(ideal + delay, scheduledGas)) return ideal + delay;
        }
        return ideal;
    }

    /// Compares the stablecoin pool's implied HBAR/USD with Chainlink and reverts when they disagree, so a
    /// manipulated pool cannot set the price of a deposit or a rebalance. Also enforces oracle freshness.
    function _checkPriceGuard() private view {
        uint256 oracle = hbarUsd();
        if (guardLeg == type(uint256).max) return;
        Leg memory leg = _legs[guardLeg];
        (uint160 sqrtPrice,,,,,,) = ISaucerSwapV2Pool(leg.pool).slot0();
        uint256 oneStable = 10 ** IERC20Metadata(leg.token).decimals();
        uint256 whbarPerUsd = _legToWhbar(leg, sqrtPrice, oneStable);
        if (whbarPerUsd == 0) revert PoolPriceDeviates(0, oracle);
        uint256 implied = 1e16 / whbarPerUsd;
        uint256 diff = implied > oracle ? implied - oracle : oracle - implied;
        if (diff * BPS > oracle * maxDeviationBps) revert PoolPriceDeviates(implied, oracle);
    }

    function _spotPrices() private view returns (uint160[] memory prices) {
        prices = new uint160[](_legs.length);
        for (uint256 i; i < _legs.length; ++i) {
            (prices[i],,,,,,) = ISaucerSwapV2Pool(_legs[i].pool).slot0();
        }
    }

    function _nav(uint160[] memory prices) private view returns (uint256 total) {
        total = IERC20(whbar).balanceOf(address(this));
        for (uint256 i; i < _legs.length; ++i) {
            Leg memory leg = _legs[i];
            total += _legToWhbar(leg, prices[i], IERC20(leg.token).balanceOf(address(this)));
        }
    }

    /// Pool price is token1 per token0 = (sqrtPriceX96 / 2^96)^2, in raw units of each token.
    function _legToWhbar(Leg memory leg, uint160 sqrtPrice, uint256 amount) private pure returns (uint256) {
        if (amount == 0) return 0;
        return leg.tokenIsToken0
            ? Math.mulDiv(Math.mulDiv(amount, sqrtPrice, Q96), sqrtPrice, Q96)
            : Math.mulDiv(Math.mulDiv(amount, Q96, sqrtPrice), Q96, sqrtPrice);
    }

    function _whbarToLeg(Leg memory leg, uint160 sqrtPrice, uint256 amount) private pure returns (uint256) {
        if (amount == 0) return 0;
        return leg.tokenIsToken0
            ? Math.mulDiv(Math.mulDiv(amount, Q96, sqrtPrice), Q96, sqrtPrice)
            : Math.mulDiv(Math.mulDiv(amount, sqrtPrice, Q96), sqrtPrice, Q96);
    }

    function _swap(address tokenIn, address tokenOut, uint24 fee, uint256 amountIn, uint256 minOut)
        private
        returns (uint256 amountOut)
    {
        // An exact allowance per swap: HTS refuses allowances above a finite token's max supply.
        if (!IERC20(tokenIn).approve(address(router), amountIn)) revert TransferFailed(tokenIn);
        amountOut = router.exactInput(
            ISaucerSwapV2Router.ExactInputParams({
                path: abi.encodePacked(tokenIn, fee, tokenOut),
                recipient: address(this),
                deadline: block.timestamp + 300,
                amountIn: amountIn,
                amountOutMinimum: minOut
            })
        );
        emit Swapped(tokenIn, tokenOut, amountIn, amountOut);
    }

    function _mintShares(uint256 amount) private {
        (int64 rc,,) = HTS.mintToken(shareToken, _int64(amount), new bytes[](0));
        if (rc != SUCCESS) revert HtsCallFailed(rc);
    }

    function _associate(address token) private {
        int64 rc = IHRC719(token).associate();
        if (rc != SUCCESS && rc != TOKEN_ALREADY_ASSOCIATED) revert HtsCallFailed(rc);
    }

    function _transfer(address token, address to, uint256 amount) private {
        if (!IERC20(token).transfer(to, amount)) revert TransferFailed(token);
    }

    function _int64(uint256 amount) private pure returns (int64) {
        return SafeCast.toInt64(SafeCast.toInt256(amount));
    }
}
