// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.28;

import {ISummerTokenV2} from "../interfaces/ISummerTokenV2.sol";
import {ISummerVestingWalletFactory} from "../interfaces/ISummerVestingWalletFactory.sol";
import {IGovernanceRewardsManager} from "../interfaces/IGovernanceRewardsManager.sol";
import {IOFT, SendParam, OFTReceipt, MessagingReceipt, MessagingFee} from "@layerzerolabs/oft-evm/contracts/interfaces/IOFT.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";

import {OwnableUpgradeable} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {ERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/ERC20Upgradeable.sol";
import {ERC20BurnableUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20BurnableUpgradeable.sol";
import {ERC20PermitUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20PermitUpgradeable.sol";
import {ERC20VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20VotesUpgradeable.sol";
import {ERC20CappedUpgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC20CappedUpgradeable.sol";
import {NoncesUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/NoncesUpgradeable.sol";
import {VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/VotesUpgradeable.sol";

import {OFTUpgradeable, OFTCoreUpgradeable} from "@layerzerolabs/oft-evm-upgradeable/contracts/oft/OFTUpgradeable.sol";

import {IGovernanceRewardsManager} from "../interfaces/IGovernanceRewardsManager.sol";
import {ISummerVestingWalletFactory} from "../interfaces/ISummerVestingWalletFactory.sol";
import {DecayController} from "./DecayController.sol";
import {VotingDecayLibrary} from "@summerfi/voting-decay/VotingDecayLibrary.sol";
import {ProtocolAccessManagedUpgradeable} from "@summerfi/access-contracts/contracts/ProtocolAccessManagedUpgradeable.sol";

import {Constants} from "@summerfi/constants/Constants.sol";
import {Percentage} from "@summerfi/percentage-solidity/contracts/Percentage.sol";
// TODO:  to be decided UUPS or transparent
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title SummerTokenV2
 * @dev Implementation of the Summer governance token with vesting, cross-chain, and voting decay capabilities.
 * Delegation of voting power is restricted to the hub chain only.
 * @custom:security-contact security@summer.fi
 */
contract SummerTokenV2 is
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    OFTUpgradeable,
    ERC20BurnableUpgradeable,
    ERC20VotesUpgradeable,
    ERC20PermitUpgradeable,
    ERC20CappedUpgradeable,
    ProtocolAccessManagedUpgradeable,
    DecayController,
    ISummerTokenV2
{
    using VotingDecayLibrary for VotingDecayLibrary.DecayState;

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    // keccak256(abi.encode(uint256(keccak256("summer.storage.SummerTokenV2")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant SummerTokenV2StorageLocation =
        0x8b71b2b2da0c6f129f91672156c90c778c03bf84bf107f1e3b5dec6b40844900;

    uint256 private constant SECONDS_PER_YEAR = 365.25 days;
    uint40 private constant MIN_DECAY_FREE_WINDOW = 30 days;
    uint40 private constant MAX_DECAY_FREE_WINDOW = 365.25 days;

    struct SummerTokenV2Storage {
        uint32 hubChainId;
        address vestingWalletFactory;
        address rewardsManager;
        VotingDecayLibrary.DecayState decayState;
        uint256 transferEnableDate;
        bool transfersEnabled;
        mapping(address account => bool isWhitelisted) whitelistedAddresses;
        bool _initialized;
    }

    function _getSummerTokenV2Storage()
        private
        pure
        returns (SummerTokenV2Storage storage $)
    {
        assembly {
            $.slot := SummerTokenV2StorageLocation
        }
    }

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Modifier to restrict certain functions to only be called on the hub chain.
     * This ensures that governance actions like delegation can only happen on the
     * designated hub chain.
     */
    modifier onlyHubChain() {
        if (block.chainid != _getSummerTokenV2Storage().hubChainId) {
            revert NotHubChain(
                block.chainid,
                _getSummerTokenV2Storage().hubChainId
            );
        }
        _;
    }

    /*//////////////////////////////////////////////////////////////
                                CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Initializes the Summer token
     */
    constructor(
        address _lzEndpoint,
        address _accessManager
    )
        OFTUpgradeable(_lzEndpoint)
        ProtocolAccessManagedUpgradeable(_accessManager)
        DecayController(address(this))
    {
        _disableInitializers();
    }

    /**
     * @dev Completes the token initialization with remaining parameters
     * @param params InitializeParams struct containing additional configuration
     */
    function initialize(InitializeParams memory params) external initializer {
        // TODO: ProtocolAccessManaged init ?
        __Context_init();
        __OFT_init(params.name, params.symbol, params.lzEndpoint);
        __ERC20_init(params.name, params.symbol);
        __ERC20Burnable_init();
        __ERC20Permit_init(params.name);
        __ERC20Votes_init();
        __Ownable_init(params.initialOwner);
        __ERC20Capped_init(params.maxSupply);
        _validateDecayRate(params.initialYearlyDecayRate);
        _validateDecayFreeWindow(params.initialDecayFreeWindow);
        SummerTokenV2Storage storage $ = _getSummerTokenV2Storage();
        $.vestingWalletFactory = params.vestingWalletFactory;
        // Convert yearly rate to per-second rate
        uint256 perSecondRate = Percentage.unwrap(
            params.initialYearlyDecayRate
        ) / SECONDS_PER_YEAR;

        $.decayState.initialize(
            params.initialDecayFreeWindow,
            perSecondRate,
            params.initialDecayFunction
        );

        $.hubChainId = params.hubChainId;
        $.transferEnableDate = params.transferEnableDate;
        $.rewardsManager = params.rewardsManager;

        _mint(msg.sender, params.initialSupply);
    }
    /**
     * @dev Override the upgrade authorization to prevent unauthorized upgrades
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyOwner {}
    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Override the send function to add whitelist checks with self-transfer allowance
     */
    function send(
        SendParam calldata _sendParam,
        MessagingFee calldata _fee,
        address _refundAddress
    )
        external
        payable
        override(IOFT, OFTCoreUpgradeable)
        returns (
            MessagingReceipt memory msgReceipt,
            OFTReceipt memory oftReceipt
        )
    {
        // Convert bytes32 to address using uint256 cast
        address to = address(uint160(uint256(_sendParam.to)));

        // Allow transfers if:
        // 1. Transfers are enabled globally, or
        // 2. The target address is whitelisted, or
        // 3. The sender is sending to themselves
        if (
            !_getSummerTokenV2Storage().transfersEnabled &&
            !_getSummerTokenV2Storage().whitelistedAddresses[to] &&
            to != msg.sender
        ) {
            revert TransferNotAllowed();
        }

        // Debit the sender's balance
        (uint256 amountSentLD, uint256 amountReceivedLD) = _debit(
            msg.sender,
            _sendParam.amountLD,
            _sendParam.minAmountLD,
            _sendParam.dstEid
        );

        // Build the message and options for LayerZero
        (bytes memory message, bytes memory options) = _buildMsgAndOptions(
            _sendParam,
            amountReceivedLD
        );

        // Send the message to the LayerZero endpoint
        msgReceipt = _lzSend(
            _sendParam.dstEid,
            message,
            options,
            _fee,
            _refundAddress
        );

        // Formulate the OFTUpgradeable receipt
        oftReceipt = OFTReceipt(amountSentLD, amountReceivedLD);

        emit OFTSent(
            msgReceipt.guid,
            _sendParam.dstEid,
            msg.sender,
            amountSentLD,
            amountReceivedLD
        );
    }
    function rewardsManager() external view returns (address) {
        return _getSummerTokenV2Storage().rewardsManager;
    }

    /// @inheritdoc ISummerTokenV2
    function getDecayFreeWindow() external view returns (uint40) {
        return _getSummerTokenV2Storage().decayState.decayFreeWindow;
    }

    /// @inheritdoc ISummerTokenV2
    function getDecayFactor(address account) external view returns (uint256) {
        return
            _getSummerTokenV2Storage().decayState.getDecayFactor(
                account,
                _getDelegateTo
            );
    }

    /// @inheritdoc ISummerTokenV2
    function getPastDecayFactor(
        address account,
        uint256 timepoint
    ) external view returns (uint256) {
        return
            _getSummerTokenV2Storage().decayState.getHistoricalDecayFactor(
                account,
                timepoint
            );
    }

    /// @inheritdoc ISummerTokenV2
    function getDelegationChainLength(
        address account
    ) external view returns (uint256) {
        return
            _getSummerTokenV2Storage().decayState.getDelegationChainLength(
                account,
                _getDelegateTo
            );
    }

    /// @inheritdoc ISummerTokenV2
    function getDecayRatePerYear() external view returns (Percentage) {
        // Convert per-second rate to yearly rate using simple multiplication
        // Note: We use simple multiplication rather than compound rate calculation
        // because:
        // 1. It's more intuitive for governance participants
        // 2. The decay rate is meant to be a simple linear reduction
        // 3. For typical decay rates, the difference is minimal
        uint256 yearlyRate = _getDecayRatePerSecond() * SECONDS_PER_YEAR;
        return Percentage.wrap(yearlyRate);
    }

    /*//////////////////////////////////////////////////////////////
                            EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ISummerTokenV2
    function setDecayRatePerYear(
        Percentage newYearlyRate
    ) external onlyGovernor {
        _validateDecayRate(newYearlyRate);
        // Convert yearly rate to per-second rate
        uint256 perSecondRate = Percentage.unwrap(newYearlyRate) /
            SECONDS_PER_YEAR;
        _getSummerTokenV2Storage().decayState.setDecayRatePerSecond(
            perSecondRate
        );
    }

    /// @inheritdoc ISummerTokenV2
    function setDecayFreeWindow(uint40 newWindow) external onlyGovernor {
        _validateDecayFreeWindow(newWindow);
        _getSummerTokenV2Storage().decayState.setDecayFreeWindow(newWindow);
    }

    /// @inheritdoc ISummerTokenV2
    function setDecayFunction(
        VotingDecayLibrary.DecayFunction newFunction
    ) external onlyGovernor {
        _getSummerTokenV2Storage().decayState.setDecayFunction(newFunction);
    }

    /// @inheritdoc ISummerTokenV2
    function updateDecayFactor(address account) external onlyDecayController {
        _getSummerTokenV2Storage().decayState.updateDecayFactor(
            account,
            _getDelegateTo
        );
    }

    /// @inheritdoc ISummerTokenV2
    function enableTransfers() external onlyGovernor {
        if (_getSummerTokenV2Storage().transfersEnabled) {
            revert TransfersAlreadyEnabled();
        }
        if (block.timestamp < _getSummerTokenV2Storage().transferEnableDate) {
            revert TransfersCannotBeEnabledYet();
        }
        _getSummerTokenV2Storage().transfersEnabled = true;
        emit TransfersEnabled();
    }

    /// @inheritdoc ISummerTokenV2
    function addToWhitelist(address account) external onlyGovernor {
        _getSummerTokenV2Storage().whitelistedAddresses[account] = true;
        emit AddressWhitelisted(account);
    }

    /// @inheritdoc ISummerTokenV2
    function removeFromWhitelist(address account) external onlyGovernor {
        _getSummerTokenV2Storage().whitelistedAddresses[account] = false;
        emit AddressRemovedFromWhitelist(account);
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Delegates voting power to a specified address. Can only be called on the hub chain.
     * @param delegatee The address to delegate voting power to
     * @dev Updates the decay factor for the caller
     * @custom:restriction This function can only be called on the hub chain
     */
    function delegate(
        address delegatee
    )
        public
        override(IVotes, VotesUpgradeable)
        updateDecay(_msgSender())
        onlyHubChain
    {
        if (delegatee == address(0)) {
            uint256 stakingBalance = IGovernanceRewardsManager(
                _getSummerTokenV2Storage().rewardsManager
            ).balanceOf(_msgSender());

            if (stakingBalance > 0) {
                revert CannotUndelegateWhileStaked();
            }
        }

        // Only initialize delegatee if they don't have decay info yet
        if (
            delegatee != address(0) &&
            !_getSummerTokenV2Storage().decayState.hasDecayInfo(delegatee)
        ) {
            _getSummerTokenV2Storage().decayState.initializeAccount(delegatee);
        }
        super.delegate(delegatee);
    }

    /**
     * @dev Required override to resolve inheritance conflict between IERC20Permit, ERC20Permit, and Nonces contracts.
     * This implementation simply calls the parent implementation and exists solely to satisfy the compiler.
     * @param owner The address to get nonces for
     * @return The current nonce for the specified owner
     */
    function nonces(
        address owner
    )
        public
        view
        override(IERC20Permit, ERC20PermitUpgradeable, NoncesUpgradeable)
        returns (uint256)
    {
        return super.nonces(owner);
    }

    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    /// @inheritdoc ISummerTokenV2
    function getVotes(
        address account
    ) public view override(ISummerTokenV2, VotesUpgradeable) returns (uint256) {
        uint256 rawVotingPower = super.getVotes(account);

        return
            _getSummerTokenV2Storage().decayState.getVotingPower(
                account,
                rawVotingPower,
                _getDelegateTo
            );
    }

    /// @inheritdoc ISummerTokenV2
    function getPastVotes(
        address account,
        uint256 timepoint
    ) public view override(ISummerTokenV2, VotesUpgradeable) returns (uint256) {
        uint256 pastVotingUnits = super.getPastVotes(account, timepoint);
        uint256 historicalDecayFactor = _getSummerTokenV2Storage()
            .decayState
            .getHistoricalDecayFactor(account, timepoint);

        return (pastVotingUnits * historicalDecayFactor) / Constants.WAD;
    }

    /// @inheritdoc ISummerTokenV2
    function getRawVotesAt(
        address account,
        uint256 timestamp
    ) public view returns (uint256) {
        return
            timestamp == 0
                ? super.getVotes(account)
                : super.getPastVotes(account, timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Internal helper to get the per-second decay rate
    /// @return The decay rate per second
    function _getDecayRatePerSecond() internal view returns (uint256) {
        return _getSummerTokenV2Storage().decayState.decayRatePerSecond;
    }

    /**
     * @dev Returns the delegate address for a given account, implementing VotingDecayLibrary's abstract method
     * @param account The address to check delegation for
     * @return The delegate address for the account
     * @custom:relationship-to-votingdecay
     * - Required by VotingDecayLibrary to track delegation chains
     * - Used in decay factor calculations to follow delegation paths
     * - Supports VotingDecayLibrary's MAX_DELEGATION_DEPTH enforcement
     * @custom:implementation-notes
     * - Delegates are used both for voting power and decay factor inheritance
     * - Returns zero address if account has not delegated
     * - Uses OpenZeppelin's ERC20Votes delegation system via super.delegates()
     */
    function _getDelegateTo(address account) internal view returns (address) {
        return super.delegates(account);
    }

    /**
     * @dev Internal function to update token balances.
     * @param from The address to transfer tokens from.
     * @param to The address to transfer tokens to.
     * @param amount The amount of tokens to transfer.
     */
    function _update(
        address from,
        address to,
        uint256 amount
    )
        internal
        override(
            ERC20Upgradeable,
            ERC20VotesUpgradeable,
            ERC20CappedUpgradeable
        )
    {
        if (!_canTransfer(from, to)) {
            revert TransferNotAllowed();
        }
        super._update(from, to, amount);
    }

    function _canTransfer(
        address from,
        address to
    ) internal view returns (bool) {
        // Allow minting and burning
        if (from == address(0) || to == address(0)) return true;

        // Allow transfers if globally enabled
        if (_getSummerTokenV2Storage().transfersEnabled) return true;

        // Allow transfers involving whitelisted addresses
        if (
            _getSummerTokenV2Storage().whitelistedAddresses[from] ||
            _getSummerTokenV2Storage().whitelistedAddresses[to]
        ) return true;

        return false;
    }

    function _checkInitializing() internal view override {
        super._checkInitializing();
    }

    function _contextSuffixLength() internal view override returns (uint256) {
        return super._contextSuffixLength();
    }

    // function _mint(
    //     address account,
    //     uint256 amount
    // ) internal override(ERC20Upgradeable) {
    //     super._mint(account, amount);
    // }

    /**
     * @dev Burns tokens from the sender's specified balance.
     * @param _from The address to debit the tokens from.
     * @param _amountLD The amount of tokens to send in local decimals.
     * @param _minAmountLD The minimum amount to send in local decimals.
     * @param _dstEid The destination chain ID.
     * @return amountSentLD The amount sent in local decimals.
     * @return amountReceivedLD The amount received in local decimals on the remote.
     */
    function _debit(
        address _from,
        uint256 _amountLD,
        uint256 _minAmountLD,
        uint32 _dstEid
    )
        internal
        override
        returns (uint256 amountSentLD, uint256 amountReceivedLD)
    {
        (amountSentLD, amountReceivedLD) = _debitView(
            _amountLD,
            _minAmountLD,
            _dstEid
        );

        // @dev In NON-default OFTUpgradeable, amountSentLD could be 100, with a 10% fee, the amountReceivedLD amount is 90,
        // therefore amountSentLD CAN differ from amountReceivedLD.

        // @dev Default OFTUpgradeable burns on src.
        _burn(_from, amountSentLD);
    }

    /**
     * @dev Overrides the default _getVotingUnits function to include all user tokens in voting power, including locked
     * up tokens in vesting wallets
     * @param account The address to get voting units for
     * @return uint256 The total number of voting units for the account
     * @custom:internal-logic
     * - Retrieves the direct token balance of the account
     * - Checks if the account has an associated vesting wallet
     * - If a vesting wallet exists, adds its balance to the account's direct balance
     * @custom:effects
     * - Does not modify any state, view function only
     * @custom:security-considerations
     * - Ensures that tokens in vesting contracts still contribute to voting power
     * - May increase the voting power of accounts with vesting wallets compared to standard ERC20Votes implementation
     * - Consider the implications of this increased voting power on governance decisions
     * @custom:gas-considerations
     * - This function performs an additional storage read and potential balance check compared to the standard
     * implementation
     * - May slightly increase gas costs for voting-related operations
     */
    function _getVotingUnits(
        address account
    ) internal view override returns (uint256) {
        // Get raw voting units first
        uint256 directBalance = balanceOf(account);
        uint256 stakingBalance = IGovernanceRewardsManager(
            _getSummerTokenV2Storage().rewardsManager
        ).balanceOf(account);
        uint256 vestingBalance = ISummerVestingWalletFactory(
            _getSummerTokenV2Storage().vestingWalletFactory
        ).vestingWallets(account) != address(0)
            ? balanceOf(
                ISummerVestingWalletFactory(
                    _getSummerTokenV2Storage().vestingWalletFactory
                ).vestingWallets(account)
            )
            : 0;

        return directBalance + stakingBalance + vestingBalance;
    }

    /**
     * @dev Transfers, mints, or burns voting units while managing delegate votes.
     * @param from The address transferring voting units (zero address for mints)
     * @param to The address receiving voting units (zero address for burns)
     * @param amount The amount of voting units to transfer
     * @custom:internal-logic
     * - Skips vote tracking for transfers involving the rewards manager
     * - Updates total supply checkpoints for mints and burns
     * - Moves delegate votes between accounts
     * @custom:security-considerations
     * - Ensures voting power is correctly tracked when tokens move between accounts
     * - Special handling for staking/unstaking to prevent double-counting
     */
    function _transferVotingUnits(
        address from,
        address to,
        uint256 amount
    ) internal override {
        bool isRewardsManagerTransfer = _handleRewardsManagerVotingTransfer(
            from,
            to
        );
        bool isVestingWalletTransfer = _handleVestingWalletVotingTransfer(
            from,
            to,
            amount
        );

        if (!isRewardsManagerTransfer && !isVestingWalletTransfer) {
            super._transferVotingUnits(from, to, amount);
        }
    }

    /**
     * @dev Handles voting power transfers involving vesting wallets
     * @param from Source address
     * @param to Destination address
     * @param amount Amount of voting units to transfer
     * @return bool True if the transfer was handled (vesting wallet case), false otherwise
     * @custom:internal-logic
     * - Checks if either from/to is a vesting wallet
     * - Handles voting power redirections for vesting wallet transfers
     */
    function _handleVestingWalletVotingTransfer(
        address from,
        address to,
        uint256 amount
    ) internal returns (bool) {
        // Case 1: Transfer TO vesting wallet
        address vestingWalletOwner = ISummerVestingWalletFactory(
            _getSummerTokenV2Storage().vestingWalletFactory
        ).vestingWalletOwners(to);
        if (vestingWalletOwner != address(0)) {
            // Skip if transfer is from the owner (they already have voting power)
            if (from != vestingWalletOwner) {
                // Transfer voting power to beneficiary instead of vesting wallet
                super._transferVotingUnits(from, vestingWalletOwner, amount);
            }
            return true;
        }

        // Case 2: Transfer FROM vesting wallet
        address fromVestingWalletOwner = ISummerVestingWalletFactory(
            _getSummerTokenV2Storage().vestingWalletFactory
        ).vestingWalletOwners(from);
        if (fromVestingWalletOwner != address(0)) {
            // Skip if transfer is to the beneficiary (they already have voting power)
            if (to == fromVestingWalletOwner) {
                return true;
            }
            // Transfer voting power from beneficiary to recipient
            super._transferVotingUnits(fromVestingWalletOwner, to, amount);
            return true;
        }

        return false;
    }

    /**
     * @dev Handles voting power transfers involving the rewards manager
     * @param from Source address
     * @param to Destination address
     * @return bool True if vote tracking should be skipped (rewards manager case), false if normal vote tracking should occur
     * @custom:internal-logic
     * - Returns true to skip vote tracking for two specific cases:
     *   1. When tokens come FROM the wrapped staking token (used for both unstaking and reward claims)
     *   2. When staking: transfers TO the rewards manager
     * - Returns false for all other transfers, allowing normal vote tracking
     * @custom:rationale
     * - Staking/unstaking/reward operations are handled separately by the rewards manager
     * - The wrapped staking token is used as the source for both unstaking and claiming rewards
     * - Skipping vote tracking here prevents double-counting of voting power since
     *   the rewards manager maintains its own balance tracking for staked tokens
     */
    function _handleRewardsManagerVotingTransfer(
        address from,
        address to
    ) internal view virtual returns (bool) {
        // Skip vote tracking for unstaking/rewards (from wrapped token) and staking (to rewards manager)
        if (
            from ==
            IGovernanceRewardsManager(_getSummerTokenV2Storage().rewardsManager)
                .wrappedStakingToken() ||
            to == address(_getSummerTokenV2Storage().rewardsManager)
        ) {
            return true;
        }
        return false;
    }

    /// @dev Validates that the decay rate is between 1% and 50%
    /// @param rate The yearly decay rate to validate
    function _validateDecayRate(Percentage rate) internal pure {
        uint256 unwrappedRate = Percentage.unwrap(rate);
        if (unwrappedRate > Constants.WAD / 2) {
            revert DecayRateTooHigh(unwrappedRate);
        }
    }

    /// @dev Validates that the decay free window is between 30 days and 365.25 days
    /// @param window The window duration to validate
    function _validateDecayFreeWindow(uint40 window) internal pure {
        if (window < MIN_DECAY_FREE_WINDOW || window > MAX_DECAY_FREE_WINDOW) {
            revert InvalidDecayFreeWindow(window);
        }
    }
}
