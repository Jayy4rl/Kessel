;; Well-behaved target: takes exactly `amount` sBTC, returns 1 share per sat.
(impl-trait .kessel-traits.deploy-target-trait)

(define-public (deploy
    (amount uint)
    (min-out uint)
  )
  (begin
    (asserts! (>= amount min-out) (err u1))
    (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
      transfer amount tx-sender current-contract none
    ))
    (ok amount)
  )
)
