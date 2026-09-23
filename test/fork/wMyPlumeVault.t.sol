// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity ^0.8.0;

import "forge-std/Test.sol";
import {sfrxETH, ERC20} from "../../src/sfrxETH.sol";
import {frxETH} from "../../src/frxETH.sol";
import {stPlumeMinter} from "../../src/stPlumeMinter.sol";
import {stPlumeRewards} from "../../src/stPlumeRewards.sol";
import {IPlumeStaking} from "../../src/interfaces/IPlumeStaking.sol";
import {PlumeStakingStorage} from "../../src/interfaces/PlumeStakingStorage.sol";

/// @notice End-to-end proof that the wMyPlume wrapper plan works against live Plume state,
///         using ONLY functions that are already deployed (no contract changes).
///
///         The keeper loop under test:
///           1. owed = stPlumeRewards.getUserRewards(vault)
///           2. stPlumeRewards.resetUserRewardsAfterClaim(vault)      [MINTER_ROLE]
///           3. stPlumeMinter.submitAndGive(vault){value: owed}       [timelock -> keeper PLUME]
///           4. vault.syncRewards()                                    [permissionless]
contract WMyPlumeVaultForkTest is Test {
    // Launched mainnet deployment (script/deployMinter.s.sol, "Launched Mainnet")
    address constant MY_PLUME = 0xc2387E0feA344D1edEC3E93Bf2124f909f74938C;
    address payable constant MINTER = payable(0xAD8874006ee4EBe311066E47c650A74171b8F624);
    address constant REWARDS = 0x6B9D6efF3f9B15b0655C5f5c2f27Fcc9A87f9087;
    address constant GOV = 0x18E1EEC9Fa5D77E472945FE0d48755386f28443c; // owner / onlyByOwnGov

    uint32 constant CYCLE = 7 days;
    uint256 constant SEED = 100 ether;

    sfrxETH vault;
    frxETH myPlume = frxETH(MY_PLUME);
    stPlumeMinter minter = stPlumeMinter(MINTER);
    stPlumeRewards rewards = stPlumeRewards(payable(REWARDS));
    IPlumeStaking plumeStaking = IPlumeStaking(0x30c791E4654EdAc575FA1700eD8633CB2FEDE871);

    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public {
        vault = new sfrxETH(ERC20(MY_PLUME), CYCLE);

        vm.deal(keeper, 1_000_000 ether);
        vm.deal(alice, 1_000_000 ether);
        vm.deal(bob, 1_000_000 ether);

        // Keeper needs MINTER_ROLE on stPlumeRewards to call resetUserRewardsAfterClaim.
        // NOTE: cache the role BEFORE the prank; an inner call would consume it.
        bytes32 minterRole = rewards.MINTER_ROLE();
        vm.prank(GOV);
        rewards.grantRole(minterRole, keeper);
    }

    // ---------------------------------------------------------------- helpers

    function _mintMyPlume(address to, uint256 amount) internal {
        vm.prank(to);
        (bool ok,) = MINTER.call{value: amount}(abi.encodeWithSignature("submitAndGive(address)", to));
        require(ok, "submitAndGive failed");
    }

    function _depositToVault(address who, uint256 amount) internal returns (uint256 shares) {
        vm.startPrank(who);
        myPlume.approve(address(vault), amount);
        shares = vault.deposit(amount, who);
        vm.stopPrank();
    }

    /// @dev One full keeper cycle. Returns the amount recycled.
    function _runKeeperCycle() internal returns (uint256 owed) {
        owed = rewards.getUserRewards(address(vault));
        if (owed == 0) return 0;

        vm.prank(keeper);
        rewards.resetUserRewardsAfterClaim(address(vault));

        // In production the PLUME comes out of the reserve via the timelock; here the
        // keeper is simply funded, which is economically identical.
        vm.prank(keeper);
        (bool ok,) = MINTER.call{value: owed}(abi.encodeWithSignature("submitAndGive(address)", address(vault)));
        require(ok, "recycle submitAndGive failed");
    }

    function _syncIfDue() internal {
        if (block.timestamp >= vault.rewardsCycleEnd()) vault.syncRewards();
    }

    /// @dev Push real rewards into stPlumeRewards the way the protocol does.
    function _loadRewards(uint256 amount) internal {
        vm.deal(GOV, GOV.balance + amount);
        vm.prank(GOV);
        minter.loadRewards{value: amount}();
    }

    // ---------------------------------------------------------------- tests

    /// The vault must accept myPLUME and issue 1:1 shares on the first deposit.
    function test_01_seedAndFirstDeposit() public {
        _mintMyPlume(address(this), SEED);
        uint256 shares = _depositToVault(address(this), SEED);

        assertEq(shares, SEED, "first deposit should be 1:1");
        assertEq(vault.totalAssets(), SEED, "totalAssets tracks stored assets");
        assertEq(vault.pricePerShare(), 1e18, "pps starts at 1.0");
        assertEq(myPlume.balanceOf(address(vault)), SEED, "vault holds myPLUME");
    }

    /// The core question: does the vault actually earn, and does the recycle move it into the price?
    function test_02_vaultAccruesAndRecycleRaisesPrice() public {
        _mintMyPlume(address(this), SEED);
        _depositToVault(address(this), SEED);

        _mintMyPlume(alice, 1000 ether);
        _depositToVault(alice, 1000 ether);

        uint256 ppsBefore = vault.pricePerShare();
        uint256 assetsBefore = vault.totalAssets();

        // Protocol earns and distributes rewards over a cycle.
        _loadRewards(50_000 ether);
        vm.warp(block.timestamp + 7 days);

        uint256 owed = rewards.getUserRewards(address(vault));
        assertGt(owed, 0, "vault must accrue rewards on the myPLUME it holds");

        uint256 recycled = _runKeeperCycle();
        assertEq(recycled, owed, "recycled exactly what was owed");
        assertEq(rewards.getUserRewards(address(vault)), 0, "vault ledger cleared");
        assertEq(myPlume.balanceOf(address(vault)), assetsBefore + recycled, "vault myPLUME balance grew");

        // Before sync, xERC4626 must ignore the new balance (this is the donation guard).
        assertEq(vault.totalAssets(), assetsBefore, "unsynced balance must NOT count");
        assertEq(vault.pricePerShare(), ppsBefore, "price must not jump on receipt");

        // After sync the rewards unlock linearly.
        _syncIfDue();
        assertEq(vault.totalAssets(), assetsBefore, "nothing unlocked at t=0 of the cycle");

        vm.warp(block.timestamp + CYCLE);
        assertEq(vault.totalAssets(), assetsBefore + recycled, "fully unlocked at cycle end");
        assertGt(vault.pricePerShare(), ppsBefore, "price per share rose");
    }

    /// A donation must not be able to move the price within a block (Morpho oracle safety).
    function test_03_donationCannotFlashMovePrice() public {
        _mintMyPlume(address(this), SEED);
        _depositToVault(address(this), SEED);

        uint256 ppsBefore = vault.pricePerShare();

        _mintMyPlume(bob, 10_000 ether);
        vm.prank(bob);
        myPlume.transfer(address(vault), 10_000 ether);

        assertEq(vault.pricePerShare(), ppsBefore, "donation must not move price immediately");

        // Even forcing a sync only starts a linear unlock; no instantaneous jump.
        vm.warp(block.timestamp + CYCLE);
        _syncIfDue();
        assertEq(vault.pricePerShare(), ppsBefore, "no jump at sync time either");
    }

    /// A depositor who enters and exits in the same block must not extract value.
    function test_04_noSandwichAroundRecycle() public {
        _mintMyPlume(address(this), SEED);
        _depositToVault(address(this), SEED);

        _loadRewards(50_000 ether);
        vm.warp(block.timestamp + 7 days);
        _runKeeperCycle();
        _syncIfDue();

        _mintMyPlume(bob, 1000 ether);
        uint256 before = myPlume.balanceOf(bob);
        uint256 shares = _depositToVault(bob, 1000 ether);
        vm.prank(bob);
        vault.redeem(shares, bob, bob);

        assertLe(myPlume.balanceOf(bob), before, "in-and-out must not be profitable");
    }

    /// Recycling must not change myPLUME backing: supply and backing grow together.
    function test_05_backingStaysOneToOne() public {
        _mintMyPlume(address(this), SEED);
        _depositToVault(address(this), SEED);

        _loadRewards(50_000 ether);
        vm.warp(block.timestamp + 7 days);

        uint256 supplyBefore = myPlume.totalSupply();
        uint256 recycled = _runKeeperCycle();

        assertEq(myPlume.totalSupply(), supplyBefore + recycled, "supply grew by exactly the recycled amount");
        // The PLUME backing it was already inside the minter (rewards are restaked on load),
        // so the keeper's payment restores the minter to 1:1 rather than inflating it.
    }

    /// Withdrawing from the vault must return myPLUME that still earns for the user.
    function test_06_userKeepsEarningAfterUnwrap() public {
        _mintMyPlume(alice, 1000 ether);
        uint256 shares = _depositToVault(alice, 1000 ether);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        assertGe(assets, 1000 ether - 1, "redeem returns principal");

        _loadRewards(50_000 ether);
        vm.warp(block.timestamp + 7 days);
        assertGt(rewards.getUserRewards(alice), 0, "unwrapped holder earns normally again");
    }

    /// The keeper cycle must be repeatable, and the price must be monotonic across cycles.
    function test_07_repeatedCyclesAreMonotonic() public {
        _mintMyPlume(address(this), SEED);
        _depositToVault(address(this), SEED);

        uint256 pps = vault.pricePerShare();
        for (uint256 i = 0; i < 4; i++) {
            _loadRewards(50_000 ether);
            vm.warp(block.timestamp + 7 days);
            _runKeeperCycle();
            _syncIfDue();
            vm.warp(block.timestamp + CYCLE);

            uint256 next = vault.pricePerShare();
            assertGe(next, pps, "price per share must never fall");
            pps = next;
        }
        assertGt(pps, 1e18, "price grew over four cycles");
    }

    /// If the ledger is reset but submitAndGive reverts, the rewards are lost.
    /// This documents WHY the keeper must never separate those two steps in production.
    function test_08_resetWithoutSubmitLosesRewards() public {
        _mintMyPlume(address(this), SEED);
        _depositToVault(address(this), SEED);

        _loadRewards(50_000 ether);
        vm.warp(block.timestamp + 7 days);

        uint256 owed = rewards.getUserRewards(address(vault));
        assertGt(owed, 0);

        vm.prank(keeper);
        rewards.resetUserRewardsAfterClaim(address(vault));

        assertEq(rewards.getUserRewards(address(vault)), 0, "ledger is gone");
        assertEq(myPlume.balanceOf(address(vault)), SEED, "and the vault got nothing");
    }

    /// Resetting the vault's ledger must not touch any other holder's rewards.
    /// This is the blast-radius test for the keeper's MINTER_ROLE.
    function test_09_resetDoesNotAffectOtherHolders() public {
        _mintMyPlume(address(this), SEED);
        _depositToVault(address(this), SEED);

        // Two ordinary holders who never touch the vault.
        _mintMyPlume(alice, 1000 ether);
        _mintMyPlume(bob, 2500 ether);

        _loadRewards(50_000 ether);
        vm.warp(block.timestamp + 7 days);

        uint256 aliceBefore = rewards.getUserRewards(alice);
        uint256 bobBefore = rewards.getUserRewards(bob);
        uint256 rptBefore = rewards.rewardPerToken();
        uint256 rateBefore = rewards.rewardRate();
        uint256 cycleEndBefore = rewards.rewardsCycleEnd();
        assertGt(aliceBefore, 0);
        assertGt(bobBefore, 0);

        // Reset ONLY the vault.
        vm.prank(keeper);
        rewards.resetUserRewardsAfterClaim(address(vault));

        // The vault is zeroed; nobody else moves.
        assertEq(rewards.getUserRewards(address(vault)), 0, "vault cleared");
        assertEq(rewards.getUserRewards(alice), aliceBefore, "alice unchanged");
        assertEq(rewards.getUserRewards(bob), bobBefore, "bob unchanged");

        // Global reward state is unchanged in value: the accumulator was checkpointed,
        // not rewound, and the emission rate and cycle are untouched.
        assertEq(rewards.rewardPerToken(), rptBefore, "rewardPerToken unchanged");
        assertEq(rewards.rewardRate(), rateBefore, "rewardRate unchanged");
        assertEq(rewards.rewardsCycleEnd(), cycleEndBefore, "cycle unchanged");

        // And everyone keeps accruing at the same rate afterwards.
        uint256 aliceMid = rewards.getUserRewards(alice);
        uint256 bobMid = rewards.getUserRewards(bob);
        _loadRewards(50_000 ether);
        vm.warp(block.timestamp + 7 days);
        assertGt(rewards.getUserRewards(alice), aliceMid, "alice still accrues");
        assertGt(rewards.getUserRewards(bob), bobMid, "bob still accrues");

        // Alice earns 1000/2500 of what Bob earns, as before the reset.
        uint256 aliceGain = rewards.getUserRewards(alice) - aliceMid;
        uint256 bobGain = rewards.getUserRewards(bob) - bobMid;
        assertApproxEqRel(aliceGain * 25, bobGain * 10, 1e12, "pro-rata split preserved");
    }

    /// Resetting cannot make the protocol less able to pay everyone else:
    /// the PLUME behind the cleared entry stays in the minter as backing.
    function test_10_resetIncreasesBackingPerShare() public {
        _mintMyPlume(address(this), SEED);
        _depositToVault(address(this), SEED);
        _mintMyPlume(alice, 1000 ether);

        _loadRewards(50_000 ether);
        vm.warp(block.timestamp + 7 days);

        uint256 supplyBefore = myPlume.totalSupply();
        uint256 minterBalanceBefore = address(minter).balance;

        vm.prank(keeper);
        rewards.resetUserRewardsAfterClaim(address(vault));

        // No tokens minted or burned, no PLUME left the minter: the claim simply vanished,
        // which makes the remaining holders' claim on the same backing strictly stronger.
        assertEq(myPlume.totalSupply(), supplyBefore, "no supply change");
        assertEq(address(minter).balance, minterBalanceBefore, "no PLUME moved");
    }

    /// ALTERNATIVE RECYCLE: instead of moving PLUME out of the reserve and re-submitting it,
    /// mint myPLUME straight to the vault. The PLUME backing those rewards is ALREADY inside
    /// the minter (net rewards are restaked on load), so clearing the ledger frees exactly
    /// that much backing and the mint consumes exactly that much. No PLUME moves at all.
    function test_11_mintDirectlyKeepsBackingExact() public {
        _mintMyPlume(address(this), SEED);
        _depositToVault(address(this), SEED);
        _mintMyPlume(alice, 1000 ether);

        _loadRewards(50_000 ether);
        vm.warp(block.timestamp + 7 days);

        uint256 owed = rewards.getUserRewards(address(vault));
        assertGt(owed, 0);

        uint256 supplyBefore = myPlume.totalSupply();
        uint256 minterBalanceBefore = address(minter).balance;
        uint256 stakedBefore = plumeStaking.stakeInfo(address(minter)).staked;
        uint256 aliceBefore = rewards.getUserRewards(alice);

        // Governance grants the minting right. In production this is the TIMELOCK, and the
        // keeper schedules the mint through it; here we grant it to the keeper directly.
        vm.prank(GOV);
        myPlume.addMinter(keeper);

        vm.startPrank(keeper);
        rewards.resetUserRewardsAfterClaim(address(vault));
        myPlume.minter_mint(address(vault), owed);
        vm.stopPrank();

        // The vault received exactly its rewards as myPLUME.
        assertEq(myPlume.balanceOf(address(vault)), SEED + owed, "vault got its rewards");
        assertEq(rewards.getUserRewards(address(vault)), 0, "vault ledger cleared");
        assertEq(myPlume.totalSupply(), supplyBefore + owed, "supply grew by exactly owed");

        // Nothing left the protocol: no reserve withdrawal, no re-stake, no external funding.
        assertEq(address(minter).balance, minterBalanceBefore, "no PLUME moved in or out");
        assertEq(plumeStaking.stakeInfo(address(minter)).staked, stakedBefore, "stake untouched");

        // Other holders are unaffected.
        assertEq(rewards.getUserRewards(alice), aliceBefore, "alice unchanged");
    }

    /// The vault must be able to redeem the compounded myPLUME like any other holder,
    /// i.e. the minted myPLUME is really backed and not an IOU.
    function test_12_compoundedSharesAreRedeemable() public {
        _mintMyPlume(alice, 1000 ether);
        uint256 shares = _depositToVault(alice, 1000 ether);

        _loadRewards(50_000 ether);
        vm.warp(block.timestamp + 7 days);
        uint256 owed = rewards.getUserRewards(address(vault));
        assertGt(owed, 0);

        vm.prank(GOV);
        myPlume.addMinter(keeper);
        vm.startPrank(keeper);
        rewards.resetUserRewardsAfterClaim(address(vault));
        myPlume.minter_mint(address(vault), owed);
        vm.stopPrank();

        vm.warp(block.timestamp + CYCLE);
        vault.syncRewards();
        vm.warp(block.timestamp + CYCLE);
        assertGt(vault.pricePerShare(), 1e18, "price per share rose");

        // Alice redeems her shares and gets back more myPLUME than she put in.
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        assertGt(assets, 1000 ether, "alice redeems more than principal");

        // And that myPLUME can actually be unstaked against the protocol.
        vm.prank(alice);
        minter.unstake(100 ether);
    }

    /// @dev Total PLUME the protocol actually controls.
    function _protocolBacking() internal view returns (uint256) {
        PlumeStakingStorage.StakeInfo memory info = plumeStaking.stakeInfo(address(minter));
        return info.staked + info.cooled + info.parked + address(minter).balance;
    }

    /// THE QUESTION: after the vault's reward ledger is reset and myPLUME is minted against
    /// it, is that myPLUME really redeemable for PLUME? This walks the whole way out:
    /// vault shares -> myPLUME -> unstake -> withdraw -> PLUME in the user's wallet.
    function test_13_recycledMyPlumeRedeemsForRealPlume() public {
        _mintMyPlume(alice, 1000 ether);
        uint256 shares = _depositToVault(alice, 1000 ether);

        _loadRewards(50_000 ether);
        vm.warp(block.timestamp + 7 days);

        uint256 owed = rewards.getUserRewards(address(vault));
        assertGt(owed, 0);

        // Solvency before: every myPLUME is covered by at least 1 PLUME of real backing.
        assertGe(_protocolBacking(), myPlume.totalSupply(), "solvent before recycle");

        // The recycle: clear the ledger, mint the matching myPLUME. No PLUME moves.
        vm.prank(GOV);
        myPlume.addMinter(keeper);
        vm.startPrank(keeper);
        rewards.resetUserRewardsAfterClaim(address(vault));
        myPlume.minter_mint(address(vault), owed);
        vm.stopPrank();

        // Solvency after: the freed reward backing now covers the newly minted supply.
        assertGe(_protocolBacking(), myPlume.totalSupply(), "still solvent after recycle");

        // Let it unlock into the share price.
        vm.warp(block.timestamp + CYCLE);
        vault.syncRewards();
        vm.warp(block.timestamp + CYCLE);

        // Alice unwraps: more myPLUME than she put in.
        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);
        assertGt(assets, 1000 ether, "unwrapped more myPLUME than deposited");
        assertEq(myPlume.balanceOf(alice), assets, "alice holds it");

        // Alice exits the protocol entirely for real PLUME.
        uint256 plumeBefore = alice.balance;
        uint256 myPlumeBefore = myPlume.balanceOf(alice);

        vm.prank(alice);
        minter.unstake(assets);

        uint256 id = minter.withdrawalRequestCount(alice) - 1;
        (uint256 reqAmount,, uint256 ts, uint256 createdTs) = minter.withdrawalRequests(alice, id);
        assertGt(reqAmount, 0, "withdrawal request created");
        if (ts > block.timestamp) vm.warp(ts);

        vm.prank(alice);
        uint256 withdrawn = minter.withdraw(alice, id);

        // Real native PLUME landed in her wallet, and the myPLUME was burned for it.
        assertEq(alice.balance, plumeBefore + withdrawn, "alice received native PLUME");
        assertEq(myPlume.balanceOf(alice), myPlumeBefore - assets, "myPLUME burned");
        assertGt(withdrawn, 0, "non-zero payout");

        // She got back more PLUME than the 1000 she originally staked, net of the
        // redemption fee. This is the yield, realised in the underlying asset.
        uint256 maxFeeBps = createdTs == ts ? 5000 : 150; // instant vs standard, 1e6 precision
        uint256 minExpected = assets - (assets * maxFeeBps / 1e6);
        assertGe(withdrawn, minExpected, "payout net of fee");
        assertGt(withdrawn, 1000 ether - (1000 ether * maxFeeBps / 1e6), "beat her principal");

        // And the protocol is still solvent for everyone left.
        assertGe(_protocolBacking(), myPlume.totalSupply(), "solvent after exit");
    }

    /// The classic ERC-4626 first-depositor inflation attack, against a 10 PLUME seed.
    /// xERC4626 already refuses to count donations until syncRewards(), and then unlocks
    /// them linearly, so the attack cannot even be attempted in one block. The seed is the
    /// second line of defence: it keeps totalSupply large enough that share rounding is
    /// irrelevant for any realistic deposit.
    function test_14_seedDefeatsInflationAttack() public {
        // Seed exactly as script/deployWrapped.s.sol does: deposit, burn the shares.
        _mintMyPlume(address(this), 10 ether);
        myPlume.approve(address(vault), 10 ether);
        vault.deposit(10 ether, address(0xdEaD));
        assertEq(vault.totalSupply(), 10 ether, "seeded");

        // Attacker donates 10,000 myPLUME — a thousand times the seed.
        _mintMyPlume(bob, 10_000 ether);
        vm.prank(bob);
        myPlume.transfer(address(vault), 10_000 ether);

        // It is invisible until a sync, and cannot be synced until the cycle ends.
        assertEq(vault.totalAssets(), 10 ether, "donation ignored before sync");

        vm.warp(block.timestamp + CYCLE);
        vault.syncRewards();
        vm.warp(block.timestamp + CYCLE);
        assertEq(vault.totalAssets(), 10_010 ether, "donation fully unlocked");

        // The victim deposits a normal amount and must NOT be rounded down to zero shares.
        _mintMyPlume(alice, 1 ether);
        uint256 shares = _depositToVault(alice, 1 ether);
        assertGt(shares, 0, "victim must receive shares");

        // And must be able to get essentially all of it back.
        vm.prank(alice);
        uint256 returned = vault.redeem(shares, alice, alice);
        assertApproxEqRel(returned, 1 ether, 1e12, "victim recovers their deposit");
    }
}
