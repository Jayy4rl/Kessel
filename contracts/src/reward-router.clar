;; title: reward-router
;; summary: Claim PoX-5 bond rewards and deploy them into a DeFi position in a
;;          single atomic transaction.
;; description:
;;   The router never takes custody. Every leg runs with the caller as
;;   `tx-sender`: the signer-manager pays the claimed sBTC to the caller, and
;;   the deploy target moves it from the caller into a position the caller
;;   owns. Two `restrict-assets?` guards bound what those external contracts
;;   may do with the caller's assets:
;;     - claim leg:  no outflow of any asset
;;     - deploy leg: exactly the claimed sBTC, plus at most `max-stx` uSTX
;;   The claimed amount is measured from the caller's sBTC balance, never taken
;;   from the source's return value. Any failure reverts the whole transaction.

(use-trait reward-source-trait .kessel-traits.reward-source-trait)
(use-trait deploy-target-trait .kessel-traits.deploy-target-trait)

;; errors
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_PAUSED (err u101))
(define-constant ERR_UNKNOWN_TARGET (err u102))
(define-constant ERR_TARGET_DISABLED (err u103))
(define-constant ERR_TARGET_MISMATCH (err u104))
(define-constant ERR_SOURCE_NOT_ALLOWED (err u105))
(define-constant ERR_NOTHING_CLAIMED (err u106))
(define-constant ERR_BELOW_MIN_AMOUNT (err u107))
(define-constant ERR_CLAIM_MOVED_ASSETS (err u108))
(define-constant ERR_DEPLOY_ALLOWANCE_EXCEEDED (err u109))
(define-constant ERR_PARTIAL_DEPLOY (err u110))
(define-constant ERR_NOT_A_CONTRACT (err u111))
(define-constant ERR_INVALID_NAME (err u112))
(define-constant ERR_TOO_MANY_TARGETS (err u113))
(define-constant ERR_NO_PENDING_OWNER (err u114))

;; data vars
(define-data-var owner principal tx-sender)
(define-data-var pending-owner (optional principal) none)
(define-data-var paused bool false)
;; Registration order of target names, so `get-targets` can enumerate them.
(define-data-var target-names (list 20 (string-ascii 20)) (list))

;; data maps
(define-map targets
  (string-ascii 20)
  {
    contract: principal,
    enabled: bool,
  }
)
;; Signer-managers (or adapters over them) allowed as reward sources.
(define-map sources
  principal
  bool
)

;; public functions

;; Claim the caller's sBTC rewards for one bond leg of `reward-cycle` from
;; `source`, then deploy all of it into the registered target `target-name`.
;;
;; `min-amount` rejects claims smaller than the caller expects, `min-out` is
;; forwarded to the target as its slippage floor, and `max-stx` caps the uSTX
;; the target may pull from the caller (e.g. the STX side of an sBTC/STX LP).
(define-public (claim-and-deploy
    (bond-index uint)
    (reward-cycle uint)
    (source <reward-source-trait>)
    (target-name (string-ascii 20))
    (target <deploy-target-trait>)
    (min-amount uint)
    (min-out uint)
    (max-stx uint)
  )
  (let (
      (staker tx-sender)
      (entry (unwrap! (map-get? targets target-name) ERR_UNKNOWN_TARGET))
    )
    ;; Rewards are routed only when their owner calls directly.
    (asserts! (is-eq staker contract-caller) ERR_UNAUTHORIZED)
    (asserts! (not (var-get paused)) ERR_PAUSED)
    (asserts! (get enabled entry) ERR_TARGET_DISABLED)
    (asserts! (is-eq (contract-of target) (get contract entry))
      ERR_TARGET_MISMATCH
    )
    (asserts! (is-source-enabled (contract-of source)) ERR_SOURCE_NOT_ALLOWED)
    (let ((claimed (try! (claim-from source staker reward-cycle bond-index))))
      (asserts! (> claimed u0) ERR_NOTHING_CLAIMED)
      (asserts! (>= claimed min-amount) ERR_BELOW_MIN_AMOUNT)
      (let ((received (try! (deploy-to target staker claimed min-out max-stx))))
        (print {
          topic: "claim-and-deploy",
          staker: staker,
          bond-index: bond-index,
          reward-cycle: reward-cycle,
          source: (contract-of source),
          target: target-name,
          claimed: claimed,
          received: received,
        })
        (ok {
          claimed: claimed,
          deployed: claimed,
          received: received,
          target: target-name,
        })
      )
    )
  )
)

;; Register or update a deployment target. Owner only.
(define-public (set-target
    (target-name (string-ascii 20))
    (contract principal)
    (enabled bool)
  )
  (begin
    (asserts! (is-eq contract-caller (var-get owner)) ERR_UNAUTHORIZED)
    (asserts! (> (len target-name) u0) ERR_INVALID_NAME)
    (try! (assert-contract contract))
    (if (is-none (map-get? targets target-name))
      (var-set target-names
        (unwrap! (as-max-len? (append (var-get target-names) target-name) u20)
          ERR_TOO_MANY_TARGETS
        ))
      true
    )
    (map-set targets target-name {
      contract: contract,
      enabled: enabled,
    })
    (print {
      topic: "set-target",
      target: target-name,
      contract: contract,
      enabled: enabled,
    })
    (ok true)
  )
)

;; Allow or disallow a reward source. Owner only.
(define-public (set-source
    (contract principal)
    (enabled bool)
  )
  (begin
    (asserts! (is-eq contract-caller (var-get owner)) ERR_UNAUTHORIZED)
    (try! (assert-contract contract))
    (map-set sources contract enabled)
    (print {
      topic: "set-source",
      contract: contract,
      enabled: enabled,
    })
    (ok true)
  )
)

;; Emergency stop for `claim-and-deploy`. Owner only.
(define-public (set-paused (new-paused bool))
  (begin
    (asserts! (is-eq contract-caller (var-get owner)) ERR_UNAUTHORIZED)
    (var-set paused new-paused)
    (print {
      topic: "set-paused",
      paused: new-paused,
    })
    (ok true)
  )
)

;; Two-step ownership handover: the current owner nominates, the nominee
;; accepts. Guards against handing the router to a mistyped principal.
(define-public (transfer-ownership (new-owner principal))
  (begin
    (asserts! (is-eq contract-caller (var-get owner)) ERR_UNAUTHORIZED)
    (var-set pending-owner (some new-owner))
    (print {
      topic: "transfer-ownership",
      pending-owner: new-owner,
    })
    (ok true)
  )
)

(define-public (accept-ownership)
  (let ((new-owner (unwrap! (var-get pending-owner) ERR_NO_PENDING_OWNER)))
    (asserts! (is-eq contract-caller new-owner) ERR_UNAUTHORIZED)
    (var-set owner new-owner)
    (var-set pending-owner none)
    (print {
      topic: "accept-ownership",
      owner: new-owner,
    })
    (ok true)
  )
)

;; read only functions

;; Whether `claim-and-deploy` would pass the router's own checks for `who`.
;; The expected claim and target outcome come from the PoX-5 SDK and the
;; target protocol's read-only functions, not from here.
(define-read-only (preview-claim-and-deploy
    (who principal)
    (source principal)
    (target-name (string-ascii 20))
  )
  (let (
      (target (map-get? targets target-name))
      (source-enabled (is-source-enabled source))
      (target-enabled (default-to false (get enabled target)))
      (router-paused (var-get paused))
    )
    {
      paused: router-paused,
      source-enabled: source-enabled,
      target: target,
      sbtc-balance: (get-sbtc-balance who),
      executable: (and (not router-paused) source-enabled target-enabled),
    }
  )
)

(define-read-only (get-targets)
  (map target-view (var-get target-names))
)

(define-read-only (get-target (target-name (string-ascii 20)))
  (map-get? targets target-name)
)

(define-read-only (is-source-enabled (contract principal))
  (default-to false (map-get? sources contract))
)

(define-read-only (is-paused)
  (var-get paused)
)

(define-read-only (get-owner)
  (var-get owner)
)

(define-read-only (get-pending-owner)
  (var-get pending-owner)
)

;; sbtc-token's `get-balance` is `(ok (ft-get-balance ...))`: it declares no
;; error type and cannot fail.
(define-read-only (get-sbtc-balance (who principal))
  ;; #[allow(panic)]
  (unwrap-panic (contract-call? 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
    get-balance who
  ))
)

;; private functions

;; Claim through `source`, which runs with `staker` as `tx-sender` and so must
;; not be able to move any of the staker's assets.
(define-private (claim-from
    (source <reward-source-trait>)
    (staker principal)
    (reward-cycle uint)
    (bond-index uint)
  )
  (let ((balance-before (get-sbtc-balance staker)))
    (unwrap!
      (restrict-assets? staker ()
        (try! (contract-call? source claim-staker-rewards staker reward-cycle
          (some bond-index)
        ))
      )
      ERR_CLAIM_MOVED_ASSETS
    )
    ;; An L1 BTC payout leaves the sBTC balance unchanged and yields 0 here.
    (ok (- (get-sbtc-balance staker) balance-before))
  )
)

;; Deploy exactly `amount` sBTC through `target`, letting it spend nothing
;; else of the staker's beyond `max-stx` uSTX.
(define-private (deploy-to
    (target <deploy-target-trait>)
    (staker principal)
    (amount uint)
    (min-out uint)
    (max-stx uint)
  )
  (let (
      (balance-before (get-sbtc-balance staker))
      (received (unwrap!
        (restrict-assets? staker (
            (with-ft 'SM3VDXK3WZZSA84XXFKAFAF15NNZX32CTSG82JFQ4.sbtc-token
              "sbtc-token" amount
            )
            (with-stx max-stx)
          )
          (try! (contract-call? target deploy amount min-out))
        )
        ERR_DEPLOY_ALLOWANCE_EXCEEDED
      ))
    )
    (asserts! (is-eq (get-sbtc-balance staker) (- balance-before amount))
      ERR_PARTIAL_DEPLOY
    )
    (ok received)
  )
)

(define-private (assert-contract (who principal))
  (ok (asserts! (is-ok (contract-hash? who)) ERR_NOT_A_CONTRACT))
)

;; Only called with names from `target-names`, each of which `set-target`
;; registered in `targets` at the same time; entries are never deleted.
(define-private (target-view (target-name (string-ascii 20)))
  (merge { name: target-name }
    ;; #[allow(panic)]
    (unwrap-panic (map-get? targets target-name))
  )
)
