// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {AgentIdentity} from "./AgentIdentity.sol";
import {ReentrancyGuard} from "./utils/ReentrancyGuard.sol";

/// @title SignalMarket
/// @notice Agent-to-agent commerce primitive. A provider agent lists a signal at a fixed
/// price under a category; a consumer agent buys it and payment routes to the provider's
/// wallet. The evidence hash is recorded on-chain so the off-chain signal payload can be
/// verifiably matched later. Lifetime sales/revenue are tracked per provider so the A2A
/// economy is queryable on-chain. Reputation is intentionally NOT credited here: under the
/// vault-only model only an agent's own AgentVault may write its ERC-8004 reputation, so a
/// free A2A purchase cannot be used to farm reputation.
contract SignalMarket is ReentrancyGuard {
    AgentIdentity public immutable identity;

    struct Listing {
        uint256 providerAgentId;
        uint256 priceWei;
        string category;
        bool active;
    }

    /// @notice Flattened view of an active listing plus the provider's lifetime economy stats.
    struct ListingView {
        uint256 id;
        uint256 providerAgentId;
        uint256 priceWei;
        string category;
        uint256 sales;
        uint256 revenueWei;
    }

    uint256 public nextListingId = 1;
    mapping(uint256 => Listing) public listings;

    // --- A2A economy metrics (on-chain, no log scanning needed) ---
    mapping(uint256 => uint256) public salesOf; // providerAgentId -> lifetime sales count
    mapping(uint256 => uint256) public revenueOf; // providerAgentId -> lifetime wei earned
    uint256 public totalSales;
    uint256 public totalRevenueWei;

    event ListingCreated(uint256 indexed listingId, uint256 indexed providerAgentId, uint256 priceWei, string category);
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

    function createListing(uint256 providerAgentId, uint256 priceWei, string calldata category)
        external
        returns (uint256 listingId)
    {
        require(identity.getAgentWallet(providerAgentId) == msg.sender, "not provider");
        require(priceWei > 0, "zero price");
        require(bytes(category).length > 0, "no category");
        listingId = nextListingId++;
        listings[listingId] =
            Listing({providerAgentId: providerAgentId, priceWei: priceWei, category: category, active: true});
        emit ListingCreated(listingId, providerAgentId, priceWei, category);
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

        // Effects before interactions (the provider/buyer calls are external).
        salesOf[l.providerAgentId] += 1;
        revenueOf[l.providerAgentId] += l.priceWei;
        totalSales += 1;
        totalRevenueWei += l.priceWei;

        address provider = identity.getAgentWallet(l.providerAgentId);
        (bool ok,) = provider.call{value: l.priceWei}("");
        require(ok, "pay");
        if (msg.value > l.priceWei) {
            (bool refund,) = msg.sender.call{value: msg.value - l.priceWei}("");
            require(refund, "refund");
        }

        emit SignalPurchased(listingId, l.providerAgentId, consumerAgentId, l.priceWei, evidenceHash);
    }

    /// @notice All currently-active listings with each provider's lifetime economy stats —
    /// one call for the marketplace UI / snapshot (no per-id round-trips or log scanning).
    function getActiveListings() external view returns (ListingView[] memory out) {
        uint256 n;
        for (uint256 id = 1; id < nextListingId; id++) {
            if (listings[id].active) n++;
        }
        out = new ListingView[](n);
        uint256 j;
        for (uint256 id = 1; id < nextListingId; id++) {
            Listing storage l = listings[id];
            if (!l.active) continue;
            out[j++] = ListingView({
                id: id,
                providerAgentId: l.providerAgentId,
                priceWei: l.priceWei,
                category: l.category,
                sales: salesOf[l.providerAgentId],
                revenueWei: revenueOf[l.providerAgentId]
            });
        }
    }
}
