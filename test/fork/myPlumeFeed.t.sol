// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import "../../src/Periphery/MyPlumeFeed.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract MyPlumeFeedForkTest is Test {
    MyPlumeFeed feed;
    address owner = address(0x1234);
    address timelock = address(0x5678);

    function setUp() public {
        ProxyAdmin admin = new ProxyAdmin();
        MyPlumeFeed impl = new MyPlumeFeed();
        TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(address(impl), address(admin), bytes(""));
        MyPlumeFeed minter = MyPlumeFeed(payable(address(proxy)));
        minter.initialize(address(0x5c982097b505A3940823a11E6157e9C86aF08987), address(0xE4274Bc25BA313364DE71F104acF27746c6278Cb), address(0x2E420ac76a43fC94F05168Cb8DCf4996b717dA17), address(0x30c791E4654EdAc575FA1700eD8633CB2FEDE871));
        feed = MyPlumeFeed(payable(address(proxy)));
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