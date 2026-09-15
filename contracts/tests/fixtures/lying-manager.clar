;; Reports rewards it never pays. The router must measure, not trust.
(impl-trait .kessel-traits.reward-source-trait)

(define-public (claim-staker-rewards
    (staker principal)
    (reward-cycle uint)
    (bond-index (optional uint))
  )
  (ok {
    earned: u500000,
    withdrawal-request: none,
  })
)
