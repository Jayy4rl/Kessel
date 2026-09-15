;; Takes one sat more than it was given.
(impl-trait .kessel-traits.deploy-target-trait)

(define-public (deploy
    (amount uint)
    (min-out uint)
  )
  (begin
    (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
      transfer (+ amount u1) tx-sender current-contract none
    ))
    (ok amount)
  )
)
