;; Freelance Escrow Smart Contract
;; Hold payments in escrow until project milestones are completed satisfactorily
;; This contract enables secure freelancer-client transactions with milestone-based payments

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-PROJECT-NOT-FOUND (err u101))
(define-constant ERR-MILESTONE-NOT-FOUND (err u102))
(define-constant ERR-INSUFFICIENT-FUNDS (err u103))
(define-constant ERR-PROJECT-ALREADY-STARTED (err u104))
(define-constant ERR-PROJECT-COMPLETED (err u105))
(define-constant ERR-MILESTONE-ALREADY-COMPLETED (err u106))
(define-constant ERR-DEADLINE-NOT-REACHED (err u107))
(define-constant ERR-DISPUTE-ACTIVE (err u108))
(define-constant ERR-INVALID-RATING (err u109))
(define-constant ERR-ALREADY-RATED (err u110))

;; Project Status
(define-constant STATUS-CREATED u1)
(define-constant STATUS-FUNDED u2)
(define-constant STATUS-IN-PROGRESS u3)
(define-constant STATUS-COMPLETED u4)
(define-constant STATUS-CANCELLED u5)
(define-constant STATUS-DISPUTED u6)

;; Milestone Status
(define-constant MILESTONE-PENDING u1)
(define-constant MILESTONE-SUBMITTED u2)
(define-constant MILESTONE-APPROVED u3)
(define-constant MILESTONE-REJECTED u4)
(define-constant MILESTONE-DISPUTED u5)

;; Platform Configuration
(define-constant PLATFORM-FEE-RATE u250) ;; 2.5% platform fee (250/10000)
(define-constant DISPUTE-TIMEOUT-BLOCKS u1440) ;; ~10 days
(define-constant AUTO-RELEASE-BLOCKS u2160) ;; ~15 days

;; Data Variables
(define-data-var project-counter uint u0)
(define-data-var total-platform-fees uint u0)
(define-data-var contract-paused bool false)

;; Data Maps

;; Projects
(define-map projects
    uint ;; project-id
    {
        client: principal,
        freelancer: principal,
        title: (string-ascii 128),
        description: (string-ascii 512),
        total-amount: uint,
        platform-fee: uint,
        freelancer-amount: uint,
        created-at: uint,
        deadline: uint,
        status: uint,
        milestones-count: uint,
        completed-milestones: uint,
        dispute-raised: bool,
        dispute-timestamp: uint
    }
)

;; Milestones
(define-map milestones
    {project-id: uint, milestone-id: uint}
    {
        title: (string-ascii 64),
        description: (string-ascii 256),
        amount: uint,
        deadline: uint,
        status: uint,
        submitted-at: (optional uint),
        approved-at: (optional uint),
        deliverables-hash: (optional (buff 32))
    }
)

;; User profiles and reputation
(define-map user-profiles
    principal
    {
        total-projects: uint,
        completed-projects: uint,
        total-earned: uint,
        total-spent: uint,
        average-rating: uint, ;; out of 100
        total-ratings: uint,
        is-verified: bool,
        registration-date: uint
    }
)

;; Project ratings
(define-map project-ratings
    {project-id: uint, rater: principal}
    {
        rating: uint, ;; 1-5 scale
        review: (string-ascii 256),
        timestamp: uint
    }
)

;; Dispute records
(define-map disputes
    uint ;; project-id
    {
        raised-by: principal,
        reason: (string-ascii 256),
        evidence-hash: (optional (buff 32)),
        timestamp: uint,
        resolved: bool,
        resolution: (optional (string-ascii 256))
    }
)

;; Skills and categories
(define-map project-skills
    uint ;; project-id
    (list 10 (string-ascii 32)) ;; skills required
)

;; Public Functions

;; Create a new project
(define-public (create-project
    (freelancer principal)
    (title (string-ascii 128))
    (description (string-ascii 512))
    (total-amount uint)
    (deadline-blocks uint)
    (skills (list 10 (string-ascii 32)))
    )
    (let
        (
            (project-id (+ (var-get project-counter) u1))
            (platform-fee (/ (* total-amount PLATFORM-FEE-RATE) u10000))
            (freelancer-amount (- total-amount platform-fee))
        )
        ;; Validate inputs
        (asserts! (not (var-get contract-paused)) ERR-NOT-AUTHORIZED)
        (asserts! (> total-amount u0) ERR-INSUFFICIENT-FUNDS)
        (asserts! (> deadline-blocks u0) ERR-INVALID-RATING)
        
        ;; Create project record
        (map-set projects project-id {
            client: tx-sender,
            freelancer: freelancer,
            title: title,
            description: description,
            total-amount: total-amount,
            platform-fee: platform-fee,
            freelancer-amount: freelancer-amount,
            created-at: stacks-block-height,
            deadline: (+ stacks-block-height deadline-blocks),
            status: STATUS-CREATED,
            milestones-count: u0,
            completed-milestones: u0,
            dispute-raised: false,
            dispute-timestamp: u0
        })
        
        ;; Store project skills
        (map-set project-skills project-id skills)
        
        ;; Update user profiles
        (update-user-profile tx-sender u1 u0 u0 total-amount)
        (update-user-profile freelancer u1 u0 u0 u0)
        
        ;; Update counter
        (var-set project-counter project-id)
        
        (ok project-id)
    )
)

;; Fund project escrow
(define-public (fund-project (project-id uint))
    (let
        (
            (project (unwrap! (map-get? projects project-id) ERR-PROJECT-NOT-FOUND))
        )
        ;; Validate funding conditions
        (asserts! (is-eq tx-sender (get client project)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status project) STATUS-CREATED) ERR-PROJECT-ALREADY-STARTED)
        
        ;; Transfer funds to escrow
        (try! (stx-transfer? (get total-amount project) tx-sender (as-contract tx-sender)))
        
        ;; Update project status
        (map-set projects project-id
            (merge project {status: STATUS-FUNDED})
        )
        
        (ok true)
    )
)

;; Add milestone to project
(define-public (add-milestone
    (project-id uint)
    (milestone-id uint)
    (title (string-ascii 64))
    (description (string-ascii 256))
    (amount uint)
    (deadline-blocks uint)
    )
    (let
        (
            (project (unwrap! (map-get? projects project-id) ERR-PROJECT-NOT-FOUND))
        )
        ;; Validate milestone creation
        (asserts! (or (is-eq tx-sender (get client project)) (is-eq tx-sender (get freelancer project))) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status project) STATUS-FUNDED) ERR-PROJECT-ALREADY-STARTED)
        
        ;; Create milestone
        (map-set milestones {project-id: project-id, milestone-id: milestone-id} {
            title: title,
            description: description,
            amount: amount,
            deadline: (+ stacks-block-height deadline-blocks),
            status: MILESTONE-PENDING,
            submitted-at: none,
            approved-at: none,
            deliverables-hash: none
        })
        
        ;; Update project milestones count
        (map-set projects project-id
            (merge project {
                milestones-count: (+ (get milestones-count project) u1),
                status: STATUS-IN-PROGRESS
            })
        )
        
        (ok true)
    )
)

;; Submit milestone deliverables
(define-public (submit-milestone
    (project-id uint)
    (milestone-id uint)
    (deliverables-hash (buff 32))
    )
    (let
        (
            (project (unwrap! (map-get? projects project-id) ERR-PROJECT-NOT-FOUND))
            (milestone (unwrap! (map-get? milestones {project-id: project-id, milestone-id: milestone-id}) ERR-MILESTONE-NOT-FOUND))
        )
        ;; Validate submission
        (asserts! (is-eq tx-sender (get freelancer project)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status milestone) MILESTONE-PENDING) ERR-MILESTONE-ALREADY-COMPLETED)
        
        ;; Update milestone
        (map-set milestones {project-id: project-id, milestone-id: milestone-id}
            (merge milestone {
                status: MILESTONE-SUBMITTED,
                submitted-at: (some stacks-block-height),
                deliverables-hash: (some deliverables-hash)
            })
        )
        
        (ok true)
    )
)

;; Approve milestone and release payment
(define-public (approve-milestone (project-id uint) (milestone-id uint))
    (let
        (
            (project (unwrap! (map-get? projects project-id) ERR-PROJECT-NOT-FOUND))
            (milestone (unwrap! (map-get? milestones {project-id: project-id, milestone-id: milestone-id}) ERR-MILESTONE-NOT-FOUND))
        )
        ;; Validate approval
        (asserts! (is-eq tx-sender (get client project)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status milestone) MILESTONE-SUBMITTED) ERR-MILESTONE-ALREADY-COMPLETED)
        
        ;; Release payment to freelancer
        (try! (as-contract (stx-transfer? (get amount milestone) tx-sender (get freelancer project))))
        
        ;; Update milestone
        (map-set milestones {project-id: project-id, milestone-id: milestone-id}
            (merge milestone {
                status: MILESTONE-APPROVED,
                approved-at: (some stacks-block-height)
            })
        )
        
        ;; Update project
        (let
            (
                (new-completed (+ (get completed-milestones project) u1))
            )
            (map-set projects project-id
                (merge project {
                    completed-milestones: new-completed,
                    status: (if (is-eq new-completed (get milestones-count project)) STATUS-COMPLETED STATUS-IN-PROGRESS)
                })
            )
        )
        
        (ok true)
    )
)

;; Raise dispute
(define-public (raise-dispute
    (project-id uint)
    (reason (string-ascii 256))
    (evidence-hash (optional (buff 32)))
    )
    (let
        (
            (project (unwrap! (map-get? projects project-id) ERR-PROJECT-NOT-FOUND))
        )
        ;; Validate dispute conditions
        (asserts! (or (is-eq tx-sender (get client project)) (is-eq tx-sender (get freelancer project))) ERR-NOT-AUTHORIZED)
        (asserts! (not (get dispute-raised project)) ERR-DISPUTE-ACTIVE)
        (asserts! (is-eq (get status project) STATUS-IN-PROGRESS) ERR-PROJECT-COMPLETED)
        
        ;; Create dispute record
        (map-set disputes project-id {
            raised-by: tx-sender,
            reason: reason,
            evidence-hash: evidence-hash,
            timestamp: stacks-block-height,
            resolved: false,
            resolution: none
        })
        
        ;; Update project
        (map-set projects project-id
            (merge project {
                status: STATUS-DISPUTED,
                dispute-raised: true,
                dispute-timestamp: stacks-block-height
            })
        )
        
        (ok true)
    )
)

;; Resolve dispute (admin only)
(define-public (resolve-dispute
    (project-id uint)
    (resolution (string-ascii 256))
    (freelancer-payment uint)
    (client-refund uint)
    )
    (let
        (
            (project (unwrap! (map-get? projects project-id) ERR-PROJECT-NOT-FOUND))
            (dispute (unwrap! (map-get? disputes project-id) ERR-DISPUTE-ACTIVE))
        )
        ;; Only admin can resolve disputes
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        (asserts! (not (get resolved dispute)) ERR-DISPUTE-ACTIVE)
        
        ;; Process payments
        (if (> freelancer-payment u0)
            (try! (as-contract (stx-transfer? freelancer-payment tx-sender (get freelancer project))))
            true
        )
        
        (if (> client-refund u0)
            (try! (as-contract (stx-transfer? client-refund tx-sender (get client project))))
            true
        )
        
        ;; Update dispute
        (map-set disputes project-id
            (merge dispute {
                resolved: true,
                resolution: (some resolution)
            })
        )
        
        ;; Update project
        (map-set projects project-id
            (merge project {status: STATUS-COMPLETED})
        )
        
        ;; Collect remaining as platform fee
        (let
            (
                (remaining (- (get total-amount project) freelancer-payment client-refund))
            )
            (var-set total-platform-fees (+ (var-get total-platform-fees) remaining))
        )
        
        (ok true)
    )
)

;; Rate project participant
(define-public (rate-project
    (project-id uint)
    (rating uint)
    (review (string-ascii 256))
    )
    (let
        (
            (project (unwrap! (map-get? projects project-id) ERR-PROJECT-NOT-FOUND))
        )
        ;; Validate rating
        (asserts! (or (is-eq tx-sender (get client project)) (is-eq tx-sender (get freelancer project))) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status project) STATUS-COMPLETED) ERR-PROJECT-COMPLETED)
        (asserts! (and (>= rating u1) (<= rating u5)) ERR-INVALID-RATING)
        (asserts! (is-none (map-get? project-ratings {project-id: project-id, rater: tx-sender})) ERR-ALREADY-RATED)
        
        ;; Store rating
        (map-set project-ratings {project-id: project-id, rater: tx-sender} {
            rating: rating,
            review: review,
            timestamp: stacks-block-height
        })
        
        ;; Update rated user's profile
        (let
            (
                (rated-user (if (is-eq tx-sender (get client project)) (get freelancer project) (get client project)))
            )
            (update-user-rating rated-user rating)
        )
        
        (ok true)
    )
)

;; Emergency withdrawal (admin only)
(define-public (emergency-withdraw (project-id uint))
    (let
        (
            (project (unwrap! (map-get? projects project-id) ERR-PROJECT-NOT-FOUND))
        )
        (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-NOT-AUTHORIZED)
        
        ;; Return funds to client
        (try! (as-contract (stx-transfer? (get freelancer-amount project) tx-sender (get client project))))
        
        ;; Update project status
        (map-set projects project-id
            (merge project {status: STATUS-CANCELLED})
        )
        
        (ok true)
    )
)

;; Read-Only Functions

;; Get project details
(define-read-only (get-project (project-id uint))
    (map-get? projects project-id)
)

;; Get milestone details
(define-read-only (get-milestone (project-id uint) (milestone-id uint))
    (map-get? milestones {project-id: project-id, milestone-id: milestone-id})
)

;; Get user profile
(define-read-only (get-user-profile (user principal))
    (map-get? user-profiles user)
)

;; Get project rating
(define-read-only (get-project-rating (project-id uint) (rater principal))
    (map-get? project-ratings {project-id: project-id, rater: rater})
)

;; Get dispute details
(define-read-only (get-dispute (project-id uint))
    (map-get? disputes project-id)
)

;; Get project skills
(define-read-only (get-project-skills (project-id uint))
    (map-get? project-skills project-id)
)

;; Get contract statistics
(define-read-only (get-contract-stats)
    {
        total-projects: (var-get project-counter),
        total-platform-fees: (var-get total-platform-fees),
        contract-paused: (var-get contract-paused)
    }
)

;; Check if milestone deadline passed
(define-read-only (is-milestone-overdue (project-id uint) (milestone-id uint))
    (match (map-get? milestones {project-id: project-id, milestone-id: milestone-id})
        milestone (> stacks-block-height (get deadline milestone))
        false
    )
)

;; Private Functions

;; Update user profile
(define-private (update-user-profile (user principal) (projects-delta uint) (completed-delta uint) (earned-delta uint) (spent-delta uint))
    (let
        (
            (profile (default-to {
                total-projects: u0,
                completed-projects: u0,
                total-earned: u0,
                total-spent: u0,
                average-rating: u0,
                total-ratings: u0,
                is-verified: false,
                registration-date: stacks-block-height
            } (map-get? user-profiles user)))
        )
        (map-set user-profiles user
            (merge profile {
                total-projects: (+ (get total-projects profile) projects-delta),
                completed-projects: (+ (get completed-projects profile) completed-delta),
                total-earned: (+ (get total-earned profile) earned-delta),
                total-spent: (+ (get total-spent profile) spent-delta)
            })
        )
    )
)

;; Update user rating
(define-private (update-user-rating (user principal) (new-rating uint))
    (let
        (
            (profile (unwrap-panic (map-get? user-profiles user)))
            (current-total (get total-ratings profile))
            (current-avg (get average-rating profile))
            (new-total (+ current-total u1))
            (rating-points (* new-rating u20)) ;; Convert 1-5 to 20-100 scale
            (new-avg (/ (+ (* current-avg current-total) rating-points) new-total))
        )
        (map-set user-profiles user
            (merge profile {
                average-rating: new-avg,
                total-ratings: new-total
            })
        )
    )
)

