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
        last-updated: u0,
        esg-score: (calculate-esg-score company)
      }))
    true))

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
        last-updated: u0,
        esg-score: (calculate-esg-score company)
      }))
    true))