--
-- PostgreSQL database dump
--

\restrict gMIZ9zW2a0OeNag0tfMx1UyrMkWXa1RA3jBxCD6IOel4GbAN8qVDW0ThVymvgjB

-- Dumped from database version 18.0
-- Dumped by pg_dump version 18.0

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: btree_gist; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS btree_gist WITH SCHEMA public;


--
-- Name: EXTENSION btree_gist; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION btree_gist IS 'support for indexing common datatypes in GiST';


--
-- Name: branch_has_hours(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.branch_has_hours(p_branch_id integer) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT p_branch_id IS NOT NULL
   AND EXISTS (SELECT 1 FROM branch_weekly_hours w WHERE w.branch_id = p_branch_id AND w.active = TRUE);
$$;


--
-- Name: branch_hours_on(integer, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.branch_hours_on(p_branch_id integer, p_day date) RETURNS TABLE(start_time time without time zone, end_time time without time zone)
    LANGUAGE sql STABLE
    AS $$
SELECT w.start_time, w.end_time
FROM branch_weekly_hours w
WHERE w.branch_id = p_branch_id
  AND w.active = TRUE
  AND w.day_of_week = EXTRACT(ISODOW FROM p_day)::INT
  AND (w.valid_from IS NULL OR p_day >= w.valid_from)
  AND (w.valid_to IS NULL OR p_day <= w.valid_to)
  AND (
        w.valid_from IS NOT NULL OR w.valid_to IS NOT NULL
        OR NOT EXISTS (
            SELECT 1
            FROM branch_weekly_hours v
            WHERE v.branch_id = w.branch_id
              AND v.active = TRUE
              AND v.day_of_week = w.day_of_week
              AND (v.valid_from IS NOT NULL OR v.valid_to IS NOT NULL)
              AND (v.valid_from IS NULL OR p_day >= v.valid_from)
              AND (v.valid_to IS NULL OR p_day <= v.valid_to)
        )
      );
$$;


--
-- Name: business_buffer_minutes(integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.business_buffer_minutes(p_business_id integer) RETURNS integer
    LANGUAGE sql STABLE
    AS $_$
SELECT COALESCE((
    SELECT CASE WHEN v ~ '^[0-9]{1,3}$' THEN v::INT END
    FROM (
        SELECT COALESCE(b.configuration ->> 'booking.bufferMinutes', b.configuration #>> '{booking,bufferMinutes}') AS v
        FROM businesses b
        WHERE b.business_id = p_business_id
    ) x
), 0);
$_$;


--
-- Name: calendar_business_of(integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.calendar_business_of(p_branch_id integer, p_professional_id integer) RETURNS integer
    LANGUAGE sql STABLE
    AS $$
SELECT COALESCE(
    (SELECT business_id FROM branches WHERE branch_id = p_branch_id),
    (SELECT business_id FROM professionals WHERE professional_id = p_professional_id)
);
$$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: holidays; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.holidays (
    holiday_id bigint NOT NULL,
    date date NOT NULL,
    name text,
    branch_id integer,
    business_id integer,
    professional_id integer,
    kind character varying(20) DEFAULT 'HOLIDAY'::character varying NOT NULL,
    end_date date,
    open_anyway boolean DEFAULT false NOT NULL,
    start_time time without time zone,
    end_time time without time zone,
    reason_type character varying(20),
    recurrence character varying(12) DEFAULT 'NONE'::character varying NOT NULL,
    recurrence_until date,
    source character varying(10) DEFAULT 'MANUAL'::character varying NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT ck_holidays_kind CHECK (((kind)::text = ANY ((ARRAY['HOLIDAY'::character varying, 'CLOSED'::character varying, 'SPECIAL_HOURS'::character varying])::text[]))),
    CONSTRAINT ck_holidays_open_anyway CHECK (((NOT open_anyway) OR ((kind)::text = 'HOLIDAY'::text))),
    CONSTRAINT ck_holidays_range CHECK (((end_date IS NULL) OR (end_date >= date))),
    CONSTRAINT ck_holidays_reason CHECK (((reason_type IS NULL) OR ((reason_type)::text = ANY ((ARRAY['VACATION'::character varying, 'MEDICAL'::character varying, 'EVENT'::character varying, 'INVENTORY'::character varying, 'UNFORESEEN'::character varying, 'OTHER'::character varying])::text[])))),
    CONSTRAINT ck_holidays_recurrence CHECK (((recurrence)::text = ANY ((ARRAY['NONE'::character varying, 'YEARLY'::character varying, 'MONTHLY'::character varying, 'MONTHLY_NTH'::character varying, 'WEEKLY'::character varying])::text[]))),
    CONSTRAINT ck_holidays_source CHECK (((source)::text = ANY ((ARRAY['COUNTRY'::character varying, 'MANUAL'::character varying])::text[]))),
    CONSTRAINT ck_holidays_special_hours CHECK (((((kind)::text = 'SPECIAL_HOURS'::text) AND (start_time IS NOT NULL) AND (end_time IS NOT NULL) AND (start_time < end_time)) OR (((kind)::text <> 'SPECIAL_HOURS'::text) AND (start_time IS NULL) AND (end_time IS NULL))))
);


--
-- Name: calendar_day_events(integer, integer, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.calendar_day_events(p_branch_id integer, p_professional_id integer, p_day date) RETURNS SETOF public.holidays
    LANGUAGE sql STABLE
    AS $$
SELECT h.*
FROM holidays h
WHERE (h.business_id IS NULL OR h.business_id = public.calendar_business_of(p_branch_id, p_professional_id))
  AND (h.branch_id IS NULL OR h.branch_id = p_branch_id)
  AND (h.professional_id IS NULL OR h.professional_id = p_professional_id)
  AND public.calendar_event_matches(h.date, h.end_date, h.recurrence, h.recurrence_until, p_day);
$$;


--
-- Name: calendar_event_matches(date, date, text, date, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.calendar_event_matches(p_date date, p_end_date date, p_recurrence text, p_until date, p_day date) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
SELECT CASE
    WHEN p_recurrence IS NULL OR p_recurrence = 'NONE' THEN
        p_day BETWEEN p_date AND COALESCE(p_end_date, p_date)
    WHEN p_day < p_date OR (p_until IS NOT NULL AND p_day > p_until) THEN
        FALSE
    WHEN p_recurrence = 'WEEKLY' THEN
        ((p_day - p_date) % 7) <= COALESCE(p_end_date, p_date) - p_date
    WHEN p_recurrence = 'MONTHLY_NTH' THEN
        EXTRACT(ISODOW FROM p_day) = EXTRACT(ISODOW FROM p_date)
        AND (EXTRACT(DAY FROM p_day)::INT - 1) / 7 = (EXTRACT(DAY FROM p_date)::INT - 1) / 7
    WHEN p_recurrence = 'MONTHLY' THEN
        EXISTS (
            SELECT 1
            FROM generate_series(0, 1) AS back(n),
                 LATERAL (SELECT (p_date + make_interval(months =>
                        ((EXTRACT(YEAR FROM p_day)::INT - EXTRACT(YEAR FROM p_date)::INT) * 12
                         + EXTRACT(MONTH FROM p_day)::INT - EXTRACT(MONTH FROM p_date)::INT - back.n)))::DATE AS s) occ
            WHERE p_day BETWEEN occ.s AND occ.s + (COALESCE(p_end_date, p_date) - p_date)
        )
    WHEN p_recurrence = 'YEARLY' THEN
        EXISTS (
            SELECT 1
            FROM generate_series(0, 1) AS back(n),
                 LATERAL (SELECT (p_date + make_interval(years =>
                        (EXTRACT(YEAR FROM p_day)::INT - EXTRACT(YEAR FROM p_date)::INT - back.n)))::DATE AS s) occ
            WHERE p_day BETWEEN occ.s AND occ.s + (COALESCE(p_end_date, p_date) - p_date)
        )
    ELSE FALSE
END;
$$;


--
-- Name: calendar_is_closed(integer, integer, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.calendar_is_closed(p_branch_id integer, p_professional_id integer, p_day date) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
SELECT EXISTS (
        SELECT 1 FROM public.calendar_day_events(p_branch_id, p_professional_id, p_day) e WHERE e.kind = 'CLOSED'
    )
    OR COALESCE((
        SELECT NOT e.open_anyway
        FROM public.calendar_day_events(p_branch_id, p_professional_id, p_day) e
        WHERE e.kind = 'HOLIDAY'
        ORDER BY (e.branch_id IS NOT NULL) DESC, (e.business_id IS NOT NULL) DESC, e.holiday_id DESC
        LIMIT 1
    ), FALSE);
$$;


--
-- Name: calendar_special_hours(integer, integer, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.calendar_special_hours(p_branch_id integer, p_professional_id integer, p_day date) RETURNS TABLE(start_time time without time zone, end_time time without time zone, scope text)
    LANGUAGE sql STABLE
    AS $$
SELECT e.start_time, e.end_time,
       CASE WHEN e.professional_id IS NOT NULL THEN 'PROFESSIONAL'
            WHEN e.branch_id IS NOT NULL THEN 'BRANCH'
            ELSE 'BUSINESS' END
FROM public.calendar_day_events(p_branch_id, p_professional_id, p_day) e
WHERE e.kind = 'SPECIAL_HOURS'
ORDER BY (e.professional_id IS NOT NULL) DESC, (e.branch_id IS NOT NULL) DESC, e.holiday_id DESC
LIMIT 1;
$$;


--
-- Name: effective_working_spans(integer, integer, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.effective_working_spans(p_professional_id integer, p_branch_id integer, p_day date) RETURNS TABLE(span_start timestamp without time zone, span_end timestamp without time zone)
    LANGUAGE sql STABLE
    AS $$
WITH special AS (
    SELECT * FROM public.calendar_special_hours(p_branch_id, p_professional_id, p_day)
),
weekly AS (
    SELECT * FROM public.professional_hours_on(p_professional_id, p_branch_id, p_day)
),
prof_spans AS (
    -- a special day of this very professional: works exactly then
    SELECT p_day::timestamp + s.start_time AS a, p_day::timestamp + s.end_time AS b
    FROM special s WHERE s.scope = 'PROFESSIONAL'
    UNION ALL
    -- a special day of the branch or the business: whoever works that weekday works the special hours
    SELECT p_day::timestamp + s.start_time, p_day::timestamp + s.end_time
    FROM special s WHERE s.scope <> 'PROFESSIONAL' AND EXISTS (SELECT 1 FROM weekly)
    UNION ALL
    SELECT p_day::timestamp + w.start_time, p_day::timestamp + w.end_time
    FROM weekly w WHERE NOT EXISTS (SELECT 1 FROM special)
),
branch_spans AS (
    SELECT p_day::timestamp + s.start_time AS a, p_day::timestamp + s.end_time AS b
    FROM special s WHERE s.scope IN ('BRANCH', 'BUSINESS')
    UNION ALL
    SELECT p_day::timestamp + h.start_time, p_day::timestamp + h.end_time
    FROM public.branch_hours_on(p_branch_id, p_day) h
    WHERE NOT EXISTS (SELECT 1 FROM special s WHERE s.scope IN ('BRANCH', 'BUSINESS'))
)
SELECT GREATEST(p.a, b.a), LEAST(p.b, b.b)
FROM prof_spans p
JOIN branch_spans b ON GREATEST(p.a, b.a) < LEAST(p.b, b.b)
WHERE NOT public.calendar_is_closed(p_branch_id, p_professional_id, p_day)
  AND public.branch_has_hours(p_branch_id)
  AND NOT EXISTS (SELECT 1 FROM special s WHERE s.scope = 'PROFESSIONAL')
UNION ALL
-- no restriction by the branch: a branch without hours, a professional's own special day, or no branch at all
SELECT p.a, p.b
FROM prof_spans p
WHERE NOT public.calendar_is_closed(p_branch_id, p_professional_id, p_day)
  AND (
        NOT public.branch_has_hours(p_branch_id)
        OR EXISTS (SELECT 1 FROM special s WHERE s.scope = 'PROFESSIONAL')
      )
ORDER BY 1;
$$;


--
-- Name: get_available_days(integer, integer, date, date, integer, integer, integer[], text, integer, boolean, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_available_days(p_professional_id integer, p_branch_id integer, p_from date, p_to date, p_duration_minutes integer, p_slot_minutes integer, p_block_status_ids integer[], p_business_timezone text, p_minimum_lead_time_minutes integer, p_enforce_end_within_schedule boolean DEFAULT false, p_exclude_appointment_id integer DEFAULT NULL::integer) RETURNS TABLE(available_date date)
    LANGUAGE sql STABLE
    AS $$
WITH days AS (
    SELECT generate_series(p_from, p_to, INTERVAL '1 day')::date AS d
)
SELECT d.d AS available_date
FROM days d
WHERE EXISTS (
    SELECT 1
    FROM public.get_available_slots(
        p_professional_id,
        p_branch_id,
        d.d,
        p_duration_minutes,
        p_slot_minutes,
        p_block_status_ids,
        p_business_timezone,
        p_minimum_lead_time_minutes,
        p_enforce_end_within_schedule,
        p_exclude_appointment_id
    )
    LIMIT 1
)
ORDER BY available_date;
$$;


--
-- Name: get_available_days_by_branch(integer, date, date, integer, integer, integer[], text, integer, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_available_days_by_branch(p_branch_id integer, p_from date, p_to date, p_duration_minutes integer, p_slot_minutes integer, p_block_status_ids integer[], p_business_timezone text, p_minimum_lead_time_minutes integer, p_enforce_end_within_schedule boolean DEFAULT false) RETURNS TABLE(available_date date)
    LANGUAGE sql STABLE
    AS $$
WITH days AS (
    SELECT generate_series(p_from, p_to, INTERVAL '1 day')::date AS d
),
pros_by_day AS (
    SELECT DISTINCT d.d, w.professional_id
    FROM days d
    JOIN professional_weekly_hours w
      ON w.active = TRUE
     AND (w.branch_id = p_branch_id OR w.branch_id IS NULL)
     AND w.day_of_week = EXTRACT(ISODOW FROM d.d::timestamp)::INT
)
SELECT d.d AS available_date
FROM days d
WHERE EXISTS (
    SELECT 1
    FROM pros_by_day p
    WHERE p.d = d.d
      AND EXISTS (
            SELECT 1
            FROM public.get_available_slots(
                p.professional_id,
                p_branch_id,
                d.d,
                p_duration_minutes,
                p_slot_minutes,
                p_block_status_ids,
                p_business_timezone,
                p_minimum_lead_time_minutes,
                p_enforce_end_within_schedule
            )
            LIMIT 1
      )
)
ORDER BY available_date;
$$;


--
-- Name: get_available_slots(integer, integer, date, integer, integer, integer[], text, integer, boolean, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_available_slots(p_professional_id integer, p_branch_id integer, p_target_date date, p_duration_minutes integer, p_slot_minutes integer, p_block_status_ids integer[], p_business_timezone text, p_minimum_lead_time_minutes integer, p_enforce_end_within_schedule boolean DEFAULT false, p_exclude_appointment_id integer DEFAULT NULL::integer) RETURNS TABLE(slot_start timestamp without time zone, slot_end timestamp without time zone)
    LANGUAGE sql STABLE
    AS $$
WITH local_clock AS (
    SELECT
        CURRENT_TIMESTAMP AT TIME ZONE COALESCE(NULLIF(p_business_timezone, ''), 'America/Santiago')
            AS business_now,
        make_interval(mins => GREATEST(COALESCE(p_minimum_lead_time_minutes, 0), 0))
            AS minimum_lead_time
),
ctx AS (
    SELECT public.calendar_business_of(p_branch_id, p_professional_id) AS business_id
),
buffer AS (
    SELECT make_interval(mins => public.business_buffer_minutes(c.business_id)) AS gap FROM ctx c
),
day_bounds AS (
    SELECT
        p_target_date::timestamp AS day_start,
        (p_target_date::timestamp + INTERVAL '1 day') AS day_end,
        GREATEST(COALESCE(p_slot_minutes, 1), 1) AS slot_step_minutes
),
base_spans AS (
    SELECT s.span_start, s.span_end
    FROM public.effective_working_spans(p_professional_id, p_branch_id, p_target_date) s
),
slot_seeds AS (
    SELECT
        b.span_start,
        b.span_end,
        GREATEST(b.span_start, lc.business_now + lc.minimum_lead_time) AS first_candidate,
        CASE
            WHEN COALESCE(p_enforce_end_within_schedule, FALSE)
                THEN b.span_end - make_interval(mins => p_duration_minutes)
            ELSE b.span_end - INTERVAL '1 minute'
        END AS latest_start,
        db.slot_step_minutes
    FROM base_spans b
    CROSS JOIN local_clock lc
    CROSS JOIN day_bounds db
),
blocking_periods AS (
    SELECT
        u.start_datetime::timestamp AS block_start,
        u.end_datetime::timestamp AS block_end
    FROM professional_unavailability u
    JOIN unavailability_types ut ON ut.type_id = u.type_id
    CROSS JOIN day_bounds db
    WHERE u.professional_id = p_professional_id
      AND (u.branch_id = p_branch_id OR u.branch_id IS NULL)
      AND ut.blocks_agenda = TRUE
      AND tsrange(u.start_datetime::timestamp, u.end_datetime::timestamp, '[)')
          && tsrange(db.day_start, db.day_end, '[)')
    UNION ALL
    SELECT
        sb.start_time::timestamp AS block_start,
        sb.end_time::timestamp AS block_end
    FROM schedule_blocks sb
    CROSS JOIN day_bounds db
    CROSS JOIN ctx c
    WHERE sb.active = TRUE
      AND (
            (sb.professional_id = p_professional_id AND (sb.branch_id = p_branch_id OR sb.branch_id IS NULL))
            OR (sb.professional_id IS NULL
                AND sb.business_id = c.business_id
                AND (sb.branch_id IS NULL OR sb.branch_id = p_branch_id))
          )
      AND tsrange(sb.start_time::timestamp, sb.end_time::timestamp, '[)')
          && tsrange(db.day_start, db.day_end, '[)')
    UNION ALL
    SELECT
        a.start_datetime::timestamp AS block_start,
        (a.end_datetime + bf.gap)::timestamp AS block_end
    FROM appointments a
    CROSS JOIN day_bounds db
    CROSS JOIN buffer bf
    WHERE a.professional_id = p_professional_id
      AND (a.branch_id = p_branch_id OR a.branch_id IS NULL)
      AND a.status_id = ANY(p_block_status_ids)
      AND (p_exclude_appointment_id IS NULL OR a.appointment_id <> p_exclude_appointment_id)
      AND tsrange(a.start_datetime::timestamp, (a.end_datetime + bf.gap)::timestamp, '[)')
          && tsrange(db.day_start, db.day_end, '[)')
    UNION ALL
    SELECT
        pa.start_datetime::timestamp AS block_start,
        (pa.end_datetime + bf.gap)::timestamp AS block_end
    FROM pending_appointments pa
    CROSS JOIN day_bounds db
    CROSS JOIN buffer bf
    WHERE pa.professional_id = p_professional_id
      AND (pa.branch_id = p_branch_id OR pa.branch_id IS NULL)
      AND pa.expires_at > CURRENT_TIMESTAMP
      AND tsrange(pa.start_datetime::timestamp, (pa.end_datetime + bf.gap)::timestamp, '[)')
          && tsrange(db.day_start, db.day_end, '[)')
),
aligned_slot_seeds AS (
    SELECT
        span_start,
        span_end,
        first_candidate,
        latest_start,
        CASE
            WHEN first_candidate <= span_start THEN span_start
            ELSE span_start
                + (
                    CEIL(
                        EXTRACT(EPOCH FROM (first_candidate - span_start))
                        / (slot_step_minutes * 60)
                    )::INT * slot_step_minutes
                ) * INTERVAL '1 minute'
        END AS first_grid_start,
        slot_step_minutes
    FROM slot_seeds
),
grid_candidates AS (
    SELECT gs AS slot_start
    FROM aligned_slot_seeds s
    CROSS JOIN LATERAL generate_series(
        s.first_grid_start,
        s.latest_start,
        make_interval(mins => s.slot_step_minutes)
    ) AS gs
    WHERE s.first_grid_start <= s.latest_start
),
boundary_candidates AS (
    SELECT s.first_candidate AS slot_start
    FROM aligned_slot_seeds s
    WHERE s.first_candidate <= s.latest_start
    UNION ALL
    SELECT b.block_end AS slot_start
    FROM blocking_periods b
    JOIN aligned_slot_seeds s
      ON b.block_end >= s.first_candidate
     AND b.block_end <= s.latest_start
     AND b.block_end >= s.span_start
     AND b.block_end < s.span_end
),
day_slots AS (
    SELECT
        c.slot_start,
        c.slot_start + make_interval(mins => p_duration_minutes) AS slot_end
    FROM (
        SELECT slot_start FROM grid_candidates
        UNION ALL
        SELECT slot_start FROM boundary_candidates
    ) c
    GROUP BY c.slot_start
)
SELECT s.slot_start, s.slot_end
FROM day_slots s
WHERE public.is_appointment_range_available(
    p_professional_id,
    p_branch_id,
    s.slot_start,
    s.slot_end,
    p_block_status_ids,
    p_business_timezone,
    p_minimum_lead_time_minutes,
    p_enforce_end_within_schedule,
    p_exclude_appointment_id
)
ORDER BY s.slot_start;
$$;


--
-- Name: get_available_slots_by_branch(integer, date, integer, integer, integer[], text, integer, boolean); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_available_slots_by_branch(p_branch_id integer, p_target_date date, p_duration_minutes integer, p_slot_minutes integer, p_block_status_ids integer[], p_business_timezone text, p_minimum_lead_time_minutes integer, p_enforce_end_within_schedule boolean DEFAULT false) RETURNS TABLE(professional_id integer, slot_start timestamp without time zone, slot_end timestamp without time zone)
    LANGUAGE sql STABLE
    AS $$
WITH pros AS (
    SELECT DISTINCT w.professional_id
    FROM professional_weekly_hours w
    WHERE w.active = TRUE
      AND (w.branch_id = p_branch_id OR w.branch_id IS NULL)
      AND w.day_of_week = EXTRACT(ISODOW FROM p_target_date::timestamp)::INT
)
SELECT p.professional_id, s.slot_start, s.slot_end
FROM pros p
CROSS JOIN LATERAL public.get_available_slots(
    p.professional_id,
    p_branch_id,
    p_target_date,
    p_duration_minutes,
    p_slot_minutes,
    p_block_status_ids,
    p_business_timezone,
    p_minimum_lead_time_minutes,
    p_enforce_end_within_schedule
) AS s
ORDER BY p.professional_id, s.slot_start;
$$;


--
-- Name: is_appointment_range_available(integer, integer, timestamp without time zone, timestamp without time zone, integer[], text, integer, boolean, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.is_appointment_range_available(p_professional_id integer, p_branch_id integer, p_start_datetime timestamp without time zone, p_end_datetime timestamp without time zone, p_block_status_ids integer[], p_business_timezone text, p_minimum_lead_time_minutes integer, p_enforce_end_within_schedule boolean DEFAULT false, p_exclude_appointment_id integer DEFAULT NULL::integer) RETURNS boolean
    LANGUAGE sql STABLE
    AS $$
WITH local_clock AS (
    SELECT
        CURRENT_TIMESTAMP AT TIME ZONE COALESCE(NULLIF(p_business_timezone, ''), 'America/Santiago')
            AS business_now,
        make_interval(mins => GREATEST(COALESCE(p_minimum_lead_time_minutes, 0), 0))
            AS minimum_lead_time
),
requested AS (
    SELECT p_start_datetime AS start_dt,
           p_end_datetime AS end_dt,
           public.calendar_business_of(p_branch_id, p_professional_id) AS business_id
),
buffer AS (
    SELECT make_interval(mins => public.business_buffer_minutes(r.business_id)) AS gap FROM requested r
),
in_schedule AS (
    SELECT 1
    FROM requested r
    JOIN LATERAL public.effective_working_spans(p_professional_id, p_branch_id, r.start_dt::date) s
      ON r.start_dt >= s.span_start
     AND (
            (COALESCE(p_enforce_end_within_schedule, FALSE) = TRUE AND r.end_dt <= s.span_end)
            OR (COALESCE(p_enforce_end_within_schedule, FALSE) = FALSE AND r.start_dt < s.span_end)
         )
    LIMIT 1
),
blocking_ranges AS (
    SELECT tsrange(u.start_datetime::timestamp, u.end_datetime::timestamp, '[)') AS period
    FROM professional_unavailability u
    JOIN unavailability_types ut ON ut.type_id = u.type_id
    JOIN requested r
      ON tsrange(u.start_datetime::timestamp, u.end_datetime::timestamp, '[)')
         && tsrange(r.start_dt::timestamp, r.end_dt::timestamp, '[)')
    WHERE u.professional_id = p_professional_id
      AND (u.branch_id = p_branch_id OR u.branch_id IS NULL)
      AND ut.blocks_agenda = TRUE
    UNION ALL
    SELECT tsrange(sb.start_time::timestamp, sb.end_time::timestamp, '[)') AS period
    FROM schedule_blocks sb
    JOIN requested r
      ON tsrange(sb.start_time::timestamp, sb.end_time::timestamp, '[)')
         && tsrange(r.start_dt::timestamp, r.end_dt::timestamp, '[)')
    WHERE sb.active = TRUE
      AND (
            (sb.professional_id = p_professional_id AND (sb.branch_id = p_branch_id OR sb.branch_id IS NULL))
            OR (sb.professional_id IS NULL
                AND sb.business_id = r.business_id
                AND (sb.branch_id IS NULL OR sb.branch_id = p_branch_id))
          )
    UNION ALL
    SELECT tsrange(a.start_datetime::timestamp, (a.end_datetime + bf.gap)::timestamp, '[)') AS period
    FROM appointments a
    CROSS JOIN buffer bf
    JOIN requested r
      ON tsrange(a.start_datetime::timestamp, (a.end_datetime + bf.gap)::timestamp, '[)')
         && tsrange(r.start_dt::timestamp, (r.end_dt + bf.gap)::timestamp, '[)')
    WHERE a.professional_id = p_professional_id
      AND (a.branch_id = p_branch_id OR a.branch_id IS NULL)
      AND a.status_id = ANY(p_block_status_ids)
      AND (p_exclude_appointment_id IS NULL OR a.appointment_id <> p_exclude_appointment_id)
    UNION ALL
    SELECT tsrange(pa.start_datetime::timestamp, (pa.end_datetime + bf.gap)::timestamp, '[)') AS period
    FROM pending_appointments pa
    CROSS JOIN buffer bf
    JOIN requested r
      ON tsrange(pa.start_datetime::timestamp, (pa.end_datetime + bf.gap)::timestamp, '[)')
         && tsrange(r.start_dt::timestamp, (r.end_dt + bf.gap)::timestamp, '[)')
    WHERE pa.professional_id = p_professional_id
      AND (pa.branch_id = p_branch_id OR pa.branch_id IS NULL)
      AND pa.expires_at > CURRENT_TIMESTAMP
)
SELECT EXISTS (
    SELECT 1
    FROM requested r
    CROSS JOIN local_clock lc
    WHERE r.end_dt > r.start_dt
      AND r.start_dt >= lc.business_now + lc.minimum_lead_time
      AND EXISTS (SELECT 1 FROM in_schedule)
      AND NOT EXISTS (SELECT 1 FROM blocking_ranges)
);
$$;


--
-- Name: professional_hours_on(integer, integer, date); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.professional_hours_on(p_professional_id integer, p_branch_id integer, p_day date) RETURNS TABLE(start_time time without time zone, end_time time without time zone)
    LANGUAGE sql STABLE
    AS $$
SELECT w.start_time, w.end_time
FROM professional_weekly_hours w
WHERE w.professional_id = p_professional_id
  AND w.active = TRUE
  AND (w.branch_id = p_branch_id OR w.branch_id IS NULL)
  AND w.day_of_week = EXTRACT(ISODOW FROM p_day)::INT
  AND (w.valid_from IS NULL OR p_day >= w.valid_from)
  AND (w.valid_to IS NULL OR p_day <= w.valid_to)
  AND (
        w.valid_from IS NOT NULL OR w.valid_to IS NOT NULL
        OR NOT EXISTS (
            SELECT 1
            FROM professional_weekly_hours v
            WHERE v.professional_id = w.professional_id
              AND v.active = TRUE
              AND (v.branch_id = p_branch_id OR v.branch_id IS NULL)
              AND v.day_of_week = w.day_of_week
              AND (v.valid_from IS NOT NULL OR v.valid_to IS NOT NULL)
              AND (v.valid_from IS NULL OR p_day >= v.valid_from)
              AND (v.valid_to IS NULL OR p_day <= v.valid_to)
        )
      );
$$;


--
-- Name: admin_audit_events; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_audit_events (
    event_id bigint NOT NULL,
    actor_user_id integer,
    action character varying(80) NOT NULL,
    target_type character varying(80) NOT NULL,
    target_id character varying(120) NOT NULL,
    previous_state jsonb,
    new_state jsonb,
    result character varying(24) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: admin_audit_events_event_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.admin_audit_events_event_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: admin_audit_events_event_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.admin_audit_events_event_id_seq OWNED BY public.admin_audit_events.event_id;


--
-- Name: admin_recovery_codes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.admin_recovery_codes (
    code_id bigint NOT NULL,
    user_id integer NOT NULL,
    code_hash character varying(64) NOT NULL,
    used_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: admin_recovery_codes_code_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.admin_recovery_codes_code_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: admin_recovery_codes_code_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.admin_recovery_codes_code_id_seq OWNED BY public.admin_recovery_codes.code_id;


--
-- Name: applications; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.applications (
    application_id bigint NOT NULL,
    user_id integer NOT NULL,
    email character varying(255) NOT NULL,
    plan_code character varying(20) NOT NULL,
    reason character varying(1000) NOT NULL,
    status character varying(10) DEFAULT 'PENDING'::character varying NOT NULL,
    decision_note character varying(500),
    decided_by integer,
    decided_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT applications_status_check CHECK (((status)::text = ANY ((ARRAY['PENDING'::character varying, 'APPROVED'::character varying, 'REJECTED'::character varying])::text[])))
);


--
-- Name: applications_application_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.applications_application_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: applications_application_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.applications_application_id_seq OWNED BY public.applications.application_id;


--
-- Name: appointment_status; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.appointment_status (
    status_id integer NOT NULL,
    business_id integer,
    status_name character varying(50) NOT NULL,
    color_code character varying(7),
    requires_payment boolean DEFAULT false,
    active boolean DEFAULT true,
    blocks_agenda boolean DEFAULT true
);


--
-- Name: appointment_status_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.appointment_status_history (
    history_id bigint NOT NULL,
    appointment_id integer NOT NULL,
    from_status character varying(50),
    to_status character varying(50) NOT NULL,
    source character varying(10) NOT NULL,
    actor_user_id integer,
    note character varying(200),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT appointment_status_history_source_check CHECK (((source)::text = ANY ((ARRAY['STAFF'::character varying, 'CLIENT'::character varying, 'SYSTEM'::character varying])::text[])))
);


--
-- Name: appointment_status_history_history_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.appointment_status_history_history_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: appointment_status_history_history_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.appointment_status_history_history_id_seq OWNED BY public.appointment_status_history.history_id;


--
-- Name: appointment_status_status_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.appointment_status_status_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: appointment_status_status_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.appointment_status_status_id_seq OWNED BY public.appointment_status.status_id;


--
-- Name: appointments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.appointments (
    appointment_id integer NOT NULL,
    customer_id integer NOT NULL,
    professional_id integer NOT NULL,
    service_id integer NOT NULL,
    status_id integer NOT NULL,
    branch_id integer,
    start_datetime timestamp without time zone NOT NULL,
    end_datetime timestamp without time zone NOT NULL,
    period tsrange GENERATED ALWAYS AS (tsrange(start_datetime, end_datetime, '[)'::text)) STORED,
    agreed_price numeric(10,2),
    notes text,
    reminder_sent boolean DEFAULT false,
    booking_source character varying(50),
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    confirmation_token_hash character varying(64),
    token_expires_at timestamp with time zone,
    version bigint DEFAULT 0 NOT NULL,
    was_rescheduled boolean DEFAULT false NOT NULL,
    review_request_sent boolean DEFAULT false,
    visit_address character varying(255),
    commission_rate numeric(5,2),
    commission_recipient character varying(20),
    reschedule_offer_until timestamp without time zone,
    CONSTRAINT appointments_check CHECK ((start_datetime < end_datetime)),
    CONSTRAINT ck_appointment_commission_rate CHECK (((commission_rate IS NULL) OR ((commission_rate >= (0)::numeric) AND (commission_rate <= (100)::numeric)))),
    CONSTRAINT ck_appointment_commission_snapshot CHECK ((((commission_rate IS NULL) AND (commission_recipient IS NULL)) OR ((commission_rate IS NOT NULL) AND (commission_recipient IS NOT NULL) AND ((commission_recipient)::text = ANY ((ARRAY['BUSINESS'::character varying, 'PROFESSIONAL'::character varying])::text[])))))
);


--
-- Name: appointments_appointment_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.appointments ALTER COLUMN appointment_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.appointments_appointment_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: attachment_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attachment_roles (
    role_id character varying(50) NOT NULL,
    description text,
    allowed_entities jsonb,
    constraints jsonb,
    active boolean DEFAULT true
);


--
-- Name: attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.attachments (
    attachment_id uuid NOT NULL,
    file_name character varying(255) NOT NULL,
    storage_key character varying(1024) NOT NULL,
    content_type character varying(100) NOT NULL,
    file_size_bytes bigint NOT NULL,
    storage_provider character varying(50) NOT NULL,
    file_sha256 text,
    created_at timestamp with time zone DEFAULT CURRENT_TIMESTAMP,
    created_by_user_id integer,
    attachment_variant character varying(100),
    attachment_version character varying(32),
    image_width integer,
    image_height integer
);


--
-- Name: audit_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.audit_log (
    log_id bigint NOT NULL,
    business_id integer NOT NULL,
    user_id integer NOT NULL,
    table_name character varying(50) NOT NULL,
    record_id integer NOT NULL,
    action character varying(20),
    old_data jsonb,
    new_data jsonb,
    ip_address character varying(45),
    user_agent character varying(500),
    "timestamp" timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    branch_id integer
);


--
-- Name: audit_log_log_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.audit_log ALTER COLUMN log_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.audit_log_log_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: automatic_reminders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.automatic_reminders (
    reminder_id integer NOT NULL,
    business_id integer NOT NULL,
    template_id integer NOT NULL,
    event_type character varying(50),
    hours_before integer,
    channel_id integer NOT NULL,
    active boolean DEFAULT true,
    branch_id integer
);


--
-- Name: automatic_reminders_reminder_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.automatic_reminders ALTER COLUMN reminder_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.automatic_reminders_reminder_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: blacklisted_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.blacklisted_tokens (
    token_hash character varying(255) NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    blacklisted_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: branch_weekly_hours; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.branch_weekly_hours (
    weekly_id bigint NOT NULL,
    branch_id integer NOT NULL,
    day_of_week integer NOT NULL,
    start_time time without time zone NOT NULL,
    end_time time without time zone NOT NULL,
    active boolean DEFAULT true NOT NULL,
    valid_from date,
    valid_to date,
    CONSTRAINT branch_weekly_hours_check CHECK ((start_time < end_time)),
    CONSTRAINT branch_weekly_hours_check1 CHECK (((valid_from IS NULL) OR (valid_to IS NULL) OR (valid_from <= valid_to))),
    CONSTRAINT branch_weekly_hours_day_of_week_check CHECK (((day_of_week >= 1) AND (day_of_week <= 7)))
);


--
-- Name: branch_weekly_hours_weekly_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.branch_weekly_hours_weekly_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: branch_weekly_hours_weekly_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.branch_weekly_hours_weekly_id_seq OWNED BY public.branch_weekly_hours.weekly_id;


--
-- Name: branches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.branches (
    branch_id integer NOT NULL,
    business_id integer NOT NULL,
    name character varying(100) NOT NULL,
    address character varying(255),
    phone character varying(50),
    email character varying(255),
    config jsonb,
    active boolean DEFAULT true,
    city character varying(100),
    region character varying(255),
    kind character varying(10) DEFAULT 'PHYSICAL'::character varying NOT NULL,
    CONSTRAINT branches_kind_check CHECK (((kind)::text = ANY ((ARRAY['PHYSICAL'::character varying, 'HOME'::character varying])::text[])))
);


--
-- Name: branches_branch_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.branches ALTER COLUMN branch_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.branches_branch_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: business_photo_comments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.business_photo_comments (
    comment_id bigint NOT NULL,
    business_id integer NOT NULL,
    photo_role character varying(50) NOT NULL,
    author_name character varying(80) NOT NULL,
    body character varying(300) NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: business_photo_comments_comment_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.business_photo_comments_comment_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: business_photo_comments_comment_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.business_photo_comments_comment_id_seq OWNED BY public.business_photo_comments.comment_id;


--
-- Name: businesses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.businesses (
    business_id integer NOT NULL,
    industry_id integer NOT NULL,
    name character varying(255),
    booking_url character varying(255),
    registration_date timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    address character varying(255),
    phone character varying(50),
    email character varying(255),
    configuration jsonb,
    active boolean DEFAULT true,
    timezone character varying(50) DEFAULT 'America/Santiago'::character varying NOT NULL,
    city character varying(100),
    description text,
    is_publicly_listed boolean DEFAULT true NOT NULL,
    average_rating double precision DEFAULT 0.0 NOT NULL,
    total_reviews integer DEFAULT 0 NOT NULL,
    profile_key character varying(20),
    attention_mode character varying(10) DEFAULT 'LOCAL'::character varying NOT NULL,
    CONSTRAINT businesses_attention_mode_check CHECK (((attention_mode)::text = ANY ((ARRAY['LOCAL'::character varying, 'HOME'::character varying, 'BOTH'::character varying])::text[]))),
    CONSTRAINT ck_businesses_profile_key CHECK (((profile_key IS NULL) OR ((profile_key)::text = ANY ((ARRAY['GENERAL'::character varying, 'BEAUTY'::character varying, 'HEALTH'::character varying, 'MENTAL_HEALTH'::character varying, 'PETS'::character varying, 'FIELD_SERVICE'::character varying])::text[]))))
);


--
-- Name: businesses_business_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.businesses ALTER COLUMN business_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.businesses_business_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: campaign_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.campaign_messages (
    message_id bigint NOT NULL,
    campaign_id integer NOT NULL,
    customer_id integer,
    first_name character varying(100),
    email character varying(255) NOT NULL,
    status character varying(10) DEFAULT 'QUEUED'::character varying NOT NULL,
    reason character varying(60),
    sent_at timestamp without time zone,
    CONSTRAINT campaign_messages_status_check CHECK (((status)::text = ANY ((ARRAY['QUEUED'::character varying, 'SENT'::character varying, 'FAILED'::character varying, 'SKIPPED'::character varying])::text[])))
);


--
-- Name: campaign_messages_message_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.campaign_messages_message_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: campaign_messages_message_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.campaign_messages_message_id_seq OWNED BY public.campaign_messages.message_id;


--
-- Name: campaign_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.campaign_templates (
    business_id integer NOT NULL,
    template_key character varying(40) NOT NULL,
    subject character varying(150) NOT NULL,
    body text NOT NULL,
    discount_text character varying(60),
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: campaigns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.campaigns (
    campaign_id integer NOT NULL,
    business_id integer NOT NULL,
    name character varying(100) NOT NULL,
    template_key character varying(40),
    segment character varying(20) NOT NULL,
    subject character varying(150) NOT NULL,
    body text NOT NULL,
    discount_text character varying(60),
    status character varying(12) DEFAULT 'QUEUED'::character varying NOT NULL,
    total_recipients integer DEFAULT 0 NOT NULL,
    sent_count integer DEFAULT 0 NOT NULL,
    failed_count integer DEFAULT 0 NOT NULL,
    skipped_count integer DEFAULT 0 NOT NULL,
    created_by_user_id integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    finished_at timestamp without time zone,
    CONSTRAINT campaigns_segment_check CHECK (((segment)::text = ANY ((ARRAY['all'::character varying, 'inactive'::character varying, 'birthday'::character varying, 'frequent'::character varying, 'recent'::character varying])::text[]))),
    CONSTRAINT campaigns_status_check CHECK (((status)::text = ANY ((ARRAY['QUEUED'::character varying, 'RUNNING'::character varying, 'COMPLETED'::character varying, 'FAILED'::character varying])::text[])))
);


--
-- Name: campaigns_campaign_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.campaigns_campaign_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: campaigns_campaign_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.campaigns_campaign_id_seq OWNED BY public.campaigns.campaign_id;


--
-- Name: cash_registers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.cash_registers (
    register_id integer NOT NULL,
    business_id integer NOT NULL,
    user_id integer NOT NULL,
    branch_id integer NOT NULL,
    date date NOT NULL,
    opening_amount numeric(12,2) DEFAULT 0.00,
    cash_inflows numeric(12,2) DEFAULT 0.00,
    cash_outflows numeric(12,2) DEFAULT 0.00,
    theoretical_amount numeric(12,2) DEFAULT 0.00,
    physical_amount numeric(12,2),
    difference numeric(12,2) DEFAULT 0.00,
    status character varying(20),
    opening_time timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    closing_time timestamp without time zone,
    notes text
);


--
-- Name: cash_registers_register_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.cash_registers ALTER COLUMN register_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.cash_registers_register_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.categories (
    category_id integer NOT NULL,
    name character varying(255) NOT NULL,
    business_id integer NOT NULL,
    is_active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT now(),
    updated_at timestamp without time zone DEFAULT now()
);


--
-- Name: categories_category_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.categories ALTER COLUMN category_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.categories_category_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: commercial_account_setups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_account_setups (
    setup_id uuid NOT NULL,
    user_id integer NOT NULL,
    billing_tenant_id uuid NOT NULL,
    business_id integer,
    completed_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT commercial_account_setups_check CHECK (((completed_at IS NULL) OR (business_id IS NOT NULL)))
);


--
-- Name: commercial_payment_checkouts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commercial_payment_checkouts (
    checkout_id uuid NOT NULL,
    setup_id uuid NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: commissions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.commissions (
    commission_id integer NOT NULL,
    detail_id integer NOT NULL,
    professional_id integer NOT NULL,
    percentage numeric(5,2) NOT NULL,
    base_amount numeric(12,2) NOT NULL,
    commission_amount numeric(12,2) NOT NULL,
    calculation_date date NOT NULL,
    paid boolean DEFAULT false,
    payment_date date,
    branch_id integer
);


--
-- Name: commissions_commission_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.commissions ALTER COLUMN commission_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.commissions_commission_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: communication_channels; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.communication_channels (
    channel_id integer NOT NULL,
    name character varying(20) NOT NULL,
    active boolean DEFAULT true
);


--
-- Name: communication_channels_channel_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.communication_channels ALTER COLUMN channel_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.communication_channels_channel_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: customer_health_profiles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_health_profiles (
    customer_id integer NOT NULL,
    national_id character varying(12),
    insurance_type character varying(20),
    insurance_name character varying(80),
    emergency_contact_name character varying(120),
    emergency_contact_phone character varying(20),
    guardian_name character varying(120),
    guardian_national_id character varying(12),
    allergies text,
    medical_notes text,
    consent_at timestamp without time zone,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_by_user_id integer,
    CONSTRAINT customer_health_profiles_insurance_type_check CHECK (((insurance_type)::text = ANY ((ARRAY['FONASA'::character varying, 'ISAPRE'::character varying, 'PARTICULAR'::character varying, 'OTRO'::character varying])::text[])))
);


--
-- Name: customer_records; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customer_records (
    record_id integer NOT NULL,
    customer_id integer NOT NULL,
    professional_id integer NOT NULL,
    appointment_id integer,
    record_type character varying(50),
    record_date timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    content text,
    attachments jsonb,
    private boolean DEFAULT false
);


--
-- Name: customer_records_record_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.customer_records ALTER COLUMN record_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.customer_records_record_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: customers; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.customers (
    customer_id integer NOT NULL,
    business_id integer NOT NULL,
    first_name character varying(100) NOT NULL,
    last_name character varying(100),
    email character varying(255),
    phone character varying(20),
    birth_date date,
    gender character varying(10),
    address character varying(255),
    notes text,
    preferences jsonb,
    last_service timestamp without time zone,
    total_spent numeric(12,2) DEFAULT 0.00,
    active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    home_branch_id integer
);


--
-- Name: customers_customer_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.customers ALTER COLUMN customer_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.customers_customer_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: delivery_statuses; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.delivery_statuses (
    status_id integer NOT NULL,
    name character varying(20) NOT NULL,
    active boolean DEFAULT true
);


--
-- Name: delivery_statuses_status_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.delivery_statuses ALTER COLUMN status_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.delivery_statuses_status_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: document_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.document_types (
    document_type_id integer NOT NULL,
    business_id integer,
    name character varying(50) NOT NULL,
    active boolean DEFAULT true,
    is_system_defined boolean DEFAULT false
);


--
-- Name: document_types_document_type_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.document_types ALTER COLUMN document_type_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.document_types_document_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: email_verification_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.email_verification_tokens (
    token_hash character varying(64) NOT NULL,
    user_id integer NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    used_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: entity_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.entity_attachments (
    attachment_id uuid NOT NULL,
    entity_type character varying(50) NOT NULL,
    entity_id text NOT NULL,
    attachment_role_id character varying(50) NOT NULL
);


--
-- Name: flyway_schema_history; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.flyway_schema_history (
    installed_rank integer NOT NULL,
    version character varying(50),
    description character varying(200) NOT NULL,
    type character varying(20) NOT NULL,
    script character varying(1000) NOT NULL,
    checksum integer,
    installed_by character varying(100) NOT NULL,
    installed_on timestamp without time zone DEFAULT now() NOT NULL,
    execution_time integer NOT NULL,
    success boolean NOT NULL
);


--
-- Name: holidays_holiday_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.holidays_holiday_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: holidays_holiday_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.holidays_holiday_id_seq OWNED BY public.holidays.holiday_id;


--
-- Name: import_batches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.import_batches (
    batch_id uuid NOT NULL,
    business_id integer NOT NULL,
    actor_user_id integer NOT NULL,
    original_filename character varying(255) NOT NULL,
    file_type character varying(20) NOT NULL,
    source character varying(30) DEFAULT 'GENERIC'::character varying NOT NULL,
    status character varying(30) NOT NULL,
    analysis_json jsonb,
    requested_mapping jsonb,
    valid_rows integer DEFAULT 0 NOT NULL,
    invalid_rows integer DEFAULT 0 NOT NULL,
    duplicate_rows integer DEFAULT 0 NOT NULL,
    imported_rows integer DEFAULT 0 NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    completed_at timestamp without time zone
);


--
-- Name: import_rows; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.import_rows (
    row_id uuid NOT NULL,
    batch_id uuid NOT NULL,
    sheet_name character varying(255),
    entity_type character varying(30) NOT NULL,
    row_number integer NOT NULL,
    raw_data jsonb NOT NULL,
    normalized_data jsonb,
    status character varying(30) NOT NULL,
    error_reason text,
    duplicate_reason text,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: industries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.industries (
    industry_id integer NOT NULL,
    name character varying(50) NOT NULL,
    description character varying(255),
    active boolean DEFAULT true,
    category_id integer,
    default_profile character varying(20) DEFAULT 'GENERAL'::character varying NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    CONSTRAINT ck_industries_default_profile CHECK (((default_profile)::text = ANY ((ARRAY['GENERAL'::character varying, 'BEAUTY'::character varying, 'HEALTH'::character varying, 'MENTAL_HEALTH'::character varying, 'PETS'::character varying, 'FIELD_SERVICE'::character varying, 'ASK'::character varying])::text[])))
);


--
-- Name: industries_industry_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.industries ALTER COLUMN industry_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.industries_industry_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: industry_categories; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.industry_categories (
    category_id integer NOT NULL,
    name character varying(60) NOT NULL,
    description character varying(255),
    sort_order integer DEFAULT 0 NOT NULL,
    active boolean DEFAULT true NOT NULL
);


--
-- Name: industry_categories_category_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.industry_categories_category_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: industry_categories_category_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.industry_categories_category_id_seq OWNED BY public.industry_categories.category_id;


--
-- Name: inventory_movements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.inventory_movements (
    movement_id integer NOT NULL,
    product_id integer NOT NULL,
    branch_id integer NOT NULL,
    user_id integer NOT NULL,
    movement_type_id integer NOT NULL,
    quantity integer NOT NULL,
    previous_stock integer NOT NULL,
    new_stock integer NOT NULL,
    reason character varying(255),
    reference_id integer,
    reference_table character varying(50),
    movement_date timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: inventory_movements_movement_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.inventory_movements ALTER COLUMN movement_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.inventory_movements_movement_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: invoices; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.invoices (
    invoice_id integer NOT NULL,
    sale_id integer NOT NULL,
    document_type_id integer NOT NULL,
    tax_folio bigint,
    issue_date timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    customer_tax_id character varying(12),
    company_name character varying(255),
    address character varying(255),
    tax_xml text,
    pdf_url character varying(500),
    tax_status character varying(50)
);


--
-- Name: invoices_invoice_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.invoices ALTER COLUMN invoice_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.invoices_invoice_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: legal_acceptances; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.legal_acceptances (
    acceptance_id bigint NOT NULL,
    user_id integer NOT NULL,
    document_type character varying(20) NOT NULL,
    document_version character varying(40) NOT NULL,
    method character varying(20) NOT NULL,
    accepted_at timestamp with time zone DEFAULT now() NOT NULL
);


--
-- Name: legal_acceptances_acceptance_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.legal_acceptances_acceptance_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: legal_acceptances_acceptance_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.legal_acceptances_acceptance_id_seq OWNED BY public.legal_acceptances.acceptance_id;


--
-- Name: local_modules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.local_modules (
    code character varying(40) NOT NULL,
    name character varying(80) NOT NULL,
    description character varying(500) DEFAULT ''::character varying NOT NULL,
    available boolean DEFAULT true NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL
);


--
-- Name: local_plan_limits; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.local_plan_limits (
    plan_code character varying(20) NOT NULL,
    key character varying(40) NOT NULL,
    value integer NOT NULL,
    CONSTRAINT local_plan_limits_value_check CHECK ((value >= 0))
);


--
-- Name: local_plans; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.local_plans (
    code character varying(20) NOT NULL,
    name character varying(60) NOT NULL,
    description character varying(300) DEFAULT ''::character varying NOT NULL,
    sort_order integer DEFAULT 0 NOT NULL,
    active boolean DEFAULT true NOT NULL
);


--
-- Name: local_subscription_modules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.local_subscription_modules (
    tenant_id uuid NOT NULL,
    module_code character varying(40) NOT NULL,
    started_at timestamp with time zone DEFAULT now() NOT NULL,
    ends_at timestamp with time zone,
    note character varying(200)
);


--
-- Name: local_subscriptions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.local_subscriptions (
    tenant_id uuid NOT NULL,
    subscription_id uuid DEFAULT gen_random_uuid() NOT NULL,
    plan_code character varying(20) NOT NULL,
    status character varying(10) DEFAULT 'ACTIVE'::character varying NOT NULL,
    additional_professionals integer DEFAULT 0 NOT NULL,
    additional_branches integer DEFAULT 0 NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT local_subscriptions_status_check CHECK (((status)::text = ANY ((ARRAY['ACTIVE'::character varying, 'CANCELED'::character varying])::text[])))
);


--
-- Name: marketing_campaigns; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.marketing_campaigns (
    campaign_id integer NOT NULL,
    business_id integer NOT NULL,
    template_id integer NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    start_date timestamp without time zone NOT NULL,
    end_date timestamp without time zone,
    segment jsonb,
    status character varying(20),
    total_recipients integer DEFAULT 0,
    total_sent integer DEFAULT 0,
    total_delivered integer DEFAULT 0,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    branch_id integer
);


--
-- Name: marketing_campaigns_campaign_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.marketing_campaigns ALTER COLUMN campaign_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.marketing_campaigns_campaign_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: marketing_optouts; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.marketing_optouts (
    business_id integer NOT NULL,
    email character varying(255) NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL
);


--
-- Name: message_deliveries; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.message_deliveries (
    delivery_id bigint NOT NULL,
    business_id integer NOT NULL,
    customer_id integer NOT NULL,
    template_id integer,
    channel_id integer NOT NULL,
    recipient character varying(255) NOT NULL,
    subject character varying(255),
    content text NOT NULL,
    status_id integer NOT NULL,
    sent_date timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    delivered_date timestamp without time zone,
    error_message text,
    external_reference character varying(255),
    branch_id integer
);


--
-- Name: message_deliveries_delivery_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.message_deliveries ALTER COLUMN delivery_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.message_deliveries_delivery_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: message_templates; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.message_templates (
    template_id integer NOT NULL,
    business_id integer NOT NULL,
    name character varying(100) NOT NULL,
    type character varying(50),
    channel_id integer NOT NULL,
    subject character varying(255),
    content text NOT NULL,
    variables jsonb,
    active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: message_templates_template_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.message_templates ALTER COLUMN template_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.message_templates_template_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: module_requests; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.module_requests (
    request_id bigint NOT NULL,
    business_id integer NOT NULL,
    module_code character varying(40) NOT NULL,
    requested_by integer NOT NULL,
    message character varying(500),
    status character varying(10) DEFAULT 'PENDING'::character varying NOT NULL,
    decision_note character varying(500),
    decided_by integer,
    decided_at timestamp with time zone,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT module_requests_status_check CHECK (((status)::text = ANY ((ARRAY['PENDING'::character varying, 'GRANTED'::character varying, 'REJECTED'::character varying])::text[])))
);


--
-- Name: module_requests_request_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.module_requests_request_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: module_requests_request_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.module_requests_request_id_seq OWNED BY public.module_requests.request_id;


--
-- Name: movement_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.movement_types (
    movement_type_id integer NOT NULL,
    name character varying(50) NOT NULL,
    active boolean DEFAULT true
);


--
-- Name: movement_types_movement_type_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.movement_types ALTER COLUMN movement_type_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.movement_types_movement_type_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: notification_dispatch_log; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.notification_dispatch_log (
    business_id integer NOT NULL,
    kind character varying(40) NOT NULL,
    period_key character varying(20) NOT NULL,
    sent_at timestamp without time zone DEFAULT now() NOT NULL
);


--
-- Name: payment_methods; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payment_methods (
    method_id integer NOT NULL,
    business_id integer NOT NULL,
    name character varying(50) NOT NULL,
    type character varying(20),
    commission numeric(5,2) DEFAULT 0.00,
    active boolean DEFAULT true
);


--
-- Name: payment_methods_method_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.payment_methods ALTER COLUMN method_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.payment_methods_method_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: payments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.payments (
    payment_id integer NOT NULL,
    sale_id integer NOT NULL,
    method_id integer NOT NULL,
    amount numeric(12,2) NOT NULL,
    reference character varying(255),
    status character varying(20),
    payment_date timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    commission_amount numeric(10,2) DEFAULT 0.00
);


--
-- Name: payments_payment_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.payments ALTER COLUMN payment_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.payments_payment_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: pending_appointments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.pending_appointments (
    pending_id uuid NOT NULL,
    customer_id integer NOT NULL,
    professional_id integer NOT NULL,
    service_id integer NOT NULL,
    branch_id integer,
    start_datetime timestamp without time zone NOT NULL,
    end_datetime timestamp without time zone NOT NULL,
    verification_code character varying(6) NOT NULL,
    expires_at timestamp with time zone NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: product_movements; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_movements (
    movement_id bigint NOT NULL,
    business_id integer NOT NULL,
    product_id integer NOT NULL,
    type character varying(12) NOT NULL,
    quantity integer NOT NULL,
    unit_price numeric(12,0),
    unit_cost numeric(12,0),
    sale_id uuid,
    customer_id integer,
    appointment_id integer,
    reason character varying(200),
    created_by integer,
    created_at timestamp without time zone DEFAULT now() NOT NULL,
    CONSTRAINT product_movements_quantity_check CHECK ((quantity <> 0)),
    CONSTRAINT product_movements_type_check CHECK (((type)::text = ANY ((ARRAY['PURCHASE'::character varying, 'SALE'::character varying, 'ADJUSTMENT'::character varying, 'LOSS'::character varying])::text[])))
);


--
-- Name: product_movements_movement_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.product_movements_movement_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: product_movements_movement_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.product_movements_movement_id_seq OWNED BY public.product_movements.movement_id;


--
-- Name: product_order_items; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_order_items (
    order_id uuid NOT NULL,
    product_id integer NOT NULL,
    name character varying(255) NOT NULL,
    quantity integer NOT NULL,
    unit_price integer NOT NULL,
    CONSTRAINT product_order_items_quantity_check CHECK ((quantity > 0)),
    CONSTRAINT product_order_items_unit_price_check CHECK ((unit_price >= 0))
);


--
-- Name: product_orders; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_orders (
    order_id uuid NOT NULL,
    business_id integer NOT NULL,
    code character varying(8) NOT NULL,
    customer_id integer,
    customer_name character varying(200) NOT NULL,
    customer_email character varying(255) NOT NULL,
    customer_phone character varying(30),
    branch_id integer,
    note character varying(300),
    status character varying(10) DEFAULT 'PENDING'::character varying NOT NULL,
    total integer NOT NULL,
    created_at timestamp without time zone NOT NULL,
    expires_at timestamp without time zone NOT NULL,
    paid_at timestamp without time zone,
    paid_by integer,
    sale_id uuid,
    cancel_reason character varying(200),
    CONSTRAINT product_orders_status_check CHECK (((status)::text = ANY ((ARRAY['PENDING'::character varying, 'PAID'::character varying, 'CANCELLED'::character varying])::text[]))),
    CONSTRAINT product_orders_total_check CHECK ((total >= 0))
);


--
-- Name: product_stocks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.product_stocks (
    product_id integer NOT NULL,
    branch_id integer NOT NULL,
    current_stock integer DEFAULT 0,
    minimum_stock integer DEFAULT 0
);


--
-- Name: products; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.products (
    product_id integer NOT NULL,
    business_id integer NOT NULL,
    barcode character varying(100),
    name character varying(255) NOT NULL,
    description text,
    category character varying(100),
    current_stock integer DEFAULT 0,
    minimum_stock integer DEFAULT 0,
    purchase_price numeric(10,2),
    sale_price numeric(10,2) NOT NULL,
    tax_included boolean DEFAULT true,
    active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    show_online boolean DEFAULT true NOT NULL
);


--
-- Name: products_product_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.products ALTER COLUMN product_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.products_product_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: professional_branches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.professional_branches (
    professional_id integer NOT NULL,
    branch_id integer NOT NULL
);


--
-- Name: professional_schedules; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.professional_schedules (
    schedule_id integer NOT NULL,
    professional_id integer NOT NULL,
    day_of_week integer NOT NULL,
    start_time time without time zone,
    end_time time without time zone,
    active boolean DEFAULT true,
    branch_id integer,
    CONSTRAINT professional_schedules_day_of_week_check CHECK (((day_of_week >= 1) AND (day_of_week <= 7)))
);


--
-- Name: professional_schedules_schedule_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.professional_schedules ALTER COLUMN schedule_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.professional_schedules_schedule_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: professional_unavailability; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.professional_unavailability (
    unavail_id bigint NOT NULL,
    professional_id integer NOT NULL,
    branch_id integer,
    type_id integer,
    start_datetime timestamp without time zone NOT NULL,
    end_datetime timestamp without time zone NOT NULL,
    note text,
    CONSTRAINT professional_unavailability_check CHECK ((start_datetime < end_datetime))
);


--
-- Name: professional_unavailability_unavail_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.professional_unavailability_unavail_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: professional_unavailability_unavail_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.professional_unavailability_unavail_id_seq OWNED BY public.professional_unavailability.unavail_id;


--
-- Name: professional_weekly_hours; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.professional_weekly_hours (
    weekly_id bigint NOT NULL,
    professional_id integer NOT NULL,
    day_of_week integer NOT NULL,
    start_time time without time zone NOT NULL,
    end_time time without time zone NOT NULL,
    branch_id integer,
    active boolean DEFAULT true,
    valid_from date,
    valid_to date,
    CONSTRAINT ck_weekly_validity CHECK (((valid_from IS NULL) OR (valid_to IS NULL) OR (valid_from <= valid_to))),
    CONSTRAINT professional_weekly_hours_check CHECK ((start_time < end_time)),
    CONSTRAINT professional_weekly_hours_day_of_week_check CHECK (((day_of_week >= 1) AND (day_of_week <= 7)))
);


--
-- Name: professional_weekly_hours_weekly_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.professional_weekly_hours_weekly_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: professional_weekly_hours_weekly_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.professional_weekly_hours_weekly_id_seq OWNED BY public.professional_weekly_hours.weekly_id;


--
-- Name: professionals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.professionals (
    professional_id integer NOT NULL,
    user_id integer NOT NULL,
    business_id integer NOT NULL,
    specialty character varying(100),
    color_code character varying(7),
    default_commission numeric(5,2),
    active boolean DEFAULT true,
    commission_recipient character varying(20) DEFAULT 'PROFESSIONAL'::character varying NOT NULL,
    CONSTRAINT ck_professional_commission_recipient CHECK (((commission_recipient)::text = ANY ((ARRAY['BUSINESS'::character varying, 'PROFESSIONAL'::character varying])::text[])))
);


--
-- Name: professionals_professional_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.professionals ALTER COLUMN professional_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.professionals_professional_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: quotes; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.quotes (
    quote_id integer NOT NULL,
    business_id integer NOT NULL,
    customer_id integer NOT NULL,
    title character varying(150) NOT NULL,
    description text,
    status character varying(10) DEFAULT 'DRAFT'::character varying NOT NULL,
    items jsonb DEFAULT '[]'::jsonb NOT NULL,
    total numeric(12,2) DEFAULT 0 NOT NULL,
    valid_until date,
    notes text,
    appointment_id integer,
    created_by_user_id integer,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP NOT NULL,
    CONSTRAINT quotes_status_check CHECK (((status)::text = ANY ((ARRAY['DRAFT'::character varying, 'SENT'::character varying, 'ACCEPTED'::character varying, 'REJECTED'::character varying])::text[])))
);


--
-- Name: quotes_quote_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.quotes_quote_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: quotes_quote_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.quotes_quote_id_seq OWNED BY public.quotes.quote_id;


--
-- Name: refresh_tokens; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.refresh_tokens (
    token_id uuid NOT NULL,
    user_id integer NOT NULL,
    jti character varying(36) NOT NULL,
    family_id uuid,
    token_hash character varying(255) NOT NULL,
    fingerprint character varying(255),
    expires_at timestamp without time zone NOT NULL,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    last_used_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    revoked boolean DEFAULT false,
    user_agent character varying(300)
);


--
-- Name: reviews; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.reviews (
    review_id bigint NOT NULL,
    business_id integer NOT NULL,
    appointment_id integer,
    rating smallint NOT NULL,
    comment character varying(500),
    author_name character varying(150),
    author_email character varying(255),
    source character varying(20) DEFAULT 'PUBLIC_LINK'::character varying NOT NULL,
    status character varying(20) DEFAULT 'VISIBLE'::character varying NOT NULL,
    verified boolean DEFAULT false NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    CONSTRAINT reviews_rating_check CHECK (((rating >= 1) AND (rating <= 5))),
    CONSTRAINT reviews_source_check CHECK (((source)::text = ANY ((ARRAY['APPOINTMENT'::character varying, 'PUBLIC_LINK'::character varying, 'QR'::character varying])::text[]))),
    CONSTRAINT reviews_status_check CHECK (((status)::text = ANY ((ARRAY['VISIBLE'::character varying, 'HIDDEN'::character varying, 'PENDING'::character varying])::text[])))
);


--
-- Name: reviews_review_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.reviews_review_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: reviews_review_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.reviews_review_id_seq OWNED BY public.reviews.review_id;


--
-- Name: roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.roles (
    role_id integer NOT NULL,
    role_name character varying(50) NOT NULL,
    description character varying(255),
    permissions jsonb,
    active boolean DEFAULT true
);


--
-- Name: roles_role_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.roles ALTER COLUMN role_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.roles_role_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: sale_details; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sale_details (
    detail_id integer NOT NULL,
    sale_id integer NOT NULL,
    product_id integer,
    appointment_id integer,
    description character varying(255) NOT NULL,
    quantity integer NOT NULL,
    unit_price numeric(10,2) NOT NULL,
    discount numeric(10,2) DEFAULT 0.00,
    line_total numeric(12,2) NOT NULL
);


--
-- Name: sale_details_detail_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.sale_details ALTER COLUMN detail_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.sale_details_detail_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: sales; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.sales (
    sale_id integer NOT NULL,
    business_id integer NOT NULL,
    customer_id integer,
    user_id integer NOT NULL,
    sale_number character varying(50),
    subtotal numeric(12,2) NOT NULL,
    discount numeric(12,2) DEFAULT 0.00,
    tax numeric(12,2) DEFAULT 0.00,
    total_amount numeric(12,2) NOT NULL,
    sale_date timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    notes text,
    branch_id integer
);


--
-- Name: sales_sale_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.sales ALTER COLUMN sale_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.sales_sale_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: schedule_blocks; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.schedule_blocks (
    block_id integer NOT NULL,
    business_id integer NOT NULL,
    branch_id integer,
    professional_id integer,
    start_time timestamp without time zone NOT NULL,
    end_time timestamp without time zone NOT NULL,
    reason character varying(255),
    active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    updated_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    block_type character varying(20) DEFAULT 'OTHER'::character varying NOT NULL,
    CONSTRAINT ck_schedule_blocks_type CHECK (((block_type)::text = ANY ((ARRAY['VACATION'::character varying, 'MEDICAL'::character varying, 'EVENT'::character varying, 'INVENTORY'::character varying, 'UNFORESEEN'::character varying, 'OTHER'::character varying])::text[]))),
    CONSTRAINT schedule_blocks_check CHECK ((start_time < end_time))
);


--
-- Name: schedule_blocks_block_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.schedule_blocks ALTER COLUMN block_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.schedule_blocks_block_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: service_branch_settings; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_branch_settings (
    service_id integer NOT NULL,
    branch_id integer NOT NULL,
    active boolean DEFAULT true,
    price_override numeric(10,2)
);


--
-- Name: service_professionals; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.service_professionals (
    professional_id integer NOT NULL,
    service_id integer NOT NULL
);


--
-- Name: services; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.services (
    service_id integer NOT NULL,
    business_id integer NOT NULL,
    name character varying(255) NOT NULL,
    description text,
    duration_minutes integer NOT NULL,
    price numeric(10,2) NOT NULL,
    commission_percentage numeric(5,2),
    active boolean DEFAULT true,
    color_code character varying(7),
    category_id integer,
    at_home boolean DEFAULT false NOT NULL
);


--
-- Name: services_service_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.services ALTER COLUMN service_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.services_service_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: support_tickets; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.support_tickets (
    ticket_id bigint NOT NULL,
    user_id integer NOT NULL,
    business_id integer,
    category character varying(30) NOT NULL,
    quantity integer,
    message character varying(2000),
    status character varying(20) DEFAULT 'OPEN'::character varying NOT NULL,
    created_at timestamp with time zone DEFAULT now() NOT NULL,
    updated_at timestamp with time zone DEFAULT now() NOT NULL,
    subject character varying(140),
    resolution_note character varying(1000),
    CONSTRAINT support_tickets_addon_fields_check CHECK ((((category)::text !~~ 'ADDON%'::text) OR ((business_id IS NOT NULL) AND (quantity IS NOT NULL)))),
    CONSTRAINT support_tickets_category_check CHECK (((category)::text = ANY ((ARRAY['ADDON_PROFESSIONALS'::character varying, 'ADDON_BRANCHES'::character varying, 'HELP'::character varying, 'BUG'::character varying, 'ACCOUNT'::character varying, 'BILLING'::character varying, 'OTHER'::character varying, 'CUSTOM_LANDING'::character varying])::text[]))),
    CONSTRAINT support_tickets_quantity_check CHECK (((quantity >= 1) AND (quantity <= 20))),
    CONSTRAINT support_tickets_status_check CHECK (((status)::text = ANY ((ARRAY['OPEN'::character varying, 'IN_PROGRESS'::character varying, 'RESOLVED'::character varying])::text[])))
);


--
-- Name: support_tickets_ticket_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.support_tickets_ticket_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: support_tickets_ticket_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.support_tickets_ticket_id_seq OWNED BY public.support_tickets.ticket_id;


--
-- Name: unavailability_types; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.unavailability_types (
    type_id integer NOT NULL,
    code text NOT NULL,
    display_name text NOT NULL,
    blocks_agenda boolean DEFAULT true
);


--
-- Name: unavailability_types_type_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.unavailability_types_type_id_seq
    AS integer
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: unavailability_types_type_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.unavailability_types_type_id_seq OWNED BY public.unavailability_types.type_id;


--
-- Name: user_branch_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_branch_roles (
    user_branch_role_id integer NOT NULL,
    user_id integer NOT NULL,
    business_id integer NOT NULL,
    branch_id integer NOT NULL,
    role_id integer NOT NULL,
    active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: user_branch_roles_user_branch_role_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.user_branch_roles ALTER COLUMN user_branch_role_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.user_branch_roles_user_branch_role_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: user_business_roles; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.user_business_roles (
    user_business_role_id integer NOT NULL,
    user_id integer NOT NULL,
    business_id integer NOT NULL,
    role_id integer NOT NULL,
    active boolean DEFAULT true,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP
);


--
-- Name: user_business_roles_user_business_role_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.user_business_roles ALTER COLUMN user_business_role_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.user_business_roles_user_business_role_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: users; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.users (
    user_id integer NOT NULL,
    email character varying(255) NOT NULL,
    password_hash character varying(255),
    first_name character varying(100),
    last_name character varying(100),
    phone character varying(20),
    active boolean DEFAULT true,
    last_access timestamp without time zone,
    created_at timestamp without time zone DEFAULT CURRENT_TIMESTAMP,
    current_reset_jti character varying(36),
    is_super_admin boolean DEFAULT false,
    auth_provider character varying(30) DEFAULT 'LOCAL'::character varying NOT NULL,
    provider_subject character varying(255),
    provider_linked_at timestamp without time zone,
    totp_secret_enc text,
    totp_enabled boolean DEFAULT false NOT NULL,
    totp_last_step bigint,
    email_verified boolean DEFAULT false NOT NULL
);


--
-- Name: users_user_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

ALTER TABLE public.users ALTER COLUMN user_id ADD GENERATED BY DEFAULT AS IDENTITY (
    SEQUENCE NAME public.users_user_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1
);


--
-- Name: whatsapp_conversations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.whatsapp_conversations (
    conversation_id bigint NOT NULL,
    contact character varying(30) NOT NULL,
    business_id integer,
    state character varying(20) DEFAULT 'MENU'::character varying NOT NULL,
    data text DEFAULT '{}'::text NOT NULL,
    human boolean DEFAULT false NOT NULL,
    summary character varying(500),
    updated_at timestamp without time zone NOT NULL
);


--
-- Name: whatsapp_conversations_conversation_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.whatsapp_conversations_conversation_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: whatsapp_conversations_conversation_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.whatsapp_conversations_conversation_id_seq OWNED BY public.whatsapp_conversations.conversation_id;


--
-- Name: whatsapp_integrations; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.whatsapp_integrations (
    business_id integer NOT NULL,
    enabled boolean DEFAULT false NOT NULL,
    updated_at timestamp without time zone NOT NULL,
    mode character varying(10) DEFAULT 'AUTO'::character varying NOT NULL,
    CONSTRAINT whatsapp_integrations_mode_check CHECK (((mode)::text = ANY ((ARRAY['AUTO'::character varying, 'REQUEST'::character varying])::text[])))
);


--
-- Name: whatsapp_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.whatsapp_messages (
    message_id bigint NOT NULL,
    business_id integer,
    direction character varying(3) NOT NULL,
    contact character varying(30) NOT NULL,
    body character varying(1000) NOT NULL,
    status character varying(10) NOT NULL,
    wa_message_id character varying(120),
    created_at timestamp without time zone NOT NULL,
    author character varying(5) DEFAULT 'BOT'::character varying NOT NULL,
    CONSTRAINT whatsapp_messages_author_check CHECK (((author)::text = ANY ((ARRAY['USER'::character varying, 'BOT'::character varying, 'HUMAN'::character varying])::text[]))),
    CONSTRAINT whatsapp_messages_direction_check CHECK (((direction)::text = ANY ((ARRAY['IN'::character varying, 'OUT'::character varying])::text[]))),
    CONSTRAINT whatsapp_messages_status_check CHECK (((status)::text = ANY ((ARRAY['RECEIVED'::character varying, 'SENT'::character varying, 'FAILED'::character varying])::text[])))
);


--
-- Name: whatsapp_messages_message_id_seq; Type: SEQUENCE; Schema: public; Owner: -
--

CREATE SEQUENCE public.whatsapp_messages_message_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: whatsapp_messages_message_id_seq; Type: SEQUENCE OWNED BY; Schema: public; Owner: -
--

ALTER SEQUENCE public.whatsapp_messages_message_id_seq OWNED BY public.whatsapp_messages.message_id;


--
-- Name: admin_audit_events event_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_audit_events ALTER COLUMN event_id SET DEFAULT nextval('public.admin_audit_events_event_id_seq'::regclass);


--
-- Name: admin_recovery_codes code_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_recovery_codes ALTER COLUMN code_id SET DEFAULT nextval('public.admin_recovery_codes_code_id_seq'::regclass);


--
-- Name: applications application_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applications ALTER COLUMN application_id SET DEFAULT nextval('public.applications_application_id_seq'::regclass);


--
-- Name: appointment_status status_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_status ALTER COLUMN status_id SET DEFAULT nextval('public.appointment_status_status_id_seq'::regclass);


--
-- Name: appointment_status_history history_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_status_history ALTER COLUMN history_id SET DEFAULT nextval('public.appointment_status_history_history_id_seq'::regclass);


--
-- Name: branch_weekly_hours weekly_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_weekly_hours ALTER COLUMN weekly_id SET DEFAULT nextval('public.branch_weekly_hours_weekly_id_seq'::regclass);


--
-- Name: business_photo_comments comment_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_photo_comments ALTER COLUMN comment_id SET DEFAULT nextval('public.business_photo_comments_comment_id_seq'::regclass);


--
-- Name: campaign_messages message_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_messages ALTER COLUMN message_id SET DEFAULT nextval('public.campaign_messages_message_id_seq'::regclass);


--
-- Name: campaigns campaign_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaigns ALTER COLUMN campaign_id SET DEFAULT nextval('public.campaigns_campaign_id_seq'::regclass);


--
-- Name: holidays holiday_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.holidays ALTER COLUMN holiday_id SET DEFAULT nextval('public.holidays_holiday_id_seq'::regclass);


--
-- Name: industry_categories category_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.industry_categories ALTER COLUMN category_id SET DEFAULT nextval('public.industry_categories_category_id_seq'::regclass);


--
-- Name: legal_acceptances acceptance_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_acceptances ALTER COLUMN acceptance_id SET DEFAULT nextval('public.legal_acceptances_acceptance_id_seq'::regclass);


--
-- Name: module_requests request_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_requests ALTER COLUMN request_id SET DEFAULT nextval('public.module_requests_request_id_seq'::regclass);


--
-- Name: product_movements movement_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_movements ALTER COLUMN movement_id SET DEFAULT nextval('public.product_movements_movement_id_seq'::regclass);


--
-- Name: professional_unavailability unavail_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_unavailability ALTER COLUMN unavail_id SET DEFAULT nextval('public.professional_unavailability_unavail_id_seq'::regclass);


--
-- Name: professional_weekly_hours weekly_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_weekly_hours ALTER COLUMN weekly_id SET DEFAULT nextval('public.professional_weekly_hours_weekly_id_seq'::regclass);


--
-- Name: quotes quote_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quotes ALTER COLUMN quote_id SET DEFAULT nextval('public.quotes_quote_id_seq'::regclass);


--
-- Name: reviews review_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews ALTER COLUMN review_id SET DEFAULT nextval('public.reviews_review_id_seq'::regclass);


--
-- Name: support_tickets ticket_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_tickets ALTER COLUMN ticket_id SET DEFAULT nextval('public.support_tickets_ticket_id_seq'::regclass);


--
-- Name: unavailability_types type_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unavailability_types ALTER COLUMN type_id SET DEFAULT nextval('public.unavailability_types_type_id_seq'::regclass);


--
-- Name: whatsapp_conversations conversation_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.whatsapp_conversations ALTER COLUMN conversation_id SET DEFAULT nextval('public.whatsapp_conversations_conversation_id_seq'::regclass);


--
-- Name: whatsapp_messages message_id; Type: DEFAULT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.whatsapp_messages ALTER COLUMN message_id SET DEFAULT nextval('public.whatsapp_messages_message_id_seq'::regclass);


--
-- Name: admin_audit_events admin_audit_events_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_audit_events
    ADD CONSTRAINT admin_audit_events_pkey PRIMARY KEY (event_id);


--
-- Name: admin_recovery_codes admin_recovery_codes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_recovery_codes
    ADD CONSTRAINT admin_recovery_codes_pkey PRIMARY KEY (code_id);


--
-- Name: admin_recovery_codes admin_recovery_codes_user_id_code_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_recovery_codes
    ADD CONSTRAINT admin_recovery_codes_user_id_code_hash_key UNIQUE (user_id, code_hash);


--
-- Name: applications applications_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applications
    ADD CONSTRAINT applications_pkey PRIMARY KEY (application_id);


--
-- Name: appointment_status_history appointment_status_history_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_status_history
    ADD CONSTRAINT appointment_status_history_pkey PRIMARY KEY (history_id);


--
-- Name: appointment_status appointment_status_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_status
    ADD CONSTRAINT appointment_status_pkey PRIMARY KEY (status_id);


--
-- Name: appointments appointments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_pkey PRIMARY KEY (appointment_id);


--
-- Name: attachment_roles attachment_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachment_roles
    ADD CONSTRAINT attachment_roles_pkey PRIMARY KEY (role_id);


--
-- Name: attachments attachments_file_sha256_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT attachments_file_sha256_key UNIQUE (file_sha256);


--
-- Name: attachments attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT attachments_pkey PRIMARY KEY (attachment_id);


--
-- Name: attachments attachments_storage_key_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT attachments_storage_key_key UNIQUE (storage_key);


--
-- Name: audit_log audit_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_pkey PRIMARY KEY (log_id);


--
-- Name: automatic_reminders automatic_reminders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automatic_reminders
    ADD CONSTRAINT automatic_reminders_pkey PRIMARY KEY (reminder_id);


--
-- Name: blacklisted_tokens blacklisted_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.blacklisted_tokens
    ADD CONSTRAINT blacklisted_tokens_pkey PRIMARY KEY (token_hash);


--
-- Name: branch_weekly_hours branch_weekly_hours_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_weekly_hours
    ADD CONSTRAINT branch_weekly_hours_pkey PRIMARY KEY (weekly_id);


--
-- Name: branches branches_business_id_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branches
    ADD CONSTRAINT branches_business_id_name_key UNIQUE (business_id, name);


--
-- Name: branches branches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branches
    ADD CONSTRAINT branches_pkey PRIMARY KEY (branch_id);


--
-- Name: business_photo_comments business_photo_comments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_photo_comments
    ADD CONSTRAINT business_photo_comments_pkey PRIMARY KEY (comment_id);


--
-- Name: businesses businesses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.businesses
    ADD CONSTRAINT businesses_pkey PRIMARY KEY (business_id);


--
-- Name: campaign_messages campaign_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_messages
    ADD CONSTRAINT campaign_messages_pkey PRIMARY KEY (message_id);


--
-- Name: campaign_templates campaign_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_templates
    ADD CONSTRAINT campaign_templates_pkey PRIMARY KEY (business_id, template_key);


--
-- Name: campaigns campaigns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaigns
    ADD CONSTRAINT campaigns_pkey PRIMARY KEY (campaign_id);


--
-- Name: cash_registers cash_registers_branch_id_date_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cash_registers
    ADD CONSTRAINT cash_registers_branch_id_date_key UNIQUE (branch_id, date);


--
-- Name: cash_registers cash_registers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cash_registers
    ADD CONSTRAINT cash_registers_pkey PRIMARY KEY (register_id);


--
-- Name: categories categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT categories_pkey PRIMARY KEY (category_id);


--
-- Name: commercial_account_setups commercial_account_setups_billing_tenant_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_account_setups
    ADD CONSTRAINT commercial_account_setups_billing_tenant_id_key UNIQUE (billing_tenant_id);


--
-- Name: commercial_account_setups commercial_account_setups_business_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_account_setups
    ADD CONSTRAINT commercial_account_setups_business_id_key UNIQUE (business_id);


--
-- Name: commercial_account_setups commercial_account_setups_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_account_setups
    ADD CONSTRAINT commercial_account_setups_pkey PRIMARY KEY (setup_id);


--
-- Name: commercial_payment_checkouts commercial_payment_checkouts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_payment_checkouts
    ADD CONSTRAINT commercial_payment_checkouts_pkey PRIMARY KEY (checkout_id);


--
-- Name: commissions commissions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commissions
    ADD CONSTRAINT commissions_pkey PRIMARY KEY (commission_id);


--
-- Name: communication_channels communication_channels_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.communication_channels
    ADD CONSTRAINT communication_channels_name_key UNIQUE (name);


--
-- Name: communication_channels communication_channels_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.communication_channels
    ADD CONSTRAINT communication_channels_pkey PRIMARY KEY (channel_id);


--
-- Name: customer_health_profiles customer_health_profiles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_health_profiles
    ADD CONSTRAINT customer_health_profiles_pkey PRIMARY KEY (customer_id);


--
-- Name: customer_records customer_records_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_records
    ADD CONSTRAINT customer_records_pkey PRIMARY KEY (record_id);


--
-- Name: customers customers_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_pkey PRIMARY KEY (customer_id);


--
-- Name: delivery_statuses delivery_statuses_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_statuses
    ADD CONSTRAINT delivery_statuses_name_key UNIQUE (name);


--
-- Name: delivery_statuses delivery_statuses_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.delivery_statuses
    ADD CONSTRAINT delivery_statuses_pkey PRIMARY KEY (status_id);


--
-- Name: document_types document_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_types
    ADD CONSTRAINT document_types_pkey PRIMARY KEY (document_type_id);


--
-- Name: email_verification_tokens email_verification_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_verification_tokens
    ADD CONSTRAINT email_verification_tokens_pkey PRIMARY KEY (token_hash);


--
-- Name: entity_attachments entity_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.entity_attachments
    ADD CONSTRAINT entity_attachments_pkey PRIMARY KEY (attachment_id, entity_type, entity_id, attachment_role_id);


--
-- Name: flyway_schema_history flyway_schema_history_pk; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.flyway_schema_history
    ADD CONSTRAINT flyway_schema_history_pk PRIMARY KEY (installed_rank);


--
-- Name: holidays holidays_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.holidays
    ADD CONSTRAINT holidays_pkey PRIMARY KEY (holiday_id);


--
-- Name: import_batches import_batches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_batches
    ADD CONSTRAINT import_batches_pkey PRIMARY KEY (batch_id);


--
-- Name: import_rows import_rows_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_rows
    ADD CONSTRAINT import_rows_pkey PRIMARY KEY (row_id);


--
-- Name: industries industries_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.industries
    ADD CONSTRAINT industries_name_key UNIQUE (name);


--
-- Name: industries industries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.industries
    ADD CONSTRAINT industries_pkey PRIMARY KEY (industry_id);


--
-- Name: industry_categories industry_categories_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.industry_categories
    ADD CONSTRAINT industry_categories_name_key UNIQUE (name);


--
-- Name: industry_categories industry_categories_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.industry_categories
    ADD CONSTRAINT industry_categories_pkey PRIMARY KEY (category_id);


--
-- Name: inventory_movements inventory_movements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_movements
    ADD CONSTRAINT inventory_movements_pkey PRIMARY KEY (movement_id);


--
-- Name: invoices invoices_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_pkey PRIMARY KEY (invoice_id);


--
-- Name: invoices invoices_sale_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_sale_id_key UNIQUE (sale_id);


--
-- Name: invoices invoices_tax_folio_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_tax_folio_key UNIQUE (tax_folio);


--
-- Name: legal_acceptances legal_acceptances_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_acceptances
    ADD CONSTRAINT legal_acceptances_pkey PRIMARY KEY (acceptance_id);


--
-- Name: local_modules local_modules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.local_modules
    ADD CONSTRAINT local_modules_pkey PRIMARY KEY (code);


--
-- Name: local_plan_limits local_plan_limits_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.local_plan_limits
    ADD CONSTRAINT local_plan_limits_pkey PRIMARY KEY (plan_code, key);


--
-- Name: local_plans local_plans_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.local_plans
    ADD CONSTRAINT local_plans_pkey PRIMARY KEY (code);


--
-- Name: local_subscription_modules local_subscription_modules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.local_subscription_modules
    ADD CONSTRAINT local_subscription_modules_pkey PRIMARY KEY (tenant_id, module_code);


--
-- Name: local_subscriptions local_subscriptions_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.local_subscriptions
    ADD CONSTRAINT local_subscriptions_pkey PRIMARY KEY (tenant_id);


--
-- Name: marketing_campaigns marketing_campaigns_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketing_campaigns
    ADD CONSTRAINT marketing_campaigns_pkey PRIMARY KEY (campaign_id);


--
-- Name: marketing_optouts marketing_optouts_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketing_optouts
    ADD CONSTRAINT marketing_optouts_pkey PRIMARY KEY (business_id, email);


--
-- Name: message_deliveries message_deliveries_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_deliveries
    ADD CONSTRAINT message_deliveries_pkey PRIMARY KEY (delivery_id);


--
-- Name: message_templates message_templates_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_templates
    ADD CONSTRAINT message_templates_pkey PRIMARY KEY (template_id);


--
-- Name: module_requests module_requests_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_requests
    ADD CONSTRAINT module_requests_pkey PRIMARY KEY (request_id);


--
-- Name: movement_types movement_types_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.movement_types
    ADD CONSTRAINT movement_types_name_key UNIQUE (name);


--
-- Name: movement_types movement_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.movement_types
    ADD CONSTRAINT movement_types_pkey PRIMARY KEY (movement_type_id);


--
-- Name: notification_dispatch_log notification_dispatch_log_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_dispatch_log
    ADD CONSTRAINT notification_dispatch_log_pkey PRIMARY KEY (business_id, kind, period_key);


--
-- Name: payment_methods payment_methods_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_methods
    ADD CONSTRAINT payment_methods_pkey PRIMARY KEY (method_id);


--
-- Name: payments payments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_pkey PRIMARY KEY (payment_id);


--
-- Name: pending_appointments pending_appointments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pending_appointments
    ADD CONSTRAINT pending_appointments_pkey PRIMARY KEY (pending_id);


--
-- Name: product_movements product_movements_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_movements
    ADD CONSTRAINT product_movements_pkey PRIMARY KEY (movement_id);


--
-- Name: product_order_items product_order_items_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_order_items
    ADD CONSTRAINT product_order_items_pkey PRIMARY KEY (order_id, product_id);


--
-- Name: product_orders product_orders_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_orders
    ADD CONSTRAINT product_orders_pkey PRIMARY KEY (order_id);


--
-- Name: product_stocks product_stocks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_stocks
    ADD CONSTRAINT product_stocks_pkey PRIMARY KEY (product_id, branch_id);


--
-- Name: products products_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_pkey PRIMARY KEY (product_id);


--
-- Name: professional_branches professional_branches_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_branches
    ADD CONSTRAINT professional_branches_pkey PRIMARY KEY (professional_id, branch_id);


--
-- Name: professional_schedules professional_schedules_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_schedules
    ADD CONSTRAINT professional_schedules_pkey PRIMARY KEY (schedule_id);


--
-- Name: professional_unavailability professional_unavailability_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_unavailability
    ADD CONSTRAINT professional_unavailability_pkey PRIMARY KEY (unavail_id);


--
-- Name: professional_weekly_hours professional_weekly_hours_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_weekly_hours
    ADD CONSTRAINT professional_weekly_hours_pkey PRIMARY KEY (weekly_id);


--
-- Name: professionals professionals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professionals
    ADD CONSTRAINT professionals_pkey PRIMARY KEY (professional_id);


--
-- Name: professionals professionals_user_id_business_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professionals
    ADD CONSTRAINT professionals_user_id_business_id_key UNIQUE (user_id, business_id);


--
-- Name: quotes quotes_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quotes
    ADD CONSTRAINT quotes_pkey PRIMARY KEY (quote_id);


--
-- Name: refresh_tokens refresh_tokens_jti_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refresh_tokens
    ADD CONSTRAINT refresh_tokens_jti_key UNIQUE (jti);


--
-- Name: refresh_tokens refresh_tokens_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refresh_tokens
    ADD CONSTRAINT refresh_tokens_pkey PRIMARY KEY (token_id);


--
-- Name: refresh_tokens refresh_tokens_token_hash_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refresh_tokens
    ADD CONSTRAINT refresh_tokens_token_hash_key UNIQUE (token_hash);


--
-- Name: reviews reviews_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_pkey PRIMARY KEY (review_id);


--
-- Name: roles roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (role_id);


--
-- Name: roles roles_role_name_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.roles
    ADD CONSTRAINT roles_role_name_key UNIQUE (role_name);


--
-- Name: sale_details sale_details_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sale_details
    ADD CONSTRAINT sale_details_pkey PRIMARY KEY (detail_id);


--
-- Name: sales sales_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales
    ADD CONSTRAINT sales_pkey PRIMARY KEY (sale_id);


--
-- Name: schedule_blocks schedule_blocks_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_blocks
    ADD CONSTRAINT schedule_blocks_pkey PRIMARY KEY (block_id);


--
-- Name: service_branch_settings service_branch_settings_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_branch_settings
    ADD CONSTRAINT service_branch_settings_pkey PRIMARY KEY (service_id, branch_id);


--
-- Name: service_professionals service_professionals_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_professionals
    ADD CONSTRAINT service_professionals_pkey PRIMARY KEY (professional_id, service_id);


--
-- Name: services services_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.services
    ADD CONSTRAINT services_pkey PRIMARY KEY (service_id);


--
-- Name: support_tickets support_tickets_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_tickets
    ADD CONSTRAINT support_tickets_pkey PRIMARY KEY (ticket_id);


--
-- Name: categories uk_categories_name_business; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT uk_categories_name_business UNIQUE (name, business_id);


--
-- Name: unavailability_types unavailability_types_code_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unavailability_types
    ADD CONSTRAINT unavailability_types_code_key UNIQUE (code);


--
-- Name: unavailability_types unavailability_types_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.unavailability_types
    ADD CONSTRAINT unavailability_types_pkey PRIMARY KEY (type_id);


--
-- Name: user_branch_roles user_branch_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_branch_roles
    ADD CONSTRAINT user_branch_roles_pkey PRIMARY KEY (user_branch_role_id);


--
-- Name: user_branch_roles user_branch_roles_user_id_branch_id_role_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_branch_roles
    ADD CONSTRAINT user_branch_roles_user_id_branch_id_role_id_key UNIQUE (user_id, branch_id, role_id);


--
-- Name: user_business_roles user_business_roles_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_business_roles
    ADD CONSTRAINT user_business_roles_pkey PRIMARY KEY (user_business_role_id);


--
-- Name: user_business_roles user_business_roles_user_id_business_id_role_id_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_business_roles
    ADD CONSTRAINT user_business_roles_user_id_business_id_role_id_key UNIQUE (user_id, business_id, role_id);


--
-- Name: users users_email_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users users_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.users
    ADD CONSTRAINT users_pkey PRIMARY KEY (user_id);


--
-- Name: sales ux_sales_branch_salenumber; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales
    ADD CONSTRAINT ux_sales_branch_salenumber UNIQUE (branch_id, sale_number);


--
-- Name: whatsapp_conversations whatsapp_conversations_contact_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.whatsapp_conversations
    ADD CONSTRAINT whatsapp_conversations_contact_key UNIQUE (contact);


--
-- Name: whatsapp_conversations whatsapp_conversations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.whatsapp_conversations
    ADD CONSTRAINT whatsapp_conversations_pkey PRIMARY KEY (conversation_id);


--
-- Name: whatsapp_integrations whatsapp_integrations_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.whatsapp_integrations
    ADD CONSTRAINT whatsapp_integrations_pkey PRIMARY KEY (business_id);


--
-- Name: whatsapp_messages whatsapp_messages_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.whatsapp_messages
    ADD CONSTRAINT whatsapp_messages_pkey PRIMARY KEY (message_id);


--
-- Name: flyway_schema_history_s_idx; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX flyway_schema_history_s_idx ON public.flyway_schema_history USING btree (success);


--
-- Name: idx_admin_audit_events_created_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_admin_audit_events_created_at ON public.admin_audit_events USING btree (created_at DESC);


--
-- Name: idx_admin_audit_events_target; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_admin_audit_events_target ON public.admin_audit_events USING btree (target_type, target_id);


--
-- Name: idx_appointment_status_business_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appointment_status_business_id ON public.appointment_status USING btree (business_id);


--
-- Name: idx_appointment_status_history_appointment; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appointment_status_history_appointment ON public.appointment_status_history USING btree (appointment_id, created_at DESC);


--
-- Name: idx_appointments_reschedule_offer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appointments_reschedule_offer ON public.appointments USING btree (reschedule_offer_until) WHERE (reschedule_offer_until IS NOT NULL);


--
-- Name: idx_appt_branch_start; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appt_branch_start ON public.appointments USING btree (branch_id, start_datetime);


--
-- Name: idx_appt_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appt_created ON public.appointments USING btree (created_at);


--
-- Name: idx_appt_cust; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appt_cust ON public.appointments USING btree (customer_id);


--
-- Name: idx_appt_prof_start; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appt_prof_start ON public.appointments USING btree (professional_id, start_datetime);


--
-- Name: idx_appt_start; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appt_start ON public.appointments USING btree (start_datetime);


--
-- Name: idx_appt_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appt_status ON public.appointments USING btree (status_id);


--
-- Name: idx_appt_token_expires_at; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_appt_token_expires_at ON public.appointments USING btree (token_expires_at);


--
-- Name: idx_ar_branch_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ar_branch_active ON public.automatic_reminders USING btree (branch_id, active);


--
-- Name: idx_ar_bus_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ar_bus_active ON public.automatic_reminders USING btree (business_id, active);


--
-- Name: idx_ar_event; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ar_event ON public.automatic_reminders USING btree (event_type);


--
-- Name: idx_attachment_roles_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_attachment_roles_active ON public.attachment_roles USING btree (active);


--
-- Name: idx_attachments_storage_key; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_attachments_storage_key ON public.attachments USING btree (storage_key);


--
-- Name: idx_attachments_variant_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_attachments_variant_role ON public.entity_attachments USING btree (entity_type, entity_id, attachment_role_id);


--
-- Name: idx_audit_action; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_action ON public.audit_log USING btree (action);


--
-- Name: idx_audit_branch_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_branch_time ON public.audit_log USING btree (branch_id, "timestamp");


--
-- Name: idx_audit_bus_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_bus_time ON public.audit_log USING btree (business_id, "timestamp");


--
-- Name: idx_audit_table_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_table_time ON public.audit_log USING btree (table_name, "timestamp");


--
-- Name: idx_audit_user_time; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_audit_user_time ON public.audit_log USING btree (user_id, "timestamp");


--
-- Name: idx_blacklisted_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_blacklisted_expires ON public.blacklisted_tokens USING btree (expires_at);


--
-- Name: idx_branch_weekly_branch_day; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_branch_weekly_branch_day ON public.branch_weekly_hours USING btree (branch_id, day_of_week, active);


--
-- Name: idx_branches_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_branches_active ON public.branches USING btree (active);


--
-- Name: idx_branches_business; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_branches_business ON public.branches USING btree (business_id);


--
-- Name: idx_branches_city_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_branches_city_active ON public.branches USING btree (city, active) WHERE (city IS NOT NULL);


--
-- Name: idx_businesses_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_businesses_email ON public.businesses USING btree (email);


--
-- Name: idx_businesses_industry; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_businesses_industry ON public.businesses USING btree (industry_id);


--
-- Name: idx_businesses_marketplace; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_businesses_marketplace ON public.businesses USING btree (active, is_publicly_listed, industry_id);


--
-- Name: idx_campaign_messages_campaign; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_campaign_messages_campaign ON public.campaign_messages USING btree (campaign_id, status);


--
-- Name: idx_campaign_messages_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_campaign_messages_email ON public.campaign_messages USING btree (email, sent_at);


--
-- Name: idx_campaigns_business; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_campaigns_business ON public.campaigns USING btree (business_id, created_at DESC);


--
-- Name: idx_com_paid; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_com_paid ON public.commissions USING btree (paid);


--
-- Name: idx_com_paydate; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_com_paydate ON public.commissions USING btree (payment_date);


--
-- Name: idx_com_prof_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_com_prof_date ON public.commissions USING btree (professional_id, calculation_date);


--
-- Name: idx_comm_branch_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_comm_branch_date ON public.commissions USING btree (branch_id, calculation_date);


--
-- Name: idx_creg_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_creg_status ON public.cash_registers USING btree (status);


--
-- Name: idx_cust_bus_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cust_bus_active ON public.customers USING btree (business_id, active);


--
-- Name: idx_cust_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cust_created ON public.customers USING btree (created_at);


--
-- Name: idx_cust_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cust_email ON public.customers USING btree (email);


--
-- Name: idx_cust_home_branch; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cust_home_branch ON public.customers USING btree (home_branch_id);


--
-- Name: idx_cust_phone; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_cust_phone ON public.customers USING btree (phone);


--
-- Name: idx_customer_health_profiles_national_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_customer_health_profiles_national_id ON public.customer_health_profiles USING btree (national_id);


--
-- Name: idx_document_types_business_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_document_types_business_id ON public.document_types USING btree (business_id);


--
-- Name: idx_entity_attachments_lookup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_entity_attachments_lookup ON public.entity_attachments USING btree (entity_type, entity_id);


--
-- Name: idx_entity_attachments_lookup_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_entity_attachments_lookup_role ON public.entity_attachments USING btree (entity_type, entity_id, attachment_role_id);


--
-- Name: idx_holidays_business; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_holidays_business ON public.holidays USING btree (business_id, date);


--
-- Name: idx_import_batches_actor; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_import_batches_actor ON public.import_batches USING btree (actor_user_id);


--
-- Name: idx_import_batches_business_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_import_batches_business_created ON public.import_batches USING btree (business_id, created_at DESC);


--
-- Name: idx_import_rows_batch_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_import_rows_batch_status ON public.import_rows USING btree (batch_id, status);


--
-- Name: idx_industries_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_industries_category ON public.industries USING btree (category_id, sort_order, name);


--
-- Name: idx_inv_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_inv_date ON public.invoices USING btree (issue_date);


--
-- Name: idx_inv_folio; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_inv_folio ON public.invoices USING btree (tax_folio);


--
-- Name: idx_inv_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_inv_status ON public.invoices USING btree (tax_status);


--
-- Name: idx_legal_acceptances_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_legal_acceptances_user ON public.legal_acceptances USING btree (user_id);


--
-- Name: idx_md_branch_sent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_md_branch_sent ON public.message_deliveries USING btree (branch_id, sent_date);


--
-- Name: idx_md_bus_sent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_md_bus_sent ON public.message_deliveries USING btree (business_id, sent_date);


--
-- Name: idx_md_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_md_channel ON public.message_deliveries USING btree (channel_id);


--
-- Name: idx_md_cust_sent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_md_cust_sent ON public.message_deliveries USING btree (customer_id, sent_date);


--
-- Name: idx_md_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_md_status ON public.message_deliveries USING btree (status_id);


--
-- Name: idx_mkt_branch_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mkt_branch_status ON public.marketing_campaigns USING btree (branch_id, status);


--
-- Name: idx_mkt_bus_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mkt_bus_status ON public.marketing_campaigns USING btree (business_id, status);


--
-- Name: idx_mkt_start; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mkt_start ON public.marketing_campaigns USING btree (start_date);


--
-- Name: idx_mov_branch_prod_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_branch_prod_date ON public.inventory_movements USING btree (branch_id, product_id, movement_date);


--
-- Name: idx_mov_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_date ON public.inventory_movements USING btree (movement_date);


--
-- Name: idx_mov_prod_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_prod_date ON public.inventory_movements USING btree (product_id, movement_date);


--
-- Name: idx_mov_type; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mov_type ON public.inventory_movements USING btree (movement_type_id);


--
-- Name: idx_mtpl_bus_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mtpl_bus_active ON public.message_templates USING btree (business_id, active);


--
-- Name: idx_mtpl_type_channel; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_mtpl_type_channel ON public.message_templates USING btree (type, channel_id);


--
-- Name: idx_pay_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pay_date ON public.payments USING btree (payment_date);


--
-- Name: idx_pay_sale; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pay_sale ON public.payments USING btree (sale_id);


--
-- Name: idx_pay_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pay_status ON public.payments USING btree (status);


--
-- Name: idx_paym_bus_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_paym_bus_active ON public.payment_methods USING btree (business_id, active);


--
-- Name: idx_pbran_branch; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pbran_branch ON public.professional_branches USING btree (branch_id);


--
-- Name: idx_pending_appt_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pending_appt_customer ON public.pending_appointments USING btree (customer_id);


--
-- Name: idx_pending_appt_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pending_appt_expires ON public.pending_appointments USING btree (expires_at);


--
-- Name: idx_photo_comments_photo; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_photo_comments_photo ON public.business_photo_comments USING btree (business_id, photo_role, created_at DESC);


--
-- Name: idx_prod_bus_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_prod_bus_active ON public.products USING btree (business_id, active);


--
-- Name: idx_prod_category; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_prod_category ON public.products USING btree (category);


--
-- Name: idx_product_movements_business_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_product_movements_business_date ON public.product_movements USING btree (business_id, created_at);


--
-- Name: idx_product_movements_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_product_movements_product ON public.product_movements USING btree (product_id, created_at);


--
-- Name: idx_prof_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_prof_active ON public.professionals USING btree (active);


--
-- Name: idx_prof_business; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_prof_business ON public.professionals USING btree (business_id);


--
-- Name: idx_prof_user_business; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_prof_user_business ON public.professionals USING btree (user_id, business_id);


--
-- Name: idx_pstocks_branch; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pstocks_branch ON public.product_stocks USING btree (branch_id);


--
-- Name: idx_pstocks_stock; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_pstocks_stock ON public.product_stocks USING btree (current_stock);


--
-- Name: idx_quotes_business_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_quotes_business_status ON public.quotes USING btree (business_id, status, created_at DESC);


--
-- Name: idx_quotes_customer; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_quotes_customer ON public.quotes USING btree (customer_id);


--
-- Name: idx_rec_cust; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rec_cust ON public.customer_records USING btree (customer_id);


--
-- Name: idx_rec_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rec_date ON public.customer_records USING btree (record_date);


--
-- Name: idx_rec_prof; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_rec_prof ON public.customer_records USING btree (professional_id);


--
-- Name: idx_refresh_tokens_expires; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_refresh_tokens_expires ON public.refresh_tokens USING btree (expires_at);


--
-- Name: idx_refresh_tokens_family; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_refresh_tokens_family ON public.refresh_tokens USING btree (family_id);


--
-- Name: idx_refresh_tokens_revoked; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_refresh_tokens_revoked ON public.refresh_tokens USING btree (revoked);


--
-- Name: idx_refresh_tokens_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_refresh_tokens_user ON public.refresh_tokens USING btree (user_id);


--
-- Name: idx_reviews_business; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reviews_business ON public.reviews USING btree (business_id);


--
-- Name: idx_reviews_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reviews_created ON public.reviews USING btree (created_at DESC);


--
-- Name: idx_reviews_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_reviews_status ON public.reviews USING btree (status);


--
-- Name: idx_sales_branch_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sales_branch_date ON public.sales USING btree (branch_id, sale_date);


--
-- Name: idx_sales_bus_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sales_bus_date ON public.sales USING btree (business_id, sale_date);


--
-- Name: idx_sales_cust; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sales_cust ON public.sales USING btree (customer_id);


--
-- Name: idx_sales_date; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sales_date ON public.sales USING btree (sale_date);


--
-- Name: idx_sched_blocks_prof_period; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sched_blocks_prof_period ON public.schedule_blocks USING btree (professional_id, start_time, end_time) WHERE (active = true);


--
-- Name: idx_sched_blocks_scope_period; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sched_blocks_scope_period ON public.schedule_blocks USING btree (business_id, branch_id, start_time, end_time) WHERE ((active = true) AND (professional_id IS NULL));


--
-- Name: idx_sched_prof_branch_day; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sched_prof_branch_day ON public.professional_schedules USING btree (professional_id, branch_id, day_of_week);


--
-- Name: idx_sched_prof_day; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sched_prof_day ON public.professional_schedules USING btree (professional_id, day_of_week);


--
-- Name: idx_sdet_appt; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sdet_appt ON public.sale_details USING btree (appointment_id);


--
-- Name: idx_sdet_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sdet_product ON public.sale_details USING btree (product_id);


--
-- Name: idx_sdet_sale; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_sdet_sale ON public.sale_details USING btree (sale_id);


--
-- Name: idx_srv_branch; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_srv_branch ON public.service_branch_settings USING btree (branch_id);


--
-- Name: idx_srv_bus_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_srv_bus_active ON public.services USING btree (business_id, active);


--
-- Name: idx_ubr_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ubr_active ON public.user_business_roles USING btree (active);


--
-- Name: idx_ubr_branch_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ubr_branch_role ON public.user_branch_roles USING btree (branch_id, role_id);


--
-- Name: idx_ubr_business; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ubr_business ON public.user_business_roles USING btree (business_id);


--
-- Name: idx_ubr_role; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ubr_role ON public.user_business_roles USING btree (role_id);


--
-- Name: idx_ubr_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ubr_user ON public.user_business_roles USING btree (user_id);


--
-- Name: idx_ubr_user_branch; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_ubr_user_branch ON public.user_branch_roles USING btree (user_id, branch_id);


--
-- Name: idx_unavail_prof_period; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_unavail_prof_period ON public.professional_unavailability USING gist (professional_id, tsrange(start_datetime, end_datetime, '[)'::text));


--
-- Name: idx_users_active; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_active ON public.users USING btree (active);


--
-- Name: idx_users_auth_provider; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_auth_provider ON public.users USING btree (auth_provider);


--
-- Name: idx_users_email; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_users_email ON public.users USING btree (email);


--
-- Name: idx_weekly_prof_day; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX idx_weekly_prof_day ON public.professional_weekly_hours USING btree (professional_id, day_of_week, active);


--
-- Name: ix_applications_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_applications_status ON public.applications USING btree (status, created_at DESC);


--
-- Name: ix_commercial_checkout_setup; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_commercial_checkout_setup ON public.commercial_payment_checkouts USING btree (setup_id);


--
-- Name: ix_email_verification_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_email_verification_user ON public.email_verification_tokens USING btree (user_id, created_at DESC);


--
-- Name: ix_module_requests_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_module_requests_status ON public.module_requests USING btree (status, created_at DESC);


--
-- Name: ix_product_order_items_product; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_product_order_items_product ON public.product_order_items USING btree (product_id);


--
-- Name: ix_product_orders_status; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_product_orders_status ON public.product_orders USING btree (business_id, status, created_at DESC);


--
-- Name: ix_support_tickets_business; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_support_tickets_business ON public.support_tickets USING btree (business_id, status);


--
-- Name: ix_support_tickets_status_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_support_tickets_status_created ON public.support_tickets USING btree (status, created_at DESC);


--
-- Name: ix_support_tickets_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_support_tickets_user ON public.support_tickets USING btree (user_id, created_at DESC);


--
-- Name: ix_whatsapp_conversations_business; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_whatsapp_conversations_business ON public.whatsapp_conversations USING btree (business_id, human DESC, updated_at DESC);


--
-- Name: ix_whatsapp_messages_business; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_whatsapp_messages_business ON public.whatsapp_messages USING btree (business_id, created_at DESC);


--
-- Name: uk_appointment_status_business_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uk_appointment_status_business_name ON public.appointment_status USING btree (business_id, status_name) WHERE (business_id IS NOT NULL);


--
-- Name: uk_appointment_status_system_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uk_appointment_status_system_name ON public.appointment_status USING btree (status_name) WHERE (business_id IS NULL);


--
-- Name: uk_document_types_business_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uk_document_types_business_name ON public.document_types USING btree (business_id, name) WHERE (business_id IS NOT NULL);


--
-- Name: uk_document_types_system_name; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX uk_document_types_system_name ON public.document_types USING btree (name) WHERE (business_id IS NULL);


--
-- Name: ux_applications_user_open; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_applications_user_open ON public.applications USING btree (user_id) WHERE ((status)::text = ANY ((ARRAY['PENDING'::character varying, 'APPROVED'::character varying])::text[]));


--
-- Name: ux_appt_active_token_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_appt_active_token_hash ON public.appointments USING btree (confirmation_token_hash) WHERE (confirmation_token_hash IS NOT NULL);


--
-- Name: ux_branches_branch_business; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_branches_branch_business ON public.branches USING btree (branch_id, business_id);


--
-- Name: ux_branches_business_name_lower; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_branches_business_name_lower ON public.branches USING btree (business_id, lower(btrim((name)::text)));


--
-- Name: ux_branches_one_home_per_business; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_branches_one_home_per_business ON public.branches USING btree (business_id) WHERE ((kind)::text = 'HOME'::text);


--
-- Name: ux_businesses_booking_url_lower; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_businesses_booking_url_lower ON public.businesses USING btree (lower((booking_url)::text)) WHERE ((booking_url IS NOT NULL) AND ((booking_url)::text <> ''::text));


--
-- Name: ux_businesses_email_lower; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_businesses_email_lower ON public.businesses USING btree (lower((email)::text)) WHERE ((email IS NOT NULL) AND ((email)::text <> ''::text));


--
-- Name: ux_businesses_name_norm; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_businesses_name_norm ON public.businesses USING btree (lower(regexp_replace(btrim((name)::text), '\s+'::text, ' '::text, 'g'::text)));


--
-- Name: ux_commercial_pending_setup_user; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_commercial_pending_setup_user ON public.commercial_account_setups USING btree (user_id) WHERE (completed_at IS NULL);


--
-- Name: ux_customers_business_email_lower; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_customers_business_email_lower ON public.customers USING btree (business_id, lower((email)::text)) WHERE ((email IS NOT NULL) AND ((email)::text <> ''::text) AND active);


--
-- Name: ux_holidays_scope_date; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_holidays_scope_date ON public.holidays USING btree (COALESCE(business_id, 0), COALESCE(branch_id, 0), COALESCE(professional_id, 0), kind, date) WHERE (((kind)::text = ANY ((ARRAY['HOLIDAY'::character varying, 'SPECIAL_HOURS'::character varying])::text[])) AND ((recurrence)::text = 'NONE'::text));


--
-- Name: ux_import_rows_batch_sheet_row_entity; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_import_rows_batch_sheet_row_entity ON public.import_rows USING btree (batch_id, COALESCE(sheet_name, ''::character varying), row_number, entity_type);


--
-- Name: ux_module_requests_open; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_module_requests_open ON public.module_requests USING btree (business_id, module_code) WHERE ((status)::text = 'PENDING'::text);


--
-- Name: ux_product_orders_code; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_product_orders_code ON public.product_orders USING btree (business_id, code);


--
-- Name: ux_products_business_barcode; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_products_business_barcode ON public.products USING btree (business_id, barcode) WHERE ((barcode IS NOT NULL) AND ((barcode)::text <> ''::text));


--
-- Name: ux_services_business_name_lower; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_services_business_name_lower ON public.services USING btree (business_id, lower(btrim((name)::text))) WHERE active;


--
-- Name: ux_users_email_lower; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_users_email_lower ON public.users USING btree (lower((email)::text));


--
-- Name: ux_users_provider_subject; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_users_provider_subject ON public.users USING btree (provider_subject) WHERE (provider_subject IS NOT NULL);


--
-- Name: ux_whatsapp_messages_wa_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_whatsapp_messages_wa_id ON public.whatsapp_messages USING btree (wa_message_id) WHERE (wa_message_id IS NOT NULL);


--
-- Name: admin_audit_events admin_audit_events_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_audit_events
    ADD CONSTRAINT admin_audit_events_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.users(user_id);


--
-- Name: admin_recovery_codes admin_recovery_codes_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.admin_recovery_codes
    ADD CONSTRAINT admin_recovery_codes_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id) ON DELETE CASCADE;


--
-- Name: applications applications_decided_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applications
    ADD CONSTRAINT applications_decided_by_fkey FOREIGN KEY (decided_by) REFERENCES public.users(user_id) ON DELETE SET NULL;


--
-- Name: applications applications_plan_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applications
    ADD CONSTRAINT applications_plan_code_fkey FOREIGN KEY (plan_code) REFERENCES public.local_plans(code);


--
-- Name: applications applications_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.applications
    ADD CONSTRAINT applications_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id) ON DELETE CASCADE;


--
-- Name: appointment_status appointment_status_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_status
    ADD CONSTRAINT appointment_status_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: appointment_status_history appointment_status_history_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_status_history
    ADD CONSTRAINT appointment_status_history_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.users(user_id) ON DELETE SET NULL;


--
-- Name: appointment_status_history appointment_status_history_appointment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointment_status_history
    ADD CONSTRAINT appointment_status_history_appointment_id_fkey FOREIGN KEY (appointment_id) REFERENCES public.appointments(appointment_id) ON DELETE CASCADE;


--
-- Name: appointments appointments_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id);


--
-- Name: appointments appointments_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id) ON DELETE CASCADE;


--
-- Name: appointments appointments_professional_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_professional_id_fkey FOREIGN KEY (professional_id) REFERENCES public.professionals(professional_id);


--
-- Name: appointments appointments_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_service_id_fkey FOREIGN KEY (service_id) REFERENCES public.services(service_id);


--
-- Name: appointments appointments_status_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.appointments
    ADD CONSTRAINT appointments_status_id_fkey FOREIGN KEY (status_id) REFERENCES public.appointment_status(status_id);


--
-- Name: attachments attachments_created_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.attachments
    ADD CONSTRAINT attachments_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(user_id) ON DELETE SET NULL;


--
-- Name: audit_log audit_log_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id);


--
-- Name: audit_log audit_log_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id);


--
-- Name: audit_log audit_log_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT audit_log_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- Name: automatic_reminders automatic_reminders_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automatic_reminders
    ADD CONSTRAINT automatic_reminders_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id);


--
-- Name: automatic_reminders automatic_reminders_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automatic_reminders
    ADD CONSTRAINT automatic_reminders_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id);


--
-- Name: automatic_reminders automatic_reminders_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automatic_reminders
    ADD CONSTRAINT automatic_reminders_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.communication_channels(channel_id);


--
-- Name: automatic_reminders automatic_reminders_template_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automatic_reminders
    ADD CONSTRAINT automatic_reminders_template_id_fkey FOREIGN KEY (template_id) REFERENCES public.message_templates(template_id);


--
-- Name: branch_weekly_hours branch_weekly_hours_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branch_weekly_hours
    ADD CONSTRAINT branch_weekly_hours_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id) ON DELETE CASCADE;


--
-- Name: branches branches_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.branches
    ADD CONSTRAINT branches_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: business_photo_comments business_photo_comments_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.business_photo_comments
    ADD CONSTRAINT business_photo_comments_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: businesses businesses_industry_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.businesses
    ADD CONSTRAINT businesses_industry_id_fkey FOREIGN KEY (industry_id) REFERENCES public.industries(industry_id);


--
-- Name: campaign_messages campaign_messages_campaign_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_messages
    ADD CONSTRAINT campaign_messages_campaign_id_fkey FOREIGN KEY (campaign_id) REFERENCES public.campaigns(campaign_id) ON DELETE CASCADE;


--
-- Name: campaign_messages campaign_messages_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_messages
    ADD CONSTRAINT campaign_messages_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id) ON DELETE SET NULL;


--
-- Name: campaign_templates campaign_templates_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaign_templates
    ADD CONSTRAINT campaign_templates_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: campaigns campaigns_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaigns
    ADD CONSTRAINT campaigns_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: campaigns campaigns_created_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.campaigns
    ADD CONSTRAINT campaigns_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(user_id) ON DELETE SET NULL;


--
-- Name: cash_registers cash_registers_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cash_registers
    ADD CONSTRAINT cash_registers_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id);


--
-- Name: cash_registers cash_registers_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cash_registers
    ADD CONSTRAINT cash_registers_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id);


--
-- Name: cash_registers cash_registers_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cash_registers
    ADD CONSTRAINT cash_registers_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- Name: commercial_account_setups commercial_account_setups_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_account_setups
    ADD CONSTRAINT commercial_account_setups_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id);


--
-- Name: commercial_account_setups commercial_account_setups_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_account_setups
    ADD CONSTRAINT commercial_account_setups_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- Name: commercial_payment_checkouts commercial_payment_checkouts_setup_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commercial_payment_checkouts
    ADD CONSTRAINT commercial_payment_checkouts_setup_id_fkey FOREIGN KEY (setup_id) REFERENCES public.commercial_account_setups(setup_id);


--
-- Name: commissions commissions_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commissions
    ADD CONSTRAINT commissions_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id);


--
-- Name: commissions commissions_detail_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commissions
    ADD CONSTRAINT commissions_detail_id_fkey FOREIGN KEY (detail_id) REFERENCES public.sale_details(detail_id) ON DELETE CASCADE;


--
-- Name: commissions commissions_professional_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.commissions
    ADD CONSTRAINT commissions_professional_id_fkey FOREIGN KEY (professional_id) REFERENCES public.professionals(professional_id);


--
-- Name: customer_health_profiles customer_health_profiles_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_health_profiles
    ADD CONSTRAINT customer_health_profiles_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id) ON DELETE CASCADE;


--
-- Name: customer_health_profiles customer_health_profiles_updated_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_health_profiles
    ADD CONSTRAINT customer_health_profiles_updated_by_user_id_fkey FOREIGN KEY (updated_by_user_id) REFERENCES public.users(user_id) ON DELETE SET NULL;


--
-- Name: customer_records customer_records_appointment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_records
    ADD CONSTRAINT customer_records_appointment_id_fkey FOREIGN KEY (appointment_id) REFERENCES public.appointments(appointment_id) ON DELETE SET NULL;


--
-- Name: customer_records customer_records_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_records
    ADD CONSTRAINT customer_records_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id) ON DELETE CASCADE;


--
-- Name: customer_records customer_records_professional_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customer_records
    ADD CONSTRAINT customer_records_professional_id_fkey FOREIGN KEY (professional_id) REFERENCES public.professionals(professional_id);


--
-- Name: customers customers_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id);


--
-- Name: customers customers_home_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.customers
    ADD CONSTRAINT customers_home_branch_id_fkey FOREIGN KEY (home_branch_id) REFERENCES public.branches(branch_id);


--
-- Name: document_types document_types_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.document_types
    ADD CONSTRAINT document_types_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: email_verification_tokens email_verification_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.email_verification_tokens
    ADD CONSTRAINT email_verification_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id) ON DELETE CASCADE;


--
-- Name: entity_attachments entity_attachments_attachment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.entity_attachments
    ADD CONSTRAINT entity_attachments_attachment_id_fkey FOREIGN KEY (attachment_id) REFERENCES public.attachments(attachment_id) ON DELETE CASCADE;


--
-- Name: entity_attachments entity_attachments_attachment_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.entity_attachments
    ADD CONSTRAINT entity_attachments_attachment_role_id_fkey FOREIGN KEY (attachment_role_id) REFERENCES public.attachment_roles(role_id);


--
-- Name: automatic_reminders fk_ar_branch_business; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.automatic_reminders
    ADD CONSTRAINT fk_ar_branch_business FOREIGN KEY (branch_id, business_id) REFERENCES public.branches(branch_id, business_id) DEFERRABLE;


--
-- Name: audit_log fk_audit_branch_business; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.audit_log
    ADD CONSTRAINT fk_audit_branch_business FOREIGN KEY (branch_id, business_id) REFERENCES public.branches(branch_id, business_id) DEFERRABLE;


--
-- Name: categories fk_categories_business; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.categories
    ADD CONSTRAINT fk_categories_business FOREIGN KEY (business_id) REFERENCES public.businesses(business_id);


--
-- Name: cash_registers fk_creg_branch_business; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.cash_registers
    ADD CONSTRAINT fk_creg_branch_business FOREIGN KEY (branch_id, business_id) REFERENCES public.branches(branch_id, business_id) DEFERRABLE;


--
-- Name: message_deliveries fk_mdeliv_branch_business; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_deliveries
    ADD CONSTRAINT fk_mdeliv_branch_business FOREIGN KEY (branch_id, business_id) REFERENCES public.branches(branch_id, business_id) DEFERRABLE;


--
-- Name: marketing_campaigns fk_mkt_branch_business; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketing_campaigns
    ADD CONSTRAINT fk_mkt_branch_business FOREIGN KEY (branch_id, business_id) REFERENCES public.branches(branch_id, business_id) DEFERRABLE;


--
-- Name: sales fk_sales_branch_business; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales
    ADD CONSTRAINT fk_sales_branch_business FOREIGN KEY (branch_id, business_id) REFERENCES public.branches(branch_id, business_id) DEFERRABLE;


--
-- Name: services fk_services_category; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.services
    ADD CONSTRAINT fk_services_category FOREIGN KEY (category_id) REFERENCES public.categories(category_id);


--
-- Name: holidays holidays_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.holidays
    ADD CONSTRAINT holidays_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id);


--
-- Name: holidays holidays_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.holidays
    ADD CONSTRAINT holidays_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: holidays holidays_professional_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.holidays
    ADD CONSTRAINT holidays_professional_id_fkey FOREIGN KEY (professional_id) REFERENCES public.professionals(professional_id) ON DELETE CASCADE;


--
-- Name: import_batches import_batches_actor_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_batches
    ADD CONSTRAINT import_batches_actor_user_id_fkey FOREIGN KEY (actor_user_id) REFERENCES public.users(user_id) ON DELETE RESTRICT;


--
-- Name: import_batches import_batches_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_batches
    ADD CONSTRAINT import_batches_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: import_rows import_rows_batch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.import_rows
    ADD CONSTRAINT import_rows_batch_id_fkey FOREIGN KEY (batch_id) REFERENCES public.import_batches(batch_id) ON DELETE CASCADE;


--
-- Name: industries industries_category_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.industries
    ADD CONSTRAINT industries_category_id_fkey FOREIGN KEY (category_id) REFERENCES public.industry_categories(category_id);


--
-- Name: inventory_movements inventory_movements_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_movements
    ADD CONSTRAINT inventory_movements_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id);


--
-- Name: inventory_movements inventory_movements_movement_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_movements
    ADD CONSTRAINT inventory_movements_movement_type_id_fkey FOREIGN KEY (movement_type_id) REFERENCES public.movement_types(movement_type_id);


--
-- Name: inventory_movements inventory_movements_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_movements
    ADD CONSTRAINT inventory_movements_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- Name: inventory_movements inventory_movements_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.inventory_movements
    ADD CONSTRAINT inventory_movements_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- Name: invoices invoices_document_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_document_type_id_fkey FOREIGN KEY (document_type_id) REFERENCES public.document_types(document_type_id);


--
-- Name: invoices invoices_sale_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.invoices
    ADD CONSTRAINT invoices_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES public.sales(sale_id);


--
-- Name: legal_acceptances legal_acceptances_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.legal_acceptances
    ADD CONSTRAINT legal_acceptances_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- Name: local_plan_limits local_plan_limits_plan_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.local_plan_limits
    ADD CONSTRAINT local_plan_limits_plan_code_fkey FOREIGN KEY (plan_code) REFERENCES public.local_plans(code) ON DELETE CASCADE;


--
-- Name: local_subscription_modules local_subscription_modules_module_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.local_subscription_modules
    ADD CONSTRAINT local_subscription_modules_module_code_fkey FOREIGN KEY (module_code) REFERENCES public.local_modules(code);


--
-- Name: local_subscription_modules local_subscription_modules_tenant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.local_subscription_modules
    ADD CONSTRAINT local_subscription_modules_tenant_id_fkey FOREIGN KEY (tenant_id) REFERENCES public.local_subscriptions(tenant_id) ON DELETE CASCADE;


--
-- Name: local_subscriptions local_subscriptions_plan_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.local_subscriptions
    ADD CONSTRAINT local_subscriptions_plan_code_fkey FOREIGN KEY (plan_code) REFERENCES public.local_plans(code);


--
-- Name: marketing_campaigns marketing_campaigns_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketing_campaigns
    ADD CONSTRAINT marketing_campaigns_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id);


--
-- Name: marketing_campaigns marketing_campaigns_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketing_campaigns
    ADD CONSTRAINT marketing_campaigns_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id);


--
-- Name: marketing_campaigns marketing_campaigns_template_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketing_campaigns
    ADD CONSTRAINT marketing_campaigns_template_id_fkey FOREIGN KEY (template_id) REFERENCES public.message_templates(template_id);


--
-- Name: marketing_optouts marketing_optouts_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.marketing_optouts
    ADD CONSTRAINT marketing_optouts_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: message_deliveries message_deliveries_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_deliveries
    ADD CONSTRAINT message_deliveries_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id);


--
-- Name: message_deliveries message_deliveries_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_deliveries
    ADD CONSTRAINT message_deliveries_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id);


--
-- Name: message_deliveries message_deliveries_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_deliveries
    ADD CONSTRAINT message_deliveries_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.communication_channels(channel_id);


--
-- Name: message_deliveries message_deliveries_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_deliveries
    ADD CONSTRAINT message_deliveries_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id) ON DELETE CASCADE;


--
-- Name: message_deliveries message_deliveries_status_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_deliveries
    ADD CONSTRAINT message_deliveries_status_id_fkey FOREIGN KEY (status_id) REFERENCES public.delivery_statuses(status_id);


--
-- Name: message_deliveries message_deliveries_template_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_deliveries
    ADD CONSTRAINT message_deliveries_template_id_fkey FOREIGN KEY (template_id) REFERENCES public.message_templates(template_id);


--
-- Name: message_templates message_templates_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_templates
    ADD CONSTRAINT message_templates_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id);


--
-- Name: message_templates message_templates_channel_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.message_templates
    ADD CONSTRAINT message_templates_channel_id_fkey FOREIGN KEY (channel_id) REFERENCES public.communication_channels(channel_id);


--
-- Name: module_requests module_requests_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_requests
    ADD CONSTRAINT module_requests_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: module_requests module_requests_decided_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_requests
    ADD CONSTRAINT module_requests_decided_by_fkey FOREIGN KEY (decided_by) REFERENCES public.users(user_id) ON DELETE SET NULL;


--
-- Name: module_requests module_requests_module_code_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_requests
    ADD CONSTRAINT module_requests_module_code_fkey FOREIGN KEY (module_code) REFERENCES public.local_modules(code);


--
-- Name: module_requests module_requests_requested_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.module_requests
    ADD CONSTRAINT module_requests_requested_by_fkey FOREIGN KEY (requested_by) REFERENCES public.users(user_id) ON DELETE CASCADE;


--
-- Name: notification_dispatch_log notification_dispatch_log_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.notification_dispatch_log
    ADD CONSTRAINT notification_dispatch_log_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: payment_methods payment_methods_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payment_methods
    ADD CONSTRAINT payment_methods_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id);


--
-- Name: payments payments_method_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_method_id_fkey FOREIGN KEY (method_id) REFERENCES public.payment_methods(method_id);


--
-- Name: payments payments_sale_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.payments
    ADD CONSTRAINT payments_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES public.sales(sale_id) ON DELETE CASCADE;


--
-- Name: pending_appointments pending_appointments_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pending_appointments
    ADD CONSTRAINT pending_appointments_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id);


--
-- Name: pending_appointments pending_appointments_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pending_appointments
    ADD CONSTRAINT pending_appointments_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id) ON DELETE CASCADE;


--
-- Name: pending_appointments pending_appointments_professional_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pending_appointments
    ADD CONSTRAINT pending_appointments_professional_id_fkey FOREIGN KEY (professional_id) REFERENCES public.professionals(professional_id);


--
-- Name: pending_appointments pending_appointments_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.pending_appointments
    ADD CONSTRAINT pending_appointments_service_id_fkey FOREIGN KEY (service_id) REFERENCES public.services(service_id);


--
-- Name: product_movements product_movements_appointment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_movements
    ADD CONSTRAINT product_movements_appointment_id_fkey FOREIGN KEY (appointment_id) REFERENCES public.appointments(appointment_id) ON DELETE SET NULL;


--
-- Name: product_movements product_movements_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_movements
    ADD CONSTRAINT product_movements_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: product_movements product_movements_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_movements
    ADD CONSTRAINT product_movements_created_by_fkey FOREIGN KEY (created_by) REFERENCES public.users(user_id) ON DELETE SET NULL;


--
-- Name: product_movements product_movements_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_movements
    ADD CONSTRAINT product_movements_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id) ON DELETE SET NULL;


--
-- Name: product_movements product_movements_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_movements
    ADD CONSTRAINT product_movements_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id) ON DELETE CASCADE;


--
-- Name: product_order_items product_order_items_order_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_order_items
    ADD CONSTRAINT product_order_items_order_id_fkey FOREIGN KEY (order_id) REFERENCES public.product_orders(order_id) ON DELETE CASCADE;


--
-- Name: product_order_items product_order_items_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_order_items
    ADD CONSTRAINT product_order_items_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id) ON DELETE CASCADE;


--
-- Name: product_orders product_orders_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_orders
    ADD CONSTRAINT product_orders_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id) ON DELETE SET NULL;


--
-- Name: product_orders product_orders_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_orders
    ADD CONSTRAINT product_orders_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: product_orders product_orders_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_orders
    ADD CONSTRAINT product_orders_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id) ON DELETE SET NULL;


--
-- Name: product_orders product_orders_paid_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_orders
    ADD CONSTRAINT product_orders_paid_by_fkey FOREIGN KEY (paid_by) REFERENCES public.users(user_id) ON DELETE SET NULL;


--
-- Name: product_stocks product_stocks_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_stocks
    ADD CONSTRAINT product_stocks_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id) ON DELETE CASCADE;


--
-- Name: product_stocks product_stocks_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.product_stocks
    ADD CONSTRAINT product_stocks_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id) ON DELETE CASCADE;


--
-- Name: products products_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.products
    ADD CONSTRAINT products_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id);


--
-- Name: professional_branches professional_branches_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_branches
    ADD CONSTRAINT professional_branches_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id) ON DELETE CASCADE;


--
-- Name: professional_branches professional_branches_professional_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_branches
    ADD CONSTRAINT professional_branches_professional_id_fkey FOREIGN KEY (professional_id) REFERENCES public.professionals(professional_id) ON DELETE CASCADE;


--
-- Name: professional_schedules professional_schedules_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_schedules
    ADD CONSTRAINT professional_schedules_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id);


--
-- Name: professional_schedules professional_schedules_professional_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_schedules
    ADD CONSTRAINT professional_schedules_professional_id_fkey FOREIGN KEY (professional_id) REFERENCES public.professionals(professional_id);


--
-- Name: professional_unavailability professional_unavailability_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_unavailability
    ADD CONSTRAINT professional_unavailability_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id);


--
-- Name: professional_unavailability professional_unavailability_professional_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_unavailability
    ADD CONSTRAINT professional_unavailability_professional_id_fkey FOREIGN KEY (professional_id) REFERENCES public.professionals(professional_id);


--
-- Name: professional_unavailability professional_unavailability_type_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_unavailability
    ADD CONSTRAINT professional_unavailability_type_id_fkey FOREIGN KEY (type_id) REFERENCES public.unavailability_types(type_id);


--
-- Name: professional_weekly_hours professional_weekly_hours_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_weekly_hours
    ADD CONSTRAINT professional_weekly_hours_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id);


--
-- Name: professional_weekly_hours professional_weekly_hours_professional_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professional_weekly_hours
    ADD CONSTRAINT professional_weekly_hours_professional_id_fkey FOREIGN KEY (professional_id) REFERENCES public.professionals(professional_id);


--
-- Name: professionals professionals_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professionals
    ADD CONSTRAINT professionals_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id);


--
-- Name: professionals professionals_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.professionals
    ADD CONSTRAINT professionals_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- Name: quotes quotes_appointment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quotes
    ADD CONSTRAINT quotes_appointment_id_fkey FOREIGN KEY (appointment_id) REFERENCES public.appointments(appointment_id) ON DELETE SET NULL;


--
-- Name: quotes quotes_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quotes
    ADD CONSTRAINT quotes_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: quotes quotes_created_by_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quotes
    ADD CONSTRAINT quotes_created_by_user_id_fkey FOREIGN KEY (created_by_user_id) REFERENCES public.users(user_id) ON DELETE SET NULL;


--
-- Name: quotes quotes_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.quotes
    ADD CONSTRAINT quotes_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id) ON DELETE CASCADE;


--
-- Name: refresh_tokens refresh_tokens_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.refresh_tokens
    ADD CONSTRAINT refresh_tokens_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id) ON DELETE CASCADE;


--
-- Name: reviews reviews_appointment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_appointment_id_fkey FOREIGN KEY (appointment_id) REFERENCES public.appointments(appointment_id) ON DELETE SET NULL;


--
-- Name: reviews reviews_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.reviews
    ADD CONSTRAINT reviews_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: sale_details sale_details_appointment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sale_details
    ADD CONSTRAINT sale_details_appointment_id_fkey FOREIGN KEY (appointment_id) REFERENCES public.appointments(appointment_id) ON DELETE SET NULL;


--
-- Name: sale_details sale_details_product_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sale_details
    ADD CONSTRAINT sale_details_product_id_fkey FOREIGN KEY (product_id) REFERENCES public.products(product_id);


--
-- Name: sale_details sale_details_sale_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sale_details
    ADD CONSTRAINT sale_details_sale_id_fkey FOREIGN KEY (sale_id) REFERENCES public.sales(sale_id) ON DELETE CASCADE;


--
-- Name: sales sales_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales
    ADD CONSTRAINT sales_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id);


--
-- Name: sales sales_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales
    ADD CONSTRAINT sales_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id);


--
-- Name: sales sales_customer_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales
    ADD CONSTRAINT sales_customer_id_fkey FOREIGN KEY (customer_id) REFERENCES public.customers(customer_id);


--
-- Name: sales sales_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.sales
    ADD CONSTRAINT sales_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- Name: schedule_blocks schedule_blocks_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_blocks
    ADD CONSTRAINT schedule_blocks_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id) ON DELETE SET NULL;


--
-- Name: schedule_blocks schedule_blocks_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_blocks
    ADD CONSTRAINT schedule_blocks_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: schedule_blocks schedule_blocks_professional_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.schedule_blocks
    ADD CONSTRAINT schedule_blocks_professional_id_fkey FOREIGN KEY (professional_id) REFERENCES public.professionals(professional_id) ON DELETE CASCADE;


--
-- Name: service_branch_settings service_branch_settings_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_branch_settings
    ADD CONSTRAINT service_branch_settings_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id) ON DELETE CASCADE;


--
-- Name: service_branch_settings service_branch_settings_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_branch_settings
    ADD CONSTRAINT service_branch_settings_service_id_fkey FOREIGN KEY (service_id) REFERENCES public.services(service_id) ON DELETE CASCADE;


--
-- Name: service_professionals service_professionals_professional_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_professionals
    ADD CONSTRAINT service_professionals_professional_id_fkey FOREIGN KEY (professional_id) REFERENCES public.professionals(professional_id);


--
-- Name: service_professionals service_professionals_service_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.service_professionals
    ADD CONSTRAINT service_professionals_service_id_fkey FOREIGN KEY (service_id) REFERENCES public.services(service_id);


--
-- Name: services services_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.services
    ADD CONSTRAINT services_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id);


--
-- Name: support_tickets support_tickets_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_tickets
    ADD CONSTRAINT support_tickets_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id);


--
-- Name: support_tickets support_tickets_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.support_tickets
    ADD CONSTRAINT support_tickets_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id);


--
-- Name: user_branch_roles user_branch_roles_branch_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_branch_roles
    ADD CONSTRAINT user_branch_roles_branch_id_fkey FOREIGN KEY (branch_id) REFERENCES public.branches(branch_id) ON DELETE CASCADE;


--
-- Name: user_branch_roles user_branch_roles_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_branch_roles
    ADD CONSTRAINT user_branch_roles_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: user_branch_roles user_branch_roles_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_branch_roles
    ADD CONSTRAINT user_branch_roles_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(role_id);


--
-- Name: user_branch_roles user_branch_roles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_branch_roles
    ADD CONSTRAINT user_branch_roles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id) ON DELETE CASCADE;


--
-- Name: user_business_roles user_business_roles_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_business_roles
    ADD CONSTRAINT user_business_roles_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: user_business_roles user_business_roles_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_business_roles
    ADD CONSTRAINT user_business_roles_role_id_fkey FOREIGN KEY (role_id) REFERENCES public.roles(role_id);


--
-- Name: user_business_roles user_business_roles_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.user_business_roles
    ADD CONSTRAINT user_business_roles_user_id_fkey FOREIGN KEY (user_id) REFERENCES public.users(user_id) ON DELETE CASCADE;


--
-- Name: whatsapp_conversations whatsapp_conversations_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.whatsapp_conversations
    ADD CONSTRAINT whatsapp_conversations_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: whatsapp_integrations whatsapp_integrations_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.whatsapp_integrations
    ADD CONSTRAINT whatsapp_integrations_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- Name: whatsapp_messages whatsapp_messages_business_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.whatsapp_messages
    ADD CONSTRAINT whatsapp_messages_business_id_fkey FOREIGN KEY (business_id) REFERENCES public.businesses(business_id) ON DELETE CASCADE;


--
-- PostgreSQL database dump complete
--

\unrestrict gMIZ9zW2a0OeNag0tfMx1UyrMkWXa1RA3jBxCD6IOel4GbAN8qVDW0ThVymvgjB

