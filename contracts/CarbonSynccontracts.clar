;; title: CarbonSync Carbon Credit Marketplace
;; version: 1.0.0
;; summary: IoT-verified carbon offset marketplace with real-time tokenization
;; description: A comprehensive smart contract for carbon credit creation, verification, trading, and ESG tracking

;; traits
(define-trait carbon-credit-trait
  (
    ;; Transfer carbon credits
    (transfer (uint principal principal) (response bool uint))
    ;; Get balance of carbon credits
    (get-balance (principal) (response uint uint))
  )
)

;; token definitions
(define-fungible-token carbon-credit)

;; constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-OWNER-ONLY (err u100))
(define-constant ERR-NOT-TOKEN-OWNER (err u101))
(define-constant ERR-INSUFFICIENT-BALANCE (err u102))
(define-constant ERR-INVALID-AMOUNT (err u103))
(define-constant ERR-INVALID-SENSOR (err u104))
(define-constant ERR-CREDIT-NOT-FOUND (err u105))
(define-constant ERR-CREDIT-ALREADY-RETIRED (err u106))
(define-constant ERR-INSUFFICIENT-VERIFICATION (err u107))
(define-constant ERR-INVALID-PROJECT (err u108))
(define-constant ERR-MARKETPLACE-PAUSED (err u109))
(define-constant ERR-INVALID-PRICE (err u110))
(define-constant ERR-REENTRANCY (err u111))
(define-constant ERR-INVALID-PRINCIPAL (err u112))
(define-constant ERR-UNAUTHORIZED (err u113))
(define-constant ERR-LISTING-NOT-FOUND (err u114))
(define-constant ERR-LISTING-INACTIVE (err u115))

;; Minimum verification threshold (number of sensor readings required)
(define-constant MIN-VERIFICATION-THRESHOLD u10)
(define-constant BIODIVERSITY-MULTIPLIER u150) ;; 1.5x multiplier for biodiversity projects

;; data vars
(define-data-var contract-paused bool false)
(define-data-var next-project-id uint u1)
(define-data-var next-credit-id uint u1)
(define-data-var total-credits-issued uint u0)
(define-data-var total-credits-retired uint u0)
(define-data-var verification-threshold uint MIN-VERIFICATION-THRESHOLD)
(define-data-var reentrancy-guard bool false)
(define-data-var next-listing-id uint u1)

;; data maps
;; Carbon offset projects
(define-map carbon-projects
  { project-id: uint }
  {
    owner: principal,
    name: (string-ascii 64),
    location: (string-ascii 64),
    project-type: (string-ascii 32), ;; "forest", "renewable", "soil", "biodiversity"
    expected-annual-offset: uint, ;; in tons CO2
    verification-sensors: (list 10 (string-ascii 64)),
    biodiversity-score: uint, ;; 0-100 scale
    is-active: bool,
    created-at: uint
  }
)

;; Individual carbon credits
(define-map carbon-credits
  { credit-id: uint }
  {
    project-id: uint,
    owner: principal,
    amount: uint, ;; in tons CO2 equivalent
    creation-timestamp: uint,
    iot-verification-hash: (string-ascii 64),
    verification-count: uint,
    is-retired: bool,
    retirement-timestamp: (optional uint),
    biodiversity-bonus: uint
  }
)

;; IoT sensor data for verification
(define-map sensor-readings
  { sensor-id: (string-ascii 64), timestamp: uint }
  {
    project-id: uint,
    co2-sequestered: uint, ;; in grams
    temperature: int,
    humidity: uint,
    verification-hash: (string-ascii 64),
    is-verified: bool
  }
)

;; Marketplace listings
(define-map marketplace-listings
  { listing-id: uint }
  {
    credit-id: uint,
    seller: principal,
    price-per-ton: uint, ;; in micro-STX
    amount: uint,
    is-active: bool,
    created-at: uint
  }
)

;; Corporate ESG tracking
(define-map corporate-esg
  { company: principal }
  {
    total-credits-purchased: uint,
    total-credits-retired: uint,
    esg-score: uint,
    last-updated: uint
  }
)

;; Project verification status
(define-map project-verifications
  { project-id: uint }
  {
    total-sensor-readings: uint,
    verified-readings: uint,
    last-verification: uint,
    cumulative-co2-offset: uint
  }
)

;; Admin whitelist for emergency functions
(define-map admins
  principal
  bool
)

;; Initialize contract owner as admin
(map-set admins CONTRACT-OWNER true)

;; public functions

;; Emergency pause function
(define-public (pause-contract)
  (begin
    (asserts! (default-to false (map-get? admins tx-sender)) ERR-UNAUTHORIZED)
    (var-set contract-paused true)
    (ok true)
  )
)

(define-public (unpause-contract)
  (begin
    (asserts! (default-to false (map-get? admins tx-sender)) ERR-UNAUTHORIZED)
    (var-set contract-paused false)
    (ok true)
  )
)

(define-public (add-admin (new-admin principal))
  (begin
    (asserts! (is-eq tx-sender CONTRACT-OWNER) ERR-OWNER-ONLY)
    (asserts! (not (is-eq new-admin CONTRACT-OWNER)) ERR-INVALID-PRINCIPAL)
    (map-set admins new-admin true)
    (ok true)
  )
)

;; Register a new carbon offset project
(define-public (register-project 
  (name (string-ascii 64))
  (location (string-ascii 64))
  (project-type (string-ascii 32))
  (expected-annual-offset uint)
  (verification-sensors (list 10 (string-ascii 64)))
  (biodiversity-score uint))
  (let
    ((project-id (var-get next-project-id)))
    (asserts! (not (var-get contract-paused)) ERR-MARKETPLACE-PAUSED)
    (asserts! (> expected-annual-offset u0) ERR-INVALID-AMOUNT)
    (asserts! (<= biodiversity-score u100) ERR-INVALID-AMOUNT)
    
    (map-set carbon-projects
      { project-id: project-id }
      {
        owner: tx-sender,
        name: name,
        location: location,
        project-type: project-type,
        expected-annual-offset: expected-annual-offset,
        verification-sensors: verification-sensors,
        biodiversity-score: biodiversity-score,
        is-active: true,
        created-at: stacks-block-height
      })
    
    (map-set project-verifications
      { project-id: project-id }
      {
        total-sensor-readings: u0,
        verified-readings: u0,
        last-verification: stacks-block-height,
        cumulative-co2-offset: u0
      })
    
    (var-set next-project-id (+ project-id u1))
    (ok project-id)
  )
)

;; Submit IoT sensor reading for verification
(define-public (submit-sensor-reading
  (sensor-id (string-ascii 64))
  (project-id uint)
  (co2-sequestered uint)
  (temperature int)
  (humidity uint)
  (verification-hash (string-ascii 64)))
  (let
    ((project (unwrap! (map-get? carbon-projects { project-id: project-id }) ERR-INVALID-PROJECT))
     (verification (unwrap! (map-get? project-verifications { project-id: project-id }) ERR-INVALID-PROJECT)))
    (asserts! (not (var-get contract-paused)) ERR-MARKETPLACE-PAUSED)
    (asserts! (get is-active project) ERR-INVALID-PROJECT)
    (asserts! (> co2-sequestered u0) ERR-INVALID-AMOUNT)
    
    (map-set sensor-readings
      { sensor-id: sensor-id, timestamp: stacks-block-height }
      {
        project-id: project-id,
        co2-sequestered: co2-sequestered,
        temperature: temperature,
        humidity: humidity,
        verification-hash: verification-hash,
        is-verified: true
      })
    
    (map-set project-verifications
      { project-id: project-id }
      (merge verification {
        total-sensor-readings: (+ (get total-sensor-readings verification) u1),
        verified-readings: (+ (get verified-readings verification) u1),
        last-verification: stacks-block-height,
        cumulative-co2-offset: (+ (get cumulative-co2-offset verification) co2-sequestered)
      }))
    
    (ok true)
  )
)

;; Issue carbon credits based on verified data
(define-public (issue-carbon-credit
  (project-id uint)
  (amount uint))
  (let
    ((project (unwrap! (map-get? carbon-projects { project-id: project-id }) ERR-INVALID-PROJECT))
     (verification (unwrap! (map-get? project-verifications { project-id: project-id }) ERR-INVALID-PROJECT))
     (credit-id (var-get next-credit-id))
     (biodiversity-bonus (if (>= (get biodiversity-score project) u80)
                            (/ (* amount BIODIVERSITY-MULTIPLIER) u100)
                            u0)))
    (asserts! (not (var-get contract-paused)) ERR-MARKETPLACE-PAUSED)
    (asserts! (is-eq tx-sender (get owner project)) ERR-NOT-TOKEN-OWNER)
    (asserts! (get is-active project) ERR-INVALID-PROJECT)
    (asserts! (>= (get verified-readings verification) (var-get verification-threshold)) ERR-INSUFFICIENT-VERIFICATION)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    
    (map-set carbon-credits
      { credit-id: credit-id }
      {
        project-id: project-id,
        owner: tx-sender,
        amount: amount,
        creation-timestamp: stacks-block-height,
        iot-verification-hash: "verified",
        verification-count: (get verified-readings verification),
        is-retired: false,
        retirement-timestamp: none,
        biodiversity-bonus: biodiversity-bonus
      })
    
    (try! (ft-mint? carbon-credit (+ amount biodiversity-bonus) tx-sender))
    (var-set total-credits-issued (+ (var-get total-credits-issued) amount))
    (var-set next-credit-id (+ credit-id u1))
    (ok credit-id)
  )
)

;; Transfer carbon credits
(define-public (transfer-credits (amount uint) (sender principal) (recipient principal))
  (begin
    (asserts! (not (var-get contract-paused)) ERR-MARKETPLACE-PAUSED)
    (asserts! (not (var-get reentrancy-guard)) ERR-REENTRANCY)
    (asserts! (is-eq tx-sender sender) ERR-NOT-TOKEN-OWNER)
    (asserts! (not (is-eq sender recipient)) ERR-INVALID-PRINCIPAL)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (var-set reentrancy-guard true)
    (try! (ft-transfer? carbon-credit amount sender recipient))
    (unwrap-panic (update-corporate-esg-transfer recipient amount))
    (var-set reentrancy-guard false)
    (ok true)
  )
)

;; Create marketplace listing
(define-public (create-listing
  (credit-id uint)
  (price-per-ton uint)
  (amount uint))
  (let
    ((credit (unwrap! (map-get? carbon-credits { credit-id: credit-id }) ERR-CREDIT-NOT-FOUND))
     (listing-id (var-get next-listing-id)))
    (asserts! (not (var-get contract-paused)) ERR-MARKETPLACE-PAUSED)
    (asserts! (is-eq tx-sender (get owner credit)) ERR-NOT-TOKEN-OWNER)
    (asserts! (not (get is-retired credit)) ERR-CREDIT-ALREADY-RETIRED)
    (asserts! (> price-per-ton u0) ERR-INVALID-PRICE)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (<= amount (get amount credit)) ERR-INSUFFICIENT-BALANCE)
    
    (map-set marketplace-listings
      { listing-id: listing-id }
      {
        credit-id: credit-id,
        seller: tx-sender,
        price-per-ton: price-per-ton,
        amount: amount,
        is-active: true,
        created-at: stacks-block-height
      })
    
    (var-set next-listing-id (+ listing-id u1))
    (ok listing-id)
  )
)

;; Purchase carbon credits from marketplace
(define-public (purchase-listing (listing-id uint) (amount uint))
  (let
    ((listing (unwrap! (map-get? marketplace-listings { listing-id: listing-id }) ERR-LISTING-NOT-FOUND))
     (total-price (* (get price-per-ton listing) amount)))
    (asserts! (not (var-get contract-paused)) ERR-MARKETPLACE-PAUSED)
    (asserts! (not (var-get reentrancy-guard)) ERR-REENTRANCY)
    (asserts! (get is-active listing) ERR-LISTING-INACTIVE)
    (asserts! (<= amount (get amount listing)) ERR-INSUFFICIENT-BALANCE)
    (asserts! (not (is-eq tx-sender (get seller listing))) ERR-INVALID-PRINCIPAL)
    (var-set reentrancy-guard true)
    
    ;; Transfer payment
    (try! (stx-transfer? total-price tx-sender (get seller listing)))
    
    ;; Transfer credits
    (try! (ft-transfer? carbon-credit amount (get seller listing) tx-sender))
    
    ;; Update listing
    (if (is-eq amount (get amount listing))
      (map-set marketplace-listings
        { listing-id: listing-id }
        (merge listing { is-active: false, amount: u0 }))
      (map-set marketplace-listings
        { listing-id: listing-id }
        (merge listing { amount: (- (get amount listing) amount) })))
    
    ;; Update ESG tracking
    (unwrap-panic (update-corporate-esg tx-sender amount))
    (var-set reentrancy-guard false)
    (ok true)
  )
)

;; Retire carbon credits
(define-public (retire-credits (credit-id uint) (amount uint))
  (let
    ((credit (unwrap! (map-get? carbon-credits { credit-id: credit-id }) ERR-CREDIT-NOT-FOUND)))
    (asserts! (not (var-get contract-paused)) ERR-MARKETPLACE-PAUSED)
    (asserts! (is-eq tx-sender (get owner credit)) ERR-NOT-TOKEN-OWNER)
    (asserts! (not (get is-retired credit)) ERR-CREDIT-ALREADY-RETIRED)
    (asserts! (> amount u0) ERR-INVALID-AMOUNT)
    (asserts! (<= amount (get amount credit)) ERR-INSUFFICIENT-BALANCE)
    
    ;; Burn the tokens
    (try! (ft-burn? carbon-credit amount tx-sender))
    
    ;; Update credit
    (if (is-eq amount (get amount credit))
      (map-set carbon-credits
        { credit-id: credit-id }
        (merge credit { 
          is-retired: true, 
          retirement-timestamp: (some stacks-block-height),
          amount: u0
        }))
      (map-set carbon-credits
        { credit-id: credit-id }
        (merge credit { amount: (- (get amount credit) amount) })))
    
    ;; Update tracking
    (var-set total-credits-retired (+ (var-get total-credits-retired) amount))
    (unwrap-panic (update-corporate-esg-retirement tx-sender amount))
    (ok true)
  )
)

;; read only functions

;; Get carbon credit balance
(define-read-only (get-balance (account principal))
  (ok (ft-get-balance carbon-credit account)))

;; Get project details
(define-read-only (get-project (project-id uint))
  (map-get? carbon-projects { project-id: project-id }))

;; Get credit details
(define-read-only (get-credit (credit-id uint))
  (map-get? carbon-credits { credit-id: credit-id }))

;; Get marketplace listing
(define-read-only (get-listing (listing-id uint))
  (map-get? marketplace-listings { listing-id: listing-id }))

;; Get project verification status
(define-read-only (get-project-verification (project-id uint))
  (map-get? project-verifications { project-id: project-id }))

;; Get corporate ESG data
(define-read-only (get-corporate-esg (company principal))
  (map-get? corporate-esg { company: company }))

;; Get sensor reading
(define-read-only (get-sensor-reading (sensor-id (string-ascii 64)) (timestamp uint))
  (map-get? sensor-readings { sensor-id: sensor-id, timestamp: timestamp }))

;; Get contract statistics
(define-read-only (get-contract-stats)
  {
    total-credits-issued: (var-get total-credits-issued),
    total-credits-retired: (var-get total-credits-retired),
    total-projects: (- (var-get next-project-id) u1),
    contract-paused: (var-get contract-paused)
  })

;; Calculate ESG score based on carbon activity
(define-read-only (calculate-esg-score (company principal))
  (let
    ((esg-data (default-to 
                 { total-credits-purchased: u0, total-credits-retired: u0, esg-score: u0, last-updated: u0 }
                 (map-get? corporate-esg { company: company }))))
    (if (> (get total-credits-purchased esg-data) u0)
      (if (> (/ (* (get total-credits-retired esg-data) u100) (get total-credits-purchased esg-data)) u100)
        u100
        (/ (* (get total-credits-retired esg-data) u100) (get total-credits-purchased esg-data)))
      u0)))

;; private functions

;; Update corporate ESG tracking for purchases
(define-private (update-corporate-esg (company principal) (amount uint))
  (let
    ((current-esg (default-to 
                   { total-credits-purchased: u0, total-credits-retired: u0, esg-score: u0, last-updated: u0 }
                   (map-get? corporate-esg { company: company }))))
    (map-set corporate-esg
      { company: company }
      (merge current-esg {
        total-credits-purchased: (+ (get total-credits-purchased current-esg) amount),
        last-updated: stacks-block-height,
        esg-score: (calculate-esg-score company)
      }))
    (ok true)))

;; Update corporate ESG tracking for retirements
(define-private (update-corporate-esg-retirement (company principal) (amount uint))
  (let
    ((current-esg (default-to 
                   { total-credits-purchased: u0, total-credits-retired: u0, esg-score: u0, last-updated: u0 }
                   (map-get? corporate-esg { company: company }))))
    (map-set corporate-esg
      { company: company }
      (merge current-esg {
        total-credits-retired: (+ (get total-credits-retired current-esg) amount),
        last-updated: stacks-block-height,
        esg-score: (calculate-esg-score company)
      }))
    (ok true)))

;; Update corporate ESG tracking for transfers
(define-private (update-corporate-esg-transfer (company principal) (amount uint))
  (let
    ((current-esg (default-to 
                   { total-credits-purchased: u0, total-credits-retired: u0, esg-score: u0, last-updated: u0 }
                   (map-get? corporate-esg { company: company }))))
    (map-set corporate-esg
      { company: company }
      (merge current-esg {
        total-credits-purchased: (+ (get total-credits-purchased current-esg) amount),
        last-updated: stacks-block-height,
        esg-score: (calculate-esg-score company)
      }))
    (ok true)))