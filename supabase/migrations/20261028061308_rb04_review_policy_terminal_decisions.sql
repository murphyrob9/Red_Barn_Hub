BEGIN;
CREATE OR REPLACE FUNCTION public.rb04_app_operations_dev(p_user_id uuid,p_action text,p_params jsonb DEFAULT '{}')
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
                AND (max_amount_cents IS NULL OR max_amount_cents>=e.amount_cents)
                ORDER BY effective_from DESC LIMIT 1;
            IF v_decision IN ('APPROVED','REJECTED','ACKNOWLEDGED') AND NOT FOUND THEN RETURN jsonb_build_object('ok',false,'code','POLICY_REQUIRED'); END IF;
            IF v_decision='ACKNOWLEDGED' AND rule.requires_approval IS TRUE THEN
                RETURN jsonb_build_object('ok',false,'code','APPROVAL_REQUIRED');
            END IF;
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

COMMIT;
