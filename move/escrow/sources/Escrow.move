module artos::escrow;

use 0x1::option::{Self, Option};
use 0x1::type_name::{Self, TypeName};
use 0x2::balance::{Self, Balance};
use 0x2::clock::{Self, Clock};
use 0x2::coin::{Self, Coin};
use 0x2::event;
use 0x2::object::{Self, UID, ID};
use 0x2::transfer;
use 0x2::tx_context::{Self, TxContext};

// ============================================
//  NAUTILUS PA STUB (Replace in production)
// ============================================

public struct ProgrammableAccount has key, store {
    id: UID,
}

public fun assert_is_authorized(_pa: &ProgrammableAccount, _ctx: &TxContext) {}

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
    pa_id: ID,
}

public struct RefundCap<phantom T> has key, store {
    id: UID,
    escrow_id: ID,
    pa_id: ID,
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
//  AI ALLOWANCE — Trustless agent spending budget
// ============================================
//
// `AiAllowance<T>` is the on-chain analogue of AP2's "trusted, deterministic
// channel of consent" (UCP spec §AP2 Mandates, Option 1). The user signs ONCE
// in Slush to create it, depositing a `Balance<T>` and binding a spending
// policy. From then on, a pre-registered agent can spend within the policy
// without further user signatures. The user can revoke at any time.
//
// Two identity axes for the agent, mirroring the off-chain AP2 model:
//   • `agent_sui_address` — ed25519 Sui keypair the agent uses to submit PTBs.
//     Enforced by `tx_context::sender(ctx) == agent_sui_address` on every spend.
//   • `agent_p256_kid`    — RFC 7638 thumbprint of the agent's P-256 JWK,
//     used off-chain by the backend when signing AP2 `checkout_mandate`s on
//     this allowance's behalf. Stored on-chain for public auditability.
//
// Policy is enforced atomically inside `spend_from_allowance`:
//   1. not revoked
//   2. not past `expires_at`
//   3. `amount <= max_per_purchase`
//   4. `spent_today + amount <= max_per_day` (with day rollover)
//   5. `merchant` ∈ `allowed_merchants`
//   6. `tx_context::sender(ctx) == agent_sui_address`
//
// Funds flow: allowance.funds → escrow.funds, via the existing escrow
// lifecycle. Refunds route back to the allowance owner, NOT the agent.

public struct AiAllowance<phantom T> has key, store {
    id: UID,
    /// The user who created and funds the allowance. Refunds route here.
    owner: address,
    /// Pre-deposited budget the agent can spend from.
    funds: Balance<T>,
    /// Hard cap per single purchase.
    max_per_purchase: u64,
    /// Rolling-24h cap; `spent_today` resets when `now >= day_started_at + 86400000`.
    max_per_day: u64,
    spent_today: u64,
    day_started_at: u64,
    /// Allowance becomes unusable after this timestamp (ms since epoch).
    expires_at: u64,
    /// Empty vector = any merchant allowed. Non-empty = whitelist.
    allowed_merchants: vector<address>,
    /// Sui address the agent uses to submit `spend_from_allowance` PTBs.
    agent_sui_address: address,
    /// RFC 7638 JWK thumbprint of the agent's P-256 mandate-signing key.
    /// Advisory metadata for off-chain AP2 verification; not consulted on-chain.
    agent_p256_kid: vector<u8>,
    /// Set by `revoke_allowance`; subsequent spends abort.
    revoked: bool,
    created_at: u64,
}

public struct EventAllowanceCreated has copy, drop {
    allowance_id: ID,
    owner: address,
    agent_sui_address: address,
    agent_p256_kid: vector<u8>,
    initial_balance: u64,
    max_per_purchase: u64,
    max_per_day: u64,
    expires_at: u64,
    coin_type: TypeName,
    timestamp: u64,
}

public struct EventAllowanceToppedUp has copy, drop {
    allowance_id: ID,
    amount: u64,
    new_balance: u64,
    coin_type: TypeName,
    timestamp: u64,
}

public struct EventAllowanceSpent has copy, drop {
    allowance_id: ID,
    escrow_id: ID,
    order_id: vector<u8>,
    merchant: address,
    amount: u64,
    spent_today_after: u64,
    remaining_balance: u64,
    coin_type: TypeName,
    timestamp: u64,
}

public struct EventAllowanceRevoked has copy, drop {
    allowance_id: ID,
    owner: address,
    refunded_amount: u64,
    coin_type: TypeName,
    timestamp: u64,
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
    ctx: &mut TxContext,
): (ReleaseCap<T>, RefundCap<T>) {
    let id = object::new(ctx);
    let now = clock::timestamp_ms(clock);
    let escrow_id = object::uid_to_inner(&id);
    let pa_id = object::uid_to_inner(&pa.id);

    let coin_type = type_name::get<T>();

    let release_cap = ReleaseCap<T> {
        id: object::new(ctx),
        escrow_id,
        pa_id,
    };
    let refund_cap = RefundCap<T> {
        id: object::new(ctx),
        escrow_id,
        pa_id,
    };

    event::emit(EventCreated {
        order_id,
        customer,
        merchant,
        amount,
        coin_type,
        timestamp: now,
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

// ============================================
//  SINGLE-PTB ESCROW (agent / UCP path)
// ============================================
//
// `create_and_fund_escrow` lets the BUYER atomically create an already-funded
// escrow in a single signed PTB:
//
//   1. Buyer's wallet selects a `Coin<T>` and passes it in.
//   2. We consume it directly into the escrow's `Balance<T>`.
//   3. Status is `1` (funded) from inception — no separate `deposit` call.
//   4. The escrow object and both capabilities are RETURNED to the caller —
//      we do NOT share or transfer inside this function, per Sui composability
//      best practice. The PTB calls `share_escrow` + `transferObjects`.
//
// `tx_context::sender(ctx)` is bound as `customer` so spoofing is impossible —
// the buyer's signature *is* the identity proof.
public fun create_and_fund_escrow<T>(
    payment: Coin<T>,
    order_id: vector<u8>,
    merchant: address,
    pa: &ProgrammableAccount,
    pa_policy: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): (OrderEscrow<T>, ReleaseCap<T>, RefundCap<T>) {
    let customer = tx_context::sender(ctx);
    let amount = coin::value(&payment);
    assert!(amount > 0, 60); // Must fund with non-zero amount

    let now = clock::timestamp_ms(clock);
    let id = object::new(ctx);
    let escrow_id = object::uid_to_inner(&id);
    let pa_id = object::uid_to_inner(&pa.id);
    let coin_type = type_name::get<T>();

    let release_cap = ReleaseCap<T> {
        id: object::new(ctx),
        escrow_id,
        pa_id,
    };
    let refund_cap = RefundCap<T> {
        id: object::new(ctx),
        escrow_id,
        pa_id,
    };

    event::emit(EventCreated {
        order_id,
        customer,
        merchant,
        amount,
        coin_type,
        timestamp: now,
    });

    let balance = coin::into_balance(payment);

    event::emit(EventDeposited {
        order_id,
        amount,
        coin_type,
        timestamp: now,
        payer: customer,
    });

    let escrow = OrderEscrow<T> {
        id,
        order_id,
        customer,
        merchant,
        amount,
        status: 1, // funded immediately
        created_at: now,
        deposit_at: option::some(now),
        pa_id,
        funds: option::some(balance),
        pa_policy,
        coin_type,
    };

    (escrow, release_cap, refund_cap)
}

/// Share an `OrderEscrow<T>` produced by `create_and_fund_escrow`.
/// Separated from creation so the PTB can transfer caps before sharing.
/// Lint allows: the object is freshly created in the same PTB by
/// `create_and_fund_escrow`; sharing it here is the intended pattern.
#[allow(lint(share_owned, custom_state_change))]
public fun share_escrow<T>(escrow: OrderEscrow<T>) {
    transfer::share_object(escrow);
}

/// Deposit any coin type
public fun deposit<T>(
    escrow: &mut OrderEscrow<T>,
    payment: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
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
    ctx: &mut TxContext,
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
    ctx: &mut TxContext,
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
    ctx: &mut TxContext,
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
    ctx: &mut TxContext,
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
//  AI ALLOWANCE — Entry functions
// ============================================
//
// Error code range 70–79 reserved for allowance flows.
//   70 zero initial deposit
//   71 zero max_per_purchase
//   72 max_per_day < max_per_purchase (nonsensical policy)
//   73 expires_at in the past
//   74 zero top-up amount
//   75 revoke called by non-owner
//   76 spend called by wrong agent address
//   77 allowance revoked
//   78 allowance expired
//   79 amount > max_per_purchase
//   80 daily cap exhausted
//   81 merchant not in whitelist
//   82 insufficient balance

const DAY_MS: u64 = 86_400_000;

/// User signs ONE Slush tx to bootstrap a standing allowance for an agent.
/// Returns the allowance object so the PTB can `share_object` it (so the
/// agent can later borrow `&mut` to spend). Same pattern as `create_and_fund_escrow`.
public fun create_allowance<T>(
    funding: Coin<T>,
    max_per_purchase: u64,
    max_per_day: u64,
    expires_at: u64,
    allowed_merchants: vector<address>,
    agent_sui_address: address,
    agent_p256_kid: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): AiAllowance<T> {
    let now = clock::timestamp_ms(clock);
    let initial = coin::value(&funding);

    assert!(initial > 0, 70);
    assert!(max_per_purchase > 0, 71);
    assert!(max_per_day >= max_per_purchase, 72);
    assert!(expires_at > now, 73);

    let owner = tx_context::sender(ctx);
    let coin_type = type_name::get<T>();
    let funds = coin::into_balance(funding);

    let id = object::new(ctx);
    let allowance_id = object::uid_to_inner(&id);

    let allowance = AiAllowance<T> {
        id,
        owner,
        funds,
        max_per_purchase,
        max_per_day,
        spent_today: 0,
        day_started_at: now,
        expires_at,
        allowed_merchants,
        agent_sui_address,
        agent_p256_kid,
        revoked: false,
        created_at: now,
    };

    event::emit(EventAllowanceCreated {
        allowance_id,
        owner,
        agent_sui_address,
        agent_p256_kid,
        initial_balance: initial,
        max_per_purchase,
        max_per_day,
        expires_at,
        coin_type,
        timestamp: now,
    });

    allowance
}

/// Share helper — PTB calls this after `create_allowance` so the allowance
/// becomes a shared object the agent can borrow `&mut` to spend.
#[allow(lint(share_owned, custom_state_change))]
public fun share_allowance<T>(allowance: AiAllowance<T>) {
    transfer::share_object(allowance);
}

/// Owner-only — add more budget without changing policy.
public fun top_up_allowance<T>(
    allowance: &mut AiAllowance<T>,
    funding: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(tx_context::sender(ctx) == allowance.owner, 75);
    let added = coin::value(&funding);
    assert!(added > 0, 74);

    balance::join(&mut allowance.funds, coin::into_balance(funding));

    event::emit(EventAllowanceToppedUp {
        allowance_id: object::uid_to_inner(&allowance.id),
        amount: added,
        new_balance: balance::value(&allowance.funds),
        coin_type: type_name::get<T>(),
        timestamp: clock::timestamp_ms(clock),
    });
}

/// Owner-only — terminate the allowance and return remaining funds to owner.
/// After this, `revoked = true` and any future spend aborts with code 77.
/// We do NOT delete the object so the audit trail (created_at, spent_today,
/// agent identity) remains queryable on chain.
public fun revoke_allowance<T>(allowance: &mut AiAllowance<T>, clock: &Clock, ctx: &mut TxContext) {
    assert!(tx_context::sender(ctx) == allowance.owner, 75);

    let remaining_balance = balance::value(&allowance.funds);
    let coin_type = type_name::get<T>();

    if (remaining_balance > 0) {
        let drained = balance::withdraw_all(&mut allowance.funds);
        let refund_coin = coin::from_balance(drained, ctx);
        transfer::public_transfer(refund_coin, allowance.owner);
    };

    allowance.revoked = true;

    event::emit(EventAllowanceRevoked {
        allowance_id: object::uid_to_inner(&allowance.id),
        owner: allowance.owner,
        refunded_amount: remaining_balance,
        coin_type,
        timestamp: clock::timestamp_ms(clock),
    });
}

/// Agent-only — atomically spend `amount` from the allowance into a fresh
/// funded escrow. Mirrors `create_and_fund_escrow` but the funds come from
/// `allowance.funds` and `customer` is bound to `allowance.owner` (not the
/// tx sender, which is the agent).
///
/// All policy checks run before any state mutation; if any assertion fails
/// the entire PTB aborts and no funds move.
public fun spend_from_allowance<T>(
    allowance: &mut AiAllowance<T>,
    order_id: vector<u8>,
    merchant: address,
    amount: u64,
    pa: &ProgrammableAccount,
    pa_policy: vector<u8>,
    clock: &Clock,
    ctx: &mut TxContext,
): (OrderEscrow<T>, ReleaseCap<T>, RefundCap<T>) {
    let now = clock::timestamp_ms(clock);
    let sender = tx_context::sender(ctx);

    // 1. Agent identity check.
    assert!(sender == allowance.agent_sui_address, 76);
    // 2. Lifecycle checks.
    assert!(!allowance.revoked, 77);
    assert!(now < allowance.expires_at, 78);
    // 3. Per-purchase cap.
    assert!(amount > 0, 60); // matches create_and_fund_escrow's zero-amount code
    assert!(amount <= allowance.max_per_purchase, 79);
    // 4. Daily cap with rollover.
    let spent_after = roll_day_if_needed(allowance, now) + amount;
    assert!(spent_after <= allowance.max_per_day, 80);
    // 5. Merchant whitelist (empty vector = unrestricted).
    if (!vector::is_empty(&allowance.allowed_merchants)) {
        assert!(vector::contains(&allowance.allowed_merchants, &merchant), 81);
    };
    // 6. Sufficient balance.
    assert!(balance::value(&allowance.funds) >= amount, 82);

    // ── Mutations after this line ─────────────────────────────────────────
    allowance.spent_today = spent_after;

    let coin_type = type_name::get<T>();
    let customer = allowance.owner;

    // Carve the spend out of the allowance balance.
    let spend_balance = balance::split(&mut allowance.funds, amount);

    // Build the escrow inline. We can't reuse `create_and_fund_escrow` because
    // it binds `customer` to `tx_context::sender` (which is the agent here),
    // breaking refund routing.
    let escrow_uid = object::new(ctx);
    let escrow_id = object::uid_to_inner(&escrow_uid);
    let pa_id = object::uid_to_inner(&pa.id);

    let release_cap = ReleaseCap<T> {
        id: object::new(ctx),
        escrow_id,
        pa_id,
    };
    let refund_cap = RefundCap<T> {
        id: object::new(ctx),
        escrow_id,
        pa_id,
    };

    event::emit(EventCreated {
        order_id,
        customer,
        merchant,
        amount,
        coin_type,
        timestamp: now,
    });
    event::emit(EventDeposited {
        order_id,
        amount,
        coin_type,
        timestamp: now,
        payer: customer, // funds originated from the allowance, owned by `customer`
    });
    event::emit(EventAllowanceSpent {
        allowance_id: object::uid_to_inner(&allowance.id),
        escrow_id,
        order_id,
        merchant,
        amount,
        spent_today_after: allowance.spent_today,
        remaining_balance: balance::value(&allowance.funds),
        coin_type,
        timestamp: now,
    });

    let escrow = OrderEscrow<T> {
        id: escrow_uid,
        order_id,
        customer,
        merchant,
        amount,
        status: 1, // funded
        created_at: now,
        deposit_at: option::some(now),
        pa_id,
        funds: option::some(spend_balance),
        pa_policy,
        coin_type,
    };

    (escrow, release_cap, refund_cap)
}

/// Internal — rolls `spent_today` back to zero if more than 24h have passed
/// since `day_started_at`. Returns the (possibly reset) `spent_today` value.
fun roll_day_if_needed<T>(allowance: &mut AiAllowance<T>, now: u64): u64 {
    if (now >= allowance.day_started_at + DAY_MS) {
        allowance.spent_today = 0;
        allowance.day_started_at = now;
    };
    allowance.spent_today
}

// ── Allowance read-only helpers (for off-chain inspection / tests) ────────

public fun allowance_owner<T>(a: &AiAllowance<T>): address { a.owner }

public fun allowance_balance<T>(a: &AiAllowance<T>): u64 { balance::value(&a.funds) }

public fun allowance_spent_today<T>(a: &AiAllowance<T>): u64 { a.spent_today }

public fun allowance_max_per_purchase<T>(a: &AiAllowance<T>): u64 { a.max_per_purchase }

public fun allowance_max_per_day<T>(a: &AiAllowance<T>): u64 { a.max_per_day }

public fun allowance_expires_at<T>(a: &AiAllowance<T>): u64 { a.expires_at }

public fun allowance_revoked<T>(a: &AiAllowance<T>): bool { a.revoked }

public fun allowance_agent_address<T>(a: &AiAllowance<T>): address { a.agent_sui_address }

public fun allowance_agent_kid<T>(a: &AiAllowance<T>): &vector<u8> { &a.agent_p256_kid }

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

// ============================================
// ✅ TEST-ONLY HELPERS
// ============================================

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ESCROW {}, ctx);
}
