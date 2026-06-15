// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title ComplianceRegistry
/// @notice A standalone, on-chain KYC / accreditation / jurisdiction attestation registry —
/// a composable primitive any Mantle protocol can read *before* letting an address into a gated
/// flow. Licensed KYC issuers post `Attestation`s for subjects; any protocol can then call the
/// pure `screen(subject)` / `screenAccredited(subject)` views to ask "is this address eligible,
/// and if not, why?" — the same spirit as ReefGuard and TrustOracle. Attestations carry a KYC
/// flag, an accredited-investor flag, an ISO-3166 numeric country code, validity bounds, and a
/// hash of the off-chain evidence; jurisdictions can be blocked by the owner.
contract ComplianceRegistry {
    struct Attestation {
        bool kyc;
        bool accredited;
        uint16 country;
        uint64 issuedAt;
        uint64 expiresAt;
        bytes32 evidenceHash;
    }

    address public owner;
    mapping(address => bool) public isIssuer;
    mapping(uint16 => bool) public blockedCountry; // ISO-3166 numeric country code blocklist
    mapping(address => Attestation) public attestationOf;
    uint64 public demoValiditySeconds; // default 30 days
    bool public demoEnabled = true; // testnet self-attest switch; owner disables for production

    event Attested(
        address indexed subject, bool kyc, bool accredited, uint16 country, uint64 expiresAt, bytes32 evidenceHash
    );
    event Revoked(address indexed subject);
    event IssuerSet(address indexed issuer, bool allowed);
    event CountryBlocked(uint16 indexed country, bool blocked);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event DemoValiditySet(uint64 secs);
    event DemoEnabledSet(bool enabled);

    modifier onlyOwner() {
        require(msg.sender == owner, "not owner");
        _;
    }

    modifier onlyIssuer() {
        require(isIssuer[msg.sender], "not issuer");
        _;
    }

    constructor() {
        owner = msg.sender;
        isIssuer[msg.sender] = true;
        demoValiditySeconds = 30 days;
    }

    function setIssuer(address issuer, bool allowed) external onlyOwner {
        isIssuer[issuer] = allowed;
        emit IssuerSet(issuer, allowed);
    }

    function setBlockedCountry(uint16 country, bool blocked) external onlyOwner {
        blockedCountry[country] = blocked;
        emit CountryBlocked(country, blocked);
    }

    function setDemoValidity(uint64 secs) external onlyOwner {
        demoValiditySeconds = secs;
        emit DemoValiditySet(secs);
    }

    function setDemoEnabled(bool enabled) external onlyOwner {
        demoEnabled = enabled;
        emit DemoEnabledSet(enabled);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "zero addr");
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    /// @notice Post an attestation for `subject`. Restricted to licensed KYC issuers.
    /// Records `issuedAt = block.timestamp` and stores the rest verbatim.
    function attest(address subject, bool kyc, bool accredited, uint16 country, uint64 expiresAt, bytes32 evidenceHash)
        external
        onlyIssuer
    {
        attestationOf[subject] = Attestation({
            kyc: kyc,
            accredited: accredited,
            country: country,
            issuedAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            evidenceHash: evidenceHash
        });
        emit Attested(subject, kyc, accredited, country, expiresAt, evidenceHash);
    }

    function revoke(address subject) external onlyIssuer {
        delete attestationOf[subject];
        emit Revoked(subject);
    }

    /// @notice TESTNET DEMO ONLY. Lets any caller self-issue a passing KYC + accredited
    /// attestation so they can experience the gated flow without a real issuer. This is NOT a
    /// real compliance check: in production every attestation comes from a licensed KYC issuer
    /// via `attest()`, and the owner disables this with `setDemoEnabled(false)`. country is 0
    /// (unset) and the evidence hash is a fixed demo marker.
    function selfAttestDemo() external {
        require(demoEnabled, "demo disabled");
        uint64 expiresAt = uint64(block.timestamp) + demoValiditySeconds;
        bytes32 evidenceHash = keccak256("reef-testnet-demo-kyc");
        attestationOf[msg.sender] = Attestation({
            kyc: true,
            accredited: true,
            country: 0,
            issuedAt: uint64(block.timestamp),
            expiresAt: expiresAt,
            evidenceHash: evidenceHash
        });
        emit Attested(msg.sender, true, true, 0, expiresAt, evidenceHash);
    }

    /// @notice Compliance check. Returns (true, "ok") if `subject` may enter a gated flow, else
    /// (false, reason). Pure view — any protocol can call it for free in its own gating checks.
    function screen(address subject) external view returns (bool eligible, string memory reason) {
        return _screen(subject);
    }

    /// @notice Like `screen`, but additionally requires accredited-investor status.
    function screenAccredited(address subject) external view returns (bool eligible, string memory reason) {
        (bool ok, string memory r) = _screen(subject);
        if (!ok) return (ok, r);
        if (!attestationOf[subject].accredited) return (false, "accredited investor status required");
        return (true, "ok");
    }

    function isEligible(address subject) external view returns (bool) {
        (bool ok,) = _screen(subject);
        return ok;
    }

    function _screen(address subject) internal view returns (bool eligible, string memory reason) {
        Attestation storage a = attestationOf[subject];
        if (!a.kyc) return (false, "no KYC attestation");
        if (a.expiresAt != 0 && block.timestamp > a.expiresAt) return (false, "attestation expired");
        if (blockedCountry[a.country]) return (false, "jurisdiction blocked");
        return (true, "ok");
    }
}
