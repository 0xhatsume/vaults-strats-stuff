// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.4;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import { Pausable } from "@openzeppelin/contracts/security/Pausable.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { AccessControl } from "@openzeppelin/contracts/access/AccessControl.sol";
import { Vault } from "../libraries/Vault.sol";
import { ShareMath } from "../libraries/ShareMath.sol";
import { IWETH } from "../interfaces/IWETH.sol";
import { IWhitelist } from "../interfaces/IWhitelist.sol";
import { VaultLifecycle } from "../libraries/VaultLifecycle.sol";

contract BaseVault is AccessControl, ERC20, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    /************************************************
     *  STORAGE
     ***********************************************/

    /// @notice On every round's close, the pricePerShare value of a vault token is stored
    /// This is used to determine the number of shares to be returned
    mapping(uint256 => uint256) public roundPricePerShare;

    /// @notice Stores pending user withdrawals
    mapping(address => Vault.Withdrawal) public withdrawals;

    /// @notice Stores the eth leverage set
    mapping(uint256 => Vault.LeverageSet) public ethLeverageSets;

    /// @notice Stores the btc leverage set
    mapping(uint256 => Vault.LeverageSet) public btcLeverageSets;

    /// @notice Stores the current round queued withdrawal share amount
    mapping(uint256 => uint128) public roundQueuedWithdrawalShares;

    /// @notice Vault's parameters like cap, decimals
    Vault.VaultParams public vaultParams;

    /// @notice Vault's lifecycle state like round and locked amounts
    Vault.VaultState public vaultState;

    /// @notice Vault's state of the hedges deployed and glp allocation
    Vault.StrategyState public strategyState;

    /// @notice Asset used in the vault
    address public asset;

    /// @notice Fee recipient for the performance and management fees
    address public feeRecipient;

    /// @notice Role for vault operations such as rollToNextPosition.
    address public keeper;

    /// @notice Whitelist implimentation
    address public whitelistLibrary;

    /// @notice Performance fee collected on premiums earned in rollToNextPosition. Only when there is no loss.
    uint256 public performanceFee;

    /// @notice Management fee collected on roll to next. This fee is collected each epoch
    uint256 public managementFee;

    /// @notice Deposit fee charged on entering of the vault
    uint256 public depositFee;

    /// @notice Withdrawal fee charged on exit of the vault
    uint256 public withdrawalFee;

    /// @notice If the vault is in a late withdrawal period while rebalancing
    bool public lateWithdrawPeriod;

    /// @notice The expected duration of each epoch
    uint256 public epochDuration;

    /// @notice Scale for slippage
    uint256 public SCALE = 1000;

    /************************************************
     *  IMMUTABLES & CONSTANTS
     ***********************************************/

    /// @notice WETH9
    address public immutable WETH = 0x82aF49447D8a07e3bd95BD0d56f35241523fBab1;

    /// @notice admin role hash
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @notice keeper role hash
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    /// @notice Day in seconds
    uint32 public constant DAY = 86400;

    /************************************************
     *  EVENTS
     ***********************************************/

    event DepositRound(address indexed account, uint256 amount, uint256 round);

    event Deposit(address indexed caller, address indexed owner, uint256 assets, uint256 shares);

    event InitiateWithdraw(address indexed account, uint256 shares, uint256 round);

    event ManagementFeeSet(uint256 managementFee, uint256 newManagementFee);

    event PerformanceFeeSet(uint256 performanceFee, uint256 newPerformanceFee);

    event DepositFeeSet(uint256 depositFee, uint256 newDepositFee);

    event WithdrawalFeeSet(uint256 withdrawalFee, uint256 newWithdrawalFee);

    event CapSet(uint256 oldCap, uint256 newCap);

    event Withdraw(address indexed account, uint256 amount, uint256 shares);

    event CollectVaultFees(uint256 performanceFee, uint256 vaultFee, uint256 round, address indexed feeRecipient);

    /************************************************
     *  CONSTRUCTOR & INITIALIZATION
     ***********************************************/
    /**
     * @notice Initializes the contract with immutable variables
     */
    constructor(
        address _asset,
        address _feeRecipient,
        address _keeper,
        uint256 _managementFee,
        uint256 _performanceFee,
        uint256 _depositFee,
        uint104 _vaultRound,
        Vault.VaultParams memory _vaultParams,
        string memory _name,
        string memory _symbol
    ) ERC20(_name, _symbol) {
        require(_asset != address(0), "!_asset");
        require(_feeRecipient != address(0), "!_feeRecipient");
        require(_keeper != address(0), "!_keeper");
        require(_performanceFee < 100 * Vault.FEE_MULTIPLIER, "_performanceFee >= 100%");
        require(_managementFee < 100 * Vault.FEE_MULTIPLIER, "_managementFee >= 100%");
        require(_depositFee < 100 * Vault.FEE_MULTIPLIER, "_depositFee >= 100%");
        require(_vaultParams.minimumSupply > 0, "!_minimumSupply");
        require(_vaultParams.cap > 0, "!_cap");
        require(_vaultParams.cap > _vaultParams.minimumSupply, "_cap <= _minimumSupply");
        require(bytes(_name).length > 0, "!_name");
        require(bytes(_symbol).length > 0, "!_symbol");

        asset = _asset;
        feeRecipient = _feeRecipient;
        keeper = _keeper;
        performanceFee = _performanceFee;
        managementFee = _managementFee;
        depositFee = _depositFee;
        withdrawalFee = 0;
        vaultParams = _vaultParams;
        vaultState.round = _vaultRound;
        whitelistLibrary = address(0);
        lateWithdrawPeriod = false;
        epochDuration = DAY;

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(KEEPER_ROLE, _keeper);
        _setupRole(ADMIN_ROLE, msg.sender);
    }

    /************************************************
     *  MODIFIERS
     ***********************************************/

    /**
     * @dev Throws if called by any account other than the keeper.
     */
    modifier onlyKeeper() {
        require(hasRole(KEEPER_ROLE, msg.sender), "!keeper");
        _;
    }

    /**
     * @dev Throws if called by any account other than the admin.
     */
    modifier onlyAdmin() {
        require(hasRole(ADMIN_ROLE, msg.sender), "Caller is not an admin");
        _;
    }

    /************************************************
     *  SETTERS
     ***********************************************/

    /**
     * @notice Sets the whitelist implementation
     * @param _newWhitelistLibrary address to the whitelist implementation
     */
    function setWhitelistLibrary(address _newWhitelistLibrary) external onlyAdmin {
        whitelistLibrary = _newWhitelistLibrary;
    }

    /**
     * @notice Sets the epoch duration
     * @param _newEpochDuration new epoch duration
     */
    function setEpochDuration(uint256 _newEpochDuration) external onlyAdmin {
        epochDuration = _newEpochDuration;
    }

    /**
     * @notice Sets the SCALE value for resolution of calcs
     * @param _newScale epoch duration
     */
    function setScale(uint256 _newScale) external onlyAdmin {
        SCALE = _newScale;
    }

    /**
     * @notice Sets a new eth leverage pool
     * @param _leverageSet the leverage set to be set
     * @param _index the index to set it at
     */
    function setEthLeveragePool(Vault.LeverageSet memory _leverageSet, uint256 _index) external onlyAdmin {
        require(_leverageSet.poolCommitter != address(0), "!addNewLeveragePool");
        require(_leverageSet.leveragePool != address(0), "!addNewLeveragePool");
        ethLeverageSets[_index] = _leverageSet;
    }

    /**
     * @notice Sets a new btc leverage pool
     * @param _leverageSet the leverage set to be set
     * @param _index the index to set it at
     */
    function setBtcLeveragePool(Vault.LeverageSet memory _leverageSet, uint256 _index) external onlyAdmin {
        require(_leverageSet.poolCommitter != address(0), "!addNewLeveragePool");
        require(_leverageSet.leveragePool != address(0), "!addNewLeveragePool");
        btcLeverageSets[_index] = _leverageSet;
    }

    /**
     * @notice Sets the new fee recipient
     * @param newFeeRecipient is the address of the new fee recipient
     */
    function setFeeRecipient(address newFeeRecipient) external onlyAdmin {
        require(newFeeRecipient != address(0), "!newFeeRecipient");
        require(newFeeRecipient != feeRecipient, "Must be new feeRecipient");
        feeRecipient = newFeeRecipient;
    }

    /**
     * @notice Sets the management fee for the vault
     * @param newManagementFee is the management fee (6 decimals). ex: 2 * 10 ** 6 = 2%
     */
    function setManagementFee(uint256 newManagementFee) external onlyAdmin {
        require(newManagementFee < 10 * Vault.FEE_MULTIPLIER, "Invalid management fee");
        uint256 hourlyRate = newManagementFee / 8760; // hours per year
        uint256 epochRate = (hourlyRate * epochDuration) / 3600;
        emit ManagementFeeSet(managementFee, newManagementFee);
        managementFee = epochRate; // % per epoch
    }

    /**
     * @notice Sets the performance fee for the vault
     * @param newPerformanceFee is the performance fee (6 decimals). ex: 20 * 10 ** 6 = 20%
     */
    function setPerformanceFee(uint256 newPerformanceFee) external onlyAdmin {
        require(newPerformanceFee < 100 * Vault.FEE_MULTIPLIER, "Invalid performance fee");
        emit PerformanceFeeSet(performanceFee, newPerformanceFee);
        performanceFee = newPerformanceFee;
    }

    /**
     * @notice Sets the deposit fee for the vault
     * @param newDepositFee is the deposit fee (6 decimals). ex: 20 * 10 ** 6 = 20%
     */
    function setDepositFee(uint256 newDepositFee) external onlyAdmin {
        require(newDepositFee < 20 * Vault.FEE_MULTIPLIER, "Invalid deposit fee");
        emit DepositFeeSet(depositFee, newDepositFee);
        depositFee = newDepositFee;
    }

    /**
     * @notice Sets the withdrawal fee for the vault
     * @param newWithdrawalFee is the withdrawal fee (6 decimals). ex: 20 * 10 ** 6 = 20%
     */
    function setWithdrawalFee(uint256 newWithdrawalFee) external onlyAdmin {
        require(newWithdrawalFee < 20 * Vault.FEE_MULTIPLIER, "Invalid withdrawal fee");
        emit WithdrawalFeeSet(withdrawalFee, newWithdrawalFee);
        withdrawalFee = newWithdrawalFee;
    }

    /**
     * @notice Sets a new cap for deposits
     * @param newCap is the new cap for deposits
     */
    function setCap(uint256 newCap) external onlyAdmin {
        require(newCap >= 0, "!newCap");
        ShareMath.assertUint104(newCap);
        emit CapSet(vaultParams.cap, newCap);
        vaultParams.cap = uint104(newCap);
    }

    /**
     * @notice Pauses deposits for the vault
     */
    function pauseDeposits() external onlyAdmin {
        _pause();
    }

    /**
     * @notice unpauses deposits for the vault
     */
    function unpauseDeposits() external onlyAdmin {
        _unpause();
    }

    /************************************************
     *  DEPOSIT & WITHDRAWALS
     ***********************************************/

    /**
     * @notice Deposits the `asset` from msg.sender.
     * @param amount is the amount of `asset` to deposit
     */
    function deposit(uint256 amount) external nonReentrant {
        require(amount > 0, "!amount");
        require(whitelistLibrary == address(0), "whitelist enabled");
        _depositFor(amount, msg.sender);
    }

    /**
     * @notice Deposits the `asset` from msg.sender added to `creditor`'s deposit.
     * @notice Used for vault -> vault deposits on the user's behalf
     * @param amount is the amount of `asset` to deposit
     * @param creditor is the address that can claim/withdraw deposited amount
     */
    function deposit(uint256 amount, address creditor) external nonReentrant returns (uint256 mintShares) {
        require(amount > 0, "!amount");
        require(creditor != address(0), "!creditor");
        require(whitelistLibrary == address(0), "whitelist enabled");
        mintShares = _depositFor(amount, creditor);
    }

    /**
     * @notice Deposits the `asset` from msg.sender. Whitelist must be enabled
     * @param amount is the amount of `asset` to deposit
     */
    function whitelistDeposit(uint256 amount, bytes32[] calldata merkleproof) external nonReentrant {
        require(amount > 0, "!amount");
        require(whitelistLibrary != address(0), "whitelist not enabled");
        uint256 checkpointBalance = checkpointTotalBalance();
        require(IWhitelist(whitelistLibrary).isWhitelisted(msg.sender, checkpointBalance, amount, merkleproof), "!whitelist");
        _depositFor(amount, msg.sender);
    }

    /**
     * @notice Mints the vault shares to the creditor
     * @param amount is the amount of `asset` deposited
     * @param creditor is the address to receieve the deposit
     * @return mintShares the shares minted
     */
    function _depositFor(uint256 amount, address creditor) private whenNotPaused returns (uint256 mintShares) {
        uint256 checkpointBalance = checkpointTotalBalance();

        uint256 currentRound = vaultState.round;
        uint256 totalWithDepositedAmount = checkpointBalance + amount;

        require(totalWithDepositedAmount <= vaultParams.cap, "Exceed cap");
        require(totalWithDepositedAmount >= vaultParams.minimumSupply, "Insufficient balance");

        emit DepositRound(creditor, amount, currentRound);

        uint256 depositFeeAmount = (amount * depositFee) / (100 * Vault.FEE_MULTIPLIER);
        uint256 depositAmount = amount - depositFeeAmount;

        uint256 newTotalPending = uint256(vaultState.totalPending) + depositAmount;

        vaultState.totalPending = uint128(newTotalPending);

        uint256 assetPerShare = roundPricePerShare[currentRound];

        mintShares = ShareMath.assetToShares(depositAmount, assetPerShare, vaultParams.decimals);

        emit Deposit(msg.sender, creditor, depositAmount, mintShares);

        IERC20(vaultParams.asset).safeTransferFrom(msg.sender, address(this), amount);
        transferAsset(feeRecipient, depositFeeAmount);

        _mint(creditor, mintShares);
    }

    /**
     * @notice Initiates a withdrawal that can be processed once the round completes
     * @param numShares is the number of shares to withdraw
     */
    function initiateWithdraw(uint256 numShares) external nonReentrant {
        if (lateWithdrawPeriod) {
            _initiateWithdraw(numShares, vaultState.round + 1);
        } else {
            _initiateWithdraw(numShares, vaultState.round);
        }
    }

    /**
     * @notice Initiates a withdrawal queued for the specified round
     * @param _numShares is the number of shares to withdraw
     * @param _round is the round to queue the withdrawal for
     */
    function _initiateWithdraw(uint256 _numShares, uint256 _round) internal {
        require(_numShares > 0, "!_numShares");

        // This caches the `round` variable used in shareBalances
        uint256 withdrawalRound = _round;
        Vault.Withdrawal storage withdrawal = withdrawals[msg.sender];

        bool withdrawalIsSameRound = withdrawal.round >= withdrawalRound;

        emit InitiateWithdraw(msg.sender, _numShares, withdrawalRound);

        uint256 existingShares = uint256(withdrawal.shares);

        uint256 withdrawalShares;
        if (withdrawalIsSameRound) {
            withdrawalShares = existingShares + _numShares;
        } else {
            require(existingShares == 0, "Existing withdraw");
            withdrawalShares = _numShares;
            withdrawals[msg.sender].round = uint16(withdrawalRound);
        }

        ShareMath.assertUint128(withdrawalShares);
        withdrawals[msg.sender].shares = uint128(withdrawalShares);

        uint256 newQueuedWithdrawShares = uint256(roundQueuedWithdrawalShares[withdrawalRound]) + _numShares;
        ShareMath.assertUint128(newQueuedWithdrawShares);
        roundQueuedWithdrawalShares[withdrawalRound] = uint128(newQueuedWithdrawShares);

        _transfer(msg.sender, address(this), _numShares);
    }

    /**
     * @notice Completes a scheduled withdrawal from a past round. Uses finalized pps for the round
     * @return withdrawAmount the current withdrawal amount
     */
    function _completeWithdraw() internal returns (uint256) {
        Vault.Withdrawal storage withdrawal = withdrawals[msg.sender];

        uint256 withdrawalShares = withdrawal.shares;
        uint256 withdrawalRound = withdrawal.round;

        // This checks if there is a withdrawal
        require(withdrawalShares > 0, "Not initiated");

        require(withdrawalRound < vaultState.round, "Round not closed");

        // We leave the round number as non-zero to save on gas for subsequent writes
        withdrawals[msg.sender].shares = 0;
        vaultState.queuedWithdrawShares = uint128(uint256(vaultState.queuedWithdrawShares) - withdrawalShares);

        uint256 withdrawAmount = ShareMath.sharesToAsset(
            withdrawalShares,
            roundPricePerShare[withdrawalRound],
            vaultParams.decimals
        );

        if (withdrawalFee > 0) {
            uint256 withdrawFeeAmount = (withdrawAmount * withdrawalFee) / (100 * Vault.FEE_MULTIPLIER);
            withdrawAmount -= withdrawFeeAmount;
        }

        emit Withdraw(msg.sender, withdrawAmount, withdrawalShares);

        _burn(address(this), withdrawalShares);
        require(withdrawAmount > 0, "!withdrawAmount");

        transferAsset(msg.sender, withdrawAmount);

        return withdrawAmount;
    }

    /**
     * @notice Mints a number of shares to the receiver
     * @param _shares is the number of shares to mint
     * @param _receiver is account recieving the shares
     */
    function mint(uint256 _shares, address _receiver) external nonReentrant {
        require(_shares > 0, "!_shares");
        require(_receiver != address(0), "!_receiver");

        uint256 currentRound = vaultState.round;
        uint256 assetPerShare = roundPricePerShare[currentRound];
        uint256 assetAmount = ShareMath.sharesToAsset(_shares, assetPerShare, vaultParams.decimals);

        _depositFor(assetAmount, _receiver);
    }

    /************************************************
     *  VAULT OPERATIONS
     ***********************************************/

    /*
     * @notice Helper function that helps to save gas for writing values into the roundPricePerShare map.
     *         Writing `1` into the map makes subsequent writes warm, reducing the gas from 20k to 5k.
     *         Having 1 initialized beforehand will not be an issue as long as we round down share calculations to 0.
     * @param numRounds is the number of rounds to initialize in the map
     */
    function initRounds(uint256 numRounds) external nonReentrant {
        require(numRounds > 0, "!numRounds");

        uint256 _round = vaultState.round;
        for (uint256 i = 0; i < numRounds; i++) {
            uint256 index = _round + i;
            require(roundPricePerShare[index] == 0, "Initialized"); // AVOID OVERWRITING ACTUAL VALUES
            roundPricePerShare[index] = ShareMath.PLACEHOLDER_UINT;
        }
    }

    /*
     * @notice Helper function that performs most administrative tasks
     * such as setting next strategy params, depositing to tracer and GMX, getting vault fees, etc.
     */
    function _rollToNextEpoch(
        uint256 lastQueuedWithdrawAmount,
        uint256 currentQueuedWithdrawalShares,
        uint256 totalAssetValue
    ) internal returns (uint256 lockedBalance, uint256 queuedWithdrawAmount) {
        uint256 newSbtcAllocation = strategyState.nextSbtcAllocation;
        uint256 newSethAllocation = strategyState.nextSethAllocation;
        uint256 newGlpAllocation = strategyState.nextGlpAllocation;

        uint256 performanceFeeInAsset;
        uint256 totalVaultFee;
        {
            uint256 newPricePerShare;
            (lockedBalance, queuedWithdrawAmount, newPricePerShare, performanceFeeInAsset, totalVaultFee) = VaultLifecycle
                .rollover(
                    vaultState,
                    VaultLifecycle.RolloverParams(
                        vaultParams.decimals,
                        totalAssetValue,
                        totalSupply(),
                        lastQueuedWithdrawAmount,
                        currentQueuedWithdrawalShares,
                        performanceFee,
                        managementFee,
                        (block.timestamp - vaultState.epochStart) / epochDuration
                    )
                );

            strategyState.activeSbtcAllocation = newSbtcAllocation;
            strategyState.activeSethAllocation = newSethAllocation;
            strategyState.activeGlpAllocation = newGlpAllocation;

            strategyState.nextSbtcAllocation = 0;
            strategyState.nextSethAllocation = 0;
            strategyState.nextGlpAllocation = 0;

            uint256 currentRound = vaultState.round;
            roundPricePerShare[currentRound] = newPricePerShare;

            // close the late withdrawal period for rebalancing
            lateWithdrawPeriod = false;

            emit CollectVaultFees(performanceFeeInAsset, totalVaultFee, currentRound, feeRecipient);

            vaultState.totalPending = 0;
            vaultState.round = uint104(currentRound + 1);
            vaultState.epochStart = block.timestamp;
            vaultState.epochEnd = vaultState.epochStart + epochDuration;
            roundPricePerShare[vaultState.round] = newPricePerShare;
        }

        if (totalVaultFee > 0) {
            transferAsset(payable(feeRecipient), totalVaultFee);
        }
        return (lockedBalance, queuedWithdrawAmount);
    }

    /**
     * @notice Helper function to make either an ETH transfer or ERC20 transfer
     * @param recipient is the receiving address
     * @param amount is the transfer amount
     */
    function transferAsset(address recipient, uint256 amount) internal {
        if (asset == WETH) {
            IWETH(WETH).withdraw(amount);
            (bool success, ) = recipient.call{ value: amount }("");
            require(success, "Transfer failed");
            return;
        }
        IERC20(asset).safeTransfer(recipient, amount);
    }

    /************************************************
     *  GETTERS
     ***********************************************/

    /**
     * @notice Returns the asset balance held on the vault for the account
     * @param account is the address to lookup balance for
     * @return the amount of `asset` custodied by the vault for the user
     */
    function accountVaultBalance(address account) external view returns (uint256) {
        uint256 _decimals = vaultParams.decimals;
        uint256 assetPerShare = roundPricePerShare[vaultState.round];
        return ShareMath.sharesToAsset(shares(account), assetPerShare, _decimals);
    }

    /**
     * @notice Getter for returning the account's share balance
     * @param _account is the account to lookup share balance for
     * @return heldByAccount share balance
     */
    function shares(address _account) public view returns (uint256) {
        uint256 heldByAccount = balanceOf(_account);
        return heldByAccount;
    }

    /**
     * @notice The price of a unit of share denominated in the `asset`
     * @return
     */
    function pricePerShare() external view returns (uint256) {
        return roundPricePerShare[vaultState.round];
    }

    /**
     * @notice Returns the vault's balance with realtime deposits and the locked value at the start of the epoch
     * @return total balance of the vault, including the amounts locked in third party protocols
     */
    function checkpointTotalBalance() public view returns (uint256) {
        return uint256(vaultState.lastLockedAmount) + IERC20(vaultParams.asset).balanceOf(address(this));
    }

    /**
     * @notice Returns the token decimals
     * @return
     */
    function decimals() public view override returns (uint8) {
        return vaultParams.decimals;
    }

    /**
     * @notice Returns the vault cap
     * @return
     */
    function cap() external view returns (uint256) {
        return vaultParams.cap;
    }

    /**
     * @notice Returns the value of deposits not yet used in the strategy
     * @return
     */
    function totalPending() external view returns (uint256) {
        return vaultState.totalPending;
    }

    /**
     * @notice Converts the vault asset to shares at the current rate for this epoch
     * @param _assets the amount of the vault asset to convert
     * @return shares amount of shares for the asset
     */
    function convertToShares(uint256 _assets) public view virtual returns (uint256) {
        uint256 assetPerShare = roundPricePerShare[vaultState.round];
        return ShareMath.assetToShares(_assets, assetPerShare, vaultParams.decimals);
    }

    /**
     * @notice Converts the vault shares to assets at the current rate for this epoch
     * @param _shares the amount of vault shares to convert
     * @return asset amount of asset for the shares
     */
    function convertToAssets(uint256 _shares) public view virtual returns (uint256) {
        uint256 assetPerShare = roundPricePerShare[vaultState.round];
        return ShareMath.sharesToAsset(_shares, assetPerShare, vaultParams.decimals);
    }

    /**
     * @notice Previews a deposit to the vault for the number of assets
     * @param _assets to be deposited
     * @return shares amount of shares recieved after fees
     */
    function previewDeposit(uint256 _assets) public view virtual returns (uint256) {
        uint256 amountLessDepositFee = _assets - ((_assets * depositFee) / (100 * Vault.FEE_MULTIPLIER));
        return convertToShares(amountLessDepositFee);
    }

    /**
     * @notice Previews a mint of vault shares
     * @param _shares amount of shares to be minted
     * @return asset amount of asset required to mint the shares after fees
     */
    function previewMint(uint256 _shares) public view virtual returns (uint256) {
        uint256 amountLessDepositFee = _shares - ((_shares * depositFee) / (100 * Vault.FEE_MULTIPLIER));
        return convertToAssets(amountLessDepositFee);
    }

    /**
     * @notice Previews a withdrawal from the vault at the current price per share
     * @param _shares the amount of shares to withdraw
     * @return asset the amount of asset recieved after fees
     */
    function previewWithdraw(uint256 _shares) public view virtual returns (uint256) {
        uint256 amountLessWithdrawalFee = _shares - ((_shares * withdrawalFee) / (100 * Vault.FEE_MULTIPLIER));
        return convertToAssets(amountLessWithdrawalFee);
    }

    /**
     * @notice Previews the next balances for the epoch with queued withdrawals
     * @param lastQueuedWithdrawAmount the amount last queued for withdrawal
     * @param currentQueuedWithdrawalShares the amount queued for withdrawal this round
     * @param totalAssetValue total asset value of the vault
     * @return lockedBalance balance locked for the next strategy epoch
     * @return queuedWithdrawAmount next queued withdrawal amount to be set aside for withdrawals
     */
    function previewNextBalances(
        uint256 lastQueuedWithdrawAmount,
        uint256 currentQueuedWithdrawalShares,
        uint256 totalAssetValue
    ) internal view virtual returns (uint256 lockedBalance, uint256 queuedWithdrawAmount) {
        uint256 epochSeconds = (block.timestamp - vaultState.epochStart) / epochDuration;

        (lockedBalance, queuedWithdrawAmount, , , ) = VaultLifecycle.rollover(
            vaultState,
            VaultLifecycle.RolloverParams(
                vaultParams.decimals,
                totalAssetValue,
                totalSupply(),
                lastQueuedWithdrawAmount,
                currentQueuedWithdrawalShares,
                performanceFee,
                managementFee,
                epochSeconds
            )
        );
    }

    /**
     * @notice recover eth
     */
    function recoverEth() external onlyAdmin {
        (bool success, ) = msg.sender.call{ value: address(this).balance }("");
        require(success, "Withdraw failed");
    }
}