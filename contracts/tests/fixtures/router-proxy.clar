;; An intermediary contract calling the router on a user's behalf.
(use-trait reward-source-trait .kessel-traits.reward-source-trait)
(use-trait deploy-target-trait .kessel-traits.deploy-target-trait)

(define-public (route
    (source <reward-source-trait>)
    (target-name (string-ascii 20))
    (target <deploy-target-trait>)
  )
  (contract-call? .reward-router claim-and-deploy u1 u10 source target-name
    target u0 u0 u0
  )
)
