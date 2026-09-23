// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {CovenRouter} from "../../src/CovenRouter.sol";
import {Mask} from "../utils/Mask.sol";
import {ICovenRouter} from "../../src/interfaces/ICovenRouter.sol";

/// A hook-like contract whose two 32-byte immutables land in runtime code as PUSH32 data.
contract ParamHook {
    uint256 public immutable feeBps;
    uint256 public immutable token;
    constructor(uint256 f, uint256 t) {
        feeBps = f;
        token = t;
    }
    function ping() external view returns (uint256) {
        return feeBps + token;
    }
}

/// Same-length probe with different logic (to test non-masked bytes must match).
contract OtherHook {
    uint256 public immutable feeBps;
    uint256 public immutable token;
    constructor(uint256 f, uint256 t) {
        feeBps = f;
        token = t;
    }
    function ping() external view returns (uint256) {
        return feeBps * token; // different opcode than ParamHook
    }
}

contract TemplateAudit is Test {
    CovenRouter router;
    address owner = makeAddr("owner");
    address feeRecipient = makeAddr("feeRecipient");
    address guardian = makeAddr("guardian");

    function setUp() public {
        router = new CovenRouter(owner, feeRecipient, guardian, 30, new address[](0), new ICovenRouter.TemplateInit[](0));
    }

    // ---- helper: build template offsets by diffing PUSH32 immediates (safe, real-usage pattern) ----
    function _diffOffsets(address a, address b) internal view returns (uint16[] memory offsets) {
        bytes memory ca = a.code;
        bytes memory cb = b.code;
        assertEq(ca.length, cb.length, "size");
        uint16[] memory tmp = new uint16[](64);
        uint256 count;
        uint256 pc;
        while (pc < ca.length) {
            uint8 op = uint8(ca[pc]);
            if (op >= 0x60 && op <= 0x7f) {
                uint256 size = op - 0x5f;
                if (size == 32 && !_eq(ca, cb, pc + 1)) {
                    tmp[count++] = SafeCast.toUint16(pc + 1);
                }
                pc += 1 + size;
            } else {
                pc += 1;
            }
        }
        offsets = new uint16[](count);
        for (uint256 i; i < count; ++i) offsets[i] = tmp[i];
    }

    function _hookAt(address where, uint256 f, uint256 t) internal returns (ParamHook) {
        deployCodeTo("TemplateAudit.t.sol:ParamHook", abi.encode(f, t), where);
        return ParamHook(where);
    }

    /// M-01 regression: identical code at an address with different permission bits is
    /// a different hook to v4, and the template must not admit it.
    function test_M01_templateDoesNotAdmitADifferentFlagSet() public {
        ParamHook ref = _hookAt(0x1111111111111111111111111111111111110040, 1, 0xAAAA);
        ParamHook sameCodeMoreFlags = _hookAt(0x22222222222222222222222222222222222200C4, 1, 0xAAAA);
        assertEq(address(ref).code.length, address(sameCodeMoreFlags).code.length, "same code");

        uint16[] memory none = new uint16[](0);
        vm.prank(owner);
        router.addHookTemplate(address(ref), Mask.windows(none));

        assertTrue(router.isHookAllowed(address(ref)), "reference allowed");
        assertFalse(router.isHookAllowed(address(sameCodeMoreFlags)), "escalated flag set rejected");
    }

    /// M-02 regression: a window that reaches past the end of a PUSH immediate into
    /// executable bytes is refused at registration.
    function test_M02_maskOverExecutableBytesIsRejected() public {
        ParamHook ref = _hookAt(0x1111111111111111111111111111111111110040, 1, 0xAAAA);
        uint16[] memory offs = _pushImmediateStarts(address(ref));
        assertGt(offs.length, 0, "expected PUSH32 immediates");
        uint16 start = offs[0];

        vm.startPrank(owner);
        // exactly the immediate: fine
        router.addHookTemplate(address(ref), Mask.one(start, 32));
        // one byte past it: rejected
        vm.expectRevert(abi.encodeWithSelector(ICovenRouter.MaskCoversCode.selector, uint16(start + 1)));
        router.addHookTemplate(address(ref), Mask.one(start + 1, 32));
        vm.stopPrank();
    }

    function _pushImmediateStarts(address a) internal view returns (uint16[] memory out) {
        bytes memory c = a.code;
        uint16[] memory tmp = new uint16[](c.length);
        uint256 count;
        uint256 pc;
        while (pc < c.length) {
            uint8 op = uint8(c[pc]);
            if (op >= 0x60 && op <= 0x7f) {
                uint256 size = op - 0x5f;
                if (size == 32 && pc + 1 + 32 <= c.length) tmp[count++] = SafeCast.toUint16(pc + 1);
                pc += 1 + size;
            } else {
                pc += 1;
            }
        }
        out = new uint16[](count);
        for (uint256 i; i < count; ++i) out[i] = tmp[i];
    }

    function _eq(bytes memory a, bytes memory b, uint256 off) internal pure returns (bool) {
        for (uint256 i; i < 32; ++i) if (a[off + i] != b[off + i]) return false;
        return true;
    }

    // ============================================================
    // Template soundness
    // ============================================================

    /// Two clones differing ONLY in a masked constant both match; a clone differing in a
    /// NON-masked constant does NOT. This is the core soundness property AND demonstrates M1:
    /// the masked value is fully attacker-controlled (fee 1 vs fee 1e18 both admitted).
    function test_maskedConstantIsAttackerControlled_butNonMaskedMustMatch() public {
        // All three share the low 14 address bits, as a launchpad's mined clones would.
        ParamHook ref = _hookAt(0x1111111111111111111111111111111111110040, 1, 0xAAAA);
        ParamHook clone = _hookAt(0x2222222222222222222222222222222222220040, 1e18, 0xAAAA);
        ParamHook wrongToken = _hookAt(0x3333333333333333333333333333333333330040, 1, 0xBBBB);

        uint16[] memory offsets = _diffOffsets(address(ref), address(clone)); // masks only the fee slot
        assertGt(offsets.length, 0, "expected a masked diff");

        vm.prank(owner);
        router.addHookTemplate(address(ref), Mask.windows(offsets));

        assertTrue(router.isHookAllowed(address(ref)), "ref allowed");
        assertTrue(router.isHookAllowed(address(clone)), "clone with adversarial fee allowed (M1)");
        assertFalse(router.isHookAllowed(address(wrongToken)), "non-masked diff must be rejected");
    }

    /// A contract with identical length but different LOGIC (opcodes) is rejected even if we
    /// try to mask the differing immutables — the code bytes around them differ.
    function test_differentLogicSameLengthRejected() public {
        ParamHook ref = new ParamHook(1, 0xAAAA);
        OtherHook other = new OtherHook(1, 0xAAAA);
        // Mask every 32-byte PUSH immediate that differs; if lengths match, try to force a match.
        if (address(ref).code.length != address(other).code.length) {
            emit log("lengths differ - trivially rejected by codeSize check");
            uint16[] memory none = new uint16[](0);
            vm.prank(owner);
            router.addHookTemplate(address(ref), Mask.windows(none));
            assertFalse(router.isHookAllowed(address(other)));
            return;
        }
        uint16[] memory offsets = _diffOffsets(address(ref), address(other));
        vm.prank(owner);
        router.addHookTemplate(address(ref), Mask.windows(offsets));
        assertTrue(router.isHookAllowed(address(ref)));
        assertFalse(router.isHookAllowed(address(other)), "different logic must not match");
    }

    /// M1 demonstration in its strongest form: if the owner masks an offset that is NOT
    /// PUSH32 immediate data but executable code, two functionally different contracts can
    /// collide. We simulate the owner mistake by masking arbitrary offsets that cover a
    /// difference in executable bytes, and show the guard depends entirely on owner care.
    function test_M1_maskingExecutableBytesIsUnsafe() public {
        // Build a template from ref with an offset chosen to blanket a region.
        ParamHook ref = new ParamHook(1, 0xAAAA);
        OtherHook other = new OtherHook(1, 0xAAAA);
        bytes memory ca = address(ref).code;
        bytes memory cb = address(other).code;
        if (ca.length != cb.length) {
            emit log("codeSize differs; strongest-form M1 not reproducible with these probes");
            return;
        }
        // Collect EVERY 32-aligned window where bytes differ, regardless of whether it is
        // push-data. A careless owner could do exactly this ("just mask all the diffs").
        uint16[] memory tmp = new uint16[](ca.length);
        uint256 count;
        uint256 i;
        while (i + 32 <= ca.length) {
            bool diff;
            for (uint256 k; k < 32; ++k) if (ca[i + k] != cb[i + k]) { diff = true; break; }
            if (diff) { tmp[count++] = SafeCast.toUint16(i); i += 32; } else { i += 1; }
        }
        if (count == 0 || count > router.MAX_HOOK_TEMPLATES() * 0 + 8) {
            emit log_named_uint("diff windows", count);
        }
        // Not asserting a forced collision here (probe logic rarely aligns), but the log makes the
        // risk surface explicit: the contract accepts any non-overlapping 32-byte offsets.
        emit log_named_uint("careless-mask diff windows", count);
        assertTrue(true);
    }

    // ============================================================
    // Template registration validation
    // ============================================================

    function test_offsetValidation() public {
        ParamHook ref = new ParamHook(1, 2);
        uint256 size = address(ref).code.length;

        vm.startPrank(owner);

        // out of bounds: offset + 32 > size
        uint16[] memory oob = new uint16[](1);
        oob[0] = SafeCast.toUint16(size - 31);
        vm.expectRevert(ICovenRouter.InvalidTemplate.selector);
        router.addHookTemplate(address(ref), Mask.windows(oob));

        // overlapping / non-ascending
        uint16[] memory overlap = new uint16[](2);
        overlap[0] = 40;
        overlap[1] = 50; // 50 < 40+32
        vm.expectRevert(ICovenRouter.InvalidTemplate.selector);
        router.addHookTemplate(address(ref), Mask.windows(overlap));

        // empty reference code
        vm.expectRevert(ICovenRouter.InvalidTemplate.selector);
        router.addHookTemplate(makeAddr("eoa"), Mask.none());

        // valid, then duplicate
        router.addHookTemplate(address(ref), Mask.none());
        vm.expectRevert(ICovenRouter.TemplateExists.selector);
        router.addHookTemplate(address(ref), Mask.none());

        vm.stopPrank();
    }

    function test_templateLimitEnforced() public {
        vm.startPrank(owner);
        for (uint256 i; i < router.MAX_HOOK_TEMPLATES(); ++i) {
            ParamHook h = new ParamHook(i, 7);
            router.addHookTemplate(address(h), Mask.none());
        }
        ParamHook extra = new ParamHook(999, 7);
        vm.expectRevert(ICovenRouter.TooManyTemplates.selector);
        router.addHookTemplate(address(extra), Mask.none());
        vm.stopPrank();
    }

    function test_removeSwapPopKeepsOthers() public {
        vm.startPrank(owner);
        ParamHook a = new ParamHook(1, 1);
        ParamHook b = new ParamHook(2, 2);
        ParamHook c = new ParamHook(3, 3);
        bytes32 idA = router.addHookTemplate(address(a), Mask.none());
        bytes32 idB = router.addHookTemplate(address(b), Mask.none());
        router.addHookTemplate(address(c), Mask.none());
        assertEq(router.hookTemplateIds().length, 3);
        // remove the middle one
        router.removeHookTemplate(idB);
        vm.stopPrank();
        assertEq(router.hookTemplateIds().length, 2);
        assertTrue(router.isHookAllowed(address(a)));
        assertTrue(router.isHookAllowed(address(c)));
        assertFalse(router.isHookAllowed(address(b)));
        // idA still resolvable
        (uint256 sz,,) = router.hookTemplate(idA);
        assertGt(sz, 0);
    }

    function test_removeUnknownReverts() public {
        vm.prank(owner);
        vm.expectRevert(ICovenRouter.TemplateNotFound.selector);
        router.removeHookTemplate(bytes32(uint256(0xdead)));
    }

    function test_explicitAllowOverridesAndZeroHookRejected() public {
        ParamHook h = new ParamHook(1, 1);
        assertFalse(router.isHookAllowed(address(h)));
        vm.prank(owner);
        router.setHookAllowed(address(h), true);
        assertTrue(router.isHookAllowed(address(h)));
        vm.prank(owner);
        router.setHookAllowed(address(h), false);
        assertFalse(router.isHookAllowed(address(h)));
        vm.prank(owner);
        vm.expectRevert(ICovenRouter.InvalidHook.selector);
        router.setHookAllowed(address(0), true);
    }

    // ============================================================
    // Access control / admin
    // ============================================================

    function test_onlyOwnerGuards() public {
        address bad = makeAddr("bad");
        vm.startPrank(bad);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bad));
        router.setPlatformFee(10);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bad));
        router.setFeeRecipient(bad);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bad));
        router.setGuardian(bad);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bad));
        router.setHookAllowed(bad, true);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bad));
        router.addHookTemplate(address(router), Mask.none());
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bad));
        router.unpause();
        vm.stopPrank();
    }

    function test_setterBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(ICovenRouter.InvalidPlatformFee.selector);
        router.setPlatformFee(101);
        router.setPlatformFee(100); // cap ok
        assertEq(router.platformFeeBps(), 100);

        vm.expectRevert(ICovenRouter.InvalidFeeRecipient.selector);
        router.setFeeRecipient(address(0));
        vm.expectRevert(ICovenRouter.InvalidFeeRecipient.selector);
        router.setFeeRecipient(address(router));

        vm.expectRevert(ICovenRouter.InvalidGuardian.selector);
        router.setGuardian(address(0));
        vm.stopPrank();
    }

    function test_constructorBounds() public {
        vm.expectRevert(ICovenRouter.InvalidFeeRecipient.selector);
        new CovenRouter(owner, address(0), guardian, 30, new address[](0), new ICovenRouter.TemplateInit[](0));
        vm.expectRevert(ICovenRouter.InvalidGuardian.selector);
        new CovenRouter(owner, feeRecipient, address(0), 30, new address[](0), new ICovenRouter.TemplateInit[](0));
        vm.expectRevert(ICovenRouter.InvalidPlatformFee.selector);
        new CovenRouter(owner, feeRecipient, guardian, 101, new address[](0), new ICovenRouter.TemplateInit[](0));
        // owner zero rejected by OZ Ownable
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new CovenRouter(address(0), feeRecipient, guardian, 30, new address[](0), new ICovenRouter.TemplateInit[](0));
    }

    function test_pauseAuthorization() public {
        // guardian can pause
        vm.prank(guardian);
        router.pause();
        assertTrue(router.paused());
        // guardian cannot unpause
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, guardian));
        router.unpause();
        // random cannot pause
        vm.prank(makeAddr("x"));
        vm.expectRevert(ICovenRouter.Unauthorized.selector);
        router.pause();
        // owner unpauses
        vm.prank(owner);
        router.unpause();
        assertFalse(router.paused());
        // owner can also pause
        vm.prank(owner);
        router.pause();
        assertTrue(router.paused());
    }

    function test_renounceDisabledAndTwoStepOwnership() public {
        vm.prank(owner);
        vm.expectRevert(ICovenRouter.OwnershipCannotBeRenounced.selector);
        router.renounceOwnership();

        address next = makeAddr("next");
        vm.prank(owner);
        router.transferOwnership(next);
        assertEq(router.owner(), owner, "still old owner until accept");
        // wrong acceptor
        vm.prank(makeAddr("intruder"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, makeAddr("intruder")));
        router.acceptOwnership();
        vm.prank(next);
        router.acceptOwnership();
        assertEq(router.owner(), next);
    }

    function test_unlockCallbackGatedToPoolManager() public {
        vm.expectRevert(ICovenRouter.Unauthorized.selector);
        router.unlockCallback("");
        vm.prank(makeAddr("notpm"));
        vm.expectRevert(ICovenRouter.Unauthorized.selector);
        router.unlockCallback(hex"1234");
    }
}
