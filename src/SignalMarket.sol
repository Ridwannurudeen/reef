// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AgentIdentity} from "./AgentIdentity.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";

/// @title SignalMarket
/// @notice Agent-to-agent commerce primitive. A provider agent lists a signal
/// at a fixed price; a consumer agent buys it, payment routes to the provider's
/// wallet, and both agents accrue ERC-8004 reputation: provider for the sale,
/// consumer for completing the transaction. Evidence hash is recorded on-chain
/// so the off-chain signal payload can be verifiably matched later.
contract SignalMarket is ReentrancyGuard {
    AgentIdentity public immutable identity;

    struct Listing {
        uint256 providerAgentId;
        uint256 priceWei;
        bool active;
    }

    uint256 public nextListingId = 1;
    mapping(uint256 => Listing) public listings;

    /// @dev Reputation bumps applied on each successful purchase.
    int128 public constant PROVIDER_REPUTATION = 1e18;
    int128 public constant CONSUMER_REPUTATION = 1e17;

    event ListingCreated(uint256 indexed listingId, uint256 indexed providerAgentId, uint256 priceWei);
    event ListingDeactivated(uint256 indexed listingId);
    event SignalPurchased(
        uint256 indexed listingId,
        uint256 indexed providerAgentId,
        uint256 indexed consumerAgentId,
        uint256 paid,
        bytes32 evidenceHash
    );

    constructor(address identity_) {
        require(identity_ != address(0), "zero identity");
        identity = AgentIdentity(identity_);
    }

    function createListing(uint256 providerAgentId, uint256 priceWei) external returns (uint256 listingId) {
        require(identity.getAgentWallet(providerAgentId) == msg.sender, "not provider");
        require(priceWei > 0, "zero price");
        listingId = nextListingId++;
        listings[listingId] = Listing({providerAgentId: providerAgentId, priceWei: priceWei, active: true});
        emit ListingCreated(listingId, providerAgentId, priceWei);
    }

    function deactivate(uint256 listingId) external {
        Listing storage l = listings[listingId];
        require(l.active, "not active");
        require(identity.getAgentWallet(l.providerAgentId) == msg.sender, "not provider");
        l.active = false;
        emit ListingDeactivated(listingId);
    }

    function purchaseSignal(uint256 listingId, uint256 consumerAgentId, bytes32 evidenceHash)
        external
        payable
        nonReentrant
    {
        Listing memory l = listings[listingId];
        require(l.active, "not active");
        require(l.providerAgentId != consumerAgentId, "self deal");
        require(msg.value >= l.priceWei, "underpaid");
        require(identity.getAgentWallet(consumerAgentId) == msg.sender, "not consumer");
        require(evidenceHash != bytes32(0), "zero evidence");

        address provider = identity.getAgentWallet(l.providerAgentId);
        (bool ok,) = provider.call{value: l.priceWei}("");
        require(ok, "pay");
        if (msg.value > l.priceWei) {
            (bool refund,) = msg.sender.call{value: msg.value - l.priceWei}("");
            require(refund, "refund");
        }

        identity.giveFeedback(l.providerAgentId, PROVIDER_REPUTATION, 18);
        identity.giveFeedback(consumerAgentId, CONSUMER_REPUTATION, 18);

        emit SignalPurchased(listingId, l.providerAgentId, consumerAgentId, l.priceWei, evidenceHash);
    }
}
