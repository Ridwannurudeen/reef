// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {AgentIdentity} from "../src/AgentIdentity.sol";
import {AgentVault} from "../src/AgentVault.sol";
import {AdapterRegistry} from "../src/AdapterRegistry.sol";
import {FusionXAdapter} from "../src/adapters/FusionXAdapter.sol";

/// @notice Minimal named, openly-mintable ERC-20 for the testnet DEX-NAV demo.
contract DemoToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    constructor(string memory n, string memory s) {
        name = n;
        symbol = s;
    }

    function mint(address to, uint256 amt) external {
        balanceOf[to] += amt;
        totalSupply += amt;
        emit Transfer(address(0), to, amt);
    }

    function approve(address sp, uint256 amt) external override returns (bool) {
        allowance[msg.sender][sp] = amt;
        emit Approval(msg.sender, sp, amt);
        return true;
    }

    function transfer(address to, uint256 amt) external override returns (bool) {
        balanceOf[msg.sender] -= amt;
        balanceOf[to] += amt;
        emit Transfer(msg.sender, to, amt);
        return true;
    }

    function transferFrom(address f, address to, uint256 amt) external override returns (bool) {
        uint256 a = allowance[f][msg.sender];
        if (a != type(uint256).max) allowance[f][msg.sender] = a - amt;
        balanceOf[f] -= amt;
        balanceOf[to] += amt;
        emit Transfer(f, to, amt);
        return true;
    }
}

interface IFusionXFactory {
    function createPair(address a, address b) external returns (address pair);
    function getPair(address a, address b) external view returns (address pair);
}

interface IFusionXPair {
    function mint(address to) external returns (uint256 liquidity);
}

/// @notice Standalone REAL DEX-backed-NAV demo on Mantle Sepolia (chain 5003).
/// Stands up its own DEEP FusionX V2 pool (so price impact is small), an AgentVault,
/// and a FusionXAdapter, then deposits and deploys the vault's reserve into a live long
/// position. The vault's nav() is then a real on-chain AMM mark-to-market — NOT simulated
/// linear yield. Fully isolated from the live 5-vault leaderboard instance.
///
/// Required env: PRIVATE_KEY (the Sepolia deployer; ~25 MNT gas is plenty).
/// Run (simulate): forge script script/DeployDexNav.s.sol:DeployDexNav --rpc-url mantle_sepolia
/// Run (broadcast): add --broadcast --slow
contract DeployDexNav is Script {
    address constant ROUTER = 0x272465431A6b86E3B9E5b9bD33f5D103a3F59eDb;
    address constant FACTORY = 0x8734110e5e1dcF439c7F549db740E546fea82d66;

    uint256 constant POOL_SEED = 1_000_000e18; // deep 1:1 pool → small price impact
    uint256 constant DEPOSIT = 10_000e18;
    uint256 constant DEPLOY = 8_000e18; // 80% into the long, 20% idle redemption buffer

    function run() external {
        require(block.chainid == 5003, "not mantle sepolia");
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address me = vm.addr(pk);
        vm.startBroadcast(pk);

        // 1. demo tokens (named for legibility on Mantlescan)
        DemoToken asset = new DemoToken("Reef Demo USD", "rdUSD");
        DemoToken long = new DemoToken("Reef Demo ETH", "rdETH");

        // 2. deep 1:1 FusionX pool via factory + low-level pair.mint (canonical V2 add)
        asset.mint(me, POOL_SEED);
        long.mint(me, POOL_SEED);
        address pair = IFusionXFactory(FACTORY).createPair(address(asset), address(long));
        asset.transfer(pair, POOL_SEED);
        long.transfer(pair, POOL_SEED);
        IFusionXPair(pair).mint(me);

        // 3. reef vault on the demo asset
        AgentIdentity identity = new AgentIdentity();
        AdapterRegistry registry = new AdapterRegistry();
        uint256 agentId = identity.register();
        AgentVault vault = new AgentVault(address(asset), agentId, address(identity), address(registry));
        identity.setReputationSource(agentId, address(vault));

        // 4. real DEX adapter (3% slippage tolerance), vetted + wired
        FusionXAdapter adapter = new FusionXAdapter(address(asset), address(long), ROUTER, address(vault), 300);
        registry.approveAdapter(address(adapter));
        vault.approveStrategy(address(adapter));

        // 5. deposit + deploy a slice into the live long position
        asset.mint(me, DEPOSIT);
        asset.approve(address(vault), DEPOSIT);
        vault.deposit(DEPOSIT);
        vault.deployToStrategy(address(adapter), DEPLOY);
        uint256 navAfterDeploy = vault.nav();
        vm.stopBroadcast();

        console.log("=== Reef DEX-NAV demo (Sepolia 5003) ===");
        console.log("asset (rdUSD)    :", address(asset));
        console.log("long  (rdETH)    :", address(long));
        console.log("pair             :", pair);
        console.log("AgentIdentity    :", address(identity));
        console.log("AdapterRegistry  :", address(registry));
        console.log("AgentVault       :", address(vault));
        console.log("FusionXAdapter   :", address(adapter));
        console.log("agentId          :", agentId);
        console.log("nav after deploy :", navAfterDeploy);
        console.log("(nav is live AMM mark-to-market; ~1e18 minus real round-trip trading cost)");
    }
}
