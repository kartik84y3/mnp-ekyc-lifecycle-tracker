-- ============================================================================
-- PROJECT: MNP (Mobile Number Portability) & eKYC Lifecycle Tracker
-- ENVIRONMENT: MySQL Workbench 8.0+
-- ============================================================================

DROP DATABASE IF EXISTS telecom_mnp_tracker;
CREATE DATABASE telecom_mnp_tracker;
USE telecom_mnp_tracker;

-- Enable MySQL Event Scheduler for automatic UPC expiration
SET GLOBAL event_scheduler = ON;

-- ============================================================================
-- 1. TABLE DEFINITIONS (3NF Normalized Schema)
-- ============================================================================

-- 1.1 Telecom Circles (LSAs - Licensed Service Areas)
CREATE TABLE Telecom_Circles (
    circle_id INT AUTO_INCREMENT PRIMARY KEY,
    circle_code VARCHAR(10) NOT NULL UNIQUE,
    circle_name VARCHAR(50) NOT NULL,
    mnp_zone ENUM('Zone 1 (North/West)', 'Zone 2 (South/East)') NOT NULL,
    upc_validity_days INT NOT NULL DEFAULT 4 COMMENT '4 days standard; 30 days for J&K, Assam, NE'
);

-- 1.2 Telecom Operators (Access Service Providers)
CREATE TABLE Operators (
    operator_id INT AUTO_INCREMENT PRIMARY KEY,
    operator_code VARCHAR(10) NOT NULL UNIQUE,
    operator_name VARCHAR(50) NOT NULL,
    network_type VARCHAR(20) DEFAULT '4G/5G'
);

-- 1.3 Subscribers (Master Customer & SIM State)
CREATE TABLE Subscribers (
    subscriber_id INT AUTO_INCREMENT PRIMARY KEY,
    mobile_number CHAR(10) NOT NULL UNIQUE,
    full_name VARCHAR(100) NOT NULL,
    current_operator_id INT NOT NULL,
    circle_id INT NOT NULL,
    connection_type ENUM('Prepaid', 'Postpaid') NOT NULL,
    activation_date DATE NOT NULL COMMENT 'Must be >= 90 days for MNP',
    last_sim_swap_date DATE DEFAULT NULL COMMENT 'DoT Rule: Must be >= 7 days before MNP',
    is_sub_judice BOOLEAN DEFAULT FALSE COMMENT 'True if number is blocked by legal/court order',
    sim_status ENUM('ACTIVE', 'CUTOVER_IN_PROGRESS', 'SUSPENDED') DEFAULT 'ACTIVE',
    CONSTRAINT fk_sub_operator FOREIGN KEY (current_operator_id) REFERENCES Operators(operator_id),
    CONSTRAINT fk_sub_circle FOREIGN KEY (circle_id) REFERENCES Telecom_Circles(circle_id),
    INDEX idx_mobile (mobile_number)
);

-- 1.4 eKYC Records (Aadhaar / DigiLocker Verification)
CREATE TABLE eKYC_Records (
    kyc_id INT AUTO_INCREMENT PRIMARY KEY,
    subscriber_id INT NOT NULL,
    aadhaar_last_4 CHAR(4) NOT NULL,
    digilocker_doc_hash VARCHAR(64) NOT NULL UNIQUE,
    biometric_verified BOOLEAN DEFAULT FALSE,
    demographic_name_match BOOLEAN DEFAULT FALSE COMMENT 'Matches Donor Name vs eKYC Name',
    pos_agent_code VARCHAR(20) NOT NULL,
    verified_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT fk_kyc_sub FOREIGN KEY (subscriber_id) REFERENCES Subscribers(subscriber_id)
);

-- 1.5 Billing Clearance (Donor Operator Financial Holds)
CREATE TABLE Billing_Clearance (
    clearance_id INT AUTO_INCREMENT PRIMARY KEY,
    subscriber_id INT NOT NULL UNIQUE,
    donor_operator_id INT NOT NULL,
    outstanding_dues DECIMAL(10, 2) DEFAULT 0.00,
    unbilled_usage DECIMAL(10, 2) DEFAULT 0.00,
    clearance_status ENUM('CLEARED', 'HOLD_UNPAID_DUES', 'WAIVED') DEFAULT 'CLEARED',
    last_updated DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP,
    CONSTRAINT fk_bill_sub FOREIGN KEY (subscriber_id) REFERENCES Subscribers(subscriber_id),
    CONSTRAINT fk_bill_donor FOREIGN KEY (donor_operator_id) REFERENCES Operators(operator_id)
);

-- 1.6 UPC Tokens (Unique Porting Codes generated via 1900)
CREATE TABLE UPC_Tokens (
    upc_code CHAR(8) PRIMARY KEY COMMENT '2-char Operator/Circle prefix + 6-digit random',
    subscriber_id INT NOT NULL,
    generated_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    expires_at DATETIME NULL,
    upc_status ENUM('ACTIVE', 'USED', 'EXPIRED', 'CANCELLED') DEFAULT 'ACTIVE',
    CONSTRAINT fk_upc_sub FOREIGN KEY (subscriber_id) REFERENCES Subscribers(subscriber_id)
);

-- 1.7 Porting Requests (Core MNP Lifecycle Tracker)
CREATE TABLE Porting_Requests (
    request_id INT AUTO_INCREMENT PRIMARY KEY,
    upc_code CHAR(8) NOT NULL UNIQUE,
    subscriber_id INT NOT NULL,
    donor_operator_id INT NOT NULL,
    recipient_operator_id INT NOT NULL,
    kyc_id INT NOT NULL,
    port_type ENUM('Intra-Circle', 'Inter-Circle') NOT NULL,
    porting_fee DECIMAL(5, 2) DEFAULT 6.46 COMMENT 'TRAI regulated MNP fee in INR',
    request_status ENUM('SUBMITTED', 'KYC_VERIFIED', 'SCHEDULED_FOR_CUTOVER', 'COMPLETED', 'REJECTED', 'WITHDRAWN') DEFAULT 'SUBMITTED',
    rejection_reason VARCHAR(255) DEFAULT NULL,
    requested_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    scheduled_cutover_time DATETIME DEFAULT NULL,
    completed_at DATETIME DEFAULT NULL,
    CONSTRAINT fk_req_upc FOREIGN KEY (upc_code) REFERENCES UPC_Tokens(upc_code),
    CONSTRAINT fk_req_sub FOREIGN KEY (subscriber_id) REFERENCES Subscribers(subscriber_id),
    CONSTRAINT fk_req_donor FOREIGN KEY (donor_operator_id) REFERENCES Operators(operator_id),
    CONSTRAINT fk_req_recipient FOREIGN KEY (recipient_operator_id) REFERENCES Operators(operator_id),
    CONSTRAINT fk_req_kyc FOREIGN KEY (kyc_id) REFERENCES eKYC_Records(kyc_id)
);

-- 1.8 Audit Logs (Tracks every state change for compliance)
CREATE TABLE MNP_Audit_Logs (
    log_id INT AUTO_INCREMENT PRIMARY KEY,
    subscriber_id INT NOT NULL,
    action_type VARCHAR(50) NOT NULL,
    action_details VARCHAR(255) NOT NULL,
    logged_at DATETIME DEFAULT CURRENT_TIMESTAMP
);

-- ============================================================================
-- 2. TRIGGERS (SIP: Zero-Rejection Pre-Check Gate & Dynamic Circle TTL)
-- ============================================================================

DELIMITER $$

-- Trigger 2.1: Pre-Check Eligibility & Auto-Calculate Circle Expiry (4 vs 30 days)
CREATE TRIGGER trg_Before_UPC_Insert
BEFORE INSERT ON UPC_Tokens
FOR EACH ROW
BEGIN
    DECLARE v_activation_date DATE;
    DECLARE v_sim_swap_date DATE;
    DECLARE v_is_sub_judice BOOLEAN;
    DECLARE v_conn_type VARCHAR(20);
    DECLARE v_dues DECIMAL(10,2);
    DECLARE v_validity_days INT;

    -- Fetch Subscriber & Circle details
    SELECT s.activation_date, s.last_sim_swap_date, s.is_sub_judice, s.connection_type, c.upc_validity_days
    INTO v_activation_date, v_sim_swap_date, v_is_sub_judice, v_conn_type, v_validity_days
    FROM Subscribers s
    JOIN Telecom_Circles c ON s.circle_id = c.circle_id
    WHERE s.subscriber_id = NEW.subscriber_id;

    -- Check 1: Court/Legal Hold
    IF v_is_sub_judice = TRUE THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'TRAI Rejection: Mobile number is under legal/sub-judice prohibition.';
    END IF;

    -- Check 2: 90-Day Network Age Rule
    IF DATEDIFF(CURDATE(), v_activation_date) < 90 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'TRAI Rejection: Subscriber has not completed 90 days on the current operator network.';
    END IF;

    -- Check 3: DoT 7-Day SIM Swap Cooling-Off Rule
    IF v_sim_swap_date IS NOT NULL AND DATEDIFF(CURDATE(), v_sim_swap_date) < 7 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'DoT Security Block: 7-day cooling period after SIM swap is still active.';
    END IF;

    -- Check 4: Postpaid Outstanding Dues Clearance
    IF v_conn_type = 'Postpaid' THEN
        SELECT outstanding_dues INTO v_dues
        FROM Billing_Clearance
        WHERE subscriber_id = NEW.subscriber_id;

        IF v_dues > 0.00 THEN
            SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Donor Rejection: Postpaid subscriber has unpaid billed dues.';
        END IF;
    END IF;

    -- Dynamic Circle TTL Assignment (4 Days Standard, 30 Days J&K/NE/Assam)
    IF NEW.generated_at IS NULL THEN
        SET NEW.generated_at = NOW();
    END IF;
    SET NEW.expires_at = DATE_ADD(NEW.generated_at, INTERVAL v_validity_days DAY);
END$$

-- Trigger 2.2: Validate eKYC & UPC Status Before Creating a Porting Request
CREATE TRIGGER trg_Before_PortRequest_Insert
BEFORE INSERT ON Porting_Requests
FOR EACH ROW
BEGIN
    DECLARE v_upc_status VARCHAR(20);
    DECLARE v_upc_expiry DATETIME;
    DECLARE v_biometric BOOLEAN;
    DECLARE v_name_match BOOLEAN;

    -- Check UPC Status & Expiry
    SELECT upc_status, expires_at INTO v_upc_status, v_upc_expiry
    FROM UPC_Tokens WHERE upc_code = NEW.upc_code;

    IF v_upc_status != 'ACTIVE' OR NOW() > v_upc_expiry THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'MNP Error: Provided UPC code is expired, already used, or cancelled.';
    END IF;

    -- Check eKYC Biometric & Demographic Match
    SELECT biometric_verified, demographic_name_match INTO v_biometric, v_name_match
    FROM eKYC_Records WHERE kyc_id = NEW.kyc_id;

    IF v_biometric = FALSE OR v_name_match = FALSE THEN
        SET NEW.request_status = 'REJECTED';
        SET NEW.rejection_reason = 'eKYC Verification Failed: Biometric or Demographic Name Mismatch';
    ELSE
        SET NEW.request_status = 'SCHEDULED_FOR_CUTOVER';
        -- Schedule night cutover window: 3 days for Intra-Circle, 5 days for Inter-Circle
        IF NEW.port_type = 'Intra-Circle' THEN
            SET NEW.scheduled_cutover_time = DATE_ADD(NOW(), INTERVAL 3 DAY);
        ELSE
            SET NEW.scheduled_cutover_time = DATE_ADD(NOW(), INTERVAL 5 DAY);
        END IF;
    END IF;
END$$

DELIMITER ;

-- ============================================================================
-- 3. STORED PROCEDURES (SIP: Atomic Night-Window Cutover & 24h Withdrawal)
-- ============================================================================

DELIMITER $$

-- Procedure 3.1: Atomic Night-Window SIM Cutover (Prevents "No Service" Blackhole)
CREATE PROCEDURE sp_ExecuteAtomicCutover(IN p_request_id INT)
BEGIN
    DECLARE v_sub_id INT;
    DECLARE v_recipient_op INT;
    DECLARE v_donor_op INT;
    DECLARE v_upc CHAR(8);
    DECLARE v_req_status VARCHAR(30);

    -- Rollback everything if any SQL error occurs mid-cutover
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT subscriber_id, donor_operator_id, recipient_operator_id, upc_code, request_status
    INTO v_sub_id, v_donor_op, v_recipient_op, v_upc, v_req_status
    FROM Porting_Requests
    WHERE request_id = p_request_id
    FOR UPDATE;

    IF v_req_status != 'SCHEDULED_FOR_CUTOVER' THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'Cutover Aborted: Request is not in SCHEDULED_FOR_CUTOVER state.';
    END IF;

    -- Step 1: Switch Operator in Master Subscribers Table & Reset Activation Date
    UPDATE Subscribers
    SET current_operator_id = v_recipient_op,
        activation_date = CURDATE(),
        sim_status = 'ACTIVE'
    WHERE subscriber_id = v_sub_id;

    -- Step 2: Mark UPC Token as USED
    UPDATE UPC_Tokens
    SET upc_status = 'USED'
    WHERE upc_code = v_upc;

    -- Step 3: Mark Porting Request as COMPLETED
    UPDATE Porting_Requests
    SET request_status = 'COMPLETED',
        completed_at = NOW()
    WHERE request_id = p_request_id;

    -- Step 4: Write Compliance Audit Log
    INSERT INTO MNP_Audit_Logs (subscriber_id, action_type, action_details)
    VALUES (v_sub_id, 'ATOMIC_CUTOVER_SUCCESS',
            CONCAT('Ported from Operator ID ', v_donor_op, ' to Operator ID ', v_recipient_op, ' using UPC ', v_upc));

    COMMIT;
END$$

-- Procedure 3.2: Customer Porting Withdrawal (Allowed within 24 Hours of Request)
CREATE PROCEDURE sp_WithdrawPortRequest(IN p_request_id INT)
BEGIN
    DECLARE v_req_time DATETIME;
    DECLARE v_upc CHAR(8);
    DECLARE v_sub_id INT;

    SELECT requested_at, upc_code, subscriber_id
    INTO v_req_time, v_upc, v_sub_id
    FROM Porting_Requests WHERE request_id = p_request_id;

    IF TIMESTAMPDIFF(HOUR, v_req_time, NOW()) > 24 THEN
        SIGNAL SQLSTATE '45000'
        SET MESSAGE_TEXT = 'TRAI Rule Violation: Cancellation window (24 hours) has already passed.';
    ELSE
        UPDATE Porting_Requests SET request_status = 'WITHDRAWN' WHERE request_id = p_request_id;
        UPDATE UPC_Tokens SET upc_status = 'CANCELLED' WHERE upc_code = v_upc;
        INSERT INTO MNP_Audit_Logs (subscriber_id, action_type, action_details)
        VALUES (v_sub_id, 'PORT_WITHDRAWN', CONCAT('Request ', p_request_id, ' withdrawn within 24h window.'));
    END IF;
END$$

DELIMITER ;

-- ============================================================================
-- 4. SCHEDULED EVENT (Hourly Auto-Cleanup of Expired UPCs)
-- ============================================================================

CREATE EVENT IF NOT EXISTS ev_AutoExpireUPCs
ON SCHEDULE EVERY 1 HOUR
DO
    UPDATE UPC_Tokens
    SET upc_status = 'EXPIRED'
    WHERE upc_status = 'ACTIVE' AND expires_at < NOW();

-- ============================================================================
-- 5. SAMPLE DATA INSERTION (Indian Telecom Scenarios)
-- ============================================================================

-- 5.1 Insert Telecom Circles
INSERT INTO Telecom_Circles (circle_code, circle_name, mnp_zone, upc_validity_days) VALUES
('UPW', 'UP West & Uttarakhand', 'Zone 1 (North/West)', 4),
('PB',  'Punjab',                'Zone 1 (North/West)', 4),
('DL',  'Delhi NCR',             'Zone 1 (North/West)', 4),
('JK',  'Jammu & Kashmir',       'Zone 1 (North/West)', 30),
('KA',  'Karnataka',             'Zone 2 (South/East)', 4);

-- 5.2 Insert Operators
INSERT INTO Operators (operator_code, operator_name, network_type) VALUES
('JIO',  'Reliance Jio Infocomm', '5G/4G'),
('AIR',  'Bharti Airtel',         '5G/4G'),
('VI',   'Vodafone Idea (Vi)',    '4G'),
('BSNL', 'BSNL Mobile',           '4G/3G');

-- 5.3 Insert Subscribers (Covering Valid, Unpaid Dues, <90 Days, and Recent SIM Swap cases)
INSERT INTO Subscribers (mobile_number, full_name, current_operator_id, circle_id, connection_type, activation_date, last_sim_swap_date, is_sub_judice) VALUES
('9876543210', 'Aarav Sharma',   3, 1, 'Prepaid',  '2024-01-15', NULL,         FALSE), -- Eligible (Vi, UPW)
('9811223344', 'Priya Verma',    2, 2, 'Postpaid', '2023-06-10', '2026-01-10', FALSE), -- Eligible Postpaid (Airtel, Punjab)
('9988776655', 'Rohan Mehta',    1, 4, 'Prepaid',  '2025-05-20', NULL,         FALSE), -- Eligible J&K (30-day UPC validity)
('9123456780', 'Vikram Singh',   2, 3, 'Postpaid', '2024-03-01', NULL,         FALSE), -- Ineligible: Has Unpaid Postpaid Dues
('9001122334', 'Neha Gupta',     3, 1, 'Prepaid',  DATE_SUB(CURDATE(), INTERVAL 30 DAY), NULL, FALSE), -- Ineligible: <90 Days on network
('9776655443', 'Kabir Das',      1, 2, 'Prepaid',  '2023-11-11', DATE_SUB(CURDATE(), INTERVAL 2 DAY), FALSE); -- Ineligible: SIM Swapped 2 days ago

-- 5.4 Insert Billing Clearance Records
INSERT INTO Billing_Clearance (subscriber_id, donor_operator_id, outstanding_dues, unbilled_usage, clearance_status) VALUES
(1, 3, 0.00,   0.00,   'CLEARED'),
(2, 2, 0.00,   145.50, 'CLEARED'),
(3, 1, 0.00,   0.00,   'CLEARED'),
(4, 2, 849.00, 210.00, 'HOLD_UNPAID_DUES'), -- Blocks subscriber 4 from generating UPC
(5, 3, 0.00,   0.00,   'CLEARED'),
(6, 1, 0.00,   0.00,   'CLEARED');

-- 5.5 Insert eKYC Verification Records
INSERT INTO eKYC_Records (subscriber_id, aadhaar_last_4, digilocker_doc_hash, biometric_verified, demographic_name_match, pos_agent_code) VALUES
(1, '4821', SHA2('DOC_AARAV_2026', 256), TRUE,  TRUE,  'POS_UPW_101'), -- Valid eKYC
(2, '9012', SHA2('DOC_PRIYA_2026', 256), TRUE,  TRUE,  'POS_PB_204'),  -- Valid eKYC
(3, '3349', SHA2('DOC_ROHAN_2026', 256), TRUE,  FALSE, 'POS_JK_019');  -- Demographic Name Mismatch!

-- 5.6 Generate UPC Tokens for Eligible Subscribers (Trigger automatically calculates expires_at)
INSERT INTO UPC_Tokens (upc_code, subscriber_id) VALUES
('VU884920', 1), -- Gets 4-day expiry (UP West)
('AP773819', 2), -- Gets 4-day expiry (Punjab)
('JJ992011', 3); -- Gets 30-day expiry (Jammu & Kashmir)

-- 5.7 Create Porting Requests
INSERT INTO Porting_Requests (upc_code, subscriber_id, donor_operator_id, recipient_operator_id, kyc_id, port_type) VALUES
('VU884920', 1, 3, 1, 1, 'Intra-Circle'), -- Vi to Jio (Auto-scheduled for cutover)
('AP773819', 2, 2, 1, 2, 'Intra-Circle'), -- Airtel to Jio (Auto-scheduled for cutover)
('JJ992011', 3, 1, 2, 3, 'Inter-Circle'); -- Jio to Airtel (Auto-REJECTED by Trigger due to Name Mismatch)

-- 5.8 Execute Atomic Night Cutover for Request #1 (Aarav Sharma moves from Vi to Jio)
CALL sp_ExecuteAtomicCutover(1);

-- ============================================================================
-- 6. ANALYTICAL VIEWS (For Project Evaluation & Dashboard)
-- ============================================================================

-- View 6.1: Live MNP Lifecycle Tracker Dashboard
CREATE VIEW vw_MNP_Live_Dashboard AS
SELECT 
    pr.request_id,
    s.mobile_number,
    s.full_name,
    tc.circle_name,
    d_op.operator_name AS donor_operator,
    r_op.operator_name AS recipient_operator,
    pr.upc_code,
    u.expires_at AS upc_expiry,
    pr.port_type,
    pr.request_status,
    pr.rejection_reason,
    pr.scheduled_cutover_time,
    pr.completed_at
FROM Porting_Requests pr
JOIN Subscribers s ON pr.subscriber_id = s.subscriber_id
JOIN Telecom_Circles tc ON s.circle_id = tc.circle_id
JOIN Operators d_op ON pr.donor_operator_id = d_op.operator_id
JOIN Operators r_op ON pr.recipient_operator_id = r_op.operator_id
JOIN UPC_Tokens u ON pr.upc_code = u.upc_code;

-- View 6.2: Operator Port-In vs Port-Out Net Churn Report
CREATE VIEW vw_Operator_Net_Churn AS
SELECT 
    o.operator_name,
    COUNT(CASE WHEN pr.recipient_operator_id = o.operator_id AND pr.request_status = 'COMPLETED' THEN 1 END) AS total_port_in,
    COUNT(CASE WHEN pr.donor_operator_id = o.operator_id AND pr.request_status = 'COMPLETED' THEN 1 END) AS total_port_out,
    (COUNT(CASE WHEN pr.recipient_operator_id = o.operator_id AND pr.request_status = 'COMPLETED' THEN 1 END) -
     COUNT(CASE WHEN pr.donor_operator_id = o.operator_id AND pr.request_status = 'COMPLETED' THEN 1 END)) AS net_subscriber_gain
FROM Operators o
LEFT JOIN Porting_Requests pr ON o.operator_id IN (pr.donor_operator_id, pr.recipient_operator_id)
GROUP BY o.operator_id, o.operator_name;

-- ============================================================================
-- 7. VERIFICATION QUERIES (Outputs Results Automatically Below)
-- ============================================================================
SELECT * FROM vw_MNP_Live_Dashboard;
SELECT * FROM vw_Operator_Net_Churn;
SELECT * FROM MNP_Audit_Logs;

-- TEST 1: Try generating UPC for Vikram Singh (Has Rs. 849 Unpaid Postpaid Bill)
-- Expected Output: Error Code 1644 - Donor Rejection: Postpaid subscriber has unpaid billed dues.
INSERT INTO UPC_Tokens (upc_code, subscriber_id) VALUES ('AD112233', 4);

-- TEST 2: Try generating UPC for Neha Gupta (Only 30 days old on network; < 90 days rule)
-- Expected Output: Error Code 1644 - TRAI Rejection: Subscriber has not completed 90 days...
INSERT INTO UPC_Tokens (upc_code, subscriber_id) VALUES ('VU445566', 5);

-- TEST 3: Try generating UPC for Kabir Das (Swapped SIM 2 days ago; < 7 days DoT cooling rule)
-- Expected Output: Error Code 1644 - DoT Security Block: 7-day cooling period after SIM swap...
INSERT INTO UPC_Tokens (upc_code, subscriber_id) VALUES ('JP778899', 6);
