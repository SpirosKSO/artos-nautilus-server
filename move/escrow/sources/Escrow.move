module artos::escrow {
    use 0x2::object::{Self, UID, ID};
    use 0x1::option::{Self, Option};
    use 0x2::clock::{Self, Clock};
    use 0x2::tx_context::{Self, TxContext};
    use 0x2::coin::{Self, Coin};
    use 0x2::event;
    use 0x2::transfer;
    use 0x2::balance::{Self, Balance};
    use 0x1::type_name::{Self, TypeName};

    // ============================================
    //  NAUTILUS PA STUB (Replace in production)
    // ============================================
    
    public struct ProgrammableAccount has key, store {
        id: UID,
    }

    public fun assert_is_authorized(_pa: &ProgrammableAccount, _ctx: &TxContext) {
        // Stub - replace with actual Nautilus logic
    }

    // ============================================
    // ✅ GENERIC ESCROW STRUCTURES
    // ============================================
    
    /// Generic escrow that works with any coin type
    /// T = SUI, USDC, USDT, WETH, etc.
    public struct OrderEscrow<phantom T> has key, store {
        id: UID,
        order_id: vector<u8>,
        customer: address,
        merchant: address,
        amount: u64,
        status: u8, // 0=pending, 1=funded, 2=released, 3=refunded, 4=disputed, 5=emergency_withdrawn
        created_at: u64,
        deposit_at: Option<u64>,
        pa_id: ID,
        funds: Option<Balance<T>>, //  Generic balance
        pa_policy: vector<u8>,
        coin_type: TypeName, //  Store coin type for verification
    }

    /// Capabilities (generic)
    public struct ReleaseCap<phantom T> has key, store { 
        id: UID, 
        escrow_id: ID, 
        pa_id: ID 
    }
    
    public struct RefundCap<phantom T> has key, store { 
        id: UID, 
        escrow_id: ID, 
        pa_id: ID 
    }

    /// Admin capability (not generic - manages all escrows)
    public struct AdminCap has key, store {
        id: UID,
    }

    // ============================================
    //  EVENTS (with coin type tracking)
    // ============================================
    
    public struct EventCreated has copy, drop {
        order_id: vector<u8>,
        customer: address,
        merchant: address,
        amount: u64,
        coin_type: TypeName,
        timestamp: u64,
    }

    public struct EventDeposited has copy, drop {
        order_id: vector<u8>,
        amount: u64,
        coin_type: TypeName,
        timestamp: u64,
        payer: address,
    }

    public struct EventReleased has copy, drop {
        order_id: vector<u8>,
        amount: u64,
        coin_type: TypeName,
        timestamp: u64,
        caller: address,
    }

    public struct EventRefunded has copy, drop {
        order_id: vector<u8>,
        amount: u64,
        coin_type: TypeName,
        timestamp: u64,
        caller: address,
    }

    public struct EventDisputed has copy, drop {
        escrow_id: ID,
        order_id: vector<u8>,
        timestamp: u64,
        caller: address,
    }

    public struct EventEmergencyWithdraw has copy, drop {
        escrow_id: ID,
        order_id: vector<u8>,
        recipient: address,
        amount: u64,
        coin_type: TypeName,
        timestamp: u64,
        caller: address,
    }

    // ============================================
    //  MODULE INITIALIZATION
    // ============================================
    
    public struct ESCROW has drop {}

    fun init(_witness: ESCROW, ctx: &mut TxContext) {
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        // Transfer AdminCap to deployer
        transfer::transfer(admin_cap, tx_context::sender(ctx));
    }

    // ============================================
    //  CORE ESCROW FUNCTIONS (Generic)
    // ============================================

    /// Create escrow for any coin type
    public fun create_escrow<T>(
        order_id: vector<u8>,
        customer: address,
        merchant: address,
        amount: u64,
        pa: &ProgrammableAccount,
        pa_policy: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext
    ): (ReleaseCap<T>, RefundCap<T>) {
        let id = object::new(ctx);
        let now = clock::timestamp_ms(clock);
        let escrow_id = object::uid_to_inner(&id);
        let pa_id = object::uid_to_inner(&pa.id);
        
        let coin_type = type_name::get<T>();
        
        let release_cap = ReleaseCap<T> { 
            id: object::new(ctx), 
            escrow_id, 
            pa_id 
        };
        let refund_cap = RefundCap<T> { 
            id: object::new(ctx), 
            escrow_id, 
            pa_id 
        };
        
        event::emit(EventCreated { 
            order_id, 
            customer, 
            merchant, 
            amount, 
            coin_type,
            timestamp: now 
        });
        
        let escrow = OrderEscrow<T> {
            id,
            order_id,
            customer,
            merchant,
            amount,
            status: 0,
            created_at: now,
            deposit_at: option::none(),
            pa_id,
            funds: option::none(),
            pa_policy,
            coin_type,
        };
        
        transfer::share_object(escrow);
        (release_cap, refund_cap)
    }

    /// Deposit any coin type
    public fun deposit<T>(
        escrow: &mut OrderEscrow<T>,
        payment: Coin<T>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(escrow.status == 0, 10); // Must be pending
        assert!(tx_context::sender(ctx) == escrow.customer, 11);
        
        let coin_value = coin::value(&payment);
        assert!(coin_value >= escrow.amount, 12);
        
        // Convert coin to balance for efficient storage
        let balance = coin::into_balance(payment);
        option::fill(&mut escrow.funds, balance);
        
        escrow.status = 1; // funded
        let now = clock::timestamp_ms(clock);
        option::fill(&mut escrow.deposit_at, now);
        
        event::emit(EventDeposited { 
            order_id: escrow.order_id, 
            amount: coin_value, 
            coin_type: escrow.coin_type,
            timestamp: now,
            payer: tx_context::sender(ctx),
        });
    }

    /// Release funds to merchant
    public fun release<T>(
        escrow: &mut OrderEscrow<T>,
        cap: ReleaseCap<T>,
        pa: &ProgrammableAccount,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let ReleaseCap { id, escrow_id, pa_id } = cap;
        object::delete(id);
        
        assert!(escrow_id == object::uid_to_inner(&escrow.id), 20);
        assert!(pa_id == object::uid_to_inner(&pa.id), 21);
        assert!(escrow.status == 1, 22); // Must be funded
        assert_is_authorized(pa, ctx);
        
        //  Optional: Time lock (uncomment for production)
        // if (option::is_some(&escrow.deposit_at)) {
        //     let deposit_time = *option::borrow(&escrow.deposit_at);
        //     let now = clock::timestamp_ms(clock);
        //     let min_lock_ms = 24 * 60 * 60 * 1000; // 24 hours
        //     assert!(now >= deposit_time + min_lock_ms, 23);
        // };
        
        let balance = option::extract(&mut escrow.funds);
        let amount = balance::value(&balance);
        let coin = coin::from_balance(balance, ctx);
        
        transfer::public_transfer(coin, escrow.merchant);
        escrow.status = 2; // released
        
        event::emit(EventReleased { 
            order_id: escrow.order_id, 
            amount, 
            coin_type: escrow.coin_type,
            timestamp: clock::timestamp_ms(clock),
            caller: tx_context::sender(ctx),
        });
    }

    /// Refund funds to customer
    public fun refund<T>(
        escrow: &mut OrderEscrow<T>,
        cap: RefundCap<T>,
        pa: &ProgrammableAccount,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let RefundCap { id, escrow_id, pa_id } = cap;
        object::delete(id);
        
        assert!(escrow_id == object::uid_to_inner(&escrow.id), 30);
        assert!(pa_id == object::uid_to_inner(&pa.id), 31);
        assert!(escrow.status == 1, 32); // Must be funded
        assert_is_authorized(pa, ctx);
        
        let balance = option::extract(&mut escrow.funds);
        let amount = balance::value(&balance);
        let coin = coin::from_balance(balance, ctx);
        
        transfer::public_transfer(coin, escrow.customer);
        escrow.status = 3; // refunded
        
        event::emit(EventRefunded { 
            order_id: escrow.order_id, 
            amount, 
            coin_type: escrow.coin_type,
            timestamp: clock::timestamp_ms(clock),
            caller: tx_context::sender(ctx),
        });
    }

    // ============================================
    //  DISPUTE RESOLUTION (Admin only)
    // ============================================

    /// Raise dispute (freezes funds)
    public fun dispute<T>(
        _admin_cap: &AdminCap,
        escrow: &mut OrderEscrow<T>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(escrow.status == 1, 40); // Must be funded
        escrow.status = 4; // disputed
        
        event::emit(EventDisputed {
            escrow_id: object::uid_to_inner(&escrow.id),
            order_id: escrow.order_id,
            timestamp: clock::timestamp_ms(clock),
            caller: tx_context::sender(ctx),
        });
    }

    /// Emergency withdrawal (admin resolves dispute)
    public fun emergency_withdraw<T>(
        _admin_cap: &AdminCap,
        escrow: &mut OrderEscrow<T>,
        recipient: address,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(escrow.status == 4, 50); // Must be disputed
        assert!(option::is_some(&escrow.funds), 51);
        
        let balance = option::extract(&mut escrow.funds);
        let amount = balance::value(&balance);
        let coin = coin::from_balance(balance, ctx);
        
        transfer::public_transfer(coin, recipient);
        escrow.status = 5; // emergency_withdrawn
        
        event::emit(EventEmergencyWithdraw {
            escrow_id: object::uid_to_inner(&escrow.id),
            order_id: escrow.order_id,
            recipient,
            amount,
            coin_type: escrow.coin_type,
            timestamp: clock::timestamp_ms(clock),
            caller: tx_context::sender(ctx),
        });
    }

    // ============================================
    // ✅ HELPER FUNCTIONS
    // ============================================
    
    /// Get escrow coin type
    public fun get_coin_type<T>(escrow: &OrderEscrow<T>): TypeName {
        escrow.coin_type
    }

    /// Get escrow status
    public fun get_status<T>(escrow: &OrderEscrow<T>): u8 {
        escrow.status
    }

    /// Get escrow amount
    public fun get_amount<T>(escrow: &OrderEscrow<T>): u64 {
        escrow.amount
    }

    // ============================================
    // ✅ TEST HELPER (Remove in production)
    // ============================================
    
    /// Create a test ProgrammableAccount for development
    public entry fun create_test_pa(ctx: &mut TxContext) {
        let pa = ProgrammableAccount {
            id: object::new(ctx),
        };
        transfer::share_object(pa);
    }
}