/* ===================================================== */
/* ACTIVE ACCOUNT SCHEDULE SOURCE */
/* ===================================================== */
WITH schedule_base AS (
    SELECT
        ACCOUNT_NUMBER           AS schedule_id,
        ACCOUNT_NUMBER           AS acno,
        BRANCH_CODE,
        UPPER(COMPONENT_NAME)    AS component_name,
        UPPER(FORMULA_NAME)      AS formula_name,
        TRUNC(SCHEDULE_DUE_DATE) AS duedt,
        NVL(AMOUNT_DUE, 0)       AS amt,
        NVL(AMOUNT_SETTLED, 0)   AS settled_amt,
        SETTLEMENT_CCY,
        NVL(EMI_AMOUNT, 0)       AS emi_amount,
        SCHEDULE_FLAG,
        WAIVER_FLAG,
        CAPITALIZED
    FROM CLTB_ACCOUNT_SCHEDULES
),

/* ===================================================== */
/* FULL SCHEDULE */
/* ===================================================== */
full_schedules AS (
    SELECT
        acno,
        schedule_id,
        BRANCH_CODE,
        component_name,
        formula_name,
        duedt,
        amt,
        settled_amt,
        SETTLEMENT_CCY,
        emi_amount,
        SCHEDULE_FLAG,
        WAIVER_FLAG,
        CAPITALIZED
    FROM schedule_base
),

/* ===================================================== */
/* SCHEDULE ACCOUNT LIST */
/* ===================================================== */
schedule_accounts AS (
    SELECT
        schedule_id,
        MIN(acno) AS acno,
        MIN(BRANCH_CODE) KEEP (DENSE_RANK FIRST ORDER BY BRANCH_CODE) AS branch_code,
        MIN(SETTLEMENT_CCY) KEEP (DENSE_RANK FIRST ORDER BY SETTLEMENT_CCY) AS settlement_ccy
    FROM full_schedules
    GROUP BY schedule_id
),

/* ===================================================== */
/* SCHEDULE SIGNATURE: PRINCIPAL / EMP INTEREST / EMI */
/* ===================================================== */
schedule_signature AS (
    SELECT
        schedule_id,
        MAX(CASE WHEN component_name = 'PRINCIPAL' THEN 1 ELSE 0 END) AS has_principal,
        MAX(CASE WHEN formula_name = 'MAIN_INT_FRM_1' THEN 1 ELSE 0 END) AS has_emp_interest,
        MAX(CASE WHEN formula_name = 'MAIN_INT_FRM_2' THEN 1 ELSE 0 END) AS has_emi
    FROM full_schedules
    GROUP BY schedule_id
),

/* ===================================================== */
/* INSTALLMENT AMOUNTS BY DUE DATE */
/* Principal = PRINCIPAL.AMOUNT_DUE */
/* Interest  = MAIN_INT_FRM_1/2.AMOUNT_DUE */
/* EMI total = MAIN_INT_FRM_2.EMI_AMOUNT */
/* ===================================================== */
installment_amounts AS (
    SELECT
        fs.schedule_id,
        fs.acno,
        fs.duedt,
        SUM(CASE WHEN fs.component_name = 'PRINCIPAL' THEN fs.amt ELSE 0 END) AS principal_amt,
        SUM(
            CASE
                WHEN fs.formula_name IN ('MAIN_INT_FRM_1', 'MAIN_INT_FRM_2')
                THEN fs.amt
                ELSE 0
            END
        ) AS interest_amt,
        MAX(CASE WHEN fs.formula_name = 'MAIN_INT_FRM_2' THEN fs.emi_amount ELSE 0 END) AS total_emi_amt
    FROM full_schedules fs
    GROUP BY
        fs.schedule_id,
        fs.acno,
        fs.duedt
),

/* ===================================================== */
/* FUTURE INSTALLMENT AMOUNTS */
/* ===================================================== */
future_installment_amounts AS (
    SELECT
        schedule_id,
        duedt,
        principal_amt,
        interest_amt,
        total_emi_amt
    FROM installment_amounts
    WHERE duedt > TRUNC(PkgDate.migrateDate)
),

/* ===================================================== */
/* FUTURE INSTALLMENT COUNT */
/* Avoid long concatenation in main query */
/* ===================================================== */
installment_amounts_agg AS (
    SELECT
        schedule_id,
        COUNT(*) AS installment_amount_cnt
    FROM future_installment_amounts
    WHERE principal_amt <> 0
       OR interest_amt <> 0
       OR total_emi_amt <> 0
    GROUP BY schedule_id
),

/* ===================================================== */
/* LAST PAID / LAST DUE DATE UP TO MIGRATION DATE */
/* ===================================================== */
lastpaiddate_analytic AS (
    SELECT
        schedule_id,
        MAX(duedt) AS lastpaid_date
    FROM full_schedules
    WHERE duedt <= TRUNC(PkgDate.migrateDate)
      AND (
             component_name = 'PRINCIPAL'
          OR formula_name IN ('MAIN_INT_FRM_1', 'MAIN_INT_FRM_2')
      )
    GROUP BY schedule_id
),

/* ===================================================== */
/* PRINCIPAL STREAM */
/* ===================================================== */
principal_installments AS (
    SELECT
        schedule_id,
        acno,
        duedt,
        SUM(amt) AS amt,
        MIN(SETTLEMENT_CCY) KEEP (DENSE_RANK FIRST ORDER BY SETTLEMENT_CCY) AS settlement_ccy
    FROM full_schedules
    WHERE component_name = 'PRINCIPAL'
    GROUP BY
        schedule_id,
        acno,
        duedt
),

/* ===================================================== */
/* SCHEDULE EXPIRY BASED ON PRINCIPAL STREAM */
/* ===================================================== */
schdlexpirydate_analytic AS (
    SELECT
        schedule_id,
        MAX(duedt) AS schdlexpiry_date,
        MAX(amt) KEEP (DENSE_RANK LAST ORDER BY duedt) AS schdlexpiry_amt
    FROM principal_installments
    GROUP BY schedule_id
),

/* ===================================================== */
/* FUTURE PRINCIPAL INSTALLMENTS */
/* ===================================================== */
future_principal AS (
    SELECT
        acno,
        schedule_id,
        duedt,
        amt,
        settlement_ccy
    FROM principal_installments
    WHERE duedt > TRUNC(PkgDate.migrateDate)
),

/* ===================================================== */
/* PRINCIPAL SUMMARY / REMAINING SCHEDULES */
/* ===================================================== */
principal_summary AS (
    SELECT
        schedule_id,
        MIN(acno) KEEP (DENSE_RANK FIRST ORDER BY acno) AS acno,
        COUNT(*) AS remain_cnt,
        MIN(duedt) AS principle_nextrepay_date,
        MIN(amt) KEEP (DENSE_RANK FIRST ORDER BY duedt) AS principle_nextrepay_amt,
        MAX(duedt) AS maturity_date,
        MAX(amt) KEEP (DENSE_RANK LAST ORDER BY duedt) AS maturity_amt,
        MIN(settlement_ccy) KEEP (DENSE_RANK FIRST ORDER BY settlement_ccy) AS settlement_ccy
    FROM future_principal
    GROUP BY schedule_id
),

/* ===================================================== */
/* INTEREST STREAM */
/* EMP/SEMI-Bullet: MAIN_INT_FRM_1 */
/* EMI: MAIN_INT_FRM_2 and special-case MAIN_INT_FRM_1 */
/* ===================================================== */
interest_installments AS (
    SELECT
        fs.schedule_id,
        fs.duedt,
        SUM(fs.amt) AS interest_amt,
        MAX(CASE WHEN fs.formula_name = 'MAIN_INT_FRM_2' THEN fs.emi_amount ELSE 0 END) AS total_emi_amt
    FROM full_schedules fs
    JOIN schedule_signature ss
      ON ss.schedule_id = fs.schedule_id
    WHERE (
             ss.has_emi = 1
             AND fs.formula_name IN ('MAIN_INT_FRM_1', 'MAIN_INT_FRM_2')
          )
       OR (
             NVL(ss.has_emi, 0) = 0
             AND fs.formula_name = 'MAIN_INT_FRM_1'
          )
    GROUP BY
        fs.schedule_id,
        fs.duedt
),

/* ===================================================== */
/* FUTURE INTEREST / EMI ESTIMATE */
/* ===================================================== */
future_interest AS (
    SELECT
        schedule_id,
        MIN(duedt) AS estimate_nextinterest_date,
        MIN(interest_amt) KEEP (DENSE_RANK FIRST ORDER BY duedt) AS estimate_nextinterest_amt,
        MIN(total_emi_amt) KEEP (DENSE_RANK FIRST ORDER BY duedt) AS estimate_nextemi_amt
    FROM interest_installments
    WHERE duedt > TRUNC(PkgDate.migrateDate)
    GROUP BY schedule_id
),

/* ===================================================== */
/* INTEREST START DATE */
/* ===================================================== */
interest_start AS (
    SELECT
        schedule_id,
        MIN(duedt) AS intfstdt
    FROM interest_installments
    WHERE duedt > TRUNC(PkgDate.migrateDate)
    GROUP BY schedule_id
),

/* ===================================================== */
/* COMPARE PIPELINE: EMP VS SEMI-BULLET */
/* Exclude maturity row for regularity comparison */
/* ===================================================== */
compare_base AS (
    SELECT
        fp.acno,
        fp.schedule_id,
        fp.duedt,
        fp.amt,
        ps.remain_cnt,
        ps.principle_nextrepay_date,
        ps.principle_nextrepay_amt,
        ps.maturity_date,
        ps.maturity_amt
    FROM future_principal fp
    JOIN principal_summary ps
      ON ps.schedule_id = fp.schedule_id
    WHERE fp.duedt < ps.maturity_date
),

/* ===== PICK LAST PRINCIPAL ROWS FOR COMPARISON ===== */
compare_rn AS (
    SELECT
        acno,
        schedule_id,
        duedt,
        amt,
        remain_cnt,
        principle_nextrepay_date,
        principle_nextrepay_amt,
        maturity_date,
        maturity_amt,
        ROW_NUMBER() OVER (
            PARTITION BY schedule_id
            ORDER BY duedt DESC
        ) AS rn_desc
    FROM compare_base
),

/* ===== LIMIT COMPARISON WINDOW TO LAST FIVE ROWS ===== */
compare_for_first AS (
    SELECT
        acno,
        schedule_id,
        duedt,
        amt,
        remain_cnt,
        principle_nextrepay_date,
        principle_nextrepay_amt,
        maturity_date,
        maturity_amt,
        rn_desc
    FROM compare_rn
    WHERE rn_desc <= 5
),

/* ===== REORDER COMPARISON WINDOW ASCENDING ===== */
compare_limited AS (
    SELECT
        acno,
        schedule_id,
        duedt,
        amt,
        remain_cnt,
        principle_nextrepay_date,
        principle_nextrepay_amt,
        maturity_date,
        maturity_amt,
        rn_desc,
        ROW_NUMBER() OVER (
            PARTITION BY schedule_id
            ORDER BY duedt
        ) AS cmp_rn_limited
    FROM compare_for_first
),

/* ===== USE UP TO FOUR ROWS FOR MONTH/AMOUNT VALIDATION ===== */
compare_limited_filtered AS (
    SELECT
        acno,
        schedule_id,
        duedt,
        amt,
        remain_cnt,
        principle_nextrepay_date,
        principle_nextrepay_amt,
        maturity_date,
        maturity_amt,
        rn_desc,
        cmp_rn_limited
    FROM compare_limited
    WHERE cmp_rn_limited <= LEAST(4, remain_cnt)
),

/* ===== FIRST COMPARISON DATE AND AMOUNT ===== */
first_compare AS (
    SELECT
        schedule_id,
        MIN(duedt) AS first_date_comparation,
        MIN(amt) KEEP (DENSE_RANK FIRST ORDER BY duedt) AS first_amount_comparation
    FROM compare_limited_filtered
    GROUP BY schedule_id
),

/* ===== VALIDATE MONTHLY PRINCIPAL FREQUENCY ===== */
month_validation AS (
    SELECT
        c.schedule_id,
        COUNT(*) AS total_cmp_cnt,
        COUNT(
            CASE
                WHEN TRUNC(c.duedt, 'MM') =
                     ADD_MONTHS(TRUNC(fc.first_date_comparation, 'MM'), c.cmp_rn_limited - 1)
                THEN 1
            END
        ) AS valid_month_cnt
    FROM compare_limited_filtered c
    JOIN first_compare fc
      ON fc.schedule_id = c.schedule_id
    GROUP BY c.schedule_id
),

/* ===== VALIDATE FIXED PRINCIPAL AMOUNT ===== */
amount_validation AS (
    SELECT
        c.schedule_id,
        COUNT(*) AS total_cmp_cnt,
        COUNT(CASE WHEN c.amt = fc.first_amount_comparation THEN 1 END) AS valid_amount_cnt
    FROM compare_limited_filtered c
    JOIN first_compare fc
      ON fc.schedule_id = c.schedule_id
    GROUP BY c.schedule_id
),

/* ===================================================== */
/* FINAL BASE CORE */
/* Derive schedule type before SEMI-Bullet aggregation */
/* ===================================================== */
final_base_core AS (
    SELECT
        sa.acno,
        sa.schedule_id,
        sa.branch_code,
        sa.settlement_ccy,
        NVL(ss.has_principal, 0) AS has_principal,
        NVL(ss.has_emp_interest, 0) AS has_emp_interest,
        NVL(ss.has_emi, 0) AS has_emi,
        NVL(ps.remain_cnt, 0) AS remain_cnt,
        ps.principle_nextrepay_date AS pfstdt,
        ist.intfstdt,
        fc.first_date_comparation,
        fc.first_amount_comparation,
        ps.principle_nextrepay_date,
        ps.principle_nextrepay_amt,
        ps.maturity_date,
        ps.maturity_amt,
        se.schdlexpiry_date,
        se.schdlexpiry_amt,
        lp.lastpaid_date,
        fi.estimate_nextinterest_date,
        fi.estimate_nextinterest_amt,
        fi.estimate_nextemi_amt,
        ia.installment_amount_cnt,
        CASE
            WHEN sa.settlement_ccy = 'KHR'
            THEN ROUND(fc.first_amount_comparation, 0)
            ELSE fc.first_amount_comparation
        END AS round_firstamount_compare,
        CASE
            WHEN sa.settlement_ccy = 'KHR'
            THEN ROUND(ps.principle_nextrepay_amt, 0)
            ELSE ps.principle_nextrepay_amt
        END AS round_principleamt_nextrepay,
        /* ================= SCHEDULE TYPE ================= */
        CASE
            /* ===== PASSED MATURITY ===== */
            WHEN NVL(ps.remain_cnt, 0) = 0
            THEN 'PASSED_MATURITY'

            /* ================= EMI_BASE ================= */
            /* New DB: MAIN_INT_FRM_2 exists */
            WHEN NVL(ss.has_emi, 0) = 1
            THEN 'EMI'

            /* ================= EMP_BASE / SEMI-BULLET BASE ================= */
            /* New DB: PRINCIPAL + MAIN_INT_FRM_1 without MAIN_INT_FRM_2 */
            ELSE
                CASE
                    /* ===== SPECIAL CASE: REMAIN = 2 ===== */
                    WHEN NVL(ps.remain_cnt, 0) = 2 THEN
                        CASE
                            WHEN TRUNC(se.schdlexpiry_date, 'MM') <>
                                 ADD_MONTHS(TRUNC(ps.principle_nextrepay_date, 'MM'), 1)
                            THEN 'SEMI-Bullet'
                            WHEN TRUNC(se.schdlexpiry_date, 'MM') =
                                 ADD_MONTHS(TRUNC(ps.principle_nextrepay_date, 'MM'), 1)
                                 AND NVL(ps.principle_nextrepay_amt, 0) = 0
                            THEN 'SEMI-Bullet'
                            ELSE 'EMP'
                        END
                    /* ===== NORMAL CASE: REMAIN >= 3 ===== */
                    WHEN mv.total_cmp_cnt = mv.valid_month_cnt
                     AND av.total_cmp_cnt = av.valid_amount_cnt
                     AND fc.first_amount_comparation > 0
                    THEN 'EMP'

                    /* ===== FLEXIBLE PRINCIPAL DATE/AMOUNT ===== */
                    ELSE 'SEMI-Bullet'
                END
        END AS sched_type,
        /* === TO FIND OUT THE NEXT INTEREST REPAY DATE BASED ON LAST REPAYMENT HISTORY === */
        CASE
            /* ===== Interest schedule start date is still in the future ===== */
            WHEN TRUNC(ist.intfstdt) > TRUNC(PkgDate.migrateDate)
            THEN ist.intfstdt
            /* ===== Use last-paid anchor + 1 month if it is still in the future ===== */
            WHEN lp.lastpaid_date IS NOT NULL
             AND ist.intfstdt IS NOT NULL
             AND ADD_MONTHS(
                    TO_DATE(
                        TO_CHAR(lp.lastpaid_date, 'YYYYMM') ||
                        TO_CHAR(ist.intfstdt, 'DD'),
                        'YYYYMMDD'
                    ),
                    1
                 ) > TRUNC(PkgDate.migrateDate)
            THEN
                ADD_MONTHS(
                    TO_DATE(
                        TO_CHAR(lp.lastpaid_date, 'YYYYMM') ||
                        TO_CHAR(ist.intfstdt, 'DD'),
                        'YYYYMMDD'
                    ),
                    1
                )
            /* ===== Fallback: tomorrow ===== */
            ELSE TRUNC(PkgDate.migrateDate) + 1
        END AS interest_nextrepay_date,
        /* === NEXT INTEREST REPAY DATE SOURCE (EARMARK) === */
        CASE
            WHEN TRUNC(ist.intfstdt) > TRUNC(PkgDate.migrateDate)
            THEN 'FROM_INT_START_DATE'
            WHEN lp.lastpaid_date IS NOT NULL
             AND ist.intfstdt IS NOT NULL
             AND ADD_MONTHS(
                    TO_DATE(
                        TO_CHAR(lp.lastpaid_date, 'YYYYMM') ||
                        TO_CHAR(ist.intfstdt, 'DD'),
                        'YYYYMMDD'
                    ),
                    1
                 ) > TRUNC(PkgDate.migrateDate)
            THEN 'FROM_LASTPAID_PLUS_1M'
            ELSE 'FALLBACK_TOMORROW'
        END AS regulardate_monthlyrepay
    FROM schedule_accounts sa
    LEFT JOIN schedule_signature ss ON ss.schedule_id = sa.schedule_id
    LEFT JOIN principal_summary ps ON ps.schedule_id = sa.schedule_id
    LEFT JOIN first_compare fc ON fc.schedule_id = sa.schedule_id
    LEFT JOIN month_validation mv ON mv.schedule_id = sa.schedule_id
    LEFT JOIN amount_validation av ON av.schedule_id = sa.schedule_id
    LEFT JOIN schdlexpirydate_analytic se ON se.schedule_id = sa.schedule_id
    LEFT JOIN lastpaiddate_analytic lp ON lp.schedule_id = sa.schedule_id
    LEFT JOIN future_interest fi ON fi.schedule_id = sa.schedule_id
    LEFT JOIN interest_start ist ON ist.schedule_id = sa.schedule_id
    LEFT JOIN installment_amounts_agg ia ON ia.schedule_id = sa.schedule_id
),

/* ===================================================== */
/* SEMI-BULLET VALUES */
/* Populate only for derived sched_type = SEMI-Bullet */
/* ===================================================== */
semibullet_agg AS (
    SELECT
        cb.schedule_id,
        COUNT(*) AS total_semibullet_repay,
        RTRIM(
            XMLAGG(
                XMLELEMENT(
                    e,
                    TO_CHAR(cb.duedt, 'DD/MM/YYYY') || ' | ' ||
                    TO_CHAR(cb.amt, 'FM999999999999990.00') ||
                    ','
                )
                ORDER BY cb.duedt
            ).EXTRACT('//text()').GETCLOBVAL(),
            ','
        ) AS semibullet_repay_by_months
    FROM future_principal cb
    JOIN final_base_core fbc
      ON fbc.schedule_id = cb.schedule_id
     AND fbc.sched_type = 'SEMI-Bullet'
    GROUP BY cb.schedule_id
),

/* ===================================================== */
/* FINAL BASE */
/* Attach SEMI-Bullet values after sched_type is known */
/* ===================================================== */
final_base AS (
    SELECT
        fbc.*,
        CASE
            WHEN fbc.sched_type = 'SEMI-Bullet'
            THEN sb.total_semibullet_repay
        END AS total_semibullet_repay,
        CASE
            WHEN fbc.sched_type = 'SEMI-Bullet'
            THEN sb.semibullet_repay_by_months
        END AS semibullet_repay_by_months
    FROM final_base_core fbc
    LEFT JOIN semibullet_agg sb
      ON sb.schedule_id = fbc.schedule_id
)

/* ===================================================== */
/* FINAL SELECT */
/* ===================================================== */
SELECT
    ROW_NUMBER() OVER (ORDER BY fb.acno) AS no,
    fb.acno,
    fb.schedule_id,
    fb.branch_code,
    fb.settlement_ccy,
    fb.has_principal,
    fb.has_emp_interest,
    fb.has_emi,
    fb.sched_type,
    fb.remain_cnt,
    fb.pfstdt,
    fb.intfstdt,
    fb.principle_nextrepay_date,
    fb.round_principleamt_nextrepay,
    fb.maturity_date,
    fb.maturity_amt,
    fb.schdlexpiry_date,
    fb.schdlexpiry_amt,
    fb.lastpaid_date,
    fb.estimate_nextinterest_date,
    fb.estimate_nextinterest_amt,
    fb.estimate_nextemi_amt,
    fb.first_date_comparation,
    fb.first_amount_comparation,
    fb.round_firstamount_compare,
    fb.interest_nextrepay_date,
    fb.regulardate_monthlyrepay,
    fb.total_semibullet_repay,
    fb.semibullet_repay_by_months,
    fb.installment_amount_cnt,

    /* ===================================================== */
    /* ================= SCHEDULE DETAILS TYPE ============= */
    /* ===================================================== */
    CASE
        /* ===== EMI/EMP/SEMI --- Past Maturity Date ===== */
        WHEN fb.schdlexpiry_date IS NOT NULL
         AND fb.schdlexpiry_date <= TRUNC(PkgDate.migrateDate)
        THEN 'EMI/EMP/SEMI-Past Maturity Date'
        /* ===== EMI-Remain Schedules (=1) ===== */
        WHEN fb.sched_type = 'EMI'
         AND fb.remain_cnt = 1
        THEN 'EMI-Remain Schedules(=1)'
        /* ===== EMI-Normal ===== */
        WHEN fb.sched_type = 'EMI'
         AND fb.remain_cnt >= 2
        THEN 'EMI-Normal'
        /* ===== EMP-Remain Schedules (<=2) ===== */
        WHEN fb.sched_type = 'EMP'
         AND fb.remain_cnt <= 2
        THEN 'EMP-Remain Schedules(<=2)'
        /* ===== EMP-Grace Period ===== */
        /* ===== EMP-Normal ===== */
        WHEN fb.sched_type = 'EMP'
         AND fb.remain_cnt > 2
         AND fb.pfstdt > fb.intfstdt
         AND fb.pfstdt > TRUNC(PkgDate.migrateDate)
        THEN 'EMP-Grace Period'
        WHEN fb.sched_type = 'EMP'
         AND fb.remain_cnt > 2
        THEN 'EMP-Normal'
        /* ===== SEMIBullet-Remain Schedules (=1) ===== */
        WHEN fb.sched_type = 'SEMI-Bullet'
         AND fb.remain_cnt = 1
        THEN 'SEMIBullet-Remain Schedules(=1)'
        /* ===== SEMIBullet-Normal ===== */
        WHEN fb.sched_type = 'SEMI-Bullet'
         AND fb.remain_cnt >= 2
        THEN 'SEMIBullet-Normal'
        WHEN fb.sched_type = 'PASSED_MATURITY'
        THEN 'EMI/EMP/SEMI-Past Maturity Date'
        ELSE 'Undefined schedule'
    END AS schedule_details_type
FROM final_base fb
ORDER BY fb.acno;

/*
Run this separate detail query when you need one row per installment.
It avoids ORA-01489 by not concatenating many installments into one string.

SELECT
    ACCOUNT_NUMBER AS schedule_id,
    ACCOUNT_NUMBER AS acno,
    BRANCH_CODE,
    TRUNC(SCHEDULE_DUE_DATE) AS duedt,
    SUM(
        CASE
            WHEN UPPER(COMPONENT_NAME) = 'PRINCIPAL'
            THEN NVL(AMOUNT_DUE, 0)
            ELSE 0
        END
    ) AS principal_amt,
    SUM(
        CASE
            WHEN UPPER(FORMULA_NAME) IN ('MAIN_INT_FRM_1', 'MAIN_INT_FRM_2')
            THEN NVL(AMOUNT_DUE, 0)
            ELSE 0
        END
    ) AS interest_amt,
    MAX(
        CASE
            WHEN UPPER(FORMULA_NAME) = 'MAIN_INT_FRM_2'
            THEN NVL(EMI_AMOUNT, 0)
            ELSE 0
        END
    ) AS total_emi_amt,
    MIN(SETTLEMENT_CCY) KEEP (DENSE_RANK FIRST ORDER BY SETTLEMENT_CCY) AS settlement_ccy
FROM CLTB_ACCOUNT_SCHEDULES
WHERE TRUNC(SCHEDULE_DUE_DATE) > TRUNC(PkgDate.migrateDate)
GROUP BY
    ACCOUNT_NUMBER,
    BRANCH_CODE,
    TRUNC(SCHEDULE_DUE_DATE)
HAVING SUM(
           CASE
               WHEN UPPER(COMPONENT_NAME) = 'PRINCIPAL'
               THEN NVL(AMOUNT_DUE, 0)
               ELSE 0
           END
       ) <> 0
    OR SUM(
           CASE
               WHEN UPPER(FORMULA_NAME) IN ('MAIN_INT_FRM_1', 'MAIN_INT_FRM_2')
               THEN NVL(AMOUNT_DUE, 0)
               ELSE 0
           END
       ) <> 0
    OR MAX(
           CASE
               WHEN UPPER(FORMULA_NAME) = 'MAIN_INT_FRM_2'
               THEN NVL(EMI_AMOUNT, 0)
               ELSE 0
           END
       ) <> 0
ORDER BY
    schedule_id,
    duedt;
*/
