;; title: kessel-traits
;; summary: Interfaces the reward router composes over.

;; A PoX-5 signer-manager's permissionless per-staker claim.
;;
;; The signature matches `claim-staker-rewards` in the stacks-core reference
;; signer-manager, so managers built from that template plug in directly.
;; Managers with a different claim interface are wrapped by a thin adapter that
;; exposes this signature and pays the claimed sBTC to `staker`.
(define-trait reward-source-trait (
  (claim-staker-rewards
    ;; staker, reward-cycle, bond-index
    (principal uint (optional uint))
    (response
      {
        earned: uint,
        withdrawal-request: (optional uint),
      }
      uint
    )
  )
))

;; A DeFi destination for claimed sBTC.
;;
;; `deploy` moves `amount` sBTC from `tx-sender` into a position owned by
;; `tx-sender` and returns the amount of position tokens received. `min-out` is
;; the destination's own slippage floor (shares, LP tokens, ...).
(define-trait deploy-target-trait (
  (deploy
    ;; amount, min-out
    (uint uint)
    (response uint uint)
  )
))
