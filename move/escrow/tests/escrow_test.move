address 0x0 {
module escrow_test {
    use artos::escrow;
    use 0x2::object;
    use 0x2::coin::{Self as coin, Coin};
    use 0x2::sui::SUI;
    use 0x1::option;
    use 0x2::tx_context;
    use std::vector;

    /// Helper: create a dummy programmable account
    fun dummy_pa(): escrow::ProgrammableAccount {
        escrow::ProgrammableAccount {}
    }

    #[test]
    public fun test_create_and_deposit() {
        let ctx = &mut tx_context::new_for_testing();
        let pa = dummy_pa();
        let pa_policy = vector::empty<u8>();
        let (mut escrow_obj, _, _) = escrow::create_escrow(
            vector::utf8(b"order1"),
            @0x2,
            @0x3,
            100,
            &pa,
            pa_policy,
            ctx
        );
        let coin_obj = coin::mint<SUI>(100, ctx);
        escrow::deposit(&mut escrow_obj, @0x2, 100, coin_obj, ctx);
        assert!(escrow_obj.status == 1, 100);
    }

    #[test]
    public fun test_release_and_refund() {
        let ctx = &mut tx_context::new_for_testing();
        let pa = dummy_pa();
        let pa_policy = vector::empty<u8>();
        let (mut escrow_obj, mut release_cap, mut refund_cap) = escrow::create_escrow(
            vector::utf8(b"order2"),
            @0x2,
            @0x3,
            50,
            &pa,
            pa_policy,
            ctx
        );
        let coin_obj = coin::mint<SUI>(50, ctx);
        escrow::deposit(&mut escrow_obj, @0x2, 50, coin_obj, ctx);
        // Simulate time lock expiry
        escrow_obj.deposit_at = option::some(0);
        escrow::release(&mut escrow_obj, release_cap, &pa, ctx);
        assert!(escrow_obj.status == 2, 101);

        // Refund path (should not be possible after release, but test refund logic)
        let (mut escrow_obj2, _, mut refund_cap2) = escrow::create_escrow(
            vector::utf8(b"order3"),
            @0x2,
            @0x3,
            75,
            &pa,
            pa_policy,
            ctx
        );
        let coin_obj2 = coin::mint<SUI>(75, ctx);
        escrow::deposit(&mut escrow_obj2, @0x2, 75, coin_obj2, ctx);
        escrow::refund(&mut escrow_obj2, refund_cap2, &pa, ctx);
        assert!(escrow_obj2.status == 3, 102);
    }

    #[test]
    public fun test_dispute_and_emergency_withdraw() {
        let ctx = &mut tx_context::new_for_testing();
        let pa = dummy_pa();
        let pa_policy = vector::empty<u8>();
        let (mut escrow_obj, _, _) = escrow::create_escrow(
            vector::utf8(b"order4"),
            @0x2,
            @0x3,
            80,
            &pa,
            pa_policy,
            ctx
        );
        let coin_obj = coin::mint<SUI>(80, ctx);
        escrow::deposit(&mut escrow_obj, @0x2, 80, coin_obj, ctx);
        let dispute_cap = escrow::mint_dispute_cap(&escrow_obj, ctx);
        escrow::dispute(&mut escrow_obj, dispute_cap, ctx);
        assert!(escrow_obj.status == 4, 200);

        let dispute_cap2 = escrow::mint_dispute_cap(&escrow_obj, ctx);
        escrow::emergency_withdraw(&mut escrow_obj, dispute_cap2, @0x3, ctx);
        assert!(escrow_obj.status == 5, 201);
    }

    #[test]
    public fun test_close() {
        let ctx = &mut tx_context::new_for_testing();
        let pa = dummy_pa();
        let pa_policy = vector::empty<u8>();
        let (mut escrow_obj, _, _) = escrow::create_escrow(
            vector::utf8(b"order5"),
            @0x2,
            @0x3,
            10,
            &pa,
            pa_policy,
            ctx
        );
        escrow_obj.status = 2; // simulate released
        escrow::close(escrow_obj, &pa, ctx);
        // If no panic, close succeeded
    }
}
}
