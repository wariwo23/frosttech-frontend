-- FrostTech Notification Recovery — Draft migration
-- Review only. Do not apply until separately approved.
-- Prevent the public notification sender from reclaiming failed/stale events.
-- Only the authenticated Super Administrator can initiate a controlled recovery.

CREATE OR REPLACE FUNCTION public.claim_frosttech_email_event_v2(
  p_event_key text,
  p_event_type text,
  p_recipient text,
  p_payload jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_event public.email_notification_events%ROWTYPE;
  v_token uuid;
  v_payload jsonb;
BEGIN
  IF COALESCE(auth.role(), '') <> 'service_role' THEN
    RAISE EXCEPTION 'Not authorized';
  END IF;

  IF p_event_key IS NULL OR pg_catalog.length(pg_catalog.btrim(p_event_key)) = 0
     OR pg_catalog.length(p_event_key) > 256 THEN
    RAISE EXCEPTION 'Invalid event key';
  END IF;

  IF p_event_type NOT IN ('quote_request_submitted','advertiser_application_submitted') THEN
    RAISE EXCEPTION 'Unsupported event type';
  END IF;

  IF p_recipient IS NULL OR pg_catalog.length(pg_catalog.btrim(p_recipient)) = 0
     OR pg_catalog.length(p_recipient) > 320 THEN
    RAISE EXCEPTION 'Invalid recipient';
  END IF;

  v_payload := COALESCE(p_payload, '{}'::jsonb);
  IF pg_catalog.jsonb_typeof(v_payload) <> 'object'
     OR pg_catalog.octet_length(v_payload::text) > 65536 THEN
    RAISE EXCEPTION 'Invalid notification payload';
  END IF;

  INSERT INTO public.email_notification_events(event_key,event_type,recipient,payload)
  VALUES(p_event_key,p_event_type,p_recipient,v_payload)
  ON CONFLICT(event_key) DO NOTHING;

  SELECT * INTO v_event
  FROM public.email_notification_events
  WHERE event_key = p_event_key
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Notification event could not be loaded'; END IF;

  IF v_event.event_type <> p_event_type OR v_event.recipient <> p_recipient
     OR v_event.payload <> v_payload THEN
    RAISE EXCEPTION 'Event key conflicts with existing notification data';
  END IF;

  -- Normal/public notification path may claim only never-attempted pending events.
  -- Failed and stale-sending events require the separate Super Admin recovery path.
  IF v_event.status <> 'pending' OR v_event.attempts <> 0 THEN
    RETURN NULL;
  END IF;

  v_token := pg_catalog.gen_random_uuid();
  UPDATE public.email_notification_events
  SET status='sending', attempts=attempts+1, claim_token=v_token,
      updated_at=pg_catalog.now(), last_error=NULL
  WHERE id=v_event.id;

  RETURN v_token;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_list_notification_events(
  p_limit integer DEFAULT 50,
  p_offset integer DEFAULT 0
)
RETURNS TABLE(
  id uuid,
  event_type text,
  recipient text,
  status text,
  attempts integer,
  provider_message_id text,
  last_error text,
  created_at timestamptz,
  updated_at timestamptz,
  sent_at timestamptz
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Super Administrator access required';
  END IF;
  IF p_limit IS NULL OR p_limit < 1 OR p_limit > 100
     OR p_offset IS NULL OR p_offset < 0 THEN
    RAISE EXCEPTION 'Invalid pagination';
  END IF;

  RETURN QUERY
  SELECT e.id,e.event_type,e.recipient,e.status,e.attempts,
         e.provider_message_id,e.last_error,e.created_at,e.updated_at,e.sent_at
  FROM public.email_notification_events e
  ORDER BY e.created_at DESC
  LIMIT p_limit OFFSET p_offset;
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_begin_notification_recovery(
  p_event_id uuid,
  p_reason text,
  p_confirm boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_event public.email_notification_events%ROWTYPE;
  v_token uuid;
  v_provider_status text;
  v_error_json jsonb;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Super Administrator access required';
  END IF;
  IF p_confirm IS DISTINCT FROM true THEN
    RAISE EXCEPTION 'Explicit recovery confirmation is required';
  END IF;
  IF p_reason IS NULL OR pg_catalog.length(pg_catalog.btrim(p_reason)) < 12
     OR pg_catalog.length(p_reason) > 1000 THEN
    RAISE EXCEPTION 'A recovery reason of 12–1000 characters is required';
  END IF;

  SELECT * INTO v_event
  FROM public.email_notification_events
  WHERE id=p_event_id
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Notification event not found'; END IF;
  IF v_event.status <> 'failed' THEN
    RAISE EXCEPTION 'Only confirmed failed events may be recovered';
  END IF;

  -- Only a recorded, definitive non-transient provider 4xx rejection is retryable.
  -- Network errors, missing provider responses, 5xx, 408, 409, 425 and 429
  -- remain uncertain and must never be automatically resent.
  BEGIN
    v_error_json := v_event.last_error::jsonb;
  EXCEPTION WHEN OTHERS THEN
    v_error_json := NULL;
  END;
  v_provider_status := COALESCE(
    v_error_json->>'http_status',
    v_error_json->>'statusCode'
  );

  IF v_provider_status IS NULL OR v_provider_status !~ '^[0-9]{3}

  INSERT INTO public.admin_activity_log(actor_user_id,action,target_user_id,details)
  VALUES(
    auth.uid(),
    'notification_recovery_started',
    NULL,
    pg_catalog.jsonb_build_object(
      'event_id',v_event.id,'event_type',v_event.event_type,
      'previous_status',v_event.status,'attempt',v_event.attempts+1,
      'reason',pg_catalog.btrim(p_reason),'started_at',pg_catalog.now()
    )
  );

  RETURN pg_catalog.jsonb_build_object(
    'event_id',v_event.id,'event_key',v_event.event_key,
    'event_type',v_event.event_type,'recipient',v_event.recipient,
    'payload',v_event.payload,'claim_token',v_token
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_finish_notification_recovery(
  p_event_id uuid,
  p_claim_token uuid,
  p_status text,
  p_provider_message_id text DEFAULT NULL,
  p_error text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_event public.email_notification_events%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Super Administrator access required';
  END IF;
  IF p_status NOT IN ('sent','failed') THEN
    RAISE EXCEPTION 'Invalid recovery result';
  END IF;

  SELECT * INTO v_event
  FROM public.email_notification_events
  WHERE id=p_event_id AND claim_token=p_claim_token AND status='sending'
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Recovery claim expired or no longer belongs to this operation'; END IF;

  UPDATE public.email_notification_events
  SET status=p_status,
      provider_message_id=CASE WHEN p_status='sent' THEN p_provider_message_id ELSE provider_message_id END,
      sent_at=CASE WHEN p_status='sent' THEN pg_catalog.now() ELSE sent_at END,
      last_error=CASE WHEN p_status='failed' THEN pg_catalog.left(COALESCE(p_error,'Recovery failed'),2000) ELSE NULL END,
      claim_token=NULL,
      updated_at=pg_catalog.now()
  WHERE id=p_event_id;

  INSERT INTO public.admin_activity_log(actor_user_id,action,target_user_id,details)
  VALUES(
    auth.uid(),
    'notification_recovery_finished',
    NULL,
    pg_catalog.jsonb_build_object(
      'event_id',v_event.id,'event_type',v_event.event_type,
      'result_status',p_status,'provider_message_id',p_provider_message_id,
      'error',CASE WHEN p_status='failed' THEN pg_catalog.left(COALESCE(p_error,''),1000) ELSE NULL END,
      'finished_at',pg_catalog.now()
    )
  );
  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_list_notification_events(integer,integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_begin_notification_recovery(uuid,text,boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_finish_notification_recovery(uuid,uuid,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_notification_events(integer,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_begin_notification_recovery(uuid,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_finish_notification_recovery(uuid,uuid,text,text,text) TO authenticated;

     OR v_provider_status::integer < 400 OR v_provider_status::integer >= 500
     OR v_provider_status::integer IN (408,409,425,429) THEN
    RAISE EXCEPTION 'Recovery blocked: provider outcome is not a confirmed retry-safe rejection';
  END IF;

  IF v_provider_status = '403'
     AND (
       pg_catalog.position('verify a domain' in pg_catalog.lower(COALESCE(v_event.last_error,''))) > 0
       OR pg_catalog.position('testing emails' in pg_catalog.lower(COALESCE(v_event.last_error,''))) > 0
     ) THEN
    RAISE EXCEPTION 'Recovery blocked: the sender-domain restriction must be resolved by the domain owner first';
  END IF;

  v_token := pg_catalog.gen_random_uuid();
  UPDATE public.email_notification_events
  SET status='sending', attempts=attempts+1, claim_token=v_token,
      updated_at=pg_catalog.now()
  WHERE id=v_event.id;

  INSERT INTO public.admin_activity_log(actor_user_id,action,target_user_id,details)
  VALUES(
    auth.uid(),
    'notification_recovery_started',
    auth.uid(),
    pg_catalog.jsonb_build_object(
      'event_id',v_event.id,'event_type',v_event.event_type,
      'previous_status',v_event.status,'attempt',v_event.attempts+1,
      'reason',pg_catalog.btrim(p_reason),'started_at',pg_catalog.now()
    )
  );

  RETURN pg_catalog.jsonb_build_object(
    'event_id',v_event.id,'event_key',v_event.event_key,
    'event_type',v_event.event_type,'recipient',v_event.recipient,
    'payload',v_event.payload,'claim_token',v_token
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.admin_finish_notification_recovery(
  p_event_id uuid,
  p_claim_token uuid,
  p_status text,
  p_provider_message_id text DEFAULT NULL,
  p_error text DEFAULT NULL
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO ''
AS $function$
DECLARE
  v_event public.email_notification_events%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL OR NOT public.is_super_admin() THEN
    RAISE EXCEPTION 'Super Administrator access required';
  END IF;
  IF p_status NOT IN ('sent','failed') THEN
    RAISE EXCEPTION 'Invalid recovery result';
  END IF;

  SELECT * INTO v_event
  FROM public.email_notification_events
  WHERE id=p_event_id AND claim_token=p_claim_token AND status='sending'
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'Recovery claim expired or no longer belongs to this operation'; END IF;

  UPDATE public.email_notification_events
  SET status=p_status,
      provider_message_id=CASE WHEN p_status='sent' THEN p_provider_message_id ELSE provider_message_id END,
      sent_at=CASE WHEN p_status='sent' THEN pg_catalog.now() ELSE sent_at END,
      last_error=CASE WHEN p_status='failed' THEN pg_catalog.left(COALESCE(p_error,'Recovery failed'),2000) ELSE NULL END,
      claim_token=NULL,
      updated_at=pg_catalog.now()
  WHERE id=p_event_id;

  INSERT INTO public.admin_activity_log(actor_user_id,action,target_user_id,details)
  VALUES(
    auth.uid(),
    'notification_recovery_finished',
    auth.uid(),
    pg_catalog.jsonb_build_object(
      'event_id',v_event.id,'event_type',v_event.event_type,
      'result_status',p_status,'provider_message_id',p_provider_message_id,
      'error',CASE WHEN p_status='failed' THEN pg_catalog.left(COALESCE(p_error,''),1000) ELSE NULL END,
      'finished_at',pg_catalog.now()
    )
  );
  RETURN true;
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_list_notification_events(integer,integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_begin_notification_recovery(uuid,text,boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.admin_finish_notification_recovery(uuid,uuid,text,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_notification_events(integer,integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_begin_notification_recovery(uuid,text,boolean) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_finish_notification_recovery(uuid,uuid,text,text,text) TO authenticated;
