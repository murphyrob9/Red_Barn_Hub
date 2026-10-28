-- RB04 schema-only baseline, sourced from the reconstructed PostgreSQL 17 database.
-- Apply once to a fresh RB04 namespace, as postgres.
-- Prerequisites: public schema, auth.users(id), auth.role(), and existing roles
-- postgres, anon, authenticated, service_role, and rb04_schema_reader.
-- Role provisioning and local auth/compatibility stubs are external prerequisites.
-- No data, credentials, ingestion execution, or scheduled work is included.
-- ACL normalization: local surrogate -> service_role; two default function ACLs
-- are represented explicitly with the same resolved grants.

BEGIN;

--
-- PostgreSQL database dump
--


-- Dumped from database version 17.11 (Debian 17.11-1.pgdg13+2)
-- Dumped by pg_dump version 17.11 (Debian 17.11-1.pgdg13+2)

SET LOCAL statement_timeout = 0;
SET LOCAL lock_timeout = 0;
SET LOCAL idle_in_transaction_session_timeout = 0;
SET LOCAL transaction_timeout = 0;
SET LOCAL client_encoding = 'UTF8';
SET LOCAL standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', true);
SET LOCAL check_function_bodies = false;
SET LOCAL xmloption = content;
SET LOCAL client_min_messages = warning;
SET LOCAL row_security = off;

--
-- Name: rb04; Type: SCHEMA; Schema: -; Owner: postgres
--

CREATE SCHEMA rb04;


ALTER SCHEMA rb04 OWNER TO postgres;

--
-- Name: rb04_app_readonly_dev(uuid, uuid, text, date, date); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.rb04_app_readonly_dev(p_user_id uuid, p_merchant_id uuid, p_view text, p_start date, p_end date) RETURNS jsonb
    LANGUAGE plpgsql STABLE SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  c_limit constant int := 500;
  c_dev_merchant constant uuid := '44b7802c-9152-4a58-a81f-b12280f809e7';
  m rb04.dashboard_memberships%ROWTYPE;
  v_count int;
  v_emp_id uuid;
  v_emp_clover text;
  v_emp_name text;
  v_rows jsonb := '[]'::jsonb;
  v_total int;
  v_mgr boolean;
BEGIN
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'Service role required' USING ERRCODE = '42501';
  END IF;
  IF p_user_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'UNAUTHENTICATED');
  END IF;
  IF p_view IS NULL OR p_view NOT IN
     ('me','daily_summary','employee_weekly','review_queue','exceptions','approval_rules','my_weekly','my_activity') THEN
    RETURN jsonb_build_object('ok', false, 'code', 'INVALID_REQUEST');
  END IF;
  -- Undated views reject any supplied date.
  IF p_view IN ('me','approval_rules') AND (p_start IS NOT NULL OR p_end IS NOT NULL) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'INVALID_REQUEST');
  END IF;

  -- Resolve exactly one active membership.
  IF p_merchant_id IS NULL THEN
    SELECT count(*) INTO v_count
      FROM rb04.dashboard_memberships
     WHERE user_id = p_user_id AND active IS TRUE;
    IF v_count = 0 THEN RETURN jsonb_build_object('ok', false, 'code', 'NO_ACTIVE_MEMBERSHIP'); END IF;
    IF v_count > 1 THEN RETURN jsonb_build_object('ok', false, 'code', 'AMBIGUOUS_MEMBERSHIP'); END IF;
    SELECT * INTO m
      FROM rb04.dashboard_memberships
     WHERE user_id = p_user_id AND active IS TRUE;
  ELSE
    SELECT * INTO m
      FROM rb04.dashboard_memberships
     WHERE user_id = p_user_id AND merchant_id = p_merchant_id;
    IF NOT FOUND OR m.active IS NOT TRUE THEN
      RETURN jsonb_build_object('ok', false, 'code', 'NO_ACTIVE_MEMBERSHIP');
    END IF;
  END IF;
  IF m.app_role IS NULL OR m.app_role NOT IN ('OWNER','ADMIN','MANAGER','SHIFT_LEAD','BARTENDER') THEN
    RETURN jsonb_build_object('ok', false, 'code', 'NO_ACTIVE_MEMBERSHIP');
  END IF;

  -- Merchant eligibility, independent of the ingestion 'enabled' flag.
  IF m.merchant_id IS DISTINCT FROM c_dev_merchant OR NOT EXISTS (
       SELECT 1
         FROM rb04.merchants mm
         JOIN rb04.organizations o ON o.id = mm.organization_id
        WHERE mm.id = m.merchant_id) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'MERCHANT_NOT_ELIGIBLE');
  END IF;

  -- Employee linkage: same merchant, ACTIVE, with a Clover employee ID.
  IF m.accountability_employee_id IS NOT NULL THEN
    SELECT e.id, e.clover_employee_id, e.display_name
      INTO v_emp_id, v_emp_clover, v_emp_name
      FROM rb04.accountability_employees e
     WHERE e.merchant_id = m.merchant_id
       AND e.id = m.accountability_employee_id
       AND e.employment_status = 'ACTIVE'
       AND e.clover_employee_id IS NOT NULL;
  END IF;
  IF m.app_role = 'BARTENDER' AND v_emp_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'EMPLOYEE_NOT_LINKED');
  END IF;

  -- Role matrix (shift-lead review queue withheld pending policy confirmation).
  v_mgr := m.app_role IN ('OWNER','ADMIN','MANAGER');
  IF NOT (
       p_view = 'me'
    OR (p_view IN ('daily_summary','employee_weekly','review_queue','exceptions') AND v_mgr)
    OR (p_view = 'approval_rules' AND m.app_role IN ('OWNER','ADMIN'))
    OR (p_view IN ('my_weekly','my_activity') AND m.app_role <> 'SHIFT_LEAD')
  ) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'FORBIDDEN');
  END IF;
  IF p_view IN ('my_weekly','my_activity') AND v_emp_id IS NULL THEN
    RETURN jsonb_build_object('ok', false, 'code', 'EMPLOYEE_NOT_LINKED');
  END IF;

  -- Dated views require a range of at most 93 calendar days.
  IF p_view NOT IN ('me','approval_rules')
     AND (p_start IS NULL OR p_end IS NULL OR p_end < p_start OR p_end - p_start > 92) THEN
    RETURN jsonb_build_object('ok', false, 'code', 'INVALID_REQUEST');
  END IF;

  -- Every branch: explicit column allowlist, deterministic ORDER BY with a unique
  -- tie-breaker before LIMIT, and c_limit + 1 rows fetched to detect truncation.
  IF p_view = 'me' THEN
    v_rows := jsonb_build_array(jsonb_build_object(
      'role', m.app_role,
      'merchant_id', m.merchant_id,
      'employee_linked', v_emp_id IS NOT NULL,
      'employee_display_name', v_emp_name));

  ELSIF p_view = 'daily_summary' THEN
    -- Unique per merchant: business_date.
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'business_date', d.business_date,
             'sales_count', d.sales_count, 'sales_cents', d.sales_cents,
             'tips_cents', d.tips_cents,
             'comp_count', d.comp_count, 'comp_cents', d.comp_cents,
             'discount_count', d.discount_count, 'discount_cents', d.discount_cents,
             'void_count', d.void_count, 'refund_count', d.refund_count)
             ORDER BY d.business_date), '[]'::jsonb)
      INTO v_rows
      FROM (SELECT business_date, sales_count, sales_cents, tips_cents, comp_count, comp_cents,
                   discount_count, discount_cents, void_count, refund_count
              FROM rb04.accountability_dashboard_daily
             WHERE merchant_id = m.merchant_id AND business_date BETWEEN p_start AND p_end
             ORDER BY business_date
             LIMIT c_limit + 1) d;

  ELSIF p_view = 'employee_weekly' THEN
    -- Unique per merchant: (week_start_monday, source_employee_id). Verified: the view
    -- GROUPs BY merchant_id, week_start_monday, source_employee_id, so each key (including
    -- a single NULL employee group) appears once; NULLS LAST keeps that group's position fixed.
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'week_start_monday', w.week_start_monday,
             'source_employee_id', w.source_employee_id,
             'employee_name', w.employee_name,
             'sales_cents', w.sales_cents, 'tips_cents', w.tips_cents,
             'comp_cents', w.comp_cents, 'discount_cents', w.discount_cents,
             'void_count', w.void_count, 'refund_count', w.refund_count,
             'sale_count', w.sale_count)
             ORDER BY w.week_start_monday, w.source_employee_id NULLS LAST), '[]'::jsonb)
      INTO v_rows
      FROM (SELECT week_start_monday, source_employee_id, employee_name, sales_cents, tips_cents,
                   comp_cents, discount_cents, void_count, refund_count, sale_count
              FROM rb04.accountability_dashboard_employee_weekly
             WHERE merchant_id = m.merchant_id AND week_start_monday BETWEEN p_start AND p_end
             ORDER BY week_start_monday, source_employee_id NULLS LAST
             LIMIT c_limit + 1) w;

  ELSIF p_view = 'review_queue' THEN
    -- Managers only. Unique: event_id.
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'event_id', q.event_id, 'business_date', q.business_date,
             'observed_at', q.observed_at, 'event_type', q.event_type,
             'source_order_id', q.source_order_id, 'source_payment_id', q.source_payment_id,
             'source_employee_id', q.source_employee_id, 'source_employee_name', q.source_employee_name,
             'amount_cents', q.amount_cents, 'source_notes', q.source_notes,
             'latest_decision', q.latest_decision, 'latest_reviewer_role', q.latest_reviewer_role,
             'last_reviewed_at', q.last_reviewed_at, 'active_exceptions', q.active_exceptions,
             'highest_exception_severity', q.highest_exception_severity)
             ORDER BY q.business_date, q.observed_at, q.event_id), '[]'::jsonb)
      INTO v_rows
      FROM (SELECT event_id, business_date, observed_at, event_type, source_order_id, source_payment_id,
                   source_employee_id, source_employee_name, amount_cents, source_notes,
                   latest_decision, latest_reviewer_role, last_reviewed_at,
                   active_exceptions, highest_exception_severity
              FROM rb04.accountability_dashboard_review_queue
             WHERE merchant_id = m.merchant_id AND business_date BETWEEN p_start AND p_end
             ORDER BY business_date, observed_at, event_id
             LIMIT c_limit + 1) q;

  ELSIF p_view = 'exceptions' THEN
    -- Unique: id. Range applied to the Chicago calendar date of opened_at.
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id', x.id, 'event_id', x.event_id, 'exception_type', x.exception_type,
             'severity', x.severity, 'status', x.status, 'explanation', x.explanation,
             'assigned_employee_id', x.assigned_employee_id,
             'opened_at', x.opened_at, 'resolved_at', x.resolved_at,
             'resolution_notes', x.resolution_notes)
             ORDER BY x.opened_at, x.id), '[]'::jsonb)
      INTO v_rows
      FROM (SELECT id, event_id, exception_type, severity, status, explanation,
                   assigned_employee_id, opened_at, resolved_at, resolution_notes
              FROM rb04.accountability_exceptions
             WHERE merchant_id = m.merchant_id
               AND (opened_at AT TIME ZONE 'America/Chicago')::date BETWEEN p_start AND p_end
             ORDER BY opened_at, id
             LIMIT c_limit + 1) x;

  ELSIF p_view = 'approval_rules' THEN
    -- Owners and administrators only. Unique: id.
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'id', r.id, 'event_type', r.event_type, 'approver_role', r.approver_role,
             'max_amount_cents', r.max_amount_cents, 'requires_reason', r.requires_reason,
             'requires_approval', r.requires_approval, 'effective_from', r.effective_from,
             'effective_to', r.effective_to, 'policy_reference', r.policy_reference)
             ORDER BY r.event_type, r.effective_from, r.id), '[]'::jsonb)
      INTO v_rows
      FROM (SELECT id, event_type, approver_role, max_amount_cents, requires_reason,
                   requires_approval, effective_from, effective_to, policy_reference
              FROM rb04.accountability_approval_rules
             WHERE merchant_id = m.merchant_id
             ORDER BY event_type, effective_from, id
             LIMIT c_limit + 1) r;

  ELSIF p_view = 'my_weekly' THEN
    -- Own linked employee only. Unique per (merchant, employee): week_start_monday.
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'week_start_monday', w.week_start_monday,
             'sales_cents', w.sales_cents, 'tips_cents', w.tips_cents,
             'comp_cents', w.comp_cents, 'discount_cents', w.discount_cents,
             'void_count', w.void_count, 'refund_count', w.refund_count,
             'sale_count', w.sale_count)
             ORDER BY w.week_start_monday), '[]'::jsonb)
      INTO v_rows
      FROM (SELECT week_start_monday, sales_cents, tips_cents, comp_cents, discount_cents,
                   void_count, refund_count, sale_count
              FROM rb04.accountability_dashboard_employee_weekly
             WHERE merchant_id = m.merchant_id
               AND source_employee_id = v_emp_clover
               AND week_start_monday BETWEEN p_start AND p_end
             ORDER BY week_start_monday
             LIMIT c_limit + 1) w;

  ELSIF p_view = 'my_activity' THEN
    -- Own linked employee only. Unique: event_id. No notes or reviewer identity.
    SELECT coalesce(jsonb_agg(jsonb_build_object(
             'event_id', s.event_id, 'business_date', s.business_date,
             'event_type', s.event_type, 'amount_cents', s.amount_cents,
             'latest_decision', s.latest_decision, 'awaiting_review', s.awaiting_review)
             ORDER BY s.business_date, s.event_id), '[]'::jsonb)
      INTO v_rows
      FROM (SELECT event_id, business_date, event_type, amount_cents, latest_decision, awaiting_review
              FROM rb04.accountability_event_review_status
             WHERE merchant_id = m.merchant_id
               AND source_employee_id = v_emp_clover
               AND business_date BETWEEN p_start AND p_end
             ORDER BY business_date, event_id
             LIMIT c_limit + 1) s;
  END IF;

  -- Accurate truncation: fetched up to c_limit + 1; return at most c_limit.
  v_total := jsonb_array_length(v_rows);
  IF v_total > c_limit THEN
    v_rows := v_rows - c_limit;  -- removes the extra (last) element at index c_limit
  END IF;

  RETURN jsonb_build_object(
    'ok', true,
    'role', m.app_role,
    'merchant_id', m.merchant_id,
    'employee_linked', v_emp_id IS NOT NULL,
    'rows', v_rows,
    'row_count', jsonb_array_length(v_rows),
    'truncated', v_total > c_limit);
END;
$$;


ALTER FUNCTION public.rb04_app_readonly_dev(p_user_id uuid, p_merchant_id uuid, p_view text, p_start date, p_end date) OWNER TO postgres;

--
-- Name: rb04_check_connection_dev(); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.rb04_check_connection_dev() RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
  v_merchant_id uuid :=
    '44b7802c-9152-4a58-a81f-b12280f809e7'::uuid;

  v_checkpoints jsonb;
  v_count integer;
  v_valid boolean;
BEGIN
  -- Defense in depth: service role only.
  IF auth.role() IS DISTINCT FROM 'service_role' THEN
    RAISE EXCEPTION 'RB04 unauthorized database role'
      USING ERRCODE = '42501';
  END IF;

  -- Read only the two expected DEV checkpoints.
  SELECT
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'resource', resource,
          'status', status,
          'next_offset', next_offset
        )
        ORDER BY resource
      ),
      '[]'::jsonb
    ),
    COUNT(*)
  INTO v_checkpoints, v_count
  FROM rb04.clover_sync_checkpoints
  WHERE merchant_id = v_merchant_id
    AND resource IN ('orders', 'payments');

  SELECT
    v_count = 2
    AND COUNT(*) = 2
    AND COUNT(DISTINCT resource) = 2
    AND BOOL_AND(
      status = 'NOT_STARTED'
      AND next_offset = 0
    )
  INTO v_valid
  FROM rb04.clover_sync_checkpoints
  WHERE merchant_id = v_merchant_id
    AND resource IN ('orders', 'payments');

  RETURN jsonb_build_object(
    'ok', COALESCE(v_valid, false),
    'environment', 'DEV',
    'mode', 'DB_CONNECTIVITY_READONLY',
    'merchantId', v_merchant_id,
    'connectivity',
      CASE
        WHEN COALESCE(v_valid, false)
        THEN 'PASS'
        ELSE 'BASELINE_MISMATCH'
      END,
    'checkpoints', v_checkpoints,
    'databaseWrites', false,
    'normalizationExecuted', false,
    'checkpointsUpdated', false,
    'rpcExecutedForIngestion', false
  );
END;
$$;


ALTER FUNCTION public.rb04_check_connection_dev() OWNER TO postgres;

--
-- Name: rb04_check_scan_dev(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.rb04_check_scan_dev(p_resource text) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    v_checkpoint rb04.clover_sync_checkpoints%ROWTYPE;
    v_audit rb04.clover_scan_audits%ROWTYPE;
    v_issues jsonb := '[]'::jsonb;
    v_state text;
BEGIN
    IF p_resource IS NULL
       OR p_resource NOT IN ('orders', 'payments')
    THEN
        RAISE EXCEPTION 'Invalid resource';
    END IF;

    SELECT *
    INTO v_checkpoint
    FROM rb04.clover_sync_checkpoints
    WHERE merchant_id =
        '44b7802c-9152-4a58-a81f-b12280f809e7'::uuid
      AND resource = p_resource;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Checkpoint missing';
    END IF;

    IF v_checkpoint.status = 'NOT_STARTED'
       AND v_checkpoint.next_offset = 0
    THEN
        RETURN jsonb_build_object(
            'resource', p_resource,
            'state', 'PENDING',
            'reason', 'No scan committed',
            'internallyConsistent', false,
            'independentlyVerified', false,
            'cursorAdvanceAllowed', false
        );
    END IF;

    SELECT *
    INTO v_audit
    FROM rb04.clover_scan_audits
    WHERE merchant_id = v_checkpoint.merchant_id
      AND resource = p_resource
      AND scan_start_ms = v_checkpoint.scan_start_ms
      AND scan_end_ms = v_checkpoint.scan_end_ms
    ORDER BY id DESC
    LIMIT 1;

    IF NOT FOUND THEN
        v_issues := v_issues ||
            jsonb_build_array('AUDIT_MISSING');
    ELSE
        IF v_audit.final_offset
           IS DISTINCT FROM v_checkpoint.next_offset
        THEN
            v_issues := v_issues ||
                jsonb_build_array('OFFSET_MISMATCH');
        END IF;

        IF v_audit.records_read
           IS DISTINCT FROM v_checkpoint.next_offset
        THEN
            v_issues := v_issues ||
                jsonb_build_array('RECORD_COUNT_MISMATCH');
        END IF;

        IF v_audit.first_offset <> 0 THEN
            v_issues := v_issues ||
                jsonb_build_array('INVALID_FIRST_OFFSET');
        END IF;

        IF v_audit.pages_read < 1 THEN
            v_issues := v_issues ||
                jsonb_build_array('NO_PAGES_COMMITTED');
        END IF;

        IF v_audit.unique_records
           IS DISTINCT FROM v_audit.records_read
        THEN
            v_issues := v_issues ||
                jsonb_build_array('AUDIT_COUNT_MISMATCH');
        END IF;

        IF v_checkpoint.status = 'PAUSED'
           AND v_audit.status <> 'PARTIAL'
        THEN
            v_issues := v_issues ||
                jsonb_build_array('AUDIT_STATUS_MISMATCH');
        END IF;
    END IF;

    IF jsonb_array_length(v_issues) > 0 THEN
        v_state := 'FAIL';
    ELSIF v_checkpoint.status = 'PAUSED'
          AND v_audit.status = 'PARTIAL'
    THEN
        v_state := 'PASS';
    ELSE
        v_state := 'PENDING';
    END IF;

    RETURN jsonb_build_object(
        'resource', p_resource,
        'state', v_state,
        'issues', v_issues,
        'checkpointStatus', v_checkpoint.status,
        'auditStatus', v_audit.status,
        'recordsRead', v_audit.records_read,
        'nextOffset', v_checkpoint.next_offset,
        'internallyConsistent', v_state = 'PASS',
        'independentlyVerified', false,
        'cursorAdvanceAllowed', false
    );
END;
$$;


ALTER FUNCTION public.rb04_check_scan_dev(p_resource text) OWNER TO postgres;

--
-- Name: rb04_commit_clover_page_dev(uuid, text, bigint, bigint, integer, jsonb, boolean, integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.rb04_commit_clover_page_dev(p_merchant_id uuid, p_resource text, p_scan_start_ms bigint, p_scan_end_ms bigint, p_expected_offset integer, p_records jsonb, p_page_complete boolean DEFAULT false, p_retry_attempts integer DEFAULT 0) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
DECLARE
    v_checkpoint rb04.clover_sync_checkpoints%ROWTYPE;
    v_merchant_enabled boolean;
    v_writes_authorized boolean;
    v_record jsonb;
    v_external_id text;
    v_modified_ms bigint;
    v_sha256 text;
    v_result jsonb;
    v_inserted integer := 0;
    v_existing_snapshots integer := 0;
    v_count integer;
    v_distinct_count integer;
    v_next_offset integer;
    v_audit_id bigint;
    v_status text;
    v_now_ms bigint;
    v_seen_count integer := 0;
BEGIN
    IF auth.role() IS DISTINCT FROM 'service_role' THEN
        RAISE EXCEPTION 'Service role required';
    END IF;


    IF NOT EXISTS (
        SELECT 1
        FROM rb04.dev_ingestion_control
        WHERE control_id = 1
          AND writes_enabled IS TRUE
    ) THEN
        RAISE EXCEPTION
            'RB-04 DEV ingestion is disabled by database policy';
    END IF;

    IF p_merchant_id IS DISTINCT FROM
       '44b7802c-9152-4a58-a81f-b12280f809e7'::uuid THEN
        RAISE EXCEPTION 'Merchant not permitted';
    END IF;

    SELECT enabled INTO v_merchant_enabled
    FROM rb04.merchants
    WHERE id = p_merchant_id
      AND clover_merchant_id = 'X3MHXR2NA6FG1'
    FOR UPDATE;

    IF NOT FOUND OR v_merchant_enabled IS DISTINCT FROM false THEN
        RAISE EXCEPTION 'DEV merchant configuration invalid';
    END IF;
    
    -- RB-04 DEV: Independent database write authorization.
    -- Missing or disabled authorization blocks ingestion.
    SELECT writes_authorized
    INTO v_writes_authorized
    FROM rb04.ingestion_write_controls
    WHERE merchant_id = p_merchant_id
    FOR UPDATE;

    IF NOT FOUND
       OR v_writes_authorized IS DISTINCT FROM true
    THEN
        RAISE EXCEPTION
            'RB-04 DEV ingestion is not authorized';
    END IF;


    v_now_ms := (
        extract(epoch FROM clock_timestamp()) * 1000
    )::bigint;

    IF p_resource IS NULL
       OR p_resource NOT IN ('orders', 'payments')
       OR p_scan_start_ms IS NULL
       OR p_scan_end_ms IS NULL
       OR p_scan_start_ms < 0
       OR p_scan_end_ms <= p_scan_start_ms
       OR p_scan_end_ms - p_scan_start_ms > 14400000
       OR p_scan_end_ms > v_now_ms - 3600000
       OR p_expected_offset IS NULL
       OR p_expected_offset < 0
       OR p_records IS NULL
       OR jsonb_typeof(p_records) <> 'array'
       OR jsonb_array_length(p_records) > 10
       OR p_retry_attempts IS NULL
       OR p_retry_attempts < 0
       OR p_page_complete IS NULL
    THEN
        RAISE EXCEPTION
            'Invalid page arguments or unsafe scan window';
    END IF;

    v_count := jsonb_array_length(p_records);

    IF p_page_complete AND v_count >= 10 THEN
        RAISE EXCEPTION
            'Full page cannot establish end of retrieval';
    END IF;

    IF NOT p_page_complete AND v_count <> 10 THEN
        RAISE EXCEPTION
            'Non-final page must contain exactly 10 records';
    END IF;

    IF p_expected_offset > 2147483647 - v_count THEN
        RAISE EXCEPTION 'Page offset overflow';
    END IF;

    SELECT count(DISTINCT item.value->>'id')::integer
    INTO v_distinct_count
    FROM jsonb_array_elements(p_records) AS item(value);

    IF v_distinct_count <> v_count THEN
        RAISE EXCEPTION
            'Repeated or missing Clover record IDs within page';
    END IF;

    SELECT *
    INTO v_checkpoint
    FROM rb04.clover_sync_checkpoints
    WHERE merchant_id = p_merchant_id
      AND resource = p_resource
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION
            'Synchronization checkpoint missing';
    END IF;

    IF v_checkpoint.status = 'NOT_STARTED' THEN
        IF p_expected_offset <> 0
           OR v_checkpoint.next_offset <> 0
           OR v_checkpoint.scan_start_ms IS NOT NULL
           OR v_checkpoint.scan_end_ms IS NOT NULL
        THEN
            RAISE EXCEPTION 'Invalid initial checkpoint';
        END IF;

        IF EXISTS (
            SELECT 1
            FROM rb04.clover_scan_audits
            WHERE merchant_id = p_merchant_id
              AND resource = p_resource
              AND status IN ('RUNNING', 'PARTIAL')
        ) THEN
            RAISE EXCEPTION 'Unresolved scan audit exists';
        END IF;

    ELSIF v_checkpoint.status = 'RUNNING' THEN
        IF v_checkpoint.scan_start_ms
               IS DISTINCT FROM p_scan_start_ms
           OR v_checkpoint.scan_end_ms
               IS DISTINCT FROM p_scan_end_ms
           OR v_checkpoint.next_offset
               IS DISTINCT FROM p_expected_offset
           OR p_expected_offset = 0
        THEN
            RAISE EXCEPTION 'Scan checkpoint mismatch';
        END IF;

    ELSE
        RAISE EXCEPTION
            'Scan is not writable; explicit recovery required';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM rb04.clover_scan_audits
        WHERE merchant_id = p_merchant_id
          AND resource = p_resource
          AND scan_start_ms < p_scan_end_ms
          AND scan_end_ms > p_scan_start_ms
          AND (
              scan_start_ms <> p_scan_start_ms
              OR scan_end_ms <> p_scan_end_ms
          )
    ) THEN
        RAISE EXCEPTION
            'Overlapping historical scan window';
    END IF;

    -- Validate every record before any raw insertion.
    FOR v_record IN
        SELECT value
        FROM jsonb_array_elements(p_records)
    LOOP
        IF jsonb_typeof(v_record) <> 'object' THEN
            RAISE EXCEPTION 'Invalid Clover record';
        END IF;

        v_external_id := v_record->>'id';

        IF v_external_id IS NULL
           OR length(v_external_id) NOT BETWEEN 1 AND 128
           OR v_record->>'modifiedTime' IS NULL
           OR v_record->>'modifiedTime' !~ '^[0-9]+$'
        THEN
            RAISE EXCEPTION
                'Invalid Clover record identity or timestamp';
        END IF;

        BEGIN
            v_modified_ms :=
                (v_record->>'modifiedTime')::bigint;
        EXCEPTION
            WHEN numeric_value_out_of_range THEN
                RAISE EXCEPTION 'Clover timestamp out of range';
        END;

        IF v_modified_ms < p_scan_start_ms
           OR v_modified_ms >= p_scan_end_ms
        THEN
            RAISE EXCEPTION 'Record outside scan window';
        END IF;
    END LOOP;

    -- Create or lock the scan audit before tracking IDs.
    IF p_expected_offset = 0 THEN
        INSERT INTO rb04.clover_scan_audits (
            merchant_id,
            resource,
            scan_start_ms,
            scan_end_ms,
            status,
            pages_read,
            records_read,
            unique_records,
            duplicate_records,
            retry_attempts,
            first_offset,
            final_offset
        )
        VALUES (
            p_merchant_id,
            p_resource,
            p_scan_start_ms,
            p_scan_end_ms,
            'RUNNING',
            0, 0, 0, 0, 0, 0, 0
        )
        RETURNING id INTO v_audit_id;
    ELSE
        SELECT id
        INTO v_audit_id
        FROM rb04.clover_scan_audits
        WHERE merchant_id = p_merchant_id
          AND resource = p_resource
          AND scan_start_ms = p_scan_start_ms
          AND scan_end_ms = p_scan_end_ms
          AND status = 'RUNNING'
        FOR UPDATE;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Active scan audit missing';
        END IF;
    END IF;

    -- The unique constraint rejects IDs previously seen
    -- on any earlier page of this same scan.
    FOR v_record IN
        SELECT value
        FROM jsonb_array_elements(p_records)
    LOOP
        v_external_id := v_record->>'id';

        INSERT INTO rb04.clover_scan_seen_records (
            scan_audit_id,
            external_id,
            first_page_offset
        )
        VALUES (
            v_audit_id,
            v_external_id,
            p_expected_offset
        )
        ON CONFLICT (scan_audit_id, external_id)
        DO NOTHING;

        IF NOT FOUND THEN
            RAISE EXCEPTION
                'Cross-page duplicate Clover ID detected: %',
                v_external_id;
        END IF;

        v_seen_count := v_seen_count + 1;

        v_sha256 := encode(
            extensions.digest(
                convert_to(v_record::text, 'UTF8'),
                'sha256'
            ),
            'hex'
        );

        v_result := public.rb04_insert_raw_dev(
            p_merchant_id,
            p_resource,
            v_external_id,
            v_record,
            v_sha256,
            '/' || p_resource
        );

        IF (v_result->>'inserted')::boolean IS TRUE THEN
            v_inserted := v_inserted + 1;
        ELSIF (v_result->>'inserted')::boolean IS FALSE THEN
            v_existing_snapshots :=
                v_existing_snapshots + 1;
        ELSE
            RAISE EXCEPTION
                'Unexpected raw insertion response';
        END IF;
    END LOOP;

    v_next_offset := p_expected_offset + v_count;

    v_status := CASE
        WHEN p_page_complete THEN 'PAUSED'
        ELSE 'RUNNING'
    END;

    UPDATE rb04.clover_scan_audits
    SET
        pages_read = pages_read + 1,
        records_read = records_read + v_count,
        unique_records = unique_records + v_seen_count,
        retry_attempts = retry_attempts + p_retry_attempts,
        final_offset = v_next_offset,
        status = CASE
            WHEN p_page_complete THEN 'PARTIAL'
            ELSE 'RUNNING'
        END
    WHERE id = v_audit_id;

    UPDATE rb04.clover_sync_checkpoints
    SET
        status = v_status,
        scan_start_ms = p_scan_start_ms,
        scan_end_ms = p_scan_end_ms,
        next_offset = v_next_offset,
        last_started_at = CASE
            WHEN p_expected_offset = 0
                THEN now()
            ELSE last_started_at
        END,
        updated_at = now(),
        last_error = NULL
    WHERE merchant_id = p_merchant_id
      AND resource = p_resource;

    RETURN jsonb_build_object(
        'ok', true,
        'resource', p_resource,
        'auditId', v_audit_id,
        'recordsReceived', v_count,
        'distinctIdsInPage', v_distinct_count,
        'snapshotsInserted', v_inserted,
        'existingSnapshots', v_existing_snapshots,
        'nextOffset', v_next_offset,
        'status', v_status,
        'retrievalComplete', p_page_complete,
        'reconciled', false,
        'independentlyVerified', false,
        'cursorAdvanceAllowed', false
    );
END;
$_$;


ALTER FUNCTION public.rb04_commit_clover_page_dev(p_merchant_id uuid, p_resource text, p_scan_start_ms bigint, p_scan_end_ms bigint, p_expected_offset integer, p_records jsonb, p_page_complete boolean, p_retry_attempts integer) OWNER TO postgres;

--
-- Name: rb04_get_commit_checkpoint_dev(text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.rb04_get_commit_checkpoint_dev(p_resource text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
DECLARE
    v_checkpoint rb04.clover_sync_checkpoints%ROWTYPE;
BEGIN
    IF auth.role() IS DISTINCT FROM 'service_role' THEN
        RAISE EXCEPTION 'Service role required';
    END IF;

    IF p_resource IS NULL
       OR p_resource NOT IN ('orders', 'payments') THEN
        RAISE EXCEPTION 'Invalid resource';
    END IF;

    SELECT *
    INTO v_checkpoint
    FROM rb04.clover_sync_checkpoints
    WHERE merchant_id =
        '44b7802c-9152-4a58-a81f-b12280f809e7'::uuid
      AND resource = p_resource;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'DEV checkpoint not found';
    END IF;

    RETURN jsonb_build_object(
        'resource', v_checkpoint.resource,
        'status', v_checkpoint.status,
        'scanStartMs', v_checkpoint.scan_start_ms,
        'scanEndMs', v_checkpoint.scan_end_ms,
        'nextOffset', v_checkpoint.next_offset
    );
END;
$$;


ALTER FUNCTION public.rb04_get_commit_checkpoint_dev(p_resource text) OWNER TO postgres;

--
-- Name: rb04_insert_raw_dev(uuid, text, text, jsonb, text, text); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.rb04_insert_raw_dev(p_merchant_id uuid, p_resource text, p_external_id text, p_payload jsonb, p_sha256 text, p_source_endpoint text) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $_$
DECLARE
    v_id bigint;
    v_merchant_enabled boolean;
BEGIN
    -- Only backend service-role requests may execute.
    IF auth.role() IS DISTINCT FROM 'service_role' THEN
        RAISE EXCEPTION 'Service role required';
    END IF;

    -- Global DEV database authorization.
    IF NOT EXISTS (
        SELECT 1
        FROM rb04.dev_ingestion_control
        WHERE control_id = 1
          AND writes_enabled IS TRUE
    ) THEN
        RAISE EXCEPTION
            'RB-04 DEV ingestion is disabled by database policy';
    END IF;

    -- Restrict to the designated DEV merchant.
    IF p_merchant_id IS DISTINCT FROM
       '44b7802c-9152-4a58-a81f-b12280f809e7'::uuid
    THEN
        RAISE EXCEPTION 'Merchant not permitted';
    END IF;

    -- Merchant-specific database authorization.
    IF NOT EXISTS (
        SELECT 1
        FROM rb04.ingestion_write_controls
        WHERE merchant_id = p_merchant_id
          AND writes_authorized IS TRUE
    ) THEN
        RAISE EXCEPTION
            'RB-04 DEV ingestion is not authorized';
    END IF;

    -- Confirm the merchant is the disabled DEV destination.
    SELECT enabled
    INTO v_merchant_enabled
    FROM rb04.merchants
    WHERE id = p_merchant_id
      AND clover_merchant_id = 'X3MHXR2NA6FG1';

    IF NOT FOUND
       OR v_merchant_enabled IS DISTINCT FROM false
    THEN
        RAISE EXCEPTION
            'DEV merchant configuration invalid';
    END IF;

    -- Validate snapshot inputs.
    IF p_resource IS NULL
       OR p_resource NOT IN ('orders', 'payments')
       OR p_external_id IS NULL
       OR length(p_external_id) NOT BETWEEN 1 AND 128
       OR p_payload IS NULL
       OR jsonb_typeof(p_payload) <> 'object'
       OR p_payload->>'id' IS DISTINCT FROM p_external_id
       OR p_sha256 IS NULL
       OR p_sha256 !~ '^[0-9a-f]{64}$'
       OR p_source_endpoint IS NULL
       OR p_source_endpoint NOT IN ('/orders', '/payments')
       OR p_source_endpoint IS DISTINCT FROM '/' || p_resource
    THEN
        RAISE EXCEPTION 'Invalid snapshot input';
    END IF;

    -- Validate the supplied hash against the actual payload.
    IF p_sha256 IS DISTINCT FROM encode(
        extensions.digest(
            convert_to(p_payload::text, 'UTF8'),
            'sha256'
        ),
        'hex'
    ) THEN
        RAISE EXCEPTION 'Snapshot SHA-256 mismatch';
    END IF;

    -- Insert immutable raw snapshot if not already present.
    INSERT INTO rb04.raw_objects (
        merchant_id,
        resource,
        external_id,
        payload,
        sha256,
        source_endpoint
    )
    VALUES (
        p_merchant_id,
        p_resource,
        p_external_id,
        p_payload,
        p_sha256,
        p_source_endpoint
    )
    ON CONFLICT (
        merchant_id,
        resource,
        external_id,
        sha256
    ) DO NOTHING
    RETURNING id INTO v_id;

    RETURN jsonb_build_object(
        'inserted', v_id IS NOT NULL
    );
END;
$_$;


ALTER FUNCTION public.rb04_insert_raw_dev(p_merchant_id uuid, p_resource text, p_external_id text, p_payload jsonb, p_sha256 text, p_source_endpoint text) OWNER TO postgres;

--
-- Name: rb04_run_normalization_dev(integer); Type: FUNCTION; Schema: public; Owner: postgres
--

CREATE FUNCTION public.rb04_run_normalization_dev(p_batch_size integer DEFAULT 100) RETURNS jsonb
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO ''
    AS $$
BEGIN
    IF auth.role() IS DISTINCT FROM 'service_role' THEN
        RAISE EXCEPTION
            'Service role required';
    END IF;

    IF p_batch_size IS NULL
       OR p_batch_size < 1
       OR p_batch_size > 100
    THEN
        RAISE EXCEPTION
            'Invalid batch size';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM rb04.merchants
        WHERE id =
            '44b7802c-9152-4a58-a81f-b12280f809e7'::uuid
          AND clover_merchant_id = 'X3MHXR2NA6FG1'
          AND enabled = false
    ) THEN
        RAISE EXCEPTION
            'DEV safeguard failed';
    END IF;

    RETURN rb04.run_normalization_dev(
        p_batch_size
    );
END;
$$;


ALTER FUNCTION public.rb04_run_normalization_dev(p_batch_size integer) OWNER TO postgres;

--
-- Name: audit_rejection_retry(); Type: FUNCTION; Schema: rb04; Owner: postgres
--

CREATE FUNCTION rb04.audit_rejection_retry() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
BEGIN
    IF NEW.retry_count <= OLD.retry_count THEN
        RETURN NEW;
    END IF;

    INSERT INTO rb04.normalization_retry_attempts (
        rejection_id,
        merchant_id,
        previous_status,
        resulting_status,
        outcome,
        reason,
        retry_number
    )
    VALUES (
        NEW.id,
        NEW.merchant_id,
        OLD.status,
        NEW.status,
        CASE
            WHEN NEW.status = 'RESOLVED'
                THEN 'RESOLVED'
            WHEN NEW.status = OLD.status
                THEN 'REVIEW_REQUIRED'
            ELSE 'NO_CHANGE'
        END,
        NEW.resolution_notes,
        NEW.retry_count
    );

    RETURN NEW;
END;
$$;


ALTER FUNCTION rb04.audit_rejection_retry() OWNER TO postgres;

--
-- Name: capture_normalization_rejections(); Type: FUNCTION; Schema: rb04; Owner: postgres
--

CREATE FUNCTION rb04.capture_normalization_rejections() RETURNS trigger
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
DECLARE
    v_error jsonb;
    v_raw_id bigint;
    v_external_id text;
    v_reason text;
BEGIN
    -- Only process completed runs containing rejections.
    IF NEW.status NOT IN ('PARTIAL', 'COMPLETE')
       OR NEW.rejected = 0
       OR NEW.error_details IS NULL
       OR jsonb_typeof(NEW.error_details) <> 'array'
    THEN
        RETURN NEW;
    END IF;

    FOR v_error IN
        SELECT value
        FROM jsonb_array_elements(NEW.error_details)
    LOOP
        -- Ignore malformed audit entries.
        IF jsonb_typeof(v_error) <> 'object'
           OR COALESCE(v_error->>'raw_id', '') !~ '^[0-9]{1,18}$'
        THEN
            CONTINUE;
        END IF;

        v_raw_id := (v_error->>'raw_id')::bigint;
        v_external_id := v_error->>'clover_id';
        v_reason := v_error->>'reason';

        -- Only accept records belonging to the run's
        -- merchant and resource.
        INSERT INTO rb04.normalization_rejections (
            merchant_id,
            raw_id,
            resource,
            external_id,
            reason,
            status,
            last_detected_at
        )
        SELECT
            NEW.merchant_id,
            r.id,
            NEW.resource,
            r.external_id,
            COALESCE(v_reason, 'UNKNOWN'),
            'OPEN',
            now()
        FROM rb04.raw_objects r
        WHERE r.id = v_raw_id
          AND r.merchant_id = NEW.merchant_id
          AND r.resource = NEW.resource
          AND r.external_id IS NOT DISTINCT FROM v_external_id
        ON CONFLICT (merchant_id, raw_id)
        DO UPDATE SET
            reason = EXCLUDED.reason,
            last_detected_at = now()
        WHERE rb04.normalization_rejections.status
              IN ('OPEN', 'RETRY_PENDING');
    END LOOP;

    RETURN NEW;
END;
$_$;


ALTER FUNCTION rb04.capture_normalization_rejections() OWNER TO postgres;

--
-- Name: normalize_batch_dev(text, integer); Type: FUNCTION; Schema: rb04; Owner: postgres
--

CREATE FUNCTION rb04.normalize_batch_dev(p_resource text, p_limit integer DEFAULT 100) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
DECLARE
    v_merchant constant uuid :=
        '44b7802c-9152-4a58-a81f-b12280f809e7'::uuid;

    v_cursor bigint;
    v_cursor_end bigint;
    v_run_id bigint;

    v_scanned integer := 0;
    v_inserted integer := 0;
    v_updated integer := 0;
    v_unchanged integer := 0;
    v_rejected integer := 0;

    v_affected integer;
    v_exists boolean;
    v_newer boolean;
    v_reason text;

    v_amount bigint;
    v_tax bigint;
    v_tip bigint;
    v_created bigint;
    v_modified bigint;

    v_old_modified bigint;
    v_old_observed timestamptz;

    v_errors jsonb := '[]'::jsonb;

    r record;
BEGIN
    IF p_resource NOT IN ('orders', 'payments')
       OR p_resource IS NULL
    THEN
        RAISE EXCEPTION 'Invalid resource';
    END IF;

    IF p_limit IS NULL OR p_limit < 1 OR p_limit > 1000 THEN
        RAISE EXCEPTION 'Limit must be between 1 and 1000';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM rb04.merchants
        WHERE id = v_merchant
          AND clover_merchant_id = 'X3MHXR2NA6FG1'
          AND enabled = false
    ) THEN
        RAISE EXCEPTION 'DEV merchant safeguard failed';
    END IF;

    -- Serialize batches for the same merchant/resource.
    INSERT INTO rb04.normalization_checkpoints (
        merchant_id, resource, last_raw_id
    )
    VALUES (v_merchant, p_resource, 0)
    ON CONFLICT (merchant_id, resource) DO NOTHING;

    SELECT last_raw_id
    INTO v_cursor
    FROM rb04.normalization_checkpoints
    WHERE merchant_id = v_merchant
      AND resource = p_resource
    FOR UPDATE;

    v_cursor_end := v_cursor;

    INSERT INTO rb04.normalization_runs (
        merchant_id,
        resource,
        status,
        cursor_start
    )
    VALUES (
        v_merchant,
        p_resource,
        'RUNNING',
        v_cursor
    )
    RETURNING id INTO v_run_id;

    FOR r IN
        SELECT id, external_id, payload, observed_at
        FROM rb04.raw_objects
        WHERE merchant_id = v_merchant
          AND resource = p_resource
          AND id > v_cursor
        ORDER BY id
        LIMIT p_limit
    LOOP
        v_scanned := v_scanned + 1;
        v_cursor_end := r.id;
        v_reason := NULL;

        -- Validate source identity.
        IF jsonb_typeof(r.payload) <> 'object'
           OR r.payload->>'id'
              IS DISTINCT FROM r.external_id
        THEN
            v_reason := 'INVALID_PAYLOAD_OR_ID';
        END IF;

        -- Validate amount and timestamps.
        IF v_reason IS NULL THEN
            IF p_resource = 'orders' THEN
                IF r.payload->>'total' IS NULL
                   OR r.payload->>'total'
                      !~ '^[0-9]{1,15}$'
                THEN
                    v_reason := 'INVALID_ORDER_TOTAL';
                END IF;
            ELSE
                IF r.payload->>'amount' IS NULL
                   OR r.payload->>'amount'
                      !~ '^[0-9]{1,15}$'
                THEN
                    v_reason := 'INVALID_PAYMENT_AMOUNT';
                END IF;

                IF v_reason IS NULL AND (
                    (
                        r.payload->>'taxAmount' IS NOT NULL
                        AND r.payload->>'taxAmount'
                            !~ '^[0-9]{1,15}$'
                    )
                    OR
                    (
                        r.payload->>'tipAmount' IS NOT NULL
                        AND r.payload->>'tipAmount'
                            !~ '^[0-9]{1,15}$'
                    )
                ) THEN
                    v_reason := 'INVALID_TAX_OR_TIP';
                END IF;
            END IF;
        END IF;

        IF v_reason IS NULL AND (
            (
                r.payload->>'createdTime' IS NOT NULL
                AND r.payload->>'createdTime'
                    !~ '^[0-9]{1,15}$'
            )
            OR
            (
                r.payload->>'modifiedTime' IS NOT NULL
                AND r.payload->>'modifiedTime'
                    !~ '^[0-9]{1,15}$'
            )
        ) THEN
            v_reason := 'INVALID_TIMESTAMP';
        END IF;

        IF v_reason IS NOT NULL THEN
            v_rejected := v_rejected + 1;

            v_errors := v_errors ||
                jsonb_build_array(
                    jsonb_build_object(
                        'raw_id', r.id,
                        'clover_id', r.external_id,
                        'reason', v_reason
                    )
                );

            CONTINUE;
        END IF;

        v_created :=
            (r.payload->>'createdTime')::bigint;
        v_modified :=
            (r.payload->>'modifiedTime')::bigint;

        IF p_resource = 'orders' THEN
            v_amount :=
                (r.payload->>'total')::bigint;
            v_tax := NULL;
            v_tip := NULL;

            SELECT
                modified_ms, observed_at
            INTO v_old_modified, v_old_observed
            FROM rb04.orders
            WHERE merchant_id = v_merchant
              AND clover_id = r.external_id;

        ELSE
            v_amount :=
                (r.payload->>'amount')::bigint;
            v_tax :=
                (r.payload->>'taxAmount')::bigint;
            v_tip :=
                (r.payload->>'tipAmount')::bigint;

            SELECT
                modified_ms, observed_at
            INTO v_old_modified, v_old_observed
            FROM rb04.payments
            WHERE merchant_id = v_merchant
              AND clover_id = r.external_id;
        END IF;

        v_exists := FOUND;

        IF NOT v_exists THEN
            IF p_resource = 'orders' THEN
                INSERT INTO rb04.orders (
                    merchant_id, clover_id,
                    state, payment_state,
                    total_cents, created_ms, modified_ms,
                    employee_clover_id, device_clover_id,
                    note_present, observed_at
                )
                VALUES (
                    v_merchant,
                    r.external_id,
                    r.payload->>'state',
                    r.payload->>'paymentState',
                    v_amount,
                    v_created,
                    v_modified,
                    r.payload#>>'{employee,id}',
                    r.payload#>>'{device,id}',
                    NULLIF(
                        BTRIM(r.payload->>'note'), ''
                    ) IS NOT NULL,
                    r.observed_at
                )
                ON CONFLICT DO NOTHING;
            ELSE
                INSERT INTO rb04.payments (
                    merchant_id, clover_id, order_id,
                    employee_clover_id, tender_clover_id,
                    amount_cents, tax_cents, tip_cents,
                    result, created_ms, modified_ms,
                    observed_at
                )
                VALUES (
                    v_merchant,
                    r.external_id,
                    r.payload#>>'{order,id}',
                    r.payload#>>'{employee,id}',
                    r.payload#>>'{tender,id}',
                    v_amount,
                    v_tax,
                    v_tip,
                    r.payload->>'result',
                    v_created,
                    v_modified,
                    r.observed_at
                )
                ON CONFLICT DO NOTHING;
            END IF;

            GET DIAGNOSTICS v_affected = ROW_COUNT;

            IF v_affected = 1 THEN
                v_inserted := v_inserted + 1;
            ELSE
                v_unchanged := v_unchanged + 1;
            END IF;

            CONTINUE;
        END IF;

        v_newer :=
            COALESCE(v_modified, -1)
                > COALESCE(v_old_modified, -1)
            OR (
                v_modified IS NOT DISTINCT FROM
                    v_old_modified
                AND r.observed_at > v_old_observed
            );

        IF NOT v_newer THEN
            v_unchanged := v_unchanged + 1;
            CONTINUE;
        END IF;

        IF p_resource = 'orders' THEN
            UPDATE rb04.orders AS target
            SET
                state = r.payload->>'state',
                payment_state =
                    r.payload->>'paymentState',
                total_cents = v_amount,
                created_ms = v_created,
                modified_ms = v_modified,
                employee_clover_id =
                    r.payload#>>'{employee,id}',
                device_clover_id =
                    r.payload#>>'{device,id}',
                note_present =
                    NULLIF(
                        BTRIM(r.payload->>'note'), ''
                    ) IS NOT NULL,
                observed_at = r.observed_at
            WHERE target.merchant_id = v_merchant
              AND target.clover_id = r.external_id
              AND (
                  COALESCE(v_modified, -1)
                    > COALESCE(target.modified_ms, -1)
                  OR (
                      v_modified IS NOT DISTINCT FROM
                          target.modified_ms
                      AND r.observed_at > target.observed_at
                  )
              );
        ELSE
            UPDATE rb04.payments AS target
            SET
                order_id =
                    r.payload#>>'{order,id}',
                employee_clover_id =
                    r.payload#>>'{employee,id}',
                tender_clover_id =
                    r.payload#>>'{tender,id}',
                amount_cents = v_amount,
                tax_cents = v_tax,
                tip_cents = v_tip,
                result = r.payload->>'result',
                created_ms = v_created,
                modified_ms = v_modified,
                observed_at = r.observed_at
            WHERE target.merchant_id = v_merchant
              AND target.clover_id = r.external_id
              AND (
                  COALESCE(v_modified, -1)
                    > COALESCE(target.modified_ms, -1)
                  OR (
                      v_modified IS NOT DISTINCT FROM
                          target.modified_ms
                      AND r.observed_at > target.observed_at
                  )
              );
        END IF;

        GET DIAGNOSTICS v_affected = ROW_COUNT;

        IF v_affected = 1 THEN
            v_updated := v_updated + 1;
        ELSE
            v_unchanged := v_unchanged + 1;
        END IF;
    END LOOP;

    UPDATE rb04.normalization_checkpoints
    SET
        last_raw_id = v_cursor_end,
        last_processed_at = now(),
        updated_at = now()
    WHERE merchant_id = v_merchant
      AND resource = p_resource;

    UPDATE rb04.normalization_runs
    SET
        completed_at = now(),
        status = CASE
            WHEN v_rejected > 0 THEN 'PARTIAL'
            ELSE 'COMPLETE'
        END,
        cursor_end = v_cursor_end,
        scanned = v_scanned,
        inserted = v_inserted,
        updated = v_updated,
        unchanged = v_unchanged,
        rejected = v_rejected,
        error_details = v_errors
    WHERE id = v_run_id;

    RETURN jsonb_build_object(
        'run_id', v_run_id,
        'resource', p_resource,
        'cursor_start', v_cursor,
        'cursor_end', v_cursor_end,
        'scanned', v_scanned,
        'inserted', v_inserted,
        'updated', v_updated,
        'unchanged', v_unchanged,
        'rejected', v_rejected,
        'status', CASE
            WHEN v_rejected > 0 THEN 'PARTIAL'
            ELSE 'COMPLETE'
        END
    );
END;
$_$;


ALTER FUNCTION rb04.normalize_batch_dev(p_resource text, p_limit integer) OWNER TO postgres;

--
-- Name: normalize_sample_dev(boolean); Type: FUNCTION; Schema: rb04; Owner: postgres
--

CREATE FUNCTION rb04.normalize_sample_dev(p_apply boolean DEFAULT false) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
DECLARE
    v_merchant uuid :=
        '44b7802c-9152-4a58-a81f-b12280f809e7'::uuid;
    r record;
    v_orders integer := 0;
    v_payments integer := 0;
    v_changes integer := 0;
    v_rows integer;
    v_amount text;
    v_created text;
    v_modified text;
    v_tax text;
    v_tip text;
BEGIN
    -- DEV safety: the merchant must remain disabled.
    IF NOT EXISTS (
        SELECT 1
        FROM rb04.merchants
        WHERE id = v_merchant
          AND clover_merchant_id = 'X3MHXR2NA6FG1'
          AND enabled = false
    ) THEN
        RAISE EXCEPTION 'DEV merchant safeguard failed';
    END IF;

    -- First validate all source records before any writes.
    FOR r IN
        SELECT DISTINCT ON (merchant_id, resource, external_id)
            resource, external_id, payload, observed_at
        FROM rb04.raw_objects
        WHERE merchant_id = v_merchant
          AND resource IN ('orders', 'payments')
        ORDER BY merchant_id, resource, external_id,
                 observed_at DESC, id DESC
    LOOP
        IF r.payload->>'id' IS DISTINCT FROM r.external_id THEN
            RAISE EXCEPTION 'Clover ID mismatch';
        END IF;

        v_amount := CASE WHEN r.resource = 'orders'
            THEN r.payload->>'total'
            ELSE r.payload->>'amount' END;
        v_created := r.payload->>'createdTime';
        v_modified := r.payload->>'modifiedTime';
        v_tax := r.payload->>'taxAmount';
        v_tip := r.payload->>'tipAmount';

        IF v_amount IS NULL
           OR v_amount !~ '^[0-9]{1,15}$'
           OR (v_created IS NOT NULL
               AND v_created !~ '^[0-9]{1,15}$')
           OR (v_modified IS NOT NULL
               AND v_modified !~ '^[0-9]{1,15}$')
           OR (v_tax IS NOT NULL
               AND v_tax !~ '^[0-9]{1,15}$')
           OR (v_tip IS NOT NULL
               AND v_tip !~ '^[0-9]{1,15}$')
        THEN
            RAISE EXCEPTION 'Invalid numeric field for %',
                r.external_id;
        END IF;

        IF r.resource = 'orders' THEN
            v_orders := v_orders + 1;
        ELSE
            v_payments := v_payments + 1;
        END IF;
    END LOOP;

    -- This function is restricted to our first 10 records.
    IF v_orders <> 5 OR v_payments <> 5 THEN
        RAISE EXCEPTION
            'Expected 5 orders and 5 payments; found % and %',
            v_orders, v_payments;
    END IF;

    IF NOT p_apply THEN
        RETURN jsonb_build_object(
            'mode', 'PREVIEW',
            'orders', v_orders,
            'payments', v_payments,
            'writes', 0,
            'validation', 'PASS'
        );
    END IF;

    -- Normalize orders.
    INSERT INTO rb04.orders AS target (
        merchant_id, clover_id, state, payment_state,
        total_cents, created_ms, modified_ms,
        employee_clover_id, device_clover_id,
        note_present, observed_at
    )
    SELECT
        merchant_id,
        external_id,
        payload->>'state',
        payload->>'paymentState',
        (payload->>'total')::bigint,
        (payload->>'createdTime')::bigint,
        (payload->>'modifiedTime')::bigint,
        payload#>>'{employee,id}',
        payload#>>'{device,id}',
        NULLIF(BTRIM(payload->>'note'), '') IS NOT NULL,
        observed_at
    FROM (
        SELECT DISTINCT ON (merchant_id, resource, external_id)
            *
        FROM rb04.raw_objects
        WHERE merchant_id = v_merchant
          AND resource = 'orders'
        ORDER BY merchant_id, resource, external_id,
                 observed_at DESC, id DESC
    ) s
    ON CONFLICT (merchant_id, clover_id)
    DO UPDATE SET
        state = EXCLUDED.state,
        payment_state = EXCLUDED.payment_state,
        total_cents = EXCLUDED.total_cents,
        created_ms = EXCLUDED.created_ms,
        modified_ms = EXCLUDED.modified_ms,
        employee_clover_id = EXCLUDED.employee_clover_id,
        device_clover_id = EXCLUDED.device_clover_id,
        note_present = EXCLUDED.note_present,
        observed_at = EXCLUDED.observed_at
    WHERE
        COALESCE(EXCLUDED.modified_ms, -1)
          > COALESCE(target.modified_ms, -1)
        OR (
            EXCLUDED.modified_ms IS NOT DISTINCT FROM target.modified_ms
            AND EXCLUDED.observed_at > target.observed_at
        );

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_changes := v_changes + v_rows;

    -- Normalize payments. AUTH remains AUTH.
    INSERT INTO rb04.payments AS target (
        merchant_id, clover_id, order_id,
        employee_clover_id, tender_clover_id,
        amount_cents, tax_cents, tip_cents,
        result, created_ms, modified_ms, observed_at
    )
    SELECT
        merchant_id,
        external_id,
        payload#>>'{order,id}',
        payload#>>'{employee,id}',
        payload#>>'{tender,id}',
        (payload->>'amount')::bigint,
        (payload->>'taxAmount')::bigint,
        (payload->>'tipAmount')::bigint,
        payload->>'result',
        (payload->>'createdTime')::bigint,
        (payload->>'modifiedTime')::bigint,
        observed_at
    FROM (
        SELECT DISTINCT ON (merchant_id, resource, external_id)
            *
        FROM rb04.raw_objects
        WHERE merchant_id = v_merchant
          AND resource = 'payments'
        ORDER BY merchant_id, resource, external_id,
                 observed_at DESC, id DESC
    ) s
    ON CONFLICT (merchant_id, clover_id)
    DO UPDATE SET
        order_id = EXCLUDED.order_id,
        employee_clover_id = EXCLUDED.employee_clover_id,
        tender_clover_id = EXCLUDED.tender_clover_id,
        amount_cents = EXCLUDED.amount_cents,
        tax_cents = EXCLUDED.tax_cents,
        tip_cents = EXCLUDED.tip_cents,
        result = EXCLUDED.result,
        created_ms = EXCLUDED.created_ms,
        modified_ms = EXCLUDED.modified_ms,
        observed_at = EXCLUDED.observed_at
    WHERE
        COALESCE(EXCLUDED.modified_ms, -1)
          > COALESCE(target.modified_ms, -1)
        OR (
            EXCLUDED.modified_ms IS NOT DISTINCT FROM target.modified_ms
            AND EXCLUDED.observed_at > target.observed_at
        );

    GET DIAGNOSTICS v_rows = ROW_COUNT;
    v_changes := v_changes + v_rows;

    RETURN jsonb_build_object(
        'mode', 'APPLY',
        'orders', v_orders,
        'payments', v_payments,
        'rows_inserted_or_updated', v_changes,
        'validation', 'PASS'
    );
END;
$_$;


ALTER FUNCTION rb04.normalize_sample_dev(p_apply boolean) OWNER TO postgres;

--
-- Name: normalize_transactions_dev(boolean, integer); Type: FUNCTION; Schema: rb04; Owner: postgres
--

CREATE FUNCTION rb04.normalize_transactions_dev(p_apply boolean DEFAULT false, p_limit integer DEFAULT 100) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
DECLARE
    v_merchant constant uuid :=
        '44b7802c-9152-4a58-a81f-b12280f809e7'::uuid;

    r record;
    v_existing record;

    v_scanned integer := 0;
    v_inserted integer := 0;
    v_updated integer := 0;
    v_unchanged integer := 0;
    v_rejected integer := 0;

    v_amount bigint;
    v_tax bigint;
    v_tip bigint;
    v_created bigint;
    v_modified bigint;

    v_old_modified bigint;
    v_old_observed timestamptz;

    v_newer boolean;
    v_reason text;

    v_rejections jsonb := '[]'::jsonb;
BEGIN
    IF p_limit < 1 OR p_limit > 1000 THEN
        RAISE EXCEPTION 'Limit must be between 1 and 1000';
    END IF;

    -- Development merchant safeguard.
    IF NOT EXISTS (
        SELECT 1
        FROM rb04.merchants
        WHERE id = v_merchant
          AND clover_merchant_id = 'X3MHXR2NA6FG1'
          AND enabled = false
    ) THEN
        RAISE EXCEPTION 'DEV merchant safeguard failed';
    END IF;

    FOR r IN
        SELECT DISTINCT ON (
            merchant_id,
            resource,
            external_id
        )
            merchant_id,
            resource,
            external_id,
            payload,
            observed_at
        FROM rb04.raw_objects
        WHERE merchant_id = v_merchant
          AND resource IN ('orders', 'payments')
        ORDER BY
            merchant_id,
            resource,
            external_id,
            observed_at DESC,
            id DESC
        LIMIT p_limit
    LOOP
        v_scanned := v_scanned + 1;
        v_reason := NULL;

        -- Basic source validation.
        IF jsonb_typeof(r.payload) <> 'object'
           OR r.payload->>'id'
                IS DISTINCT FROM r.external_id
        THEN
            v_reason := 'INVALID_ID_OR_PAYLOAD';
        END IF;

        -- Validate numeric fields before casting.
        IF v_reason IS NULL THEN
            IF r.resource = 'orders' THEN
                IF r.payload->>'total' IS NULL
                   OR r.payload->>'total'
                        !~ '^[0-9]{1,15}$'
                THEN
                    v_reason := 'INVALID_ORDER_TOTAL';
                END IF;
            ELSE
                IF r.payload->>'amount' IS NULL
                   OR r.payload->>'amount'
                        !~ '^[0-9]{1,15}$'
                THEN
                    v_reason := 'INVALID_PAYMENT_AMOUNT';
                END IF;

                IF v_reason IS NULL AND (
                    (r.payload->>'taxAmount' IS NOT NULL
                     AND r.payload->>'taxAmount'
                         !~ '^[0-9]{1,15}$')
                    OR
                    (r.payload->>'tipAmount' IS NOT NULL
                     AND r.payload->>'tipAmount'
                         !~ '^[0-9]{1,15}$')
                ) THEN
                    v_reason := 'INVALID_TAX_OR_TIP';
                END IF;
            END IF;
        END IF;

        IF v_reason IS NULL AND (
            (r.payload->>'createdTime' IS NOT NULL
             AND r.payload->>'createdTime'
                 !~ '^[0-9]{1,15}$')
            OR
            (r.payload->>'modifiedTime' IS NOT NULL
             AND r.payload->>'modifiedTime'
                 !~ '^[0-9]{1,15}$')
        ) THEN
            v_reason := 'INVALID_TIMESTAMP';
        END IF;

        IF v_reason IS NOT NULL THEN
            v_rejected := v_rejected + 1;

            v_rejections := v_rejections ||
                jsonb_build_array(
                    jsonb_build_object(
                        'resource', r.resource,
                        'id', r.external_id,
                        'reason', v_reason
                    )
                );

            CONTINUE;
        END IF;

        v_created :=
            (r.payload->>'createdTime')::bigint;
        v_modified :=
            (r.payload->>'modifiedTime')::bigint;

        IF r.resource = 'orders' THEN
            v_amount :=
                (r.payload->>'total')::bigint;
            v_tax := NULL;
            v_tip := NULL;

            SELECT
                modified_ms,
                observed_at
            INTO v_existing
            FROM rb04.orders
            WHERE merchant_id = v_merchant
              AND clover_id = r.external_id;

        ELSE
            v_amount :=
                (r.payload->>'amount')::bigint;
            v_tax :=
                (r.payload->>'taxAmount')::bigint;
            v_tip :=
                (r.payload->>'tipAmount')::bigint;

            SELECT
                modified_ms,
                observed_at
            INTO v_existing
            FROM rb04.payments
            WHERE merchant_id = v_merchant
              AND clover_id = r.external_id;
        END IF;

        IF NOT FOUND THEN
            IF p_apply THEN
                IF r.resource = 'orders' THEN
                    INSERT INTO rb04.orders (
                        merchant_id,
                        clover_id,
                        state,
                        payment_state,
                        total_cents,
                        created_ms,
                        modified_ms,
                        employee_clover_id,
                        device_clover_id,
                        note_present,
                        observed_at
                    )
                    VALUES (
                        v_merchant,
                        r.external_id,
                        r.payload->>'state',
                        r.payload->>'paymentState',
                        v_amount,
                        v_created,
                        v_modified,
                        r.payload#>>'{employee,id}',
                        r.payload#>>'{device,id}',
                        NULLIF(
                            BTRIM(r.payload->>'note'),
                            ''
                        ) IS NOT NULL,
                        r.observed_at
                    )
                    ON CONFLICT DO NOTHING;
                ELSE
                    INSERT INTO rb04.payments (
                        merchant_id,
                        clover_id,
                        order_id,
                        employee_clover_id,
                        tender_clover_id,
                        amount_cents,
                        tax_cents,
                        tip_cents,
                        result,
                        created_ms,
                        modified_ms,
                        observed_at
                    )
                    VALUES (
                        v_merchant,
                        r.external_id,
                        r.payload#>>'{order,id}',
                        r.payload#>>'{employee,id}',
                        r.payload#>>'{tender,id}',
                        v_amount,
                        v_tax,
                        v_tip,
                        r.payload->>'result',
                        v_created,
                        v_modified,
                        r.observed_at
                    )
                    ON CONFLICT DO NOTHING;
                END IF;
            END IF;

            v_inserted := v_inserted + 1;
            CONTINUE;
        END IF;

        v_old_modified := v_existing.modified_ms;
        v_old_observed := v_existing.observed_at;

        v_newer :=
            COALESCE(v_modified, -1)
                > COALESCE(v_old_modified, -1)
            OR (
                v_modified IS NOT DISTINCT FROM
                    v_old_modified
                AND r.observed_at > v_old_observed
            );

        IF NOT v_newer THEN
            v_unchanged := v_unchanged + 1;
            CONTINUE;
        END IF;

        IF p_apply THEN
            IF r.resource = 'orders' THEN
                UPDATE rb04.orders
                SET
                    state = r.payload->>'state',
                    payment_state =
                        r.payload->>'paymentState',
                    total_cents = v_amount,
                    created_ms = v_created,
                    modified_ms = v_modified,
                    employee_clover_id =
                        r.payload#>>'{employee,id}',
                    device_clover_id =
                        r.payload#>>'{device,id}',
                    note_present =
                        NULLIF(
                            BTRIM(r.payload->>'note'),
                            ''
                        ) IS NOT NULL,
                    observed_at = r.observed_at
                WHERE merchant_id = v_merchant
                  AND clover_id = r.external_id
                  AND (
                      COALESCE(v_modified, -1)
                          > COALESCE(modified_ms, -1)
                      OR (
                          v_modified IS NOT DISTINCT
                              FROM modified_ms
                          AND r.observed_at > observed_at
                      )
                  );
            ELSE
                UPDATE rb04.payments
                SET
                    order_id =
                        r.payload#>>'{order,id}',
                    employee_clover_id =
                        r.payload#>>'{employee,id}',
                    tender_clover_id =
                        r.payload#>>'{tender,id}',
                    amount_cents = v_amount,
                    tax_cents = v_tax,
                    tip_cents = v_tip,
                    result = r.payload->>'result',
                    created_ms = v_created,
                    modified_ms = v_modified,
                    observed_at = r.observed_at
                WHERE merchant_id = v_merchant
                  AND clover_id = r.external_id
                  AND (
                      COALESCE(v_modified, -1)
                          > COALESCE(modified_ms, -1)
                      OR (
                          v_modified IS NOT DISTINCT
                              FROM modified_ms
                          AND r.observed_at > observed_at
                      )
                  );
            END IF;
        END IF;

        v_updated := v_updated + 1;
    END LOOP;

    RETURN jsonb_build_object(
        'mode',
            CASE WHEN p_apply
                THEN 'APPLY'
                ELSE 'PREVIEW'
            END,
        'scanned', v_scanned,
        'inserted', v_inserted,
        'updated', v_updated,
        'unchanged', v_unchanged,
        'rejected', v_rejected,
        'rejections', v_rejections
    );
END;
$_$;


ALTER FUNCTION rb04.normalize_transactions_dev(p_apply boolean, p_limit integer) OWNER TO postgres;

--
-- Name: retry_rejection_dev(bigint); Type: FUNCTION; Schema: rb04; Owner: postgres
--

CREATE FUNCTION rb04.retry_rejection_dev(p_rejection_id bigint) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $_$
DECLARE
    v_merchant constant uuid :=
        '44b7802c-9152-4a58-a81f-b12280f809e7'::uuid;

    v_rejection rb04.normalization_rejections%ROWTYPE;
    v_raw rb04.raw_objects%ROWTYPE;
    v_latest rb04.raw_objects%ROWTYPE;

    v_normalized_modified bigint;
    v_normalized_observed timestamptz;

    v_source_modified bigint;
    v_status text;
    v_reason text;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM rb04.merchants
        WHERE id = v_merchant
          AND clover_merchant_id = 'X3MHXR2NA6FG1'
          AND enabled = false
    ) THEN
        RAISE EXCEPTION 'DEV merchant safeguard failed';
    END IF;

    SELECT *
    INTO v_rejection
    FROM rb04.normalization_rejections
    WHERE id = p_rejection_id
      AND merchant_id = v_merchant
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Rejection not found';
    END IF;

    IF v_rejection.status IN ('RESOLVED', 'IGNORED') THEN
        RETURN jsonb_build_object(
            'rejection_id', p_rejection_id,
            'status', v_rejection.status,
            'action', 'NO_CHANGE'
        );
    END IF;

    SELECT *
    INTO v_raw
    FROM rb04.raw_objects
    WHERE id = v_rejection.raw_id
      AND merchant_id = v_merchant
      AND resource = v_rejection.resource
      AND external_id = v_rejection.external_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Original raw snapshot not found';
    END IF;

    SELECT *
    INTO v_latest
    FROM rb04.raw_objects
    WHERE merchant_id = v_merchant
      AND resource = v_rejection.resource
      AND external_id = v_rejection.external_id
      AND id > v_raw.id
    ORDER BY observed_at DESC, id DESC
    LIMIT 1;

    IF NOT FOUND THEN
        v_status := 'OPEN';
        v_reason := 'NO_NEWER_SNAPSHOT';
    ELSIF v_latest.payload->>'id'
           IS DISTINCT FROM v_latest.external_id
    THEN
        v_status := 'OPEN';
        v_reason := 'NEWER_SNAPSHOT_ID_MISMATCH';
    ELSIF COALESCE(
        v_latest.payload->>'modifiedTime', ''
    ) !~ '^[0-9]{1,15}$'
    THEN
        v_status := 'OPEN';
        v_reason := 'NEWER_SNAPSHOT_INVALID_TIMESTAMP';
    ELSE
        v_source_modified :=
            (v_latest.payload->>'modifiedTime')::bigint;

        IF v_rejection.resource = 'orders' THEN
            SELECT modified_ms, observed_at
            INTO v_normalized_modified, v_normalized_observed
            FROM rb04.orders
            WHERE merchant_id = v_merchant
              AND clover_id = v_rejection.external_id;
        ELSE
            SELECT modified_ms, observed_at
            INTO v_normalized_modified, v_normalized_observed
            FROM rb04.payments
            WHERE merchant_id = v_merchant
              AND clover_id = v_rejection.external_id;
        END IF;

        IF FOUND
           AND v_normalized_modified IS NOT NULL
           AND v_normalized_modified >= v_source_modified
           AND (
               v_normalized_modified > v_source_modified
               OR v_normalized_observed >= v_latest.observed_at
           )
        THEN
            v_status := 'RESOLVED';
            v_reason := 'NEWER_SNAPSHOT_ALREADY_NORMALIZED';
        ELSE
            v_status := 'OPEN';
            v_reason := 'NEWER_SNAPSHOT_NOT_YET_NORMALIZED';
        END IF;
    END IF;

    UPDATE rb04.normalization_rejections
    SET
        status = v_status,
        retry_count = retry_count + 1,
        last_detected_at = now(),
        resolved_at = CASE
            WHEN v_status = 'RESOLVED' THEN now()
            ELSE NULL
        END,
        resolution_notes = v_reason
    WHERE id = p_rejection_id;

    RETURN jsonb_build_object(
        'rejection_id', p_rejection_id,
        'status', v_status,
        'reason', v_reason,
        'action', CASE
            WHEN v_status = 'RESOLVED'
            THEN 'RECONCILED'
            ELSE 'REVIEW_REQUIRED'
        END
    );
END;
$_$;


ALTER FUNCTION rb04.retry_rejection_dev(p_rejection_id bigint) OWNER TO postgres;

--
-- Name: run_normalization_dev(integer); Type: FUNCTION; Schema: rb04; Owner: postgres
--

CREATE FUNCTION rb04.run_normalization_dev(p_batch_size integer DEFAULT 100) RETURNS jsonb
    LANGUAGE plpgsql
    SET search_path TO ''
    AS $$
DECLARE
    v_orders jsonb;
    v_payments jsonb;
    v_started timestamptz := clock_timestamp();
    v_orders_error text;
    v_payments_error text;
BEGIN
    IF p_batch_size IS NULL
       OR p_batch_size < 1
       OR p_batch_size > 500
    THEN
        RAISE EXCEPTION
            'Batch size must be between 1 and 500';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM rb04.merchants
        WHERE id =
          '44b7802c-9152-4a58-a81f-b12280f809e7'::uuid
          AND enabled = false
    ) THEN
        RAISE EXCEPTION
            'DEV merchant safeguard failed';
    END IF;

    -- Each resource runs in its own exception block.
    -- A failure in one does not prevent the other
    -- from being attempted.

    BEGIN
        v_orders :=
            rb04.normalize_batch_dev(
                'orders',
                p_batch_size
            );
    EXCEPTION WHEN OTHERS THEN
        v_orders_error := SQLERRM;
    END;

    BEGIN
        v_payments :=
            rb04.normalize_batch_dev(
                'payments',
                p_batch_size
            );
    EXCEPTION WHEN OTHERS THEN
        v_payments_error := SQLERRM;
    END;

    RETURN jsonb_build_object(
        'environment', 'DEV',
        'started_at', v_started,
        'completed_at', clock_timestamp(),
        'orders', COALESCE(
            v_orders,
            jsonb_build_object(
                'status', 'FAILED',
                'error', v_orders_error
            )
        ),
        'payments', COALESCE(
            v_payments,
            jsonb_build_object(
                'status', 'FAILED',
                'error', v_payments_error
            )
        )
    );
END;
$$;


ALTER FUNCTION rb04.run_normalization_dev(p_batch_size integer) OWNER TO postgres;

SET LOCAL default_tablespace = '';

SET LOCAL default_table_access_method = heap;

--
-- Name: accountability_approval_rules; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.accountability_approval_rules (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    merchant_id uuid NOT NULL,
    event_type text NOT NULL,
    approver_role text NOT NULL,
    max_amount_cents bigint,
    requires_reason boolean DEFAULT true NOT NULL,
    requires_approval boolean DEFAULT true NOT NULL,
    effective_from date NOT NULL,
    effective_to date,
    policy_reference text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT accountability_approval_rules_approver_role_check CHECK ((approver_role = ANY (ARRAY['SHIFT_LEAD'::text, 'MANAGER'::text, 'OWNER'::text]))),
    CONSTRAINT accountability_approval_rules_check CHECK (((effective_to IS NULL) OR (effective_to >= effective_from))),
    CONSTRAINT accountability_approval_rules_event_type_check CHECK ((event_type = ANY (ARRAY['COMP'::text, 'DISCOUNT'::text, 'VOID'::text, 'REFUND'::text, 'OTHER'::text]))),
    CONSTRAINT accountability_approval_rules_max_amount_cents_check CHECK ((max_amount_cents >= 0))
);


ALTER TABLE rb04.accountability_approval_rules OWNER TO postgres;

--
-- Name: raw_objects; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.raw_objects (
    id bigint NOT NULL,
    merchant_id uuid NOT NULL,
    resource text NOT NULL,
    external_id text NOT NULL,
    payload jsonb NOT NULL,
    sha256 text NOT NULL,
    observed_at timestamp with time zone DEFAULT now() NOT NULL,
    source_endpoint text NOT NULL
);


ALTER TABLE rb04.raw_objects OWNER TO postgres;

--
-- Name: accountability_clover_raw_candidates; Type: VIEW; Schema: rb04; Owner: postgres
--

CREATE VIEW rb04.accountability_clover_raw_candidates WITH (security_invoker='true') AS
 WITH raw AS (
         SELECT to_jsonb(r.*) AS row_data
           FROM rb04.raw_objects r
        ), unpacked AS (
         SELECT raw.row_data,
            COALESCE((raw.row_data -> 'payload'::text), (raw.row_data -> 'raw_payload'::text), (raw.row_data -> 'data'::text), (raw.row_data -> 'raw_json'::text)) AS payload,
            COALESCE((raw.row_data ->> 'merchant_id'::text), (raw.row_data ->> 'merchant_uuid'::text)) AS merchant_key,
            COALESCE((raw.row_data ->> 'resource'::text), (raw.row_data ->> 'resource_type'::text), (raw.row_data ->> 'object_type'::text)) AS resource_label,
            COALESCE((raw.row_data ->> 'external_id'::text), (raw.row_data ->> 'clover_id'::text), (raw.row_data ->> 'object_id'::text)) AS external_key,
            COALESCE((raw.row_data ->> 'payload_sha256'::text), (raw.row_data ->> 'sha256'::text)) AS source_hash
           FROM raw
        ), parsed AS (
         SELECT unpacked.row_data,
            unpacked.payload,
            unpacked.merchant_key,
            unpacked.resource_label,
            unpacked.external_key,
            unpacked.source_hash,
                CASE
                    WHEN (jsonb_typeof(unpacked.payload) = 'object'::text) THEN unpacked.payload
                    ELSE NULL::jsonb
                END AS p
           FROM unpacked
        )
 SELECT merchant_key,
    resource_label,
    external_key,
    source_hash,
    (p ->> 'id'::text) AS payload_id,
    (p ->> 'order'::text) AS order_raw,
    ((p -> 'employee'::text) ->> 'id'::text) AS nested_employee_id,
    (p ->> 'employeeId'::text) AS direct_employee_id,
    (p ->> 'tipAmount'::text) AS tip_amount_raw,
    (p ->> 'amount'::text) AS amount_raw,
    (p ->> 'modifiedTime'::text) AS modified_time_raw,
    (p ->> 'createdTime'::text) AS created_time_raw,
        CASE
            WHEN (p IS NULL) THEN 'PAYLOAD_UNAVAILABLE'::text
            WHEN (COALESCE(external_key, (p ->> 'id'::text)) IS NULL) THEN 'MISSING_EXTERNAL_ID'::text
            WHEN (COALESCE(resource_label, ''::text) <> ALL (ARRAY['orders'::text, 'payments'::text])) THEN 'RESOURCE_UNCONFIRMED'::text
            ELSE 'REVIEW_REQUIRED'::text
        END AS mapping_status,
    p AS source_payload
   FROM parsed;


ALTER VIEW rb04.accountability_clover_raw_candidates OWNER TO postgres;

--
-- Name: accountability_events; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.accountability_events (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    merchant_id uuid NOT NULL,
    event_type text NOT NULL,
    source_system text DEFAULT 'CLOVER'::text NOT NULL,
    source_event_key text NOT NULL,
    source_order_id text,
    source_payment_id text,
    source_employee_id text,
    source_employee_name text,
    observed_at timestamp with time zone NOT NULL,
    business_date date NOT NULL,
    amount_cents bigint NOT NULL,
    source_payload_sha256 text,
    source_notes text,
    source_reference text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT accountability_events_amount_cents_check CHECK ((amount_cents >= 0)),
    CONSTRAINT accountability_events_event_type_check CHECK ((event_type = ANY (ARRAY['COMP'::text, 'DISCOUNT'::text, 'VOID'::text, 'REFUND'::text, 'TIP'::text, 'SALE'::text, 'OTHER'::text]))),
    CONSTRAINT accountability_events_source_event_key_check CHECK (((length(source_event_key) >= 1) AND (length(source_event_key) <= 255))),
    CONSTRAINT accountability_events_source_payload_sha256_check CHECK (((source_payload_sha256 IS NULL) OR (source_payload_sha256 ~ '^[0-9a-f]{64}$'::text))),
    CONSTRAINT accountability_events_source_system_check CHECK ((source_system = ANY (ARRAY['CLOVER'::text, 'MANUAL'::text, 'OTHER'::text])))
);


ALTER TABLE rb04.accountability_events OWNER TO postgres;

--
-- Name: accountability_dashboard_daily; Type: VIEW; Schema: rb04; Owner: postgres
--

CREATE VIEW rb04.accountability_dashboard_daily WITH (security_invoker='true') AS
 SELECT merchant_id,
    business_date,
    count(*) FILTER (WHERE (event_type = 'SALE'::text)) AS sales_count,
    COALESCE(sum(amount_cents) FILTER (WHERE (event_type = 'SALE'::text)), (0)::numeric) AS sales_cents,
    COALESCE(sum(amount_cents) FILTER (WHERE (event_type = 'TIP'::text)), (0)::numeric) AS tips_cents,
    count(*) FILTER (WHERE (event_type = 'COMP'::text)) AS comp_count,
    COALESCE(sum(amount_cents) FILTER (WHERE (event_type = 'COMP'::text)), (0)::numeric) AS comp_cents,
    count(*) FILTER (WHERE (event_type = 'DISCOUNT'::text)) AS discount_count,
    COALESCE(sum(amount_cents) FILTER (WHERE (event_type = 'DISCOUNT'::text)), (0)::numeric) AS discount_cents,
    count(*) FILTER (WHERE (event_type = 'VOID'::text)) AS void_count,
    count(*) FILTER (WHERE (event_type = 'REFUND'::text)) AS refund_count
   FROM rb04.accountability_events
  GROUP BY merchant_id, business_date;


ALTER VIEW rb04.accountability_dashboard_daily OWNER TO postgres;

--
-- Name: accountability_weekly_activity; Type: VIEW; Schema: rb04; Owner: postgres
--

CREATE VIEW rb04.accountability_weekly_activity WITH (security_invoker='true') AS
 SELECT merchant_id,
    (business_date - ((EXTRACT(isodow FROM business_date))::integer - 1)) AS week_start_monday,
    source_employee_id,
    source_employee_name,
    event_type,
    count(*) AS event_count,
    sum(amount_cents) AS amount_cents
   FROM rb04.accountability_events e
  GROUP BY merchant_id, (business_date - ((EXTRACT(isodow FROM business_date))::integer - 1)), source_employee_id, source_employee_name, event_type;


ALTER VIEW rb04.accountability_weekly_activity OWNER TO postgres;

--
-- Name: accountability_dashboard_employee_weekly; Type: VIEW; Schema: rb04; Owner: postgres
--

CREATE VIEW rb04.accountability_dashboard_employee_weekly WITH (security_invoker='true') AS
 SELECT merchant_id,
    week_start_monday,
    source_employee_id,
    max(source_employee_name) AS employee_name,
    COALESCE(sum(amount_cents) FILTER (WHERE (event_type = 'SALE'::text)), (0)::numeric) AS sales_cents,
    COALESCE(sum(amount_cents) FILTER (WHERE (event_type = 'TIP'::text)), (0)::numeric) AS tips_cents,
    COALESCE(sum(amount_cents) FILTER (WHERE (event_type = 'COMP'::text)), (0)::numeric) AS comp_cents,
    COALESCE(sum(amount_cents) FILTER (WHERE (event_type = 'DISCOUNT'::text)), (0)::numeric) AS discount_cents,
    (COALESCE(sum(event_count) FILTER (WHERE (event_type = 'VOID'::text)), (0)::numeric))::bigint AS void_count,
    (COALESCE(sum(event_count) FILTER (WHERE (event_type = 'REFUND'::text)), (0)::numeric))::bigint AS refund_count,
    (COALESCE(sum(event_count) FILTER (WHERE (event_type = 'SALE'::text)), (0)::numeric))::bigint AS sale_count
   FROM rb04.accountability_weekly_activity
  GROUP BY merchant_id, week_start_monday, source_employee_id;


ALTER VIEW rb04.accountability_dashboard_employee_weekly OWNER TO postgres;

--
-- Name: accountability_reviews; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.accountability_reviews (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    merchant_id uuid NOT NULL,
    event_id uuid NOT NULL,
    reviewer_employee_id uuid,
    reviewer_display_name text NOT NULL,
    reviewer_role text NOT NULL,
    decision text NOT NULL,
    reason text NOT NULL,
    policy_reference text,
    reviewed_at timestamp with time zone DEFAULT now() NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT accountability_reviews_decision_check CHECK ((decision = ANY (ARRAY['APPROVED'::text, 'REJECTED'::text, 'NEEDS_INFORMATION'::text, 'ESCALATED'::text, 'ACKNOWLEDGED'::text]))),
    CONSTRAINT accountability_reviews_reason_check CHECK (((length(TRIM(BOTH FROM reason)) >= 1) AND (length(TRIM(BOTH FROM reason)) <= 2000))),
    CONSTRAINT accountability_reviews_reviewer_display_name_check CHECK (((length(TRIM(BOTH FROM reviewer_display_name)) >= 1) AND (length(TRIM(BOTH FROM reviewer_display_name)) <= 160))),
    CONSTRAINT accountability_reviews_reviewer_role_check CHECK ((reviewer_role = ANY (ARRAY['SHIFT_LEAD'::text, 'MANAGER'::text, 'OWNER'::text])))
);


ALTER TABLE rb04.accountability_reviews OWNER TO postgres;

--
-- Name: accountability_event_review_status; Type: VIEW; Schema: rb04; Owner: postgres
--

CREATE VIEW rb04.accountability_event_review_status WITH (security_invoker='true') AS
 SELECT e.merchant_id,
    e.id AS event_id,
    e.event_type,
    e.business_date,
    e.source_employee_id,
    e.source_employee_name,
    e.amount_cents,
    r.decision AS latest_decision,
    r.reviewer_role AS latest_reviewer_role,
    r.reviewed_at AS last_reviewed_at,
    (r.id IS NULL) AS awaiting_review
   FROM (rb04.accountability_events e
     LEFT JOIN LATERAL ( SELECT v.id,
            v.decision,
            v.reviewer_role,
            v.reviewed_at
           FROM rb04.accountability_reviews v
          WHERE ((v.merchant_id = e.merchant_id) AND (v.event_id = e.id))
          ORDER BY v.reviewed_at DESC, v.created_at DESC, v.id DESC
         LIMIT 1) r ON (true));


ALTER VIEW rb04.accountability_event_review_status OWNER TO postgres;

--
-- Name: accountability_exceptions; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.accountability_exceptions (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    merchant_id uuid NOT NULL,
    event_id uuid NOT NULL,
    exception_type text NOT NULL,
    severity text DEFAULT 'REVIEW'::text NOT NULL,
    status text DEFAULT 'OPEN'::text NOT NULL,
    explanation text,
    assigned_employee_id uuid,
    opened_at timestamp with time zone DEFAULT now() NOT NULL,
    resolved_at timestamp with time zone,
    resolution_notes text,
    CONSTRAINT accountability_exceptions_check CHECK (((status = ANY (ARRAY['RESOLVED'::text, 'DISMISSED'::text])) = (resolved_at IS NOT NULL))),
    CONSTRAINT accountability_exceptions_exception_type_check CHECK (((length(TRIM(BOTH FROM exception_type)) >= 1) AND (length(TRIM(BOTH FROM exception_type)) <= 100))),
    CONSTRAINT accountability_exceptions_severity_check CHECK ((severity = ANY (ARRAY['INFO'::text, 'REVIEW'::text, 'HIGH'::text]))),
    CONSTRAINT accountability_exceptions_status_check CHECK ((status = ANY (ARRAY['OPEN'::text, 'IN_REVIEW'::text, 'RESOLVED'::text, 'DISMISSED'::text])))
);


ALTER TABLE rb04.accountability_exceptions OWNER TO postgres;

--
-- Name: accountability_dashboard_review_queue; Type: VIEW; Schema: rb04; Owner: postgres
--

CREATE VIEW rb04.accountability_dashboard_review_queue WITH (security_invoker='true') AS
 SELECT e.merchant_id,
    e.id AS event_id,
    e.business_date,
    e.observed_at,
    e.event_type,
    e.source_order_id,
    e.source_payment_id,
    e.source_employee_id,
    e.source_employee_name,
    e.amount_cents,
    e.source_notes,
    r.latest_decision,
    r.latest_reviewer_role,
    r.last_reviewed_at,
    count(x.id) FILTER (WHERE (x.status = ANY (ARRAY['OPEN'::text, 'IN_REVIEW'::text]))) AS active_exceptions,
        CASE max(
            CASE
                WHEN (x.status = ANY (ARRAY['OPEN'::text, 'IN_REVIEW'::text])) THEN
                CASE x.severity
                    WHEN 'HIGH'::text THEN 3
                    WHEN 'REVIEW'::text THEN 2
                    WHEN 'INFO'::text THEN 1
                    ELSE NULL::integer
                END
                ELSE NULL::integer
            END)
            WHEN 3 THEN 'HIGH'::text
            WHEN 2 THEN 'REVIEW'::text
            WHEN 1 THEN 'INFO'::text
            ELSE NULL::text
        END AS highest_exception_severity
   FROM ((rb04.accountability_events e
     JOIN rb04.accountability_event_review_status r ON (((r.event_id = e.id) AND (r.merchant_id = e.merchant_id))))
     LEFT JOIN rb04.accountability_exceptions x ON (((x.event_id = e.id) AND (x.merchant_id = e.merchant_id))))
  WHERE ((e.event_type = ANY (ARRAY['COMP'::text, 'DISCOUNT'::text, 'VOID'::text, 'REFUND'::text])) AND ((r.latest_decision IS NULL) OR (r.latest_decision = ANY (ARRAY['NEEDS_INFORMATION'::text, 'ESCALATED'::text])) OR (x.status = ANY (ARRAY['OPEN'::text, 'IN_REVIEW'::text]))))
  GROUP BY e.merchant_id, e.id, e.business_date, e.observed_at, e.event_type, e.source_order_id, e.source_payment_id, e.source_employee_id, e.source_employee_name, e.amount_cents, e.source_notes, r.latest_decision, r.latest_reviewer_role, r.last_reviewed_at;


ALTER VIEW rb04.accountability_dashboard_review_queue OWNER TO postgres;

--
-- Name: accountability_employees; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.accountability_employees (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    merchant_id uuid NOT NULL,
    clover_employee_id text,
    display_name text NOT NULL,
    employment_status text DEFAULT 'ACTIVE'::text NOT NULL,
    role_name text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT accountability_employees_display_name_check CHECK (((length(TRIM(BOTH FROM display_name)) >= 1) AND (length(TRIM(BOTH FROM display_name)) <= 160))),
    CONSTRAINT accountability_employees_employment_status_check CHECK ((employment_status = ANY (ARRAY['ACTIVE'::text, 'INACTIVE'::text, 'UNKNOWN'::text])))
);


ALTER TABLE rb04.accountability_employees OWNER TO postgres;

--
-- Name: accountability_transform_runs; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.accountability_transform_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    merchant_id uuid NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    status text NOT NULL,
    source_count integer DEFAULT 0 NOT NULL,
    candidate_count integer DEFAULT 0 NOT NULL,
    blocked_count integer DEFAULT 0 NOT NULL,
    notes jsonb DEFAULT '{}'::jsonb NOT NULL,
    CONSTRAINT accountability_transform_runs_status_check CHECK ((status = ANY (ARRAY['PREVIEW'::text, 'BLOCKED'::text, 'COMPLETE'::text, 'FAILED'::text])))
);


ALTER TABLE rb04.accountability_transform_runs OWNER TO postgres;

--
-- Name: app_memberships; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.app_memberships (
    organization_id uuid NOT NULL,
    user_id uuid NOT NULL,
    role text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    CONSTRAINT app_memberships_role_check CHECK ((role = ANY (ARRAY['owner'::text, 'manager'::text, 'shift_lead'::text, 'employee'::text])))
);


ALTER TABLE rb04.app_memberships OWNER TO postgres;

--
-- Name: cash_events; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.cash_events (
    merchant_id uuid NOT NULL,
    clover_id text NOT NULL,
    employee_clover_id text,
    device_clover_id text,
    amount_change_cents bigint,
    event_type text,
    occurred_ms bigint,
    observed_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE rb04.cash_events OWNER TO postgres;

--
-- Name: catalog_items; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.catalog_items (
    merchant_id uuid NOT NULL,
    clover_id text NOT NULL,
    name text,
    price_cents bigint,
    stock_count numeric(16,4),
    modified_ms bigint,
    observed_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE rb04.catalog_items OWNER TO postgres;

--
-- Name: clover_scan_audits; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.clover_scan_audits (
    id bigint NOT NULL,
    merchant_id uuid NOT NULL,
    resource text NOT NULL,
    scan_start_ms bigint NOT NULL,
    scan_end_ms bigint NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    status text DEFAULT 'RUNNING'::text NOT NULL,
    pages_read integer DEFAULT 0 NOT NULL,
    records_read integer DEFAULT 0 NOT NULL,
    unique_records integer DEFAULT 0 NOT NULL,
    duplicate_records integer DEFAULT 0 NOT NULL,
    retry_attempts integer DEFAULT 0 NOT NULL,
    first_offset integer DEFAULT 0 NOT NULL,
    final_offset integer,
    error_details jsonb DEFAULT '[]'::jsonb NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT clover_scan_audits_check CHECK ((scan_end_ms >= scan_start_ms)),
    CONSTRAINT clover_scan_audits_check1 CHECK (((final_offset IS NULL) OR (final_offset >= first_offset))),
    CONSTRAINT clover_scan_audits_duplicate_records_check CHECK ((duplicate_records >= 0)),
    CONSTRAINT clover_scan_audits_first_offset_check CHECK ((first_offset >= 0)),
    CONSTRAINT clover_scan_audits_pages_read_check CHECK ((pages_read >= 0)),
    CONSTRAINT clover_scan_audits_records_read_check CHECK ((records_read >= 0)),
    CONSTRAINT clover_scan_audits_resource_check CHECK ((resource = ANY (ARRAY['orders'::text, 'payments'::text]))),
    CONSTRAINT clover_scan_audits_retry_attempts_check CHECK ((retry_attempts >= 0)),
    CONSTRAINT clover_scan_audits_scan_start_ms_check CHECK ((scan_start_ms >= 0)),
    CONSTRAINT clover_scan_audits_status_check CHECK ((status = ANY (ARRAY['RUNNING'::text, 'COMPLETE'::text, 'PARTIAL'::text, 'FAILED'::text]))),
    CONSTRAINT clover_scan_audits_unique_records_check CHECK ((unique_records >= 0))
);


ALTER TABLE rb04.clover_scan_audits OWNER TO postgres;

--
-- Name: clover_scan_audits_id_seq; Type: SEQUENCE; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.clover_scan_audits ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME rb04.clover_scan_audits_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: clover_scan_seen_records; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.clover_scan_seen_records (
    id bigint NOT NULL,
    scan_audit_id bigint NOT NULL,
    external_id text NOT NULL,
    first_page_offset integer NOT NULL,
    first_seen_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT rb04_scan_seen_external_id_valid CHECK (((length(external_id) >= 1) AND (length(external_id) <= 128))),
    CONSTRAINT rb04_scan_seen_offset_valid CHECK ((first_page_offset >= 0))
);


ALTER TABLE rb04.clover_scan_seen_records OWNER TO postgres;

--
-- Name: clover_scan_seen_records_id_seq; Type: SEQUENCE; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.clover_scan_seen_records ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME rb04.clover_scan_seen_records_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: clover_sync_checkpoints; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.clover_sync_checkpoints (
    merchant_id uuid NOT NULL,
    resource text NOT NULL,
    status text DEFAULT 'NOT_STARTED'::text NOT NULL,
    scan_start_ms bigint,
    scan_end_ms bigint,
    next_offset integer DEFAULT 0 NOT NULL,
    last_completed_modified_ms bigint,
    last_started_at timestamp with time zone,
    last_completed_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    last_error text,
    CONSTRAINT clover_sync_checkpoints_check CHECK (((scan_start_ms IS NULL) OR (scan_end_ms IS NULL) OR (scan_end_ms >= scan_start_ms))),
    CONSTRAINT clover_sync_checkpoints_last_completed_modified_ms_check CHECK (((last_completed_modified_ms IS NULL) OR (last_completed_modified_ms >= 0))),
    CONSTRAINT clover_sync_checkpoints_next_offset_check CHECK ((next_offset >= 0)),
    CONSTRAINT clover_sync_checkpoints_resource_check CHECK ((resource = ANY (ARRAY['orders'::text, 'payments'::text]))),
    CONSTRAINT clover_sync_checkpoints_scan_end_ms_check CHECK (((scan_end_ms IS NULL) OR (scan_end_ms >= 0))),
    CONSTRAINT clover_sync_checkpoints_scan_start_ms_check CHECK (((scan_start_ms IS NULL) OR (scan_start_ms >= 0))),
    CONSTRAINT clover_sync_checkpoints_status_check CHECK ((status = ANY (ARRAY['NOT_STARTED'::text, 'RUNNING'::text, 'PAUSED'::text, 'COMPLETE'::text, 'FAILED'::text])))
);


ALTER TABLE rb04.clover_sync_checkpoints OWNER TO postgres;

--
-- Name: comp_approvals; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.comp_approvals (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    merchant_id uuid NOT NULL,
    order_id text,
    discount_application_id text,
    requested_by uuid,
    approved_by uuid,
    status text DEFAULT 'PENDING'::text NOT NULL,
    reason text,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    decided_at timestamp with time zone,
    CONSTRAINT comp_approvals_status_check CHECK ((status = ANY (ARRAY['PENDING'::text, 'APPROVED'::text, 'REJECTED'::text, 'ESCALATED'::text])))
);


ALTER TABLE rb04.comp_approvals OWNER TO postgres;

--
-- Name: dashboard_memberships; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.dashboard_memberships (
    user_id uuid NOT NULL,
    merchant_id uuid NOT NULL,
    app_role text NOT NULL,
    active boolean DEFAULT true NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    accountability_employee_id uuid,
    CONSTRAINT dashboard_memberships_app_role_check CHECK ((app_role = ANY (ARRAY['OWNER'::text, 'ADMIN'::text, 'MANAGER'::text, 'SHIFT_LEAD'::text, 'BARTENDER'::text])))
);


ALTER TABLE rb04.dashboard_memberships OWNER TO postgres;

--
-- Name: dev_ingestion_control; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.dev_ingestion_control (
    control_id integer NOT NULL,
    writes_enabled boolean DEFAULT false NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT dev_ingestion_control_control_id_check CHECK ((control_id = 1))
);


ALTER TABLE rb04.dev_ingestion_control OWNER TO postgres;

--
-- Name: discount_applications; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.discount_applications (
    merchant_id uuid NOT NULL,
    clover_id text NOT NULL,
    order_id text NOT NULL,
    order_line_id text,
    discount_id text,
    name text,
    amount_cents bigint,
    percentage numeric(12,6),
    scope text NOT NULL,
    observed_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT discount_applications_scope_check CHECK ((scope = ANY (ARRAY['ORDER'::text, 'LINE'::text])))
);


ALTER TABLE rb04.discount_applications OWNER TO postgres;

--
-- Name: ingestion_write_controls; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.ingestion_write_controls (
    merchant_id uuid NOT NULL,
    writes_authorized boolean DEFAULT false NOT NULL,
    authorized_at timestamp with time zone,
    authorization_note text,
    updated_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE rb04.ingestion_write_controls OWNER TO postgres;

--
-- Name: line_modifications; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.line_modifications (
    merchant_id uuid NOT NULL,
    clover_id text NOT NULL,
    order_line_id text NOT NULL,
    modifier_id text,
    name text,
    amount_cents bigint,
    observed_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE rb04.line_modifications OWNER TO postgres;

--
-- Name: merchants; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.merchants (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    clover_merchant_id text NOT NULL,
    label text NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE rb04.merchants OWNER TO postgres;

--
-- Name: normalization_checkpoints; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.normalization_checkpoints (
    merchant_id uuid NOT NULL,
    resource text NOT NULL,
    last_raw_id bigint DEFAULT 0 NOT NULL,
    last_processed_at timestamp with time zone,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT normalization_checkpoints_last_raw_id_check CHECK ((last_raw_id >= 0)),
    CONSTRAINT normalization_checkpoints_resource_check CHECK ((resource = ANY (ARRAY['orders'::text, 'payments'::text])))
);


ALTER TABLE rb04.normalization_checkpoints OWNER TO postgres;

--
-- Name: normalization_rejections; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.normalization_rejections (
    id bigint NOT NULL,
    merchant_id uuid NOT NULL,
    raw_id bigint NOT NULL,
    resource text NOT NULL,
    external_id text NOT NULL,
    reason text NOT NULL,
    status text DEFAULT 'OPEN'::text NOT NULL,
    first_detected_at timestamp with time zone DEFAULT now() NOT NULL,
    last_detected_at timestamp with time zone DEFAULT now() NOT NULL,
    retry_count integer DEFAULT 0 NOT NULL,
    resolved_at timestamp with time zone,
    resolution_notes text,
    CONSTRAINT normalization_rejections_resource_check CHECK ((resource = ANY (ARRAY['orders'::text, 'payments'::text]))),
    CONSTRAINT normalization_rejections_retry_count_check CHECK ((retry_count >= 0)),
    CONSTRAINT normalization_rejections_status_check CHECK ((status = ANY (ARRAY['OPEN'::text, 'RETRY_PENDING'::text, 'RESOLVED'::text, 'IGNORED'::text])))
);


ALTER TABLE rb04.normalization_rejections OWNER TO postgres;

--
-- Name: normalization_rejections_id_seq; Type: SEQUENCE; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.normalization_rejections ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME rb04.normalization_rejections_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: normalization_retry_attempts; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.normalization_retry_attempts (
    id bigint NOT NULL,
    rejection_id bigint NOT NULL,
    merchant_id uuid NOT NULL,
    attempted_at timestamp with time zone DEFAULT now() NOT NULL,
    previous_status text NOT NULL,
    resulting_status text NOT NULL,
    outcome text NOT NULL,
    reason text,
    retry_number integer NOT NULL,
    CONSTRAINT normalization_retry_attempts_outcome_check CHECK ((outcome = ANY (ARRAY['RESOLVED'::text, 'REVIEW_REQUIRED'::text, 'NO_CHANGE'::text]))),
    CONSTRAINT normalization_retry_attempts_retry_number_check CHECK ((retry_number >= 0))
);


ALTER TABLE rb04.normalization_retry_attempts OWNER TO postgres;

--
-- Name: normalization_retry_attempts_id_seq; Type: SEQUENCE; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.normalization_retry_attempts ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME rb04.normalization_retry_attempts_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: normalization_runs; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.normalization_runs (
    id bigint NOT NULL,
    merchant_id uuid NOT NULL,
    resource text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    completed_at timestamp with time zone,
    status text DEFAULT 'RUNNING'::text NOT NULL,
    cursor_start bigint DEFAULT 0 NOT NULL,
    cursor_end bigint,
    scanned integer DEFAULT 0 NOT NULL,
    inserted integer DEFAULT 0 NOT NULL,
    updated integer DEFAULT 0 NOT NULL,
    unchanged integer DEFAULT 0 NOT NULL,
    rejected integer DEFAULT 0 NOT NULL,
    error_details jsonb DEFAULT '[]'::jsonb NOT NULL,
    CONSTRAINT normalization_runs_resource_check CHECK ((resource = ANY (ARRAY['orders'::text, 'payments'::text]))),
    CONSTRAINT normalization_runs_status_check CHECK ((status = ANY (ARRAY['RUNNING'::text, 'COMPLETE'::text, 'PARTIAL'::text, 'FAILED'::text])))
);


ALTER TABLE rb04.normalization_runs OWNER TO postgres;

--
-- Name: normalization_runs_id_seq; Type: SEQUENCE; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.normalization_runs ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME rb04.normalization_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: order_lines; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.order_lines (
    merchant_id uuid NOT NULL,
    clover_id text NOT NULL,
    order_id text NOT NULL,
    item_id text,
    name text,
    price_cents bigint,
    quantity numeric(16,4),
    refunded boolean,
    created_ms bigint,
    observed_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE rb04.order_lines OWNER TO postgres;

--
-- Name: orders; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.orders (
    merchant_id uuid NOT NULL,
    clover_id text NOT NULL,
    state text,
    payment_state text,
    total_cents bigint,
    created_ms bigint,
    modified_ms bigint,
    employee_clover_id text,
    device_clover_id text,
    note_present boolean DEFAULT false NOT NULL,
    observed_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE rb04.orders OWNER TO postgres;

--
-- Name: organizations; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.organizations (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    name text NOT NULL,
    timezone text DEFAULT 'America/Chicago'::text NOT NULL,
    business_day_start_hour integer DEFAULT 7 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT organizations_business_day_start_hour_check CHECK (((business_day_start_hour >= 0) AND (business_day_start_hour <= 23)))
);


ALTER TABLE rb04.organizations OWNER TO postgres;

--
-- Name: payments; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.payments (
    merchant_id uuid NOT NULL,
    clover_id text NOT NULL,
    order_id text,
    employee_clover_id text,
    tender_clover_id text,
    amount_cents bigint,
    tax_cents bigint,
    tip_cents bigint,
    result text,
    created_ms bigint,
    modified_ms bigint,
    observed_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE rb04.payments OWNER TO postgres;

--
-- Name: raw_objects_id_seq; Type: SEQUENCE; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.raw_objects ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME rb04.raw_objects_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: refunds; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.refunds (
    merchant_id uuid NOT NULL,
    clover_id text NOT NULL,
    order_id text,
    payment_id text,
    amount_cents bigint,
    tax_cents bigint,
    tip_cents bigint,
    status text,
    created_ms bigint,
    observed_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE rb04.refunds OWNER TO postgres;

--
-- Name: shift_cash_counts; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.shift_cash_counts (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    organization_id uuid NOT NULL,
    merchant_id uuid NOT NULL,
    shift_date date NOT NULL,
    opened_by uuid,
    closed_by uuid,
    opening_cents bigint,
    closing_cents bigint,
    variance_cents bigint,
    notes text,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


ALTER TABLE rb04.shift_cash_counts OWNER TO postgres;

--
-- Name: sync_checkpoints; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.sync_checkpoints (
    merchant_id uuid NOT NULL,
    resource text NOT NULL,
    cursor_value text,
    high_water_ms bigint,
    last_success_at timestamp with time zone
);


ALTER TABLE rb04.sync_checkpoints OWNER TO postgres;

--
-- Name: sync_runs; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.sync_runs (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    merchant_id uuid NOT NULL,
    resource text NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    finished_at timestamp with time zone,
    status text DEFAULT 'RUNNING'::text NOT NULL,
    records_seen integer DEFAULT 0 NOT NULL,
    error_code text,
    CONSTRAINT sync_runs_status_check CHECK ((status = ANY (ARRAY['RUNNING'::text, 'SUCCEEDED'::text, 'FAILED'::text])))
);


ALTER TABLE rb04.sync_runs OWNER TO postgres;

--
-- Name: webhook_inbox; Type: TABLE; Schema: rb04; Owner: postgres
--

CREATE TABLE rb04.webhook_inbox (
    id bigint NOT NULL,
    merchant_id uuid NOT NULL,
    event_key text NOT NULL,
    event_type text,
    received_at timestamp with time zone DEFAULT now() NOT NULL,
    processed_at timestamp with time zone,
    payload jsonb NOT NULL
);


ALTER TABLE rb04.webhook_inbox OWNER TO postgres;

--
-- Name: webhook_inbox_id_seq; Type: SEQUENCE; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.webhook_inbox ALTER COLUMN id ADD GENERATED ALWAYS AS IDENTITY (
    SEQUENCE NAME rb04.webhook_inbox_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: accountability_approval_rules accountability_approval_rules_merchant_id_event_type_approv_key; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_approval_rules
    ADD CONSTRAINT accountability_approval_rules_merchant_id_event_type_approv_key UNIQUE (merchant_id, event_type, approver_role, effective_from);


--
-- Name: accountability_approval_rules accountability_approval_rules_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_approval_rules
    ADD CONSTRAINT accountability_approval_rules_pkey PRIMARY KEY (id);


--
-- Name: accountability_employees accountability_employees_merchant_id_clover_employee_id_key; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_employees
    ADD CONSTRAINT accountability_employees_merchant_id_clover_employee_id_key UNIQUE (merchant_id, clover_employee_id);


--
-- Name: accountability_employees accountability_employees_merchant_id_id_key; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_employees
    ADD CONSTRAINT accountability_employees_merchant_id_id_key UNIQUE (merchant_id, id);


--
-- Name: accountability_employees accountability_employees_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_employees
    ADD CONSTRAINT accountability_employees_pkey PRIMARY KEY (id);


--
-- Name: accountability_events accountability_events_merchant_id_id_key; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_events
    ADD CONSTRAINT accountability_events_merchant_id_id_key UNIQUE (merchant_id, id);


--
-- Name: accountability_events accountability_events_merchant_id_source_system_source_even_key; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_events
    ADD CONSTRAINT accountability_events_merchant_id_source_system_source_even_key UNIQUE (merchant_id, source_system, source_event_key);


--
-- Name: accountability_events accountability_events_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_events
    ADD CONSTRAINT accountability_events_pkey PRIMARY KEY (id);


--
-- Name: accountability_exceptions accountability_exceptions_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_exceptions
    ADD CONSTRAINT accountability_exceptions_pkey PRIMARY KEY (id);


--
-- Name: accountability_reviews accountability_reviews_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_reviews
    ADD CONSTRAINT accountability_reviews_pkey PRIMARY KEY (id);


--
-- Name: accountability_transform_runs accountability_transform_runs_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_transform_runs
    ADD CONSTRAINT accountability_transform_runs_pkey PRIMARY KEY (id);


--
-- Name: app_memberships app_memberships_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.app_memberships
    ADD CONSTRAINT app_memberships_pkey PRIMARY KEY (organization_id, user_id);


--
-- Name: cash_events cash_events_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.cash_events
    ADD CONSTRAINT cash_events_pkey PRIMARY KEY (merchant_id, clover_id);


--
-- Name: catalog_items catalog_items_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.catalog_items
    ADD CONSTRAINT catalog_items_pkey PRIMARY KEY (merchant_id, clover_id);


--
-- Name: clover_scan_audits clover_scan_audits_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.clover_scan_audits
    ADD CONSTRAINT clover_scan_audits_pkey PRIMARY KEY (id);


--
-- Name: clover_scan_seen_records clover_scan_seen_records_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.clover_scan_seen_records
    ADD CONSTRAINT clover_scan_seen_records_pkey PRIMARY KEY (id);


--
-- Name: clover_sync_checkpoints clover_sync_checkpoints_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.clover_sync_checkpoints
    ADD CONSTRAINT clover_sync_checkpoints_pkey PRIMARY KEY (merchant_id, resource);


--
-- Name: comp_approvals comp_approvals_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.comp_approvals
    ADD CONSTRAINT comp_approvals_pkey PRIMARY KEY (id);


--
-- Name: dashboard_memberships dashboard_memberships_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.dashboard_memberships
    ADD CONSTRAINT dashboard_memberships_pkey PRIMARY KEY (user_id, merchant_id);


--
-- Name: dev_ingestion_control dev_ingestion_control_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.dev_ingestion_control
    ADD CONSTRAINT dev_ingestion_control_pkey PRIMARY KEY (control_id);


--
-- Name: discount_applications discount_applications_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.discount_applications
    ADD CONSTRAINT discount_applications_pkey PRIMARY KEY (merchant_id, clover_id);


--
-- Name: ingestion_write_controls ingestion_write_controls_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.ingestion_write_controls
    ADD CONSTRAINT ingestion_write_controls_pkey PRIMARY KEY (merchant_id);


--
-- Name: line_modifications line_modifications_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.line_modifications
    ADD CONSTRAINT line_modifications_pkey PRIMARY KEY (merchant_id, clover_id);


--
-- Name: merchants merchants_clover_merchant_id_key; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.merchants
    ADD CONSTRAINT merchants_clover_merchant_id_key UNIQUE (clover_merchant_id);


--
-- Name: merchants merchants_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.merchants
    ADD CONSTRAINT merchants_pkey PRIMARY KEY (id);


--
-- Name: normalization_checkpoints normalization_checkpoints_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.normalization_checkpoints
    ADD CONSTRAINT normalization_checkpoints_pkey PRIMARY KEY (merchant_id, resource);


--
-- Name: normalization_rejections normalization_rejections_merchant_id_raw_id_key; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.normalization_rejections
    ADD CONSTRAINT normalization_rejections_merchant_id_raw_id_key UNIQUE (merchant_id, raw_id);


--
-- Name: normalization_rejections normalization_rejections_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.normalization_rejections
    ADD CONSTRAINT normalization_rejections_pkey PRIMARY KEY (id);


--
-- Name: normalization_retry_attempts normalization_retry_attempts_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.normalization_retry_attempts
    ADD CONSTRAINT normalization_retry_attempts_pkey PRIMARY KEY (id);


--
-- Name: normalization_runs normalization_runs_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.normalization_runs
    ADD CONSTRAINT normalization_runs_pkey PRIMARY KEY (id);


--
-- Name: order_lines order_lines_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.order_lines
    ADD CONSTRAINT order_lines_pkey PRIMARY KEY (merchant_id, clover_id);


--
-- Name: orders orders_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.orders
    ADD CONSTRAINT orders_pkey PRIMARY KEY (merchant_id, clover_id);


--
-- Name: organizations organizations_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.organizations
    ADD CONSTRAINT organizations_pkey PRIMARY KEY (id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (merchant_id, clover_id);


--
-- Name: raw_objects raw_objects_merchant_id_resource_external_id_sha256_key; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.raw_objects
    ADD CONSTRAINT raw_objects_merchant_id_resource_external_id_sha256_key UNIQUE (merchant_id, resource, external_id, sha256);


--
-- Name: raw_objects raw_objects_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.raw_objects
    ADD CONSTRAINT raw_objects_pkey PRIMARY KEY (id);


--
-- Name: clover_scan_seen_records rb04_scan_seen_unique_record; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.clover_scan_seen_records
    ADD CONSTRAINT rb04_scan_seen_unique_record UNIQUE (scan_audit_id, external_id);


--
-- Name: refunds refunds_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.refunds
    ADD CONSTRAINT refunds_pkey PRIMARY KEY (merchant_id, clover_id);


--
-- Name: shift_cash_counts shift_cash_counts_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.shift_cash_counts
    ADD CONSTRAINT shift_cash_counts_pkey PRIMARY KEY (id);


--
-- Name: sync_checkpoints sync_checkpoints_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.sync_checkpoints
    ADD CONSTRAINT sync_checkpoints_pkey PRIMARY KEY (merchant_id, resource);


--
-- Name: sync_runs sync_runs_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.sync_runs
    ADD CONSTRAINT sync_runs_pkey PRIMARY KEY (id);


--
-- Name: webhook_inbox webhook_inbox_merchant_id_event_key_key; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.webhook_inbox
    ADD CONSTRAINT webhook_inbox_merchant_id_event_key_key UNIQUE (merchant_id, event_key);


--
-- Name: webhook_inbox webhook_inbox_pkey; Type: CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.webhook_inbox
    ADD CONSTRAINT webhook_inbox_pkey PRIMARY KEY (id);


--
-- Name: clover_scan_audits_merchant_resource_idx; Type: INDEX; Schema: rb04; Owner: postgres
--

CREATE INDEX clover_scan_audits_merchant_resource_idx ON rb04.clover_scan_audits USING btree (merchant_id, resource, started_at DESC);


--
-- Name: dashboard_memberships_employee_unique; Type: INDEX; Schema: rb04; Owner: postgres
--

CREATE UNIQUE INDEX dashboard_memberships_employee_unique ON rb04.dashboard_memberships USING btree (merchant_id, accountability_employee_id) WHERE ((accountability_employee_id IS NOT NULL) AND active);


--
-- Name: idx_rb04_normalization_runs_merchant_resource; Type: INDEX; Schema: rb04; Owner: postgres
--

CREATE INDEX idx_rb04_normalization_runs_merchant_resource ON rb04.normalization_runs USING btree (merchant_id, resource, started_at DESC);


--
-- Name: idx_rb04_rejections_review; Type: INDEX; Schema: rb04; Owner: postgres
--

CREATE INDEX idx_rb04_rejections_review ON rb04.normalization_rejections USING btree (merchant_id, status, first_detected_at);


--
-- Name: idx_rb04_retry_attempts_rejection; Type: INDEX; Schema: rb04; Owner: postgres
--

CREATE INDEX idx_rb04_retry_attempts_rejection ON rb04.normalization_retry_attempts USING btree (rejection_id, attempted_at DESC);


--
-- Name: idx_rb04_scan_seen_audit; Type: INDEX; Schema: rb04; Owner: postgres
--

CREATE INDEX idx_rb04_scan_seen_audit ON rb04.clover_scan_seen_records USING btree (scan_audit_id);


--
-- Name: raw_objects_lookup; Type: INDEX; Schema: rb04; Owner: postgres
--

CREATE INDEX raw_objects_lookup ON rb04.raw_objects USING btree (merchant_id, resource, external_id, observed_at DESC);


--
-- Name: rb04_accountability_events_business_idx; Type: INDEX; Schema: rb04; Owner: postgres
--

CREATE INDEX rb04_accountability_events_business_idx ON rb04.accountability_events USING btree (merchant_id, business_date, event_type);


--
-- Name: rb04_accountability_events_employee_idx; Type: INDEX; Schema: rb04; Owner: postgres
--

CREATE INDEX rb04_accountability_events_employee_idx ON rb04.accountability_events USING btree (merchant_id, source_employee_id, business_date);


--
-- Name: rb04_accountability_exceptions_status_idx; Type: INDEX; Schema: rb04; Owner: postgres
--

CREATE INDEX rb04_accountability_exceptions_status_idx ON rb04.accountability_exceptions USING btree (merchant_id, status, opened_at);


--
-- Name: rb04_accountability_reviews_event_idx; Type: INDEX; Schema: rb04; Owner: postgres
--

CREATE INDEX rb04_accountability_reviews_event_idx ON rb04.accountability_reviews USING btree (merchant_id, event_id, reviewed_at DESC, created_at DESC);


--
-- Name: rb04_accountability_rules_lookup_idx; Type: INDEX; Schema: rb04; Owner: postgres
--

CREATE INDEX rb04_accountability_rules_lookup_idx ON rb04.accountability_approval_rules USING btree (merchant_id, event_type, effective_from DESC);


--
-- Name: rb04_scan_audit_one_running_idx; Type: INDEX; Schema: rb04; Owner: postgres
--

CREATE UNIQUE INDEX rb04_scan_audit_one_running_idx ON rb04.clover_scan_audits USING btree (merchant_id, resource) WHERE (status = 'RUNNING'::text);


--
-- Name: rb04_scan_audit_unique_window_idx; Type: INDEX; Schema: rb04; Owner: postgres
--

CREATE UNIQUE INDEX rb04_scan_audit_unique_window_idx ON rb04.clover_scan_audits USING btree (merchant_id, resource, scan_start_ms, scan_end_ms);


--
-- Name: normalization_rejections trg_rb04_audit_rejection_retry; Type: TRIGGER; Schema: rb04; Owner: postgres
--

CREATE TRIGGER trg_rb04_audit_rejection_retry AFTER UPDATE OF retry_count ON rb04.normalization_rejections FOR EACH ROW EXECUTE FUNCTION rb04.audit_rejection_retry();


--
-- Name: normalization_runs trg_rb04_capture_normalization_rejections; Type: TRIGGER; Schema: rb04; Owner: postgres
--

CREATE TRIGGER trg_rb04_capture_normalization_rejections AFTER UPDATE OF status, error_details ON rb04.normalization_runs FOR EACH ROW EXECUTE FUNCTION rb04.capture_normalization_rejections();


--
-- Name: accountability_approval_rules accountability_approval_rules_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_approval_rules
    ADD CONSTRAINT accountability_approval_rules_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: accountability_employees accountability_employees_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_employees
    ADD CONSTRAINT accountability_employees_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: accountability_events accountability_events_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_events
    ADD CONSTRAINT accountability_events_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: accountability_exceptions accountability_exceptions_merchant_id_assigned_employee_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_exceptions
    ADD CONSTRAINT accountability_exceptions_merchant_id_assigned_employee_id_fkey FOREIGN KEY (merchant_id, assigned_employee_id) REFERENCES rb04.accountability_employees(merchant_id, id);


--
-- Name: accountability_exceptions accountability_exceptions_merchant_id_event_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_exceptions
    ADD CONSTRAINT accountability_exceptions_merchant_id_event_id_fkey FOREIGN KEY (merchant_id, event_id) REFERENCES rb04.accountability_events(merchant_id, id);


--
-- Name: accountability_exceptions accountability_exceptions_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_exceptions
    ADD CONSTRAINT accountability_exceptions_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: accountability_reviews accountability_reviews_merchant_id_event_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_reviews
    ADD CONSTRAINT accountability_reviews_merchant_id_event_id_fkey FOREIGN KEY (merchant_id, event_id) REFERENCES rb04.accountability_events(merchant_id, id);


--
-- Name: accountability_reviews accountability_reviews_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_reviews
    ADD CONSTRAINT accountability_reviews_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: accountability_reviews accountability_reviews_merchant_id_reviewer_employee_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_reviews
    ADD CONSTRAINT accountability_reviews_merchant_id_reviewer_employee_id_fkey FOREIGN KEY (merchant_id, reviewer_employee_id) REFERENCES rb04.accountability_employees(merchant_id, id);


--
-- Name: accountability_transform_runs accountability_transform_runs_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.accountability_transform_runs
    ADD CONSTRAINT accountability_transform_runs_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: app_memberships app_memberships_organization_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.app_memberships
    ADD CONSTRAINT app_memberships_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES rb04.organizations(id);


--
-- Name: app_memberships app_memberships_user_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.app_memberships
    ADD CONSTRAINT app_memberships_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id);


--
-- Name: clover_scan_audits clover_scan_audits_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.clover_scan_audits
    ADD CONSTRAINT clover_scan_audits_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: clover_scan_seen_records clover_scan_seen_records_scan_audit_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.clover_scan_seen_records
    ADD CONSTRAINT clover_scan_seen_records_scan_audit_id_fkey FOREIGN KEY (scan_audit_id) REFERENCES rb04.clover_scan_audits(id) ON DELETE RESTRICT;


--
-- Name: clover_sync_checkpoints clover_sync_checkpoints_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.clover_sync_checkpoints
    ADD CONSTRAINT clover_sync_checkpoints_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: comp_approvals comp_approvals_approved_by_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.comp_approvals
    ADD CONSTRAINT comp_approvals_approved_by_fkey FOREIGN KEY (approved_by) REFERENCES auth.users(id);


--
-- Name: comp_approvals comp_approvals_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.comp_approvals
    ADD CONSTRAINT comp_approvals_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: comp_approvals comp_approvals_organization_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.comp_approvals
    ADD CONSTRAINT comp_approvals_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES rb04.organizations(id);


--
-- Name: comp_approvals comp_approvals_requested_by_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.comp_approvals
    ADD CONSTRAINT comp_approvals_requested_by_fkey FOREIGN KEY (requested_by) REFERENCES auth.users(id);


--
-- Name: dashboard_memberships dashboard_memberships_employee_fk; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.dashboard_memberships
    ADD CONSTRAINT dashboard_memberships_employee_fk FOREIGN KEY (merchant_id, accountability_employee_id) REFERENCES rb04.accountability_employees(merchant_id, id);


--
-- Name: dashboard_memberships dashboard_memberships_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.dashboard_memberships
    ADD CONSTRAINT dashboard_memberships_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: dashboard_memberships dashboard_memberships_user_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.dashboard_memberships
    ADD CONSTRAINT dashboard_memberships_user_id_fkey FOREIGN KEY (user_id) REFERENCES auth.users(id) ON DELETE CASCADE;


--
-- Name: discount_applications discount_applications_merchant_id_order_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.discount_applications
    ADD CONSTRAINT discount_applications_merchant_id_order_id_fkey FOREIGN KEY (merchant_id, order_id) REFERENCES rb04.orders(merchant_id, clover_id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: ingestion_write_controls ingestion_write_controls_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.ingestion_write_controls
    ADD CONSTRAINT ingestion_write_controls_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: line_modifications line_modifications_merchant_id_order_line_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.line_modifications
    ADD CONSTRAINT line_modifications_merchant_id_order_line_id_fkey FOREIGN KEY (merchant_id, order_line_id) REFERENCES rb04.order_lines(merchant_id, clover_id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: merchants merchants_organization_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.merchants
    ADD CONSTRAINT merchants_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES rb04.organizations(id);


--
-- Name: normalization_checkpoints normalization_checkpoints_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.normalization_checkpoints
    ADD CONSTRAINT normalization_checkpoints_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: normalization_rejections normalization_rejections_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.normalization_rejections
    ADD CONSTRAINT normalization_rejections_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: normalization_rejections normalization_rejections_raw_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.normalization_rejections
    ADD CONSTRAINT normalization_rejections_raw_id_fkey FOREIGN KEY (raw_id) REFERENCES rb04.raw_objects(id);


--
-- Name: normalization_retry_attempts normalization_retry_attempts_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.normalization_retry_attempts
    ADD CONSTRAINT normalization_retry_attempts_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: normalization_retry_attempts normalization_retry_attempts_rejection_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.normalization_retry_attempts
    ADD CONSTRAINT normalization_retry_attempts_rejection_id_fkey FOREIGN KEY (rejection_id) REFERENCES rb04.normalization_rejections(id);


--
-- Name: normalization_runs normalization_runs_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.normalization_runs
    ADD CONSTRAINT normalization_runs_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: order_lines order_lines_merchant_id_order_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.order_lines
    ADD CONSTRAINT order_lines_merchant_id_order_id_fkey FOREIGN KEY (merchant_id, order_id) REFERENCES rb04.orders(merchant_id, clover_id) DEFERRABLE INITIALLY DEFERRED;


--
-- Name: orders orders_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.orders
    ADD CONSTRAINT orders_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: raw_objects raw_objects_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.raw_objects
    ADD CONSTRAINT raw_objects_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: shift_cash_counts shift_cash_counts_closed_by_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.shift_cash_counts
    ADD CONSTRAINT shift_cash_counts_closed_by_fkey FOREIGN KEY (closed_by) REFERENCES auth.users(id);


--
-- Name: shift_cash_counts shift_cash_counts_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.shift_cash_counts
    ADD CONSTRAINT shift_cash_counts_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: shift_cash_counts shift_cash_counts_opened_by_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.shift_cash_counts
    ADD CONSTRAINT shift_cash_counts_opened_by_fkey FOREIGN KEY (opened_by) REFERENCES auth.users(id);


--
-- Name: shift_cash_counts shift_cash_counts_organization_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.shift_cash_counts
    ADD CONSTRAINT shift_cash_counts_organization_id_fkey FOREIGN KEY (organization_id) REFERENCES rb04.organizations(id);


--
-- Name: sync_checkpoints sync_checkpoints_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.sync_checkpoints
    ADD CONSTRAINT sync_checkpoints_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: sync_runs sync_runs_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.sync_runs
    ADD CONSTRAINT sync_runs_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: webhook_inbox webhook_inbox_merchant_id_fkey; Type: FK CONSTRAINT; Schema: rb04; Owner: postgres
--

ALTER TABLE ONLY rb04.webhook_inbox
    ADD CONSTRAINT webhook_inbox_merchant_id_fkey FOREIGN KEY (merchant_id) REFERENCES rb04.merchants(id);


--
-- Name: accountability_approval_rules; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.accountability_approval_rules ENABLE ROW LEVEL SECURITY;

--
-- Name: accountability_employees; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.accountability_employees ENABLE ROW LEVEL SECURITY;

--
-- Name: accountability_events; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.accountability_events ENABLE ROW LEVEL SECURITY;

--
-- Name: accountability_exceptions; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.accountability_exceptions ENABLE ROW LEVEL SECURITY;

--
-- Name: accountability_reviews; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.accountability_reviews ENABLE ROW LEVEL SECURITY;

--
-- Name: accountability_transform_runs; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.accountability_transform_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: app_memberships; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.app_memberships ENABLE ROW LEVEL SECURITY;

--
-- Name: cash_events; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.cash_events ENABLE ROW LEVEL SECURITY;

--
-- Name: catalog_items; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.catalog_items ENABLE ROW LEVEL SECURITY;

--
-- Name: clover_scan_audits; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.clover_scan_audits ENABLE ROW LEVEL SECURITY;

--
-- Name: clover_scan_seen_records; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.clover_scan_seen_records ENABLE ROW LEVEL SECURITY;

--
-- Name: clover_sync_checkpoints; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.clover_sync_checkpoints ENABLE ROW LEVEL SECURITY;

--
-- Name: comp_approvals; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.comp_approvals ENABLE ROW LEVEL SECURITY;

--
-- Name: dashboard_memberships; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.dashboard_memberships ENABLE ROW LEVEL SECURITY;

--
-- Name: dev_ingestion_control; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.dev_ingestion_control ENABLE ROW LEVEL SECURITY;

--
-- Name: discount_applications; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.discount_applications ENABLE ROW LEVEL SECURITY;

--
-- Name: ingestion_write_controls; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.ingestion_write_controls ENABLE ROW LEVEL SECURITY;

--
-- Name: line_modifications; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.line_modifications ENABLE ROW LEVEL SECURITY;

--
-- Name: merchants; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.merchants ENABLE ROW LEVEL SECURITY;

--
-- Name: normalization_checkpoints; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.normalization_checkpoints ENABLE ROW LEVEL SECURITY;

--
-- Name: normalization_rejections; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.normalization_rejections ENABLE ROW LEVEL SECURITY;

--
-- Name: normalization_retry_attempts; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.normalization_retry_attempts ENABLE ROW LEVEL SECURITY;

--
-- Name: normalization_runs; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.normalization_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: order_lines; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.order_lines ENABLE ROW LEVEL SECURITY;

--
-- Name: orders; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.orders ENABLE ROW LEVEL SECURITY;

--
-- Name: organizations; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.organizations ENABLE ROW LEVEL SECURITY;

--
-- Name: payments; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.payments ENABLE ROW LEVEL SECURITY;

--
-- Name: raw_objects; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.raw_objects ENABLE ROW LEVEL SECURITY;

--
-- Name: refunds; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.refunds ENABLE ROW LEVEL SECURITY;

--
-- Name: shift_cash_counts; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.shift_cash_counts ENABLE ROW LEVEL SECURITY;

--
-- Name: sync_checkpoints; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.sync_checkpoints ENABLE ROW LEVEL SECURITY;

--
-- Name: sync_runs; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.sync_runs ENABLE ROW LEVEL SECURITY;

--
-- Name: webhook_inbox; Type: ROW SECURITY; Schema: rb04; Owner: postgres
--

ALTER TABLE rb04.webhook_inbox ENABLE ROW LEVEL SECURITY;

-- Clear platform default grants on the objects created by this baseline,
-- then restore the source ACLs below.
REVOKE ALL ON SCHEMA rb04 FROM PUBLIC, anon, authenticated, service_role, rb04_schema_reader;
REVOKE ALL ON ALL TABLES IN SCHEMA rb04 FROM PUBLIC, anon, authenticated, service_role, rb04_schema_reader;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA rb04 FROM PUBLIC, anon, authenticated, service_role, rb04_schema_reader;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA rb04 FROM PUBLIC, anon, authenticated, service_role, rb04_schema_reader;

REVOKE ALL ON FUNCTION public.rb04_app_readonly_dev(p_user_id uuid, p_merchant_id uuid, p_view text, p_start date, p_end date) FROM PUBLIC, anon, authenticated, service_role, rb04_schema_reader;
REVOKE ALL ON FUNCTION public.rb04_check_connection_dev() FROM PUBLIC, anon, authenticated, service_role, rb04_schema_reader;
REVOKE ALL ON FUNCTION public.rb04_check_scan_dev(p_resource text) FROM PUBLIC, anon, authenticated, service_role, rb04_schema_reader;
REVOKE ALL ON FUNCTION public.rb04_commit_clover_page_dev(p_merchant_id uuid, p_resource text, p_scan_start_ms bigint, p_scan_end_ms bigint, p_expected_offset integer, p_records jsonb, p_page_complete boolean, p_retry_attempts integer) FROM PUBLIC, anon, authenticated, service_role, rb04_schema_reader;
REVOKE ALL ON FUNCTION public.rb04_get_commit_checkpoint_dev(p_resource text) FROM PUBLIC, anon, authenticated, service_role, rb04_schema_reader;
REVOKE ALL ON FUNCTION public.rb04_insert_raw_dev(p_merchant_id uuid, p_resource text, p_external_id text, p_payload jsonb, p_sha256 text, p_source_endpoint text) FROM PUBLIC, anon, authenticated, service_role, rb04_schema_reader;
REVOKE ALL ON FUNCTION public.rb04_run_normalization_dev(p_batch_size integer) FROM PUBLIC, anon, authenticated, service_role, rb04_schema_reader;

-- DEV NULL ACLs for these functions resolve to owner plus PUBLIC EXECUTE.
GRANT EXECUTE ON FUNCTION rb04.audit_rejection_retry() TO PUBLIC;
GRANT EXECUTE ON FUNCTION rb04.capture_normalization_rejections() TO PUBLIC;

--
-- Name: SCHEMA rb04; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA rb04 TO service_role;
GRANT USAGE ON SCHEMA rb04 TO rb04_schema_reader;


--
-- Name: FUNCTION rb04_app_readonly_dev(p_user_id uuid, p_merchant_id uuid, p_view text, p_start date, p_end date); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.rb04_app_readonly_dev(p_user_id uuid, p_merchant_id uuid, p_view text, p_start date, p_end date) FROM PUBLIC;
GRANT ALL ON FUNCTION public.rb04_app_readonly_dev(p_user_id uuid, p_merchant_id uuid, p_view text, p_start date, p_end date) TO service_role;


--
-- Name: FUNCTION rb04_check_connection_dev(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.rb04_check_connection_dev() FROM PUBLIC;
GRANT ALL ON FUNCTION public.rb04_check_connection_dev() TO service_role;


--
-- Name: FUNCTION rb04_check_scan_dev(p_resource text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.rb04_check_scan_dev(p_resource text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.rb04_check_scan_dev(p_resource text) TO service_role;


--
-- Name: FUNCTION rb04_commit_clover_page_dev(p_merchant_id uuid, p_resource text, p_scan_start_ms bigint, p_scan_end_ms bigint, p_expected_offset integer, p_records jsonb, p_page_complete boolean, p_retry_attempts integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.rb04_commit_clover_page_dev(p_merchant_id uuid, p_resource text, p_scan_start_ms bigint, p_scan_end_ms bigint, p_expected_offset integer, p_records jsonb, p_page_complete boolean, p_retry_attempts integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.rb04_commit_clover_page_dev(p_merchant_id uuid, p_resource text, p_scan_start_ms bigint, p_scan_end_ms bigint, p_expected_offset integer, p_records jsonb, p_page_complete boolean, p_retry_attempts integer) TO service_role;


--
-- Name: FUNCTION rb04_get_commit_checkpoint_dev(p_resource text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.rb04_get_commit_checkpoint_dev(p_resource text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.rb04_get_commit_checkpoint_dev(p_resource text) TO service_role;


--
-- Name: FUNCTION rb04_insert_raw_dev(p_merchant_id uuid, p_resource text, p_external_id text, p_payload jsonb, p_sha256 text, p_source_endpoint text); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.rb04_insert_raw_dev(p_merchant_id uuid, p_resource text, p_external_id text, p_payload jsonb, p_sha256 text, p_source_endpoint text) FROM PUBLIC;
GRANT ALL ON FUNCTION public.rb04_insert_raw_dev(p_merchant_id uuid, p_resource text, p_external_id text, p_payload jsonb, p_sha256 text, p_source_endpoint text) TO service_role;


--
-- Name: FUNCTION rb04_run_normalization_dev(p_batch_size integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION public.rb04_run_normalization_dev(p_batch_size integer) FROM PUBLIC;
GRANT ALL ON FUNCTION public.rb04_run_normalization_dev(p_batch_size integer) TO service_role;


--
-- Name: FUNCTION normalize_batch_dev(p_resource text, p_limit integer); Type: ACL; Schema: rb04; Owner: postgres
--

REVOKE ALL ON FUNCTION rb04.normalize_batch_dev(p_resource text, p_limit integer) FROM PUBLIC;


--
-- Name: FUNCTION normalize_sample_dev(p_apply boolean); Type: ACL; Schema: rb04; Owner: postgres
--

REVOKE ALL ON FUNCTION rb04.normalize_sample_dev(p_apply boolean) FROM PUBLIC;


--
-- Name: FUNCTION normalize_transactions_dev(p_apply boolean, p_limit integer); Type: ACL; Schema: rb04; Owner: postgres
--

REVOKE ALL ON FUNCTION rb04.normalize_transactions_dev(p_apply boolean, p_limit integer) FROM PUBLIC;


--
-- Name: FUNCTION retry_rejection_dev(p_rejection_id bigint); Type: ACL; Schema: rb04; Owner: postgres
--

REVOKE ALL ON FUNCTION rb04.retry_rejection_dev(p_rejection_id bigint) FROM PUBLIC;


--
-- Name: FUNCTION run_normalization_dev(p_batch_size integer); Type: ACL; Schema: rb04; Owner: postgres
--

REVOKE ALL ON FUNCTION rb04.run_normalization_dev(p_batch_size integer) FROM PUBLIC;


--
-- Name: TABLE accountability_approval_rules; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.accountability_approval_rules TO service_role;


--
-- Name: TABLE raw_objects; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.raw_objects TO service_role;


--
-- Name: TABLE accountability_clover_raw_candidates; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.accountability_clover_raw_candidates TO service_role;


--
-- Name: TABLE accountability_events; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.accountability_events TO service_role;


--
-- Name: TABLE accountability_dashboard_daily; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.accountability_dashboard_daily TO service_role;


--
-- Name: TABLE accountability_weekly_activity; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.accountability_weekly_activity TO service_role;


--
-- Name: TABLE accountability_dashboard_employee_weekly; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.accountability_dashboard_employee_weekly TO service_role;


--
-- Name: TABLE accountability_reviews; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.accountability_reviews TO service_role;


--
-- Name: TABLE accountability_event_review_status; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.accountability_event_review_status TO service_role;


--
-- Name: TABLE accountability_exceptions; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.accountability_exceptions TO service_role;


--
-- Name: TABLE accountability_dashboard_review_queue; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.accountability_dashboard_review_queue TO service_role;


--
-- Name: TABLE accountability_employees; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.accountability_employees TO service_role;


--
-- Name: TABLE accountability_transform_runs; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.accountability_transform_runs TO service_role;


--
-- Name: TABLE app_memberships; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.app_memberships TO service_role;


--
-- Name: TABLE cash_events; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.cash_events TO service_role;


--
-- Name: TABLE catalog_items; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.catalog_items TO service_role;


--
-- Name: TABLE clover_scan_audits; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.clover_scan_audits TO service_role;


--
-- Name: SEQUENCE clover_scan_audits_id_seq; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON SEQUENCE rb04.clover_scan_audits_id_seq TO service_role;


--
-- Name: TABLE clover_scan_seen_records; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.clover_scan_seen_records TO service_role;


--
-- Name: SEQUENCE clover_scan_seen_records_id_seq; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON SEQUENCE rb04.clover_scan_seen_records_id_seq TO service_role;


--
-- Name: TABLE clover_sync_checkpoints; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.clover_sync_checkpoints TO service_role;


--
-- Name: TABLE comp_approvals; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.comp_approvals TO service_role;


--
-- Name: TABLE dashboard_memberships; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.dashboard_memberships TO service_role;


--
-- Name: TABLE discount_applications; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.discount_applications TO service_role;


--
-- Name: TABLE ingestion_write_controls; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.ingestion_write_controls TO service_role;


--
-- Name: TABLE line_modifications; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.line_modifications TO service_role;


--
-- Name: TABLE merchants; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.merchants TO service_role;


--
-- Name: TABLE normalization_checkpoints; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.normalization_checkpoints TO service_role;


--
-- Name: TABLE normalization_rejections; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.normalization_rejections TO service_role;


--
-- Name: SEQUENCE normalization_rejections_id_seq; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON SEQUENCE rb04.normalization_rejections_id_seq TO service_role;


--
-- Name: TABLE normalization_retry_attempts; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.normalization_retry_attempts TO service_role;


--
-- Name: SEQUENCE normalization_retry_attempts_id_seq; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON SEQUENCE rb04.normalization_retry_attempts_id_seq TO service_role;


--
-- Name: TABLE normalization_runs; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.normalization_runs TO service_role;


--
-- Name: SEQUENCE normalization_runs_id_seq; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON SEQUENCE rb04.normalization_runs_id_seq TO service_role;


--
-- Name: TABLE order_lines; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.order_lines TO service_role;


--
-- Name: TABLE orders; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.orders TO service_role;


--
-- Name: TABLE organizations; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.organizations TO service_role;


--
-- Name: TABLE payments; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.payments TO service_role;


--
-- Name: SEQUENCE raw_objects_id_seq; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON SEQUENCE rb04.raw_objects_id_seq TO service_role;


--
-- Name: TABLE refunds; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.refunds TO service_role;


--
-- Name: TABLE shift_cash_counts; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.shift_cash_counts TO service_role;


--
-- Name: TABLE sync_checkpoints; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.sync_checkpoints TO service_role;


--
-- Name: TABLE sync_runs; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.sync_runs TO service_role;


--
-- Name: TABLE webhook_inbox; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON TABLE rb04.webhook_inbox TO service_role;


--
-- Name: SEQUENCE webhook_inbox_id_seq; Type: ACL; Schema: rb04; Owner: postgres
--

GRANT ALL ON SEQUENCE rb04.webhook_inbox_id_seq TO service_role;


--
-- PostgreSQL database dump complete
--

COMMIT;
