// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;
import {Test} from "forge-std/Test.sol";
import {CovenSession} from "../src/CovenSession.sol";
import {CovenSessionFactory} from "../src/CovenSessionFactory.sol";

contract Stub {
    uint256 public x;
}

contract CovenSessionFactoryTest is Test {
    address internal constant USDC = 0x3600000000000000000000000000000000000000;
    CovenSessionFactory internal factory;
    address internal routerStub;
    address internal lensStub;
    address internal owner = makeAddr("owner");
    address internal key = makeAddr("key");

    function setUp() public {
        routerStub = address(new Stub());
        lensStub = address(new Stub());
        factory = new CovenSessionFactory(routerStub, lensStub);
    }

    function _cfg() internal view returns (CovenSession.InitConfig memory cfg) {
        CovenSession.TokenCap[] memory caps = new CovenSession.TokenCap[](1);
        caps[0] = CovenSession.TokenCap({token: USDC, perTradeCap: 1_000e6, dailyCap: 5_000e6});
        cfg = CovenSession.InitConfig({
            router: address(0),
            lens: address(0),
            sessionKey: key,
            changeDelay: 1 hours,
            expiry: uint40(block.timestamp + 30 days),
            tradeCountCap: 10,
            maxImpactBps: 500,
            maxSlippageBps: 100,
            tokens: caps
        });
    }

    function test_constructorRejectsCodelessRouterOrLens() public {
        vm.expectRevert(CovenSessionFactory.InvalidRouterLens.selector);
        new CovenSessionFactory(makeAddr("noCode"), lensStub);
        vm.expectRevert(CovenSessionFactory.InvalidRouterLens.selector);
        new CovenSessionFactory(routerStub, makeAddr("noCode"));
    }

    function test_createRecordsSessionAndForcesCanonicalRouterLens() public {
        address predicted = factory.predict(owner, _cfg(), bytes32(uint256(1)));
        vm.prank(owner);
        address session = factory.create(_cfg(), bytes32(uint256(1)));
        assertEq(session, predicted, "predict matches create");
        assertTrue(factory.isSession(session), "recorded");
        assertEq(address(CovenSession(session).ROUTER()), factory.ROUTER(), "canonical router");
        assertEq(address(CovenSession(session).LENS()), factory.LENS(), "canonical lens");
        assertEq(CovenSession(session).owner(), owner, "owner");
        assertEq(CovenSession(session).sessionKey(), key, "session key");
    }

    function test_lookalikeSessionIsNotRecorded() public {
        CovenSession.InitConfig memory cfg = _cfg();
        cfg.router = address(0xdead);
        cfg.lens = address(0xbeef);
        CovenSession rogue = new CovenSession(owner, cfg);
        assertFalse(factory.isSession(address(rogue)), "a directly-deployed session is not trusted by the factory");
    }

    function test_saltIsKeyedOnCaller() public {
        vm.prank(owner);
        address a = factory.create(_cfg(), bytes32(uint256(1)));
        vm.prank(makeAddr("other"));
        address b = factory.create(_cfg(), bytes32(uint256(1)));
        assertTrue(a != b, "same salt, different caller, different address");
    }

    /// M-04 regression: a session can only ever be created for the caller, so an attacker
    /// cannot plant an attested session in someone else's `sessionsOf` list.
    function test_createOnlyEverOwnedByTheCaller() public {
        address attacker = makeAddr("attacker");
        vm.prank(attacker);
        address session = factory.create(_cfg(), keccak256("squat"));
        assertEq(CovenSession(session).owner(), attacker, "owned by the caller, not a victim");
        assertEq(factory.sessionsOf(owner).length, 0, "victim's list stays empty");
        assertEq(factory.sessionsOf(attacker).length, 1, "listed under the attacker instead");
    }
}
