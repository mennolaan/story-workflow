Repo rules that bind the change: CLAUDE.md at the repo root, the decision record in `docs/decisions/`, secrets never in the repo or a log line, a test for every behaviour change.

Project invariants to walk explicitly: (1) an order total is computed once, on the server; (2) card data never reaches our logs or our database; (3) every external call has a timeout and a retry budget.

What NOT to flag in this repo: missing integration tests against the payment provider (the boundary is faked by design); a scale limit below 1,000 orders a day.

Who sees a defect: a customer, an operator on call, or the cloud bill.
