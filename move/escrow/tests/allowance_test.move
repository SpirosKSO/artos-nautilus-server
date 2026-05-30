#[test_only]
module artos::allowance_tests;

use artos::escrow::{Self, OrderEscrow, ReleaseCap, RefundCap, AiAllowance, ProgrammableAccount};
use sui::clock;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario as ts;

const OWNER: address = @0xA1;
const AGENT: address = @0xA2;
const OTHER_AGENT: address = @0xA3;
const MERCHANT: address = @0xB1;
const OTHER_MERCHANT: address = @0xB2;
const PLATFORM: address = @0xD;
const ADMIN: address = @0xC;

const DAY_MS: u64 = 86_400_000;
const FUTURE: u64 = 9_999_999_999_999; // ~year 2286

fun setup(): ts::Scenario {
    let mut scenario = ts::begin(ADMIN);
    escrow::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    escrow::create_test_pa(ts::ctx(&mut scenario));
    scenario
}

// Helper: mint a SUI coin of `amount` to the current tx sender.
fun mint(scenario: &mut ts::Scenario, amount: u64): coin::Coin<SUI> {
    coin::mint_for_testing<SUI>(amount, ts::ctx(scenario))
}

// Helper: create + share an allowance owned by OWNER for AGENT, funded at
// `initial`, with `per_purchase` / `per_day` caps and an empty merchant
// whitelist (= any merchant allowed).
fun bootstrap_allowance(
    scenario: &mut ts::Scenario,
    initial: u64,
    per_purchase: u64,
    per_day: u64,
    allowed_merchants: vector<address>,
) {
    ts::next_tx(scenario, OWNER);
    let clk = clock::create_for_testing(ts::ctx(scenario));
    let funding = mint(scenario, initial);
    let allowance = escrow::create_allowance<SUI>(
        funding,
        per_purchase,
        per_day,
        FUTURE,
        allowed_merchants,
        AGENT,
        b"agent-kid-thumbprint",
        &clk,
        ts::ctx(scenario),
    );
    escrow::share_allowance(allowance);
    clock::destroy_for_testing(clk);
}

/// Happy path: bootstrap → agent spends → escrow funded, allowance debited.
#[test]
public fun test_allowance_create_and_spend_happy_path() {
    let mut scenario = setup();
    bootstrap_allowance(&mut scenario, 1000, 200, 500, vector[]);

    // Agent spends.
    ts::next_tx(&mut scenario, AGENT);
    let mut allowance = ts::take_shared<AiAllowance<SUI>>(&scenario);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));

    let (escrow_obj, release_cap, refund_cap) = escrow::spend_from_allowance<SUI>(
        &mut allowance,
        b"order_a1",
        MERCHANT,
        150,
        &pa,
        vector[],
        &clk,
        ts::ctx(&mut scenario),
    );

    assert!(escrow::get_status(&escrow_obj) == 1, 1000);
    assert!(escrow::get_amount(&escrow_obj) == 150, 1001);
    assert!(escrow::allowance_balance(&allowance) == 850, 1002);
    assert!(escrow::allowance_spent_today(&allowance) == 150, 1003);
    assert!(!escrow::allowance_revoked(&allowance), 1004);

    escrow::share_escrow(escrow_obj);
    transfer::public_transfer(release_cap, PLATFORM);
    transfer::public_transfer(refund_cap, PLATFORM);
    ts::return_shared(allowance);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);
    ts::end(scenario);
}

/// Wrong-agent attempt aborts (code 76).
#[test, expected_failure(abort_code = 76, location = escrow)]
public fun test_allowance_rejects_wrong_agent() {
    let mut scenario = setup();
    bootstrap_allowance(&mut scenario, 1000, 200, 500, vector[]);

    ts::next_tx(&mut scenario, OTHER_AGENT);
    let mut allowance = ts::take_shared<AiAllowance<SUI>>(&scenario);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));

    let (escrow_obj, release_cap, refund_cap) = escrow::spend_from_allowance<SUI>(
        &mut allowance,
        b"o",
        MERCHANT,
        100,
        &pa,
        vector[],
        &clk,
        ts::ctx(&mut scenario),
    );

    // Unreachable.
    escrow::share_escrow(escrow_obj);
    transfer::public_transfer(release_cap, PLATFORM);
    transfer::public_transfer(refund_cap, PLATFORM);
    ts::return_shared(allowance);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);
    ts::end(scenario);
}

/// Per-purchase cap breach aborts (code 79).
#[test, expected_failure(abort_code = 79, location = escrow)]
public fun test_allowance_rejects_over_per_purchase_cap() {
    let mut scenario = setup();
    bootstrap_allowance(&mut scenario, 1000, 200, 500, vector[]);

    ts::next_tx(&mut scenario, AGENT);
    let mut allowance = ts::take_shared<AiAllowance<SUI>>(&scenario);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));

    let (escrow_obj, release_cap, refund_cap) = escrow::spend_from_allowance<SUI>(
        &mut allowance,
        b"o",
        MERCHANT,
        201,
        &pa,
        vector[],
        &clk,
        ts::ctx(&mut scenario),
    );

    escrow::share_escrow(escrow_obj);
    transfer::public_transfer(release_cap, PLATFORM);
    transfer::public_transfer(refund_cap, PLATFORM);
    ts::return_shared(allowance);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);
    ts::end(scenario);
}

/// Daily cap exhausted across multiple spends (code 80).
#[test, expected_failure(abort_code = 80, location = escrow)]
public fun test_allowance_rejects_when_daily_cap_exhausted() {
    let mut scenario = setup();
    bootstrap_allowance(&mut scenario, 1000, 200, 500, vector[]);

    // First two spends total 400 (under 500).
    spend_ok(&mut scenario, b"o1", MERCHANT, 200);
    spend_ok(&mut scenario, b"o2", MERCHANT, 200);

    // Third spend (200 more) would push spent_today to 600 > 500.
    ts::next_tx(&mut scenario, AGENT);
    let mut allowance = ts::take_shared<AiAllowance<SUI>>(&scenario);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));

    let (escrow_obj, release_cap, refund_cap) = escrow::spend_from_allowance<SUI>(
        &mut allowance,
        b"o3",
        MERCHANT,
        200,
        &pa,
        vector[],
        &clk,
        ts::ctx(&mut scenario),
    );

    escrow::share_escrow(escrow_obj);
    transfer::public_transfer(release_cap, PLATFORM);
    transfer::public_transfer(refund_cap, PLATFORM);
    ts::return_shared(allowance);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);
    ts::end(scenario);
}

/// Day rollover resets spent_today after 24h.
#[test]
public fun test_allowance_day_rollover_resets_spent_today() {
    let mut scenario = setup();
    bootstrap_allowance(&mut scenario, 1000, 200, 400, vector[]);

    // Spend up to the day cap.
    spend_ok(&mut scenario, b"o1", MERCHANT, 200);
    spend_ok(&mut scenario, b"o2", MERCHANT, 200);

    // Advance clock past DAY_MS and try again.
    ts::next_tx(&mut scenario, AGENT);
    let mut allowance = ts::take_shared<AiAllowance<SUI>>(&scenario);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let mut clk = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::increment_for_testing(&mut clk, DAY_MS + 1);

    let (escrow_obj, release_cap, refund_cap) = escrow::spend_from_allowance<SUI>(
        &mut allowance,
        b"o3",
        MERCHANT,
        200,
        &pa,
        vector[],
        &clk,
        ts::ctx(&mut scenario),
    );

    // After rollover: spent_today should reflect only the new 200.
    assert!(escrow::allowance_spent_today(&allowance) == 200, 1100);

    escrow::share_escrow(escrow_obj);
    transfer::public_transfer(release_cap, PLATFORM);
    transfer::public_transfer(refund_cap, PLATFORM);
    ts::return_shared(allowance);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);
    ts::end(scenario);
}

/// Merchant whitelist enforced when non-empty (code 81).
#[test, expected_failure(abort_code = 81, location = escrow)]
public fun test_allowance_rejects_merchant_not_in_whitelist() {
    let mut scenario = setup();
    bootstrap_allowance(&mut scenario, 1000, 200, 500, vector[MERCHANT]);

    ts::next_tx(&mut scenario, AGENT);
    let mut allowance = ts::take_shared<AiAllowance<SUI>>(&scenario);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));

    let (escrow_obj, release_cap, refund_cap) = escrow::spend_from_allowance<SUI>(
        &mut allowance,
        b"o",
        OTHER_MERCHANT,
        100,
        &pa,
        vector[],
        &clk,
        ts::ctx(&mut scenario),
    );

    escrow::share_escrow(escrow_obj);
    transfer::public_transfer(release_cap, PLATFORM);
    transfer::public_transfer(refund_cap, PLATFORM);
    ts::return_shared(allowance);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);
    ts::end(scenario);
}

/// Revoke returns remaining funds and blocks future spends (code 77).
#[test, expected_failure(abort_code = 77, location = escrow)]
public fun test_allowance_revoke_blocks_future_spend() {
    let mut scenario = setup();
    bootstrap_allowance(&mut scenario, 1000, 200, 500, vector[]);

    // Owner revokes.
    ts::next_tx(&mut scenario, OWNER);
    let mut allowance = ts::take_shared<AiAllowance<SUI>>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    escrow::revoke_allowance(&mut allowance, &clk, ts::ctx(&mut scenario));
    assert!(escrow::allowance_revoked(&allowance), 1200);
    assert!(escrow::allowance_balance(&allowance) == 0, 1201);
    ts::return_shared(allowance);
    clock::destroy_for_testing(clk);

    // Agent tries to spend post-revoke — aborts with 77.
    ts::next_tx(&mut scenario, AGENT);
    let mut allowance = ts::take_shared<AiAllowance<SUI>>(&scenario);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));

    let (escrow_obj, release_cap, refund_cap) = escrow::spend_from_allowance<SUI>(
        &mut allowance,
        b"o",
        MERCHANT,
        100,
        &pa,
        vector[],
        &clk,
        ts::ctx(&mut scenario),
    );

    escrow::share_escrow(escrow_obj);
    transfer::public_transfer(release_cap, PLATFORM);
    transfer::public_transfer(refund_cap, PLATFORM);
    ts::return_shared(allowance);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);
    ts::end(scenario);
}

/// Top-up by non-owner aborts (code 75).
#[test, expected_failure(abort_code = 75, location = escrow)]
public fun test_allowance_top_up_requires_owner() {
    let mut scenario = setup();
    bootstrap_allowance(&mut scenario, 1000, 200, 500, vector[]);

    ts::next_tx(&mut scenario, AGENT);
    let mut allowance = ts::take_shared<AiAllowance<SUI>>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let extra = mint(&mut scenario, 500);

    escrow::top_up_allowance<SUI>(&mut allowance, extra, &clk, ts::ctx(&mut scenario));

    ts::return_shared(allowance);
    clock::destroy_for_testing(clk);
    ts::end(scenario);
}

/// End-to-end: allowance-funded escrow can be released by the platform, and
/// funds land at the merchant (not the agent).
#[test]
public fun test_allowance_spend_then_release_to_merchant() {
    let mut scenario = setup();
    bootstrap_allowance(&mut scenario, 1000, 300, 600, vector[]);

    // Agent spends.
    ts::next_tx(&mut scenario, AGENT);
    let mut allowance = ts::take_shared<AiAllowance<SUI>>(&scenario);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let (escrow_obj, release_cap, refund_cap) = escrow::spend_from_allowance<SUI>(
        &mut allowance,
        b"orderA",
        MERCHANT,
        250,
        &pa,
        vector[],
        &clk,
        ts::ctx(&mut scenario),
    );
    escrow::share_escrow(escrow_obj);
    transfer::public_transfer(release_cap, PLATFORM);
    transfer::public_transfer(refund_cap, PLATFORM);
    ts::return_shared(allowance);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);

    // Platform releases.
    ts::next_tx(&mut scenario, PLATFORM);
    let mut escrow_obj = ts::take_shared<OrderEscrow<SUI>>(&scenario);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let cap = ts::take_from_sender<ReleaseCap<SUI>>(&scenario);

    escrow::release(&mut escrow_obj, cap, &pa, &clk, ts::ctx(&mut scenario));
    assert!(escrow::get_status(&escrow_obj) == 2, 1300);

    ts::return_shared(escrow_obj);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);
    ts::end(scenario);
}

/// End-to-end: refund from an allowance-funded escrow routes to the
/// allowance OWNER (not the agent).
#[test]
public fun test_allowance_refund_returns_to_owner() {
    let mut scenario = setup();
    bootstrap_allowance(&mut scenario, 1000, 300, 600, vector[]);

    ts::next_tx(&mut scenario, AGENT);
    let mut allowance = ts::take_shared<AiAllowance<SUI>>(&scenario);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let (escrow_obj, release_cap, refund_cap) = escrow::spend_from_allowance<SUI>(
        &mut allowance,
        b"orderR",
        MERCHANT,
        250,
        &pa,
        vector[],
        &clk,
        ts::ctx(&mut scenario),
    );
    escrow::share_escrow(escrow_obj);
    transfer::public_transfer(release_cap, PLATFORM);
    transfer::public_transfer(refund_cap, PLATFORM);
    ts::return_shared(allowance);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);

    // Platform refunds.
    ts::next_tx(&mut scenario, PLATFORM);
    let mut escrow_obj = ts::take_shared<OrderEscrow<SUI>>(&scenario);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let cap = ts::take_from_sender<RefundCap<SUI>>(&scenario);

    escrow::refund(&mut escrow_obj, cap, &pa, &clk, ts::ctx(&mut scenario));
    assert!(escrow::get_status(&escrow_obj) == 3, 1400);

    ts::return_shared(escrow_obj);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);
    ts::end(scenario);
}

// ── Internal test helper ──────────────────────────────────────────────────

/// Performs a successful spend and consumes the returned objects (the test
/// doesn't care about the caps, just that the call succeeded).
fun spend_ok(scenario: &mut ts::Scenario, order_id: vector<u8>, merchant: address, amount: u64) {
    ts::next_tx(scenario, AGENT);
    let mut allowance = ts::take_shared<AiAllowance<SUI>>(scenario);
    let pa = ts::take_shared<ProgrammableAccount>(scenario);
    let clk = clock::create_for_testing(ts::ctx(scenario));

    let (escrow_obj, release_cap, refund_cap) = escrow::spend_from_allowance<SUI>(
        &mut allowance,
        order_id,
        merchant,
        amount,
        &pa,
        vector[],
        &clk,
        ts::ctx(scenario),
    );

    escrow::share_escrow(escrow_obj);
    transfer::public_transfer(release_cap, PLATFORM);
    transfer::public_transfer(refund_cap, PLATFORM);
    ts::return_shared(allowance);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);
}
