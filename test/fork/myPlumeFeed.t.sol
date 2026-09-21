// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/Periphery/MyPlumeFeed.sol";
import "../../src/stPlumeMinter.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract MyPlumeFeedForkTest is Test {
    MyPlumeFeed feed;
    address owner = address(0x1234);
    address timelock = address(0x5678);

    // Mainnet Main deployment (per script/deployMinter.s.sol)
    address constant MY_PLUME_TOKEN = 0x5c982097b505A3940823a11E6157e9C86aF08987;
    address constant MINTER_PROXY = 0xE4274Bc25BA313364DE71F104acF27746c6278Cb;
    address constant MINTER_PROXY_ADMIN = 0xB7791d7039284c2021C0F77120C84609B03BB2E9;
    address constant MINTER_PROXY_ADMIN_OWNER = 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c;
    address constant ST_PLUME_REWARDS = 0x2E420ac76a43fC94F05168Cb8DCf4996b717dA17;
    address constant PLUME_STAKING = 0x30c791E4654EdAc575FA1700eD8633CB2FEDE871;

    function setUp() public {
        // Upgrade the deployed minter to the latest implementation that exposes
        // `slashedAmount()` — the new MyPlumeFeed.getTotalDeposits() reads it.
        stPlumeMinter newMinterImpl = new stPlumeMinter();
        vm.prank(MINTER_PROXY_ADMIN_OWNER);
        ProxyAdmin(MINTER_PROXY_ADMIN).upgrade(
            TransparentUpgradeableProxy(payable(MINTER_PROXY)),
            address(newMinterImpl)
        );

        ProxyAdmin admin = new ProxyAdmin();
        MyPlumeFeed impl = new MyPlumeFeed();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), address(admin), bytes(""));
        feed = MyPlumeFeed(payable(address(proxy)));
        feed.initialize(MY_PLUME_TOKEN, MINTER_PROXY, ST_PLUME_REWARDS, PLUME_STAKING);
    }

    function test_getMyPlumePrice() public {
        assertApproxEqRel(feed.getMyPlumePrice(), 1e18, 5e16);
    }

    function test_myPlumeStats() public {
        feed.getTotalDeposits();
        feed.getPlumeStakedAmount();
        feed.getMyPlumeRewards();
        feed.getMyPlumeTvl();
        feed.getMyPlumePrice();
        feed.getMinterStats();
        feed.getRedemptionFees();
        feed.getCurrentWithheldETH();
        feed.getTotalInstantUnstaked();
        feed.getLiquidityRatio();
        feed.getEffectiveYield();
        feed.totalRewards();
    }
} 