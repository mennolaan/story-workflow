# Worked example: PO intent to a ready handoff

This is an authored teaching/eval fixture, not a reported customer deployment.
Its business rules apply only to this example. The sources in ../research.md
informed the structure, not the cancellation policy.

## 1. Original PO input

“As a customer, I want to cancel an order before it ships, so I can correct a
mistake without contacting support.”

At this point the story is NOT READY. “Ships” has no agreed system state;
refunds, concurrent shipment, retry behavior and authorization are unresolved.
Do not let an agent guess a refund deadline or promise that every order qualifies.

## 2. Evidence and answered decisions

For this fixture only, assume the PO supplied these answers:

- D1: Cancellation is allowed only for an order owned by the authenticated
  customer while its state is `confirmed`. `dispatching` is already too late.
- D2: Existing order-state transitions are authoritative. Cancellation and
  dispatch must compete atomically; exactly one transition wins.
- D3: A repeated successful cancellation returns the existing cancelled result;
  it creates no second cancellation event.
- D4: Refund handling is an existing downstream flow. Changing it or adding a
  refund deadline is out of scope; document that boundary.

The refinement record links the original story plus D1-D4, names who answered
and when, and retains any remaining nonblocking implementation assumptions.

## 3. Stable requirements and scenarios

| Id | Requirement and source | Acceptance scenario |
|---|---|---|
| R-1 | Only the authenticated owner can cancel (PO story, D1) | Given another customer owns the order, a cancellation request cannot change it or reveal private order details |
| R-2 | Cancellation is allowed in `confirmed` only (D1) | Given `dispatching`, the attempt reports the agreed conflict and leaves state/events unchanged |
| R-3 | Dispatch and cancellation have one winner (D2) | Two concurrent attempts cannot both produce successful transitions |
| R-4 | Repeating cancellation creates no second event (D3) | Repeat the request and inspect persisted event count and returned state |
| R-5 | Customer-facing docs explain eligibility and refund boundary (D1,D4) | Read the updated guide and compare it with the API/state behavior |

Exact status codes/messages must come from existing API conventions or a real
scope decision. The refinement names this remaining decision if conventions do
not settle it; it does not fabricate an agreed code in the scenarios.

## 4. Implementation-ready handoffs

First verify repository paths/callers and the existing transition contract.
An example safe split, AFTER that inspection, is:

- Foundation: settle the atomic transition API and error contract; own shared
  types and contract tests. Dependent work waits for its reviewed commit.
- Track A: implement cancellation and ownership checks with its exclusive
  service/test files; R-1 through R-4. Include a real database concurrency test.
- Track B: implement customer UI states in exclusive UI/test files against the
  foundation contract; R-1/R-2. A mocked UI alone does not prove R-3.
- Integration: wire API/UI, update the shared customer guide, and run the full
  customer/retry/race scenarios; R-1 through R-5.

If inspection finds shared files or dependencies, the claims/grouping gate joins
or moves the affected tasks. These labels are not proof of independence.
The orchestrator chooses model/effort per owned scope, not per job title.

## 5. Evaluation before implementation

Positive case: the owner cancels a confirmed order once.
Negative cases: wrong owner, dispatching order, repeat request and dispatch race.
Expected observations: persisted state, event count, response contract and UI.
Forbidden: two winning transitions, duplicate events, invented refund promises.
Define fixture setup and graders before implementation. An assertion that only
checks an HTTP status cannot certify the persisted event count.

## 6. Completion and traceability

Each R id maps to frozen criterion ids and tasks. Capture the real checks at the
integrated HEAD, review those criteria, then derive `traceability.json` through
`story-review.sh trace`. If the race was not executed against the required
storage engine, R-3 is unverified even when every unit test passed. Update the
implementation/evidence or resolve a real scope decision; never weaken the
original requirement to declare completion.
