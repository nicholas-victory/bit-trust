;; Title: BitTrust Protocol - Intelligent Credit-Based Lending Platform
;;
;; Summary: A revolutionary Bitcoin-native lending ecosystem that transforms 
;; creditworthiness into collateral efficiency through adaptive algorithms
;;
;; Description:
;; BitTrust Protocol introduces a paradigm shift in decentralized finance by creating
;; a self-evolving credit infrastructure built specifically for Bitcoin's Layer 2.
;; Our intelligent scoring mechanism rewards financial responsibility with reduced
;; collateral requirements and premium interest rates. Users begin their journey
;; with standard terms and progressively unlock elite borrowing privileges through
;; consistent repayment behavior. The protocol features dynamic risk assessment,
;; partial collateralization for qualified borrowers, and seamless integration
;; with the Stacks blockchain's Bitcoin-anchored security model.
;;
;; Key Innovation: Traditional DeFi requires 100%+ collateral. BitTrust enables
;; creditworthy users to borrow with as little as 50% collateral, democratizing
;; access to capital while maintaining protocol security through behavioral economics.

;; PROTOCOL CONSTANTS & ERROR DEFINITIONS

(define-constant CONTRACT-OWNER tx-sender)

;; Error codes for comprehensive debugging
(define-constant ERR-UNAUTHORIZED (err u1))
(define-constant ERR-INSUFFICIENT-BALANCE (err u2))
(define-constant ERR-INVALID-AMOUNT (err u3))
(define-constant ERR-LOAN-NOT-FOUND (err u4))
(define-constant ERR-LOAN-DEFAULTED (err u5))
(define-constant ERR-INSUFFICIENT-SCORE (err u6))
(define-constant ERR-ACTIVE-LOAN (err u7))
(define-constant ERR-NOT-DUE (err u8))
(define-constant ERR-INVALID-DURATION (err u9))
(define-constant ERR-INVALID-LOAN-ID (err u10))

;; Credit scoring parameters
(define-constant MIN-SCORE u50)
(define-constant MAX-SCORE u100)
(define-constant MIN-LOAN-SCORE u70)

;; DATA STRUCTURES & STORAGE MAPS

;; User credit profiles with comprehensive tracking
(define-map UserScores
  { user: principal }
  {
    score: uint,
    total-borrowed: uint,
    total-repaid: uint,
    loans-taken: uint,
    loans-repaid: uint,
    last-update: uint,
  }
)

;; Comprehensive loan tracking structure
(define-map Loans
  { loan-id: uint }
  {
    borrower: principal,
    amount: uint,
    collateral: uint,
    due-height: uint,
    interest-rate: uint,
    is-active: bool,
    is-defaulted: bool,
    repaid-amount: uint,
  }
)

;; User loan portfolio management
(define-map UserLoans
  { user: principal }
  { active-loans: (list 20 uint) }
)

;; GLOBAL PROTOCOL VARIABLES

(define-data-var next-loan-id uint u0)
(define-data-var total-stx-locked uint u0)

;; CORE PUBLIC FUNCTIONS

;; Initialize credit journey for new users
;; Creates baseline credit profile required for protocol participation
(define-public (initialize-score)
  (let ((sender tx-sender))
    (asserts! (is-none (map-get? UserScores { user: sender })) ERR-UNAUTHORIZED)
    (ok (map-set UserScores { user: sender } {
      score: MIN-SCORE,
      total-borrowed: u0,
      total-repaid: u0,
      loans-taken: u0,
      loans-repaid: u0,
      last-update: stacks-block-height,
    }))
  )
)

;; Request new loan with intelligent collateral calculation
;; Parameters: loan amount, collateral offered, loan duration in blocks
;; Returns: unique loan identifier for tracking
(define-public (request-loan
    (amount uint)
    (collateral uint)
    (duration uint)
  )
  (let (
      (sender tx-sender)
      (loan-id (+ (var-get next-loan-id) u1))
      (user-score (unwrap! (map-get? UserScores { user: sender }) ERR-UNAUTHORIZED))
      (active-loans (default-to { active-loans: (list) } (map-get? UserLoans { user: sender })))
    )
    ;; Comprehensive eligibility validation
    (asserts! (>= (get score user-score) MIN-LOAN-SCORE) ERR-INSUFFICIENT-SCORE)
    (asserts! (<= (len (get active-loans active-loans)) u5) ERR-ACTIVE-LOAN)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (and (> duration u0) (<= duration u52560)) ERR-INVALID-DURATION)
    ;; Max ~1 year
    ;; Adaptive collateral requirement based on creditworthiness
    (let ((required-collateral (calculate-required-collateral amount (get score user-score))))
      (asserts! (>= collateral required-collateral) ERR-INSUFFICIENT-BALANCE)
      ;; Secure collateral escrow
      (try! (stx-transfer? collateral sender (as-contract tx-sender)))
      ;; Create comprehensive loan record
      (map-set Loans { loan-id: loan-id } {
        borrower: sender,
        amount: amount,
        collateral: collateral,
        due-height: (+ stacks-block-height duration),
        interest-rate: (calculate-interest-rate (get score user-score)),
        is-active: true,
        is-defaulted: false,
        repaid-amount: u0,
      })
      ;; Update user's loan portfolio
      (try! (update-user-loans sender loan-id))
      ;; Execute loan disbursement
      (as-contract (try! (stx-transfer? amount tx-sender sender)))
      ;; Update protocol metrics
      (var-set next-loan-id loan-id)
      (var-set total-stx-locked (+ (var-get total-stx-locked) collateral))
      (ok loan-id)
    )
  )
)

;; Process loan repayment with credit scoring updates
;; Supports partial payments and automatic collateral release
(define-public (repay-loan
    (loan-id uint)
    (amount uint)
  )
  (let (
      (sender tx-sender)
      (loan (unwrap! (map-get? Loans { loan-id: loan-id }) ERR-LOAN-NOT-FOUND))
    )
    ;; Authorization and status validation
    (asserts! (is-eq sender (get borrower loan)) ERR-UNAUTHORIZED)
    (asserts! (get is-active loan) ERR-LOAN-NOT-FOUND)
    (asserts! (not (get is-defaulted loan)) ERR-LOAN-DEFAULTED)
    (asserts! (<= loan-id (var-get next-loan-id)) ERR-INVALID-LOAN-ID)
    ;; Calculate total obligation including interest
    (let ((total-due (calculate-total-due loan)))
      (asserts! (>= amount u0) ERR-INVALID-AMOUNT)
      ;; Process repayment transfer
      (try! (stx-transfer? amount sender (as-contract tx-sender)))
      ;; Update loan repayment status
      (let ((new-repaid-amount (+ (get repaid-amount loan) amount)))
        (map-set Loans { loan-id: loan-id }
          (merge loan {
            repaid-amount: new-repaid-amount,
            is-active: (< new-repaid-amount total-due),
          })
        )
        ;; Handle complete loan settlement
        (if (>= new-repaid-amount total-due)
          (begin
            (try! (update-credit-score sender true loan))
            (as-contract (try! (stx-transfer? (get collateral loan) tx-sender sender)))
            (var-set total-stx-locked
              (- (var-get total-stx-locked) (get collateral loan))
            )
          )
          true
        )
        (ok true)
      )
    )
  )
)

;; INTELLIGENT CALCULATION FUNCTIONS

;; Dynamic collateral calculation based on credit excellence
;; Higher credit scores unlock reduced collateral requirements
(define-private (calculate-required-collateral
    (amount uint)
    (score uint)
  )
  (let ((collateral-ratio (- u100 (/ (* score u50) u100))))
    (/ (* amount collateral-ratio) u100)
  )
)

;; Credit-based interest rate optimization
;; Rewards creditworthy borrowers with premium rates
(define-private (calculate-interest-rate (score uint))
  (let ((base-rate u10))
    (- base-rate (/ (* score u5) u100))
  )
)

;; Comprehensive debt calculation including accrued interest
(define-private (calculate-total-due (loan {
  borrower: principal,
  amount: uint,
  collateral: uint,
  due-height: uint,
  interest-rate: uint,
  is-active: bool,
  is-defaulted: bool,
  repaid-amount: uint,
}))
  (let ((interest (* (get amount loan) (get interest-rate loan))))
    (+ (get amount loan) (/ interest u100))
  )
)

;; Adaptive credit scoring algorithm
;; Rewards successful repayments, penalizes defaults
(define-private (update-credit-score
    (user principal)
    (success bool)
    (loan {
      borrower: principal,
      amount: uint,
      collateral: uint,
      due-height: uint,
      interest-rate: uint,
      is-active: bool,
      is-defaulted: bool,
      repaid-amount: uint,
    })
  )
  (let (
      (current-score (unwrap! (map-get? UserScores { user: user }) ERR-UNAUTHORIZED))
      (new-score (if success
        (if (<= (+ (get score current-score) u2) MAX-SCORE)
          (+ (get score current-score) u2)
          MAX-SCORE
        )
        (if (>= (- (get score current-score) u10) MIN-SCORE)
          (- (get score current-score) u10)
          MIN-SCORE
        )
      ))
    )
    ;; Update comprehensive user profile
    (if success
      (map-set UserScores { user: user }
        (merge current-score {
          score: new-score,
          total-repaid: (+ (get total-repaid current-score) (get amount loan)),
          loans-repaid: (+ (get loans-repaid current-score) u1),
          last-update: stacks-block-height,
        })
      )
      (map-set UserScores { user: user }
        (merge current-score {
          score: new-score,
          last-update: stacks-block-height,
        })
      )
    )
    (ok true)
  )
)

;; Portfolio management for active loan tracking
(define-private (update-user-loans
    (user principal)
    (loan-id uint)
  )
  (let ((user-loans (default-to { active-loans: (list) } (map-get? UserLoans { user: user }))))
    (map-set UserLoans { user: user } { active-loans: (unwrap! (as-max-len? (append (get active-loans user-loans) loan-id) u20)
      ERR-ACTIVE-LOAN
    ) }
    )
    (ok true)
  )
)

;; PUBLIC READ-ONLY FUNCTIONS

;; Retrieve comprehensive user credit profile
(define-read-only (get-user-score (user principal))
  (map-get? UserScores { user: user })
)

;; Access detailed loan information
(define-read-only (get-loan (loan-id uint))
  (map-get? Loans { loan-id: loan-id })
)

;; View user's active loan portfolio
(define-read-only (get-user-active-loans (user principal))
  (map-get? UserLoans { user: user })
)

;; ADMINISTRATIVE FUNCTIONS

;; Default management for overdue loans
;; Maintains protocol security through automated risk management
(define-public (mark-loan-defaulted (loan-id uint))
  (let ((loan (unwrap! (map-get? Loans { loan-id: loan-id }) ERR-LOAN-NOT-FOUND)))
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-UNAUTHORIZED)
    (asserts! (>= stacks-block-height (get due-height loan)) ERR-NOT-DUE)
    (asserts! (get is-active loan) ERR-LOAN-NOT-FOUND)
    (asserts! (<= loan-id (var-get next-loan-id)) ERR-INVALID-LOAN-ID)
    ;; Execute default procedures
    (map-set Loans { loan-id: loan-id }
      (merge loan {
        is-defaulted: true,
        is-active: false,
      })
    )
    ;; Apply credit score penalty
    (try! (update-credit-score (get borrower loan) false loan))
    (ok true)
  )
)