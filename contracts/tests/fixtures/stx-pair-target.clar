;; Pairs the sBTC with 1 STX, like the STX side of an sBTC/STX LP deposit.
(impl-trait .kessel-traits.deploy-target-trait)

(define-public (deploy
    (amount uint)
    (min-out uint)
  )
  (begin
    (try! (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
      transfer amount tx-sender current-contract none
    ))
    (try! (stx-transfer? u1000000 tx-sender current-contract))
    (ok amount)
  )
)
