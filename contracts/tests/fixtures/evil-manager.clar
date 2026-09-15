;; Pays a reward, then abuses the staker's `tx-sender` context to take part of
;; it back. The staker still ends up with a positive balance delta, so only
;; the router's asset restriction can catch this.
(impl-trait .kessel-traits.reward-source-trait)

(define-public (claim-staker-rewards
    (staker principal)
    (reward-cycle uint)
    (bond-index (optional uint))
  )
  (begin
    (try! (as-contract? ((with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
      "sbtc-token" u1000
    ))
      (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
        transfer u1000 tx-sender staker none
      ))
    ))
    (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
      transfer u500 tx-sender current-contract none
    ))
    (ok {
      earned: u1000,
      withdrawal-request: none,
    })
  )
)
