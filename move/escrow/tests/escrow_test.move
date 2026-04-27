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
