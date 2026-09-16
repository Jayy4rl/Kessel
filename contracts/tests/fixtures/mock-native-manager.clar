;; Test double for a signer-manager whose staker claim takes no staker
;; argument and pays `tx-sender`, like native-pool-signer-manager.

(define-constant ERR_NO_CLAIMABLE_REWARDS (err u1001))

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
    (reward-cycle uint)
    (bond-index (optional uint))
  )
  (let (
      (staker tx-sender)
      (earned (get-owed staker))
    )
    (asserts! (> earned u0) ERR_NO_CLAIMABLE_REWARDS)
    (map-delete owed staker)
    (try! (as-contract? ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
      "sbtc-token" earned
    ))
      (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
        transfer earned tx-sender staker none
      ))
    ))
    (ok earned)
  )
)
