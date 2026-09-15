;; title: bitflow-sbtc-stx-target
;; summary: Deploy target that adds sBTC/STX liquidity on Bitflow XYK.
;; description:
;;   sBTC is the pool's x-token, so `amount` is the x-amount; xyk-core pulls the
;;   matching STX (y-amount) from `tx-sender` and mints LP tokens to
;;   `tx-sender`. The router caps that STX with its `max-stx` allowance.
;;   `min-out` is Bitflow's `min-dlp` and must be non-zero.

(impl-trait .kessel-traits.deploy-target-trait)

(define-public (deploy
    (amount uint)
    (min-out uint)
  )
  (contract-call? 'SM1793C4R5PZ4NS4VQ4WMP7SKKYVH8JZEWSZ9HCCR.xyk-core-v-1-2
    add-liquidity
    'SM1793C4R5PZ4NS4VQ4WMP7SKKYVH8JZEWSZ9HCCR.xyk-pool-sbtc-stx-v-1-1
    'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
    'SM1793C4R5PZ4NS4VQ4WMP7SKKYVH8JZEWSZ9HCCR.token-stx-v-1-2 amount min-out
  )
)
