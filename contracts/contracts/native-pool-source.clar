;; title: native-pool-source
;; summary: Reward source for signer-managers whose staker claim takes no
;;          staker argument and pays `tx-sender`.
;; description:
;;   `native-pool-signer-manager` binds `(staker tx-sender)` and pays that
;;   principal, so its claim does not fit `reward-source-trait` directly. The
;;   router never switches identity, so `tx-sender` is still the staker by the
;;   time this adapter calls the manager, and the manager pays them.
;;
;;   One adapter per manager: the manager is a literal, so there is no admin
;;   surface and nothing to repoint. Managers built from the stacks-core
;;   reference template (fastpool-1, fastpool-max500, xverse) already match
;;   `reward-source-trait` and need no adapter.

(impl-trait .kessel-traits.reward-source-trait)

;; The claim would pay `tx-sender`, not the staker it was asked to claim for.
(define-constant ERR_STAKER_MISMATCH (err u200))

(define-public (claim-staker-rewards
    (staker principal)
    (reward-cycle uint)
    (bond-index (optional uint))
  )
  (begin
    (asserts! (is-eq staker tx-sender) ERR_STAKER_MISMATCH)
    (let ((earned (try! (contract-call? 'SP4SZE494VC2YC5JYG7AYFQ44F5Q4PYV7DVMDPBG.native-pool-signer-manager
        claim-staker-rewards reward-cycle bond-index
      ))))
      ;; This manager always pays sBTC; it has no L1 payout option.
      (ok {
        earned: earned,
        withdrawal-request: none,
      })
    )
  )
)
