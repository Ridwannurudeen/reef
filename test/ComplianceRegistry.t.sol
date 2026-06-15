// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ComplianceRegistry} from "../src/ComplianceRegistry.sol";

contract ComplianceRegistryTest is Test {
    ComplianceRegistry reg;

    address issuer2 = address(0x1551E2);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address bad = address(0xBAD);

    uint16 constant US = 840;
    uint16 constant IR = 364;

    function setUp() public {
        reg = new ComplianceRegistry();
    }

    function test_attestThenScreenOk() public {
        reg.attest(alice, true, false, US, uint64(block.timestamp + 1 days), bytes32("ev"));
        (bool ok, string memory r) = reg.screen(alice);
        assertTrue(ok);
        assertEq(r, "ok");
        assertTrue(reg.isEligible(alice));
    }

    function test_noAttestationNotEligible() public view {
        (bool ok, string memory r) = reg.screen(bob);
        assertFalse(ok);
        assertEq(r, "no KYC attestation");
        assertFalse(reg.isEligible(bob));
    }

    function test_expired() public {
        reg.attest(alice, true, false, US, uint64(block.timestamp + 1 days), bytes32("ev"));
        vm.warp(block.timestamp + 2 days);
        (bool ok, string memory r) = reg.screen(alice);
        assertFalse(ok);
        assertEq(r, "attestation expired");
    }

    function test_jurisdictionBlocked() public {
        reg.setBlockedCountry(IR, true);
        reg.attest(alice, true, false, IR, uint64(block.timestamp + 1 days), bytes32("ev"));
        (bool ok, string memory r) = reg.screen(alice);
        assertFalse(ok);
        assertEq(r, "jurisdiction blocked");
    }

    function test_screenAccreditedRequiresAccredited() public {
        reg.attest(alice, true, false, US, uint64(block.timestamp + 1 days), bytes32("ev"));
        (bool ok, string memory r) = reg.screenAccredited(alice);
        assertFalse(ok);
        assertEq(r, "accredited investor status required");

        reg.attest(bob, true, true, US, uint64(block.timestamp + 1 days), bytes32("ev"));
        (bool ok2, string memory r2) = reg.screenAccredited(bob);
        assertTrue(ok2);
        assertEq(r2, "ok");
    }

    function test_selfAttestDemoMakesCallerEligible() public {
        vm.prank(alice);
        reg.selfAttestDemo();
        (bool ok, string memory r) = reg.screen(alice);
        assertTrue(ok);
        assertEq(r, "ok");
        (bool ok2,) = reg.screenAccredited(alice);
        assertTrue(ok2);
    }

    function test_onlyIssuerAttest() public {
        vm.prank(bad);
        vm.expectRevert(bytes("not issuer"));
        reg.attest(alice, true, false, US, uint64(block.timestamp + 1 days), bytes32("ev"));
    }

    function test_onlyOwnerSetters() public {
        vm.prank(bad);
        vm.expectRevert(bytes("not owner"));
        reg.setIssuer(bad, true);

        vm.prank(bad);
        vm.expectRevert(bytes("not owner"));
        reg.setBlockedCountry(IR, true);

        vm.prank(bad);
        vm.expectRevert(bytes("not owner"));
        reg.setDemoValidity(1 days);
    }

    function test_revokeClears() public {
        reg.attest(alice, true, false, US, uint64(block.timestamp + 1 days), bytes32("ev"));
        assertTrue(reg.isEligible(alice));
        reg.revoke(alice);
        (bool ok, string memory r) = reg.screen(alice);
        assertFalse(ok);
        assertEq(r, "no KYC attestation");
    }

    function test_setIssuerLetsNewIssuerAttest() public {
        reg.setIssuer(issuer2, true);
        vm.prank(issuer2);
        reg.attest(alice, true, false, US, uint64(block.timestamp + 1 days), bytes32("ev"));
        assertTrue(reg.isEligible(alice));
    }
}
