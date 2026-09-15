;; title: stbtc-target
;; summary: Deploy target that stakes sBTC into StackingDAO for stBTC.
;; description:
;;   `stacking-dao-core-stbtc-v1.deposit` debits sBTC from `tx-sender` and
;;   mints stBTC to `tx-sender`, so the stBTC lands with the router's caller.
;;   `min-out` is StackingDAO's `min-shares-out`; derive it off-chain from
;;   `data-stbtc-v1.get-sbtc-per-stbtc`.

(impl-trait .kessel-traits.deploy-target-trait)

(define-public (deploy
    (amount uint)
    (min-out uint)
  )
  (contract-call?
    'SP4SZE494VC2YC5JYG7AYFQ44F5Q4PYV7DVMDPBG.stacking-dao-core-stbtc-v1
    deposit amount min-out
  )
)
