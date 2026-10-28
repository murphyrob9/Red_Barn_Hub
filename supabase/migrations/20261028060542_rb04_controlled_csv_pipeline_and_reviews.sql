-- Controlled Clover CSV ingestion. Raw CSV provenance is preserved separately
-- from native Clover API snapshots. Sales allocation is explicitly not inferred.
BEGIN;

CREATE TABLE rb04.clover_import_batches (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
    merchant_id uuid NOT NULL REFERENCES rb04.merchants(id),
    business_date date NOT NULL,
    window_start timestamptz NOT NULL,
    window_end timestamptz NOT NULL,
    source_set_sha256 text NOT NULL CHECK (source_set_sha256 ~ '^[0-9a-f]{64}$'),
    sources jsonb NOT NULL,
    reference_metrics jsonb NOT NULL,
    actual_metrics jsonb NOT NULL DEFAULT '{}',
    status text NOT NULL DEFAULT 'IMPORTING' CHECK (status IN ('IMPORTING','COLLECTIONS_RECONCILED_SALES_ALLOCATION_PENDING')),
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (merchant_id,business_date),
    UNIQUE (merchant_id,id),
    CHECK (window_end > window_start)
);

CREATE TABLE rb04.clover_import_receipts (
    batch_id uuid NOT NULL,
    merchant_id uuid NOT NULL,
    payment_id text NOT NULL,
    order_id text NOT NULL,
    raw_id bigint NOT NULL REFERENCES rb04.raw_objects(id),
    payment_at timestamptz NOT NULL,
    tender_label text NOT NULL,
    amount_cents bigint NOT NULL CHECK (amount_cents >= 0),
    tax_cents bigint NOT NULL CHECK (tax_cents >= 0),
    tip_cents bigint NOT NULL CHECK (tip_cents >= 0),
    refund_cents bigint NOT NULL CHECK (refund_cents >= 0),
    employee_clover_id text,
    employee_name text,
    PRIMARY KEY (batch_id,payment_id),
    UNIQUE (merchant_id,payment_id),
    FOREIGN KEY (merchant_id,batch_id) REFERENCES rb04.clover_import_batches(merchant_id,id)
);

CREATE TABLE rb04.clover_import_discount_groups (
    batch_id uuid NOT NULL,
    merchant_id uuid NOT NULL,
    discount_name text NOT NULL,
    scope text NOT NULL CHECK (scope IN ('ORDER','ITEM')),
    amount_cents bigint NOT NULL CHECK (amount_cents > 0),
    record_count integer NOT NULL CHECK (record_count > 0),
    source jsonb NOT NULL,
    PRIMARY KEY (batch_id,discount_name,scope),
    FOREIGN KEY (merchant_id,batch_id) REFERENCES rb04.clover_import_batches(merchant_id,id)
);

ALTER TABLE rb04.clover_import_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE rb04.clover_import_receipts ENABLE ROW LEVEL SECURITY;
ALTER TABLE rb04.clover_import_discount_groups ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON rb04.clover_import_batches,rb04.clover_import_receipts,rb04.clover_import_discount_groups FROM PUBLIC,anon,authenticated,service_role;
GRANT SELECT ON rb04.clover_import_batches,rb04.clover_import_receipts,rb04.clover_import_discount_groups TO service_role;

ALTER TABLE rb04.accountability_reviews ADD COLUMN reviewer_user_id uuid REFERENCES auth.users(id);

CREATE FUNCTION rb04.import_clover_csv_batch_dev(p_batch jsonb)
RETURNS jsonb LANGUAGE plpgsql SET search_path = '' AS $$
DECLARE
    v_merchant constant uuid := '44b7802c-9152-4a58-a81f-b12280f809e7';
    v_day date := (p_batch->>'business_date')::date;
    v_start timestamptz;
    v_end timestamptz;
    v_id uuid;
    v_existing rb04.clover_import_batches%ROWTYPE;
    r jsonb;
    v_payload jsonb;
    v_hash text;
    v_raw bigint;
    v_at timestamptz;
    v_key text;
    v_actual jsonb;
    v_ref jsonb := p_batch->'reference';
    v_count integer;
    v_tips integer := 0;
    v_discounts integer := 0;
BEGIN
    IF current_user <> 'postgres' THEN RAISE EXCEPTION 'Operator-only DEV import'; END IF;
    IF p_batch->>'schema_version' IS DISTINCT FROM '1'
       OR p_batch->>'source_set_sha256' !~ '^[0-9a-f]{64}$'
       OR jsonb_typeof(p_batch->'orders') IS DISTINCT FROM 'array'
       OR jsonb_typeof(p_batch->'payments') IS DISTINCT FROM 'array'
       OR jsonb_typeof(p_batch->'discount_groups') IS DISTINCT FROM 'array'
       OR jsonb_array_length(p_batch->'payments') NOT BETWEEN 1 AND 10000
       OR jsonb_array_length(p_batch->'orders') NOT BETWEEN 1 AND 10000
       OR v_day IS NULL THEN RAISE EXCEPTION 'Invalid CSV batch'; END IF;
    IF NOT EXISTS (SELECT 1 FROM rb04.merchants WHERE id=v_merchant AND enabled IS FALSE AND clover_merchant_id='X3MHXR2NA6FG1')
       OR NOT EXISTS (SELECT 1 FROM rb04.dev_ingestion_control WHERE control_id=1 AND writes_enabled)
       OR NOT EXISTS (SELECT 1 FROM rb04.ingestion_write_controls WHERE merchant_id=v_merchant AND writes_authorized)
    THEN RAISE EXCEPTION 'Controlled DEV batch is not authorized'; END IF;
    v_start := (v_day + time '07:00') AT TIME ZONE 'America/Chicago';
    v_end := (v_day + 1 + time '07:00') AT TIME ZONE 'America/Chicago';
    IF (p_batch->>'window_start')::timestamptz IS DISTINCT FROM v_start
       OR (p_batch->>'window_end')::timestamptz IS DISTINCT FROM v_end THEN
        RAISE EXCEPTION 'Business window mismatch';
    END IF;
    PERFORM pg_advisory_xact_lock(hashtextextended('rb04:csv:'||v_day::text,0));
    SELECT * INTO v_existing FROM rb04.clover_import_batches WHERE merchant_id=v_merchant AND business_date=v_day;
    IF FOUND THEN
        IF v_existing.source_set_sha256 IS DISTINCT FROM p_batch->>'source_set_sha256' THEN
            RAISE EXCEPTION 'This date already has a different immutable batch';
        END IF;
        RETURN jsonb_build_object('ok',true,'already_imported',true,'batch_id',v_existing.id,'metrics',v_existing.actual_metrics);
    END IF;
    INSERT INTO rb04.clover_import_batches(merchant_id,business_date,window_start,window_end,source_set_sha256,sources,reference_metrics)
    VALUES(v_merchant,v_day,v_start,v_end,p_batch->>'source_set_sha256',p_batch->'sources',v_ref) RETURNING id INTO v_id;

    FOR r IN SELECT value FROM jsonb_array_elements(p_batch->'orders') LOOP
        IF nullif(r->>'id','') IS NULL OR r->'fields'->>'Order ID' IS DISTINCT FROM r->>'id'
           OR r->'fields'->>'Currency' IS DISTINCT FROM 'USD' THEN RAISE EXCEPTION 'Invalid order source'; END IF;
        v_payload := jsonb_build_object('format','CLOVER_DASHBOARD_CSV','source',r->'source','fields',r->'fields','timestamp_precision','minute');
        v_hash := encode(extensions.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex');
        INSERT INTO rb04.raw_objects(merchant_id,resource,external_id,payload,sha256,source_endpoint)
        VALUES(v_merchant,'clover_csv_orders',r->>'id',v_payload,v_hash,'clover-dashboard-csv:'||(r->'source'->>'name'))
        ON CONFLICT (merchant_id,resource,external_id,sha256) DO NOTHING;
        INSERT INTO rb04.orders(merchant_id,clover_id,state,payment_state,total_cents,created_ms,modified_ms,employee_clover_id,note_present)
        VALUES(v_merchant,r->>'id',NULL,r->>'payment_state',(r->>'total_cents')::bigint,
            (extract(epoch FROM (r->>'created_at')::timestamptz)*1000)::bigint,NULL,r->>'employee_id',false)
        ON CONFLICT (merchant_id,clover_id) DO NOTHING;
        IF EXISTS (SELECT 1 FROM rb04.orders o WHERE o.merchant_id=v_merchant AND o.clover_id=r->>'id' AND o.total_cents IS DISTINCT FROM (r->>'total_cents')::bigint) THEN
            RAISE EXCEPTION 'Existing normalized order conflicts with CSV: %',r->>'id';
        END IF;
    END LOOP;

    FOR r IN SELECT value FROM jsonb_array_elements(p_batch->'payments') LOOP
        v_at := (r->>'created_at')::timestamptz;
        IF nullif(r->>'id','') IS NULL OR r->'fields'->>'Payment ID' IS DISTINCT FROM r->>'id'
           OR r->>'currency' IS DISTINCT FROM 'USD' OR r->>'result' IS DISTINCT FROM 'SUCCESS'
           OR v_at IS NULL OR v_at<v_start OR v_at>=v_end OR (r->>'refund_cents')::bigint IS DISTINCT FROM 0
           OR (r->>'tax_cents')::bigint > (r->>'amount_cents')::bigint
           OR r->>'tender' NOT IN ('Cash','Credit Card','Debit Card')
           OR NOT EXISTS (SELECT 1 FROM rb04.orders o WHERE o.merchant_id=v_merchant AND o.clover_id=r->>'order_id')
        THEN RAISE EXCEPTION 'Unsupported or invalid receipt: %',r->>'id'; END IF;
        v_payload := jsonb_build_object('format','CLOVER_DASHBOARD_CSV','source',r->'source','fields',r->'fields','timestamp_precision','minute');
        v_hash := encode(extensions.digest(convert_to(v_payload::text,'UTF8'),'sha256'),'hex');
        INSERT INTO rb04.raw_objects(merchant_id,resource,external_id,payload,sha256,source_endpoint)
        VALUES(v_merchant,'clover_csv_payments',r->>'id',v_payload,v_hash,'clover-dashboard-csv:'||(r->'source'->>'name'))
        ON CONFLICT (merchant_id,resource,external_id,sha256) DO NOTHING;
        SELECT id INTO STRICT v_raw FROM rb04.raw_objects WHERE merchant_id=v_merchant AND resource='clover_csv_payments' AND external_id=r->>'id' AND sha256=v_hash;
        INSERT INTO rb04.payments(merchant_id,clover_id,order_id,employee_clover_id,tender_clover_id,amount_cents,tax_cents,tip_cents,result,created_ms,modified_ms)
        VALUES(v_merchant,r->>'id',r->>'order_id',r->>'employee_id',NULL,(r->>'amount_cents')::bigint,
            (r->>'tax_cents')::bigint,(r->>'tip_cents')::bigint,'SUCCESS',(extract(epoch FROM v_at)*1000)::bigint,NULL)
        ON CONFLICT (merchant_id,clover_id) DO NOTHING;
        IF EXISTS (SELECT 1 FROM rb04.payments p WHERE p.merchant_id=v_merchant AND p.clover_id=r->>'id' AND
            (p.amount_cents IS DISTINCT FROM (r->>'amount_cents')::bigint OR p.tax_cents IS DISTINCT FROM (r->>'tax_cents')::bigint
             OR p.tip_cents IS DISTINCT FROM (r->>'tip_cents')::bigint OR p.order_id IS DISTINCT FROM r->>'order_id')) THEN
            RAISE EXCEPTION 'Existing normalized payment conflicts with CSV: %',r->>'id';
        END IF;
        INSERT INTO rb04.clover_import_receipts(batch_id,merchant_id,payment_id,order_id,raw_id,payment_at,tender_label,amount_cents,tax_cents,tip_cents,refund_cents,employee_clover_id,employee_name)
        VALUES(v_id,v_merchant,r->>'id',r->>'order_id',v_raw,v_at,r->>'tender',(r->>'amount_cents')::bigint,
            (r->>'tax_cents')::bigint,(r->>'tip_cents')::bigint,0,r->>'employee_id',r->>'employee_name');
        IF (r->>'tip_cents')::bigint>0 THEN
            v_key := 'payment:'||(r->>'id')||':tip';
            IF EXISTS (SELECT 1 FROM rb04.accountability_events WHERE merchant_id=v_merchant AND source_system='CLOVER' AND source_event_key=v_key
                       AND (amount_cents IS DISTINCT FROM (r->>'tip_cents')::bigint OR business_date IS DISTINCT FROM v_day)) THEN
                RAISE EXCEPTION 'Conflicting existing tip event';
            END IF;
            INSERT INTO rb04.accountability_events(merchant_id,event_type,source_event_key,source_order_id,source_payment_id,source_employee_id,
                source_employee_name,observed_at,business_date,amount_cents,source_payload_sha256,source_notes,source_reference)
            VALUES(v_merchant,'TIP',v_key,r->>'order_id',r->>'id',r->>'employee_id',r->>'employee_name',v_at,v_day,
                (r->>'tip_cents')::bigint,v_hash,'Payment receipt-day tip. CSV timestamp precision: minute.','raw_objects:'||v_raw)
            ON CONFLICT (merchant_id,source_system,source_event_key) DO NOTHING;
            GET DIAGNOSTICS v_count = ROW_COUNT;
            v_tips := v_tips+v_count;
        END IF;
    END LOOP;

    FOR r IN SELECT value FROM jsonb_array_elements(p_batch->'discount_groups') LOOP
        IF r->>'granularity' IS DISTINCT FROM 'REPORT_DISCOUNT_GROUP' OR r->>'scope' NOT IN ('ORDER','ITEM')
           OR (r->>'amount_cents')::bigint<=0 OR (r->>'record_count')::integer<=0 THEN
            RAISE EXCEPTION 'Invalid report discount group';
        END IF;
        INSERT INTO rb04.clover_import_discount_groups(batch_id,merchant_id,discount_name,scope,amount_cents,record_count,source)
        VALUES(v_id,v_merchant,r->>'name',r->>'scope',(r->>'amount_cents')::bigint,(r->>'record_count')::integer,r->'source');
        v_key := 'discount-report:'||v_day::text||':'||(r->>'scope')||':'||(r->>'name');
        v_hash := encode(extensions.digest(convert_to(r::text,'UTF8'),'sha256'),'hex');
        INSERT INTO rb04.accountability_events(merchant_id,event_type,source_event_key,observed_at,business_date,amount_cents,
            source_payload_sha256,source_notes,source_reference)
        VALUES(v_merchant,'DISCOUNT',v_key,v_start,v_day,(r->>'amount_cents')::bigint,v_hash,
            'REPORT_DISCOUNT_GROUP; '||(r->>'name')||'; scope='||(r->>'scope')||'; source records='||(r->>'record_count')||
            '. No order, line-item or employee IDs inferred.','clover_import_batches:'||v_id)
        ON CONFLICT (merchant_id,source_system,source_event_key) DO NOTHING;
        GET DIAGNOSTICS v_count = ROW_COUNT;
        v_discounts := v_discounts+v_count;
    END LOOP;

    SELECT jsonb_build_object('payment_count',count(*),'reported_order_count',count(DISTINCT order_id),
        'tax_cents',sum(tax_cents),'tip_cents',sum(tip_cents),'refund_cents',sum(refund_cents),
        'collected_cents',sum(amount_cents+tip_cents-refund_cents),
        'net_sales_cents',sum(amount_cents-tax_cents),
        'card_cents',coalesce(sum(amount_cents+tip_cents-refund_cents) FILTER (WHERE tender_label IN ('Credit Card','Debit Card')),0),
        'cash_cents',coalesce(sum(amount_cents+tip_cents-refund_cents) FILTER (WHERE tender_label='Cash'),0))
    INTO v_actual FROM rb04.clover_import_receipts WHERE batch_id=v_id;
    v_actual := v_actual || jsonb_build_object('discount_cents',(SELECT coalesce(sum(amount_cents),0) FROM rb04.clover_import_discount_groups WHERE batch_id=v_id));
    v_actual := v_actual || jsonb_build_object('gross_sales_cents',(v_actual->>'net_sales_cents')::bigint+(v_actual->>'discount_cents')::bigint);
    IF EXISTS (SELECT 1 FROM jsonb_each(v_ref) e WHERE v_actual->e.key IS DISTINCT FROM e.value) THEN
        RAISE EXCEPTION 'Imported receipts/report-discount totals do not match the Clover reference';
    END IF;
    UPDATE rb04.clover_import_batches SET actual_metrics=v_actual,status='COLLECTIONS_RECONCILED_SALES_ALLOCATION_PENDING' WHERE id=v_id;
    RETURN jsonb_build_object('ok',true,'batch_id',v_id,'orders',jsonb_array_length(p_batch->'orders'),
        'payments',jsonb_array_length(p_batch->'payments'),'tip_events_inserted',v_tips,'report_discount_groups_inserted',v_discounts,
        'metrics',v_actual,'sales_events_posted',false,'sales_allocation_pending',true);
END;
$$;
REVOKE ALL ON FUNCTION rb04.import_clover_csv_batch_dev(jsonb) FROM PUBLIC,anon,authenticated,service_role;

CREATE VIEW rb04.accountability_collections_daily WITH (security_invoker=true) AS
SELECT id AS batch_id,merchant_id,business_date,window_start,window_end,status,actual_metrics,reference_metrics,
       true AS sales_allocation_pending
FROM rb04.clover_import_batches WHERE status='COLLECTIONS_RECONCILED_SALES_ALLOCATION_PENDING';
REVOKE ALL ON rb04.accountability_collections_daily FROM PUBLIC,anon,authenticated;
GRANT SELECT ON rb04.accountability_collections_daily TO service_role;

CREATE FUNCTION public.rb04_app_operations_dev(p_user_id uuid,p_action text,p_params jsonb DEFAULT '{}')
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path='' AS $$
DECLARE
    v_merchant constant uuid := '44b7802c-9152-4a58-a81f-b12280f809e7';
    m rb04.dashboard_memberships%ROWTYPE;
    e rb04.accountability_events%ROWTYPE;
    rule rb04.accountability_approval_rules%ROWTYPE;
    v_id uuid;
    v_rows jsonb;
    v_start date;
    v_end date;
    v_decision text;
    v_reason text;
    v_name text;
BEGIN
    IF auth.role() IS DISTINCT FROM 'service_role' THEN RAISE EXCEPTION 'Service role required' USING ERRCODE='42501'; END IF;
    SELECT * INTO m FROM rb04.dashboard_memberships WHERE user_id=p_user_id AND merchant_id=v_merchant AND active IS TRUE;
    IF NOT FOUND OR m.app_role NOT IN ('OWNER','ADMIN','MANAGER') THEN
        RETURN jsonb_build_object('ok',false,'code','FORBIDDEN');
    END IF;
    IF p_action='financial_summary' THEN
        v_start := (p_params->>'start')::date; v_end := (p_params->>'end')::date;
        IF v_start IS NULL OR v_end IS NULL OR v_end<v_start OR v_end-v_start>92 THEN
            RETURN jsonb_build_object('ok',false,'code','INVALID_REQUEST');
        END IF;
        SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.business_date),'[]') INTO v_rows FROM
            (SELECT batch_id,business_date,status,actual_metrics,reference_metrics,sales_allocation_pending FROM rb04.accountability_collections_daily
             WHERE merchant_id=v_merchant AND business_date BETWEEN v_start AND v_end ORDER BY business_date LIMIT 94) q;
    ELSIF p_action='list_rules' THEN
        IF m.app_role NOT IN ('OWNER','ADMIN') THEN RETURN jsonb_build_object('ok',false,'code','FORBIDDEN'); END IF;
        SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.effective_from,q.event_type,q.approver_role),'[]') INTO v_rows FROM
            (SELECT id,event_type,approver_role,max_amount_cents,requires_reason,requires_approval,effective_from,effective_to,policy_reference
             FROM rb04.accountability_approval_rules WHERE merchant_id=v_merchant ORDER BY effective_from,event_type,approver_role LIMIT 500) q;
    ELSIF p_action='save_rule' THEN
        IF m.app_role<>'OWNER' THEN RETURN jsonb_build_object('ok',false,'code','FORBIDDEN'); END IF;
        IF p_params->>'eventType' NOT IN ('COMP','DISCOUNT','VOID','REFUND','OTHER') OR p_params->>'approverRole' NOT IN ('OWNER','MANAGER')
           OR nullif(trim(p_params->>'policyReference'),'') IS NULL OR length(p_params->>'policyReference')>500
           OR p_params->>'effectiveFrom' IS NULL OR p_params->>'requiresApproval' IS NULL
           OR (p_params->>'maxAmountCents')::bigint<0 THEN RETURN jsonb_build_object('ok',false,'code','INVALID_REQUEST'); END IF;
        INSERT INTO rb04.accountability_approval_rules(merchant_id,event_type,approver_role,max_amount_cents,requires_reason,requires_approval,effective_from,effective_to,policy_reference)
        VALUES(v_merchant,p_params->>'eventType',p_params->>'approverRole',(p_params->>'maxAmountCents')::bigint,true,
            (p_params->>'requiresApproval')::boolean,(p_params->>'effectiveFrom')::date,(p_params->>'effectiveTo')::date,trim(p_params->>'policyReference'))
        ON CONFLICT (merchant_id,event_type,approver_role,effective_from) DO UPDATE SET max_amount_cents=EXCLUDED.max_amount_cents,
            requires_approval=EXCLUDED.requires_approval,effective_to=EXCLUDED.effective_to,policy_reference=EXCLUDED.policy_reference
        RETURNING id INTO v_id;
        RETURN jsonb_build_object('ok',true,'rule_id',v_id,'role',m.app_role);
    ELSIF p_action IN ('history','review') THEN
        SELECT * INTO e FROM rb04.accountability_events WHERE merchant_id=v_merchant AND id=(p_params->>'eventId')::uuid FOR UPDATE;
        IF NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','NOT_FOUND'); END IF;
        IF p_action='review' THEN
            IF m.app_role NOT IN ('OWNER','MANAGER') THEN RETURN jsonb_build_object('ok',false,'code','FORBIDDEN'); END IF;
            IF e.event_type NOT IN ('COMP','DISCOUNT','VOID','REFUND','OTHER') THEN RETURN jsonb_build_object('ok',false,'code','INVALID_REQUEST'); END IF;
            v_decision := p_params->>'decision'; v_reason := trim(p_params->>'reason');
            IF v_decision NOT IN ('APPROVED','REJECTED','NEEDS_INFORMATION','ESCALATED','ACKNOWLEDGED') OR v_reason IS NULL OR length(v_reason) NOT BETWEEN 1 AND 2000 THEN
                RETURN jsonb_build_object('ok',false,'code','INVALID_REQUEST');
            END IF;
            SELECT * INTO rule FROM rb04.accountability_approval_rules WHERE merchant_id=v_merchant AND event_type=e.event_type
                AND approver_role=m.app_role AND effective_from<=e.business_date AND (effective_to IS NULL OR effective_to>=e.business_date)
                AND requires_approval IS TRUE AND (max_amount_cents IS NULL OR max_amount_cents>=e.amount_cents)
                ORDER BY effective_from DESC LIMIT 1;
            IF v_decision IN ('APPROVED','REJECTED') AND NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','POLICY_REQUIRED'); END IF;
            SELECT display_name INTO v_name FROM rb04.accountability_employees WHERE merchant_id=v_merchant AND id=m.accountability_employee_id;
            INSERT INTO rb04.accountability_reviews(merchant_id,event_id,reviewer_employee_id,reviewer_display_name,reviewer_role,decision,reason,policy_reference,reviewer_user_id)
            VALUES(v_merchant,e.id,m.accountability_employee_id,coalesce(v_name,m.app_role),m.app_role,v_decision,v_reason,rule.policy_reference,p_user_id)
            RETURNING id INTO v_id;
            IF v_decision IN ('APPROVED','REJECTED') THEN
                UPDATE rb04.accountability_exceptions SET status='RESOLVED',resolved_at=now(),resolution_notes=v_decision||': '||v_reason
                WHERE merchant_id=v_merchant AND event_id=e.id AND status IN ('OPEN','IN_REVIEW');
            ELSIF v_decision IN ('NEEDS_INFORMATION','ESCALATED') THEN
                UPDATE rb04.accountability_exceptions SET status='IN_REVIEW' WHERE merchant_id=v_merchant AND event_id=e.id AND status='OPEN';
            END IF;
            RETURN jsonb_build_object('ok',true,'review_id',v_id,'decision',v_decision,'role',m.app_role);
        END IF;
        SELECT coalesce(jsonb_agg(to_jsonb(q) ORDER BY q.reviewed_at DESC,q.created_at DESC,q.id DESC),'[]') INTO v_rows FROM
            (SELECT id,reviewer_display_name,reviewer_role,decision,reason,policy_reference,reviewed_at,created_at
             FROM rb04.accountability_reviews WHERE merchant_id=v_merchant AND event_id=e.id ORDER BY reviewed_at DESC,created_at DESC,id DESC LIMIT 100) q;
    ELSE RETURN jsonb_build_object('ok',false,'code','INVALID_REQUEST');
    END IF;
    RETURN jsonb_build_object('ok',true,'role',m.app_role,'merchant_id',v_merchant,'rows',v_rows);
END;
$$;
REVOKE ALL ON FUNCTION public.rb04_app_operations_dev(uuid,text,jsonb) FROM PUBLIC,anon,authenticated;
GRANT EXECUTE ON FUNCTION public.rb04_app_operations_dev(uuid,text,jsonb) TO service_role;

COMMIT;
