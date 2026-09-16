;; Deploy target for Bitflow's legacy XYK sBTC/STX pool.
;;
;; Test fixture only: Bitflow's liquidity and fees have moved to HODLMM, and
;; this pool is near-empty. It is kept because it is a real protocol the
;; router can be driven end-to-end against on forked mainnet state; it is not
;; part of the deployable contract set and must not be registered as a target.
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
