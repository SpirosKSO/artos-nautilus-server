#[test_only]
module artos::escrow_tests;

use artos::escrow::{Self, OrderEscrow, ReleaseCap, RefundCap, AdminCap, ProgrammableAccount};
use sui::clock;
use sui::coin;
use sui::sui::SUI;
use sui::test_scenario as ts;

const CUSTOMER: address = @0xA;
const MERCHANT: address = @0xB;
const ADMIN: address = @0xC;

fun setup(): ts::Scenario {
    let mut scenario = ts::begin(ADMIN);
    escrow::init_for_testing(ts::ctx(&mut scenario));
    ts::next_tx(&mut scenario, ADMIN);
    escrow::create_test_pa(ts::ctx(&mut scenario));
    scenario
}

#[test]
public fun test_create_and_deposit() {
    let mut scenario = setup();

    ts::next_tx(&mut scenario, CUSTOMER);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let (release_cap, refund_cap) = escrow::create_escrow<SUI>(
        b"order1",
        CUSTOMER,
        MERCHANT,
        100,
        &pa,
        vector[],
        &clk,
        ts::ctx(&mut scenario),
    );
    transfer::public_transfer(release_cap, CUSTOMER);
    transfer::public_transfer(refund_cap, CUSTOMER);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);

    ts::next_tx(&mut scenario, CUSTOMER);
    let mut escrow_obj = ts::take_shared<OrderEscrow<SUI>>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let payment = coin::mint_for_testing<SUI>(100, ts::ctx(&mut scenario));
    escrow::deposit(&mut escrow_obj, payment, &clk, ts::ctx(&mut scenario));
    assert!(escrow::get_status(&escrow_obj) == 1, 100);
    ts::return_shared(escrow_obj);
    clock::destroy_for_testing(clk);

    ts::end(scenario);
}

#[test]
public fun test_release() {
    let mut scenario = setup();

    ts::next_tx(&mut scenario, CUSTOMER);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let (release_cap, refund_cap) = escrow::create_escrow<SUI>(
        b"order2",
        CUSTOMER,
        MERCHANT,
        50,
        &pa,
        vector[],
        &clk,
        ts::ctx(&mut scenario),
    );
    transfer::public_transfer(release_cap, CUSTOMER);
    transfer::public_transfer(refund_cap, CUSTOMER);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);

    ts::next_tx(&mut scenario, CUSTOMER);
    let mut escrow_obj = ts::take_shared<OrderEscrow<SUI>>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    escrow::deposit(
        &mut escrow_obj,
        coin::mint_for_testing<SUI>(50, ts::ctx(&mut scenario)),
        &clk,
        ts::ctx(&mut scenario),
    );
    ts::return_shared(escrow_obj);
    clock::destroy_for_testing(clk);

    ts::next_tx(&mut scenario, CUSTOMER);
    let mut escrow_obj = ts::take_shared<OrderEscrow<SUI>>(&scenario);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let cap = ts::take_from_sender<ReleaseCap<SUI>>(&scenario);
    escrow::release(&mut escrow_obj, cap, &pa, &clk, ts::ctx(&mut scenario));
    assert!(escrow::get_status(&escrow_obj) == 2, 101);
    ts::return_shared(escrow_obj);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);

    ts::end(scenario);
}

#[test]
public fun test_refund() {
    let mut scenario = setup();

    ts::next_tx(&mut scenario, CUSTOMER);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let (release_cap, refund_cap) = escrow::create_escrow<SUI>(
        b"order3",
        CUSTOMER,
        MERCHANT,
        75,
        &pa,
        vector[],
        &clk,
        ts::ctx(&mut scenario),
    );
    transfer::public_transfer(release_cap, CUSTOMER);
    transfer::public_transfer(refund_cap, CUSTOMER);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);

    ts::next_tx(&mut scenario, CUSTOMER);
    let mut escrow_obj = ts::take_shared<OrderEscrow<SUI>>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    escrow::deposit(
        &mut escrow_obj,
        coin::mint_for_testing<SUI>(75, ts::ctx(&mut scenario)),
        &clk,
        ts::ctx(&mut scenario),
    );
    ts::return_shared(escrow_obj);
    clock::destroy_for_testing(clk);

    ts::next_tx(&mut scenario, CUSTOMER);
    let mut escrow_obj = ts::take_shared<OrderEscrow<SUI>>(&scenario);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let cap = ts::take_from_sender<RefundCap<SUI>>(&scenario);
    escrow::refund(&mut escrow_obj, cap, &pa, &clk, ts::ctx(&mut scenario));
    assert!(escrow::get_status(&escrow_obj) == 3, 102);
    ts::return_shared(escrow_obj);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);

    ts::end(scenario);
}

#[test]
public fun test_dispute_and_emergency_withdraw() {
    let mut scenario = setup();

    ts::next_tx(&mut scenario, ADMIN);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let (release_cap, refund_cap) = escrow::create_escrow<SUI>(
        b"order4",
        CUSTOMER,
        MERCHANT,
        80,
        &pa,
        vector[],
        &clk,
        ts::ctx(&mut scenario),
    );
    transfer::public_transfer(release_cap, ADMIN);
    transfer::public_transfer(refund_cap, ADMIN);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);

    ts::next_tx(&mut scenario, CUSTOMER);
    let mut escrow_obj = ts::take_shared<OrderEscrow<SUI>>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    escrow::deposit(
        &mut escrow_obj,
        coin::mint_for_testing<SUI>(80, ts::ctx(&mut scenario)),
        &clk,
        ts::ctx(&mut scenario),
    );
    ts::return_shared(escrow_obj);
    clock::destroy_for_testing(clk);

    ts::next_tx(&mut scenario, ADMIN);
    let mut escrow_obj = ts::take_shared<OrderEscrow<SUI>>(&scenario);
    let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    escrow::dispute(&admin_cap, &mut escrow_obj, &clk, ts::ctx(&mut scenario));
    assert!(escrow::get_status(&escrow_obj) == 4, 200);
    escrow::emergency_withdraw(&admin_cap, &mut escrow_obj, MERCHANT, &clk, ts::ctx(&mut scenario));
    assert!(escrow::get_status(&escrow_obj) == 5, 201);
    ts::return_shared(escrow_obj);
    ts::return_to_sender(&scenario, admin_cap);
    clock::destroy_for_testing(clk);

    ts::end(scenario);
}

// ============================================
//  SINGLE-PTB (create_and_fund_escrow) TESTS
// ============================================

const PLATFORM: address = @0xD;

/// Happy path: buyer's single call creates a funded escrow + returns both caps.
#[test]
public fun test_create_and_fund_happy_path() {
    let mut scenario = setup();

    // Buyer signs the tx.
    ts::next_tx(&mut scenario, CUSTOMER);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let payment = coin::mint_for_testing<SUI>(250, ts::ctx(&mut scenario));

    let (escrow_obj, release_cap, refund_cap) = escrow::create_and_fund_escrow<SUI>(
        payment,
        b"order_caf_1",
        MERCHANT,
        &pa,
        vector[],
        &clk,
        ts::ctx(&mut scenario),
    );

    // Status must be FUNDED (1) from inception, not PENDING (0).
    assert!(escrow::get_status(&escrow_obj) == 1, 300);
    assert!(escrow::get_amount(&escrow_obj) == 250, 301);

    // Hand the escrow off to be shared (mirrors what the PTB does).
    escrow::share_escrow(escrow_obj);
    // Caps go to the Artos platform address (mirrors PTB transferObjects).
    transfer::public_transfer(release_cap, PLATFORM);
    transfer::public_transfer(refund_cap, PLATFORM);

    ts::return_shared(pa);
    clock::destroy_for_testing(clk);
    ts::end(scenario);
}

/// Adversarial: zero-amount payment must abort with code 60.
#[test, expected_failure(abort_code = 60, location = escrow)]
public fun test_create_and_fund_rejects_zero_amount() {
    let mut scenario = setup();

    ts::next_tx(&mut scenario, CUSTOMER);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let empty_payment = coin::mint_for_testing<SUI>(0, ts::ctx(&mut scenario));

    let (escrow_obj, release_cap, refund_cap) = escrow::create_and_fund_escrow<SUI>(
        empty_payment,
        b"order_caf_zero",
        MERCHANT,
        &pa,
        vector[],
        &clk,
        ts::ctx(&mut scenario),
    );

    // Unreachable — abort above. Consume values to satisfy the type checker.
    escrow::share_escrow(escrow_obj);
    transfer::public_transfer(release_cap, PLATFORM);
    transfer::public_transfer(refund_cap, PLATFORM);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);
    ts::end(scenario);
}

/// End-to-end: buyer create+funds → merchant releases → status=released, funds at merchant.
#[test]
public fun test_create_and_fund_then_release() {
    let mut scenario = setup();

    // Buyer creates + funds in one shot.
    ts::next_tx(&mut scenario, CUSTOMER);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let payment = coin::mint_for_testing<SUI>(500, ts::ctx(&mut scenario));

    let (escrow_obj, release_cap, refund_cap) = escrow::create_and_fund_escrow<SUI>(
        payment,
        b"order_caf_release",
        MERCHANT,
        &pa,
        vector[],
        &clk,
        ts::ctx(&mut scenario),
    );
    escrow::share_escrow(escrow_obj);
    transfer::public_transfer(release_cap, PLATFORM);
    transfer::public_transfer(refund_cap, PLATFORM);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);

    // Platform uses the ReleaseCap to release.
    ts::next_tx(&mut scenario, PLATFORM);
    let mut escrow_obj = ts::take_shared<OrderEscrow<SUI>>(&scenario);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let cap = ts::take_from_sender<ReleaseCap<SUI>>(&scenario);

    escrow::release(&mut escrow_obj, cap, &pa, &clk, ts::ctx(&mut scenario));
    assert!(escrow::get_status(&escrow_obj) == 2, 310);

    ts::return_shared(escrow_obj);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);
    ts::end(scenario);
}

/// End-to-end refund: buyer create+funds → platform refunds → status=refunded.
#[test]
public fun test_create_and_fund_then_refund() {
    let mut scenario = setup();

    ts::next_tx(&mut scenario, CUSTOMER);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let payment = coin::mint_for_testing<SUI>(120, ts::ctx(&mut scenario));

    let (escrow_obj, release_cap, refund_cap) = escrow::create_and_fund_escrow<SUI>(
        payment,
        b"order_caf_refund",
        MERCHANT,
        &pa,
        vector[],
        &clk,
        ts::ctx(&mut scenario),
    );
    escrow::share_escrow(escrow_obj);
    transfer::public_transfer(release_cap, PLATFORM);
    transfer::public_transfer(refund_cap, PLATFORM);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);

    ts::next_tx(&mut scenario, PLATFORM);
    let mut escrow_obj = ts::take_shared<OrderEscrow<SUI>>(&scenario);
    let pa = ts::take_shared<ProgrammableAccount>(&scenario);
    let clk = clock::create_for_testing(ts::ctx(&mut scenario));
    let cap = ts::take_from_sender<RefundCap<SUI>>(&scenario);

    escrow::refund(&mut escrow_obj, cap, &pa, &clk, ts::ctx(&mut scenario));
    assert!(escrow::get_status(&escrow_obj) == 3, 320);

    ts::return_shared(escrow_obj);
    ts::return_shared(pa);
    clock::destroy_for_testing(clk);
    ts::end(scenario);
}
