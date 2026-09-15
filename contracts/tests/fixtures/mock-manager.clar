;; Test double for a reference signer-manager: pays each staker's configured
;; sBTC from its own balance, like `claim-staker-rewards` with an sBTC payout.
(impl-trait .kessel-traits.reward-source-trait)

(define-map owed
  principal
  uint
)

(define-public (set-owed
    (staker principal)
    (amount uint)
  )
  (ok (map-set owed staker amount))
)

(define-read-only (get-owed (staker principal))
  (default-to u0 (map-get? owed staker))
)

(define-public (claim-staker-rewards
    (staker principal)
    (reward-cycle uint)
    (bond-index (optional uint))
  )
  (let ((earned (get-owed staker)))
    (map-delete owed staker)
    (if (> earned u0)
      (try! (as-contract? ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
        "sbtc-token" earned
      ))
        (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
          transfer earned tx-sender staker none
        ))
      ))
      true
    )
    (ok {
      earned: earned,
      withdrawal-request: none,
    })
  )
)
